import 'dart:math' as math;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';

class Building {
  final String id; // OSM way/relation ID
  final List<Position> polygon; // Mapbox Position
  final double height;
  late final CoordinateBounds _bounds; // Cache bounds

  Building({required this.id, required this.polygon, required this.height}) {
    _calculateBounds();
  }

  void _calculateBounds() {
    if (polygon.isEmpty) {
      _bounds = CoordinateBounds(
        southwest: Point(coordinates: Position(0.0, 0.0)),
        northeast: Point(coordinates: Position(0.0, 0.0)),
        infiniteBounds: false,
      );
      return;
    }

    double minLat = double.infinity, maxLat = double.negativeInfinity;
    double minLng = double.infinity, maxLng = double.negativeInfinity;

    for (final p in polygon) {
      // ---- FIX IS HERE ----
      // Cast immediately upon assignment
      minLat = math.min(minLat, p.lat).toDouble();
      maxLat = math.max(maxLat, p.lat).toDouble();
      minLng = math.min(minLng, p.lng).toDouble();
      maxLng = math.max(maxLng, p.lng).toDouble();
      // ---- END FIX ----
    }

    _bounds = CoordinateBounds(
      // No need for extra .toDouble() here now
      southwest: Point(coordinates: Position(minLng, minLat)),
      northeast: Point(coordinates: Position(maxLng, maxLat)),
      infiniteBounds: false,
    );
  }

  CoordinateBounds get bounds => _bounds;

  bool intersects(CoordinateBounds viewBounds) {
    if (viewBounds.infiniteBounds ?? false) return true;
    bool lngOverlap = _bounds.northeast.coordinates.lng >= viewBounds.southwest.coordinates.lng &&
        _bounds.southwest.coordinates.lng <= viewBounds.northeast.coordinates.lng;
    bool latOverlap = _bounds.northeast.coordinates.lat >= viewBounds.southwest.coordinates.lat &&
        _bounds.southwest.coordinates.lat <= viewBounds.northeast.coordinates.lat;
    return lngOverlap && latOverlap;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
          other is Building &&
              runtimeType == other.runtimeType &&
              id == other.id;

  @override
  int get hashCode => id.hashCode;
}