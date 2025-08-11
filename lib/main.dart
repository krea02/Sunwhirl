import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:provider/provider.dart';

import 'screens/map_screen.dart';
import 'screens/search_screen.dart';
import 'screens/time_screen.dart';
import 'providers/map_state.dart';
import 'services/terrain_elevation_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // SAFELY get the token from build arguments
  const String token = String.fromEnvironment("ACCESS_TOKEN");
  if (token.isEmpty) {
    print("Error: ACCESS_TOKEN environment variable not set during build!");
    return;
  }
  MapboxOptions.setAccessToken(token);

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => MapState()),
        // Terrain service is provided here; NO token leakage inside widgets.
        Provider<TerrainElevationService>(
          create: (_) => TerrainElevationService(
            mapboxToken: token,
            zoom: 14,
            useHiDpi: false,
          ),
          dispose: (_, s) => s.dispose(),
        ),
      ],
      child: const SunwhirlApp(),
    ),
  );
}

class SunwhirlApp extends StatefulWidget {
  const SunwhirlApp({super.key});

  @override
  State<SunwhirlApp> createState() => _SunwhirlAppState();
}

class _SunwhirlAppState extends State<SunwhirlApp> {
  int _selectedIndex = 0;

  final List<Widget> _screens = const [
    MapScreen(),
    SearchScreen(),
    TimeScreen(),
  ];

  void _onItemTapped(int index) {
    setState(() => _selectedIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sunwhirl',
      theme: ThemeData(
        primarySwatch: Colors.orange,
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.orange),
      ),
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: IndexedStack(index: _selectedIndex, children: _screens),
        bottomNavigationBar: BottomNavigationBar(
          currentIndex: _selectedIndex,
          onTap: _onItemTapped,
          type: BottomNavigationBarType.fixed,
          selectedItemColor: Theme.of(context).colorScheme.primary,
          unselectedItemColor: Colors.grey,
          items: const [
            BottomNavigationBarItem(icon: Icon(Icons.map), label: 'Map'),
            BottomNavigationBarItem(icon: Icon(Icons.search), label: 'Search'),
            BottomNavigationBarItem(icon: Icon(Icons.access_time), label: 'Time'),
          ],
        ),
      ),
    );
  }
}
