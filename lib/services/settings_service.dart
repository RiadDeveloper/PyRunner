import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persisted user settings: theme, autosave, font size, recent projects.
///
/// Every setting here is wired to real behaviour — there are no dead
/// toggles. The Settings screen (lib/screens/settings_screen.dart)
/// edits them; the IDE, console and theme read them live through this
/// ChangeNotifier.
class SettingsService extends ChangeNotifier {
  late SharedPreferences _prefs;

  /// Theme: 'dark' | 'light' | 'system'. The app shipped dark-only
  /// toggles before v1.0.4; the old 'dark_mode' bool is still read as a
  /// fallback so an upgrade keeps the user's choice.
  String theme = 'dark';

  /// Resolves 'system' against the OS brightness; 'dark'/'light' win.
  bool get isDarkMode {
    if (theme == 'light') return false;
    if (theme == 'system') {
      return PlatformDispatcher.instance.platformBrightness ==
          Brightness.dark;
    }
    return true;
  }

  bool autosave = true;

  /// Autosave delay in milliseconds (v1.0.4 setting; was a fixed 1200).
  int autosaveDelayMs = 1200;

  bool wordWrap = false;

  /// Editor font size (points).
  double fontSize = 14.0;

  /// Console font size (points) — separate from the editor's (v1.0.4).
  double consoleFontSize = 13.0;

  /// Indent unit for Tab / auto-indent: 2 or 4 spaces (v1.0.4).
  int indentSize = 4;

  /// Default entry file name used when a project has no configured
  /// entry file (v1.0.4; was a hardcoded 'main.py').
  String defaultEntryFileName = 'main.py';

  /// File-tree sidebar visible (wide layouts). Persisted; on phones
  /// the same toggle opens/closes the drawer instead.
  bool sidebarVisible = true;

  List<String> recentProjectPaths = [];

  /// Per-project entry file (what Run executes when no .py tab is open).
  /// Stored as a JSON map: {projectPath: entryFilePath}.
  Map<String, String> _entryFiles = {};

