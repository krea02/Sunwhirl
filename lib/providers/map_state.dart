import 'dart:async';
import 'dart:math' as math; // For math.max and math.min
import 'package:flutter/foundation.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import '../models/place.dart';
import '../models/building.dart';
import '../services/building_service.dart';
import '../services/place_service.dart';

class MapState with ChangeNotifier {
  DateTime _selectedDateTime = DateTime.now();
  Place? _selectedPlace;

  Map<String, Building> _buildings = {};
  List<Place> _places = [];
  Set<String> _placeIds = {};

  bool _isLoadingBuildings = false;
  Timer? _buildingsDebounceTimer;
  int _buildingRequestEpoch = 0;

  bool _isLoadingPlaces = false;
  Timer? _placesDebounceTimer;
  int _placesRequestEpoch = 0;

  CoordinateBounds? _loadedDataCoverageForBuildings;
  CoordinateBounds? _loadedDataCoverageForPlaces;

  bool _flyToPlaceNeeded = false;
  bool _mounted = true;

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
    if (_mounted) {
      notifyListeners();
    }
  }

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
      if (kDebugMode) print("MapState: Place selected: ${place?.name ?? 'None'}, Fly-to needed: $_flyToPlaceNeeded.");
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

  // --- NEW Helper function to check if a point is within bounds ---
  bool _isPointTrulyWithinBounds(Position point, CoordinateBounds bounds, {bool inclusive = true}) {
    final double lat = point.lat.toDouble();
    final double lng = point.lng.toDouble();

    final double minLat = bounds.southwest.coordinates.lat.toDouble();
    final double maxLat = bounds.northeast.coordinates.lat.toDouble();
    final double minLng = bounds.southwest.coordinates.lng.toDouble();
    final double maxLng = bounds.northeast.coordinates.lng.toDouble();

    // Handle cases where bounds might cross the antimeridian (maxLng < minLng)
    bool lngCheck;
    if (maxLng >= minLng) { // Normal case
      lngCheck = inclusive ? (lng >= minLng && lng <= maxLng) : (lng > minLng && lng < maxLng);
    } else { // Antimeridian crossed
      lngCheck = inclusive ? (lng >= minLng || lng <= maxLng) : (lng > minLng || lng < maxLng);
    }

    bool latCheck = inclusive ? (lat >= minLat && lat <= maxLat) : (lat > minLat && lat < maxLat);

    return latCheck && lngCheck;
  }


  // Helper function to check if innerBounds is contained within outerBounds
  bool _isBoundsContained(CoordinateBounds innerBounds, CoordinateBounds outerBounds) {
    if (outerBounds.infiniteBounds == true) return true;

    final sw = innerBounds.southwest.coordinates;
    final ne = innerBounds.northeast.coordinates;

    // Create all 4 corner points of the inner bounds
    final Position innerSW_pos = sw;
    final Position innerNE_pos = ne;
    final Position innerNW_pos = Position(sw.lng.toDouble(), ne.lat.toDouble());
    final Position innerSE_pos = Position(ne.lng.toDouble(), sw.lat.toDouble());

    // Use the new helper method
    return _isPointTrulyWithinBounds(innerSW_pos, outerBounds, inclusive: true) &&
        _isPointTrulyWithinBounds(innerNE_pos, outerBounds, inclusive: true) &&
        _isPointTrulyWithinBounds(innerNW_pos, outerBounds, inclusive: true) &&
        _isPointTrulyWithinBounds(innerSE_pos, outerBounds, inclusive: true);
  }

  CoordinateBounds _unionBounds(CoordinateBounds b1, CoordinateBounds b2) {
    double minLat = math.min(b1.southwest.coordinates.lat.toDouble(), b2.southwest.coordinates.lat.toDouble());
    double minLng = math.min(b1.southwest.coordinates.lng.toDouble(), b2.southwest.coordinates.lng.toDouble());
    double maxLat = math.max(b1.northeast.coordinates.lat.toDouble(), b2.northeast.coordinates.lat.toDouble());
    double maxLng = math.max(b1.northeast.coordinates.lng.toDouble(), b2.northeast.coordinates.lng.toDouble());

    // Simplified antimeridian logic for union:
    // If one of the bounds crosses (e.g. b1.ne.lng < b1.sw.lng), a simple min/max for lng is problematic.
    // A full robust union across antimeridian is complex.
    // This simplified version assumes no antimeridian crossing for the *resulting union* for simplicity.
    // If individual bounds cross, their minLng might be > maxLng (e.g. minLng=170, maxLng=-170).
    // This scenario needs a more advanced geometry library for perfect handling.
    // For now, we assume local/regional maps not typically spanning the antimeridian for the union.
    // If b1 crosses and b2 doesn't, the simple min/max might "unwrap" the longitude range undesirably.

    // Check if either original bound crossed the antimeridian.
    bool b1Crossed = b1.northeast.coordinates.lng.toDouble() < b1.southwest.coordinates.lng.toDouble();
    bool b2Crossed = b2.northeast.coordinates.lng.toDouble() < b2.southwest.coordinates.lng.toDouble();

    if (b1Crossed && b2Crossed) {
      // Both cross, union is the world excluding the gap between maxLngs and minLngs
      // This case is very complex for AABB, often results in two bounding boxes or full world.
      // For simplicity, we might take the widest coverage which could be problematic.
      // Or, if they both cross, they might form a contiguous band.
      // minLng will be min of (b1.sw.lng, b2.sw.lng)
      // maxLng will be max of (b1.ne.lng, b2.ne.lng) - but these are on other side of dateline.
      // This is where AABB union is insufficient.
      // For now, using simple min/max and logging a warning.
      if (kDebugMode) print("MapState _unionBounds: WARNING - Unioning two bounds that both cross the antimeridian. Result may be inaccurate.");
    } else if (b1Crossed || b2Crossed) {
      // One crosses. The union will also cross.
      // The one that doesn't cross, say b2: its lng range is [b2.sw.lng, b2.ne.lng]
      // The one that crosses, say b1: its lng range is [b1.sw.lng, 180] U [-180, b1.ne.lng]
      // This also makes simple min/max for longitude incorrect.
      if (kDebugMode) print("MapState _unionBounds: WARNING - Unioning with one bound crossing the antimeridian. Result may be inaccurate.");
      // A common approach is to take the "larger" segment by checking if the non-crossing bound
      // falls into the "gap" of the crossing one.
      // For now, this simplified union will proceed with direct min/max of the given values,
      // which might lead to an overly wide or incorrect longitude span.
    }
    // If neither crosses, the simple min/max for lng is fine.

    return CoordinateBounds(
      southwest: Point(coordinates: Position(minLng, minLat)),
      northeast: Point(coordinates: Position(maxLng, maxLat)),
      infiniteBounds: false,
    );
  }

  void fetchBuildingsForView(CoordinateBounds currentViewportBounds, double zoom) {
    const minFetchZoom = 14.5;
    if (zoom < minFetchZoom) {
      if (_buildings.isNotEmpty || _isLoadingBuildings || _loadedDataCoverageForBuildings != null) {
        if (kDebugMode) print("MapState: Zoom ($zoom) < $minFetchZoom. Clearing ALL accumulated buildings & coverage.");
        clearAllAccumulatedBuildingData();
      }
      return;
    }

    if (_loadedDataCoverageForBuildings != null && _isBoundsContained(currentViewportBounds, _loadedDataCoverageForBuildings!)) {
      if (kDebugMode) print("MapState: Building data for current view already covered. Skipping fetch.");
      return;
    }
    if (kDebugMode) print("MapState: Building data NOT covered. Proceeding to fetch for viewport: SW(${currentViewportBounds.southwest.coordinates.lat.toStringAsFixed(4)}, ${currentViewportBounds.southwest.coordinates.lng.toStringAsFixed(4)}) NE(${currentViewportBounds.northeast.coordinates.lat.toStringAsFixed(4)}, ${currentViewportBounds.northeast.coordinates.lng.toStringAsFixed(4)})");

    _buildingsDebounceTimer?.cancel();
    _buildingsDebounceTimer = Timer(const Duration(milliseconds: 700), () {
      if (!_mounted) return;
      _performBuildingFetch(currentViewportBounds);
    });
  }

  Future<void> _performBuildingFetch(CoordinateBounds requestedBounds) async {
    final int myEpoch = ++_buildingRequestEpoch;
    if (myEpoch == _buildingRequestEpoch) {
      if (!_isLoadingBuildings) {
        _isLoadingBuildings = true;
        if (kDebugMode) print("MapState: Building fetch (Epoch $myEpoch) STARTING. isLoadingBuildings=true.");
        _safeNotifyListeners();
      }
    } else {
      if (kDebugMode) print("MapState: Building fetch (Epoch $myEpoch) STALE at start. Will run but not manage global state.");
    }

    try {
      final List<Building> fetched = await BuildingService.fetchBuildingsInBounds(requestedBounds);

      if (!_mounted || myEpoch != _buildingRequestEpoch) {
        if(!_mounted && kDebugMode) print("MapState: Building fetch (Epoch $myEpoch) completed but MapState DISPOSED.");
        if(myEpoch != _buildingRequestEpoch && kDebugMode) print("MapState: Stale building data (Epoch $myEpoch, CurrentEpoch $_buildingRequestEpoch).");
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
        _loadedDataCoverageForBuildings = _loadedDataCoverageForBuildings == null
            ? requestedBounds // Assign directly if it's the first loaded coverage
            : _unionBounds(_loadedDataCoverageForBuildings!, requestedBounds);
        if (kDebugMode) print("MapState: Merged/Updated. Total buildings: ${_buildings.length} (Epoch: $myEpoch). Coverage updated.");
        _safeNotifyListeners();
      } else {
        if (kDebugMode) print("MapState: No new or changed building data (Epoch: $myEpoch). Total: ${_buildings.length}. Coverage not changed.");
      }

    } catch (e) {
      if (kDebugMode) print("MapState: Error fetching buildings (Epoch: $myEpoch): $e");
    } finally {
      if (myEpoch == _buildingRequestEpoch) {
        if (_isLoadingBuildings) {
          _isLoadingBuildings = false;
          if (kDebugMode) print("MapState: Building fetch (Epoch $myEpoch) FINISHED. isLoadingBuildings=false.");
          _safeNotifyListeners();
        }
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

  void fetchPlacesForView(CoordinateBounds currentViewportBounds, double zoom) {
    if (_loadedDataCoverageForPlaces != null && _isBoundsContained(currentViewportBounds, _loadedDataCoverageForPlaces!)) {
      if (kDebugMode) print("MapState: Place data for current view already covered. Skipping fetch.");
      return;
    }
    if (kDebugMode) print("MapState: Place data NOT covered. Proceeding to fetch for viewport: SW(${currentViewportBounds.southwest.coordinates.lat.toStringAsFixed(4)}, ${currentViewportBounds.southwest.coordinates.lng.toStringAsFixed(4)}) NE(${currentViewportBounds.northeast.coordinates.lat.toStringAsFixed(4)}, ${currentViewportBounds.northeast.coordinates.lng.toStringAsFixed(4)})");

    _placesDebounceTimer?.cancel();
    _placesDebounceTimer = Timer(const Duration(milliseconds: 900), () {
      if (!_mounted) return;
      _performPlacesFetch(currentViewportBounds);
    });
  }

  Future<void> _performPlacesFetch(CoordinateBounds requestedBounds) async {
    final int myEpoch = ++_placesRequestEpoch;
    if (myEpoch == _placesRequestEpoch) {
      if (!_isLoadingPlaces) {
        _isLoadingPlaces = true;
        if (kDebugMode) print("MapState: Places fetch (Epoch $myEpoch) STARTING. isLoadingPlaces=true.");
        _safeNotifyListeners();
      }
    } else {
      if (kDebugMode) print("MapState: Places fetch (Epoch $myEpoch) STALE at start. Will run but not manage global state.");
    }

    try {
      final List<Place> fetchedPlaces = await PlaceService.fetchPlacesInBounds(requestedBounds);

      if (!_mounted || myEpoch != _placesRequestEpoch) {
        if(!_mounted && kDebugMode) print("MapState: Places fetch (Epoch $myEpoch) completed but MapState DISPOSED.");
        if(myEpoch != _placesRequestEpoch && kDebugMode) print("MapState: Stale place data (Epoch $myEpoch, CurrentEpoch $_placesRequestEpoch).");
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
        _loadedDataCoverageForPlaces = _loadedDataCoverageForPlaces == null
            ? requestedBounds
            : _unionBounds(_loadedDataCoverageForPlaces!, requestedBounds);
        if (kDebugMode) print("MapState: Added $addedCount new places. Total: ${_places.length} (Epoch: $myEpoch). Coverage updated.");
        _safeNotifyListeners();
      } else {
        if (kDebugMode) print("MapState: No new unique places from fetch (Epoch: $myEpoch). Total: ${_places.length}. Coverage not changed.");
      }

    } catch (e) {
      if (kDebugMode) print("MapState: Error fetching places (Epoch: $myEpoch): $e");
    } finally {
      if (myEpoch == _placesRequestEpoch) {
        if (_isLoadingPlaces) {
          _isLoadingPlaces = false;
          if (kDebugMode) print("MapState: Places fetch (Epoch $myEpoch) FINISHED. isLoadingPlaces=false.");
          _safeNotifyListeners();
        }
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

  @override
  void dispose() {
    if (kDebugMode) print("MapState: Disposing.");
    _mounted = false;
    _buildingsDebounceTimer?.cancel();
    _placesDebounceTimer?.cancel();
    super.dispose();
  }
}