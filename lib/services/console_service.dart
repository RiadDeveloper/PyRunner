import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models.dart';
import 'project_service.dart';
import 'python_service.dart';

/// One completion shown in the suggestion row above the console input.
/// [display] is the chip label; [insert] is the full input line after
/// applying the suggestion.
class ConsoleSuggestion {
  final String display;
  final String insert;
  const ConsoleSuggestion({required this.display, required this.insert});

  @override
  bool operator ==(Object other) =>
      other is ConsoleSuggestion && other.insert == insert;

  @override
  int get hashCode => insert.hashCode;
}

/// The built-in console: there is no real POSIX shell inside a normal
/// Android app, so this interprets the commands the user types and routes
/// them to the file system or to the embedded Python runtime.
class ConsoleService extends ChangeNotifier {
  final Project project;
  final PythonService python;
  final ProjectService projects;

  /// Called before a script is launched so the editor can save dirty tabs.
  Future<void> Function()? onBeforeRun;

  /// Open a file in the editor tab (v1.0.10: the `open` / `edit`
  /// console command). Set by the IDE screen; defaults to null.
  void Function(String filePath)? onOpenFile;

  /// Whether the app has all-files access (v1.0.10: the `doctor`
  /// command). Set by the IDE screen; defaults to null (unknown).
  Future<bool> Function()? storageAccessProvider;

  /// The saved per-project run arguments (v1.0.10): the `run` command
  /// passes them to the entry file. Set by the IDE screen.
  List<String> Function()? runArgsProvider;

  /// Resolves the project's entry file (configured in settings, else
  /// main.py). Set by the IDE screen; defaults to main.py.
  String? Function()? entryFileProvider;

  /// The default entry file name from settings (v1.0.4; was a
  /// hardcoded 'main.py'). Set by the IDE screen.
  String Function()? defaultEntryFileProvider;

  late Directory cwd;
  bool replMode = false;

  final List<String> history = [];
  int _historyIndex = -1;

  ConsoleService({
    required this.project,
    required this.python,
    required this.projects,
  }) {
    cwd = Directory(project.path);
    // The console log is per project (v1.0.3): this project's lines
    // are the ones shown until another project opens. (Audit fix:
    // nothing called setActiveProject before, so every project shared
    // one log under the empty key.)
    python.setActiveProject(project.path);
  }

  String get prompt {
    if (python.waitingForInput) return 'input> ';
    if (replMode) return '>>> ';
    final rel = p.relative(cwd.path, from: project.path);
    final label = rel == '.' ? '~' : '~/$rel';
    return 'pyrunner:$label\$ ';
  }

  void printWelcome() {
    python.addSystem('PyRunner console — type "help" for commands.');
    python.addSystem('Project: ${project.name}');
    python.addSystem(
      'Tip: tap the green Play button to run the open file, or type '
      '"python main.py" here.',
    );
  }

  String historyUp(String current) {
    if (history.isEmpty) return current;
    if (_historyIndex == -1) _historyIndex = history.length;
    if (_historyIndex > 0) _historyIndex--;
    return history[_historyIndex];
  }

  String historyDown(String current) {
    if (history.isEmpty || _historyIndex == -1) return current;
    if (_historyIndex < history.length - 1) {
      _historyIndex++;
      return history[_historyIndex];
    }
    _historyIndex = -1;
    return '';
  }

  void _remember(String raw) {
    if (raw.trim().isEmpty) return;
    if (history.isEmpty || history.last != raw) history.add(raw);
    if (history.length > 200) history.removeAt(0);
    _historyIndex = -1;
  }

