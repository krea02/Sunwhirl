import 'dart:async';
import 'dart:math' as math; // For math.max and math.min
import 'package:flutter/foundation.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';

import '../models/place.dart';
import '../models/building.dart';
import '../services/building_service.dart';
import '../services/place_service.dart';

class MapState with ChangeNotifier {
  // --- Config ---
  static const double _overscanFactor = 1.3; // Fetch ~30% beyond the visible viewport
  static const double _minFetchZoomBuildings = 14.5;
  static const double _minFetchZoomPlaces = 13.5; // tweak if needed

  // --- UI state ---
  DateTime _selectedDateTime = DateTime.now();
  Place? _selectedPlace;
  bool _flyToPlaceNeeded = false;

  // --- Data state ---
  Map<String, Building> _buildings = {};
  List<Place> _places = [];
  Set<String> _placeIds = {};

  // --- Loading flags / debouncers ---
  bool _isLoadingBuildings = false;
  Timer? _buildingsDebounceTimer;
  int _buildingRequestEpoch = 0;

  bool _isLoadingPlaces = false;
  Timer? _placesDebounceTimer;
  int _placesRequestEpoch = 0;

  // --- Coverage of fetched data (to avoid refetching) ---
  CoordinateBounds? _loadedDataCoverageForBuildings;
  CoordinateBounds? _loadedDataCoverageForPlaces;

  // --- Lifecycle ---
  bool _mounted = true;

  // --- Getters ---
  DateTime get selectedDateTime => _selectedDateTime;
  Place? get selectedPlace => _selectedPlace;
  List<Building> get buildings => List.unmodifiable(_buildings.values);
  List<Place> get places => List.unmodifiable(_places);
  bool get isLoadingBuildings => _isLoadingBuildings;
  bool get isLoadingPlaces => _isLoadingPlaces;
  bool get shouldFlyToSelectedPlace => _flyToPlaceNeeded;

  MapState() {
    if (kDebugMode) print("MapState: Initialized");
  }

  void _safeNotifyListeners() {
    if (_mounted) notifyListeners();
  }

  // ---------------- Selected time & place ----------------

  void setSelectedTime(DateTime newTime) {
    if (_selectedDateTime != newTime) {
      _selectedDateTime = newTime;
      if (kDebugMode) print("MapState: Time updated to $newTime.");
      _safeNotifyListeners();
    }
  }

  void setSelectedPlace(Place? place) {
    if (_selectedPlace != place) {
      _selectedPlace = place;
      _flyToPlaceNeeded = (place != null);
      if (kDebugMode) {
        print("MapState: Place selected: ${place?.name ?? 'None'}, Fly-to: $_flyToPlaceNeeded.");
      }
      _safeNotifyListeners();
    }
  }

  void notifyPlaceFlyToHandled() {
    if (_flyToPlaceNeeded) {
      _flyToPlaceNeeded = false;
      if (kDebugMode) print("MapState: Fly-to handled, flag reset.");
      _safeNotifyListeners();
    }
  }

  // ---------------- Geometry helpers ----------------

  // Bounds overscan to prefetch around the viewport (reduces refetching on small pans).
  CoordinateBounds _expandBounds(CoordinateBounds b, {double factor = _overscanFactor}) {
    final sw = b.southwest.coordinates;
    final ne = b.northeast.coordinates;

    final swLat = sw.lat.toDouble();
    final swLng = sw.lng.toDouble();
    final neLat = ne.lat.toDouble();
    final neLng = ne.lng.toDouble();

    // Assumes no antimeridian crossing for simplicity (same assumption as elsewhere here).
    final centerLat = (swLat + neLat) / 2.0;
    final centerLng = (swLng + neLng) / 2.0;
    final halfLat = ((neLat - swLat).abs() * factor) / 2.0;
    final halfLng = ((neLng - swLng).abs() * factor) / 2.0;

    return CoordinateBounds(
      southwest: Point(coordinates: Position(centerLng - halfLng, centerLat - halfLat)),
      northeast: Point(coordinates: Position(centerLng + halfLng, centerLat + halfLat)),
      infiniteBounds: false,
    );
  }

