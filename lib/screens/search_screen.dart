import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/place.dart';
import '../utils/sun_utils.dart';
import '../providers/map_state.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _searchController = TextEditingController();

  List<Place> _allPlacesFromState = []; // Holds all places from MapState, sorted
  List<Place> _filteredPlaces = [];   // Holds filtered places for display

  // To track the instance of the places list from MapState to detect changes
  List<Place> _previousMapStatePlacesInstance = [];

  final Map<String, String> _iconPathCache = {};
  DateTime? _lastCacheClearTime;

  @override
  void initState() {
    super.initState();
    // Initialize with current places from MapState.
    // This ensures that if SearchScreen is built after places are loaded,
    // it shows them immediately. The build method will handle subsequent updates.
    final mapState = Provider.of<MapState>(context, listen: false);
    _updateLocalPlaceLists(mapState.places);
    _previousMapStatePlacesInstance = mapState.places; // Initialize the reference

    _searchController.addListener(() {
      // _filterPlaces uses _allPlacesFromState and calls setState
      _filterPlaces(_searchController.text);
    });

    _lastCacheClearTime = mapState.selectedDateTime;
  }

  // Helper function to update local lists and apply filter
  void _updateLocalPlaceLists(List<Place> newPlacesSource) {
    _allPlacesFromState = List.from(newPlacesSource);
    _allPlacesFromState.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    // After updating _allPlacesFromState, re-apply the current filter
    _filterPlaces(_searchController.text);
  }

  void _filterPlaces(String query) {
    final lowerCaseQuery = query.toLowerCase().trim();
    // This setState will trigger a rebuild, using the latest _allPlacesFromState
    setState(() {
      if (lowerCaseQuery.isEmpty) {
        _filteredPlaces = List.from(_allPlacesFromState); // Already sorted
      } else {
        _filteredPlaces = _allPlacesFromState.where((place) {
          return place.name.toLowerCase().contains(lowerCaseQuery);
        }).toList();
        // This list will maintain the sort order from _allPlacesFromState
      }
    });
  }

  Future<String> _getBasicSunMoonIconPath(Place place, DateTime dateTime) async {
    final String iconCacheKey = "basic_${place.id}_${dateTime.millisecondsSinceEpoch}";
    if (_iconPathCache.containsKey(iconCacheKey)) {
      return _iconPathCache[iconCacheKey]!;
    }

    final lat = place.location.coordinates.lat.toDouble();
    final lng = place.location.coordinates.lng.toDouble();
    final sunPos = SunUtils.getSunPosition(dateTime, lat, lng);
    final bool isSunEffectivelyUp = sunPos['altitude']! > SunUtils.altitudeThresholdRad;
    final String finalIconKey = SunUtils.getIconPath(place.type, isSunEffectivelyUp);
    _iconPathCache[iconCacheKey] = finalIconKey;
    return finalIconKey;
  }

  @override
  Widget build(BuildContext context) {
    // Watch MapState for changes to its properties
    final mapState = context.watch<MapState>();
    final selectedDateTime = mapState.selectedDateTime;
    final List<Place> currentMapStatePlaces = mapState.places;

    // Check if the places list from MapState has changed instance.
    // If so, schedule an update to our local lists after the current build.
    if (!identical(_previousMapStatePlacesInstance, currentMapStatePlaces)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) { // Ensure widget is still in the tree
          if (kDebugMode) print("SearchScreen: Detected change in mapState.places. Updating local lists.");
          _updateLocalPlaceLists(currentMapStatePlaces);
          _previousMapStatePlacesInstance = currentMapStatePlaces; // Update the reference
        }
      });
    }

    // Clear icon cache if time changes.
    // This also needs to be in a post-frame callback if it calls setState.
    if (_lastCacheClearTime != selectedDateTime) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          if (kDebugMode) print("SearchScreen: Time changed. Clearing icon cache and rebuilding list items.");
          _iconPathCache.clear();
          _lastCacheClearTime = selectedDateTime;
          // Force a rebuild of the list items to pick up new icon states from FutureBuilders
          // This is important because FutureBuilder results might be stale due to cache clear.
          setState(() {});
        }
      });
    }

    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Search Places'),
        elevation: 1, backgroundColor: colors.surface, foregroundColor: colors.onSurface,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search by name...',
                prefixIcon: Icon(Icons.search, color: colors.onSurfaceVariant),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(icon: Icon(Icons.clear, color: colors.onSurfaceVariant),
                    tooltip: "Clear search", onPressed: () => _searchController.clear())
                    : null,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(30.0), borderSide: BorderSide.none),
                filled: true, fillColor: colors.surfaceVariant.withOpacity(0.5),
                contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 20),
              ),
              style: TextStyle(color: colors.onSurface),
            ),
          ),
          // Show loading indicator if places are loading AND the filtered list is currently empty.
          if (mapState.isLoadingPlaces && _filteredPlaces.isEmpty)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else
            Expanded(
              // Use _filteredPlaces for the list view
              child: _filteredPlaces.isEmpty
                  ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Text(
                    // More informative message based on why the list might be empty
                    _searchController.text.isNotEmpty
                        ? 'No places found matching "${_searchController.text}"'
                        : _allPlacesFromState.isEmpty && !mapState.isLoadingPlaces
                        ? 'No places found in the current map area.\nTry moving or zooming out on the map.'
                        : 'Start typing to filter available places.',
                    style: theme.textTheme.titleMedium?.copyWith(color: colors.onSurfaceVariant),
                    textAlign: TextAlign.center,
                  ),
                ),
              )
                  : ListView.separated(
                itemCount: _filteredPlaces.length,
                separatorBuilder: (context, index) => Divider(
                    height: 1, thickness: 0.5, indent: 72, color: theme.dividerColor.withOpacity(0.5)),
                itemBuilder: (context, index) {
                  final place = _filteredPlaces[index];
                  // The FutureBuilder's key now correctly depends on selectedDateTime,
                  // ensuring it re-runs when time (and thus potentially icon state) changes.
                  return FutureBuilder<String>(
                    key: ValueKey("basic_${place.id}_${selectedDateTime.millisecondsSinceEpoch}"),
                    future: _getBasicSunMoonIconPath(place, selectedDateTime),
                    initialData: SunUtils.getIconPath(place.type, false), // Default to moon
                    builder: (context, snapshot) {
                      String iconKey = snapshot.data ?? SunUtils.getIconPath(place.type, false);
                      if (snapshot.hasError && kDebugMode) {
                        print("SearchScreen FutureBuilder Error for ${place.name}: ${snapshot.error}");
                        iconKey = SunUtils.getIconPath(place.type, false); // Fallback on error
                      }
                      final iconAssetPath = "assets/icons/$iconKey.png";
                      return ListTile(
                        leading: Image.asset(iconAssetPath, key: ValueKey(iconAssetPath), width: 32, height: 32,
                            errorBuilder: (_,e,s) {
                              if (kDebugMode) print("Error loading icon $iconAssetPath: $e");
                              return Icon(Icons.place_outlined, size: 32, color: colors.secondary);
                            }),
                        title: Text(place.name, style: TextStyle(color: colors.onSurface)),
                        subtitle: Text(place.type.name.toUpperCase(), style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
                        trailing: Icon(Icons.chevron_right, color: colors.onSurfaceVariant),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
                        onTap: () {
                          Provider.of<MapState>(context, listen: false).setSelectedPlace(place);
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text("Showing ${place.name} on map"), duration: const Duration(seconds: 2),
                              behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              margin: const EdgeInsets.all(10)));
                          // To switch to the map tab:
                          // This assumes your main app structure (SunwhirlApp) controls the BottomNavigationBar's selectedIndex.
                          // You would typically use a more robust navigation solution or pass a callback.
                          // For a simple case, if _onItemTapped from SunwhirlApp was accessible via a Provider/service:
                          // SomeNavigationService.instance.navigateToTab(0); // 0 for Map tab
                        },
                      );
                    },
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}