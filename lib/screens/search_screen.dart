import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/place.dart';
import '../providers/map_state.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounce;

  List<Place> _allPlacesFromState = []; // Sorted master list
  List<Place> _filteredPlaces = [];     // Display list

  // Track instance to detect when MapState gives us a new list
  List<Place> _previousMapStatePlacesInstance = const [];

  @override
  void initState() {
    super.initState();

    final mapState = Provider.of<MapState>(context, listen: false);
    _updateLocalPlaceLists(mapState.places);
    _previousMapStatePlacesInstance = mapState.places;

    _searchController.addListener(_onQueryChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.removeListener(_onQueryChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onQueryChanged() {
    // Debounce to avoid filtering every keystroke
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 120), () {
      _filterPlaces(_searchController.text);
    });
  }

  void _updateLocalPlaceLists(List<Place> newPlacesSource) {
    _allPlacesFromState = List<Place>.from(newPlacesSource)
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    _filterPlaces(_searchController.text, callSetState: true);
  }

  void _filterPlaces(String query, {bool callSetState = true}) {
    final q = query.toLowerCase().trim();
    final result = (q.isEmpty)
        ? List<Place>.from(_allPlacesFromState)
        : _allPlacesFromState.where((p) => p.name.toLowerCase().contains(q)).toList();

    if (!mounted) return;
    if (callSetState) {
      setState(() => _filteredPlaces = result);
    } else {
      _filteredPlaces = result;
    }
  }

  @override
  Widget build(BuildContext context) {
    final mapState = context.watch<MapState>();
    final List<Place> currentMapStatePlaces = mapState.places;

    // If MapState’s internal list instance changed, refresh our local cache after build
    if (!identical(_previousMapStatePlacesInstance, currentMapStatePlaces)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (kDebugMode) {
          print("SearchScreen: mapState.places changed. Updating local lists.");
        }
        _updateLocalPlaceLists(currentMapStatePlaces);
        _previousMapStatePlacesInstance = currentMapStatePlaces;
      });
    }

    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Search Places'),
        elevation: 1,
        backgroundColor: colors.surface,
        foregroundColor: colors.onSurface,
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
                    ? IconButton(
                  icon: Icon(Icons.clear, color: colors.onSurfaceVariant),
                  tooltip: "Clear search",
                  onPressed: () => _searchController.clear(),
                )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(30.0),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: colors.surfaceVariant.withOpacity(0.5),
                contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 20),
              ),
              style: TextStyle(color: colors.onSurface),
            ),
          ),

          if (mapState.isLoadingPlaces && _filteredPlaces.isEmpty)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else
            Expanded(
              child: _filteredPlaces.isEmpty
                  ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Text(
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
                  height: 1,
                  thickness: 0.5,
                  indent: 16,
                  endIndent: 16,
                  color: theme.dividerColor.withOpacity(0.5),
                ),
                itemBuilder: (context, index) {
                  final place = _filteredPlaces[index];
                  return ListTile(
                    // No leading icons for minimal data/CPU
                    title: Text(place.name, style: TextStyle(color: colors.onSurface)),
                    subtitle: Text(
                      place.type.name.toUpperCase(),
                      style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
                    ),
                    trailing: Icon(Icons.chevron_right, color: colors.onSurfaceVariant),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 6.0),
                    onTap: () {
                      // Tell MapState which place to focus; MapScreen will fly the camera
                      Provider.of<MapState>(context, listen: false).setSelectedPlace(place);

                      // Optional toast
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Showing ${place.name} on map'),
                          duration: const Duration(seconds: 2),
                          behavior: SnackBarBehavior.floating,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          margin: const EdgeInsets.all(10),
                        ),
                      );

                      // If you want to auto-switch to the Map tab, wire a nav provider
                      // and set the selected index to 0 here.
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
