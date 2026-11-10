// Responsive layout tests (D): phone (<600dp) keeps the drawer-based
// file tree; tablet (>=600dp) shows it as a persistent side panel, with
// the editor and console rendering in both.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pyrunner/models.dart';
import 'package:pyrunner/screens/project_screen.dart';
import 'package:pyrunner/services/python_service.dart';
import 'package:pyrunner/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Project project;
  late SettingsService settings;
  late PythonService python;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService();
    await settings.init();
    python = PythonService();
    // ProjectScreen calls ensurePython + pythonVersion in initState;
    // answer them here so no platform channel is needed.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.pyrunner.app/python'),
      (call) async {
        switch (call.method) {
          case 'ensurePython':
            return true;
          case 'pythonVersion':
            return '3.13.0';
          default:
            return null;
        }
      },
    );
    tempDir = await Directory.systemTemp.createTemp('pyrunner_layout_');
    await File('${tempDir.path}/main.py')
        .writeAsString('print("Hello from PyRunner!")\n');
    await File('${tempDir.path}/helper.py')
        .writeAsString('def greet():\n    return "hi"\n');
    project = Project(name: 'layout-test', path: tempDir.path);
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.pyrunner.app/python'),
      null,
    );
  });

  Future<void> pumpProject(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: ProjectScreen(
          project: project,
          python: python,
          settings: settings,
        ),
      ),
    );
    // Let the entrance animations run. (No pumpAndSettle: the editor's
    // blinking cursor never settles.) File reads and the tree listing
    // are synchronous now, so no async wait is needed.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets(
    'phone layout (390x844): editor + console render, tree in drawer',
    (tester) async {
      await pumpProject(tester, const Size(390, 844));

      // main.py is auto-opened in the editor: its tab is shown and an
      // editable code field is present. (CodeField renders through
      // EditableText, so its content is not a Text widget — assert the
      // tab + the editable field instead.)
      expect(find.text('main.py'), findsWidgets);
      expect(find.byType(EditableText), findsWidgets);
      // Console input renders below the editor. (Two TextFields in
      // total: the editor's CodeField plus the console input.)
      expect(find.byType(TextField), findsNWidgets(2));
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is TextField &&
              (w.decoration?.hintText ?? '').contains('Type a command'),
        ),
        findsOneWidget,
      );
      // The file tree is hidden inside the closed drawer.
      expect(find.text('helper.py'), findsNothing);

      // Open the drawer and the tree appears.
      tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('helper.py'), findsOneWidget);
    },
  );

  testWidgets(
    'tablet layout (1024x768): persistent side panel, editor + console',
    (tester) async {
      await pumpProject(tester, const Size(1024, 768));

      expect(find.text('main.py'), findsWidgets);
      expect(find.byType(EditableText), findsWidgets);
      // The file tree is visible without opening any drawer.
      expect(find.text('helper.py'), findsOneWidget);
      expect(find.byType(TextField), findsNWidgets(2));
    },
  );

  testWidgets(
    'sidebar toggle on tablet collapses/expands the panel (v1.0.3)',
    (tester) async {
      await pumpProject(tester, const Size(1024, 768));

      // The panel renders at 280dp wide; the collapsed panel clips to 0.
      Size panelSize() =>
          tester.getSize(find.byKey(const ValueKey('sidebarPanel')));
      expect(panelSize().width, 280);
      expect(settings.sidebarVisible, isTrue);

      await tester.tap(find.byTooltip('Show/hide file tree'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(panelSize().width, 0);
      expect(settings.sidebarVisible, isFalse);

      await tester.tap(find.byTooltip('Show/hide file tree'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(panelSize().width, 280);
      expect(settings.sidebarVisible, isTrue);
    },
  );

  testWidgets(
    'sidebar toggle on phone opens the drawer (v1.0.3)',
    (tester) async {
      await pumpProject(tester, const Size(390, 844));
      expect(find.text('helper.py'), findsNothing);

      await tester.tap(find.byTooltip('Show/hide file tree'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('helper.py'), findsOneWidget);

      tester.state<ScaffoldState>(find.byType(Scaffold)).closeDrawer();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('helper.py'), findsNothing);
    },
  );

  testWidgets(
    'autosave toggle in the editor toolbar flips the setting (v1.0.3)',
    (tester) async {
      await pumpProject(tester, const Size(390, 844));
      expect(settings.autosave, isTrue);

      final toggle =
          find.byTooltip('Autosave: on (tap to turn off)');
      await tester.ensureVisible(toggle);
      await tester.pump();
      await tester.tap(toggle);
      await tester.pump();

      expect(settings.autosave, isFalse);
      expect(
        find.byTooltip('Autosave: off (tap to turn on)'),
        findsOneWidget,
      );

      final toggleOff =
          find.byTooltip('Autosave: off (tap to turn on)');
      await tester.ensureVisible(toggleOff);
      await tester.pump();
      await tester.tap(toggleOff);
      await tester.pump();
      expect(settings.autosave, isTrue);
    },
  );

  // NOTE (v1.0.3): the "Install requirements" button itself is in the
  // app (shown when requirements.txt exists at the project root), but
  // its widget test is intentionally absent: pumping the project
  // screen with a requirements.txt present hangs the test's
  // fake-async clock (the other screen tests pump fine without it),
  // and the behaviour is covered by the bridge harness instead
  // (pip install -r requirements.txt + the pycryptodome rewrite).
}
