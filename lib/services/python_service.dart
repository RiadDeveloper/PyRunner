import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import 'console_log_store.dart';
import 'requirements_service.dart';

/// Talks to the embedded Chaquopy Python runtime through MainActivity.
///
/// Output arrives live on the EventChannel while a script / pip runs;
/// the MethodChannel call itself returns the exit code when it finishes.
///
/// Console state is per project (v1.0.3): lines, run state and
/// input-wait state live in a [ConsoleLogStore] keyed by project path,
/// so opening project B never shows project A's log and a run in A
/// never leaks output into B's console. The Python runtime itself is
/// still single (one Chaquopy process), so only one script runs at a
/// time — a second Run queues behind it on the native side.
class PythonService extends ChangeNotifier {
  static const _method = MethodChannel('com.pyrunner.app/python');
  static const _events = EventChannel('com.pyrunner.app/python_output');

  final ConsoleLogStore _store = ConsoleLogStore();

  /// Project whose log / run state this service currently shows.
  /// Set by the project screen (via its ConsoleService) when a project
  /// opens; '' while no project is open.
  String _activeProjectPath = '';

  /// Project that started the run currently in flight (set by
  /// runScript/runModule/replEval/pipInstall). Events are routed to
  /// this project, not necessarily the active one — the user may have
  /// switched projects while the run was going. Cleared by the
  /// run_finished event.
  String _runProjectPath = '';

  bool isPythonReady = false;
  String pythonVersion = '';
  StreamSubscription<dynamic>? _subscription;

  /// True while the run in flight is a script/module run (runScript /
  /// runModule), as opposed to a REPL eval or a pip install. The
  /// console uses it to decide whether typed text is type-ahead for
  /// the script's stdin (v1.0.10): only script runs read stdin, so
  /// only they accept type-ahead — text typed during a pip install is
  /// a command, not input for pip. Set optimistically at the call
  /// site, corrected by the run_started event, cleared on
  /// run_finished.
  bool _isScriptRun = false;

  /// Whether the run in flight is a script/module run.
  bool get isScriptRunning => _isScriptRun;

  /// The bridge's EOF sentinel: _InputStream.readline() returns ''
  /// for it, so input() raises EOFError. Must match EOF_SENTINEL in
  /// pyrunner_bridge.py.
  static const eofSentinel = '__PYRUNNER_EOF__';

  /// The log lines of the currently open project.
  List<ConsoleLine> get lines => _store.linesFor(_activeProjectPath);

  /// Whether a script is running in the currently open project.
  bool get isRunning => _store.isRunning(_activeProjectPath);

  /// Whether a script in the currently open project waits for input().
  bool get waitingForInput =>
      _store.isWaitingForInput(_activeProjectPath);

  /// Project whose events / output belong to: the running project
  /// while a run is in flight, else the open project.
  String get _eventProject =>
      _runProjectPath.isNotEmpty ? _runProjectPath : _activeProjectPath;

  void setActiveProject(String projectPath) {
    if (_activeProjectPath == projectPath) return;
    _activeProjectPath = projectPath;
    notifyListeners();
  }

  void init() {
    _subscription = _events.receiveBroadcastStream().listen((event) {
      if (event is! Map) return;
      final type = event['type'] as String? ?? '';
      final text = (event['text'] as String?) ?? '';
      switch (type) {
        case 'out':
          // A partial line (\r progress, input() prompt) replaces the
          // console's open line instead of stacking (v1.0.4).
          if (event['replace'] == true) {
            _store.addPartial(_eventProject, ConsoleKind.output, text);
          } else {
            _store.add(_eventProject, ConsoleKind.output, text);
          }
          notifyListeners();
          break;
        case 'err':
          if (event['replace'] == true) {
            _store.addPartial(_eventProject, ConsoleKind.error, text);
          } else {
            _store.add(_eventProject, ConsoleKind.error, text);
          }
          notifyListeners();
          break;
        case 'event':
          _handleEvent(event['name'] as String? ?? '', text);
          break;
      }
    }, onError: (_) {});
  }

  void _handleEvent(String name, String text) {
    switch (name) {
      case 'python_ready':
        isPythonReady = true;
        pythonVersion = text;
        if (_activeProjectPath.isNotEmpty) {
          _store.add(
            _activeProjectPath,
            ConsoleKind.system,
            'Python $text is ready.',
          );
        }
        notifyListeners();
        break;
      case 'run_started':
        // The bridge tags run events with the project dir when it
        // knows it (run_script/run_module); REPL/pip carry a label
        // instead and fall back to the run's project.
        final startedProject =
            _projectFromEventText(text) ?? _eventProject;
        // A project-dir tag means a script/module run; a label
        // ('repl', 'pip install') means it is not. An empty tag
        // leaves the call-site value alone.
        if (_projectFromEventText(text) != null) {
          _isScriptRun = true;
        } else if (text.isNotEmpty) {
          _isScriptRun = false;
        }
        _store.setRunning(startedProject, true);
        _store.setWaitingForInput(startedProject, false);
        notifyListeners();
        break;
      case 'run_finished':
        final parsed = _parseRunFinished(text);
        final project = parsed.$1 ?? _eventProject;
        final code = parsed.$2;
        _store.setRunning(project, false);
        _store.setWaitingForInput(project, false);
        _isScriptRun = false;
        if (code == 0) {
          _store.add(project, ConsoleKind.system,
              'Process finished (exit code 0).');
        } else if (code == 130) {
          _store.add(
              project, ConsoleKind.system, 'Process stopped by user.');
        } else {
          _store.add(project, ConsoleKind.error,
              'Process finished (exit code $code).');
        }
        if (project == _runProjectPath) _runProjectPath = '';
        notifyListeners();
        break;
      case 'input_request':
        _store.setWaitingForInput(_eventProject, true);
        notifyListeners();
        break;
      case 'input_done':
        _store.setWaitingForInput(_eventProject, false);
        notifyListeners();
        break;
    }
  }

