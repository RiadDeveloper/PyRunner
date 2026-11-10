// "Run in terminal" (v1.0.4, F): the file tree's context menu on a
// .py file runs exactly that file — the console cds into the file's
// directory first, so no `cd` is needed. The entry must NOT appear for
// other file types.

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
  late List<Map<String, dynamic>> runCalls;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService();
    await settings.init();
    python = PythonService();
    runCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.pyrunner.app/python'),
      (call) async {
        switch (call.method) {
          case 'ensurePython':
            return true;
          case 'pythonVersion':
            return '3.13.0';
          case 'runScript':
            runCalls.add(
              Map<String, dynamic>.from(call.arguments as Map),
            );
            return 0;
          default:
            return null;
        }
      },
    );
    tempDir = await Directory.systemTemp.createTemp('pyrunner-runterm-');
    await File('${tempDir.path}/main.py')
        .writeAsString('print("Hello from PyRunner!")\n');
    await Directory('${tempDir.path}/utils').create();
    await File('${tempDir.path}/utils/worker.py')
        .writeAsString('print("worker")\n');
    await File('${tempDir.path}/notes.txt').writeAsString('notes\n');
    project = Project(name: 'runterm-test', path: tempDir.path);
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.pyrunner.app/python'),
      null,
    );
  });

  Future<void> pumpProject(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1024, 768);
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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> openMenuFor(WidgetTester tester, String fileName) async {
    await tester.longPress(find.text(fileName));
    await tester.pump();
    // Give the bottom sheet's slide-up animation time to settle
    // before tapping a menu item (a tap landing mid-animation can
    // hit the scrim instead and dismiss the sheet).
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('Run in terminal runs the .py file from its own folder',
      (tester) async {
    await pumpProject(tester);
    expect(find.text('worker.py'), findsOneWidget);

    await openMenuFor(tester, 'worker.py');
    expect(find.text('Run in terminal'), findsOneWidget);

    await tester.tap(find.text('Run in terminal'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(runCalls.length, 1);
    final call = runCalls.first;
    expect(call['path'], '${tempDir.path}/utils/worker.py');
    // The console cd'd into the file's directory before running it.
    expect(call['cwd'], '${tempDir.path}/utils');
    expect(call['projectDir'], tempDir.path);
  });

  testWidgets('Run in terminal is only offered for .py files',
      (tester) async {
    await pumpProject(tester);

    await openMenuFor(tester, 'notes.txt');
    expect(find.text('Run in terminal'), findsNothing);
    expect(find.text('Set as entry file'), findsNothing);

    // Dismiss the sheet, then check the .py file offers both.
    await tester.tapAt(const Offset(512, 100));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await openMenuFor(tester, 'worker.py');
    expect(find.text('Run in terminal'), findsOneWidget);
    expect(find.text('Set as entry file'), findsOneWidget);
  });
}
