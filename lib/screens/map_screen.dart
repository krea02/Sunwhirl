import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/place.dart';
import '../models/building.dart';
import '../utils/sun_utils.dart';
import '../providers/map_state.dart';

// NEW
import '../models/city.dart';
import '../data/slovenia_cities.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with AutomaticKeepAliveClientMixin {
  MapboxMap? _mapboxMap;
  PointAnnotationManager? _pointAnnotationManager;
  PolygonAnnotationManager? _polygonManager;

  // icon name -> PNG bytes (cached once at startup)
  final Map<String, Uint8List> _placeIconImages = {};
  bool _iconsLoaded = false;

  Timer? _mapIdleTimer;
  CameraState? _lastCameraState;
  CameraState? _previousIdleCameraState;
  bool _mapReady = false;

  // For click handling
  final Map<String, Place> _annotationIdToPlace = {}; // annotation.id -> Place

  // Diffing for markers
  final Map<String, PointAnnotation> _placeIdToAnnotation = {}; // placeId -> annotation
  final Map<String, bool> _placeSunState = {};                  // placeId -> last in-sun state
  String _iconScaleBucket = "";                                 // last zoom bucket

  DateTime? _lastDrawTime;
  bool _isRedrawing = false;

  // Sticky icons: keep markers within padded viewport
  static const double _markerPadMeters = 350.0; // try 300–500m

  // Safety cap for total annotations
  static const int _kMaxAnnotations = 1200;

  // NEW: current chosen city (nullable at start)
  City? _selectedCity;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadIconImages();
  }

  @override
  void dispose() {
    _mapIdleTimer?.cancel();
    _pointAnnotationManager = null;
    _polygonManager = null;
    _mapboxMap = null;
    _placeIconImages.clear();
    _annotationIdToPlace.clear();
    _placeIdToAnnotation.clear();
    _placeSunState.clear();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final mapState = context.watch<MapState>();
    final currentTime = mapState.selectedDateTime;

    if (_mapReady && !_isRedrawing && (_lastDrawTime == null || !_lastDrawTime!.isAtSameMomentAs(currentTime))) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_isRedrawing) {
          _tryRedraw("time change in didChangeDependencies");
        }
      });
    }
  }

  Future<void> _loadIconImages() async {
    final iconPaths = {
      "cafe_sun": "assets/icons/cafe_sun.png", "cafe_moon": "assets/icons/cafe_moon.png",
      "pub_sun": "assets/icons/pub_sun.png", "pub_moon": "assets/icons/pub_moon.png",
      "park_sun": "assets/icons/park_sun.png", "park_moon": "assets/icons/park_moon.png",
      "default_sun": "assets/icons/default_sun.png", "default_moon": "assets/icons/default_moon.png",
    };
    final futures = iconPaths.entries.map((entry) async {
      try {
        final byteData = await rootBundle.load(entry.value);
        return MapEntry(entry.key, byteData.buffer.asUint8List());
      } catch (e) {
        if (kDebugMode) print("❌ MapScreen: Error loading icon '${entry.value}': $e");
        return MapEntry(entry.key, Uint8List(0));
      }
    });
    final results = await Future.wait(futures);
    _placeIconImages
      ..clear()
      ..addEntries(results.where((e) => e.value.isNotEmpty));

    if (!mounted) return;
    setState(() => _iconsLoaded = true);
    if (_mapReady && !_isRedrawing) _tryRedraw("icons loaded");
  }

  Future<void> _onMapCreated(MapboxMap mapboxMap) async {
    if (!mounted) return;
    _mapboxMap = mapboxMap;

    final mapState = Provider.of<MapState>(context, listen: false);
    final initialCenter = mapState.selectedPlace?.location
        ?? Point(coordinates: Position(14.3310, 46.3895)); // Tržič approx
    const initialZoom = 14.0;

    try {
      await _mapboxMap!.setCamera(CameraOptions(center: initialCenter, zoom: initialZoom));
      _polygonManager = await mapboxMap.annotations.createPolygonAnnotationManager();
      _pointAnnotationManager = await mapboxMap.annotations.createPointAnnotationManager();

      _pointAnnotationManager?.addOnPointAnnotationClickListener(
        AnnotationClickListener(onAnnotationClick: (annotation) {
          final place = _annotationIdToPlace[annotation.id];
          if (place != null) _showPlaceDialog(place);
        }),
      );
    } catch (e) {
      if (kDebugMode) print("❌ MapScreen: Error during map/annotation manager setup: $e");
    }
  }

  void _onMapLoaded(MapLoadedEventData event) {
    if (!mounted) return;
    _mapReady = true;

    // Reset diff caches on full map load (style might be recreated)
    _placeIdToAnnotation.clear();
    _placeSunState.clear();
    _annotationIdToPlace.clear();
    _iconScaleBucket = "";

    _updateLastCameraState().then((_) {
      if (mounted && _lastCameraState != null) {
        _previousIdleCameraState = _lastCameraState;
        if (!_isRedrawing) {
          _triggerDataFetch();
          _tryRedraw("map loaded initial");
        }
      }
    });
  }

  void _onCameraIdle(MapIdleEventData event) {
    if (!mounted || !_mapReady) return;
    _mapIdleTimer?.cancel();
    _mapIdleTimer = Timer(const Duration(milliseconds: 700), () async {
      if (!mounted || !_mapReady || _isRedrawing) return;

      final CameraState? atStart = _previousIdleCameraState;
      await _updateLastCameraState();
      if (!mounted || _lastCameraState == null) return;

      bool fetch = true;
      bool redraw = true;

      if (atStart != null) {
        const dataPosTol = 0.00005; // ~5.5m
        const dataZoomTol = 0.05;
        const arrowPosTol = 0.0001; // ~11m

        final centerChangedForData =
            (atStart.center.coordinates.lat - _lastCameraState!.center.coordinates.lat).abs() > dataPosTol ||
                (atStart.center.coordinates.lng - _lastCameraState!.center.coordinates.lng).abs() > dataPosTol;
        final zoomChangedForData = (atStart.zoom - _lastCameraState!.zoom).abs() > dataZoomTol;

        if (!centerChangedForData && !zoomChangedForData) fetch = false;

        final centerChangedForArrow =
            (atStart.center.coordinates.lat - _lastCameraState!.center.coordinates.lat).abs() > arrowPosTol ||
                (atStart.center.coordinates.lng - _lastCameraState!.center.coordinates.lng).abs() > arrowPosTol;

        if (!centerChangedForArrow && !zoomChangedForData) redraw = false;
      }

      if (fetch) _triggerDataFetch();
      if (fetch || redraw) _tryRedraw("camera idle");
      _previousIdleCameraState = _lastCameraState;
    });
  }

  Future<void> _updateLastCameraState() async {
    if (_mapboxMap == null || !mounted) return;
    try {
      _lastCameraState = await _mapboxMap!.getCameraState();
    } catch (e) {
      if (kDebugMode) print("❌ MapScreen: Error updating camera state: $e");
      _lastCameraState = null;
    }
  }

  Future<void> _triggerDataFetch() async {
    if (_mapboxMap == null || _lastCameraState == null || !mounted || !_mapReady) return;
    final currentZoom = _lastCameraState!.zoom;
    final mapState = Provider.of<MapState>(context, listen: false);
    try {
      final bounds = await _mapboxMap!.coordinateBoundsForCamera(_lastCameraState!.toCameraOptions());
      mapState.fetchBuildingsForView(bounds, currentZoom);
      mapState.fetchPlacesForView(bounds, currentZoom);
    } catch (e) {
      if (kDebugMode) print("❌ MapScreen: Error in _triggerDataFetch: $e");
    }
  }

  void _moveCameraTo(Point center, {required double zoom}) {
    if (!mounted || _mapboxMap == null) return;
    _mapboxMap!.flyTo(
      CameraOptions(center: center, zoom: zoom, pitch: 15.0),
      MapAnimationOptions(duration: 1500, startDelay: 100),
    );
  }

  // ------------------ City jump ------------------

  void _goToCity(City city) {
    final mapState = Provider.of<MapState>(context, listen: false);

    // Clear cached coverage so new area fetches immediately
    mapState.clearAllAccumulatedBuildingData();
    mapState.clearAllAccumulatedPlaceData();

    setState(() => _selectedCity = city);

    final p = Point(coordinates: Position(city.lng, city.lat));
    _moveCameraTo(p, zoom: city.zoom);

    // Nudge fetch/redraw after the fly animation
    Future.delayed(const Duration(milliseconds: 1700), () async {
      if (!mounted) return;
      await _updateLastCameraState();
      _triggerDataFetch();
      _tryRedraw("city change → ${city.name}");
    });
  }

  // ------------------ Helpers (bounds, scale, thinning) ------------------

  bool _checkAabbIntersection(CoordinateBounds b1, CoordinateBounds b2) {
    if (b1.northeast.coordinates.lng < b2.southwest.coordinates.lng ||
        b2.northeast.coordinates.lng < b1.southwest.coordinates.lng) return false;
    if (b1.northeast.coordinates.lat < b2.southwest.coordinates.lat ||
        b2.northeast.coordinates.lat < b1.southwest.coordinates.lat) return false;
    return true;
  }

  bool _isPointInBounds(Position point, CoordinateBounds bounds, {bool inclusive = true}) {
    final double lat = point.lat.toDouble();
    final double lng = point.lng.toDouble();
    final double minLat = bounds.southwest.coordinates.lat.toDouble();
    final double maxLat = bounds.northeast.coordinates.lat.toDouble();
    final double minLng = bounds.southwest.coordinates.lng.toDouble();
    final double maxLng = bounds.northeast.coordinates.lng.toDouble();

    if (inclusive) {
      return lat >= minLat && lat <= maxLat && lng >= minLng && lng <= maxLng;
    }
    return lat > minLat && lat < maxLat && lng > minLng && lng < maxLng;
  }

  double _iconScaleForZoom(double z) {
    if (z < 14.0) return 0.5;
    if (z < 15.5) return 0.7;
    if (z < 17.0) return 0.85;
    return 1.0;
  }

  String _bucketForZoom(double z) {
    if (z < 14.0) return "S";
    if (z < 15.5) return "M";
    if (z < 17.0) return "L";
    return "XL";
  }

  CoordinateBounds _padBounds(CoordinateBounds b, double padMeters) {
    final sw = b.southwest.coordinates;
    final ne = b.northeast.coordinates;
    final midLat = (sw.lat + ne.lat) / 2.0;

    final dLat = SunUtils.metersToLat(padMeters);
    final dLng = SunUtils.metersToLng(padMeters, midLat.toDouble());

    return CoordinateBounds(
      southwest: Point(coordinates: Position(sw.lng - dLng, sw.lat - dLat)),
      northeast: Point(coordinates: Position(ne.lng + dLng, ne.lat + dLat)),
      infiniteBounds: false,
    );
  }

  List<int> _thinByGrid(List<PointAnnotationOptions> opts, int targetCount) {
    if (opts.length <= targetCount) {
      return List<int>.generate(opts.length, (i) => i);
    }

    const int grid = 32;
    final chosen = <int>{};
    final firstInCell = <int, int>{};

    double _norm(double v, double a, double b) => ((v - a) / (b - a + 1e-12)).clamp(0.0, 0.9999);

    // Envelope of batch
    double minLat = double.infinity, maxLat = -double.infinity;
    double minLng = double.infinity, maxLng = -double.infinity;
    for (final o in opts) {
      final p = (o.geometry as Point).coordinates;
      minLat = math.min(minLat, p.lat.toDouble());
      maxLat = math.max(maxLat, p.lat.toDouble());
      minLng = math.min(minLng, p.lng.toDouble());
      maxLng = math.max(maxLng, p.lng.toDouble());
    }

    // One per cell, then fill remainder
    for (int i = 0; i < opts.length; i++) {
      final p = (opts[i].geometry as Point).coordinates;
      final c = (_norm(p.lng.toDouble(), minLng, maxLng) * grid).floor();
      final r = (_norm(p.lat.toDouble(), minLat, maxLat) * grid).floor();
      final key = r * 1000 + c;
      if (!firstInCell.containsKey(key)) {
        firstInCell[key] = i;
        chosen.add(i);
        if (chosen.length >= targetCount) break;
      }
    }
    for (int i = 0; i < opts.length && chosen.length < targetCount; i++) {
      chosen.add(i);
    }

    return chosen.toList()..sort();
  }

  // ------------------ Redraw pipeline (same as before) ------------------

  Future<void> _tryRedraw(String source) async {
    if (_isRedrawing) {
      if (kDebugMode) print("ℹ️ MapScreen: Redraw skipped (already running) — source: $source");
      return;
    }
    if (!mounted || _mapboxMap == null || !_mapReady || !_iconsLoaded ||
        _polygonManager == null || _pointAnnotationManager == null || _lastCameraState == null) {
      if (kDebugMode) print("ℹ️ MapScreen: Redraw skipped (not ready) — source: $source");
      return;
    }

    _isRedrawing = true;
    final mapState = Provider.of<MapState>(context, listen: false);
    final DateTime dateTime = mapState.selectedDateTime;

    try {
      final buildings = mapState.buildings;
      final places = mapState.places;
      final bounds = await _mapboxMap!.coordinateBoundsForCamera(_lastCameraState!.toCameraOptions());

      _lastDrawTime = dateTime;

      final shadowLogic = await _calculateAndDrawBuildingShadows(buildings, dateTime, bounds);
      await _drawPlaces(places, buildings, dateTime, shadowLogic, bounds);
    } catch (e, s) {
      if (kDebugMode && mounted) {
        print("❌ MapScreen: Redraw error: $e\n$s");
      }
    } finally {
      if (mounted) {
        _isRedrawing = false;
      }
    }
  }

  Future<Map<String, List<Position>>> _calculateAndDrawBuildingShadows(
      List<Building> allLoadedBuildings,
      DateTime dateTime,
      CoordinateBounds currentViewportBounds,
      ) async {
    if (!mounted || _polygonManager == null || _lastCameraState == null) return {};

    try { await _polygonManager!.deleteAll(); } catch (_) {}

    final sunPosCenter = SunUtils.getSunPosition(
      dateTime,
      _lastCameraState!.center.coordinates.lat.toDouble(),
      _lastCameraState!.center.coordinates.lng.toDouble(),
    );
    final double sunAltitudeRad = sunPosCenter['altitude']!;
    final double sunAzimuth_N_CW_rad = sunPosCenter['azimuth']!;

    final Map<String, List<Position>> calculatedShadowsForLogic = {};
    final List<PolygonAnnotationOptions> draw = [];

    if (sunAltitudeRad <= SunUtils.altitudeThresholdRad) {
      for (final b in allLoadedBuildings) {
        calculatedShadowsForLogic.putIfAbsent(b.id, () => []);
      }
      return calculatedShadowsForLogic;
    }

    final altDeg = sunAltitudeRad * SunUtils.deg;
    const double maxShadowOpacity = 0.22;
    const double horizonFadeEndAlt = SunUtils.altitudeThresholdRad * SunUtils.deg + 0.5;
    const double horizonFadeStartAlt = 5.0;
    const double peakOpacityStartAlt = 20.0;
    const double peakOpacityEndAlt = 65.0;
    const double zenithFadeStartAlt = peakOpacityEndAlt;
    const double zenithEndAlt = 88.0;

    double baseOpacity;
    if (altDeg <= horizonFadeEndAlt || altDeg >= zenithEndAlt) {
      baseOpacity = 0.0;
    } else if (altDeg < horizonFadeStartAlt) {
      baseOpacity = ((altDeg - horizonFadeEndAlt) / (horizonFadeStartAlt - horizonFadeEndAlt)) * maxShadowOpacity;
    } else if (altDeg < peakOpacityStartAlt) {
      baseOpacity = ((altDeg - horizonFadeStartAlt) / (peakOpacityStartAlt - horizonFadeStartAlt)) * maxShadowOpacity;
    } else if (altDeg <= zenithFadeStartAlt) {
      baseOpacity = maxShadowOpacity;
    } else {
      baseOpacity = (1.0 - (altDeg - zenithFadeStartAlt) / (zenithEndAlt - zenithFadeStartAlt)) * maxShadowOpacity;
    }
    baseOpacity = baseOpacity.clamp(0.0, maxShadowOpacity);

    if (baseOpacity <= 0.005) {
      for (final b in allLoadedBuildings) {
        calculatedShadowsForLogic.putIfAbsent(b.id, () => []);
      }
      return calculatedShadowsForLogic;
    }

    final zoom = _lastCameraState!.zoom;
    final centerLat = _lastCameraState!.center.coordinates.lat.toDouble();
    final mpp = SunUtils.metersPerPixel(centerLat, zoom);
    final double minShadowMeters = math.max(0.5, mpp * 1.2);

    final zoomFactor = ((zoom - 12.0) / 5.0).clamp(0.0, 1.0);
    final zoomOpacityAdj = 0.65 + 0.35 * zoomFactor;

    final sw = currentViewportBounds.southwest.coordinates;
    final ne = currentViewportBounds.northeast.coordinates;
    double _toCol(double lng) => ((lng - sw.lng) / (ne.lng - sw.lng + 1e-12)).clamp(0.0, 0.9999);
    double _toRow(double lat) => ((lat - sw.lat) / (ne.lat - sw.lat + 1e-12)).clamp(0.0, 0.9999);
    const int gridN = 32;
    final density = List.generate(gridN, (_) => List.filled(gridN, 0));
    const baseShadowColor = Color(0xFF1A1A1A);

    for (final b in allLoadedBuildings) {
      if (!_checkAabbIntersection(b.bounds, currentViewportBounds)) {
        calculatedShadowsForLogic[b.id] = [];
        continue;
      }

      final poly = SunUtils.calculateBuildingShadow(
        building: b,
        sunAzimuth_N_CW_rad: sunAzimuth_N_CW_rad,
        sunAltitudeRad: sunAltitudeRad,
        minDrawableShadowMeters: minShadowMeters,
      );
      calculatedShadowsForLogic[b.id] = poly.isNotEmpty ? List<Position>.from(poly) : [];
      if (poly.length < 3) continue;

      double cLat = 0, cLng = 0;
      for (final p in poly) { cLat += p.lat.toDouble(); cLng += p.lng.toDouble(); }
      cLat /= poly.length; cLng /= poly.length;
      final col = (_toCol(cLng) * gridN).floor().clamp(0, gridN - 1);
      final row = (_toRow(cLat) * gridN).floor().clamp(0, gridN - 1);
      final seen = density[row][col];

      final overlapFactor = 1.0 / (1.0 + seen);
      final op = (baseOpacity * zoomOpacityAdj * overlapFactor).clamp(0.03, 0.16);

      List<Position> hole = [];
      if (b.polygon.isNotEmpty) {
        final fp = List<Position>.from(b.polygon);
        if (fp.first.lat != fp.last.lat || fp.first.lng != fp.last.lng) fp.add(fp.first);
        if (fp.length >= 4) hole = List<Position>.from(fp.reversed);
      }

      final rings = <List<Position>>[poly];
      if (hole.isNotEmpty) rings.add(hole);

      draw.add(
        PolygonAnnotationOptions(
          geometry: Polygon(coordinates: rings),
          fillColor: baseShadowColor.withOpacity(op).value,
          fillOutlineColor: Colors.transparent.value,
          fillSortKey: 0,
        ),
      );

      density[row][col] = seen + 1;
    }

    try {
      if (draw.isNotEmpty) {
        await _polygonManager!.createMulti(draw);
      }
    } catch (e) {
      if (kDebugMode) print("ℹ️ MapScreen: createMulti(shadows) error: $e");
    }

    return calculatedShadowsForLogic;
  }

  Future<void> _drawPlaces(
      List<Place> allLoadedPlaces,
      List<Building> allLoadedBuildings,
      DateTime dateTime,
      Map<String, List<Position>> calculatedShadowsForLogic,
      CoordinateBounds currentViewportBounds,
      ) async {
    if (!mounted || _pointAnnotationManager == null || !_iconsLoaded || _lastCameraState == null) return;

    final double zoom = _lastCameraState!.zoom;
    final double iconScale = _iconScaleForZoom(zoom);
    final String newBucket = _bucketForZoom(zoom);

    final paddedBounds = _padBounds(currentViewportBounds, _markerPadMeters);
    final relevantBuildings =
    allLoadedBuildings.where((b) => _checkAabbIntersection(b.bounds, paddedBounds)).toList();

    final visiblePlaceIds = <String>{};
    final toDelete = <PointAnnotation>[];
    final toDeletePlaceIds = <String>[];
    final toCreate = <PointAnnotationOptions>[];
    final placesForCreatedAnnotations = <Place>[];
    final newSunState = <String, bool>{};

    for (final place in allLoadedPlaces) {
      if (!_isPointInBounds(place.location.coordinates, paddedBounds, inclusive: true)) continue;
      visiblePlaceIds.add(place.id);

      final placeLat = place.location.coordinates.lat.toDouble();
      final placeLng = place.location.coordinates.lng.toDouble();

      final sunPos = SunUtils.getSunPosition(dateTime, placeLat, placeLng);
      final double altRad = sunPos['altitude']!;
      final double azRad = sunPos['azimuth']!;

      bool isDirectSun, isEffectiveSun;
      String? hostId;

      for (final b in relevantBuildings) {
        if (b.polygon.length >= 3 && SunUtils.isPointInPolygon(place.location.coordinates, b.polygon)) {
          hostId = b.id; break;
        }
      }

      if (altRad > SunUtils.altitudeThresholdRad) {
        isDirectSun = !SunUtils.isPlaceInShadow(
          placePosition: place.location.coordinates,
          sunAzimuth_N_CW_rad: azRad,
          sunAltitudeRad: altRad,
          potentialBlockers: relevantBuildings,
          buildingShadows: calculatedShadowsForLogic,
          ignoreBuildingId: hostId,
        );

        isEffectiveSun = isDirectSun;
        if (isDirectSun) {
          int shadowedNeighbors = 0;
          const double d = 2.5;
          const int need = 3;

          final dLat = SunUtils.metersToLat(d);
          final dLng = SunUtils.metersToLng(d, placeLat);
          final probes = <Position>[
            Position(placeLng, placeLat + dLat),
            Position(placeLng + dLng, placeLat),
            Position(placeLng, placeLat - dLat),
            Position(placeLng - dLng, placeLat),
          ];
          for (final p in probes) {
            if (SunUtils.isPlaceInShadow(
              placePosition: p,
              sunAzimuth_N_CW_rad: azRad,
              sunAltitudeRad: altRad,
              potentialBlockers: relevantBuildings,
              buildingShadows: calculatedShadowsForLogic,
              ignoreBuildingId: null,
              checkRadiusMeters: 0.25,
              insideHostBuildingCheckRadiusMeters: 0.25,
            )) {
              shadowedNeighbors++;
            }
          }
          if (shadowedNeighbors >= need) isEffectiveSun = false;
        }
      } else {
        isDirectSun = false;
        isEffectiveSun = false;
      }

      newSunState[place.id] = isEffectiveSun;

      final iconKey = SunUtils.getIconPath(place.type, isEffectiveSun);
      final bytes = _placeIconImages[iconKey];
      if (bytes == null || bytes.isEmpty) continue;

      final had = _placeIdToAnnotation.containsKey(place.id);
      final bucketChanged = (_iconScaleBucket != newBucket);
      final sunChanged = (_placeSunState[place.id] != isEffectiveSun);

      if (!had || bucketChanged || sunChanged) {
        final existing = _placeIdToAnnotation[place.id];
        if (existing != null) {
          toDelete.add(existing);
          toDeletePlaceIds.add(place.id);
        }
        toCreate.add(PointAnnotationOptions(
          geometry: place.location,
          image: bytes,
          iconSize: iconScale,
          iconAnchor: IconAnchor.BOTTOM,
          iconOffset: [0.0, -2.0 * iconScale],
          symbolSortKey: 10,
        ));
        placesForCreatedAnnotations.add(place);
      }
    }

    // remove those no longer in padded viewport
    final gone = _placeIdToAnnotation.keys.where((id) {
      final ann = _placeIdToAnnotation[id];
      if (ann == null) return true;
      final pt = ann.geometry.coordinates;
      return !_isPointInBounds(pt, paddedBounds, inclusive: true);
    }).toList();

    for (final pid in gone) {
      final ann = _placeIdToAnnotation[pid];
      if (ann != null) {
        toDelete.add(ann);
        toDeletePlaceIds.add(pid);
      }
    }

    if (toDelete.isNotEmpty) {
      for (final pid in toDeletePlaceIds) {
        final ann = _placeIdToAnnotation.remove(pid);
        if (ann != null) _annotationIdToPlace.remove(ann.id);
      }
      try {
        for (final ann in toDelete) {
          await _pointAnnotationManager!.delete(ann);
        }
      } catch (e) {
        if (kDebugMode) print("ℹ️ MapScreen: delete error: $e");
      }
    }

    // enforce cap with grid thinning for the batch
    if (toCreate.isNotEmpty) {
      final existingCount = _placeIdToAnnotation.length;
      final budget = (_kMaxAnnotations - existingCount).clamp(0, _kMaxAnnotations);
      if (budget <= 0) {
        toCreate.clear();
        placesForCreatedAnnotations.clear();
      } else if (toCreate.length > budget) {
        final keepIdx = _thinByGrid(toCreate, budget);
        final filteredCreate = <PointAnnotationOptions>[];
        final filteredPlaces = <Place>[];
        for (final idx in keepIdx) {
          filteredCreate.add(toCreate[idx]);
          filteredPlaces.add(placesForCreatedAnnotations[idx]);
        }
        toCreate
          ..clear()
          ..addAll(filteredCreate);
        placesForCreatedAnnotations
          ..clear()
          ..addAll(filteredPlaces);
      }
    }

    if (toCreate.isNotEmpty) {
      try {
        final created = await _pointAnnotationManager!.createMulti(toCreate);
        for (int i = 0; i < created.length; i++) {
          final ann = created[i];
          final place = placesForCreatedAnnotations[i];
          if (ann != null) {
            _placeIdToAnnotation[place.id] = ann;
            _annotationIdToPlace[ann.id] = place;
          }
        }
      } catch (e) {
        if (kDebugMode) print("ℹ️ MapScreen: createMulti error: $e");
      }
    }

    _placeSunState
      ..clear()
      ..addAll(newSunState);
    _iconScaleBucket = newBucket;
  }

  // ------------------ UI ------------------
  @override
  Widget build(BuildContext context) {
    super.build(context);
    final mapState = context.watch<MapState>();
    final selectedPlace = mapState.selectedPlace;
    final selectedDateTime = mapState.selectedDateTime;
    final bool isLoadingData = mapState.isLoadingBuildings || mapState.isLoadingPlaces;

    if (selectedPlace != null && mapState.shouldFlyToSelectedPlace) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _mapboxMap != null) {
          _moveCameraTo(selectedPlace.location, zoom: 16.5);
          Provider.of<MapState>(context, listen: false).notifyPlaceFlyToHandled();
        }
      });
    }

    double sunArrowRotation = math.pi;
    double sunArrowOpacity = 0.3;
    if (_lastCameraState != null) {
      final sunPos = SunUtils.getSunPosition(
        selectedDateTime,
        _lastCameraState!.center.coordinates.lat.toDouble(),
        _lastCameraState!.center.coordinates.lng.toDouble(),
      );
      final double altitudeRad = sunPos['altitude']!;
      final double azimuth_N_CW_rad = sunPos['azimuth']!;
      if (altitudeRad > SunUtils.altitudeThresholdRad) {
        sunArrowOpacity = 0.9;
        sunArrowRotation = azimuth_N_CW_rad;
      }
    }

    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Scaffold(
      body: Stack(
        children: [
          MapWidget(
            key: const ValueKey("mapWidget"),
            styleUri: MapboxStyles.OUTDOORS,
            textureView: true,
            onMapCreated: _onMapCreated,
            onMapLoadedListener: _onMapLoaded,
            onMapIdleListener: _onCameraIdle,
          ),

          // Loading indicator
          Positioned(
            top: 10, left: 10,
            child: SafeArea(
              child: AnimatedOpacity(
                opacity: isLoadingData ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 300),
                child: IgnorePointer(
                  ignoring: !isLoadingData,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: colors.surface.withOpacity(0.9),
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: kElevationToShadow[2],
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(colors.primary),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        isLoadingData
                            ? (mapState.isLoadingBuildings && mapState.isLoadingPlaces
                            ? "Loading map data..."
                            : mapState.isLoadingBuildings
                            ? "Loading buildings..."
                            : "Loading places...")
                            : "Map Ready",
                        style: TextStyle(color: colors.onSurface),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          ),

          // Sun direction arrow
          Positioned(
            top: 20, right: 20,
            child: SafeArea(
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: colors.surface.withOpacity(0.7),
                  shape: BoxShape.circle,
                  boxShadow: kElevationToShadow[1],
                ),
                child: Transform.rotate(
                  angle: sunArrowRotation,
                  child: Icon(
                    Icons.navigation_rounded,
                    size: 32,
                    color: Colors.orange.withOpacity(sunArrowOpacity),
                    shadows: sunArrowOpacity > 0.5
                        ? const [Shadow(color: Colors.black38, blurRadius: 3.0, offset: Offset(1,1))]
                        : null,
                  ),
                ),
              ),
            ),
          ),

          // City filter chip (under the arrow)
          Positioned(
            top: 68, right: 16,
            child: SafeArea(
              child: _CityFilterChip(
                selected: _selectedCity?.name ?? 'City',
                onPick: (city) => _goToCity(city),
              ),
            ),
          ),

          // Current Date/Time
          Positioned(
            bottom: 15, left: 0, right: 0,
            child: IgnorePointer(
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
                  decoration: BoxDecoration(
                    color: colors.surface.withOpacity(0.9),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: kElevationToShadow[2],
                  ),
                  child: Text(
                    DateFormat.yMMMMEEEEd(Localizations.localeOf(context).toString())
                        .add_Hm()
                        .format(selectedDateTime),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                      color: colors.onSurface,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showPlaceDialog(Place place) {
    if (!mounted) return;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final mapState = Provider.of<MapState>(context, listen: false);
    final dt = mapState.selectedDateTime;
    final lat = place.location.coordinates.lat.toDouble();
    final lng = place.location.coordinates.lng.toDouble();
    final sun = SunUtils.getSunPosition(dt, lat, lng);
    final altDeg = (sun['altitude']! * SunUtils.deg);
    final azDeg  = (sun['azimuth']! * SunUtils.deg);

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: colors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16.0)),
        title: Text(place.name, style: TextStyle(color: colors.onSurface, fontWeight: FontWeight.bold)),
        contentPadding: const EdgeInsets.fromLTRB(24.0, 20.0, 24.0, 10.0),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Type: ${place.type.name.toUpperCase()}",
                  style: theme.textTheme.labelLarge?.copyWith(color: colors.onSurfaceVariant)),
              const SizedBox(height: 8),
              Text(
                "Coordinates: (${place.location.coordinates.lat.toStringAsFixed(5)}, ${place.location.coordinates.lng.toStringAsFixed(5)})",
                style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              Text(
                "Sun now: ${altDeg.toStringAsFixed(1)}° alt · ${azDeg.toStringAsFixed(0)}° az",
                style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
              ),
              if (kDebugMode) ...[
                const SizedBox(height: 4),
                Text("ID: ${place.id}",
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant.withOpacity(0.7), fontSize: 10)),
              ],
              const SizedBox(height: 20),
              Text("Open in Maps for navigation?",
                  style: theme.textTheme.bodyMedium?.copyWith(color: colors.onSurface)),
            ],
          ),
        ),
        actionsPadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text("Close", style: TextStyle(color: colors.secondary)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              _launchNavigation(place);
            },
            child: Text("Navigate", style: TextStyle(color: colors.primary, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _launchNavigation(Place place) async {
    final lat = place.location.coordinates.lat;
    final lng = place.location.coordinates.lng;
    final encodedName = Uri.encodeComponent(place.name);

    final uris = <Uri>[];
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      uris.add(Uri.parse("maps://?q=$encodedName&ll=$lat,$lng&z=16"));
      uris.add(Uri.parse("comgooglemaps://?q=$encodedName&center=$lat,$lng&zoom=16"));
    } else if (defaultTargetPlatform == TargetPlatform.android) {
      uris.add(Uri.parse("google.navigation:q=$lat,$lng&mode=d"));
      uris.add(Uri.parse("geo:$lat,$lng?q=$lat,$lng($encodedName)"));
    }
    uris.add(Uri.parse("https://www.google.com/maps/search/?api=1&query=$lat,$lng"));
    uris.add(Uri.parse("https://www.google.com/maps/@?api=1&map_action=map&center=$lat,$lng&zoom=16"));
    uris.add(Uri.parse("https://maps.apple.com/?q=$encodedName&ll=$lat,$lng&z=16"));

    for (final uri in uris) {
      try {
        if (await canLaunchUrl(uri) && await launchUrl(uri, mode: LaunchMode.externalApplication)) {
          return;
        }
      } catch (_) {}
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Text("Could not launch any map application."),
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.all(10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }
}

class AnnotationClickListener extends OnPointAnnotationClickListener {
  final Function(PointAnnotation) onAnnotationClick;
  AnnotationClickListener({required this.onAnnotationClick});
  @override
  void onPointAnnotationClick(PointAnnotation annotation) {
    onAnnotationClick(annotation);
  }
}

// --------- UI piece for the city filter ---------

class _CityFilterChip extends StatelessWidget {
  final String selected;
  final ValueChanged<City> onPick;

  const _CityFilterChip({
    required this.selected,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: colors.surface.withOpacity(0.9),
        borderRadius: BorderRadius.circular(24),
        boxShadow: kElevationToShadow[2],
      ),
      child: PopupMenuButton<City>(
        tooltip: 'Pick a city',
        onSelected: onPick,
        itemBuilder: (ctx) {
          return slovenianCities
              .map((c) => PopupMenuItem<City>(
            value: c,
            child: Text(c.name),
          ))
              .toList();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.location_city_rounded, size: 18),
              const SizedBox(width: 8),
              Text(selected, style: TextStyle(color: colors.onSurface)),
              const SizedBox(width: 4),
              const Icon(Icons.arrow_drop_down),
            ],
          ),
        ),
      ),
    );
  }
}
