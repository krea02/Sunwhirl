import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:provider/provider.dart'; // Import Provider

import 'screens/map_screen.dart';
import 'screens/search_screen.dart';
import 'screens/time_screen.dart';
import 'providers/map_state.dart'; // Import MapState

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // SAFELY get the token from build arguments
  const String token = String.fromEnvironment("ACCESS_TOKEN");
  if (token.isEmpty) {
    // Handle missing token case - show error, exit, etc.
    print("Error: ACCESS_TOKEN environment variable not set during build!");
    // runApp(ErrorApp("Mapbox Token Missing")); // Example error app
    return;
  }
  MapboxOptions.setAccessToken(token);

  // Wrap the app with the Provider
  runApp(
    ChangeNotifierProvider(
      create: (context) => MapState(),
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

  // Screens now access state via Provider, no need to pass everything down
  final List<Widget> _screens = [
    const MapScreen(), // Removed constructor args
    const SearchScreen(), // Removed constructor args
    const TimeScreen(), // Removed constructor args
  ];

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Access provider for initial setup if needed, or let screens handle it
    // final mapState = Provider.of<MapState>(context, listen: false);

    return MaterialApp(
      title: 'Sunwhirl',
      theme: ThemeData(
        primarySwatch: Colors.orange,
        useMaterial3: true, // Recommended for modern Flutter
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.orange),
      ),
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        // Keep the body switching logic
        body: IndexedStack( // Use IndexedStack to preserve state of screens
          index: _selectedIndex,
          children: _screens,
        ),
        // BottomNavigationBar remains the same
        bottomNavigationBar: BottomNavigationBar(
          currentIndex: _selectedIndex,
          onTap: _onItemTapped, // Use the method here
          type: BottomNavigationBarType.fixed,
          selectedItemColor: Theme.of(context).colorScheme.primary, // Use theme color
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