  /// A run-event text is either a project dir (absolute path, from
  /// run_script/run_module) or a label ('repl', 'pip install', '').
  String? _projectFromEventText(String text) =>
      text.startsWith('/') ? text : null;

  /// run_finished text is 'projectDir|code' for scripts/modules
  /// or just 'code' for REPL/pip. Returns (project, code).
  (String?, int) _parseRunFinished(String text) {
    final sep = text.lastIndexOf('|');
    if (sep > 0) {
      final code = int.tryParse(text.substring(sep + 1));
      final project = text.substring(0, sep);
      if (code != null && project.startsWith('/')) {
        return (project, code);
      }
    }
    return (null, int.tryParse(text) ?? 0);
  }

  void addLine(ConsoleKind kind, String text) {
    _store.add(_activeProjectPath, kind, text);
    notifyListeners();
  }

  void addSystem(String text) => addLine(ConsoleKind.system, text);

  /// Clear only the currently open project's log.
  void clear() {
    _store.clear(_activeProjectPath);
    notifyListeners();
  }

  /// Clear every project's log (Settings screen, v1.0.4).
  void clearAllLogs() {
    _store.clearAll();
    notifyListeners();
  }

  Future<bool> ensurePython() async {
    if (isPythonReady) return true;
    try {
      final ok = await _method.invokeMethod<bool>('ensurePython') ?? false;
      return ok;
    } on Exception {
      return false;
    }
  }

  Future<String> fetchPythonVersion() async {
    try {
      final v = await _method.invokeMethod<String>('pythonVersion') ?? '';
      if (v.isNotEmpty) {
        pythonVersion = v;
        isPythonReady = true;
        notifyListeners();
      }
      return v;
    } on Exception {
      return '';
    }
  }

  /// Run a script. [cwd] is the script's working directory — the
  /// console's cwd when the console knows it, else the project dir
  /// (the bridge chdirs there for the run, v1.0.4, so relative file
  /// writes land in the project folder).
  Future<int> runScript(
    String path, {
    List<String> args = const [],
    String projectDir = '',
    String cwd = '',
  }) async {
    _runProjectPath = projectDir;
    _isScriptRun = true;
    try {
      final code = await _method.invokeMethod<int>('runScript', {
        'path': path,
        'args': args,
        'projectDir': projectDir,
        'cwd': cwd.isEmpty ? projectDir : cwd,
      });
      return code ?? 1;
    } on Exception catch (e) {
      _runProjectPath = '';
      _isScriptRun = false;
      addLine(ConsoleKind.error, 'Failed to run script: $e');
      return 1;
    }
  }

  Future<int> runModule(
    String module, {
    List<String> args = const [],
    String projectDir = '',
    String cwd = '',
  }) async {
    _runProjectPath = projectDir;
    _isScriptRun = true;
    try {
      final code = await _method.invokeMethod<int>('runModule', {
        'module': module,
        'args': args,
        'projectDir': projectDir,
        'cwd': cwd.isEmpty ? projectDir : cwd,
      });
      return code ?? 1;
    } on Exception catch (e) {
      _runProjectPath = '';
      _isScriptRun = false;
      addLine(ConsoleKind.error, 'Failed to run module: $e');
      return 1;
    }
  }

  Future<void> replEval(String code) async {
    _runProjectPath = _activeProjectPath;
    _isScriptRun = false;
    try {
      await _method.invokeMethod<void>('replEval', {'code': code});
    } on Exception catch (e) {
      _runProjectPath = '';
      addLine(ConsoleKind.error, 'REPL error: $e');
    }
  }

  Future<int> pipInstall(List<String> args) async {
    _runProjectPath = _activeProjectPath;
    _isScriptRun = false;
    try {
      final code = await _method.invokeMethod<int>('pipInstall', {
        'args': args,
      });
      return code ?? 1;
    } on Exception catch (e) {
      _runProjectPath = '';
      addLine(ConsoleKind.error, 'pip failed: $e');
      return 1;
    }
  }

  Future<String> pipList() async {
    try {
      return await _method.invokeMethod<String>('pipList') ?? '';
    } on Exception catch (e) {
      return 'pip list failed: $e';
    }
  }

  /// Installed packages in the shared store, as name -> version.
  /// Backed by the bridge's importlib.metadata scan (no pip subprocess).
  Future<Map<String, String>> installedPackages() async {
    try {
      final out =
          await _method.invokeMethod<String>('installedPackages') ?? '';
      return parseInstalledPackages(out);
    } on Exception {
      return {};
    }
  }

  Future<void> feedInput(String line) async {
    try {
      await _method.invokeMethod<void>('feedInput', {'line': line});
    } on Exception {
      // Ignore: the script may have finished already.
    }
  }

  /// Send EOF (Ctrl+D) to the running script: the bridge turns the
  /// sentinel into an empty readline, so input() raises EOFError.
  /// A no-op when nothing is running (feedInput swallows the error).
  Future<void> feedEof() async {
    await feedInput(eofSentinel);
  }

  Future<void> stopRun() async {
    try {
      await _method.invokeMethod<void>('stopRun');
    } on Exception {
      // Ignore.
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
