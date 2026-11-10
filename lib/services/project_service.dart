import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models.dart';

/// Result of importing a folder or .zip. A failed import never leaves a
/// half-copied project behind; a partial import keeps what copied and
/// lists the files that failed, so the user is never left guessing.
class ImportResult {
  final Project? project;
  final String? error;
  final int filesCopied;
  final List<String> failedFiles;

  /// True when a single top-level wrapper folder was unwrapped, so the
  /// project contents sit at the project root (see
  /// [_unwrapSingleWrapperFolder]).
  final bool flattened;

  const ImportResult({
    this.project,
    this.error,
    this.filesCopied = 0,
    this.failedFiles = const [],
    this.flattened = false,
  });

  bool get success => project != null;
}

/// One new-project template (v1.0.10): an id, a display name and a
/// one-line description shown in the template picker.
class ProjectTemplate {
  final String id;
  final String name;
  final String description;
  const ProjectTemplate({
    required this.id,
    required this.name,
    required this.description,
  });
}

/// Projects live inside the app's private documents directory
/// (`<docs>/projects/<name>/`), so the editor, the console and Chaquopy can
/// always read and write them.  A folder picked from shared storage is
/// copied in (import); "Export" writes the project back out as a .zip
/// through the Android share sheet.
///
/// In-place projects (v1.0.4): a folder opened with all-files access
/// stays where it is — nothing is copied. The app only remembers its
/// path, in `<docs>/in_place_projects.json`, and the editor, console
/// and Chaquopy all work on the original directory. Deleting an
/// in-place project from the list only forgets it; the folder on the
/// phone is never touched.
class ProjectService extends ChangeNotifier {
  Directory? _projectsDir;

  Future<Directory> get projectsDir async {
    _projectsDir ??= Directory(
      p.join((await getApplicationDocumentsDirectory()).path, 'projects'),
    );
    if (!await _projectsDir!.exists()) {
      await _projectsDir!.create(recursive: true);
    }
    return _projectsDir!;
  }

  /// The registry of in-place project paths, next to the projects dir.
  Future<File> get _inPlaceRegistryFile async {
    final dir = await projectsDir;
    return File(p.join(p.dirname(dir.path), 'in_place_projects.json'));
  }

