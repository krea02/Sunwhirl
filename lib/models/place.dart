import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';

enum PlaceType { cafe, pub, park }

class Place {
  final String id;
  final String name;
  final Point location; // Mapbox Point (lng/lat)
  final PlaceType type;

  // NEW (all optional so existing code keeps working)
  final bool? hasOutdoorSeating;   // true/false/unknown
  final int? outdoorSeats;         // seats:outdoor / seats:outside
  final bool? outdoorCovered;      // outdoor_seating:covered=yes or covered=yes

  const Place({
    required this.id,
    required this.name,
    required this.location,
    required this.type,
    this.hasOutdoorSeating,
    this.outdoorSeats,
    this.outdoorCovered,
  });

  Place copyWith({
    String? id,
    String? name,
    Point? location,
    PlaceType? type,
    bool? hasOutdoorSeating,
    int? outdoorSeats,
    bool? outdoorCovered,
  }) {
    return Place(
      id: id ?? this.id,
      name: name ?? this.name,
      location: location ?? this.location,
      type: type ?? this.type,
      hasOutdoorSeating: hasOutdoorSeating ?? this.hasOutdoorSeating,
      outdoorSeats: outdoorSeats ?? this.outdoorSeats,
      outdoorCovered: outdoorCovered ?? this.outdoorCovered,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
          other is Place && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'Place($id, $name, $type, outdoor:$hasOutdoorSeating seats:$outdoorSeats covered:$outdoorCovered)';
}
