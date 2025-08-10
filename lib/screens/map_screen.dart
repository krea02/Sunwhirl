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
  bool _styleImagesRegistered = false;

  final Map<String, bool> _placeSunState = {};

  Timer? _mapIdleTimer;
  CameraState? _lastCameraState;
  CameraState? _previousIdleCameraState;
  bool _mapReady = false;

  final Map<String, Place> _annotationIdToPlace = {};

  DateTime? _lastDrawTime;
  bool _isRedrawing = false;

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
    // Note: Annotation managers are automatically disposed by the MapboxMap controller
    // when it's disposed, or when the map style changes. Explicitly setting them to null.
    _pointAnnotationManager = null;
    _polygonManager = null;
    _mapboxMap = null; // The MapWidget handles its own disposal.
    _placeIconImages.clear();
    _annotationIdToPlace.clear();
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
        return MapEntry(entry.key, Uint8List(0)); // Return empty list on error
      }
    });
    final results = await Future.wait(futures);
    _placeIconImages.clear();
    _placeIconImages.addEntries(results.where((entry) => entry.value.isNotEmpty));

    if (mounted) {
      setState(() {
        _iconsLoaded = true;
        _styleImagesRegistered = false;
      });
      await _ensureStyleImagesRegistered();
      if (_mapReady && !_isRedrawing) _tryRedraw("icons loaded");
    }
  }

  Future<void> _ensureStyleImagesRegistered() async {
    if (_mapboxMap == null || !_mapReady || _styleImagesRegistered) return;
    try {
      final style = _mapboxMap!.style;
      for (final entry in _placeIconImages.entries) {
        await style.setStyleImage(entry.key, entry.value, false);
      }
      _styleImagesRegistered = true;
    } catch (e) {
      if (kDebugMode) print("ℹ️ MapScreen: Error registering style images: $e");
    }
  }

  Future<void> _recreateAnnotationManagers() async {
    if (_mapboxMap == null) return;
    try {
      _polygonManager = await _mapboxMap!.annotations.createPolygonAnnotationManager();
      _pointAnnotationManager = await _mapboxMap!.annotations.createPointAnnotationManager();
      _annotationIdToPlace.clear();
      _pointAnnotationManager?.addOnPointAnnotationClickListener(
        AnnotationClickListener(onAnnotationClick: (annotation) {
          final place = _annotationIdToPlace[annotation.id];
          if (place != null) _showPlaceDialog(place);
        }),
      );
    } catch (e) {
      if (kDebugMode) print("❌ MapScreen: Error recreating annotation managers: $e");
    }
  }

  Future<void> _onMapCreated(MapboxMap mapboxMap) async {
    if (!mounted) return;
    _mapboxMap = mapboxMap;

    final mapState = Provider.of<MapState>(context, listen: false);
    // Default to a central location if no place is selected.
    final initialCenter = mapState.selectedPlace?.location ?? Point(coordinates: Position(14.3310, 46.3895)); // Tržič approx.
    final initialZoom = 14.0;

    try {
      await _mapboxMap?.setCamera(CameraOptions(center: initialCenter, zoom: initialZoom));
      await _recreateAnnotationManagers();
    } catch (e) {
      if (kDebugMode) print("❌ MapScreen: Error during map/annotation manager setup: $e");
    }
  }

  void _onMapLoaded(MapLoadedEventData event) {
    if (!mounted) return;
    _mapReady = true;
    _styleImagesRegistered = false;
    _placeSunState.clear();
    _ensureStyleImagesRegistered();
    _recreateAnnotationManagers().then((_) {
      _updateLastCameraState().then((_) {
        if (mounted && _lastCameraState != null) {
          _previousIdleCameraState = _lastCameraState;
          if (!_isRedrawing) {
            _triggerDataFetch(); // Fetch initial data for the view
            _tryRedraw("map loaded initial"); // Initial draw
          }
        }
      });
    });
  }

  void _onStyleLoaded(StyleLoadedEventData event) {
    if (!mounted) return;
    _styleImagesRegistered = false;
    _placeSunState.clear();
    _ensureStyleImagesRegistered();
  }

  void _onCameraIdle(MapIdleEventData event) {
    if (!mounted || !_mapReady) return;
    _mapIdleTimer?.cancel();
    _mapIdleTimer = Timer(const Duration(milliseconds: 700), () async {
      if (!mounted || !_mapReady || _isRedrawing) return;

      final CameraState? cameraStateAtStartOfIdleLogic = _previousIdleCameraState;
      await _updateLastCameraState();

      if (!mounted || _lastCameraState == null) return;

      bool cameraMovedEnoughForDataFetch = true;
      bool sunArrowNeedsUpdate = true; // Assume update needed unless proven otherwise

      if (cameraStateAtStartOfIdleLogic != null) {
        // Tolerances for camera movement checks
        final dataPosTol = 0.00005; // Degrees (approx 5.5m) for data fetch
        final dataZoomTol = 0.05;    // Zoom level change for data fetch
        final arrowPosTol = 0.0001;  // Degrees (approx 11m) for sun arrow update

        bool centerChangedForData = (cameraStateAtStartOfIdleLogic.center.coordinates.lat - _lastCameraState!.center.coordinates.lat).abs() > dataPosTol ||
            (cameraStateAtStartOfIdleLogic.center.coordinates.lng - _lastCameraState!.center.coordinates.lng).abs() > dataPosTol;
        bool zoomChangedForData = (cameraStateAtStartOfIdleLogic.zoom - _lastCameraState!.zoom).abs() > dataZoomTol;

        if (!centerChangedForData && !zoomChangedForData) {
          cameraMovedEnoughForDataFetch = false;
        }

        bool centerChangedForArrow = (cameraStateAtStartOfIdleLogic.center.coordinates.lat - _lastCameraState!.center.coordinates.lat).abs() > arrowPosTol ||
            (cameraStateAtStartOfIdleLogic.center.coordinates.lng - _lastCameraState!.center.coordinates.lng).abs() > arrowPosTol;

        if (!centerChangedForArrow && !zoomChangedForData) { // Also consider zoom for arrow if it affects shadow density perception
          sunArrowNeedsUpdate = false;
        }
      }

      if (cameraMovedEnoughForDataFetch) {
        _triggerDataFetch();
      }
      // Redraw if data might have changed OR if sun arrow / shadow appearance needs fine-tuning due to minor camera move.
      if (cameraMovedEnoughForDataFetch || sunArrowNeedsUpdate) {
        _tryRedraw("camera idle");
      }
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
      // Get current camera bounds to fetch data for the visible region.
      final bounds = await _mapboxMap!.coordinateBoundsForCamera(_lastCameraState!.toCameraOptions());
      mapState.fetchBuildingsForView(bounds, currentZoom);
      mapState.fetchPlacesForView(bounds, currentZoom);
    } catch (e) {
      if (kDebugMode) print("❌ MapScreen: Error in _triggerDataFetch: $e");
    }
  }
  void _moveCameraTo(Point center, {required double zoom}) {
    if (!mounted || _mapboxMap == null) return;
    _mapboxMap?.flyTo(
        CameraOptions(center: center, zoom: zoom, pitch: 15.0), // Slight pitch for better 3D feel
        MapAnimationOptions(duration: 1500, startDelay: 100) // Smooth animation
    );
  }

  /// Checks for AABB (Axis-Aligned Bounding Box) intersection.
  bool _checkAabbIntersection(CoordinateBounds b1, CoordinateBounds b2) {
    // If one rectangle is on left side of other
    if (b1.northeast.coordinates.lng < b2.southwest.coordinates.lng ||
        b2.northeast.coordinates.lng < b1.southwest.coordinates.lng) {
      return false;
    }
    // If one rectangle is above other
    if (b1.northeast.coordinates.lat < b2.southwest.coordinates.lat ||
        b2.northeast.coordinates.lat < b1.southwest.coordinates.lat) {
      return false;
    }
    return true; // Overlapping
  }

  /// Checks if a point is within given coordinate bounds.
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

  String _iconNameFor(PlaceType type, bool isInSun) {
    return SunUtils.getIconPath(type, isInSun);
  }

  Future<void> _tryRedraw(String source) async {
    if (_isRedrawing) {
      if (kDebugMode) print("ℹ️ MapScreen: Redraw skipped, already in progress (source: $source)");
      return;
    }
    if (!mounted || _mapboxMap == null || !_mapReady || !_iconsLoaded ||
        _polygonManager == null || _pointAnnotationManager == null || _lastCameraState == null) {
      if (kDebugMode) print("ℹ️ MapScreen: Redraw skipped, map not ready or resources missing (source: $source)");
      return;
    }

    _isRedrawing = true;
    if (kDebugMode) print("🔄 MapScreen: Starting redraw (source: $source)");

    final mapState = Provider.of<MapState>(context, listen: false);
    final DateTime dateTime = mapState.selectedDateTime;

    try {
      final List<Building> allLoadedBuildings = mapState.buildings;
      final List<Place> allLoadedPlaces = mapState.places;
      final CoordinateBounds currentViewportBounds = await _mapboxMap!.coordinateBoundsForCamera(_lastCameraState!.toCameraOptions());

      _lastDrawTime = dateTime;
      final Map<String, List<Position>> calculatedShadows =
      await _calculateAndDrawBuildingShadows(allLoadedBuildings, dateTime, currentViewportBounds);

      // Then draw places with their sun/shade status.
      await _drawPlaces(allLoadedPlaces, allLoadedBuildings, dateTime, calculatedShadows, currentViewportBounds);

    } catch (e, s) {
      if (kDebugMode && mounted) {
        print("❌ MapScreen: Error during redraw by '$source': $e\n$s");
      }
    } finally {
      if (mounted) {
        _isRedrawing = false;
        if (kDebugMode) print("✅ MapScreen: Finished redraw (source: $source)");
      }
    }
  }

  Future<Map<String, List<Position>>> _calculateAndDrawBuildingShadows(
      List<Building> allLoadedBuildings, DateTime dateTime, CoordinateBounds currentViewportBounds) async {
    if (!mounted || _polygonManager == null || _lastCameraState == null) return {};

    try {
      await _polygonManager!.deleteAll();
    } catch (e) {
      if (kDebugMode) print("ℹ️ MapScreen: Info clearing polygon annotations: $e");
    }

    // Calculate sun position based on the center of the current map view for general shadow direction and opacity.
    final sunPosCenter = SunUtils.getSunPosition(
        dateTime,
        _lastCameraState!.center.coordinates.lat.toDouble(),
        _lastCameraState!.center.coordinates.lng.toDouble()
    );
    final double sunAltitudeRad = sunPosCenter['altitude']!;
    final double sunAzimuth_N_CW_rad = sunPosCenter['azimuth']!;

    final Map<String, List<Position>> calculatedShadowsForLogic = {};
    final List<PolygonAnnotationOptions> shadowDrawOptions = [];

    if (sunAltitudeRad > SunUtils.altitudeThresholdRad) { // Only draw shadows if sun is above horizon threshold

      // --- NEW: Dynamic Opacity Logic ---
      final double altitudeDeg = sunAltitudeRad * SunUtils.deg;
      const double maxShadowOpacity = 0.35; // Max opacity for shadows

      // Define altitude ranges for fading
      const double horizonFadeEndAlt = SunUtils.altitudeThresholdRad * SunUtils.deg + 0.5; // Below this, shadow is gone
      const double horizonFadeStartAlt = 5.0;  // Shadows start fading in from horizon up to this altitude

      const double peakOpacityStartAlt = 20.0; // Shadows are fully opaque (maxShadowOpacity) from this altitude
      const double peakOpacityEndAlt = 65.0;   // Shadows remain fully opaque up to this altitude

      const double zenithFadeStartAlt = peakOpacityEndAlt; // Start fading towards zenith from this altitude
      const double zenithEndAlt = 88.0;      // Shadows are very faint/gone by this altitude (nearly overhead sun)

      double currentShadowOpacity;

      if (altitudeDeg <= horizonFadeEndAlt || altitudeDeg >= zenithEndAlt ) {
        currentShadowOpacity = 0.0; // No shadow visible (sun too low or too high and directly overhead)
      } else if (altitudeDeg > horizonFadeEndAlt && altitudeDeg < horizonFadeStartAlt) { // Fading in from horizon
        double factor = (altitudeDeg - horizonFadeEndAlt) / (horizonFadeStartAlt - horizonFadeEndAlt);
        currentShadowOpacity = factor * maxShadowOpacity;
      } else if (altitudeDeg >= horizonFadeStartAlt && altitudeDeg < peakOpacityStartAlt) { // Ramping up to peak
        double factor = (altitudeDeg - horizonFadeStartAlt) / (peakOpacityStartAlt - horizonFadeStartAlt);
        currentShadowOpacity = factor * maxShadowOpacity; // Could also be a non-linear ramp
      } else if (altitudeDeg >= peakOpacityStartAlt && altitudeDeg <= zenithFadeStartAlt) { // Max opacity range
        currentShadowOpacity = maxShadowOpacity;
      } else if (altitudeDeg > zenithFadeStartAlt && altitudeDeg < zenithEndAlt) { // Fading out to zenith
        double factor = 1.0 - (altitudeDeg - zenithFadeStartAlt) / (zenithEndAlt - zenithFadeStartAlt);
        currentShadowOpacity = factor * maxShadowOpacity;
      } else {
        currentShadowOpacity = 0.0; // Should be covered by other conditions
      }
      currentShadowOpacity = currentShadowOpacity.clamp(0.0, maxShadowOpacity);
      // --- End of New Opacity Logic ---

      if (currentShadowOpacity > 0.01) { // Only proceed if shadows will be visible
        final fillColor = Colors.black.withOpacity(currentShadowOpacity).value;

        for (final building in allLoadedBuildings) {
          // Optimization: only calculate shadow if building AABB intersects viewport AABB.
          // This is a broad check; more precise culling happens with the shadow polygon itself.
          if (!_checkAabbIntersection(building.bounds, currentViewportBounds)) {
            calculatedShadowsForLogic[building.id] = []; // Store empty list for logic
            continue;
          }

          final List<Position> shadowOuterBoundary = SunUtils.calculateBuildingShadow(
              building: building,
              sunAzimuth_N_CW_rad: sunAzimuth_N_CW_rad, // Use view-center azimuth for all buildings for consistency
              sunAltitudeRad: sunAltitudeRad         // Use view-center altitude for all buildings
          );

          // Store the calculated shadow polygon for logic (e.g., isPlaceInShadow)
          calculatedShadowsForLogic[building.id] = shadowOuterBoundary.isNotEmpty ? List.from(shadowOuterBoundary) : [];

          if (shadowOuterBoundary.length >= 3) { // If a valid shadow polygon was formed
            List<Position> buildingFootprintHole = List.from(building.polygon);
            // Ensure footprint is closed for hole creation
            if (buildingFootprintHole.isNotEmpty &&
                (buildingFootprintHole.first.lat != buildingFootprintHole.last.lat ||
                    buildingFootprintHole.first.lng != buildingFootprintHole.last.lng)) {
              buildingFootprintHole.add(buildingFootprintHole.first);
            }

            // The hole points must be in opposite winding order of the outer ring.
            // Mapbox expects counter-clockwise for outer, clockwise for inner (holes).
            // Assuming shadowOuterBoundary is CCW, footprint for hole should be CW.
            List<Position> holePoints = List.from(buildingFootprintHole.reversed);

            List<List<Position>> polygonGeometry = [shadowOuterBoundary]; // Outer ring
            if (holePoints.length >= 4) { // A valid hole polygon needs at least 3 distinct vertices + closing point
              polygonGeometry.add(holePoints); // Inner ring (hole)
            }

            shadowDrawOptions.add(PolygonAnnotationOptions(
                geometry: Polygon(coordinates: polygonGeometry),
                fillColor: fillColor,
                fillOutlineColor: Colors.transparent.value, // No visible outline for shadows
                fillSortKey: 0 // All shadows at the same visual layer
            ));
          }
        }
      } else { // Sun is up, but opacity is too low (e.g. directly overhead)
        for (final building in allLoadedBuildings) {
          calculatedShadowsForLogic.putIfAbsent(building.id, () => []);
        }
      }
    } else { // Sun is below threshold (night)
      for (final building in allLoadedBuildings) {
        calculatedShadowsForLogic.putIfAbsent(building.id, () => []);
      }
    }

    try {
      if (shadowDrawOptions.isNotEmpty) {
        await _polygonManager!.createMulti(shadowDrawOptions);
      }
    } catch (e) {
      if (kDebugMode) print("ℹ️ MapScreen: Info creating polygon annotations: $e");
    }
    return calculatedShadowsForLogic;
  }

  Future<void> _drawPlaces(
      List<Place> allLoadedPlaces, List<Building> allLoadedBuildings, DateTime dateTime,
      Map<String, List<Position>> calculatedShadowsForLogic, CoordinateBounds currentViewportBounds) async {
    if (!mounted || _pointAnnotationManager == null || !_iconsLoaded || _lastCameraState == null) return;

    final Map<String, bool> newSunState = {};
    final List<PointAnnotationOptions> annotationOptionsList = [];
    final List<Place> placesForCreatedAnnotations = []; // To map created annotation IDs back to Places

    final zoom = _lastCameraState!.zoom;
    // Dynamically scale icons based on zoom level
    final double iconScale = zoom < 14.0 ? 0.5 : zoom < 15.5 ? 0.7 : zoom < 17.0 ? 0.85 : 1.0;

    // Filter buildings to only those potentially visible or affecting visible places
    final List<Building> relevantBuildings = allLoadedBuildings
        .where((b) => _checkAabbIntersection(b.bounds, currentViewportBounds)).toList();

    for (final place in allLoadedPlaces) {
      // Cull places outside the current viewport
      if (!_isPointInBounds(place.location.coordinates, currentViewportBounds, inclusive: true)) continue;

      final placeLat = place.location.coordinates.lat.toDouble();
      final placeLng = place.location.coordinates.lng.toDouble();

      // Get sun position specifically for this place's location (more accurate for isPlaceInShadow)
      final sunPosPlace = SunUtils.getSunPosition(dateTime, placeLat, placeLng);
      final double placeSunAltitudeRad = sunPosPlace['altitude']!;
      final double placeSunAzimuth_N_CW_rad = sunPosPlace['azimuth']!;

      bool isDirectlyInSun;
      bool isEffectivelyInSun; // Final status after considering neighbors

      // Determine if the place is inside any building footprint (host building)
      String? hostBuildingId;
      for (final building in relevantBuildings) { // Check against relevant buildings only
        if (building.polygon.length >= 3 &&
            SunUtils.isPointInPolygon(place.location.coordinates, building.polygon)) {
          hostBuildingId = building.id;
          break;
        }
      }

      if (placeSunAltitudeRad > SunUtils.altitudeThresholdRad) { // Sun is up
        isDirectlyInSun = !SunUtils.isPlaceInShadow(
            placePosition: place.location.coordinates,
            sunAzimuth_N_CW_rad: placeSunAzimuth_N_CW_rad,
            sunAltitudeRad: placeSunAltitudeRad,
            potentialBlockers: relevantBuildings, // Use filtered list
            buildingShadows: calculatedShadowsForLogic,
            ignoreBuildingId: hostBuildingId // Ignore shadow from its own host building
        );

        isEffectivelyInSun = isDirectlyInSun; // Initialize final status

        // Re-introduced conservative neighbor check
        if (isDirectlyInSun) { // Only check neighbors if the point itself is in sun
          int shadowedNeighborPoints = 0;
          const double neighborProbeDistance = 2.5; // meters
          const int totalNeighborProbes = 4; // North, East, South, West
          const int neighborShadowThreshold = 3; // If 3 out of 4 neighbors are shaded, consider the place shaded

          final double probeLatOffset = SunUtils.metersToLat(neighborProbeDistance);
          final double probeLngOffsetAtPlaceLat = SunUtils.metersToLng(neighborProbeDistance, placeLat);
          List<Position> neighborProbes = [
            Position(placeLng, placeLat + probeLatOffset), // North
            Position(placeLng + probeLngOffsetAtPlaceLat, placeLat), // East
            Position(placeLng, placeLat - probeLatOffset), // South
            Position(placeLng - probeLngOffsetAtPlaceLat, placeLat), // West
          ];

          for (final probePos in neighborProbes) {
            if (SunUtils.isPlaceInShadow(
                placePosition: probePos,
                sunAzimuth_N_CW_rad: placeSunAzimuth_N_CW_rad, // Use place's sun azimuth
                sunAltitudeRad: placeSunAltitudeRad,         // Use place's sun altitude
                potentialBlockers: relevantBuildings,
                buildingShadows: calculatedShadowsForLogic,
                ignoreBuildingId: null, // Probes are independent of any host building context
                checkRadiusMeters: 0.25, // Probes check a small area around themselves
                insideHostBuildingCheckRadiusMeters: 0.25 // Same small radius for probes
            )) {
              shadowedNeighborPoints++;
            }
          }

          if (shadowedNeighborPoints >= neighborShadowThreshold) {
            isEffectivelyInSun = false; // Override to "moon" / shaded
          }
        }
      } else { // Sun is down
        isDirectlyInSun = false;
        isEffectivelyInSun = false;
      }

      final iconName = _iconNameFor(place.type, isEffectivelyInSun);
      newSunState[place.id] = isEffectivelyInSun;
      annotationOptionsList.add(PointAnnotationOptions(
        geometry: place.location,
        iconImageName: iconName,
        iconSize: iconScale,
        iconAnchor: IconAnchor.BOTTOM, // Anchor icon at its bottom center
        iconOffset: [0.0, -2.0 * iconScale], // Slight vertical offset to make bottom sit on point
        symbolSortKey: 10, // Ensure places are drawn above shadows (shadows are fillSortKey 0)
      ));
      placesForCreatedAnnotations.add(place);
    }

    bool annotationsChanged = false;
    if (_placeSunState.length != newSunState.length) {
      annotationsChanged = true;
    } else {
      for (final entry in newSunState.entries) {
        if (_placeSunState[entry.key] != entry.value) {
          annotationsChanged = true;
          break;
        }
      }
    }
    if (!annotationsChanged) return;

    try {
      await _pointAnnotationManager?.deleteAll();
      _annotationIdToPlace.clear();
      if (annotationOptionsList.isNotEmpty) {
        final createdAnnotations = await _pointAnnotationManager!.createMulti(annotationOptionsList);
        if (createdAnnotations.length == placesForCreatedAnnotations.length) {
          for (int i = 0; i < createdAnnotations.length; i++) {
            final PointAnnotation? annotation = createdAnnotations[i];
            if (annotation != null) {
              _annotationIdToPlace[annotation.id] = placesForCreatedAnnotations[i];
            }
          }
        } else {
          if (kDebugMode) print("⚠️ MapScreen: Mismatch between created annotations and places list length.");
        }
      }
      _placeSunState
        ..clear()
        ..addAll(newSunState);
    } catch (e) {
      if (kDebugMode) print("ℹ️ MapScreen: Info creating point annotations: $e");
      _annotationIdToPlace.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Important for AutomaticKeepAliveClientMixin
    final mapState = context.watch<MapState>();
    final selectedPlace = mapState.selectedPlace;
    final selectedDateTime = mapState.selectedDateTime;
    final bool isLoadingData = mapState.isLoadingBuildings || mapState.isLoadingPlaces;

    // Handle flying to a selected place
    if (selectedPlace != null && mapState.shouldFlyToSelectedPlace) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _mapboxMap != null) {
          _moveCameraTo(selectedPlace.location, zoom: 16.5);
          Provider.of<MapState>(context, listen: false).notifyPlaceFlyToHandled();
        }
      });
    }

    // Sun Arrow indicator logic
    double sunArrowRotation = math.pi; // Default: pointing South (if sun is down)
    double sunArrowOpacity = 0.3;   // Default: faint
    if (_lastCameraState != null) {
      final sunPos = SunUtils.getSunPosition(selectedDateTime,
          _lastCameraState!.center.coordinates.lat.toDouble(),
          _lastCameraState!.center.coordinates.lng.toDouble()
      );
      final double altitudeRad = sunPos['altitude']!;
      final double azimuth_N_CW_rad = sunPos['azimuth']!;

      if (altitudeRad > SunUtils.altitudeThresholdRad) { // If sun is up
        sunArrowOpacity = 0.9;
        sunArrowRotation = azimuth_N_CW_rad; // Point in sun's direction
      }
    }
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Scaffold(
      body: Stack(
        children: [
          MapWidget(
            key: const ValueKey("mapWidget"), // Ensures widget state is preserved correctly
            styleUri: MapboxStyles.OUTDOORS, // Standard Mapbox outdoor style
            textureView: true, // Recommended for performance on some platforms
            onMapCreated: _onMapCreated,
            onMapLoadedListener: _onMapLoaded,
            onStyleLoadedListener: _onStyleLoaded,
            onMapIdleListener: _onCameraIdle,
            // onCameraChangeListener: _onCameraChanged, // If more frequent updates needed
          ),
          // Loading Indicator
          Positioned(top: 10, left: 10, child: SafeArea(child: AnimatedOpacity(
            opacity: isLoadingData ? 1.0 : 0.0, duration: const Duration(milliseconds: 300),
            child: IgnorePointer(ignoring: !isLoadingData, child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(color: colors.surface.withOpacity(0.9), borderRadius: BorderRadius.circular(20), boxShadow: kElevationToShadow[2]),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation<Color>(colors.primary))),
                const SizedBox(width: 10),
                Text(isLoadingData ? (mapState.isLoadingBuildings && mapState.isLoadingPlaces ? "Loading map data..." :
                mapState.isLoadingBuildings ? "Loading buildings..." : "Loading places...") : "Map Ready", style: TextStyle(color: colors.onSurface)),
              ]),
            )),
          ))),
          // Sun Direction Arrow
          Positioned(top: 20, right: 20, child: SafeArea(child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(color: colors.surface.withOpacity(0.7), shape: BoxShape.circle, boxShadow: kElevationToShadow[1]),
            child: Transform.rotate(angle: sunArrowRotation,
                child: Icon(Icons.navigation_rounded, size: 32, color: Colors.orange.withOpacity(sunArrowOpacity),
                    shadows: sunArrowOpacity > 0.5 ? [const Shadow(color: Colors.black38, blurRadius: 3.0, offset: Offset(1,1))] : null)),
          ))),
          // Current Date/Time Display
          Positioned(bottom: 15, left: 0, right: 0, child: IgnorePointer(child: Center(child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
            decoration: BoxDecoration(color: colors.surface.withOpacity(0.9), borderRadius: BorderRadius.circular(20), boxShadow: kElevationToShadow[2]),
            child: Text(
                DateFormat.yMMMMEEEEd(Localizations.localeOf(context).toString()).add_Hm().format(selectedDateTime), // Format based on locale
                style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500, color: colors.onSurface), textAlign: TextAlign.center),
          )))),
        ],
      ),
    );
  }

  void _showPlaceDialog(Place place) {
    if (!mounted) return;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

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
              Text("Type: ${place.type.name.toUpperCase()}", style: theme.textTheme.labelLarge?.copyWith(color: colors.onSurfaceVariant)),
              const SizedBox(height: 8),
              Text("Coordinates: (${place.location.coordinates.lat.toStringAsFixed(5)}, ${place.location.coordinates.lng.toStringAsFixed(5)})",
                  style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant)),
              if (kDebugMode) ...[ // Show ID only in debug mode
                const SizedBox(height: 4),
                Text("ID: ${place.id}", style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant.withOpacity(0.7), fontSize: 10)),
              ],
              const SizedBox(height: 20),
              Text("Open in Maps for navigation?", style: theme.textTheme.bodyMedium?.copyWith(color: colors.onSurface)),
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

    final List<Uri> urisToTry = [];

    // Platform-specific map URIs
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      // Apple Maps: q for query, ll for lat,lng. Adding name to query for better context.
      urisToTry.add(Uri.parse("maps://?q=$encodedName&ll=$lat,$lng&z=16"));
      // Google Maps on iOS: q for query, center for lat,lng, zoom.
      urisToTry.add(Uri.parse("comgooglemaps://?q=$encodedName&center=$lat,$lng&zoom=16"));
    } else if (defaultTargetPlatform == TargetPlatform.android) {
      // Google Maps Navigation Intent (starts navigation directly if possible)
      urisToTry.add(Uri.parse("google.navigation:q=$lat,$lng&mode=d")); // mode=d for driving
      // Geo Intent (generic, opens in any map app that handles it)
      urisToTry.add(Uri.parse("geo:$lat,$lng?q=$lat,$lng($encodedName)"));
    }

    // Fallback web URLs
    urisToTry.add(Uri.parse("https://www.google.com/maps/search/?api=1&query=$lat,$lng&query_place_id=${place.id}")); // If place ID is Google's
    urisToTry.add(Uri.parse("https://www.google.com/maps/@?api=1&map_action=map&center=$lat,$lng&zoom=16"));
    urisToTry.add(Uri.parse("https://maps.apple.com/?q=$encodedName&ll=$lat,$lng&z=16"));


    bool launched = false;
    for (final uri in urisToTry) {
      if (kDebugMode) print("Attempting to launch: $uri");
      if (await canLaunchUrl(uri)) {
        try {
          if (await launchUrl(uri, mode: LaunchMode.externalApplication)) {
            launched = true;
            if (kDebugMode) print("Successfully launched: $uri");
            break;
          }
        } catch (e) {
          if (kDebugMode) print("Error launching $uri: $e");
          // Muted, try next URI
        }
      } else {
        if (kDebugMode) print("Cannot launch: $uri");
      }
    }

    if (!launched && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text("Could not launch any map application."),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
    }
  }
}

/// Custom Click Listener for Mapbox Point Annotations.
class AnnotationClickListener extends OnPointAnnotationClickListener {
  final Function(PointAnnotation) onAnnotationClick;

  AnnotationClickListener({required this.onAnnotationClick});

  @override
  void onPointAnnotationClick(PointAnnotation annotation) {
    onAnnotationClick(annotation);
  }
}