  // Robust point-in-bounds that handles antimeridian in a basic way.
  bool _isPointTrulyWithinBounds(Position point, CoordinateBounds bounds, {bool inclusive = true}) {
    final double lat = point.lat.toDouble();
    final double lng = point.lng.toDouble();

    final double minLat = bounds.southwest.coordinates.lat.toDouble();
    final double maxLat = bounds.northeast.coordinates.lat.toDouble();
    final double minLng = bounds.southwest.coordinates.lng.toDouble();
    final double maxLng = bounds.northeast.coordinates.lng.toDouble();

    // Handle simple antimeridian wrap
    final bool lngCheck = (maxLng >= minLng)
        ? (inclusive ? (lng >= minLng && lng <= maxLng) : (lng > minLng && lng < maxLng))
        : (inclusive ? (lng >= minLng || lng <= maxLng) : (lng > minLng || lng < maxLng));

    final bool latCheck =
    inclusive ? (lat >= minLat && lat <= maxLat) : (lat > minLat && lat < maxLat);

    return latCheck && lngCheck;
  }

  // Is innerBounds completely inside outerBounds?
  bool _isBoundsContained(CoordinateBounds inner, CoordinateBounds outer) {
    if (outer.infiniteBounds == true) return true;

    final sw = inner.southwest.coordinates;
    final ne = inner.northeast.coordinates;

    final Position innerSW_pos = sw;
    final Position innerNE_pos = ne;
    final Position innerNW_pos = Position(sw.lng.toDouble(), ne.lat.toDouble());
    final Position innerSE_pos = Position(ne.lng.toDouble(), sw.lat.toDouble());

    return _isPointTrulyWithinBounds(innerSW_pos, outer, inclusive: true) &&
        _isPointTrulyWithinBounds(innerNE_pos, outer, inclusive: true) &&
        _isPointTrulyWithinBounds(innerNW_pos, outer, inclusive: true) &&
        _isPointTrulyWithinBounds(innerSE_pos, outer, inclusive: true);
  }

  // Simple union (note: antimeridian scenarios are simplified).
  CoordinateBounds _unionBounds(CoordinateBounds b1, CoordinateBounds b2) {
    double minLat =
    math.min(b1.southwest.coordinates.lat.toDouble(), b2.southwest.coordinates.lat.toDouble());
    double minLng =
    math.min(b1.southwest.coordinates.lng.toDouble(), b2.southwest.coordinates.lng.toDouble());
    double maxLat =
    math.max(b1.northeast.coordinates.lat.toDouble(), b2.northeast.coordinates.lat.toDouble());
    double maxLng =
    math.max(b1.northeast.coordinates.lng.toDouble(), b2.northeast.coordinates.lng.toDouble());

    bool b1Crossed =
        b1.northeast.coordinates.lng.toDouble() < b1.southwest.coordinates.lng.toDouble();
    bool b2Crossed =
        b2.northeast.coordinates.lng.toDouble() < b2.southwest.coordinates.lng.toDouble();

    if (b1Crossed && b2Crossed) {
      if (kDebugMode) {
        print("MapState _unionBounds: WARNING - Both bounds cross antimeridian; union may be inaccurate.");
      }
    } else if (b1Crossed || b2Crossed) {
      if (kDebugMode) {
        print("MapState _unionBounds: WARNING - One bound crosses antimeridian; union may be inaccurate.");
      }
    }

    return CoordinateBounds(
      southwest: Point(coordinates: Position(minLng, minLat)),
      northeast: Point(coordinates: Position(maxLng, maxLat)),
      infiniteBounds: false,
    );
  }

  // ---------------- Buildings fetching ----------------

  void fetchBuildingsForView(CoordinateBounds currentViewportBounds, double zoom) {
    if (zoom < _minFetchZoomBuildings) {
      if (_buildings.isNotEmpty || _isLoadingBuildings || _loadedDataCoverageForBuildings != null) {
        if (kDebugMode) {
          print("MapState: Zoom ($zoom) < $_minFetchZoomBuildings. Clearing ALL accumulated buildings & coverage.");
        }
        clearAllAccumulatedBuildingData();
      }
      return;
    }

    final inflated = _expandBounds(currentViewportBounds);
    if (_loadedDataCoverageForBuildings != null &&
        _isBoundsContained(inflated, _loadedDataCoverageForBuildings!)) {
      if (kDebugMode) print("MapState: Building data for inflated view already covered. Skip fetch.");
      return;
    }

    if (kDebugMode) {
      final sw = inflated.southwest.coordinates;
      final ne = inflated.northeast.coordinates;
      print("MapState: Buildings NOT covered. Fetching inflated viewport: "
          "SW(${sw.lat.toStringAsFixed(4)}, ${sw.lng.toStringAsFixed(4)}) "
          "NE(${ne.lat.toStringAsFixed(4)}, ${ne.lng.toStringAsFixed(4)})");
    }

    _buildingsDebounceTimer?.cancel();
    _buildingsDebounceTimer = Timer(const Duration(milliseconds: 700), () {
      if (!_mounted) return;
      _performBuildingFetch(inflated);
    });
  }

