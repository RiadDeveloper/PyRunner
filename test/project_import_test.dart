// Regression tests for the folder-import bug (v1.0.0 -> v1.0.1).
//
// v1.0.0 created the target directory BEFORE checking the source was
// readable, so an unreadable SAF folder left an empty "phantom" project
// behind — the file tree showed the folder with no files. The fix
// preflights the source, collects per-file failures, and deletes the
// target when nothing could be copied.
//
// path_provider is mocked so the app's projects dir points at a temp dir.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pyrunner/services/project_service.dart';

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
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    await docsDir.delete(recursive: true);
    await srcDir.delete(recursive: true);
  });

  Future<void> writeNestedSource() async {
    await File('${srcDir.path}/main.py').writeAsString('print("hi")\n');
    await File('${srcDir.path}/README.md').writeAsString('# demo\n');
    await Directory('${srcDir.path}/utils').create();
    await File('${srcDir.path}/utils/helper.py')
        .writeAsString('def h():\n    return 1\n');
    await Directory('${srcDir.path}/utils/deep').create();
    await File('${srcDir.path}/utils/deep/data.txt')
        .writeAsString('hello\n');
  }

  test('importing a folder with nested subfolders copies the full tree',
      () async {
    await writeNestedSource();
    final result = await projects.importFolder(srcDir.path);
    expect(result.success, isTrue, reason: result.error);
    expect(result.filesCopied, 4);
    expect(result.failedFiles, isEmpty);

    final project = result.project!;
    expect(await File('${project.path}/main.py').exists(), isTrue);
    expect(await File('${project.path}/utils/helper.py').exists(), isTrue);
    expect(
      await File('${project.path}/utils/deep/data.txt').exists(),
      isTrue,
    );
    expect(
      await File('${project.path}/utils/helper.py').readAsString(),
      contains('def h():'),
    );

    // The project shows up in the list with its files (the tree data).
    final listed = await projects.listProjects();
    expect(listed.map((p) => p.name), contains(project.name));
    final children = await projects
        .listChildren(Directory(project.path));
    expect(children.length, 3); // main.py, README.md, utils/
  });

  test('unreadable source fails cleanly and leaves no phantom project',
      () async {
    final missing = Directory('${srcDir.path}/does-not-exist');
    final result = await projects.importFolder(missing.path);
    expect(result.success, isFalse);
    expect(result.error, isNotNull);

    final listed = await projects.listProjects();
    expect(listed, isEmpty);
  });

  test('one broken file does not abort the import; it is reported',
      () async {
    await File('${srcDir.path}/good.py').writeAsString('x = 1\n');
    // Dangling symlink: copying it throws, the good file must still copy.
    await Link('${srcDir.path}/broken.py').create('/nonexistent-target');
    final result = await projects.importFolder(srcDir.path);
    expect(result.success, isTrue, reason: result.error);
    expect(result.filesCopied, 1);
    expect(result.failedFiles, contains('broken.py'));
    expect(
      await File('${result.project!.path}/good.py').exists(),
      isTrue,
    );
  });

  test(
    'Guest_gen-main shape: a single wrapper folder is unwrapped so '
    'main.py lands at the project root',
    () async {
      // The user picked the folder that CONTAINS Guest_gen-main (or a
      // GitHub zip's root folder): the source holds exactly one
      // directory and no files. v1.0.2 left the project doubled
      // (.../Guest_gen-main/Guest_gen-main/main.py) so main.py and
      // requirements.txt were not at the project root.
      final wrapper = Directory('${srcDir.path}/Guest_gen-main');
      await wrapper.create();
      await File('${wrapper.path}/main.py')
          .writeAsString('print("hi")\n');
      await File('${wrapper.path}/requirements.txt')
          .writeAsString('pycryptodome>=3.20.0\n');
      await Directory('${wrapper.path}/utils').create();
      await File('${wrapper.path}/utils/helper.py')
          .writeAsString('def h():\n    return 1\n');

      final result = await projects.importFolder(srcDir.path);
      expect(result.success, isTrue, reason: result.error);
      expect(result.flattened, isTrue);

      final project = result.project!;
      expect(await File('${project.path}/main.py').exists(), isTrue);
      expect(
        await File('${project.path}/requirements.txt').exists(),
        isTrue,
      );
      expect(
        await File('${project.path}/utils/helper.py').exists(),
        isTrue,
      );
      expect(
        await Directory('${project.path}/Guest_gen-main').exists(),
        isFalse,
      );
    },
  );

  test(
    'GitHub zip shape: a single top-level folder is unwrapped',
    () async {
      // extractArchiveToDisk never strips the zip's root folder, so a
      // GitHub zip (Guest_gen-main/main.py, ...) used to import as
      // .../Guest_gen-main/Guest_gen-main/main.py.
      final zipPath = '${srcDir.path}/Guest_gen-main.zip';
      final archive = Archive();
      for (final entry in {
        'Guest_gen-main/main.py': 'print("hi")\n',
        'Guest_gen-main/requirements.txt': 'pycryptodome>=3.20.0\n',
        'Guest_gen-main/utils/helper.py': 'def h():\n    return 1\n',
      }.entries) {
        archive.addFile(
          ArchiveFile(
            entry.key,
            entry.value.length,
            utf8.encode(entry.value),
          ),
        );
      }
      await File(zipPath).writeAsBytes(ZipEncoder().encode(archive));

      final result = await projects.importZip(zipPath);
      expect(result.success, isTrue, reason: result.error);
      expect(result.flattened, isTrue);

      final project = result.project!;
      expect(await File('${project.path}/main.py').exists(), isTrue);
      expect(
        await File('${project.path}/requirements.txt').exists(),
        isTrue,
      );
      expect(
        await File('${project.path}/utils/helper.py').exists(),
        isTrue,
      );
      expect(
        await Directory('${project.path}/Guest_gen-main').exists(),
        isFalse,
      );
    },
  );
}
