// PyRunner v1.0.10 regression + robustness tests.
//
// The bug (2026-11-10): the sample project died at its first input()
// with KeyboardInterrupt although the user never pressed Stop — a
// stale STOP_SENTINEL from a previous run's stop poisoned the next
// run's input(). The bridge fix (readline discards a stale sentinel)
// is covered by the bridge harness (section 10); these tests cover
// the Dart side: console input typed while a script runs must feed
// the script's stdin and never stop it, a run stops only via Stop /
// `stop` / Ctrl+C, and a second run after a stopped run works.
//
// Also: entry-point detection, templates, .zip export, run args,
// `doctor`, `open`/`edit`, and the 5000-line console cap.

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pyrunner/models.dart';
import 'package:pyrunner/services/console_log_store.dart';
import 'package:pyrunner/services/console_service.dart';
import 'package:pyrunner/services/project_service.dart';
import 'package:pyrunner/services/python_service.dart';
import 'package:pyrunner/services/settings_service.dart';

void main() {
  group('console input routing (v1.0.10, A)', () {
    late Directory docsDir;
    late Directory projDir;
    late PythonService python;
    late ConsoleService console;
    late List<MethodCall> methodCalls;
    MockStreamHandlerEventSink? eventSink;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      docsDir = await Directory.systemTemp.createTemp('pyrunner-docs-');
      projDir = await Directory.systemTemp.createTemp('pyrunner-proj-');
      await File('${projDir.path}/main.py')
          .writeAsString('print("hi")\n');
      methodCalls = [];
      eventSink = null;
    });

    tearDown(() async {
      // initServices runs first in every test body; if a test failed
      // before it, the late fields are uninitialized — tolerate that.
      try {
        console.dispose();
      } catch (_) {}
      try {
        python.dispose();
      } catch (_) {}
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('com.pyrunner.app/python'),
        null,
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(
        const EventChannel('com.pyrunner.app/python_output'),
        null,
      );
      await docsDir.delete(recursive: true);
      await projDir.delete(recursive: true);
    });

    /// Create the services inside the test body and pump once so the
    /// EventChannel subscription is live. The channel mocks are
    /// registered here too (not in setUp): a mock stream handler
    /// registered in setUp captures the subscription, but events sent
    /// through its sink never reach the service — they are silently
    /// dropped. Registering the mocks in the test body, immediately
    /// before python.init(), is the pattern python_service_test uses
    /// and the only one that delivers events.
    Future<void> initServices(WidgetTester tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async {
          if (call.method == 'getApplicationDocumentsDirectory' ||
              call.method == 'getTemporaryDirectory') {
            return docsDir.path;
          }
          return null;
        },
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('com.pyrunner.app/python'),
        (call) async {
          methodCalls.add(call);
          switch (call.method) {
            case 'runScript':
            case 'runModule':
            case 'pipInstall':
              return 0;
            case 'pipList':
              return 'Package    Version\n'
                  '---------- -------\n'
                  'pip        26.3\n';
            case 'installedPackages':
              return 'pycryptodome==3.21.0\nrequests==2.31.0\n';
            case 'pythonVersion':
              return '3.13.16';
            case 'ensurePython':
              return true;
            default:
              return null;
          }
        },
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(
        const EventChannel('com.pyrunner.app/python_output'),
        MockStreamHandler.inline(
          onListen: (args, events) {
            eventSink = events;
          },
        ),
      );
      python = PythonService();
      python.init();
      console = ConsoleService(
        project: Project(name: 't', path: projDir.path),
        python: python,
        projects: ProjectService(),
      );
      await tester.pump();
      expect(eventSink, isNotNull);
    }

    Future<void> pumpEvents(WidgetTester tester) async {
      await tester.pump();
    }

    void sendEvent(String name, String text) {
      eventSink!.success({'type': 'event', 'name': name, 'text': text});
    }

    /// Drive a script run into the "running, not waiting" state —
    /// exactly the state after a dropped input_request event.
    Future<void> startScriptRun(WidgetTester tester) async {
      sendEvent('run_started', projDir.path);
      await pumpEvents(tester);
      expect(python.isRunning, isTrue);
      expect(python.isScriptRunning, isTrue);
      expect(python.waitingForInput, isFalse);
    }

    bool called(String method, [String? line]) {
      return methodCalls.any((c) =>
          c.method == method &&
          (line == null || c.arguments['line'] == line));
    }

    testWidgets(
        'text typed while a script runs feeds stdin, never stops it',
        (tester) async {
          await initServices(tester);
      await startScriptRun(tester);

      await console.execute('Riad');
      await tester.pump();

      expect(called('feedInput', 'Riad'), isTrue);
      expect(called('stopRun'), isFalse);
      // The line is echoed as input, not treated as a command.
      expect(
        python.lines.any((l) =>
            l.kind == ConsoleKind.input && l.text == 'Riad'),
        isTrue,
      );
      expect(
        python.lines.any((l) => l.text.contains('Command not found')),
        isFalse,
      );
    });

    testWidgets('`stop` while a script runs stops it; other text does not',
        (tester) async {
          await initServices(tester);
      await startScriptRun(tester);

      await console.execute('stop');
      await tester.pump();
      expect(called('stopRun'), isTrue);
      expect(called('feedInput'), isFalse);
    });

    testWidgets('text while waiting for input feeds stdin (existing path)',
        (tester) async {
          await initServices(tester);
      await startScriptRun(tester);
      sendEvent('input_request', '');
      await pumpEvents(tester);
      expect(python.waitingForInput, isTrue);

      await console.execute('Riad');
      await tester.pump();

      expect(called('feedInput', 'Riad'), isTrue);
      expect(called('stopRun'), isFalse);
    });

    testWidgets('a second run after a stopped run accepts input',
        (tester) async {
          await initServices(tester);
      await startScriptRun(tester);
      sendEvent('run_finished', '${projDir.path}|130');
      await pumpEvents(tester);
      expect(python.isRunning, isFalse);

      // The next run starts clean: no stale stop state.
      await startScriptRun(tester);
      await console.execute('Riad');
      await tester.pump();
      expect(called('feedInput', 'Riad'), isTrue);
      expect(called('stopRun'), isFalse);
    });

    testWidgets('`python main.py` while a script runs goes to stdin, not a new run',
        (tester) async {
          await initServices(tester);
      await startScriptRun(tester);

      await console.execute('python main.py');
      await tester.pump();

      // Type-ahead (v1.0.10): the text is stdin for the running
      // script — a second run is never queued behind it.
      expect(called('runScript'), isFalse);
      expect(called('feedInput', 'python main.py'), isTrue);
      expect(
        python.lines.any((l) =>
            l.kind == ConsoleKind.input && l.text == 'python main.py'),
        isTrue,
      );
    });

    testWidgets('`python main.py` during a pip run is refused, not queued',
        (tester) async {
      await initServices(tester);
      // A pip run is in flight: isRunning but NOT a script run, so
      // type-ahead does not apply and the guard in _python answers.
      sendEvent('run_started', 'pip install');
      await tester.pump();
      expect(python.isRunning, isTrue);
      expect(python.isScriptRunning, isFalse);

      await console.execute('python main.py');
      await tester.pump();

      expect(called('runScript'), isFalse);
      expect(
        python.lines.any(
            (l) => l.text.contains('already running')),
        isTrue,
      );
    });

    testWidgets('Ctrl+D (sendEof) feeds the EOF sentinel',
        (tester) async {
          await initServices(tester);
      await startScriptRun(tester);

      await console.sendEof();
      await tester.pump();

      expect(called('feedInput', PythonService.eofSentinel), isTrue);
      expect(called('stopRun'), isFalse);
    });

    testWidgets('sendEof is a no-op when nothing runs', (tester) async {
      await initServices(tester);
      await tester.pump();
      await console.sendEof();
      await tester.pump();
      expect(called('feedInput'), isFalse);
    });

    testWidgets('`open <file>` opens the file in the editor',
        (tester) async {
          await initServices(tester);
      var opened = '';
      console.onOpenFile = (path) => opened = path;
      await tester.pump();

      await console.execute('open main.py');
      await tester.pump();

      expect(opened, '${projDir.path}/main.py');
      expect(
        python.lines.any((l) => l.text.contains('Opened main.py')),
        isTrue,
      );
    });

    testWidgets('`doctor` reports Python, pip, Crypto, entry, requirements',
        (tester) async {
          await initServices(tester);
      // Real file I/O inside testWidgets must run in runAsync (the
      // real async zone): awaiting it directly in the fake-async test
      // zone stalls forever.
      await tester.runAsync(() async {
        await File('${projDir.path}/requirements.txt')
            .writeAsString('requests\npycryptodome>=3.20.0\n');
      });
      await tester.pump();
      await tester.runAsync(() async {
        await console.execute('doctor');
      });
      await tester.pump();

      final text = python.lines.map((l) => l.text).join('\n');
      expect(text, contains('Python 3.13.16'));
      expect(text, contains('pip is available'));
      expect(text, contains('pycryptodome 3.21.0 is installed'));
      expect(text, contains('Project folder is readable'));
      expect(text, contains('Entry file: main.py'));
      expect(text, contains('requirements.txt: all 2 package(s) installed'));
    });

    testWidgets('`doctor` flags a missing requirement', (tester) async {
      await initServices(tester);
      // Real file I/O inside testWidgets must run in runAsync (see
      // the `doctor` reports test above).
      await tester.runAsync(() async {
        await File('${projDir.path}/requirements.txt')
            .writeAsString('requests\nnumpy\n');
      });
      await tester.pump();
      await tester.runAsync(() async {
        await console.execute('doctor');
      });
      await tester.pump();

      final text = python.lines.map((l) => l.text).join('\n');
      expect(text, contains('missing numpy'));
    });

  });


  group('entry-point detection (v1.0.10, B)', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('pyrunner-entry-');
    });

    tearDown(() async {
      await dir.delete(recursive: true);
    });

    test('main.py wins', () async {
      await File('${dir.path}/main.py').writeAsString('print(1)\n');
      await File('${dir.path}/app.py').writeAsString('print(2)\n');
      expect(ProjectService.resolveEntryFile(dir.path),
          '${dir.path}/main.py');
    });

    test('__main__.py when there is no main.py', () async {
      await File('${dir.path}/__main__.py').writeAsString('print(1)\n');
      expect(ProjectService.resolveEntryFile(dir.path),
          '${dir.path}/__main__.py');
    });

    test('app.py when there is no main.py or __main__.py', () async {
      await File('${dir.path}/app.py').writeAsString('print(1)\n');
      expect(ProjectService.resolveEntryFile(dir.path),
          '${dir.path}/app.py');
    });

    test('a single .py file is the entry', () async {
      await File('${dir.path}/tool.py').writeAsString('print(1)\n');
      expect(ProjectService.resolveEntryFile(dir.path),
          '${dir.path}/tool.py');
    });

    test('several .py files and no known entry -> null', () async {
      await File('${dir.path}/a.py').writeAsString('print(1)\n');
      await File('${dir.path}/b.py').writeAsString('print(2)\n');
      expect(ProjectService.resolveEntryFile(dir.path), isNull);
    });

    test('configured entry wins over main.py', () async {
      await File('${dir.path}/main.py').writeAsString('print(1)\n');
      await File('${dir.path}/start.py').writeAsString('print(2)\n');
      expect(
        ProjectService.resolveEntryFile(
          dir.path,
          configured: '${dir.path}/start.py',
        ),
        '${dir.path}/start.py',
      );
    });

    test('a missing configured entry falls back to main.py', () async {
      await File('${dir.path}/main.py').writeAsString('print(1)\n');
      expect(
        ProjectService.resolveEntryFile(
          dir.path,
          configured: '${dir.path}/gone.py',
        ),
        '${dir.path}/main.py',
      );
    });

    test('empty project -> null', () {
      expect(ProjectService.resolveEntryFile(dir.path), isNull);
    });
  });

  group('new-project templates (v1.0.10, C)', () {
    late Directory docsDir;
    late ProjectService projects;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      docsDir = await Directory.systemTemp.createTemp('pyrunner-docs-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async {
          if (call.method == 'getApplicationDocumentsDirectory' ||
              call.method == 'getTemporaryDirectory') {
            return docsDir.path;
          }
          return null;
        },
      );
      projects = ProjectService();
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      await docsDir.delete(recursive: true);
    });

    test('hello template: greeting + input', () async {
      final project = await projects.createProject(
        'hello-t',
        template: ProjectService.templateById('hello'),
      );
      final main = await File('${project.path}/main.py').readAsString();
      expect(main, contains('Hello from PyRunner!'));
      expect(main, contains('input('));
      expect(File('${project.path}/README.md').existsSync(), isTrue);
    });

    test('cli template: argparse', () async {
      final project = await projects.createProject(
        'cli-t',
        template: ProjectService.templateById('cli'),
      );
      final main = await File('${project.path}/main.py').readAsString();
      expect(main, contains('argparse'));
      expect(main, contains('--name'));
      expect(main, contains('--count'));
    });

    test('data template: input + file output', () async {
      final project = await projects.createProject(
        'data-t',
        template: ProjectService.templateById('data'),
      );
      final main = await File('${project.path}/main.py').readAsString();
      expect(main, contains('input('));
      expect(main, contains('output.csv'));
      expect(main, contains('__file__'));
    });
  });

  group('share project as .zip (v1.0.10, C)', () {
    late Directory docsDir;
    late ProjectService projects;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      docsDir = await Directory.systemTemp.createTemp('pyrunner-docs-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async {
          if (call.method == 'getApplicationDocumentsDirectory' ||
              call.method == 'getTemporaryDirectory') {
            return docsDir.path;
          }
          return null;
        },
      );
      projects = ProjectService();
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      await docsDir.delete(recursive: true);
    });

    test('the .zip holds every project file', () async {
      final project = await projects.createProject('zip-t');
      await File('${project.path}/main.py').writeAsString('print(1)\n');
      await Directory('${project.path}/utils').create();
      await File('${project.path}/utils/helper.py')
          .writeAsString('def h():\n    return 1\n');
      await File('${project.path}/requirements.txt')
          .writeAsString('requests\n');

      final zipFile = await projects.buildExportZip(project);
      expect(zipFile, isNotNull);
      expect(zipFile!.existsSync(), isTrue);

      final archive =
          ZipDecoder().decodeBytes(await zipFile.readAsBytes());
      final names = archive.files.map((f) => f.name).toList();
      expect(names.any((n) => n.endsWith('main.py')), isTrue);
      expect(names.any((n) => n.endsWith('utils/helper.py')), isTrue);
      expect(names.any((n) => n.endsWith('requirements.txt')), isTrue);
    });
  });

  group('run arguments (v1.0.10, C)', () {
    test('split on whitespace, quotes honoured', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService();
      await settings.init();

      await settings.setRunArgs('/p', '--name "John Doe" --count 3');
      expect(settings.runArgsFor('/p'), '--name "John Doe" --count 3');
      expect(
        settings.runArgsListFor('/p'),
        ['--name', 'John Doe', '--count', '3'],
      );

      await settings.setRunArgs('/p', '');
      expect(settings.runArgsFor('/p'), '');
      expect(settings.runArgsListFor('/p'), isEmpty);
    });
  });

  group('console log cap (v1.0.10, B)', () {
    test('the store keeps at most 5000 lines', () {
      final store = ConsoleLogStore();
      for (var i = 0; i < 5001; i++) {
        store.add('/p', ConsoleKind.output, 'line $i');
      }
      final lines = store.linesFor('/p');
      expect(lines.length, 5000);
      expect(lines.first.text, 'line 1');
      expect(lines.last.text, 'line 5000');
    });
  });
}