  Future<List<String>> _loadInPlacePaths() async {
    try {
      final file = await _inPlaceRegistryFile;
      if (!await file.exists()) return [];
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded.whereType<String>().toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveInPlacePaths(List<String> paths) async {
    try {
      final file = await _inPlaceRegistryFile;
      await file.writeAsString(jsonEncode(paths));
    } catch (_) {
      // Registry write failure: the in-memory list is still usable
      // for this session; the project just won't be remembered.
    }
  }

  Future<List<Project>> listProjects() async {
    final dir = await projectsDir;
    final out = <Project>[];
    await for (final entity in dir.list()) {
      if (entity is Directory) {
        out.add(Project(name: p.basename(entity.path), path: entity.path));
      }
    }
    // In-place projects, remembered by path. Entries whose folder no
    // longer exists are pruned from the registry.
    final inPlace = await _loadInPlacePaths();
    final kept = <String>[];
    for (final path in inPlace) {
      if (await Directory(path).exists()) {
        kept.add(path);
        if (!out.any((project) => project.path == path)) {
          out.add(
            Project(
              name: p.basename(path),
              path: path,
              inPlace: true,
            ),
          );
        }
      }
    }
    if (kept.length != inPlace.length) {
      await _saveInPlacePaths(kept);
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  /// Open a folder in place (no copy). Returns null when the folder
  /// cannot be read. The folder is remembered so it shows in the
  /// project list next time.
  Future<Project?> openInPlace(String pickedPath) async {
    final dir = Directory(pickedPath);
    try {
      if (!await dir.exists()) return null;
      await dir.list().toList();
    } catch (_) {
      return null;
    }
    final paths = await _loadInPlacePaths();
    if (!paths.contains(pickedPath)) {
      paths.add(pickedPath);
      await _saveInPlacePaths(paths);
    }
    notifyListeners();
    return Project(
      name: p.basename(pickedPath),
      path: pickedPath,
      inPlace: true,
    );
  }

  /// Entry-file detection (v1.0.10): the file `run` / Play uses when
  /// no file is open. Order: the configured entry file, then the
  /// default entry name from settings (main.py), then `__main__.py`,
  /// then `app.py`, then the project's only `.py` file (a single-file
  /// project), else null. Synchronous file checks: async dart:io
  /// never completes inside flutter_test's fake-async zone, and a run
  /// must never stall on a pending stat.
  static String? resolveEntryFile(
    String projectPath, {
    String? configured,
    String defaultName = 'main.py',
  }) {
    if (configured != null && File(configured).existsSync()) {
      return configured;
    }
    for (final name in [defaultName, '__main__.py', 'app.py']) {
      final file = File(p.join(projectPath, name));
      if (file.existsSync()) return file.path;
    }
    // Single-file project: the only .py file at the project root.
    try {
      final pyFiles = Directory(projectPath)
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.py'))
          .toList();
      if (pyFiles.length == 1) return pyFiles.first.path;
    } catch (_) {
      // Unreadable directory: no entry file.
    }
    return null;
  }

  /// New-project templates (v1.0.10): more than a blank project.
  /// Each template writes a ready-to-run main.py plus a README.
  static const templates = <ProjectTemplate>[
    ProjectTemplate(
      id: 'hello',
      name: 'Hello World',
      description: 'Print a greeting, ask for a name, count to 5.',
    ),
    ProjectTemplate(
      id: 'cli',
      name: 'CLI tool',
      description: 'A command-line tool with argparse (--name, --count).',
    ),
    ProjectTemplate(
      id: 'data',
      name: 'Data script',
      description: 'Ask for input, then write the results to a file.',
    ),
  ];

  static ProjectTemplate? templateById(String id) {
    for (final t in templates) {
      if (t.id == id) return t;
    }
    return null;
  }

  Future<void> _writeTemplate(Directory target, ProjectTemplate t) async {
    switch (t.id) {
      case 'cli':
        await File(p.join(target.path, 'main.py')).writeAsString('''"""CLI tool template.

Run it with the green Play button, or in the console:
  python main.py --name Riad --count 3
  python main.py --help
"""

import argparse


def main():
    parser = argparse.ArgumentParser(
        description="Greet someone a few times.")
    parser.add_argument("--name", default="World",
                        help="who to greet")
    parser.add_argument("--count", type=int, default=3,
                        help="how many times to greet")
    args = parser.parse_args()

    for i in range(1, args.count + 1):
        print(f"{i}. Hello, {args.name}!")


if __name__ == "__main__":
    main()
''');
        break;
      case 'data':
        await File(p.join(target.path, 'main.py')).writeAsString('''"""Data script template.

Asks for a few values, then writes them to output.csv in the
project folder. Run it and type your answers at the prompts.
"""

import csv
import os


def main():
    title = input("Report title: ").strip() or "My report"
    rows = []
    print("Enter values one per line (empty line to finish):")
    while True:
        value = input("> ").strip()
        if not value:
            break
        rows.append(value)

    out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "output.csv")
    with open(out_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["title", title])
        writer.writerow(["value"])
        for value in rows:
            writer.writerow([value])

    print(f"Wrote {len(rows)} value(s) to output.csv")


if __name__ == "__main__":
    main()
''');
        break;
      case 'hello':
      default:
        await File(p.join(target.path, 'main.py')).writeAsString('''"""Hello World template."""

print("Hello from PyRunner!")

name = input("What is your name? ")
print(f"Nice to meet you, {name}!")

for i in range(1, 6):
    print(f"Counting... {i}")

print("Done. Edit me and run again!")
''');
        break;
    }
    await File(p.join(target.path, 'README.md')).writeAsString(
        '# ${t.name}\n\nRun `python main.py` in the console, or tap the '
        'Play button.\n');
  }

  Future<Project> createProject(
    String name, {
    bool sample = false,
    ProjectTemplate? template,
  }) async {
    final dir = await projectsDir;
    var safe = name.trim().replaceAll(RegExp(r'[^\w\-. ]'), '_');
    if (safe.isEmpty) safe = 'project';
    var target = Directory(p.join(dir.path, safe));
    var n = 2;
    while (await target.exists()) {
      target = Directory(p.join(dir.path, '$safe-$n'));
      n++;
    }
    await target.create(recursive: true);
    if (template != null) {
      await _writeTemplate(target, template);
    } else if (sample) {
      await _writeSample(target);
    }
    notifyListeners();
    return Project(name: p.basename(target.path), path: target.path);
  }

  Future<void> _writeSample(Directory target) async {
    await File(p.join(target.path, 'main.py')).writeAsString('''"""PyRunner sample project.

Run it with the green Play button, or type `python main.py` in the
console below. Try `pip install -r requirements.txt` first to fetch
the `requests` package, then uncomment the demo at the bottom.
"""

import sys

print("Hello from PyRunner!")
print(f"Python {sys.version.split()[0]} running on Android")

name = input("What is your name? ")
print(f"Nice to meet you, {name}!")

for i in range(1, 6):
    print(f"Counting... {i}")

print("Done. Edit me and run again!")

# --- requests demo (needs: pip install -r requirements.txt) ---
# import requests
# r = requests.get("https://api.github.com", timeout=15)
# print("GitHub API status:", r.status_code)
# print(r.json().get("current_user_url"))
''');
    await File(p.join(target.path, 'requirements.txt'))
        .writeAsString('requests\n');
    await File(p.join(target.path, 'README.md')).writeAsString(
        '# Sample project\n\nRun `python main.py` in the console, or tap the '
        'Play button.\n');
  }

  /// Copy a user-picked folder into the private workspace.
  ///
  /// Root cause of the v1.0.0 folder bug: the old code created the target
  /// directory *before* checking the source was readable. On Android 11+
  /// a SAF-picked folder is often not directly readable, so the copy
  /// threw — but the empty target directory was left behind and showed
  /// up as a project with no files. This version preflights the source,
  /// collects per-file failures instead of aborting on the first one,
  /// and deletes the target when nothing could be copied.
  ///
  /// v1.0.3: the contents of the picked folder become the project
  /// contents, and a single top-level wrapper folder (a GitHub .zip's
  /// root folder, or a folder picked from inside its own parent) is
  /// unwrapped, so `main.py` and `requirements.txt` land at the project
  /// root instead of one level down (`.../Guest_gen-main/Guest_gen-main/
  /// main.py`, which is what the user hit on their phone).
  Future<ImportResult> importFolder(
    String pickedPath, {
    void Function(int copied)? onProgress,
  }) async {
    final source = Directory(pickedPath);
    // Preflight: the folder must exist and be listable before anything
    // is created, so a failed import leaves no phantom empty project.
    try {
      if (!await source.exists()) {
        return const ImportResult(
          error: 'That folder could not be found.',
        );
      }
      await source.list().toList();
    } catch (_) {
      return const ImportResult(
        error: 'That folder could not be read. Try "Import ZIP", or grant '
            'the app all-files access in Android settings.',
      );
    }
    final dir = await projectsDir;
    var name = p.basename(pickedPath);
    if (name.isEmpty) name = 'project';
    var target = Directory(p.join(dir.path, name));
    var n = 2;
    while (await target.exists()) {
      target = Directory(p.join(dir.path, '$name-$n'));
      n++;
    }
    try {
      final report =
          await _copyTree(source, target, onProgress: onProgress);
      if (report.copied == 0 && report.failed.isNotEmpty) {
        await _deleteQuietly(target);
        return ImportResult(
          error: 'Could not copy any files from that folder.',
          failedFiles: report.failed,
        );
      }
      final flattened = await _unwrapSingleWrapperFolder(target);
      notifyListeners();
      return ImportResult(
        project: Project(name: p.basename(target.path), path: target.path),
        filesCopied: report.copied,
        failedFiles: report.failed,
        flattened: flattened,
      );
    } catch (_) {
      await _deleteQuietly(target);
      return const ImportResult(
        error: 'Import failed while copying files.',
      );
    }
  }

  /// Unwrap a single top-level wrapper folder: imports (folder or .zip)
  /// often contain exactly one folder and nothing else — e.g. a GitHub
  /// .zip whose root is `Guest_gen-main/`, or a folder picked from
  /// inside its own parent — which used to leave the project doubled
  /// (`projects/Guest_gen-main/Guest_gen-main/main.py`) so main.py and
  /// requirements.txt were not at the project root. When the target
  /// holds exactly one directory and no files, move that directory's
  /// contents up one level and delete it. Repeats for nested wrappers
  /// (max 3 levels). Returns true when it unwrapped at least one level.
  Future<bool> _unwrapSingleWrapperFolder(Directory target) async {
    var unwrapped = false;
    for (var i = 0; i < 3; i++) {
      List<FileSystemEntity> children;
      try {
        children = await target.list().toList();
      } catch (_) {
        return unwrapped;
      }
      final visible = children
          .where((e) => !p.basename(e.path).startsWith('.'))
          .toList();
      if (visible.length != 1 || visible.first is! Directory) {
        return unwrapped;
      }
      final wrapper = visible.first as Directory;
      try {
        await for (final entity in wrapper.list()) {
          await entity.rename(
            p.join(target.path, p.basename(entity.path)),
          );
        }
        await wrapper.delete();
        unwrapped = true;
      } catch (_) {
        return unwrapped;
      }
    }
    return unwrapped;
  }

  Future<void> _deleteQuietly(Directory dir) async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }

  /// Copy a directory tree. Per-file failures are collected (and the
  /// copy continues with the rest) instead of aborting the whole import.
  /// Returns how many files were copied and the relative paths that
  /// failed. Hidden files and `__pycache__` are skipped on purpose.
  Future<({int copied, List<String> failed})> _copyTree(
    Directory source,
    Directory target, {
    void Function(int copied)? onProgress,
  }) async {
    await target.create(recursive: true);
    var copied = 0;
    final failed = <String>[];
    await for (final entity in source.list(recursive: false)) {
      final name = p.basename(entity.path);
      try {
        if (entity is Link) {
          // Symlink: copy what it points to, or report it as failed
          // when it dangles. (A Link is neither File nor Directory, so
          // without this branch it was silently skipped.)
          final type =
              FileSystemEntity.typeSync(entity.path, followLinks: true);
          if (type == FileSystemEntityType.file) {
            await File(entity.path).copy(p.join(target.path, name));
            copied++;
            onProgress?.call(copied);
          } else if (type == FileSystemEntityType.directory) {
            final sub = await _copyTree(
              Directory(entity.path),
              Directory(p.join(target.path, name)),
              onProgress: onProgress,
            );
            copied += sub.copied;
            failed.addAll(sub.failed.map((f) => '$name/$f'));
          } else {
            failed.add(name);
          }
          continue;
        }
        if (entity is Directory) {
          if (name.startsWith('.') || name == '__pycache__') continue;
          final sub = await _copyTree(
            entity,
            Directory(p.join(target.path, name)),
            onProgress: onProgress,
          );
          copied += sub.copied;
          failed.addAll(sub.failed.map((f) => '$name/$f'));
        } else if (entity is File) {
          if (name.startsWith('.')) continue;
          await entity.copy(p.join(target.path, name));
          copied++;
          onProgress?.call(copied);
        }
      } catch (_) {
        failed.add(entity is Directory ? '$name/' : name);
      }
    }
    return (copied: copied, failed: failed);
  }

  /// Import a .zip file as a project (robust on Android 11+ where direct
  /// folder access is restricted). Like [importFolder], a failed import
  /// leaves no half-extracted project behind.
  Future<ImportResult> importZip(String zipPath) async {
    final file = File(zipPath);
    if (!await file.exists()) {
      return const ImportResult(error: 'That .zip file could not be found.');
    }
    final dir = await projectsDir;
    var name = p.basenameWithoutExtension(zipPath);
    if (name.isEmpty) name = 'project';
    var target = Directory(p.join(dir.path, name));
    var n = 2;
    while (await target.exists()) {
      target = Directory(p.join(dir.path, '$name-$n'));
      n++;
    }
    try {
      final bytes = await file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      await extractArchiveToDisk(archive, target.path);
    } catch (_) {
      await _deleteQuietly(target);
      return const ImportResult(
        error: 'Could not read that .zip file.',
      );
    }
    // GitHub .zips hold a single root folder (`repo-branch/`); unwrap
    // it so the project files sit at the project root (v1.0.3).
    final flattened = await _unwrapSingleWrapperFolder(target);
    final copied = await countFiles(target);
    if (copied == 0) {
      await _deleteQuietly(target);
      return const ImportResult(
        error: 'That .zip file contained no files.',
      );
    }
    notifyListeners();
    return ImportResult(
      project: Project(name: p.basename(target.path), path: target.path),
      filesCopied: copied,
      flattened: flattened,
    );
  }

  /// Export a project as a .zip via the Android share sheet.
  Future<bool> exportZip(Project project) async {
    final zipFile = await buildExportZip(project);
    if (zipFile == null) return false;
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(zipFile.path)],
          subject: '${project.name}.zip',
        ),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Build the .zip for [project] (all files, relative paths) in the
  /// temp directory and return it. Split out of [exportZip] so the
  /// zip contents are unit-testable without the share sheet.
  Future<File?> buildExportZip(Project project) async {
    try {
      final tmp = await getTemporaryDirectory();
      final zipPath = p.join(
        tmp.path,
        '${project.name}-${DateTime.now().millisecondsSinceEpoch}.zip',
      );
      final encoder = ZipFileEncoder();
      encoder.create(zipPath);
      await encoder.addDirectory(Directory(project.path));
      await encoder.close();
      return File(zipPath);
    } catch (_) {
      return null;
    }
  }

  /// Delete a project. An in-place project is only forgotten — its
  /// original folder on the phone is NEVER deleted. An imported copy
  /// is deleted from the private workspace as before.
  Future<bool> deleteProject(Project project) async {
    if (project.inPlace) {
      final paths = await _loadInPlacePaths();
      paths.remove(project.path);
      await _saveInPlacePaths(paths);
      notifyListeners();
      return true;
    }
    try {
      await Directory(project.path).delete(recursive: true);
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Rename a project in the private workspace. In-place projects
  /// cannot be renamed: renaming would move the user's real folder on
  /// shared storage, which the app must never do silently.
  Future<bool> renameProject(Project project, String newName) async {
    if (project.inPlace) return false;
    final safe = newName.trim().replaceAll(RegExp(r'[^\w\-. ]'), '_');
    if (safe.isEmpty) return false;
    final dir = await projectsDir;
    final target = Directory(p.join(dir.path, safe));
    if (await target.exists()) return false;
    try {
      await Directory(project.path).rename(target.path);
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  // ---------- file tree helpers ----------

  /// Children of a directory, folders first, then files, alphabetical.
  Future<List<FileSystemEntity>> listChildren(Directory dir) async {
    final items = await dir.list().toList();
    items.sort((a, b) {
      final aDir = a is Directory;
      final bDir = b is Directory;
      if (aDir != bDir) return aDir ? -1 : 1;
      return p.basename(a.path).toLowerCase().compareTo(
            p.basename(b.path).toLowerCase(),
          );
    });
    return items;
  }

  /// Synchronous version of [listChildren], used by the file tree so it
  /// renders instantly with no loading flash. Project folders are small
  /// (tens of entries), so a blocking directory listing is imperceptible
  /// — and it keeps the tree deterministic in widget tests, where async
  /// dart:io never completes inside the fake-async zone.
  List<FileSystemEntity> listChildrenSync(Directory dir) {
    final items = dir.listSync().toList();
    items.sort((a, b) {
      final aDir = a is Directory;
      final bDir = b is Directory;
      if (aDir != bDir) return aDir ? -1 : 1;
      return p.basename(a.path).toLowerCase().compareTo(
            p.basename(b.path).toLowerCase(),
          );
    });
    return items;
  }

  Future<bool> createFile(Directory parent, String name) async {
    final safe = name.trim();
    if (safe.isEmpty || safe.contains('/')) return false;
    try {
      final file = File(p.join(parent.path, safe));
      if (await file.exists()) return false;
      await file.create();
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> createFolder(Directory parent, String name) async {
    final safe = name.trim();
    if (safe.isEmpty || safe.contains('/')) return false;
    try {
      final folder = Directory(p.join(parent.path, safe));
      if (await folder.exists()) return false;
      await folder.create();
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> deleteEntity(FileSystemEntity entity) async {
    try {
      await entity.delete(recursive: true);
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> renameEntity(FileSystemEntity entity, String newName) async {
    final safe = newName.trim();
    if (safe.isEmpty || safe.contains('/')) return false;
    try {
      final target = p.join(p.dirname(entity.path), safe);
      await entity.rename(target);
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Duplicate a file next to the original: `script.py` ->
  /// `script_copy.py`, `script_copy2.py`, ... Returns false on failure.
  Future<bool> duplicateEntity(FileSystemEntity entity) async {
    if (entity is! File) return false;
    final dir = p.dirname(entity.path);
    final base = p.basenameWithoutExtension(entity.path);
    final ext = p.extension(entity.path);
    var candidate = p.join(dir, '${base}_copy$ext');
    var n = 2;
    while (await File(candidate).exists()) {
      candidate = p.join(dir, '${base}_copy$n$ext');
      n++;
    }
    try {
      await entity.copy(candidate);
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<int> countFiles(Directory dir) async {
    var count = 0;
    try {
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File) count++;
      }
    } catch (_) {}
    return count;
  }

  static const _searchableExtensions = {
    '.py',
    '.txt',
    '.md',
    '.json',
    '.csv',
    '.html',
    '.css',
    '.js',
    '.cfg',
    '.ini',
    '.toml',
    '.yml',
    '.yaml',
    '.xml',
    '',
  };
  static const _maxSearchFileBytes = 512 * 1024;

  /// Search [query] across all text files of [project] (recursive,
  /// skips hidden files and `__pycache__`). At most 500 matches.
  Future<List<SearchResult>> searchInProject(
    Project project,
    String query, {
    bool caseSensitive = false,
  }) async {
    final results = <SearchResult>[];
    if (query.isEmpty) return results;
    final needle = caseSensitive ? query : query.toLowerCase();
    final root = Directory(project.path);
    if (!await root.exists()) return results;
    await for (final entity in root.list(recursive: true)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name.startsWith('.')) continue;
      if (entity.path.contains('__pycache__')) continue;
      if (!_searchableExtensions
          .contains(p.extension(entity.path).toLowerCase())) {
        continue;
      }
      try {
        final size = await entity.length();
        if (size > _maxSearchFileBytes) continue;
        final content = await entity.readAsString();
        final lines = content.split('\n');
        for (var i = 0; i < lines.length; i++) {
          final hay = caseSensitive ? lines[i] : lines[i].toLowerCase();
          var from = 0;
          while (true) {
            final col = hay.indexOf(needle, from);
            if (col < 0) break;
            results.add(
              SearchResult(
                filePath: entity.path,
                lineNumber: i + 1,
                column: col,
                lineText: lines[i].trim(),
              ),
            );
            from = col + needle.length;
            if (results.length >= 500) return results;
          }
        }
      } catch (_) {
        // Unreadable / binary file: skip it.
      }
    }
    return results;
  }

  // ---------- pickers ----------

  Future<String?> pickFolder() async {
    return FilePicker.getDirectoryPath();
  }

  Future<String?> pickZip() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    return files.isNotEmpty ? files.first.path : null;
  }
}
