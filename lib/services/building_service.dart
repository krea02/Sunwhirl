import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import '../models/building.dart'; // Make sure this path is correct

class BuildingService {
  static final Map<String, List<Building>> _cache = {};
  static const String _overpassUrl = 'https://overpass-api.de/api/interpreter';
  static const double _metersPerLevel = 3.5;
  static const double _defaultBuildingHeight = 15.0;

  static Future<List<Building>> fetchBuildingsInBounds(CoordinateBounds bounds) async {
    final south = bounds.southwest.coordinates.lat;
    final west = bounds.southwest.coordinates.lng;
    final north = bounds.northeast.coordinates.lat;
    final east = bounds.northeast.coordinates.lng;

    final queryBoundsKey = "${south.toStringAsFixed(4)},${west.toStringAsFixed(4)},${north.toStringAsFixed(4)},${east.toStringAsFixed(4)}";

    if (_cache.containsKey(queryBoundsKey)) {
      return _cache[queryBoundsKey]!;
    }

    const double buffer = 0.001;
    final queryBounds = "${south - buffer},${west - buffer},${north + buffer},${east + buffer}";

    final query = '''
      [out:json][timeout:30];
      (
        way["building"]($queryBounds);
        relation["building"]($queryBounds);
      );
      (._;>;);
      out body;
    ''';

    try {
      final response = await http.post(
        Uri.parse(_overpassUrl),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {'data': query},
      );

      if (response.statusCode != 200) {
        throw Exception("Failed to fetch buildings: ${response.statusCode} ${response.reasonPhrase}");
      }

      final data = json.decode(utf8.decode(response.bodyBytes));
      final List<Building> buildings = _parseOverpassResponse(data);
      _cache[queryBoundsKey] = buildings;
      return buildings;

    } catch (e) {
      if (kDebugMode) {
        print("Error during Overpass request or parsing: $e");
      }
      return [];
    }
  }

  static List<Building> _parseOverpassResponse(Map<String, dynamic> data) {
    final nodes = <int, Position>{};
    final ways = <int, List<int>>{};
    final wayTags = <int, Map<String, dynamic>>{};
    final buildings = <Building>[];
    final processedElements = <String>{};

    if (data['elements'] == null) return [];

    for (var el in data['elements']) {
      if (el['type'] == 'node' && el['id'] != null && el['lon'] != null && el['lat'] != null) {
        nodes[el['id']] = Position(
          (el['lon'] as num).toDouble(),
          (el['lat'] as num).toDouble(),
        );
      } else if (el['type'] == 'way' && el['id'] != null && el['nodes'] != null) {
        ways[el['id']] = List<int>.from(el['nodes']);
        if (el['tags'] != null) {
          wayTags[el['id']] = Map<String, dynamic>.from(el['tags']);
        }
      }
    }

    for (var el in data['elements']) {
      String elementKey = "${el['type']}-${el['id']}";
      if (processedElements.contains(elementKey)) continue;

      List<Position>? polygon;
      Map<String, dynamic>? tags;
      String buildingId = elementKey;

      if (el['type'] == 'way' && wayTags[el['id']]?['building'] != null) {
        polygon = ways[el['id']]
            ?.map((nodeId) => nodes[nodeId])
            .whereType<Position>()
            .toList();
        tags = wayTags[el['id']];
        processedElements.add(elementKey);

      } else if (el['type'] == 'relation' && el['tags']?['building'] != null) {
        List<int> outerWayIds = (el['members'] as List<dynamic>?)
            ?.where((m) => m['type'] == 'way' && m['role'] == 'outer')
            .map((m) => m['ref'] as int)
            .toList() ?? [];

        if (outerWayIds.isNotEmpty) {
          int wayId = outerWayIds.first;
          polygon = ways[wayId]
              ?.map((nodeId) => nodes[nodeId])
              .whereType<Position>()
              .toList();
          tags = el['tags'];
          buildingId = elementKey;
          processedElements.add(elementKey);
          processedElements.add("way-$wayId");
        }
      }

      if (polygon != null && polygon.length >= 3 && tags != null) {
        if (polygon.first != polygon.last) {
          polygon.add(polygon.first);
        }
        double height = _estimateHeight(tags);
        buildings.add(Building(id: buildingId, polygon: polygon, height: height));
      }
    }
    return buildings;
  }

  static double _estimateHeight(Map<String, dynamic> tags) {
    final heightStr = tags['height']?.toString();
    if (heightStr != null) {
      final heightNum = double.tryParse(heightStr.split(' ')[0].replaceAll(',', '.'));
      if (heightNum != null && heightNum > 0) return heightNum;
    }

    final levelsStr = tags['building:levels']?.toString();
    if (levelsStr != null) {
      final levelsNum = int.tryParse(levelsStr);
      if (levelsNum != null && levelsNum > 0) return levelsNum * _metersPerLevel;
    }

    return _defaultBuildingHeight;
  }

  static Future<List<Building>> fetchBuildings(double lat, double lng) async {
    return await fetchBuildingsAround(lat, lng, 200);
  }

  static Future<List<Building>> fetchBuildingsAround(
      double lat, double lng, double radiusInMeters) async {
    final double delta = radiusInMeters / 111320.0;

    final bounds = CoordinateBounds(
      southwest: Point(coordinates: Position(lng - delta, lat - delta)),
      northeast: Point(coordinates: Position(lng + delta, lat + delta)),
      infiniteBounds: false,
    );

    final buildings = await fetchBuildingsInBounds(bounds);
    return buildings;
  }
}
