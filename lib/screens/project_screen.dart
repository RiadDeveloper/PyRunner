import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_code_editor/flutter_code_editor.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:flutter_highlight/themes/monokai-sublime.dart';
import 'package:highlight/languages/python.dart';
import 'package:path/path.dart' as p;

import '../models.dart';
import '../services/console_service.dart';
import '../services/editor_actions.dart';
import '../services/project_service.dart';
import '../services/python_service.dart';
import '../services/settings_service.dart';
import '../services/storage_access_service.dart';
import '../services/tree_refresh.dart';
import '../widgets/app_dialog.dart';
import '../widgets/console_panel.dart';
import '../widgets/file_tree.dart';
import 'packages_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';

class _OpenFile {
  final String path;
  final String name;
  final CodeController controller;
  bool dirty = false;
  Timer? autosaveTimer;

  /// Text the last _onTextChanged call saw; used to diff keystrokes for
  /// the auto-edit logic (auto-indent / auto-close brackets).
  String lastText;

  /// True while _onTextChanged applies a programmatic follow-up edit, so
  /// the re-entrant listener call only syncs state instead of recursing.
  bool suppressAutoEdit = false;

  _OpenFile({required this.path, required String text})
      : name = p.basename(path),
        lastText = text,
        controller = CodeController(text: text, language: python);

  void dispose() {
    autosaveTimer?.cancel();
    controller.dispose();
  }
}

/// The IDE: file tree + tabbed Python editor + built-in console.
class ProjectScreen extends StatefulWidget {
  final Project project;
  final SettingsService settings;
  final PythonService python;

  const ProjectScreen({
    super.key,
    required this.project,
    required this.settings,
    required this.python,
  });

  @override
  State<ProjectScreen> createState() => _ProjectScreenState();
}

class _ProjectScreenState extends State<ProjectScreen> {
  final _projects = ProjectService();
  final _storage = StorageAccessService();
  late final ConsoleService _console;
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final List<_OpenFile> _tabs = [];
  int _selectedTab = -1;
  bool _consoleExpanded = true;

  /// Set after the first frame: the file tree animates in once, then
  /// never replays its entrance on later refreshes.
  bool _treeEntranceDone = false;

  /// Console height in logical pixels when expanded (null = default
  /// 42% of the screen). Drag the handle above the console to resize.
  double? _consoleHeight;

  /// True while the console is being resized by drag (disables the
  /// expand/collapse animation so the panel follows the finger).
  bool _resizingConsole = false;

  // Find & replace bar state (applies to the selected tab).
  bool _showFindBar = false;
  final _findController = TextEditingController();
  final _replaceController = TextEditingController();
  final _findFocusNode = FocusNode();
  bool _findCaseSensitive = false;
  List<int> _findMatches = [];
  int _findIndex = -1;

  /// Throttled file-tree refresh while a script runs (v1.0.4, B):
  /// refresh immediately when a run finishes, at most once per
  /// second while it runs, so files the script creates appear in the
  /// tree without reopening the project.
  final _treeRefresh = TreeRefreshThrottler();

  void _onPythonChanged() {
    if (_treeRefresh.shouldRefresh(running: widget.python.isRunning)) {
      _bumpTree();
    }
  }

