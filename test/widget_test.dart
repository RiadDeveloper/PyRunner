// Smoke test: the app boots through the splash to the home screen.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pyrunner/main.dart';
import 'package:pyrunner/services/python_service.dart';
import 'package:pyrunner/services/settings_service.dart';

void main() {
  testWidgets('Home screen shows the PyRunner title', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService();
    await settings.init();
    final python = PythonService();
    // Do not call python.init() here: there is no platform channel in tests.
    // Give the home screen a tall viewport so the whole ListView lays
    // out at once (its children are built lazily, so below-the-fold
    // widgets like 'Your projects' would otherwise not exist yet).
    tester.view.physicalSize = const Size(800, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      PyRunnerApp(settings: settings, python: python),
    );
    await tester.pump();

    // Splash first (v1.0.9): no typing — the developer name fades in
    // with the rest, then the home screen (splash lasts ~2.0 s).
    await tester.pump(const Duration(milliseconds: 1000));
    expect(find.text('Riad developer'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('PyRunner'), findsWidgets);
    expect(find.text('Your projects'), findsOneWidget);
    expect(find.text('Open folder (in place)'), findsOneWidget);
    expect(find.text('Import a copy'), findsOneWidget);
    // Let the staggered entrance animations (flutter_animate uses
    // Future.delayed for their delays) fire before teardown, otherwise
    // the test binding reports a pending Timer.
    await tester.pump(const Duration(milliseconds: 600));
  });
}
