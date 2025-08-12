// lib/screens/map_screen.dart
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

// Cities
import '../models/city.dart';
import '../data/slovenia_cities.dart';
import '../data/croatia_cities.dart';
import '../data/serbia_cities.dart';

// Terrain horizon (optional)
import '../services/terrain_elevation_service.dart';

enum Country { si, hr, rs }
enum AppLang { en, sl, hr, sr }

extension AppLangX on AppLang {
  String get code => switch (this) { AppLang.en => 'en', AppLang.sl => 'sl', AppLang.hr => 'hr', AppLang.sr => 'sr' };
}

/// Tiny localizer for the few strings used on this screen
class Strs {
  final AppLang lang;
  Strs(this.lang);

  String get mapReady => switch (lang) {
    AppLang.sl => 'Zemljevid pripravljen',
    AppLang.hr => 'Karta spremna',
    AppLang.sr => 'Mapa spremna',
    _ => 'Map ready',
  };

  String get loadingMapData => switch (lang) {
    AppLang.sl => 'Nalaganje podatkov zemljevida...',
    AppLang.hr => 'Učitavanje podataka karte...',
    AppLang.sr => 'Učitavanje podataka mape...',
    _ => 'Loading map data...',
  };

  String get loadingBuildings => switch (lang) {
    AppLang.sl => 'Nalaganje stavb...',
    AppLang.hr => 'Učitavanje zgrada...',
    AppLang.sr => 'Učitavanje zgrada...',
    _ => 'Loading buildings...',
  };

  String get loadingPlaces => switch (lang) {
    AppLang.sl => 'Nalaganje mest...',
    AppLang.hr => 'Učitavanje mjesta...',
    AppLang.sr => 'Učitavanje mesta...',
    _ => 'Loading places...',
  };

  String get pickCity => switch (lang) {
    AppLang.sl => 'Izberi mesto',
    AppLang.hr => 'Odaberi grad',
    AppLang.sr => 'Izaberi grad',
    _ => 'Pick a city',
  };

  String get cityLabel => switch (lang) {
    AppLang.sl => 'Mesto',
    AppLang.hr => 'Grad',
    AppLang.sr => 'Grad',
    _ => 'City',
  };

  String get close => switch (lang) {
    AppLang.sl => 'Zapri',
    AppLang.hr => 'Zatvori',
    AppLang.sr => 'Zatvori',
    _ => 'Close',
  };

  String get navigate => switch (lang) {
    AppLang.sl => 'Navigiraj',
    AppLang.hr => 'Navigiraj',
    AppLang.sr => 'Navigacija',
    _ => 'Navigate',
  };

  String get cafes => switch (lang) {
    AppLang.sl => 'Kavarne',
    AppLang.hr => 'Kafići',
    AppLang.sr => 'Kafići',
    _ => 'Cafés',
  };

  String get pubs => switch (lang) {
    AppLang.sl => 'Pivnice',
    AppLang.hr => 'Pivnice',
    AppLang.sr => 'Pivnice',
    _ => 'Pubs',
  };

