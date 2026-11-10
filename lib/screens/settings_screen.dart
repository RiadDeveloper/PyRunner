import 'package:flutter/material.dart';

import '../app_info.dart';
import '../services/python_service.dart';
import '../services/settings_service.dart';
import '../widgets/app_dialog.dart';

/// The Settings screen (v1.0.4). Every control here is wired to real
/// behaviour — there are no dead toggles. Settings are persisted by
/// [SettingsService] and take effect live (theme, fonts, autosave,
/// indent, entry file) or on the next run where noted.
class SettingsScreen extends StatefulWidget {
  final SettingsService settings;
  final PythonService python;

  const SettingsScreen({
    super.key,
    required this.settings,
    required this.python,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _entryController;

  static const _autosaveDelays = <int>[500, 1200, 3000, 5000];

  @override
  void initState() {
    super.initState();
    _entryController = TextEditingController(
      text: widget.settings.defaultEntryFileName,
    );
  }

  @override
  void dispose() {
    _entryController.dispose();
    super.dispose();
  }

  String _delayLabel(int ms) {
    if (ms < 1000) return '${ms}ms';
    final s = ms / 1000;
    return s == s.truncateToDouble() ? '${s.toInt()}s' : '${s}s';
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Settings',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            _section(context, 'Appearance'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Theme',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 10),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(
                          value: 'dark',
                          icon: Icon(Icons.dark_mode, size: 18),
                          label: Text('Dark'),
                        ),
                        ButtonSegment(
                          value: 'light',
                          icon: Icon(Icons.light_mode, size: 18),
                          label: Text('Light'),
                        ),
                        ButtonSegment(
                          value: 'system',
                          icon: Icon(Icons.phone_android, size: 18),
                          label: Text('System'),
                        ),
                      ],
                      selected: {settings.theme},
                      onSelectionChanged: (selected) =>
                          settings.setTheme(selected.first),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Editor font size',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        Text('${settings.fontSize.toInt()} pt'),
                      ],
                    ),
                    Slider(
                      value: settings.fontSize,
                      min: 10,
                      max: 24,
                      divisions: 14,
                      label: '${settings.fontSize.toInt()} pt',
                      onChanged: settings.setFontSize,
                    ),
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Console font size',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        Text('${settings.consoleFontSize.toInt()} pt'),
                      ],
                    ),
                    Slider(
                      value: settings.consoleFontSize,
                      min: 10,
                      max: 24,
                      divisions: 14,
                      label: '${settings.consoleFontSize.toInt()} pt',
                      onChanged: settings.setConsoleFontSize,
                    ),
                  ],
                ),
              ),
            ),
            _section(context, 'Editor'),
            Card(
              child: Column(
                children: [
                  SwitchListTile(
                    title: const Text('Autosave'),
                    subtitle: const Text(
                      'Save files automatically while editing',
                    ),
                    value: settings.autosave,
                    onChanged: settings.setAutosave,
                    secondary: const Icon(Icons.save_outlined),
                  ),
                  if (settings.autosave)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Autosave delay'),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            children: _autosaveDelays
                                .map(
                                  (ms) => ChoiceChip(
                                    label: Text(_delayLabel(ms)),
                                    selected:
                                        settings.autosaveDelayMs == ms,
                                    onSelected: (_) =>
                                        settings.setAutosaveDelay(ms),
                                  ),
                                )
                                .toList(),
                          ),
                        ],
                      ),
                    ),
                  SwitchListTile(
                    title: const Text('Word wrap'),
                    subtitle: const Text(
                      'Wrap long lines in the editor',
                    ),
                    value: settings.wordWrap,
                    onChanged: settings.setWordWrap,
                    secondary: const Icon(Icons.wrap_text),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Indent size'),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          children: [2, 4]
                              .map(
                                (n) => ChoiceChip(
                                  label: Text('$n spaces'),
                                  selected: settings.indentSize == n,
                                  onSelected: (_) =>
                                      settings.setIndentSize(n),
                                ),
                              )
                              .toList(),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: TextField(
                      controller: _entryController,
                      decoration: const InputDecoration(
                        labelText: 'Default entry file',
                        helperText:
                            'Run uses this when no file is open and no '
                            'entry file is set for the project.',
                        border: OutlineInputBorder(),
                      ),
                      textCapitalization: TextCapitalization.none,
                      autocorrect: false,
                      onSubmitted: (value) =>
                          settings.setDefaultEntryFileName(value),
                      onTapOutside: (_) => settings
                          .setDefaultEntryFileName(_entryController.text),
                    ),
                  ),
                ],
              ),
            ),
            _section(context, 'Layout'),
            Card(
              child: SwitchListTile(
                title: const Text('Show file tree by default'),
                subtitle: const Text(
                  'Wide screens: the side panel starts open. '
                  'On phones this opens the drawer instead.',
                ),
                value: settings.sidebarVisible,
                onChanged: settings.setSidebarVisible,
                secondary: const Icon(Icons.view_sidebar_outlined),
              ),
            ),
            _section(context, 'Console logs'),
            Card(
              child: ListTile(
                leading: const Icon(Icons.clear_all),
                title: const Text('Clear all console logs'),
                subtitle: const Text(
                  'Erase the saved terminal output of every project.',
                ),
                onTap: () async {
                  final confirm = await showConfirmDialog(
                    context: context,
                    title: 'Clear all console logs?',
                    icon: Icons.clear_all,
                    message: 'The terminal output of every project will '
                        'be erased. This cannot be undone.',
                    confirmLabel: 'Clear all',
                    destructive: true,
                  );
                  if (confirm != true || !context.mounted) return;
                  widget.python.clearAllLogs();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('All console logs cleared.'),
                    ),
                  );
                },
              ),
            ),
            _section(context, 'About'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: Image.asset(
                        AppInfo.logoAsset,
                        width: 88,
                        height: 88,
                        fit: BoxFit.contain,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      AppInfo.name,
                      style: Theme.of(context)
                          .textTheme
                          .titleLarge
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Version ${AppInfo.version}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      AppInfo.developer,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Run and edit any Python project on your phone: '
                      'real Python 3.13, a built-in terminal, pip, and '
                      'an editor. Pure-Python wheels and Chaquopy '
                      'Android wheels install on device; packages '
                      'needing a C compiler cannot be built on the '
                      'phone.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: () async {
                final confirm = await showConfirmDialog(
                  context: context,
                  title: 'Reset settings?',
                  icon: Icons.restart_alt,
                  message: 'All settings return to their defaults. '
                      'Your projects and files are not affected.',
                  confirmLabel: 'Reset',
                  destructive: true,
                );
                if (confirm != true || !context.mounted) return;
                await settings.resetToDefaults();
                if (!context.mounted) return;
                _entryController.text = settings.defaultEntryFileName;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Settings reset.')),
                );
              },
              icon: const Icon(Icons.restart_alt),
              label: const Text('Reset settings to defaults'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}
