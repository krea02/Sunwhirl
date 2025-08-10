import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import '../models/place.dart'; // Your existing Place model

class PlaceService {
  static final Map<String, List<Place>> _cache = {}; // Cache for fetched places
  static const String _overpassUrl = 'https://overpass-api.de/api/interpreter'; // Same as BuildingService

  // Method to fetch places (cafes, pubs, parks) within the given bounds
  static Future<List<Place>> fetchPlacesInBounds(
      CoordinateBounds bounds,
      // Optionally, you could pass a list of PlaceTypes to fetch,
      // but for now, let's fetch all three main types.
      // List<PlaceType> desiredTypes,
      ) async {
    final south = bounds.southwest.coordinates.lat.toStringAsFixed(6);
    final west = bounds.southwest.coordinates.lng.toStringAsFixed(6);
    final north = bounds.northeast.coordinates.lat.toStringAsFixed(6);
    final east = bounds.northeast.coordinates.lng.toStringAsFixed(6);
    final bbox = "$south,$west,$north,$east";

    // Create a cache key based on bounds (could also include types if they were dynamic)
    final String cacheKey = bbox;
    if (_cache.containsKey(cacheKey)) {
      if (kDebugMode) print("PlaceService: Returning places from cache for $cacheKey");
      return _cache[cacheKey]!;
    }

    // Construct Overpass query parts for each type
    List<String> queryClauses = [];

    // Cafes
    queryClauses.add('node["amenity"="cafe"]($bbox);');
    queryClauses.add('way["amenity"="cafe"]($bbox);');
    // Relations for cafes are rare but possible for chains or large complexes
    // queryClauses.add('relation["amenity"="cafe"]($bbox);');

    // Pubs
    queryClauses.add('node["amenity"="pub"]($bbox);');
    queryClauses.add('way["amenity"="pub"]($bbox);');

    // Parks
    queryClauses.add('node["leisure"="park"]($bbox);');
    queryClauses.add('way["leisure"="park"]($bbox);');
    queryClauses.add('relation["leisure"="park"]($bbox);'); // Parks are often relations

    final String placeQueries = queryClauses.join('\n      ');

    final query = """
    [out:json][timeout:30];
    (
      $placeQueries
    );
    out center; 
    // 'out center;' gets the center point for ways/relations, nodes are output as is.
    // This is suitable for placing markers.
    """;

    if (kDebugMode) print("PlaceService: Fetching places with query:\n$query");

    try {
      final response = await http.post(
        Uri.parse(_overpassUrl),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {'data': query},
      );

      if (response.statusCode != 200) {
        if (kDebugMode) print("PlaceService: Overpass API error ${response.statusCode}: ${response.reasonPhrase}");
        throw Exception("Failed to fetch places: ${response.statusCode}");
      }

      final data = json.decode(utf8.decode(response.bodyBytes));
      final List<Place> places = _parseOverpassPlacesResponse(data);

      _cache[cacheKey] = places; // Cache the result
      if (kDebugMode) print("PlaceService: Fetched ${places.length} places for $cacheKey");
      return places;

    } catch (e) {
      if (kDebugMode) print("PlaceService: Error during Overpass request or parsing for places: $e");
      return []; // Return empty list on error
    }
  }

  // Helper to parse the Overpass API response into a list of Place objects
  static List<Place> _parseOverpassPlacesResponse(Map<String, dynamic> data) {
    final List<Place> places = [];
    final Set<String> processedOsmIds = {}; // To avoid duplicates if an element matches multiple clauses

    if (data['elements'] == null) return places;

    for (var el in data['elements']) {
      Map<String, dynamic>? tags = el['tags'] != null ? Map<String, dynamic>.from(el['tags']) : null;
      if (tags == null) continue;

      String? name = tags['name'];
      double lat, lon;
      String osmElementType = el['type']; // "node", "way", or "relation"
      int osmElementId = el['id'];
      String uniqueOsmId = "$osmElementType/$osmElementId";

      // Get coordinates
      if (osmElementType == 'node') {
        if (el['lat'] == null || el['lon'] == null) continue; // Skip if node has no coords
        lat = (el['lat'] as num).toDouble();
        lon = (el['lon'] as num).toDouble();
      } else if (el['center'] != null && el['center']['lat'] != null && el['center']['lon'] != null) {
        // For ways/relations with "out center;"
        lat = (el['center']['lat'] as num).toDouble();
        lon = (el['center']['lon'] as num).toDouble();
      } else {
        // if (kDebugMode) print("PlaceService: Skipping element ${uniqueOsmId} due to missing center/coords.");
        continue; // No coordinates found for way/relation center
      }

      PlaceType? placeType;

      // Determine PlaceType based on tags
      if (tags['amenity'] == 'cafe') {
        placeType = PlaceType.cafe;
      } else if (tags['amenity'] == 'pub') {
        placeType = PlaceType.pub;
      } else if (tags['leisure'] == 'park') {
        placeType = PlaceType.park;
      }
      // Add more types or refine logic as needed

      if (placeType != null) {
        // Use a default name if none is tagged
        name ??= "Unnamed ${placeType.name}";

        if (processedOsmIds.contains(uniqueOsmId)) continue; // Already processed this OSM element
        processedOsmIds.add(uniqueOsmId);

        places.add(Place(
          id: uniqueOsmId, // Use unique OSM ID (e.g., "node/12345")
          name: name,
          location: Point(coordinates: Position(lon, lat)),
          type: placeType,
        ));
      }
    }
    return places;
  }

  // Optional: Clear cache if needed, e.g., for debugging or forced refresh
  static void clearCache() {
    _cache.clear();
    if (kDebugMode) print("PlaceService: Cache cleared.");
  }
}