  String get parks => switch (lang) {
    AppLang.sl => 'Parki',
    AppLang.hr => 'Parkovi',
    AppLang.sr => 'Parkovi',
    _ => 'Parks',
  };
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});
  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with AutomaticKeepAliveClientMixin {
  MapboxMap? _mapboxMap;
  PointAnnotationManager? _pointAnnotationManager;
  PolygonAnnotationManager? _polygonManager;

  final Map<String, Uint8List> _placeIconImages = {};
  bool _iconsLoaded = false;

  Timer? _mapIdleTimer;
  CameraState? _lastCameraState;
  CameraState? _previousIdleCameraState;
  bool _mapReady = false;

  final Map<String, Place> _annotationIdToPlace = {};
  final Map<String, PointAnnotation> _placeIdToAnnotation = {};
  final Map<String, bool> _placeSunState = {};
  String _iconScaleBucket = "";

  DateTime? _lastDrawTime;
  bool _isRedrawing = false;

  // Sticky icons & budget (perf tuned)
  static const double _markerPadMeters = 320.0;
  static const int _kMaxAnnotations = 1000;

  // Country / language / city
  Country _country = Country.si;
  AppLang _lang = AppLang.sl;
  City? _selectedCity;

  // Terrain horizon (optional)
  TerrainElevationService? _elevService;
  final bool _useTerrainHorizon = true;
  final double _horizonMarginDeg = 0.5;
  final Map<String, double> _horizonCache = {};

  // Redraw when MapState updates its data
  Timer? _stateRedrawTimer;
  MapState? _mapStateRef;
  VoidCallback? _mapStateListener;

  // Filters (parks off by default)
  final Set<PlaceType> _enabledTypes = {PlaceType.cafe, PlaceType.pub};
  bool _filterOpen = false;

  // Shadow reuse cache
  double? _prevAltRad, _prevAzRad;
  CoordinateBounds? _prevShadowBounds;
  List<Building>? _prevShadowBuildingsRef;
  Map<String, List<Position>> _cachedShadows = {};

  @override
  bool get wantKeepAlive => true;

  List<City> get _citiesForCountry => switch (_country) {
    Country.si => slovenianCities,
    Country.hr => croatianCities,
    Country.rs => serbianCities,
  };

  void _setCountry(Country c, {bool alsoSetLanguage = true}) {
    setState(() {
      _country = c;
      if (alsoSetLanguage) {
        _lang = switch (c) { Country.si => AppLang.sl, Country.hr => AppLang.hr, Country.rs => AppLang.sr };
      }
    });
  }

  void _setLanguage(AppLang l) => setState(() => _lang = l);

  // Normalize angle to [-π, π]
  double _wrapAngle(double x) {
    const twoPi = 2 * math.pi;
    x = (x + math.pi) % twoPi;
    if (x < 0) x += twoPi;
    return x - math.pi;
  }

  bool _boundsClose(CoordinateBounds a, CoordinateBounds b, {double tol = 0.0008}) {
    final aSW = a.southwest.coordinates, aNE = a.northeast.coordinates;
    final bSW = b.southwest.coordinates, bNE = b.northeast.coordinates;
    return ((aSW.lat - bSW.lat).abs() < tol &&
        (aSW.lng - bSW.lng).abs() < tol &&
        (aNE.lat - bNE.lat).abs() < tol &&
        (aNE.lng - bNE.lng).abs() < tol);
  }

  @override
  void initState() {
    super.initState();
    _loadIconImages();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    _elevService ??= _tryGetTerrainService(context);

    // Listen for MapState changes and redraw lightly
    final ms = Provider.of<MapState>(context, listen: false);
    if (_mapStateRef != ms) {
      if (_mapStateRef != null && _mapStateListener != null) {
        _mapStateRef!.removeListener(_mapStateListener!);
      }
      _mapStateRef = ms;
      _mapStateListener = () {
        _stateRedrawTimer?.cancel();
        _stateRedrawTimer = Timer(const Duration(milliseconds: 60), () {
          if (mounted && _mapReady && !_isRedrawing && _iconsLoaded) {
            _tryRedraw("mapState listener");
          }
        });
      };
      _mapStateRef!.addListener(_mapStateListener!);
    }

    // Time-change redraw
    final mapState = context.watch<MapState>();
    final currentTime = mapState.selectedDateTime;
    if (_mapReady && !_isRedrawing && (_lastDrawTime == null || !_lastDrawTime!.isAtSameMomentAs(currentTime))) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_isRedrawing) _tryRedraw("time change");
      });
    }
  }

  TerrainElevationService? _tryGetTerrainService(BuildContext context) {
    try {
      return Provider.of<TerrainElevationService>(context, listen: false);
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _mapIdleTimer?.cancel();
    _stateRedrawTimer?.cancel();
    if (_mapStateRef != null && _mapStateListener != null) {
      _mapStateRef!.removeListener(_mapStateListener!);
    }

    _pointAnnotationManager = null;
    _polygonManager = null;
    _mapboxMap = null;

    _placeIconImages.clear();
    _annotationIdToPlace.clear();
    _placeIdToAnnotation.clear();
    _placeSunState.clear();
    _horizonCache.clear();

    _cachedShadows.clear();
    super.dispose();
  }

  Future<void> _loadIconImages() async {
    final iconPaths = {
      "cafe_sun": "assets/icons/cafe_sun.png",
      "cafe_moon": "assets/icons/cafe_moon.png",
      "pub_sun": "assets/icons/pub_sun.png",
      "pub_moon": "assets/icons/pub_moon.png",
      "park_sun": "assets/icons/park_sun.png",
      "park_moon": "assets/icons/park_moon.png",
      "default_sun": "assets/icons/default_sun.png",
      "default_moon": "assets/icons/default_moon.png",
    };
    final futures = iconPaths.entries.map((entry) async {
      try {
        final byteData = await rootBundle.load(entry.value);
        return MapEntry(entry.key, byteData.buffer.asUint8List());
      } catch (_) {
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
    final initialCenter =
        mapState.selectedPlace?.location ?? Point(coordinates: Position(14.3310, 46.3895)); // Tržič approx.
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
      if (kDebugMode) print("❌ MapScreen: setup error: $e");
    }
  }

  void _onMapLoaded(MapLoadedEventData event) {
    if (!mounted) return;
    _mapReady = true;

    _placeIdToAnnotation.clear();
    _placeSunState.clear();
    _annotationIdToPlace.clear();
    _iconScaleBucket = "";
    _cachedShadows.clear();
    _prevAltRad = _prevAzRad = null;
    _prevShadowBounds = null;
    _prevShadowBuildingsRef = null;

    _updateLastCameraState().then((_) {
      if (!mounted || _lastCameraState == null) return;
      _previousIdleCameraState = _lastCameraState;
      _triggerDataFetch();
      _tryRedraw("map loaded");
    });
  }

  void _onCameraIdle(MapIdleEventData event) {
    if (!mounted || !_mapReady) return;
    _mapIdleTimer?.cancel();
    _mapIdleTimer = Timer(const Duration(milliseconds: 500), () async {
      if (!mounted || !_mapReady || _isRedrawing) return;

      final start = _previousIdleCameraState;
      await _updateLastCameraState();
      if (!mounted || _lastCameraState == null) return;

      bool fetch = true, redraw = true;
      if (start != null) {
        const dataPosTol = 0.00005;
        const dataZoomTol = 0.05;
        const arrowPosTol = 0.0001;

        final movedData =
            (start.center.coordinates.lat - _lastCameraState!.center.coordinates.lat).abs() > dataPosTol ||
                (start.center.coordinates.lng - _lastCameraState!.center.coordinates.lng).abs() > dataPosTol;
        final zoomData = (start.zoom - _lastCameraState!.zoom).abs() > dataZoomTol;
        if (!movedData && !zoomData) fetch = false;

        final movedArrow =
            (start.center.coordinates.lat - _lastCameraState!.center.coordinates.lat).abs() > arrowPosTol ||
                (start.center.coordinates.lng - _lastCameraState!.center.coordinates.lng).abs() > arrowPosTol;
        if (!movedArrow && !zoomData) redraw = false;
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
    } catch (_) {
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
    } catch (_) {}
  }

  void _moveCameraTo(Point center, {required double zoom}) {
    if (!mounted || _mapboxMap == null) return;
    _mapboxMap!.flyTo(
      CameraOptions(center: center, zoom: zoom, pitch: 15.0),
      MapAnimationOptions(duration: 1500, startDelay: 100),
    );
  }

  // ---------- City jump ----------
  void _goToCity(City city) async {
    final mapState = Provider.of<MapState>(context, listen: false);

    mapState.clearAllAccumulatedBuildingData();
    mapState.clearAllAccumulatedPlaceData();

    setState(() => _selectedCity = city);

    final targetCenter = Point(coordinates: Position(city.lng, city.lat));
    final targetCam = CameraOptions(center: targetCenter, zoom: city.zoom, pitch: 15.0);

    try {
      if (_mapboxMap != null) {
        final targetBounds = await _mapboxMap!.coordinateBoundsForCamera(targetCam);
        mapState.fetchBuildingsForView(targetBounds, city.zoom);
        mapState.fetchPlacesForView(targetBounds, city.zoom);
      }
    } catch (_) {}

    _moveCameraTo(targetCenter, zoom: city.zoom);

    Future.delayed(const Duration(milliseconds: 1700), () async {
      if (!mounted) return;
      await _updateLastCameraState();
      _tryRedraw("city change → ${city.name}");
    });
  }

  // ---------- Helpers ----------
  bool _checkAabbIntersection(CoordinateBounds b1, CoordinateBounds b2) {
    if (b1.northeast.coordinates.lng < b2.southwest.coordinates.lng ||
        b2.northeast.coordinates.lng < b1.southwest.coordinates.lng) return false;
    if (b1.northeast.coordinates.lat < b2.southwest.coordinates.lat ||
        b2.northeast.coordinates.lat < b1.southwest.coordinates.lat) return false;
    return true;
  }

  bool _isPointInBounds(Position p, CoordinateBounds b, {bool inclusive = true}) {
    final lat = p.lat.toDouble(), lng = p.lng.toDouble();
    final minLat = b.southwest.coordinates.lat.toDouble();
    final maxLat = b.northeast.coordinates.lat.toDouble();
    final minLng = b.southwest.coordinates.lng.toDouble();
    final maxLng = b.northeast.coordinates.lng.toDouble();
    if (inclusive) return lat >= minLat && lat <= maxLat && lng >= minLng && lng <= maxLng;
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

  // ---------- Redraw ----------
  Future<void> _tryRedraw(String source) async {
    if (_isRedrawing) return;
    if (!mounted ||
        _mapboxMap == null ||
        !_mapReady ||
        !_iconsLoaded ||
        _polygonManager == null ||
        _pointAnnotationManager == null ||
        _lastCameraState == null) {
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

      final shadowLogic = await _calculateAndMaybeReuseBuildingShadows(buildings, dateTime, bounds);
      await _drawPlaces(places, buildings, dateTime, shadowLogic, bounds);
    } catch (e, s) {
      if (kDebugMode) print("❌ Redraw error: $e\n$s");
    } finally {
      _isRedrawing = false;
    }
  }

  Future<Map<String, List<Position>>> _calculateAndMaybeReuseBuildingShadows(
      List<Building> allLoadedBuildings,
      DateTime dateTime,
      CoordinateBounds currentViewportBounds,
      ) async {
    if (!mounted || _polygonManager == null || _lastCameraState == null) return {};

    final center = _lastCameraState!.center.coordinates;
    final sunPos = SunUtils.getSunPosition(
      dateTime,
      center.lat.toDouble(),
      center.lng.toDouble(),
    );
    final alt = sunPos['altitude']!;
    final az = sunPos['azimuth']!;

    if (alt <= SunUtils.altitudeThresholdRad) {
      if (_cachedShadows.isNotEmpty) {
        try {
          await _polygonManager!.deleteAll();
        } catch (_) {}
        _cachedShadows.clear();
      }
      _prevAltRad = alt;
      _prevAzRad = az;
      _prevShadowBounds = currentViewportBounds;
      _prevShadowBuildingsRef = allLoadedBuildings;
      return {};
    }

    const double altTol = 0.010; // ~0.57°
    const double azTol = 0.035; // ~2°
    final canReuse = _cachedShadows.isNotEmpty &&
        _prevAltRad != null &&
        _prevAzRad != null &&
        (alt - _prevAltRad!).abs() < altTol &&
        (_wrapAngle(az - _prevAzRad!)).abs() < azTol &&
        _prevShadowBounds != null &&
        _boundsClose(_prevShadowBounds!, currentViewportBounds) &&
        identical(_prevShadowBuildingsRef, allLoadedBuildings);

    if (canReuse) {
      return _cachedShadows;
    }

    try {
      await _polygonManager!.deleteAll();
    } catch (_) {}

    final calculated = <String, List<Position>>{};
    final draw = <PolygonAnnotationOptions>[];

    // Opacity curve
    final altDeg = alt * SunUtils.deg;
    const double maxShadowOpacity = 0.20;
    const double horizonFadeEndAlt = SunUtils.altitudeThresholdRad * SunUtils.deg + 0.5;
    const double horizonFadeStartAlt = 5.0;
    const double peakOpacityStartAlt = 18.0;
    const double peakOpacityEndAlt = 62.0;
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
      _cachedShadows.clear();
      _prevAltRad = alt;
      _prevAzRad = az;
      _prevShadowBounds = currentViewportBounds;
      _prevShadowBuildingsRef = allLoadedBuildings;
      return calculated;
    }

    final zoom = _lastCameraState!.zoom;
    final centerLat = center.lat.toDouble();
    final mpp = SunUtils.metersPerPixel(centerLat, zoom);
    final minShadowMeters = math.max(0.5, mpp * 1.2);

    final sw = currentViewportBounds.southwest.coordinates;
    final ne = currentViewportBounds.northeast.coordinates;
    double _toCol(double lng) => ((lng - sw.lng) / (ne.lng - sw.lng + 1e-12)).clamp(0.0, 0.9999);
    double _toRow(double lat) => ((lat - sw.lat) / (ne.lat - sw.lat + 1e-12)).clamp(0.0, 0.9999);
    const int gridN = 24; // smaller grid to reduce attenuation cost
    final density = List.generate(gridN, (_) => List.filled(gridN, 0));
    const baseShadowColor = Color(0xFF1A1A1A);

    for (final b in allLoadedBuildings) {
      if (!_checkAabbIntersection(b.bounds, currentViewportBounds)) {
        calculated[b.id] = [];
        continue;
      }

      final poly = SunUtils.calculateBuildingShadow(
        building: b,
        sunAzimuth_N_CW_rad: az,
        sunAltitudeRad: alt,
        minDrawableShadowMeters: minShadowMeters,
      );
      calculated[b.id] = poly.isNotEmpty ? List<Position>.from(poly) : [];
      if (poly.length < 3) continue;

      // overlap attenuation
      double cLat = 0, cLng = 0;
      for (final p in poly) {
        cLat += p.lat.toDouble();
        cLng += p.lng.toDouble();
      }
      cLat /= poly.length;
      cLng /= poly.length;
      final col = (_toCol(cLng) * gridN).floor().clamp(0, gridN - 1);
      final row = (_toRow(cLat) * gridN).floor().clamp(0, gridN - 1);
      final seen = density[row][col];

      final overlapFactor = 1.0 / (1.0 + seen);
      final op = (baseOpacity * overlapFactor).clamp(0.03, 0.15);

      List<Position> hole = [];
      if (b.polygon.isNotEmpty) {
        final fp = List<Position>.from(b.polygon);
        if (fp.first.lat != fp.last.lat || fp.first.lng != fp.last.lng) fp.add(fp.first);
        if (fp.length >= 4) hole = List<Position>.from(fp.reversed);
      }

      final rings = <List<Position>>[poly];
      if (hole.isNotEmpty) rings.add(hole);

      draw.add(PolygonAnnotationOptions(
        geometry: Polygon(coordinates: rings),
        fillColor: baseShadowColor.withOpacity(op).value,
        fillOutlineColor: Colors.transparent.value,
        fillSortKey: 0,
      ));

      density[row][col] = seen + 1;
    }

    if (draw.isNotEmpty) {
      try {
        await _polygonManager!.createMulti(draw);
      } catch (_) {}
    }

    _cachedShadows = calculated;
    _prevAltRad = alt;
    _prevAzRad = az;
    _prevShadowBounds = currentViewportBounds;
    _prevShadowBuildingsRef = allLoadedBuildings;

    return calculated;
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

    // pre-filter buildings by viewport once
    final relevantBuildings =
    allLoadedBuildings.where((b) => _checkAabbIntersection(b.bounds, paddedBounds)).toList();

    final visiblePlaceIds = <String>{};
    final visiblePlaces = <Place>[];
    final rawSunState = <String, bool>{};

    // Horizon sampling budget heuristic
    final heavyLoadThreshold = 600;
    int horizonBudget = 10;

    for (final place in allLoadedPlaces) {
      // type filter first (cheap)
      if (!_enabledTypes.contains(place.type)) continue;

      final pos = place.location.coordinates;
      if (!_isPointInBounds(pos, paddedBounds, inclusive: true)) continue;

      visiblePlaceIds.add(place.id);
      visiblePlaces.add(place);

      final lat = pos.lat.toDouble();
      final lng = pos.lng.toDouble();

      final sun = SunUtils.getSunPosition(dateTime, lat, lng);
      final altRad = sun['altitude']!;
      final azRad = sun['azimuth']!;

      bool isEffectiveSun = false;

      if (altRad > SunUtils.altitudeThresholdRad) {
        bool terrainBlocks = false;
        if (_useTerrainHorizon && _elevService != null) {
          if (visiblePlaces.length > heavyLoadThreshold) {
            // skip terrain horizon checks if already very heavy
          } else if (horizonBudget > 0) {
            final key = _hKey(lat, lng, azRad);
            double? hor = _horizonCache[key];
            if (hor == null) {
              try {
                hor = await SunUtils.horizonAngleRad(
                  lat,
                  lng,
                  azRad,
                  sampleElevationM: _elevService!.sampleElevationM,
                );
                _horizonCache[key] = hor;
                horizonBudget--;
              } catch (_) {}
            }
            if (hor != null) {
              final margin = _horizonMarginDeg * SunUtils.rad;
              if (altRad < hor + margin) terrainBlocks = true;
            }
          }
        }

        if (!terrainBlocks) {
          String? hostId;
          for (final b in relevantBuildings) {
            if (b.polygon.length >= 3 && SunUtils.isPointInPolygon(pos, b.polygon)) {
              hostId = b.id;
              break;
            }
          }

          final blocked = SunUtils.isPlaceInShadow(
            placePosition: pos,
            sunAzimuth_N_CW_rad: azRad,
            sunAltitudeRad: altRad,
            potentialBlockers: relevantBuildings,
            buildingShadows: calculatedShadowsForLogic,
            ignoreBuildingId: hostId,
          );
          isEffectiveSun = !blocked;

          if (isEffectiveSun) {
            int shadowedNeighbors = 0;
            const d = 2.5; // meters
            const need = 3;

            final dLat = SunUtils.metersToLat(d);
            final dLng = SunUtils.metersToLng(d, lat);
            final probes = <Position>[
              Position(lng, lat + dLat),
              Position(lng + dLng, lat),
              Position(lng, lat - dLat),
              Position(lng - dLng, lat),
            ];
            for (final p in probes) {
              final neighborBlocked = SunUtils.isPlaceInShadow(
                placePosition: p,
                sunAzimuth_N_CW_rad: azRad,
                sunAltitudeRad: altRad,
                potentialBlockers: relevantBuildings,
                buildingShadows: calculatedShadowsForLogic,
                ignoreBuildingId: null,
                checkRadiusMeters: 0.25,
                insideHostBuildingCheckRadiusMeters: 0.25,
              );
              if (neighborBlocked) shadowedNeighbors++;
            }
            if (shadowedNeighbors >= need) isEffectiveSun = false;
          }
        } else {
          isEffectiveSun = false;
        }
      } else {
        isEffectiveSun = false;
      }

      rawSunState[place.id] = isEffectiveSun;
    }

    // Smooth close-by same-type icons for visual consistency
    final smoothed = SunUtils.smoothIconStatesByLocalConsensus(
      places: visiblePlaces,
      initialSunState: rawSunState,
      radiusMeters: 10.0,
      minNeighbors: 1,
      requiredFraction: 0.66,
    );

    // 1) remove annotations now outside padded viewport or filtered out
    final toDelete = <PointAnnotation>[];
    final toDeletePlaceIds = <String>[];

    for (final entry in _placeIdToAnnotation.entries.toList()) {
      final pid = entry.key;
      final ann = entry.value;
      final pt = ann.geometry.coordinates;

      final placeForAnn = _annotationIdToPlace[ann.id];
      final wasFilteredOut = placeForAnn == null || !_enabledTypes.contains(placeForAnn.type);
      if (!visiblePlaceIds.contains(pid) || !_isPointInBounds(pt, paddedBounds, inclusive: true) || wasFilteredOut) {
        toDelete.add(ann);
        toDeletePlaceIds.add(pid);
      }
    }

    // 2) remove + recreate if sun state or scale changed
    for (final place in visiblePlaces) {
      final newInSun = smoothed[place.id] ?? false;
      final had = _placeIdToAnnotation.containsKey(place.id);
      final bucketChanged = (_iconScaleBucket != newBucket);
      final sunChanged = (_placeSunState[place.id] != newInSun);
      if (had && (bucketChanged || sunChanged)) {
        final existing = _placeIdToAnnotation[place.id];
        if (existing != null) {
          toDelete.add(existing);
          toDeletePlaceIds.add(place.id);
        }
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
      } catch (_) {}
    }

    // 3) create new/updated annotations
    final toCreate = <PointAnnotationOptions>[];
    final placesForCreated = <Place>[];

    for (final place in visiblePlaces) {
      final newInSun = smoothed[place.id] ?? false;

      final needCreate = !_placeIdToAnnotation.containsKey(place.id) ||
          (_placeSunState[place.id] != newInSun) ||
          (_iconScaleBucket != newBucket);

      if (!needCreate) continue;

      final iconKey = SunUtils.getIconPath(place.type, newInSun);
      final bytes = _placeIconImages[iconKey];
      if (bytes == null || bytes.isEmpty) continue;

      toCreate.add(PointAnnotationOptions(
        geometry: place.location,
        image: bytes,
        iconSize: iconScale,
        iconAnchor: IconAnchor.BOTTOM,
        iconOffset: [0.0, -2.0 * iconScale],
        symbolSortKey: 10,
      ));
      placesForCreated.add(place);
    }

    // Cap + thin
    if (toCreate.isNotEmpty) {
      final existingCount = _placeIdToAnnotation.length;
      final budget = (_kMaxAnnotations - existingCount).clamp(0, _kMaxAnnotations);
      if (budget <= 0) {
        toCreate.clear();
        placesForCreated.clear();
      } else if (toCreate.length > budget) {
        final keepIdx = _thinByGrid(toCreate, budget);
        final filteredOpts = <PointAnnotationOptions>[];
        final filteredPlaces = <Place>[];
        for (final i in keepIdx) {
          filteredOpts.add(toCreate[i]);
          filteredPlaces.add(placesForCreated[i]);
        }
        toCreate
          ..clear()
          ..addAll(filteredOpts);
        placesForCreated
          ..clear()
          ..addAll(filteredPlaces);
      }
    }

    if (toCreate.isNotEmpty) {
      for (int i = 0; i < toCreate.length; i++) {
        try {
          final ann = await _pointAnnotationManager!.create(toCreate[i]);
          final place = placesForCreated[i];
          if (ann != null) {
            _placeIdToAnnotation[place.id] = ann;
            _annotationIdToPlace[ann.id] = place;
          }
        } catch (_) {}
      }
    }

    _placeSunState
      ..clear()
      ..addAll(smoothed);
    _iconScaleBucket = newBucket;
  }

  // Terrain-horizon cache key: quantize lat/lng + 10° azimuth bucket
  String _hKey(double lat, double lng, double azRad) {
    final sector = ((azRad * SunUtils.deg) / 10.0).round() * 10; // 10°
    final qLat = (lat * 200).round() / 200.0; // ~0.005°
    final qLng = (lng * 200).round() / 200.0;
    return "$qLat,$qLng,$sector";
  }

  List<int> _thinByGrid(List<PointAnnotationOptions> opts, int targetCount) {
    if (opts.length <= targetCount) {
      return List<int>.generate(opts.length, (i) => i);
    }

    const int grid = 32;
    final chosen = <int>{};
    final firstInCell = <int, int>{};

    double _norm(double v, double a, double b) => ((v - a) / (b - a + 1e-12)).clamp(0.0, 0.9999);

    double minLat = double.infinity, maxLat = -double.infinity;
    double minLng = double.infinity, maxLng = -double.infinity;
    for (final o in opts) {
      final p = (o.geometry as Point).coordinates;
      minLat = math.min(minLat, p.lat.toDouble());
      maxLat = math.max(maxLat, p.lat.toDouble());
      minLng = math.min(minLng, p.lng.toDouble());
      maxLng = math.max(maxLng, p.lng.toDouble());
    }

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

  // ---------- UI ----------
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
    final strs = Strs(_lang);

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
            top: 10,
            left: 10,
            child: SafeArea(
              child: AnimatedOpacity(
                opacity: isLoadingData ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 300),
                child: IgnorePointer(
                  ignoring: !isLoadingData,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: colors.surface.withOpacity(0.95),
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: kElevationToShadow[2],
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(colors.primary),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        isLoadingData
                            ? (mapState.isLoadingBuildings && mapState.isLoadingPlaces
                            ? strs.loadingMapData
                            : mapState.isLoadingBuildings
                            ? strs.loadingBuildings
                            : strs.loadingPlaces)
                            : strs.mapReady,
                        style: TextStyle(color: colors.onSurface),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          ),

          // Sun direction arrow (top-right)
          Positioned(
            top: 20,
            right: 20,
            child: SafeArea(
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: colors.surface.withOpacity(0.75),
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
                        ? const [Shadow(color: Colors.black38, blurRadius: 3.0, offset: Offset(1, 1))]
                        : null,
                  ),
                ),
              ),
            ),
          ),

          // Country & language bar + City filter (top-right)
          Positioned(
            top: 68,
            right: 16,
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _CountryLangBar(
                    country: _country,
                    lang: _lang,
                    onCountryTap: (c) => _setCountry(c),
                    onEnglishTap: () => _setLanguage(AppLang.en),
                  ),
                  const SizedBox(height: 8),
                  _CityFilterChip(
                    selected: _selectedCity?.name ?? strs.cityLabel,
                    cities: _citiesForCountry,
                    label: strs.pickCity,
                    onPick: (city) => _goToCity(city),
                  ),
                ],
              ),
            ),
          ),

          // --- Filter button + dropdown (top-left) ---
          if (_filterOpen)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => setState(() => _filterOpen = false),
                child: const SizedBox.expand(),
              ),
            ),

          Positioned(
            top: 68,
            left: 16,
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _FilterToggleButton(
                    isOpen: _filterOpen,
                    activeCount: _enabledTypes.length,
                    onTap: () => setState(() => _filterOpen = !_filterOpen),
                  ),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    transitionBuilder: (child, anim) =>
                        SizeTransition(sizeFactor: anim, axisAlignment: -1.0, child: child),
                    child: _filterOpen
                        ? Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 300),
                        child: _TypeFilterDropdown(
                          strs: strs,
                          enabled: _enabledTypes,
                          onToggle: (t) {
                            setState(() {
                              if (_enabledTypes.contains(t)) {
                                _enabledTypes.remove(t);
                              } else {
                                _enabledTypes.add(t);
                              }
                            });
                            _tryRedraw("type filter change");
                          },
                        ),
                      ),
                    )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ),

          // Current Date/Time
          Positioned(
            bottom: 15,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
                  decoration: BoxDecoration(
                    color: colors.surface.withOpacity(0.95),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: kElevationToShadow[2],
                  ),
                  child: Text(
                    DateFormat.yMMMMEEEEd(_lang.code).add_Hm().format(selectedDateTime),
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
    final altDeg = (sun['altitude']! * SunUtils.deg).toStringAsFixed(1);
    final azDeg = (sun['azimuth']! * SunUtils.deg).toStringAsFixed(0);

    double? horizonDeg;
    if (_useTerrainHorizon && _elevService != null) {
      final key = _hKey(lat, lng, sun['azimuth']!);
      final hor = _horizonCache[key];
      if (hor != null) horizonDeg = hor * SunUtils.deg;
    }

    final strs = Strs(_lang);

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
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Type: ${place.type.name.toUpperCase()}",
                  style: theme.textTheme.labelLarge?.copyWith(color: colors.onSurfaceVariant)),
              const SizedBox(height: 8),
              Text("Sun now: $altDeg° alt · $azDeg° az",
                  style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant)),
              if (horizonDeg != null)
                Text("Local horizon: ${horizonDeg.toStringAsFixed(1)}°",
                    style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant)),
              const SizedBox(height: 8),
              Text("(${place.location.coordinates.lat.toStringAsFixed(5)}, ${place.location.coordinates.lng.toStringAsFixed(5)})",
                  style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant)),
            ],
          ),
        ),
        actionsPadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(strs.close, style: TextStyle(color: colors.secondary)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              _launchNavigation(place);
            },
            child: Text(strs.navigate, style: TextStyle(color: colors.primary, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // Robust navigation launcher for Android & iOS
  Future<void> _launchNavigation(Place place) async {
    final lat = place.location.coordinates.lat;
    final lng = place.location.coordinates.lng;
    final label = Uri.encodeComponent(place.name);

    final candidates = <Uri>[];

    if (defaultTargetPlatform == TargetPlatform.android) {
      candidates.add(Uri.parse("google.navigation:q=$lat,$lng&mode=d"));
      candidates.add(Uri.parse("geo:0,0?q=$lat,$lng($label)"));
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      candidates.add(Uri.parse("comgooglemaps://?daddr=$lat,$lng&directionsmode=driving"));
      candidates.add(Uri.parse("maps://?daddr=$lat,$lng&dirflg=d"));
    }

    candidates.add(Uri.parse("https://www.google.com/maps/dir/?api=1&destination=$lat,$lng&travelmode=driving"));

    for (final uri in candidates) {
      try {
        final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (ok) return;
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
  void onPointAnnotationClick(PointAnnotation annotation) => onAnnotationClick(annotation);
}

// --------- UI bits ---------
class _CountryLangBar extends StatelessWidget {
  final Country country;
  final AppLang lang;
  final ValueChanged<Country> onCountryTap;
  final VoidCallback onEnglishTap;

  const _CountryLangBar({
    required this.country,
    required this.lang,
    required this.onCountryTap,
    required this.onEnglishTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    Widget _flagBtn({
      required String asset,
      required bool selected,
      required VoidCallback onTap,
      String? tooltip,
    }) {
      return Tooltip(
        message: tooltip ?? '',
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            width: 34,
            height: 34,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: selected ? colors.primary.withOpacity(0.12) : colors.surface.withOpacity(0.9),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: selected ? colors.primary : colors.outlineVariant,
                width: selected ? 1.2 : 0.8,
              ),
              boxShadow: kElevationToShadow[1],
            ),
            padding: const EdgeInsets.all(4),
            child: Image.asset(
              asset,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => Icon(
                Icons.flag_outlined,
                size: 20,
                color: selected ? colors.primary : colors.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    }

    Widget _chipEN() {
      final selected = lang == AppLang.en;
      return InkWell(
        onTap: onEnglishTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            color: selected ? colors.primary.withOpacity(0.12) : colors.surface.withOpacity(0.9),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected ? colors.primary : colors.outlineVariant,
              width: selected ? 1.2 : 0.8,
            ),
            boxShadow: kElevationToShadow[1],
          ),
          alignment: Alignment.center,
          child: Text(
            'EN',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: selected ? colors.primary : colors.onSurface,
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: colors.surface.withOpacity(0.9),
        borderRadius: BorderRadius.circular(24),
        boxShadow: kElevationToShadow[2],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _flagBtn(
            asset: 'assets/icons/flag_si.png',
            selected: country == Country.si,
            onTap: () => onCountryTap(Country.si),
            tooltip: 'Slovenia',
          ),
          _flagBtn(
            asset: 'assets/icons/flag_hr.png',
            selected: country == Country.hr,
            onTap: () => onCountryTap(Country.hr),
            tooltip: 'Croatia',
          ),
          _flagBtn(
            asset: 'assets/icons/flag_rs.png',
            selected: country == Country.rs,
            onTap: () => onCountryTap(Country.rs),
            tooltip: 'Serbia',
          ),
          const SizedBox(width: 4),
          _chipEN(),
        ],
      ),
    );
  }
}

class _CityFilterChip extends StatelessWidget {
  final String selected;
  final List<City> cities;
  final String label;
  final ValueChanged<City> onPick;

  const _CityFilterChip({
    required this.selected,
    required this.cities,
    required this.label,
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
        tooltip: label,
        onSelected: onPick,
        itemBuilder: (ctx) => cities.map((c) => PopupMenuItem<City>(value: c, child: Text(c.name))).toList(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.location_city_rounded, size: 18),
            const SizedBox(width: 8),
            Text(selected, style: TextStyle(color: colors.onSurface)),
            const SizedBox(width: 4),
            const Icon(Icons.arrow_drop_down),
          ]),
        ),
      ),
    );
  }
}

