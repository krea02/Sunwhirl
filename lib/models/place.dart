import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';

enum PlaceType { cafe, pub, park }

class Place {
  final String id;
  final String name;
  final Point location; // Keep using Mapbox Point
  final PlaceType type;

  Place({
    required this.id,
    required this.name,
    required this.location,
    required this.type,
  });

  // Optional: Add == and hashCode for comparisons
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
          other is Place && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}