  Future<void> _performBuildingFetch(CoordinateBounds requestedBounds) async {
    final int myEpoch = ++_buildingRequestEpoch;

    if (myEpoch == _buildingRequestEpoch) {
      if (!_isLoadingBuildings) {
        _isLoadingBuildings = true;
        if (kDebugMode) print("MapState: Building fetch (Epoch $myEpoch) START.");
        _safeNotifyListeners();
      }
    } else {
      if (kDebugMode) print("MapState: Building fetch (Epoch $myEpoch) STALE at start.");
    }

    try {
      final List<Building> fetched = await BuildingService.fetchBuildingsInBounds(requestedBounds);

      if (!_mounted || myEpoch != _buildingRequestEpoch) {
        if (!_mounted && kDebugMode) {
          print("MapState: Building fetch (Epoch $myEpoch) completed but MapState DISPOSED.");
        }
        if (myEpoch != _buildingRequestEpoch && kDebugMode) {
          print("MapState: Stale building data (Epoch $myEpoch, Current $_buildingRequestEpoch).");
        }
        return;
      }

      bool dataChanged = false;
      if (fetched.isNotEmpty) {
        for (var b in fetched) {
          if (!_buildings.containsKey(b.id) || _buildings[b.id] != b) {
            _buildings[b.id] = b;
            dataChanged = true;
          }
        }
      }

      if (dataChanged || _loadedDataCoverageForBuildings == null) {
        _loadedDataCoverageForBuildings = (_loadedDataCoverageForBuildings == null)
            ? requestedBounds
            : _unionBounds(_loadedDataCoverageForBuildings!, requestedBounds);

        if (kDebugMode) {
          print("MapState: Buildings updated. Total=${_buildings.length} (Epoch $myEpoch). Coverage updated.");
        }
        _safeNotifyListeners();
      } else {
        if (kDebugMode) {
          print("MapState: No new/changed buildings (Epoch $myEpoch). Total=${_buildings.length}.");
        }
      }
    } catch (e) {
      if (kDebugMode) print("MapState: Error fetching buildings (Epoch $myEpoch): $e");
    } finally {
      if (myEpoch == _buildingRequestEpoch && _isLoadingBuildings) {
        _isLoadingBuildings = false;
        if (kDebugMode) print("MapState: Building fetch (Epoch $myEpoch) FINISHED.");
        _safeNotifyListeners();
      }
    }
  }

  void clearAllAccumulatedBuildingData() {
    bool stateChanged = false;
    _buildingsDebounceTimer?.cancel();
    if (_buildings.isNotEmpty) {
      _buildings.clear();
      stateChanged = true;
      if (kDebugMode) print("MapState: ALL accumulated buildings cleared.");
    }
    _loadedDataCoverageForBuildings = null;
    if (_isLoadingBuildings) {
      _isLoadingBuildings = false;
      _buildingRequestEpoch++;
      stateChanged = true;
    }
    if (stateChanged) _safeNotifyListeners();
  }

  // ---------------- Places fetching ----------------

  void fetchPlacesForView(CoordinateBounds currentViewportBounds, double zoom) {
    // Optional min zoom to reduce clutter & requests
    if (zoom < _minFetchZoomPlaces) {
      // Optionally clear places when zoomed out a lot:
      // clearAllAccumulatedPlaceData();
      return;
    }

    final inflated = _expandBounds(currentViewportBounds);
    if (_loadedDataCoverageForPlaces != null &&
        _isBoundsContained(inflated, _loadedDataCoverageForPlaces!)) {
      if (kDebugMode) print("MapState: Place data for inflated view already covered. Skip fetch.");
      return;
    }

    if (kDebugMode) {
      final sw = inflated.southwest.coordinates;
      final ne = inflated.northeast.coordinates;
      print("MapState: Places NOT covered. Fetching inflated viewport: "
          "SW(${sw.lat.toStringAsFixed(4)}, ${sw.lng.toStringAsFixed(4)}) "
          "NE(${ne.lat.toStringAsFixed(4)}, ${ne.lng.toStringAsFixed(4)})");
    }

    _placesDebounceTimer?.cancel();
    _placesDebounceTimer = Timer(const Duration(milliseconds: 900), () {
      if (!_mounted) return;
      _performPlacesFetch(inflated);
    });
  }