class _FilterToggleButton extends StatelessWidget {
  final bool isOpen;
  final int activeCount;
  final VoidCallback onTap;
  const _FilterToggleButton({
    required this.isOpen,
    required this.activeCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'Filter',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              height: 40,
              width: 40,
              decoration: BoxDecoration(
                color: colors.surface.withOpacity(0.95),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: colors.outlineVariant),
                boxShadow: kElevationToShadow[2],
              ),
              alignment: Alignment.center,
              child: Icon(Icons.tune_rounded, size: 20, color: colors.onSurface),
            ),
            Positioned(
              right: -2,
              top: -2,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: colors.primary,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$activeCount',
                  style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TypeFilterDropdown extends StatelessWidget {
  final Strs strs;
  final Set<PlaceType> enabled;
  final ValueChanged<PlaceType> onToggle;
  const _TypeFilterDropdown({
    required this.strs,
    required this.enabled,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    Widget chip(String label, PlaceType type, IconData icon) {
      final sel = enabled.contains(type);
      return FilterChip(
        label: Text(label),
        avatar: Icon(icon, size: 18),
        selected: sel,
        onSelected: (_) => onToggle(type),
        backgroundColor: colors.surfaceVariant.withOpacity(0.35),
        selectedColor: colors.primary.withOpacity(0.20),
        checkmarkColor: colors.primary,
        labelStyle: TextStyle(
          color: sel ? colors.onPrimaryContainer : colors.onSurface,
          fontWeight: FontWeight.w500,
        ),
        shape: StadiumBorder(
          side: BorderSide(color: sel ? colors.primary : colors.outlineVariant),
        ),
      );
    }

    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(14),
      color: colors.surface.withOpacity(0.98),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            chip(strs.cafes, PlaceType.cafe, Icons.local_cafe_rounded),
            chip(strs.pubs, PlaceType.pub, Icons.local_bar_rounded),
            chip(strs.parks, PlaceType.park, Icons.park_rounded),
          ],
        ),
      ),
    );
  }
}
