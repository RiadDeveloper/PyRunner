// In-place projects (v1.0.4, A): a folder opened with all-files
// access stays where it is — nothing is copied, and deleting it from
// the list never deletes the folder. Plus the manual tree refresh (B).
//
// path_provider is mocked so the app's projects dir points at a temp dir.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pyrunner/models.dart';
import 'package:pyrunner/screens/project_screen.dart';
import 'package:pyrunner/services/project_service.dart';
import 'package:pyrunner/services/python_service.dart';
import 'package:pyrunner/services/settings_service.dart';

void main() {
  late Directory docsDir;
  late Directory srcDir;
  late ProjectService projects;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    docsDir = await Directory.systemTemp.createTemp('pyrunner-docs-');
    srcDir = await Directory.systemTemp.createTemp('pyrunner-src-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationDocumentsDirectory') {
          return docsDir.path;
        }
        return null;
      },
    );
    projects = ProjectService();
    await File('${srcDir.path}/main.py').writeAsString('print("hi")\n');
    await Directory('${srcDir.path}/utils').create();
    await File('${srcDir.path}/utils/helper.py')
        .writeAsString('def h():\n    return 1\n');
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    // The pruning test deletes srcDir itself; delete both dirs
    // tolerantly so a missing dir can never fail cleanup (an
    // exists() check followed by delete() can race when the test
    // already removed the folder).
    for (final dir in [docsDir, srcDir]) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {
        // Already gone: nothing to clean up.
      }
    }
  });

  test('openInPlace opens the original folder without copying', () async {
    final project = await projects.openInPlace(srcDir.path);

    expect(project, isNotNull);
    expect(project!.inPlace, isTrue);
    expect(project.path, srcDir.path);
    expect(project.name, srcDir.path.split('/').last);

    // Nothing was copied into the private workspace.
    final private = Directory('${docsDir.path}/projects');
    final copied = private.existsSync()
        ? await private.list().toList()
        : <FileSystemEntity>[];
    expect(copied, isEmpty);

    // It shows in the project list, flagged in place.
    final listed = await projects.listProjects();
    expect(listed.map((p) => p.path), contains(srcDir.path));
    expect(
      listed.firstWhere((p) => p.path == srcDir.path).inPlace,
      isTrue,
    );
  });

  test('deleting an in-place project never deletes the folder',
      () async {
    final project = (await projects.openInPlace(srcDir.path))!;
    expect(await projects.deleteProject(project), isTrue);

    // The original folder and its files are untouched.
    expect(await Directory(srcDir.path).exists(), isTrue);
    expect(await File('${srcDir.path}/main.py').exists(), isTrue);
    expect(await File('${srcDir.path}/utils/helper.py').exists(), isTrue);

    // And it is gone from the list.
    final listed = await projects.listProjects();
    expect(listed.map((p) => p.path), isNot(contains(srcDir.path)));
  });

  test('renaming an in-place project is refused', () async {
    final project = (await projects.openInPlace(srcDir.path))!;

    expect(await projects.renameProject(project, 'new-name'), isFalse);
    expect(await Directory(srcDir.path).exists(), isTrue);
  });

  test('in-place folders that disappear are pruned from the list',
      () async {
    await projects.openInPlace(srcDir.path);
    await srcDir.delete(recursive: true);

    final listed = await projects.listProjects();
    expect(listed, isEmpty);

    // A second listing stays empty (the registry entry is gone).
    expect(await projects.listProjects(), isEmpty);
  });

  test('openInPlace returns null for an unreadable folder', () async {
    final missing = '${docsDir.path}/no-such-folder';
    expect(await projects.openInPlace(missing), isNull);
    expect(await projects.listProjects(), isEmpty);
  });

  group('ProjectScreen with an in-place project', () {
    late SettingsService settings;
    late PythonService python;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = SettingsService();
      await settings.init();
      python = PythonService();
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
    });

    tearDown(() {
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
            project: Project(
              name: 'src',
              path: srcDir.path,
              inPlace: true,
            ),
            python: python,
            settings: settings,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 500));
    }

    testWidgets('the tree lists the original folder', (tester) async {
      await pumpProject(tester);

      expect(find.text('main.py'), findsWidgets);
      expect(find.text('helper.py'), findsOneWidget);
    });

    testWidgets(
        'Refresh shows a file created after opening (the 13:24 bug)',
        (tester) async {
      await pumpProject(tester);
      expect(find.text('generated.json'), findsNothing);

      // A script (or anything else) creates a file in the original
      // folder while the project is open. (Synchronous write: async
      // dart:io never completes inside flutter_test's fake-async zone
      // on this machine — see the note below.)
      File('${srcDir.path}/generated.json')
          .writeAsStringSync('{"accounts": []}\n');

      // The manual refresh button in the file panel header.
      await tester.tap(find.text('Refresh').first);
      await tester.pump();

      expect(find.text('generated.json'), findsOneWidget);
    });

    // Autosave now writes synchronously (_saveTab), so the debounced
    // write completes inside the test's fake-async zone.
    testWidgets('autosave writes to the ORIGINAL file path',
        (tester) async {
      await pumpProject(tester);
      expect(find.text('main.py'), findsWidgets);

      // Edit the open main.py tab (the editor's EditableText is the
      // first one in the tree; the console input is the second).
      final editor = find.byType(EditableText).first;
      await tester.enterText(editor, 'print("edited in place")\n');
      // The text arrives via a simulated platform message: pump once
      // so the change is delivered and the autosave debounce starts,
      // then pump past the 1.2s debounce.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1300));
      await tester.pump();

      expect(
        File('${srcDir.path}/main.py').readAsStringSync(),
        'print("edited in place")\n',
      );
    });
  });
}