  /// Completions for the current console input, shown as suggestion chips.
  /// Sources, in order: built-in commands, command history (most recent
  /// first), and — after `python` / `cat` / `cd` / `ls` — file and folder
  /// names from the project directory matching the path fragment typed
  /// so far. Returns at most 8 suggestions.
  List<ConsoleSuggestion> suggestionsFor(String input) {
    if (input.isEmpty) return const [];
    final out = <ConsoleSuggestion>[];
    final seen = <String>{};
    void add(String display, String insert) {
      if (insert == input) return;
      if (seen.add(insert)) {
        out.add(ConsoleSuggestion(display: display, insert: insert));
      }
    }

    const commands = [
      'help',
      'clear',
      'ls',
      'cd',
      'pwd',
      'cat',
      'echo',
      'open',
      'edit',
      'doctor',
      'python',
      'python -m',
      'pip install',
      'pip install -r requirements.txt',
      'pip list',
      'run',
      'stop',
      'exit',
    ];
    for (final c in commands) {
      if (c.startsWith(input)) add(c, c);
    }
    for (var i = history.length - 1; i >= 0; i--) {
      if (history[i].startsWith(input)) add(history[i], history[i]);
    }

    // Path completion: `python m` -> `python main.py`, `cd u` -> `cd utils/`
    final m =
        RegExp(r'^(python|cat|cd|ls|open|edit)\s+(\S*)$').firstMatch(input);
    if (m != null) {
      final cmd = m.group(1)!;
      final frag = m.group(2)!;
      final slash = frag.lastIndexOf('/');
      final dirPart = slash >= 0 ? frag.substring(0, slash + 1) : '';
      final base = slash >= 0 ? frag.substring(slash + 1) : frag;
      final dirPath = dirPart.isEmpty ? cwd.path : _resolve(dirPart);
      if (dirPath != null) {
        try {
          final children = Directory(dirPath).listSync();
          children.sort((a, b) => p.basename(a.path)
              .toLowerCase()
              .compareTo(p.basename(b.path).toLowerCase()));
          for (final child in children) {
            final name = p.basename(child.path);
            if (!name.startsWith(base) || name == base) continue;
            // `cd` only completes to directories.
            if (cmd == 'cd' && child is! Directory) continue;
            final token =
                '$dirPart$name${child is Directory ? '/' : ''}';
            add(name, '$cmd $token');
          }
        } catch (_) {
          // Unreadable directory: no path suggestions.
        }
      }
    }
    return out.take(8).toList();
  }

  /// Resolve [target] (absolute or relative to cwd) and keep it inside the
  /// project tree. Returns null when it escapes the project.
  String? _resolve(String target) {
    final abs = p.isAbsolute(target)
        ? p.normalize(target)
        : p.normalize(p.join(cwd.path, target));
    final root = p.normalize(project.path);
    if (abs == root || p.isWithin(root, abs)) return abs;
    return null;
  }

  /// Resolve [target] relative to cwd, falling back to the project root
  /// when it is not found there (v1.0.3 audit fix: after `cd` into a
  /// subfolder, `python main.py` and `pip install -r requirements.txt`
  /// should still find the files at the project root instead of
  /// failing until the user `cd`s back).
  String? _resolveOrRoot(String target) {
    final fromCwd = _resolve(target);
    if (fromCwd != null && File(fromCwd).existsSync()) return fromCwd;
    if (!p.isAbsolute(target)) {
      final fromRoot = p.normalize(p.join(project.path, target));
      if (File(fromRoot).existsSync()) return fromRoot;
    }
    return fromCwd;
  }

  /// Jump the console into [dir] ("Open in terminal here" in the file
  /// tree). The directory must be inside the project.
  void cdTo(Directory dir) {
    final path = _resolve(dir.path);
    if (path == null || !Directory(path).existsSync()) return;
    cwd = Directory(path);
    final rel = p.relative(path, from: project.path);
    python.addLine(
      ConsoleKind.system,
      'Console directory: ${rel == '.' ? '~' : '~/$rel'}',
    );
    notifyListeners();
  }

  Future<void> execute(String raw) async {
    final input = raw.trimRight();
    _remember(raw);
    if (input.trim().isEmpty) return;

    // A script is waiting for input(): feed the line to it instead.
    if (python.waitingForInput) {
      python.addLine(ConsoleKind.input, input);
      await python.feedInput(input);
      return;
    }

    // v1.0.10 — type-ahead: a script is running but the
    // input_request event was dropped (the EventChannel can lose it
    // on re-subscription), so waitingForInput is false although the
    // script waits at input(). Text that is not a control command is
    // type-ahead for the script's stdin — never a command, and never
    // a stop. Only script runs accept type-ahead (REPL/pip runs fall
    // through to normal handling); the bridge discards a stale
    // STOP_SENTINEL, so a previous stop can never poison this run.
    if (python.isRunning && python.isScriptRunning) {
      final t = input.trim();
      if (t == 'stop') {
        await python.stopRun();
        python.addLine(ConsoleKind.system, 'Stop requested.');
        return;
      }
      if (t == 'clear') {
        python.clear();
        return;
      }
      if (t == 'help') {
        _printHelp();
        return;
      }
      python.addLine(ConsoleKind.input, input);
      await python.feedInput(input);
      return;
    }

    if (replMode) {
      await _replLine(input);
      return;
    }

    python.addLine(ConsoleKind.input, input);
    final parts = _split(input);
    if (parts.isEmpty) return;
    final cmd = parts.first;
    final args = parts.sublist(1);

    switch (cmd) {
      case 'help':
        _printHelp();
      case 'clear':
        python.clear();
      case 'pwd':
        python.addLine(ConsoleKind.output, cwd.path);
      case 'ls':
        await _ls(args.isNotEmpty ? args.first : null);
      case 'cd':
        _cd(args.isNotEmpty ? args.first : '~');
      case 'cat':
        await _cat(args);
      case 'echo':
        python.addLine(ConsoleKind.output, args.join(' '));
      case 'open':
      case 'edit':
        _openFile(args);
      case 'doctor':
        await _doctor();
      case 'python':
        await _python(args);
      case 'pip':
        await _pip(args);
      case 'run':
        await _runMain();
      case 'stop':
        await python.stopRun();
        python.addLine(ConsoleKind.system, 'Stop requested.');
      case 'exit':
      case 'quit':
        python.addLine(
          ConsoleKind.system,
          'Use the back button to leave the project.',
        );
      default:
        python.addLine(
          ConsoleKind.error,
          "Command not found: $cmd  (type 'help' for commands)",
        );
    }
    notifyListeners();
  }