  /// Per-project run arguments (v1.0.10): the extra arguments the Play
  /// button, the `run` command and "Run in terminal" pass to the entry
  /// file / script. Stored as a JSON map: {projectPath: argsString}.
  /// The console `python file.py args` command keeps its own explicit
  /// arguments and never adds these.
  Map<String, String> _runArgs = {};

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    // New key wins; fall back to the pre-1.0.4 dark_mode bool.
    theme = _prefs.getString('theme_mode') ??
        ((_prefs.getBool('dark_mode') ?? true) ? 'dark' : 'light');
    if (theme != 'dark' && theme != 'light' && theme != 'system') {
      theme = 'dark';
    }
    autosave = _prefs.getBool('autosave') ?? true;
    autosaveDelayMs = _prefs.getInt('autosave_delay_ms') ?? 1200;
    if (autosaveDelayMs < 200 || autosaveDelayMs > 10000) {
      autosaveDelayMs = 1200;
    }
    wordWrap = _prefs.getBool('word_wrap') ?? false;
    fontSize = _prefs.getDouble('font_size') ?? 14.0;
    consoleFontSize = _prefs.getDouble('console_font_size') ?? 13.0;
    indentSize = _prefs.getInt('indent_size') ?? 4;
    if (indentSize != 2 && indentSize != 4) indentSize = 4;
    defaultEntryFileName =
        _prefs.getString('default_entry_file') ?? 'main.py';
    if (defaultEntryFileName.trim().isEmpty) {
      defaultEntryFileName = 'main.py';
    }
    sidebarVisible = _prefs.getBool('sidebar_visible') ?? true;
    recentProjectPaths = _prefs.getStringList('recent_projects') ?? [];
    try {
      final raw = _prefs.getString('entry_files');
      if (raw != null) {
        _entryFiles = Map<String, String>.from(jsonDecode(raw) as Map);
      }
    } catch (_) {
      _entryFiles = {};
    }
    try {
      final rawArgs = _prefs.getString('run_args');
      if (rawArgs != null) {
        _runArgs = Map<String, String>.from(jsonDecode(rawArgs) as Map);
      }
    } catch (_) {
      _runArgs = {};
    }
  }

  String? entryFileFor(String projectPath) => _entryFiles[projectPath];

  Future<void> setEntryFile(String projectPath, String filePath) async {
    _entryFiles[projectPath] = filePath;
    await _prefs.setString('entry_files', jsonEncode(_entryFiles));
    notifyListeners();
  }

  Future<void> clearEntryFile(String projectPath) async {
    _entryFiles.remove(projectPath);
    await _prefs.setString('entry_files', jsonEncode(_entryFiles));
    notifyListeners();
  }

  /// The saved run-arguments string for [projectPath] ('' = none).
  String runArgsFor(String projectPath) => _runArgs[projectPath] ?? '';

  /// The saved run arguments for [projectPath], split on whitespace
  /// (quotes honoured) — the list passed to the script.
  List<String> runArgsListFor(String projectPath) {
    final raw = runArgsFor(projectPath).trim();
    if (raw.isEmpty) return const [];
    final out = <String>[];
    final buf = StringBuffer();
    var quote = '';
    for (var i = 0; i < raw.length; i++) {
      final ch = raw[i];
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

  Future<void> setRunArgs(String projectPath, String args) async {
    final trimmed = args.trim();
    if (trimmed.isEmpty) {
      _runArgs.remove(projectPath);
    } else {
      _runArgs[projectPath] = trimmed;
    }
    await _prefs.setString('run_args', jsonEncode(_runArgs));
    notifyListeners();
  }

  Future<void> setTheme(String value) async {
    if (value != 'dark' && value != 'light' && value != 'system') return;
    theme = value;
    await _prefs.setString('theme_mode', value);
    // Keep the legacy bool in step for any older build reading it.
    await _prefs.setBool('dark_mode', value != 'light');
    notifyListeners();
  }

  /// Backwards-compatible dark/light toggle (used by the AppBar theme
  /// buttons). 'system' becomes the explicit choice it resolves to.
  Future<void> setDarkMode(bool value) async {
    await setTheme(value ? 'dark' : 'light');
  }

  Future<void> setAutosave(bool value) async {
    autosave = value;
    await _prefs.setBool('autosave', value);
    notifyListeners();
  }

  Future<void> setAutosaveDelay(int milliseconds) async {
    autosaveDelayMs = milliseconds.clamp(200, 10000);
    await _prefs.setInt('autosave_delay_ms', autosaveDelayMs);
    notifyListeners();
  }

  Future<void> setSidebarVisible(bool value) async {
    sidebarVisible = value;
    await _prefs.setBool('sidebar_visible', value);
    notifyListeners();
  }

  Future<void> setWordWrap(bool value) async {
    wordWrap = value;
    await _prefs.setBool('word_wrap', value);
    notifyListeners();
  }

  Future<void> setFontSize(double value) async {
    fontSize = value.clamp(10.0, 24.0);
    await _prefs.setDouble('font_size', fontSize);
    notifyListeners();
  }

  Future<void> setConsoleFontSize(double value) async {
    consoleFontSize = value.clamp(10.0, 24.0);
    await _prefs.setDouble('console_font_size', consoleFontSize);
    notifyListeners();
  }

  Future<void> setIndentSize(int value) async {
    indentSize = value == 2 ? 2 : 4;
    await _prefs.setInt('indent_size', indentSize);
    notifyListeners();
  }

  Future<void> setDefaultEntryFileName(String value) async {
    var name = value.trim().replaceAll(RegExp(r'[/\\]'), '');
    if (name.isEmpty) name = 'main.py';
    defaultEntryFileName = name;
    await _prefs.setString('default_entry_file', name);
    notifyListeners();
  }

  /// Reset every setting to its default. Entry files and recent
  /// projects are kept — they are data, not settings.
  Future<void> resetToDefaults() async {
    theme = 'dark';
    autosave = true;
    autosaveDelayMs = 1200;
    wordWrap = false;
    fontSize = 14.0;
    consoleFontSize = 13.0;
    indentSize = 4;
    defaultEntryFileName = 'main.py';
    sidebarVisible = true;
    await _prefs.setString('theme_mode', theme);
    await _prefs.setBool('dark_mode', true);
    await _prefs.setBool('autosave', autosave);
    await _prefs.setInt('autosave_delay_ms', autosaveDelayMs);
    await _prefs.setBool('word_wrap', wordWrap);
    await _prefs.setDouble('font_size', fontSize);
    await _prefs.setDouble('console_font_size', consoleFontSize);
    await _prefs.setInt('indent_size', indentSize);
    await _prefs.setString('default_entry_file', defaultEntryFileName);
    await _prefs.setBool('sidebar_visible', sidebarVisible);
    notifyListeners();
  }

  Future<void> addRecentProject(String path) async {
    recentProjectPaths.remove(path);
    recentProjectPaths.insert(0, path);
    if (recentProjectPaths.length > 10) {
      recentProjectPaths = recentProjectPaths.sublist(0, 10);
    }
    await _prefs.setStringList('recent_projects', recentProjectPaths);
    notifyListeners();
  }

  Future<void> removeRecentProject(String path) async {
    recentProjectPaths.remove(path);
    await _prefs.setStringList('recent_projects', recentProjectPaths);
    notifyListeners();
  }
}