  @override
  void initState() {
    super.initState();
    _console = ConsoleService(
      project: widget.project,
      python: widget.python,
      projects: _projects,
    );
    _console.onBeforeRun = _saveAllDirty;
    _console.entryFileProvider =
        () => widget.settings.entryFileFor(widget.project.path);
    _console.defaultEntryFileProvider =
        () => widget.settings.defaultEntryFileName;
    // v1.0.10: `open` / `edit` in the console opens the file here.
    _console.onOpenFile = (filePath) {
      _openFile(File(filePath));
    };
    // v1.0.10: `doctor` reports all-files access.
    _console.storageAccessProvider = () => _storage.hasAllFilesAccess();
    // v1.0.10: the `run` command passes the saved per-project args.
    _console.runArgsProvider =
        () => widget.settings.runArgsListFor(widget.project.path);
    // Re-list the file tree when a run finishes / while one runs
    // (throttled) — see _treeRefresh.
    widget.python.addListener(_onPythonChanged);
    // The log persists per project (v1.0.3): only print the welcome
    // lines when this project's log is still empty, so reopening a
    // project does not repeat them.
    if (widget.python.lines.isEmpty) _console.printWelcome();
    _findController.addListener(_onFindQueryChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _treeEntranceDone = true;
    });
    widget.python.ensurePython().then((_) => widget.python.fetchPythonVersion());
    // Open the default entry file if the project has one.
    final mainFile = File(
      p.join(widget.project.path, widget.settings.defaultEntryFileName),
    );
    if (mainFile.existsSync()) {
      _openFile(mainFile);
    }
  }

  @override
  void dispose() {
    widget.python.removeListener(_onPythonChanged);
    for (final tab in _tabs) {
      tab.dispose();
    }
    _findController.removeListener(_onFindQueryChanged);
    _findController.dispose();
    _replaceController.dispose();
    _findFocusNode.dispose();
    _console.dispose();
    super.dispose();
  }

  // ---------- tabs ----------

  /// Open a file in a new tab (or select its tab if already open).
  ///
  /// Reads the file synchronously: editor files are small local files,
  /// so this shows the tab immediately with no empty-editor flash — and
  /// it keeps file opening deterministic in widget tests, where async
  /// dart:io never completes inside the fake-async zone.
  void _openFile(File file) {
    final existing = _tabs.indexWhere((t) => t.path == file.path);
    if (existing >= 0) {
      setState(() => _selectedTab = existing);
      return;
    }
    String text;
    try {
      text = file.readAsStringSync();
    } catch (_) {
      text = '';
    }
    final tab = _OpenFile(path: file.path, text: text);
    tab.controller.addListener(() => _onTextChanged(tab));
    setState(() {
      _tabs.add(tab);
      _selectedTab = _tabs.length - 1;
      if (_showFindBar) _recomputeFindMatches();
    });
  }

  void _onTextChanged(_OpenFile tab) {
    if (tab.suppressAutoEdit) {
      // Follow-up edit applied by the auto-edit logic: just keep the
      // diff baseline in sync and mark the tab dirty.
      tab.lastText = tab.controller.text;
      if (!tab.dirty) {
        setState(() => tab.dirty = true);
      }
      _restartAutosave(tab);
      return;
    }
    // CodeController notifies listeners for non-text reasons too:
    // code analysis finishing (~500ms after an edit) re-notifies.
    // A notification with no text change must not restart the
    // autosave debounce, or autosave would always fire ~500ms late
    // (and the tab would be re-marked dirty for no reason).
    if (tab.controller.text == tab.lastText) return;
    // Auto-indent / auto-close brackets/quotes / type-over / pair-delete.
    // Works on the text change (not raw key events) so it also works
    // with Android soft keyboards.
    final edit = autoEditOnTextChange(
      oldText: tab.lastText,
      newText: tab.controller.text,
      selection: tab.controller.selection,
      indentSize: widget.settings.indentSize,
    );
    tab.lastText = tab.controller.text;
    if (edit != null) {
      tab.suppressAutoEdit = true;
      tab.controller.value = TextEditingValue(
        text: edit.text,
        selection: edit.selection,
      );
      tab.suppressAutoEdit = false;
      tab.lastText = tab.controller.text;
    }
    if (!tab.dirty) {
      setState(() => tab.dirty = true);
    }
    _restartAutosave(tab);
    if (_showFindBar) {
      _recomputeFindMatches();
      setState(() {});
    }
  }

  void _restartAutosave(_OpenFile tab) {
    tab.autosaveTimer?.cancel();
    if (widget.settings.autosave) {
      tab.autosaveTimer = Timer(
        Duration(milliseconds: widget.settings.autosaveDelayMs),
        () => _saveTab(tab),
      );
    }
  }

  // ---------- find & replace ----------

  void _onFindQueryChanged() {
    _recomputeFindMatches(selectFirst: true);
    if (_findMatches.isNotEmpty) _selectFindMatch();
    setState(() {});
  }

  /// Recompute the match offsets for the current find query in the
  /// selected tab. When [selectFirst] is false, the match nearest the
  /// previously selected one is kept (used while the editor text changes);
  /// the selection itself is never moved here.
  void _recomputeFindMatches({bool selectFirst = false}) {
    final query = _findController.text;
    final prevOffset = _findIndex >= 0 && _findIndex < _findMatches.length
        ? _findMatches[_findIndex]
        : -1;
    _findMatches = [];
    _findIndex = -1;
    if (query.isEmpty || _selectedTab < 0 || _selectedTab >= _tabs.length) {
      return;
    }
    final text = _tabs[_selectedTab].controller.text;
    final hay = _findCaseSensitive ? text : text.toLowerCase();
    final needle = _findCaseSensitive ? query : query.toLowerCase();
    var from = 0;
    while (true) {
      final i = hay.indexOf(needle, from);
      if (i < 0) break;
      _findMatches.add(i);
      from = i + needle.length;
    }
    if (_findMatches.isEmpty) return;
    if (selectFirst || prevOffset < 0) {
      _findIndex = 0;
    } else {
      var idx = _findMatches.indexWhere((m) => m >= prevOffset);
      if (idx < 0) idx = _findMatches.length - 1;
      _findIndex = idx;
    }
  }

  void _selectFindMatch() {
    if (_findIndex < 0 || _findIndex >= _findMatches.length) return;
    if (_selectedTab < 0 || _selectedTab >= _tabs.length) return;
    final tab = _tabs[_selectedTab];
    final start = _findMatches[_findIndex];
    tab.controller.selection = TextSelection(
      baseOffset: start,
      extentOffset: start + _findController.text.length,
    );
  }

  void _stepFind(int dir) {
    if (_findMatches.isEmpty) return;
    _findIndex = (_findIndex + dir) % _findMatches.length;
    if (_findIndex < 0) _findIndex += _findMatches.length;
    _selectFindMatch();
    setState(() {});
  }

  void _replaceCurrent() {
    if (_findIndex < 0 || _findIndex >= _findMatches.length) return;
    if (_selectedTab < 0 || _selectedTab >= _tabs.length) return;
    final tab = _tabs[_selectedTab];
    final query = _findController.text;
    final start = _findMatches[_findIndex];
    final replacement = _replaceController.text;
    final text = tab.controller.text;
    tab.controller.value = TextEditingValue(
      text: text.substring(0, start) +
          replacement +
          text.substring(start + query.length),
      selection:
          TextSelection.collapsed(offset: start + replacement.length),
    );
    _recomputeFindMatches();
    if (_findMatches.isNotEmpty) {
      var idx = _findMatches.indexWhere(
        (m) => m >= start + replacement.length,
      );
      if (idx < 0) idx = 0;
      _findIndex = idx;
      _selectFindMatch();
    }
    setState(() {});
  }

  void _replaceAll() {
    if (_selectedTab < 0 || _selectedTab >= _tabs.length) return;
    final query = _findController.text;
    if (query.isEmpty) return;
    final tab = _tabs[_selectedTab];
    final pattern = RegExp(
      RegExp.escape(query),
      caseSensitive: _findCaseSensitive,
    );
    tab.controller.value = TextEditingValue(
      text: tab.controller.text.replaceAll(pattern, _replaceController.text),
      selection: const TextSelection.collapsed(offset: 0),
    );
    _recomputeFindMatches();
    setState(() {});
  }

  void _toggleFindBar() {
    setState(() => _showFindBar = !_showFindBar);
    if (_showFindBar) {
      _recomputeFindMatches(selectFirst: true);
      if (_findMatches.isNotEmpty) _selectFindMatch();
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _findFocusNode.requestFocus(),
      );
    }
  }

  // ---------- editor keys (Tab / Shift+Tab) ----------

  /// Tab inserts 4 spaces (to the next indent stop); Shift+Tab removes
  /// one indent level. Only hardware keyboards send Tab as a key event,
  /// so this is a bonus on top of the text-change based auto-edit.
  KeyEventResult _onEditorKey(FocusNode node, KeyEvent event, _OpenFile tab) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.tab) {
      return KeyEventResult.ignored;
    }
    if (tab.controller.popupController.shouldShow) {
      return KeyEventResult.ignored;
    }
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final edit = indentLines(
      text: tab.controller.text,
      selection: tab.controller.selection,
      outdent: shift,
      indentSize: widget.settings.indentSize,
    );
    tab.controller.value = TextEditingValue(
      text: edit.text,
      selection: edit.selection,
    );
    return KeyEventResult.handled;
  }

  /// Save a tab synchronously: editor files are small local files, so
  /// a blocking write is imperceptible — and it keeps saving
  /// deterministic in widget tests, where async dart:io never
  /// completes inside the fake-async zone (the same reason file-tree
  /// listing and editor file-open are synchronous reads). It also
  /// means "save before run" can never stall a run on a pending write.
  Future<void> _saveTab(_OpenFile tab) async {
    tab.autosaveTimer?.cancel();
    try {
      File(tab.path).writeAsStringSync(tab.controller.text);
      if (!mounted) return;
      setState(() => tab.dirty = false);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save ${tab.name}')),
      );
    }
  }

  Future<void> _saveAllDirty() async {
    for (final tab in _tabs) {
      if (tab.dirty) await _saveTab(tab);
    }
  }

  Future<void> _closeTab(int index) async {
    final tab = _tabs[index];
    if (tab.dirty) {
      final choice = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Save ${tab.name}?'),
          content: const Text('This file has unsaved changes.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop('discard'),
              child: const Text('Discard'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop('cancel'),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop('save'),
              child: const Text('Save'),
            ),
          ],
        ),
      );
      if (choice == 'cancel' || choice == null) return;
      if (choice == 'save') await _saveTab(tab);
    }
    setState(() {
      tab.dispose();
      _tabs.removeAt(index);
      if (_selectedTab >= _tabs.length) _selectedTab = _tabs.length - 1;
      if (_selectedTab < 0 && _tabs.isNotEmpty) _selectedTab = 0;
      if (_showFindBar) _recomputeFindMatches();
    });
  }

  // ---------- run ----------

  Future<void> _runCurrent() async {
    if (widget.python.isRunning) {
      // v1.0.10: Play while a run is active never silently kills it
      // — it is ignored, and the user is told why (the button also
      // morphs into Stop while running, so this is the keyboard /
      // menu path).
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('A script is already running — press Stop first.'),
        ),
      );
      return;
    }
    if (_selectedTab >= 0) {
      final tab = _tabs[_selectedTab];
      if (!tab.path.toLowerCase().endsWith('.py')) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Open a .py file to run it.')),
        );
        return;
      }
      await _saveTab(tab);
      setState(() => _consoleExpanded = true);
      await _console.execute(
        'python "${tab.path}"${_runArgsSuffix()}',
      );
      return;
    }
    await _runMain();
  }

  Future<void> _runMain() async {
    if (widget.python.isRunning) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('A script is already running — press Stop first.'),
        ),
      );
      return;
    }
    final entry = _resolveEntryFile();
    if (entry == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No file open and no entry file in this project.'),
        ),
      );
      return;
    }
    setState(() => _consoleExpanded = true);
    await _console.execute('python "$entry"${_runArgsSuffix()}');
  }

  /// The saved per-project run arguments, as a command-line suffix
  /// (v1.0.10): ` --name Riad --count 3`. Empty when none are saved.
  /// Quoted when an argument contains a space, so the console's
  /// splitter keeps it as one argument.
  String _runArgsSuffix() {
    final args = widget.settings.runArgsListFor(widget.project.path);
    if (args.isEmpty) return '';
    final quoted = args.map((a) => a.contains(' ') ? '"$a"' : a);
    return ' ${quoted.join(' ')}';
  }

  /// Entry file resolution: the file set via "Set as entry file", else
  /// the default entry name, then __main__.py, app.py, then the
  /// project's only .py file (see ProjectService.resolveEntryFile).
  /// Returns null when none exists. Synchronous file checks (see
  /// _saveTab): async dart:io never completes inside flutter_test's
  /// fake-async zone, and a run must never stall on a pending stat.
  String? _resolveEntryFile() {
    return ProjectService.resolveEntryFile(
      widget.project.path,
      configured: widget.settings.entryFileFor(widget.project.path),
      defaultName: widget.settings.defaultEntryFileName,
    );
  }

  /// "Run in terminal" (v1.0.4, F): run exactly this .py file in the
  /// console — the console cds into the file's directory first, so the
  /// user never has to `cd` into subfolders. Works for files in
  /// subfolders of in-place projects too.
  Future<void> _runFileInTerminal(File file) async {
    if (widget.python.isRunning) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('A script is already running.')),
      );
      return;
    }
    // Save the open tab first so the run uses the latest edits.
    final tabIndex = _tabs.indexWhere((t) => t.path == file.path);
    if (tabIndex >= 0) await _saveTab(_tabs[tabIndex]);
    _console.cdTo(Directory(p.dirname(file.path)));
    setState(() => _consoleExpanded = true);
    await _console.execute(
      'python "${p.basename(file.path)}"${_runArgsSuffix()}',
    );
  }

  /// "Run arguments…" (v1.0.10): the extra arguments the Play button,
  /// the `run` command and "Run in terminal" pass to the script.
  /// Saved per project; empty clears them.
  Future<void> _editRunArgs() async {
    final controller = TextEditingController(
      text: widget.settings.runArgsFor(widget.project.path),
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Run arguments'),
        content: TextField(
          controller: controller,
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          textCapitalization: TextCapitalization.none,
          decoration: const InputDecoration(
            hintText: '--name Riad --count 3',
            helperText:
                'Passed to the script by Play, `run` and "Run in terminal".\n'
                'The console `python file.py args` command uses its own args.',
            helperMaxLines: 3,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              controller.clear();
              Navigator.of(context).pop(true);
            },
            child: const Text('Clear'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved == true && mounted) {
      await widget.settings.setRunArgs(
        widget.project.path,
        controller.text,
      );
      setState(() {});
    }
    controller.dispose();
  }

  /// Open a search result: open the file and jump to the match.
  void _openSearchResult(SearchResult result) {
    final file = File(result.filePath);
    _openFile(file);
    if (_selectedTab < 0 || _selectedTab >= _tabs.length) return;
    final tab = _tabs[_selectedTab];
    final text = tab.controller.text;
    var offset = 0;
    var line = 1;
    var i = 0;
    while (i < text.length && line < result.lineNumber) {
      if (text[i] == '\n') line++;
      i++;
    }
    offset = (i + result.column).clamp(0, text.length);
    tab.controller.selection = TextSelection.collapsed(offset: offset);
  }

  /// "Go to line" dialog: jump the caret to a line number.
  Future<void> _goToLine() async {
    if (_selectedTab < 0 || _selectedTab >= _tabs.length) return;
    final tab = _tabs[_selectedTab];
    final lineCount = '\n'.allMatches(tab.controller.text).length + 1;
    final controller = TextEditingController();
    final line = await showDialog<int>(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Go to line',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  hintText: 'Line 1–$lineCount',
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (v) {
                  Navigator.of(context).pop(int.tryParse(v));
                },
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () {
                      Navigator.of(context).pop(
                        int.tryParse(controller.text),
                      );
                    },
                    child: const Text('Go'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (line == null) return;
    final target = line.clamp(1, lineCount);
    final text = tab.controller.text;
    var offset = 0;
    var current = 1;
    var i = 0;
    while (i < text.length && current < target) {
      if (text[i] == '\n') current++;
      i++;
    }
    offset = i;
    tab.controller.selection = TextSelection.collapsed(offset: offset);
  }

  // ---------- file tree actions ----------

  Future<void> _askCreate({
    required String title,
    required String hint,
    required Directory dir,
    required Future<bool> Function(String name) onCreate,
  }) async {
    final existing = _siblingNames(dir);
    final name = await showNameInputDialog(
      context: context,
      title: title,
      icon: title.toLowerCase().contains('folder')
          ? Icons.create_new_folder_outlined
          : Icons.note_add_outlined,
      hint: hint,
      existingNames: existing,
    );
    if (name == null || name.trim().isEmpty) return;
    final ok = await onCreate(name.trim());
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not create that.')),
      );
    }
    _bumpTree();
  }

  /// Lower-case names of a directory's children, for duplicate checks.
  Set<String> _siblingNames(Directory dir) {
    try {
      return dir
          .listSync()
          .map((e) => p.basename(e.path).toLowerCase())
          .toSet();
    } catch (_) {
      return {};
    }
  }

  void _entityMenu(FileSystemEntity entity) {
    final isDir = entity is Directory;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isDir) ...[
              ListTile(
                leading: const Icon(Icons.note_add_outlined),
                title: const Text('New file here'),
                onTap: () {
                  Navigator.of(context).pop();
                  _askCreate(
                    title: 'New file',
                    hint: 'script.py',
                    dir: entity,
                    onCreate: (n) =>
                        _projects.createFile(entity, n),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.create_new_folder_outlined),
                title: const Text('New folder here'),
                onTap: () {
                  Navigator.of(context).pop();
                  _askCreate(
                    title: 'New folder',
                    hint: 'folder name',
                    dir: entity,
                    onCreate: (n) =>
                        _projects.createFolder(entity, n),
                  );
                },
              ),
              // "Open in terminal here" (v1.0.3): cd the console into
              // this folder and expand it.
              ListTile(
                leading: const Icon(Icons.terminal),
                title: const Text('Open in terminal here'),
                onTap: () {
                  Navigator.of(context).pop();
                  _console.cdTo(entity);
                  setState(() => _consoleExpanded = true);
                },
              ),
            ],
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('Rename'),
              onTap: () async {
                Navigator.of(context).pop();
                final parent = Directory(p.dirname(entity.path));
                final existing = _siblingNames(parent)
                  ..remove(p.basename(entity.path).toLowerCase());
                final name = await showNameInputDialog(
                  context: context,
                  title: 'Rename',
                  icon: Icons.drive_file_rename_outline,
                  hint: p.basename(entity.path),
                  initialValue: p.basename(entity.path),
                  confirmLabel: 'Rename',
                  existingNames: existing,
                );
                if (name != null && name.trim().isNotEmpty) {
                  await _projects.renameEntity(entity, name.trim());
                  _bumpTree();
                }
              },
            ),
            if (!isDir)
              ListTile(
                leading: const Icon(Icons.copy_outlined),
                title: const Text('Duplicate'),
                onTap: () async {
                  Navigator.of(context).pop();
                  final ok = await _projects.duplicateEntity(entity);
                  if (!context.mounted) return;
                  if (!ok) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Could not duplicate that file.'),
                      ),
                    );
                  }
                  _bumpTree();
                },
              ),
            if (!isDir && entity.path.toLowerCase().endsWith('.py'))
              ListTile(
                leading: const Icon(Icons.play_circle_outline),
                title: const Text('Set as entry file'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await widget.settings.setEntryFile(
                    widget.project.path,
                    entity.path,
                  );
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        '${p.basename(entity.path)} is now the '
                        'entry file.',
                      ),
                    ),
                  );
                  setState(() {});
                },
              ),
            // "Run in terminal" (v1.0.4, F): only for .py files — runs
            // this exact file, no `cd` needed.
            if (!isDir && entity.path.toLowerCase().endsWith('.py'))
              ListTile(
                leading: const Icon(Icons.terminal),
                title: const Text('Run in terminal'),
                onTap: () {
                  Navigator.of(context).pop();
                  _runFileInTerminal(entity as File);
                },
              ),
            ListTile(
              leading: Icon(
                Icons.delete,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                'Delete',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: () async {
                Navigator.of(context).pop();
                final confirm = await showConfirmDialog(
                  context: context,
                  title: 'Delete ${isDir ? 'folder' : 'file'}?',
                  icon: Icons.delete_outline,
                  message:
                      '"${p.basename(entity.path)}"${isDir ? ' and everything inside it' : ''} will be permanently deleted.',
                  confirmLabel: 'Delete',
                  destructive: true,
                );
                if (confirm != true) return;
                final ok = await _projects.deleteEntity(entity);
                if (ok) {
                  setState(() {
                    _tabs.removeWhere((t) {
                      final hit = t.path == entity.path ||
                          p.isWithin(entity.path, t.path);
                      if (hit) t.dispose();
                      return hit;
                    });
                    if (_selectedTab >= _tabs.length) {
                      _selectedTab = _tabs.length - 1;
                    }
                  });
                }
                _bumpTree();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _bumpTree() => setState(() {});

  /// Sidebar toggle (v1.0.3): on wide screens (>=600dp) collapse or
  /// expand the persistent file panel (persisted in settings); on
  /// phones open or close the drawer.
  void _toggleSidebar() {
    final wide = MediaQuery.of(context).size.width >= 600;
    if (wide) {
      widget.settings.setSidebarVisible(
        !widget.settings.sidebarVisible,
      );
    } else {
      final scaffold = _scaffoldKey.currentState;
      if (scaffold == null) return;
      if (scaffold.isDrawerOpen) {
        scaffold.closeDrawer();
      } else {
        scaffold.openDrawer();
      }
    }
  }

  // ---------- build ----------

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final entryPath = widget.settings.entryFileFor(widget.project.path);
    final entryName =
        entryPath != null ? p.basename(entryPath) : 'main.py';
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: Text(
          widget.project.name,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          // Sidebar toggle (v1.0.3): on wide screens it collapses /
          // expands the persistent file panel (persisted in settings);
          // on phones it opens / closes the drawer.
          ListenableBuilder(
            listenable: widget.settings,
            builder: (context, _) {
              final visible = widget.settings.sidebarVisible;
              return IconButton(
                tooltip: 'Show/hide file tree',
                icon: Icon(
                  visible
                      ? Icons.view_sidebar
                      : Icons.view_sidebar_outlined,
                  size: 22,
                ),
                onPressed: _toggleSidebar,
              );
            },
          ),
          IconButton(
            tooltip: 'Search in project',
            icon: const Icon(Icons.search),
            onPressed: () async {
              final result = await Navigator.of(context)
                  .push<SearchResult>(
                MaterialPageRoute(
                  builder: (_) => SearchScreen(
                    project: widget.project,
                    projects: _projects,
                  ),
                ),
              );
              if (result != null) _openSearchResult(result);
            },
          ),
          ListenableBuilder(
            listenable: widget.python,
            builder: (context, _) {
              final running = widget.python.isRunning;
              // v1.0.10 (D): one button morphs play ▶ → stop ■ while a
              // run is active (250 ms, easeInOutCubic). Tapping it
              // while running stops the run; pressing Play again can
              // never silently kill it — the button IS the Stop button
              // while a run is in flight.
              return AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                switchInCurve: Curves.easeInOutCubic,
                switchOutCurve: Curves.easeInOutCubic,
                transitionBuilder: (child, animation) => ScaleTransition(
                  scale: animation,
                  child: FadeTransition(
                    opacity: animation,
                    child: child,
                  ),
                ),
                child: running
                    ? IconButton.filled(
                        key: const ValueKey('stop'),
                        tooltip: 'Stop',
                        style: IconButton.styleFrom(
                          backgroundColor: cs.error,
                          foregroundColor: cs.onError,
                        ),
                        icon: const Icon(Icons.stop),
                        onPressed: () => widget.python.stopRun(),
                      )
                    : IconButton.filled(
                        key: const ValueKey('play'),
                        tooltip: 'Run ($entryName)',
                        style: IconButton.styleFrom(
                          backgroundColor: cs.primary,
                          foregroundColor: cs.onPrimary,
                        ),
                        icon: const Icon(Icons.play_arrow),
                        onPressed: _runCurrent,
                      ),
              );
            },
          ),
          IconButton(
            tooltip: 'Packages',
            icon: const Icon(Icons.inventory_2_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => PackagesScreen(
                  settings: widget.settings,
                  python: widget.python,
                  projects: _projects,
                  initialProject: widget.project,
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SettingsScreen(
                  settings: widget.settings,
                  python: widget.python,
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: widget.settings.isDarkMode
                ? 'Switch to light mode'
                : 'Switch to dark mode',
            icon: Icon(
              widget.settings.isDarkMode
                  ? Icons.light_mode
                  : Icons.dark_mode,
            ),
            onPressed: () =>
                widget.settings.setDarkMode(!widget.settings.isDarkMode),
          ),
          // v1.0.10: run arguments, share as .zip, doctor.
          PopupMenuButton<String>(
            tooltip: 'More actions',
            onSelected: (value) async {
              switch (value) {
                case 'run_args':
                  await _editRunArgs();
                case 'share':
                  final ok =
                      await _projects.exportZip(widget.project);
                  if (!context.mounted) return;
                  if (!ok) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Export failed.'),
                      ),
                    );
                  }
                case 'doctor':
                  setState(() => _consoleExpanded = true);
                  await _console.execute('doctor');
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'run_args',
                child: ListTile(
                  leading: Icon(Icons.tune),
                  title: Text('Run arguments…'),
                ),
              ),
              const PopupMenuItem(
                value: 'share',
                child: ListTile(
                  leading: Icon(Icons.share),
                  title: Text('Share project (.zip)'),
                ),
              ),
              const PopupMenuItem(
                value: 'doctor',
                child: ListTile(
                  leading: Icon(Icons.health_and_safety_outlined),
                  title: Text('Doctor'),
                ),
              ),
            ],
          ),
        ],
      ),
      drawer: _buildDrawer(context),
      body: LayoutBuilder(
        builder: (context, constraints) {
          // Tablets (>=600dp) get a persistent side panel; phones keep
          // the drawer-based file tree.
          final wide = constraints.maxWidth >= 600;
          final maxConsole = constraints.maxHeight - 200;
          final defaultConsole =
              (constraints.maxHeight * 0.42).clamp(220.0, 420.0);
          final consoleHeight = _consoleExpanded
              ? (_consoleHeight ?? defaultConsole)
                  .clamp(160.0, maxConsole > 160 ? maxConsole : 160.0)
              : 49.0;
          return Column(
            children: [
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (wide)
                      // The OverflowBox lets the panel lay out at full
                      // width while the AnimatedContainer shrinks to 0;
                      // the ClipRect clips the overflow to the panel's
                      // current width. (clipBehavior on the
                      // AnimatedContainer itself is not allowed without
                      // a decoration, and a plain SizedBox cannot
                      // override the tight 0-width constraint, so the
                      // buttons/tree inside would overflow instead.)
                      ListenableBuilder(
                        listenable: widget.settings,
                        builder: (context, _) => AnimatedContainer(
                          key: const ValueKey('sidebarPanel'),
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOutCubic,
                          width: widget.settings.sidebarVisible ? 280 : 0,
                          child: ClipRect(
                            child: OverflowBox(
                              minWidth: 280,
                              maxWidth: 280,
                              alignment: Alignment.centerLeft,
                              child: SizedBox(
                                width: 280,
                                child: _buildFilePanel(context),
                              ),
                            ),
                          ),
                        ),
                      ),
                    Expanded(child: _buildEditorArea(context)),
                  ],
                ),
              ),
              AnimatedContainer(
                duration: _resizingConsole
                    ? Duration.zero
                    : const Duration(milliseconds: 300),
                curve: Curves.easeInOutCubic,
                height: consoleHeight,
                child: Column(
                  children: [
                    if (_consoleExpanded)
                      GestureDetector(
                        onVerticalDragStart: (_) =>
                            setState(() => _resizingConsole = true),
                        onVerticalDragEnd: (_) =>
                            setState(() => _resizingConsole = false),
                        onVerticalDragCancel: () =>
                            setState(() => _resizingConsole = false),
                        onVerticalDragUpdate: (details) {
                          setState(() {
                            final current = _consoleHeight ?? defaultConsole;
                            _consoleHeight =
                                (current - details.delta.dy).clamp(
                              160.0,
                              maxConsole > 160 ? maxConsole : 160.0,
                            );
                          });
                        },
                        child: MouseRegion(
                          cursor: SystemMouseCursors.resizeUpDown,
                          child: Container(
                            height: 12,
                            alignment: Alignment.center,
                            child: Container(
                              width: 48,
                              height: 4,
                              decoration: BoxDecoration(
                                color: cs.onSurfaceVariant
                                    .withValues(alpha: 0.5),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                        ),
                      ),
                    Expanded(
                      child: ConsolePanel(
                        console: _console,
                        python: widget.python,
                        settings: widget.settings,
                        expanded: _consoleExpanded,
                        onToggleExpanded: () => setState(
                          () => _consoleExpanded = !_consoleExpanded,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildDrawer(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                widget.project.name,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
            ),
            _treeActions(context, Directory(widget.project.path)),
            const Divider(),
            Expanded(child: _buildTree(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildFilePanel(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Text(
              'FILES',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
          _treeActions(context, Directory(widget.project.path)),
          Expanded(child: _buildTree(context)),
        ],
      ),
    );
  }

  Widget _treeActions(BuildContext context, Directory dir) {
    // Wrap, not Row: File + Folder + Install requirements do not fit
    // side by side in a phone drawer.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Wrap(
        spacing: 2,
        children: [
          TextButton.icon(
            icon: const Icon(Icons.note_add_outlined, size: 18),
            label: const Text('File'),
            onPressed: () => _askCreate(
              title: 'New file',
              hint: 'script.py',
              dir: dir,
              onCreate: (n) => _projects.createFile(dir, n),
            ),
          ),
          TextButton.icon(
            icon: const Icon(Icons.create_new_folder_outlined, size: 18),
            label: const Text('Folder'),
            onPressed: () => _askCreate(
              title: 'New folder',
              hint: 'folder name',
              dir: dir,
              onCreate: (n) => _projects.createFolder(dir, n),
            ),
          ),
          // Manual refresh (v1.0.4, B): re-list the tree right now.
          // The tree also refreshes itself when a run finishes and
          // (throttled) while one runs.
          TextButton.icon(
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Refresh'),
            onPressed: _bumpTree,
          ),
          // One-tap `pip install -r requirements.txt` (v1.0.3), shown
          // only when the project has a requirements file. The bridge
          // rewrites an unbounded pycryptodome line to ==3.21.0, so
          // this works for the user's Guest_gen-main project as-is.
          if (File(p.join(dir.path, 'requirements.txt')).existsSync())
            ListenableBuilder(
              listenable: widget.python,
              builder: (context, _) => TextButton.icon(
                icon: const Icon(Icons.download_outlined, size: 18),
                label: const Text('Install requirements'),
                onPressed: widget.python.isRunning
                    ? null
                    : () async {
                        setState(() => _consoleExpanded = true);
                        await _console.execute(
                          'pip install -r requirements.txt',
                        );
                      },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTree(BuildContext context) {
    return FileTree(
      project: widget.project,
      projects: _projects,
      selectedPath: _selectedTab >= 0 ? _tabs[_selectedTab].path : null,
      entryFilePath: widget.settings.entryFileFor(widget.project.path),
      animateEntrance: !_treeEntranceDone,
      // Expand the top level when the tree first builds, so a freshly
      // imported project's files are visible immediately (v1.0.3).
      // (No ValueKey here any more: the key used to rebuild the whole
      // tree on every refresh, collapsing every open folder.)
      expandTopLevel: true,
      onOpenFile: (file) {
        _openFile(file);
        if (Scaffold.of(context).isDrawerOpen) {
          Navigator.of(context).pop();
        }
      },
      onEntityMenu: _entityMenu,
      onCreateFile: (dir) => _askCreate(
        title: 'New file',
        hint: 'script.py',
        dir: dir,
        onCreate: (n) => _projects.createFile(dir, n),
      ),
      onCreateFolder: (dir) => _askCreate(
        title: 'New folder',
        hint: 'folder name',
        dir: dir,
        onCreate: (n) => _projects.createFolder(dir, n),
      ),
    );
  }

  Widget _buildEditorToolbar(BuildContext context, _OpenFile tab) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 42,
      // Horizontally scrollable on narrow phones: the buttons do not
      // fit in 390dp. (No Spacer here — it cannot live in an
      // unbounded-width scrollable Row.)
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
          IconButton(
            tooltip: 'Undo',
            icon: const Icon(Icons.undo, size: 20),
            onPressed: () => tab.controller.historyController.undo(),
          ),
          IconButton(
            tooltip: 'Redo',
            icon: const Icon(Icons.redo, size: 20),
            onPressed: () => tab.controller.historyController.redo(),
          ),
          const VerticalDivider(width: 8, indent: 8, endIndent: 8),
          IconButton(
            tooltip: 'Smaller font',
            icon: const Icon(Icons.text_decrease, size: 20),
            onPressed: () async {
              await widget.settings.setFontSize(
                (widget.settings.fontSize - 1).clamp(10.0, 24.0),
              );
              if (mounted) setState(() {});
            },
          ),
          Text(
            '${widget.settings.fontSize.toInt()}',
            style: const TextStyle(fontSize: 12),
          ),
          IconButton(
            tooltip: 'Larger font',
            icon: const Icon(Icons.text_increase, size: 20),
            onPressed: () async {
              await widget.settings.setFontSize(
                (widget.settings.fontSize + 1).clamp(10.0, 24.0),
              );
              if (mounted) setState(() {});
            },
          ),
          IconButton(
            tooltip: 'Go to line',
            icon: const Icon(Icons.format_list_numbered, size: 20),
            onPressed: _goToLine,
          ),
          IconButton(
            tooltip:
                widget.settings.wordWrap ? 'Word wrap: on' : 'Word wrap: off',
            icon: const Icon(Icons.wrap_text, size: 20),
            isSelected: widget.settings.wordWrap,
            selectedIcon: Icon(
              Icons.wrap_text,
              size: 20,
              color: cs.primary,
            ),
            onPressed: () async {
              await widget.settings
                  .setWordWrap(!widget.settings.wordWrap);
              if (mounted) setState(() {});
            },
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'Find & replace',
            icon: const Icon(Icons.search, size: 20),
            isSelected: _showFindBar,
            selectedIcon: Icon(Icons.search, size: 20, color: cs.primary),
            onPressed: _toggleFindBar,
          ),
          // Autosave toggle, surfaced here so it can be found and
          // turned off (v1.0.3): the autosave itself is unchanged
          // (1.2s debounce, Saved/Unsaved label in the save bar).
          IconButton(
            tooltip: widget.settings.autosave
                ? 'Autosave: on (tap to turn off)'
                : 'Autosave: off (tap to turn on)',
            icon: const Icon(Icons.save_outlined, size: 20),
            isSelected: widget.settings.autosave,
            selectedIcon: Icon(Icons.save, size: 20, color: cs.primary),
            onPressed: () async {
              await widget.settings
                  .setAutosave(!widget.settings.autosave);
              if (mounted) setState(() {});
            },
          ),
        ],
        ),
      ),
    );
  }

  Widget _buildFindBar(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final countText = _findController.text.isEmpty
        ? ''
        : _findMatches.isEmpty
            ? 'No matches'
            : '${_findIndex + 1} of ${_findMatches.length}';
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        border: Border(
          bottom: BorderSide(color: cs.outlineVariant),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _findController,
                  focusNode: _findFocusNode,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'Find',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _stepFind(1),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 76,
                child: Text(
                  countText,
                  style: const TextStyle(fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ),
              IconButton(
                tooltip: 'Previous match',
                icon: const Icon(Icons.keyboard_arrow_up, size: 20),
                onPressed: _findMatches.isEmpty ? null : () => _stepFind(-1),
              ),
              IconButton(
                tooltip: 'Next match',
                icon: const Icon(Icons.keyboard_arrow_down, size: 20),
                onPressed: _findMatches.isEmpty ? null : () => _stepFind(1),
              ),
              IconButton(
                tooltip: 'Match case',
                icon: const Text(
                  'Aa',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                isSelected: _findCaseSensitive,
                selectedIcon: Text(
                  'Aa',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: cs.primary,
                  ),
                ),
                onPressed: () {
                  setState(
                    () => _findCaseSensitive = !_findCaseSensitive,
                  );
                  _recomputeFindMatches(selectFirst: true);
                  if (_findMatches.isNotEmpty) _selectFindMatch();
                  setState(() {});
                },
              ),
              IconButton(
                tooltip: 'Close find bar',
                icon: const Icon(Icons.close, size: 20),
                onPressed: _toggleFindBar,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _replaceController,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'Replace with',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: _findMatches.isEmpty ? null : _replaceCurrent,
                child: const Text('Replace'),
              ),
              TextButton(
                onPressed: _findMatches.isEmpty ? null : _replaceAll,
                child: const Text('Replace all'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEditorArea(BuildContext context) {
    if (_tabs.isEmpty) {
      return _emptyEditor(context);
    }
    final tab = _tabs[_selectedTab];
    return Column(
      children: [
        // Tab bar
        SizedBox(
          height: 44,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            itemCount: _tabs.length,
            itemBuilder: (context, i) {
              final t = _tabs[i];
              final selected = i == _selectedTab;
              return Padding(
                padding: const EdgeInsets.only(right: 6),
                child: InkWell(
                  onTap: () {
                    setState(() {
                      _selectedTab = i;
                      if (_showFindBar) _recomputeFindMatches();
                    });
                  },
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: selected
                          ? Theme.of(context)
                              .colorScheme
                              .primaryContainer
                              .withValues(alpha: 0.6)
                          : Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest
                              .withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        if (t.dirty)
                          Container(
                            width: 7,
                            height: 7,
                            margin: const EdgeInsets.only(right: 6),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primary,
                              shape: BoxShape.circle,
                            ),
                          ),
                        Text(
                          t.name,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                        ),
                        const SizedBox(width: 4),
                        InkWell(
                          onTap: () => _closeTab(i),
                          child: const Icon(Icons.close, size: 15),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const Divider(height: 1),
        _buildEditorToolbar(context, tab),
        if (_showFindBar) _buildFindBar(context),
        // Editor — switching tabs cross-fades (v1.0.10, D), 200 ms
        // easeOutCubic, so the code does not snap between files.
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeOutCubic,
            transitionBuilder: (child, animation) =>
                FadeTransition(opacity: animation, child: child),
            child: Padding(
              key: ValueKey(tab.path),
              padding: const EdgeInsets.all(4),
              child: CodeTheme(
                data: CodeThemeData(
                  styles: widget.settings.isDarkMode
                      ? monokaiSublimeTheme
                      : githubTheme,
                ),
                child: Focus(
                  onKeyEvent: (node, event) => _onEditorKey(node, event, tab),
                  child: CodeField(
                    key: ValueKey(tab.path),
                    controller: tab.controller,
                    textStyle: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: widget.settings.fontSize,
                    ),
                    wrap: widget.settings.wordWrap,
                    expands: true,
                  ),
                ),
              ),
            ),
          ),
        ),
        // Save bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  tab.dirty ? 'Unsaved changes' : 'Saved',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              TextButton.icon(
                icon: const Icon(Icons.save_outlined, size: 18),
                label: const Text('Save'),
                onPressed: tab.dirty ? () => _saveTab(tab) : null,
              ),
              TextButton.icon(
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('Run'),
                onPressed: () => _runCurrent(),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _emptyEditor(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.code_off_outlined,
              size: 48,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 12),
            const Text(
              'No file open',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17),
            ),
            const SizedBox(height: 6),
            const Text(
              'Pick a file from the file tree to edit it, or create a new one.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => _askCreate(
                title: 'New file',
                hint: 'script.py',
                dir: Directory(widget.project.path),
                onCreate: (n) => _projects.createFile(
                  Directory(widget.project.path),
                  n,
                ),
              ),
              icon: const Icon(Icons.note_add_outlined),
              label: const Text('New file'),
            ),
          ],
        ),
      ),
    );
  }
}
