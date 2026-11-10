// Settings screen (v1.0.4): every control is wired to real behaviour.
// Changing a setting here must change the service (and persist it).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pyrunner/app_info.dart';
import 'package:pyrunner/screens/settings_screen.dart';
import 'package:pyrunner/services/python_service.dart';
import 'package:pyrunner/services/settings_service.dart';

void main() {
  late SettingsService settings;
  late PythonService python;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService();
    await settings.init();
    python = PythonService();
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(settings: settings, python: python),
      ),
    );
    await tester.pump();
  }

  testWidgets('About shows the version and the developer name',
      (tester) async {
    await pumpSettings(tester);

    // The About card reads the version from AppInfo (single source),
    // so this follows the pubspec bump instead of hardcoding it.
    expect(find.text('Version ${AppInfo.version}'), findsOneWidget);
    expect(find.text('Riad developer'), findsOneWidget);
    expect(find.text('PyRunner'), findsWidgets);
  });

  testWidgets('turning autosave off takes effect and persists',
      (tester) async {
    await pumpSettings(tester);
    expect(settings.autosave, isTrue);

    await tester.tap(find.text('Autosave'));
    await tester.pump();

    expect(settings.autosave, isFalse);
    // Persisted: a fresh service reading the same mock prefs sees it.
    final reloaded = SettingsService();
    await reloaded.init();
    expect(reloaded.autosave, isFalse);
  });

  testWidgets('autosave delay chips change the delay', (tester) async {
    await pumpSettings(tester);
    expect(settings.autosaveDelayMs, 1200);

    await tester.tap(find.text('3s'));
    await tester.pump();

    expect(settings.autosaveDelayMs, 3000);
  });

  testWidgets('theme switch changes the theme', (tester) async {
    await pumpSettings(tester);
    expect(settings.theme, 'dark');

    await tester.tap(find.text('Light'));
    await tester.pump();

    expect(settings.theme, 'light');
    expect(settings.isDarkMode, isFalse);
  });

  testWidgets('indent size 2 takes effect', (tester) async {
    await pumpSettings(tester);
    expect(settings.indentSize, 4);

    await tester.tap(find.text('2 spaces'));
    await tester.pump();

    expect(settings.indentSize, 2);
  });

  testWidgets('reset restores the defaults', (tester) async {
    await pumpSettings(tester);
    await settings.setAutosave(false);
    await settings.setIndentSize(2);
    await settings.setTheme('light');
    await tester.pump();

    expect(settings.autosave, isFalse);

    await tester.tap(find.text('Reset settings to defaults'));
    await tester.pump();
    // Confirm dialog.
    await tester.tap(find.text('Reset'));
    await tester.pump();

    expect(settings.autosave, isTrue);
    expect(settings.indentSize, 4);
    expect(settings.theme, 'dark');
    expect(settings.autosaveDelayMs, 1200);
  });
}
