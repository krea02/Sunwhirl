import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import '../models/place.dart';

class PlaceService {
  static final Map<String, List<Place>> _cache = {};
  static const String _overpassUrl = 'https://overpass-api.de/api/interpreter';

  /// Fetch places within bounds:
  /// - amenity: cafe, restaurant, bar, pub, fast_food, biergarten
  /// - leisure: park
  /// We request tags + center so we can infer outdoor seating and place markers.
  static Future<List<Place>> fetchPlacesInBounds(CoordinateBounds bounds) async {
    final south = bounds.southwest.coordinates.lat.toStringAsFixed(6);
    final west  = bounds.southwest.coordinates.lng.toStringAsFixed(6);
    final north = bounds.northeast.coordinates.lat.toStringAsFixed(6);
    final east  = bounds.northeast.coordinates.lng.toStringAsFixed(6);
    final bbox  = "$south,$west,$north,$east";

    final cacheKey = bbox;
    if (_cache.containsKey(cacheKey)) {
      if (kDebugMode) print("PlaceService: cache hit for $cacheKey");
      return _cache[cacheKey]!;
    }

    final query = """
[out:json][timeout:30];
(
  nwr["amenity"~"cafe|restaurant|bar|pub|fast_food"]($bbox);
  nwr["amenity"="biergarten"]($bbox);
  nwr["leisure"="park"]($bbox);
);
out center tags;
""";

    if (kDebugMode) {
      // print("PlaceService query:\\n$query");
    }

    try {
      final response = await http.post(
        Uri.parse(_overpassUrl),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {'data': query},
      );

      if (response.statusCode != 200) {
        if (kDebugMode) {
          print("PlaceService: Overpass error ${response.statusCode}: ${response.reasonPhrase}");
        }
        throw Exception("Failed to fetch places: ${response.statusCode}");
      }

      final data = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final places = _parseOverpassPlacesResponse(data);

      _cache[cacheKey] = places;
      if (kDebugMode) print("PlaceService: fetched ${places.length} places for $cacheKey");
      return places;
    } catch (e) {
      if (kDebugMode) print("PlaceService error: $e");
      return [];
    }
  }

  /// Parse Overpass response to Place list with outdoor seating inference.
  static List<Place> _parseOverpassPlacesResponse(Map<String, dynamic> data) {
    final List<Place> places = [];
    final Set<String> seen = {};
    final elements = (data['elements'] as List<dynamic>?) ?? const [];

    for (final raw in elements) {
      final el = raw as Map<String, dynamic>;
      final tags = (el['tags'] as Map?)?.cast<String, dynamic>() ?? const {};

      // Determine type
      final amenity = tags['amenity']?.toString();
      final leisure = tags['leisure']?.toString();
      PlaceType? type;
      if (amenity == 'cafe' || amenity == 'restaurant' || amenity == 'fast_food') {
        type = PlaceType.cafe;
      } else if (amenity == 'pub' || amenity == 'bar' || amenity == 'biergarten') {
        type = PlaceType.pub;
      } else if (leisure == 'park') {
        type = PlaceType.park;
      } else {
        continue;
      }

      // Coordinates: node has lat/lon; ways/relations use center
      double? lat, lon;
      if (el['type'] == 'node') {
        lat = (el['lat'] as num?)?.toDouble();
        lon = (el['lon'] as num?)?.toDouble();
      } else {
        final c = el['center'] as Map<String, dynamic>?;
        lat = (c?['lat'] as num?)?.toDouble();
        lon = (c?['lon'] as num?)?.toDouble();
      }
      if (lat == null || lon == null) continue;

      final id = "${el['type']}/${el['id']}";
      if (seen.contains(id)) continue;
      seen.add(id);

      final name = (tags['name'] as String?) ?? "Unnamed ${type.name}";

      // ---- Outdoor seating inference ----
      bool? hasOutdoor;
      int? outdoorSeats;
      bool? outdoorCovered;

      // 1) explicit outdoor_seating
      final os = (tags['outdoor_seating'] ?? tags['outdoor seating'])?.toString().toLowerCase();
      if (os == 'yes' || os == 'only') hasOutdoor = true;
      else if (os == 'no') hasOutdoor = false;

      // 2) seat counts
      final seatsStr = (tags['seats:outdoor'] ?? tags['seats:outside'])?.toString();
      if (seatsStr != null) {
        final parsed = int.tryParse(seatsStr.replaceAll(RegExp(r'[^0-9]'), ''));
        if (parsed != null) {
          outdoorSeats = parsed;
          hasOutdoor ??= parsed > 0;
        }
      }

      // 3) proxies: biergarten / terrace
      if (amenity == 'biergarten') hasOutdoor = true;
      if (tags['terrace']?.toString().toLowerCase() == 'yes') {
        hasOutdoor ??= true;
      }

      // 4) covered?
      final covered = tags['outdoor_seating:covered'] ?? tags['covered'];
      if (covered?.toString().toLowerCase() == 'yes') {
        outdoorCovered = true;
      } else if (covered?.toString().toLowerCase() == 'no') {
        outdoorCovered = false;
      }

      places.add(
        Place(
          id: id,
          name: name,
          location: Point(coordinates: Position(lon, lat)),
          type: type,
          hasOutdoorSeating: hasOutdoor,
          outdoorSeats: outdoorSeats,
          outdoorCovered: outdoorCovered,
        ),
      );
    }

    return places;
  }

  static void clearCache() {
    _cache.clear();
    if (kDebugMode) print("PlaceService: cache cleared");
  }
}
