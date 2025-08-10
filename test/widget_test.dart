import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:sunwhirlv1/main.dart';
import 'package:sunwhirlv1/providers/map_state.dart';

void main() {
  testWidgets('SunwhirlApp shows navigation tabs', (WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => MapState(),
        child: const SunwhirlApp(),
      ),
    );

    expect(find.byType(BottomNavigationBar), findsOneWidget);
    expect(find.text('Map'), findsOneWidget);
    expect(find.text('Search'), findsOneWidget);
    expect(find.text('Time'), findsOneWidget);
  });
}
