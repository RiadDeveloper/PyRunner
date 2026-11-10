import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models.dart';
import '../services/project_service.dart';
import '../services/python_service.dart';
import '../services/requirements_service.dart';
import '../services/settings_service.dart';

/// Packages: the shared app-level pip store, and per-project
/// requirements.txt status.
///
/// Packages install ONCE into the app's single shared store
/// (`<HOME>/site-packages`) and are reused by every project — like
/// desktop Python. Installing again is idempotent: pip reports
/// "already satisfied", and this screen only installs what is missing
/// or mismatched.
class PackagesScreen extends StatefulWidget {
  final SettingsService settings;
  final PythonService python;
  final ProjectService projects;
  final Project? initialProject;

  const PackagesScreen({
    super.key,
    required this.settings,
    required this.python,
    required this.projects,
    this.initialProject,
  });

  @override
  State<PackagesScreen> createState() => _PackagesScreenState();
}

class _PackagesScreenState extends State<PackagesScreen> {
  Map<String, String>? _installed;
  List<Project> _projects = [];
  Project? _selectedProject;
  List<Requirement> _requirements = [];
  bool _hasRequirementsFile = false;
  bool _installing = false;
  final _logScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _logScroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final projects = await widget.projects.listProjects();
    if (!mounted) return;
    setState(() {
      _projects = projects;
      _selectedProject =
          widget.initialProject != null &&
                  projects.any((p) => p.path == widget.initialProject!.path)
              ? widget.initialProject
              : (projects.isNotEmpty ? projects.first : null);
    });
    await _refreshInstalled();
    await _loadRequirements();
  }

  Future<void> _refreshInstalled() async {
    final map = await widget.python.installedPackages();
    if (!mounted) return;
    setState(() => _installed = map);
  }

  Future<void> _loadRequirements() async {
    final project = _selectedProject;
    if (project == null) {
      setState(() {
        _requirements = [];
        _hasRequirementsFile = false;
      });
      return;
    }
    final file = File(p.join(project.path, 'requirements.txt'));
    try {
      final text = await file.readAsString();
      setState(() {
        _requirements = parseRequirementsText(text);
        _hasRequirementsFile = true;
      });
    } catch (_) {
      setState(() {
        _requirements = [];
        _hasRequirementsFile = false;
      });
    }
  }

  Map<String, String> get _installedMap => _installed ?? {};

  List<Requirement> get _toInstall => _requirements
      .where(
        (r) =>
            requirementStatus(r, _installedMap) !=
            RequirementStatus.satisfied,
      )
      .toList();

  List<Requirement> get _missingOnly => _requirements
      .where(
        (r) =>
            requirementStatus(r, _installedMap) == RequirementStatus.missing,
      )
      .toList();

  Future<void> _install(List<Requirement> reqs, String label) async {
    if (reqs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('All requirements already satisfied.'),
        ),
      );
      return;
    }
    setState(() => _installing = true);
    widget.python.addSystem(
      'Installing ${reqs.length} package${reqs.length == 1 ? '' : 's'} '
      '($label): ${reqs.map(pipArgFor).join(', ')}',
    );
    final code = await widget.python.pipInstall(reqs.map(pipArgFor).toList());
    await _refreshInstalled();
    await _loadRequirements();
    if (!mounted) return;
    setState(() => _installing = false);
    final satisfied = _requirements
        .where(
          (r) =>
              requirementStatus(r, _installedMap) ==
              RequirementStatus.satisfied,
        )
        .length;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          code == 0
              ? 'Install finished: $satisfied of ${_requirements.length} '
                  'requirements satisfied.'
              : 'pip install finished with exit code $code — check the '
                  'log below.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Packages',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () async {
              await _refreshInstalled();
              await _loadRequirements();
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.inventory_2_outlined,
                    color: cs.primary,
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Packages install once into the shared app store '
                      'and are reused by every project. Only pure-Python '
                      'wheels and Chaquopy Android wheels can install — '
                      'packages needing C compilation will fail.',
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _sectionTitle(context, 'Installed packages'),
          const SizedBox(height: 8),
          Card(child: _installedList(context)),
          const SizedBox(height: 16),
          _sectionTitle(context, 'Project requirements'),
          const SizedBox(height: 8),
          Card(child: _requirementsCard(context)),
          const SizedBox(height: 16),
          _sectionTitle(context, 'Install log'),
          const SizedBox(height: 8),
          Card(child: _logCard(context)),
        ],
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String title) {
    return Text(
      title,
      style: Theme.of(context)
          .textTheme
          .titleMedium
          ?.copyWith(fontWeight: FontWeight.w700),
    );
  }

  Widget _installedList(BuildContext context) {
    final installed = _installed;
    if (installed == null) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (installed.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          'No packages installed yet. Install from a project’s '
          'requirements.txt below, or run "pip install <name>" in the '
          'console.',
        ),
      );
    }
    final names = installed.keys.toList()..sort();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            children: [
              Text(
                '${names.length} package${names.length == 1 ? '' : 's'}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        ...names.map(
          (name) => ListTile(
            dense: true,
            leading: const Icon(Icons.inventory_2_outlined, size: 20),
            title: Text(name, style: const TextStyle(fontFamily: 'monospace')),
            trailing: Text(
              installed[name]!,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _requirementsCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButton<Project>(
            value: _selectedProject,
            isExpanded: true,
            hint: const Text('No projects yet'),
            items: _projects
                .map(
                  (p) => DropdownMenuItem<Project>(
                    value: p,
                    child: Text(p.name, overflow: TextOverflow.ellipsis),
                  ),
                )
                .toList(),
            onChanged: (p) {
              if (p == null) return;
              setState(() => _selectedProject = p);
              _loadRequirements();
            },
          ),
          const SizedBox(height: 8),
          if (!_hasRequirementsFile)
            const Text('This project has no requirements.txt file.')
          else if (_requirements.isEmpty)
            const Text('requirements.txt is empty.')
          else
            ..._requirements.map((req) {
              final status = requirementStatus(req, _installedMap);
              final installedVersion = _installedMap[req.name];
              final (label, color) = switch (status) {
                RequirementStatus.satisfied => (
                    '✓ ${installedVersion ?? ''}',
                    Colors.green,
                  ),
                RequirementStatus.missing => ('Missing', Colors.orange),
                RequirementStatus.mismatch => (
                    'Mismatch (installed ${installedVersion ?? '?'})',
                    cs.error,
                  ),
              };
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        req.raw,
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 12,
                          color: color,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                icon: const Icon(Icons.download_outlined, size: 18),
                label: Text('Install requirements (${_toInstall.length})'),
                onPressed: _installing ||
                        _installed == null ||
                        _requirements.isEmpty
                    ? null
                    : () => _install(_toInstall, 'all unsatisfied'),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.download_outlined, size: 18),
                label: Text('Install missing only (${_missingOnly.length})'),
                onPressed: _installing ||
                        _installed == null ||
                        _requirements.isEmpty
                    ? null
                    : () => _install(_missingOnly, 'missing only'),
              ),
            ],
          ),
          if (_installing)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(),
            ),
        ],
      ),
    );
  }

  Widget _logCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 200,
      child: ListenableBuilder(
        listenable: widget.python,
        builder: (context, _) {
          final lines = widget.python.lines;
          final shown = lines.length > 120
              ? lines.sublist(lines.length - 120)
              : lines;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_logScroll.hasClients) {
              _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
            }
          });
          if (shown.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Nothing installed yet — output will appear here.'),
            );
          }
          return ListView.builder(
            controller: _logScroll,
            padding: const EdgeInsets.all(12),
            itemCount: shown.length,
            itemBuilder: (context, i) {
              final line = shown[i];
              return SelectableText(
                line.text,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: switch (line.kind) {
                    ConsoleKind.error => cs.error,
                    ConsoleKind.input => cs.primary,
                    ConsoleKind.system => cs.onSurfaceVariant,
                    ConsoleKind.output => cs.onSurface,
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}