  /// Send EOF (Ctrl+D) to the running script: input() raises EOFError.
  /// Ignored when no script is running.
  Future<void> sendEof() async {
    if (!python.isRunning || !python.isScriptRunning) return;
    python.addLine(ConsoleKind.system, 'EOF (Ctrl+D) sent.');
    await python.feedEof();
  }

  /// `open <file>` / `edit <file>`: open the file in the editor tab.
  void _openFile(List<String> args) {
    if (args.isEmpty) {
      python.addLine(ConsoleKind.error, 'open: missing file');
      return;
    }
    final path = _resolveOrRoot(args.first);
    if (path == null || !File(path).existsSync()) {
      python.addLine(ConsoleKind.error, 'open: no such file: ${args.first}');
      return;
    }
    final opener = onOpenFile;
    if (opener == null) {
      python.addLine(
        ConsoleKind.error,
        'open: the editor is not available here.',
      );
      return;
    }
    opener(path);
    python.addLine(
      ConsoleKind.system,
      'Opened ${p.basename(path)} in the editor.',
    );
  }

  /// `doctor`: check the runtime, packages, storage and this project,
  /// and report what is wrong (v1.0.10).
  Future<void> _doctor() async {
    void line(bool ok, String text) {
      python.addLine(
        ok ? ConsoleKind.output : ConsoleKind.error,
        '${ok ? '✓' : '✗'} $text',
      );
    }

    python.addLine(ConsoleKind.system, 'PyRunner doctor:');
    final version = python.pythonVersion.isNotEmpty
        ? python.pythonVersion
        : await python.fetchPythonVersion();
    line(version.isNotEmpty, 'Python ${version.isEmpty ? 'unknown' : version}');
    final pipOut = await python.pipList();
    line(
      pipOut.contains('Package'),
      pipOut.contains('Package')
          ? 'pip is available'
          : 'pip is not available',
    );
    final installed = await python.installedPackages();
    final crypto = installed.keys
        .any((k) => k.toLowerCase() == 'pycryptodome');
    line(
      crypto,
      crypto
          ? 'pycryptodome ${installed.entries.firstWhere((e) => e.key.toLowerCase() == 'pycryptodome').value} is installed'
          : 'pycryptodome is not installed (needed by projects using Crypto)',
    );
    final dir = Directory(project.path);
    var readable = false;
    var count = 0;
    try {
      if (dir.existsSync()) {
        final children = dir.listSync();
        readable = true;
        count = children.length;
      }
    } catch (_) {
      readable = false;
    }
    line(
      readable,
      readable
          ? 'Project folder is readable ($count items)'
          : 'Project folder is not readable: ${project.path}',
    );
    final storage = await storageAccessProvider?.call();
    if (storage == null) {
      python.addLine(
        ConsoleKind.system,
        '? All-files access: unknown (check Settings)',
      );
    } else {
      line(
        storage,
        storage
            ? 'All-files access is granted'
            : 'All-files access is off (in-place projects need it)',
      );
    }
    final entry = ProjectService.resolveEntryFile(
      project.path,
      configured: entryFileProvider?.call(),
      defaultName: defaultEntryFileProvider?.call() ?? 'main.py',
    );
    line(
      entry != null,
      entry != null
          ? 'Entry file: ${p.relative(entry, from: project.path)}'
          : 'No entry file found (main.py / __main__.py / app.py / single .py file)',
    );
    final reqFile = File(p.join(project.path, 'requirements.txt'));
    if (!reqFile.existsSync()) {
      python.addLine(
        ConsoleKind.system,
        '— No requirements.txt in this project',
      );
      return;
    }
    final wanted = <String>[];
    try {
      for (final raw in await reqFile.readAsLines()) {
        final req = raw.trim();
        if (req.isEmpty || req.startsWith('#')) continue;
        wanted.add(req.split(RegExp(r'[<>=!~;\s]')).first.toLowerCase());
      }
    } catch (_) {
      // Unreadable requirements file: report it below.
    }
    if (wanted.isEmpty) {
      python.addLine(
        ConsoleKind.system,
        '— requirements.txt is empty',
      );
      return;
    }
    final missing = wanted
        .where((name) => !installed.keys
            .any((k) => k.toLowerCase() == name))
        .toSet()
        .toList();
    line(
      missing.isEmpty,
      missing.isEmpty
          ? 'requirements.txt: all ${wanted.length} package(s) installed'
          : 'requirements.txt: missing ${missing.join(', ')} — run: pip install -r requirements.txt',
    );
  }

