import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../models.dart';
import '../services/project_service.dart';
import '../services/python_service.dart';
import '../services/settings_service.dart';
import '../services/storage_access_service.dart';
import '../widgets/app_dialog.dart';
import 'packages_screen.dart';
import 'project_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  final SettingsService settings;
  final PythonService python;

  const HomeScreen({super.key, required this.settings, required this.python});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with WidgetsBindingObserver {
  final _projects = ProjectService();
  final _storage = StorageAccessService();
  List<Project> _list = [];
  bool _loading = true;

  /// True while the user is in Android Settings granting all-files
  /// access; when they come back, the permission is re-checked.
  bool _awaitingStorageReturn = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    // Warm up the Python runtime in the background so the first Run is fast.
    widget.python.ensurePython().then((_) => widget.python.fetchPythonVersion());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _awaitingStorageReturn) {
      _awaitingStorageReturn = false;
      _openFolderInPlace(fromSettingsReturn: true);
    }
  }

  Future<void> _refresh() async {
    List<Project> list = [];
    try {
      list = await _projects.listProjects();
    } catch (_) {
      // Storage unavailable (e.g. in tests): show the empty state.
      list = [];
    }
    if (!mounted) return;
    setState(() {
      _list = list;
      _loading = false;
    });
  }

  void _openProject(Project project) {
    widget.settings.addRecentProject(project.path);
    Navigator.of(context)
        .push(
          PageRouteBuilder(
            pageBuilder: (_, _, _) => ProjectScreen(
              project: project,
              settings: widget.settings,
              python: widget.python,
            ),
            transitionsBuilder: (_, animation, _, child) {
              final tween = Tween<Offset>(
                begin: const Offset(0.12, 0),
                end: Offset.zero,
              ).chain(CurveTween(curve: Curves.easeOutCubic));
              return SlideTransition(
                position: animation.drive(tween),
                child: FadeTransition(opacity: animation, child: child),
              );
            },
          ),
        )
        .then((_) => _refresh());
  }

  Future<void> _newProject({bool sample = false, ProjectTemplate? template}) async {
    final name = await _askName(
      title: sample
          ? 'Sample project'
          : template != null
              ? '${template.name} project'
              : 'New project',
      hint: sample
          ? 'sample-project'
          : template != null
              ? template.id
              : 'my-project',
      existingNames: _list.map((p) => p.name.toLowerCase()).toSet(),
    );
    if (name == null) return;
    final project = await _projects.createProject(
      name,
      sample: sample,
      template: template,
    );
    _openProject(project);
  }

  /// Pick one of the new-project templates (v1.0.10), then name it.
  Future<void> _newProjectFromTemplate() async {
    final template = await showDialog<ProjectTemplate>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('New project from template'),
        children: [
          for (final t in ProjectService.templates)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(t),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.name,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      t.description,
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
    if (template == null) return;
    await _newProject(template: template);
  }

  /// "Open folder (in place)" (v1.0.4, A): the picked folder stays
  /// where it is — nothing is copied, and files the script creates
  /// land in the real folder. Needs all-files access on Android 11+.
  Future<void> _openFolderInPlace({bool fromSettingsReturn = false}) async {
    final granted = await _storage.hasAllFilesAccess();
    if (!mounted) return;
    if (!granted) {
      if (fromSettingsReturn) {
        // Came back from Settings without granting: say so once,
        // don't loop back into the dialog.
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'All-files access is still off — you can import a copy '
              'instead.',
            ),
          ),
        );
        return;
      }
      final choice = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('All-files access needed'),
          content: const Text(
            'To keep your project where it is — so the files your '
            'scripts create land in the real folder — PyRunner needs '
            'all-files access. You can grant it in Android Settings.\n\n'
            'Or import a copy instead: the project is copied into '
            'the app and your original folder stays untouched.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop('copy'),
              child: const Text('Import a copy instead'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop('settings'),
              child: const Text('Open settings'),
            ),
          ],
        ),
      );
      if (choice == 'settings') {
        _awaitingStorageReturn = true;
        await _storage.openAllFilesAccessSettings();
      } else if (choice == 'copy') {
        await _openFolder();
      }
      return;
    }
    final path = await _projects.pickFolder();
    if (path == null || !mounted) return;
    final project = await _projects.openInPlace(path);
    if (project == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'That folder could not be read. Try "Import a copy".',
          ),
        ),
      );
      return;
    }
    _openProject(project);
  }

  Future<void> _openFolder() async {
    final path = await _projects.pickFolder();
    if (path == null || !mounted) return;
    final result = await _runWithProgress<ImportResult>(
      title: 'Importing folder…',
      run: (onProgress) =>
          _projects.importFolder(path, onProgress: onProgress),
    );
    if (result == null || !mounted) return;
    _handleImportResult(result);
  }

  Future<void> _importZip() async {
    final path = await _projects.pickZip();
    if (path == null || !mounted) return;
    final result = await _runWithProgress<ImportResult>(
      title: 'Importing .zip…',
      run: (_) => _projects.importZip(path),
    );
    if (result == null || !mounted) return;
    _handleImportResult(result);
  }

  void _handleImportResult(ImportResult result) {
    if (!result.success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.error ?? 'Import failed.')),
      );
      _refresh();
      return;
    }
    if (result.failedFiles.isNotEmpty) {
      final shown = result.failedFiles.take(3).join(', ');
      final more = result.failedFiles.length > 3
          ? ' and ${result.failedFiles.length - 3} more'
          : '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Imported ${result.filesCopied} files, but '
            '${result.failedFiles.length} failed: $shown$more',
          ),
          duration: const Duration(seconds: 5),
        ),
      );
    } else if (result.flattened) {
      // The import had a single wrapper folder (e.g. a GitHub zip's
      // Guest_gen-main/Guest_gen-main/) — it was unwrapped so the
      // files are at the project root (v1.0.3).
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Imported — the extra top folder was unwrapped, so your '
            'files are at the project root.',
          ),
        ),
      );
    }
    _openProject(result.project!);
  }

  /// Runs [run] while a modal progress dialog with a live file count is
  /// shown. Returns the result, or null if the dialog went away.
  Future<T?> _runWithProgress<T>({
    required String title,
    required Future<T> Function(void Function(int copied) onProgress) run,
  }) async {
    final copied = ValueNotifier<int>(0);
    final result = await showDialog<T>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _ImportProgressDialog<T>(
        title: title,
        copied: copied,
        future: run((n) => copied.value = n),
      ),
    );
    copied.dispose();
    return result;
  }

  Future<String?> _askName({
    required String title,
    required String hint,
    Set<String> existingNames = const {},
  }) {
    return showNameInputDialog(
      context: context,
      title: title,
      icon: Icons.folder_outlined,
      hint: hint,
      initialValue: hint,
      existingNames: existingNames,
    );
  }

  void _projectMenu(Project project) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: const Text('Open'),
              onTap: () {
                Navigator.of(context).pop();
                _openProject(project);
              },
            ),
            // In-place projects cannot be renamed: renaming would move
            // the user's real folder on shared storage.
            if (!project.inPlace)
              ListTile(
                leading: const Icon(Icons.drive_file_rename_outline),
                title: const Text('Rename'),
                onTap: () async {
                  Navigator.of(context).pop();
                  final name = await _askName(
                    title: 'Rename project',
                    hint: project.name,
                    existingNames: _list
                        .where((p) => p.path != project.path)
                        .map((p) => p.name.toLowerCase())
                        .toSet(),
                  );
                  if (name != null && name.trim().isNotEmpty) {
                    await _projects.renameProject(project, name.trim());
                    _refresh();
                  }
                },
              ),
            ListTile(
              leading: const Icon(Icons.ios_share),
              title: const Text('Export as .zip'),
              onTap: () async {
                Navigator.of(context).pop();
                final messenger = ScaffoldMessenger.of(context);
                final ok = await _projects.exportZip(project);
                messenger.showSnackBar(
                  SnackBar(
                    content: Text(
                      ok
                          ? 'Choose where to save the .zip'
                          : 'Export failed.',
                    ),
                  ),
                );
              },
            ),
            ListTile(
              leading: Icon(Icons.delete, color: Theme.of(context).colorScheme.error),
              title: Text(
                'Delete',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: () async {
                Navigator.of(context).pop();
                final confirm = await showConfirmDialog(
                  context: context,
                  title: 'Delete project?',
                  icon: Icons.delete_outline,
                  message: project.inPlace
                      ? '"${project.name}" will only be removed from '
                          'this list. The folder on your phone will '
                          'NOT be deleted.'
                      : '"${project.name}" and all its files will be deleted.',
                  confirmLabel:
                      project.inPlace ? 'Remove from list' : 'Delete',
                  destructive: true,
                );
                if (confirm == true) {
                  await _projects.deleteProject(project);
                  widget.settings.removeRecentProject(project.path);
                  _refresh();
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: cs.primary,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.terminal,
                color: cs.onPrimary,
                size: 20,
              ),
            ),
            const SizedBox(width: 10),
            const Text(
              'PyRunner',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
          ],
        ),
        actions: [
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
            icon: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) =>
                  RotationTransition(turns: animation, child: child),
              child: Icon(
                widget.settings.isDarkMode
                    ? Icons.light_mode
                    : Icons.dark_mode,
                key: ValueKey(widget.settings.isDarkMode),
              ),
            ),
            onPressed: () =>
                widget.settings.setDarkMode(!widget.settings.isDarkMode),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            _heroCard(context),
            const SizedBox(height: 20),
            Text(
              'Start',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            _actionGrid(context),
            const SizedBox(height: 24),
            Row(
              children: [
                Text(
                  'Your projects',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                Text(
                  '${_list.length} project${_list.length == 1 ? '' : 's'}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_list.isEmpty)
              _emptyState(context)
            else
              // Gentle staggered entrance (v1.0.10, D): each card
              // fades + slides up, 60 ms apart (capped so a long list
              // never waits), 250 ms easeOutCubic.
              ..._list.asMap().entries.map(
                    (e) => _projectCard(context, e.value, e.key)
                        .animate()
                        .fadeIn(
                          duration: 250.ms,
                          delay: ((e.key < 8 ? e.key : 8) * 60).ms,
                          curve: Curves.easeOutCubic,
                        )
                        .slideY(
                          begin: 0.15,
                          end: 0,
                          duration: 250.ms,
                          delay: ((e.key < 8 ? e.key : 8) * 60).ms,
                          curve: Curves.easeOutCubic,
                        ),
                  ),
            const SizedBox(height: 24),
            _settingsCard(context),
          ],
        ),
      ),
    );
  }

  Widget _heroCard(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [cs.primary, cs.primary.withValues(alpha: 0.75)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.code, color: Colors.white, size: 28),
              const SizedBox(width: 8),
              Text(
                'Python, in your pocket',
                style: theme.textTheme.titleLarge?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Open any Python project, edit it, and run it with one tap — '
            'right on your phone.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.white.withValues(alpha: 0.9),
            ),
          ),
          const SizedBox(height: 14),
          ListenableBuilder(
            listenable: widget.python,
            builder: (context, _) {
              final version = widget.python.pythonVersion;
              return Wrap(
                spacing: 8,
                children: [
                  _chip(
                    context,
                    Icons.memory,
                    version.isEmpty
                        ? 'Python 3.13 starting…'
                        : 'Python $version',
                  ),
                  _chip(context, Icons.terminal, 'Built-in console'),
                  _chip(context, Icons.install_mobile, 'pip install'),
                ],
              );
            },
          ),
        ],
      ),
    ).animate().fadeIn(duration: 400.ms).slideY(begin: -0.1, end: 0);
  }

  Widget _chip(BuildContext context, IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.white),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _actionGrid(BuildContext context) {
    final actions = [
      _Action(
        Icons.folder_open,
        'Open folder (in place)',
        'Stay where it is — no copy',
        _openFolderInPlace,
      ),
      _Action(
        Icons.file_copy_outlined,
        'Import a copy',
        'Copy into the app',
        _openFolder,
      ),
      _Action(
        Icons.archive_outlined,
        'Import .zip',
        'Unzip a project',
        _importZip,
      ),
      _Action(
        Icons.create_new_folder_outlined,
        'New project',
        'Start from scratch',
        () => _newProject(),
      ),
      _Action(
        Icons.auto_awesome,
        'Sample project',
        'Try it in seconds',
        () => _newProject(sample: true),
      ),
      _Action(
        Icons.description_outlined,
        'From template',
        'Hello World, CLI, Data',
        _newProjectFromTemplate,
      ),
      _Action(
        Icons.inventory_2_outlined,
        'Packages',
        'Manage pip packages',
        () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => PackagesScreen(
              settings: widget.settings,
              python: widget.python,
              projects: _projects,
            ),
          ),
        ),
      ),
    ];
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 1.9,
      ),
      itemCount: actions.length,
      itemBuilder: (context, i) {
        final a = actions[i];
        return Card(
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: a.onTap,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    a.icon,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    a.title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    a.subtitle,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        )
            .animate(delay: (i * 70).ms)
            .fadeIn(duration: 350.ms)
            .slideY(begin: 0.15, end: 0);
      },
    );
  }

  Widget _projectCard(BuildContext context, Project project, int index) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: Theme.of(context)
                .colorScheme
                .primaryContainer
                .withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            Icons.folder,
            color: Theme.of(context).colorScheme.onPrimaryContainer,
          ),
        ),
        title: Text(
          project.name,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: FutureBuilder<int>(
          future: _projects.countFiles(Directory(project.path)),
          builder: (context, snap) {
            final n = snap.data ?? 0;
            final inPlace = project.inPlace ? ' · In place' : '';
            return Text(
              '$n file${n == 1 ? '' : 's'}$inPlace',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            );
          },
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _openProject(project),
        onLongPress: () => _projectMenu(project),
      ),
    )
        .animate(delay: (index * 60).ms)
        .fadeIn(duration: 300.ms)
        .slideX(begin: 0.08, end: 0);
  }

  Widget _emptyState(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(
              Icons.folder_off_outlined,
              size: 44,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 10),
            const Text(
              'No projects yet',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
            const SizedBox(height: 4),
            const Text(
              'Create the sample project to see PyRunner in action — '
              'it runs in seconds.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: () => _newProject(sample: true),
              icon: const Icon(Icons.auto_awesome),
              label: const Text('Create sample project'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _settingsCard(BuildContext context) {
    final settings = widget.settings;
    return Card(
      child: Column(
        children: [
          SwitchListTile(
            title: const Text('Dark mode'),
            subtitle: const Text('Easier on the eyes at night'),
            value: settings.isDarkMode,
            onChanged: settings.setDarkMode,
            secondary: const Icon(Icons.dark_mode_outlined),
          ),
          SwitchListTile(
            title: const Text('Autosave'),
            subtitle: const Text('Save files automatically while editing'),
            value: settings.autosave,
            onChanged: settings.setAutosave,
            secondary: const Icon(Icons.save_outlined),
          ),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('Settings'),
            subtitle: const Text(
              'Theme, fonts, autosave, entry file, logs, about',
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SettingsScreen(
                  settings: settings,
                  python: widget.python,
                ),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About PyRunner'),
            subtitle: const Text(
              'Runs real Python on your phone with Chaquopy. '
              'No real Linux shell — the console is built in.',
            ),
          ),
        ],
      ),
    );
  }
}

class _Action {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  _Action(this.icon, this.title, this.subtitle, this.onTap);
}

/// Modal progress dialog for imports: shows a spinner and a live file
/// count, and closes itself with the import result when it finishes.
class _ImportProgressDialog<T> extends StatefulWidget {
  final String title;
  final ValueNotifier<int> copied;
  final Future<T> future;

  const _ImportProgressDialog({
    required this.title,
    required this.copied,
    required this.future,
  });

  @override
  State<_ImportProgressDialog<T>> createState() =>
      _ImportProgressDialogState<T>();
}

class _ImportProgressDialogState<T>
    extends State<_ImportProgressDialog<T>> {
  @override
  void initState() {
    super.initState();
    widget.future.then(
      (result) {
        if (mounted) Navigator.of(context).pop(result);
      },
      onError: (_) {
        if (mounted) Navigator.of(context).pop();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  ValueListenableBuilder<int>(
                    valueListenable: widget.copied,
                    builder: (context, n, _) => Text(
                      n == 0
                          ? 'Starting…'
                          : '$n file${n == 1 ? '' : 's'} copied',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
