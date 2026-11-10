import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:path/path.dart' as p;

import '../models.dart';
import '../services/project_service.dart';

/// Expandable file tree for the open project.
class FileTree extends StatelessWidget {
  final Project project;
  final ProjectService projects;
  final String? selectedPath;
  final String? entryFilePath;
  final bool animateEntrance;

  /// Expand the top-level folders when the tree first builds, so the
  /// files of a freshly imported project are visible immediately
  /// instead of hidden inside a collapsed folder (v1.0.3).
  final bool expandTopLevel;
  final void Function(File file) onOpenFile;
  final void Function(FileSystemEntity entity) onEntityMenu;
  final void Function(Directory dir) onCreateFile;
  final void Function(Directory dir) onCreateFolder;

  const FileTree({
    super.key,
    required this.project,
    required this.projects,
    required this.selectedPath,
    this.entryFilePath,
    this.animateEntrance = false,
    this.expandTopLevel = false,
    required this.onOpenFile,
    required this.onEntityMenu,
    required this.onCreateFile,
    required this.onCreateFolder,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: projects,
      builder: (context, _) {
        // Synchronous listing: the tree renders instantly, no spinner
        // flash, and no async gap (see listChildrenSync).
        final children =
            projects.listChildrenSync(Directory(project.path));
        if (children.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Empty project — create a file to begin.'),
          );
        }
        return ListView(
          padding: const EdgeInsets.symmetric(vertical: 4),
          children: children.asMap().entries.map((e) {
            final node = _TreeNode(
              entity: e.value,
              depth: 0,
              initiallyExpanded:
                  expandTopLevel && e.value is Directory,
              projects: projects,
              selectedPath: selectedPath,
              entryFilePath: entryFilePath,
              onOpenFile: onOpenFile,
              onEntityMenu: onEntityMenu,
              onCreateFile: onCreateFile,
              onCreateFolder: onCreateFolder,
            );
            if (!animateEntrance) return node;
            return node
                .animate(delay: (e.key * 35).ms)
                .fadeIn(duration: 250.ms)
                .slideX(begin: -0.04, end: 0);
          }).toList(),
        );
      },
    );
  }
}

class _TreeNode extends StatefulWidget {
  final FileSystemEntity entity;
  final int depth;

  /// Start expanded (used by FileTree.expandTopLevel for the top
  /// level of a freshly imported project).
  final bool initiallyExpanded;
  final ProjectService projects;
  final String? selectedPath;
  final String? entryFilePath;
  final void Function(File file) onOpenFile;
  final void Function(FileSystemEntity entity) onEntityMenu;
  final void Function(Directory dir) onCreateFile;
  final void Function(Directory dir) onCreateFolder;

  const _TreeNode({
    required this.entity,
    required this.depth,
    this.initiallyExpanded = false,
    required this.projects,
    required this.selectedPath,
    this.entryFilePath,
    required this.onOpenFile,
    required this.onEntityMenu,
    required this.onCreateFile,
    required this.onCreateFolder,
  });

  @override
  State<_TreeNode> createState() => _TreeNodeState();
}

class _TreeNodeState extends State<_TreeNode> {
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
  }

  @override
  Widget build(BuildContext context) {
    final entity = widget.entity;
    final name = p.basename(entity.path);
    final isDir = entity is Directory;
    final selected = widget.selectedPath == entity.path;

    final icon = isDir
        ? Icon(
            _expanded ? Icons.folder_open : Icons.folder,
            size: 20,
            color: Theme.of(context).colorScheme.primary,
          )
        : Icon(_iconFor(name), size: 20, color: _colorFor(name, context));

    final row = InkWell(
      onTap: () {
        if (isDir) {
          setState(() => _expanded = !_expanded);
        } else {
          widget.onOpenFile(entity as File);
        }
      },
      onLongPress: () => widget.onEntityMenu(entity),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: EdgeInsets.only(
          left: 8.0 + widget.depth * 16,
          right: 8,
          top: 5,
          bottom: 5,
        ),
        decoration: selected
            ? BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .primaryContainer
                    .withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
              )
            : null,
        child: Row(
          children: [
            if (isDir)
              // The chevron rotates as the folder opens (v1.0.10, D).
              AnimatedRotation(
                turns: _expanded ? 0.25 : 0,
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeInOutCubic,
                child: Icon(
                  Icons.keyboard_arrow_right,
                  size: 18,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            icon,
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                  fontFamily: isDir ? null : 'monospace',
                  fontSize: 13.5,
                ),
              ),
            ),
            if (widget.entryFilePath == entity.path)
              Icon(
                Icons.play_arrow,
                size: 14,
                color: Theme.of(context).colorScheme.primary,
              ),
          ],
        ),
      ),
    );

    // Re-list synchronously on every build (audit fix, v1.0.3): files
    // created/renamed/deleted since the folder was opened show up
    // without collapsing and re-expanding the node.
    //
    // Smooth expand/collapse (v1.0.10, D): the children grow/shrink
    // over 250 ms (easeInOutCubic) instead of popping in and out.
    // AnimatedSize always wraps the children so the height animates
    // both ways; when collapsed the child is an empty box.
    final children =
        isDir && _expanded ? widget.projects.listChildrenSync(entity) : const <FileSystemEntity>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row,
        if (isDir)
          AnimatedSize(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeInOutCubic,
            alignment: Alignment.topCenter,
            child: !_expanded
                ? const SizedBox.shrink()
                : children.isEmpty
                    ? Padding(
                        padding: EdgeInsets.only(
                          left: 32.0 + widget.depth * 16,
                        ),
                        child: Text(
                          '(empty)',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: children
                            .map(
                              (e) => _TreeNode(
                                entity: e,
                                depth: widget.depth + 1,
                                projects: widget.projects,
                                selectedPath: widget.selectedPath,
                                entryFilePath: widget.entryFilePath,
                                onOpenFile: widget.onOpenFile,
                                onEntityMenu: widget.onEntityMenu,
                                onCreateFile: widget.onCreateFile,
                                onCreateFolder: widget.onCreateFolder,
                              ),
                            )
                            .toList(),
                      ),
          ),
      ],
    );
  }

  IconData _iconFor(String name) {
    final ext = p.extension(name).toLowerCase();
    return switch (ext) {
      '.py' => Icons.code,
      '.md' => Icons.article_outlined,
      '.txt' => Icons.description_outlined,
      '.json' => Icons.data_object,
      '.png' || '.jpg' || '.jpeg' || '.gif' => Icons.image_outlined,
      '.html' || '.css' || '.js' => Icons.language_outlined,
      '.csv' => Icons.table_chart_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
  }

  Color _colorFor(String name, BuildContext context) {
    final ext = p.extension(name).toLowerCase();
    final cs = Theme.of(context).colorScheme;
    return switch (ext) {
      '.py' => cs.primary,
      _ => cs.onSurfaceVariant,
    };
  }
}