  Future<void> _replLine(String line) async {
    python.addLine(ConsoleKind.input, line);
    final t = line.trim();
    if (t == 'exit()' || t == 'quit()' || t == 'exit' || t == 'quit') {
      replMode = false;
      python.addLine(ConsoleKind.system, 'Leaving Python REPL.');
      notifyListeners();
      return;
    }
    await python.replEval(line);
    notifyListeners();
  }

  void _printHelp() {
    const help = '''
Available commands:
  help                  Show this help
  clear                 Clear the console
  ls [dir]              List files in a directory
  cd <dir>              Change directory (.. and ~ work)
  pwd                   Show the current directory
  cat <file>            Show a file's contents
  echo <text>           Print text
  python <file.py> [args]   Run a Python script
  python -m <module> [args] Run a module
  python                Start the interactive Python REPL
  python --version      Show the Python version
  pip install <pkg>     Install a package (pure-Python / Android wheels)
  pip install -r requirements.txt
  pip list              List installed packages
  run                   Run main.py (or the open file)
  open <file> / edit <file>   Open a file in the editor
  doctor                Check Python, pip, packages, storage, project
  stop / Ctrl+C         Stop the running script
  Ctrl+D                Send EOF to the running script (input() → EOFError)
''';
    python.addLine(ConsoleKind.output, help.trimRight());
  }

  Future<void> _ls(String? target) async {
    final path = target == null ? cwd.path : _resolve(target);
    if (path == null) {
      python.addLine(ConsoleKind.error, 'ls: outside project: $target');
      return;
    }
    final dir = Directory(path);
    if (!await dir.exists()) {
      python.addLine(ConsoleKind.error, 'ls: no such directory: $target');
      return;
    }
    final children = await projects.listChildren(dir);
    if (children.isEmpty) {
      python.addLine(ConsoleKind.output, '(empty directory)');
      return;
    }
    for (final child in children) {
      if (child is Directory) {
        python.addLine(ConsoleKind.output, '${p.basename(child.path)}/');
      } else if (child is File) {
        final size = await child.length().catchError((_) => 0);
        python.addLine(
          ConsoleKind.output,
          '${p.basename(child.path)}  ($size bytes)',
        );
      }
    }
  }

  void _cd(String target) {
    if (target == '~' || target.isEmpty) {
      cwd = Directory(project.path);
      return;
    }
    final path = _resolve(target);
    if (path == null) {
      python.addLine(ConsoleKind.error, 'cd: outside project: $target');
      return;
    }
    final dir = Directory(path);
    if (!dir.existsSync()) {
      python.addLine(ConsoleKind.error, 'cd: no such directory: $target');
      return;
    }
    cwd = dir;
  }

  Future<void> _cat(List<String> args) async {
    if (args.isEmpty) {
      python.addLine(ConsoleKind.error, 'cat: missing file');
      return;
    }
    final path = _resolve(args.first);
    if (path == null) {
      python.addLine(ConsoleKind.error, 'cat: outside project: ${args.first}');
      return;
    }
    final file = File(path);
    if (!await file.exists()) {
      python.addLine(ConsoleKind.error, 'cat: no such file: ${args.first}');
      return;
    }
    final size = await file.length();
    if (size > 200 * 1024) {
      python.addLine(
        ConsoleKind.error,
        'cat: file is too large to print (${size ~/ 1024} KB)',
      );
      return;
    }
    final content = await file.readAsString();
    final lines = content.split('\n');
    for (var i = 0; i < lines.length && i < 3000; i++) {
      python.addLine(ConsoleKind.output, lines[i]);
    }
    if (lines.length > 3000) {
      python.addLine(ConsoleKind.system, '... (truncated)');
    }
  }

