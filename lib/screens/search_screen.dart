import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models.dart';
import '../services/project_service.dart';

/// Search across all files of a project. Tapping a result pops it back
/// to the IDE, which opens the file at the match.
class SearchScreen extends StatefulWidget {
  final Project project;
  final ProjectService projects;

  const SearchScreen({
    super.key,
    required this.project,
    required this.projects,
  });

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _queryController = TextEditingController();
  bool _caseSensitive = false;
  bool _searching = false;
  bool _searched = false;
  List<SearchResult> _results = [];

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _queryController.text;
    if (q.isEmpty) return;
    setState(() {
      _searching = true;
      _searched = true;
    });
    final results = await widget.projects.searchInProject(
      widget.project,
      q,
      caseSensitive: _caseSensitive,
    );
    if (!mounted) return;
    setState(() {
      _results = results;
      _searching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Search in ${widget.project.name}',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _queryController,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: 'Search all files…',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.search),
                    ),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Match case',
                  icon: const Text(
                    'Aa',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  isSelected: _caseSensitive,
                  selectedIcon: Text(
                    'Aa',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: cs.primary,
                    ),
                  ),
                  onPressed: () {
                    setState(() => _caseSensitive = !_caseSensitive);
                    if (_searched) _search();
                  },
                ),
                FilledButton(
                  onPressed: _search,
                  child: const Text('Search'),
                ),
              ],
            ),
          ),
          if (_searching) const LinearProgressIndicator(),
          Expanded(
            child: _results.isEmpty
                ? Center(
                    child: Text(
                      _searched
                          ? 'No matches.'
                          : 'Type a query and search.',
                    ),
                  )
                : ListView.builder(
                    itemCount: _results.length,
                    itemBuilder: (context, i) {
                      final r = _results[i];
                      return ListTile(
                        leading: const Icon(Icons.code, size: 20),
                        title: Text(
                          r.lineText.isEmpty ? '(empty line)' : r.lineText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 13,
                          ),
                        ),
                        subtitle: Text(
                          '${p.relative(r.filePath, from: widget.project.path)}:${r.lineNumber}',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                        onTap: () => Navigator.of(context).pop(r),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
