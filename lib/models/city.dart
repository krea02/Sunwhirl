class City {
  final String name;
  final double lat;   // degrees
  final double lng;   // degrees
  final double zoom;  // default zoom for this city

  const City({
    required this.name,
    required this.lat,
    required this.lng,
    required this.zoom,
  });

  @override
  String toString() => name;
}