  Future<void> _python(List<String> args) async {
    if (args.isEmpty) {
      replMode = true;
      python.addLine(
        ConsoleKind.system,
        'Python REPL — type Python code, or exit() to leave.',
      );
      notifyListeners();
      return;
    }
    if (args.first == '--version' || args.first == '-V') {
      final v = await python.fetchPythonVersion();
      python.addLine(
        ConsoleKind.output,
        v.isEmpty ? 'Python version unknown' : 'Python $v',
      );
      return;
    }
    // A run is already in flight: never queue a second run behind it
    // on the native executor — say so and let the user stop it first
    // (v1.0.10: Play / run must never silently kill or queue a run).
    if (python.isRunning) {
      python.addLine(
        ConsoleKind.error,
        'A script is already running — press Stop first.',
      );
      return;
    }
    if (args.first == '-m') {
      if (args.length < 2) {
        python.addLine(ConsoleKind.error, 'python -m: missing module name');
        return;
      }
      await onBeforeRun?.call();
      await python.runModule(
        args[1],
        args: args.length > 2 ? args.sublist(2) : const [],
        projectDir: project.path,
        cwd: cwd.path,
      );
      return;
    }
    final target = _resolveOrRoot(args.first);
    if (target == null || !File(target).existsSync()) {
      python.addLine(
        ConsoleKind.error,
        'python: no such file: ${args.first}',
      );
      return;
    }
    await onBeforeRun?.call();
    await python.runScript(
      target,
      args: args.length > 1 ? args.sublist(1) : const [],
      projectDir: project.path,
      cwd: cwd.path,
    );
  }

  Future<void> _pip(List<String> args) async {
    if (args.isEmpty) {
      python.addLine(
        ConsoleKind.error,
        'Usage: pip install <pkg> | pip install -r requirements.txt | pip list',
      );
      return;
    }
    if (args.first == 'list') {
      final out = await python.pipList();
      python.addLine(ConsoleKind.output, out.trimRight());
      return;
    }
    if (args.first == 'install') {
      if (args.length < 2) {
        python.addLine(ConsoleKind.error, 'pip install: missing package');
        return;
      }
      final resolved = <String>[];
      for (var i = 1; i < args.length; i++) {
        if (args[i] == '-r' && i + 1 < args.length) {
          final req = _resolveOrRoot(args[i + 1]);
          if (req == null || !File(req).existsSync()) {
            python.addLine(
              ConsoleKind.error,
              'pip: no such file: ${args[i + 1]}',
            );
            return;
          }
          resolved.add('-r');
          resolved.add(req);
          i++;
        } else {
          resolved.add(args[i]);
        }
      }
      final code = await python.pipInstall(resolved);
      if (code == 0) {
        python.addLine(ConsoleKind.system, 'pip install finished.');
      } else {
        python.addLine(
          ConsoleKind.error,
          'pip install failed (exit code $code). Only pure-Python wheels '
          'and Chaquopy Android wheels can install on device.',
        );
      }
      return;
    }
    python.addLine(
      ConsoleKind.error,
      "pip: unsupported subcommand '${args.first}' (use install or list)",
    );
  }

  Future<void> _runMain() async {
    if (python.isRunning) {
      python.addLine(
        ConsoleKind.error,
        'A script is already running — press Stop first.',
      );
      return;
    }
    final entry = ProjectService.resolveEntryFile(
      project.path,
      configured: entryFileProvider?.call(),
      defaultName: defaultEntryFileProvider?.call() ?? 'main.py',
    );
    if (entry != null) {
      await onBeforeRun?.call();
      await python.runScript(
        entry,
        args: runArgsProvider?.call() ?? const [],
        projectDir: project.path,
        cwd: cwd.path,
      );
      return;
    }
    python.addLine(
      ConsoleKind.error,
      'run: no entry file in this project.',
    );
  }

  /// Split a command line on whitespace, honouring single/double quotes.
  List<String> _split(String input) {
    final out = <String>[];
    final buf = StringBuffer();
    var quote = '';
    for (var i = 0; i < input.length; i++) {
      final ch = input[i];
      if (quote.isEmpty && (ch == '"' || ch == "'")) {
        quote = ch;
      } else if (quote.isNotEmpty && ch == quote) {
        quote = '';
      } else if (quote.isEmpty && ch == ' ') {
        if (buf.isNotEmpty) {
          out.add(buf.toString());
          buf.clear();
        }
      } else {
        buf.write(ch);
      }
    }
    if (buf.isNotEmpty) out.add(buf.toString());
    return out;
  }
}