  Future<void> _performPlacesFetch(CoordinateBounds requestedBounds) async {
    final int myEpoch = ++_placesRequestEpoch;

    if (myEpoch == _placesRequestEpoch) {
      if (!_isLoadingPlaces) {
        _isLoadingPlaces = true;
        if (kDebugMode) print("MapState: Places fetch (Epoch $myEpoch) START.");
        _safeNotifyListeners();
      }
    } else {
      if (kDebugMode) print("MapState: Places fetch (Epoch $myEpoch) STALE at start.");
    }

    try {
      final List<Place> fetchedPlaces = await PlaceService.fetchPlacesInBounds(requestedBounds);

      if (!_mounted || myEpoch != _placesRequestEpoch) {
        if (!_mounted && kDebugMode) {
          print("MapState: Places fetch (Epoch $myEpoch) completed but MapState DISPOSED.");
        }
        if (myEpoch != _placesRequestEpoch && kDebugMode) {
          print("MapState: Stale place data (Epoch $myEpoch, Current $_placesRequestEpoch).");
        }
        return;
      }

      int addedCount = 0;
      if (fetchedPlaces.isNotEmpty) {
        for (final place in fetchedPlaces) {
          if (_placeIds.add(place.id)) {
            _places.add(place);
            addedCount++;
          }
        }
      }

      if (addedCount > 0 || _loadedDataCoverageForPlaces == null) {
        _loadedDataCoverageForPlaces = (_loadedDataCoverageForPlaces == null)
            ? requestedBounds
            : _unionBounds(_loadedDataCoverageForPlaces!, requestedBounds);

        if (kDebugMode) {
          print("MapState: Added $addedCount new places. Total=${_places.length} (Epoch $myEpoch). Coverage updated.");
        }
        _safeNotifyListeners();
      } else {
        if (kDebugMode) {
          print("MapState: No new unique places (Epoch $myEpoch). Total=${_places.length}.");
        }
      }
    } catch (e) {
      if (kDebugMode) print("MapState: Error fetching places (Epoch $myEpoch): $e");
    } finally {
      if (myEpoch == _placesRequestEpoch && _isLoadingPlaces) {
        _isLoadingPlaces = false;
        if (kDebugMode) print("MapState: Places fetch (Epoch $myEpoch) FINISHED.");
        _safeNotifyListeners();
      }
    }
  }

  void clearAllAccumulatedPlaceData() {
    bool stateChanged = false;
    _placesDebounceTimer?.cancel();
    if (_places.isNotEmpty) {
      _places.clear();
      _placeIds.clear();
      stateChanged = true;
      if (kDebugMode) print("MapState: ALL accumulated places cleared.");
    }
    _loadedDataCoverageForPlaces = null;
    if (_isLoadingPlaces) {
      _isLoadingPlaces = false;
      _placesRequestEpoch++;
      stateChanged = true;
    }
    if (stateChanged) _safeNotifyListeners();
  }

  // ---------------- Resets (optional helpers) ----------------

  void resetCoverageOnly() {
    _loadedDataCoverageForBuildings = null;
    _loadedDataCoverageForPlaces = null;
    if (kDebugMode) print("MapState: Coverage reset only.");
    _safeNotifyListeners();
  }

  void resetAllData() {
    clearAllAccumulatedBuildingData();
    clearAllAccumulatedPlaceData();
    if (kDebugMode) print("MapState: All data reset.");
  }

  // ---------------- Lifecycle ----------------

  @override
  void dispose() {
    if (kDebugMode) print("MapState: Disposing.");
    _mounted = false;
    _buildingsDebounceTimer?.cancel();
    _placesDebounceTimer?.cancel();
    super.dispose();
  }
}
