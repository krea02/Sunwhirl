import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:provider/provider.dart';

import 'screens/map_screen.dart';
import 'screens/search_screen.dart';
import 'screens/time_screen.dart';
import 'providers/map_state.dart';
import 'services/terrain_elevation_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Intl date symbols for the locales you use in UI/formatting.
  // This prevents "LocaleDataException: locale data has not been initialized".
  await Future.wait([
    initializeDateFormatting('en'),
    initializeDateFormatting('sl'),
    initializeDateFormatting('hr'),
    initializeDateFormatting('sr'),
  ]);

  // Safely get the Mapbox token from build arguments
  const String token = String.fromEnvironment("ACCESS_TOKEN");

  if (token.isEmpty) {
    // Visible fallback so the app still runs and shows a helpful message.
    runApp(const _TokenErrorApp());
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
      debugShowCheckedModeBanner: false,

      // ✅ Localizations so Material/Widgets (and DateFormat) work with en/sl/hr/sr
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('en'),
        Locale('sl'),
        Locale('hr'),
        Locale('sr'),
      ],
// ✅ Correct: gets a List<Locale> (or null)
      localeListResolutionCallback: (locales, supported) {
        if (locales != null && locales.isNotEmpty) {
          for (final loc in locales) {
            for (final s in supported) {
              if (s.languageCode == loc.languageCode) return s;
            }
          }
        }
        return const Locale('en'); // fallback
      },


      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.orange),
      ),

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

/// Minimal app to show an error if ACCESS_TOKEN wasn't provided at build time.
class _TokenErrorApp extends StatelessWidget {
  const _TokenErrorApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sunwhirl',
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 500),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Icon(Icons.error_outline, size: 56, color: Colors.redAccent),
                  SizedBox(height: 16),
                  Text(
                    'ACCESS_TOKEN was not provided.\n\n'
                        'Build the app with:\n'
                        'flutter run --dart-define=ACCESS_TOKEN=YOUR_MAPBOX_TOKEN',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
