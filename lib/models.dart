/// A Python project.
///
/// [inPlace] (v1.0.4): the project lives in its original folder on
/// shared storage ("Open folder") instead of a copy inside the app's
/// private workspace. In-place projects are never copied, moved or
/// deleted by the app — deleting one from the list only forgets it.
class Project {
  final String name;
  final String path;
  final bool inPlace;

  const Project({
    required this.name,
    required this.path,
    this.inPlace = false,
  });

  @override
  bool operator ==(Object other) =>
      other is Project && other.path == path;

  @override
  int get hashCode => path.hashCode;
}

/// One line shown in the built-in console.
enum ConsoleKind { input, output, error, system }

class ConsoleLine {
  final ConsoleKind kind;
  final String text;
  final DateTime time;

  ConsoleLine({required this.kind, required this.text})
      : time = DateTime.now();
}

/// An open editor tab.
class EditorTab {
  final String path;
  final String name;
  bool dirty;

  EditorTab({required this.path, required this.name, this.dirty = false});
}

/// One match when searching across a project's files.
class SearchResult {
  final String filePath;
  final int lineNumber; // 1-based
  final int column; // 0-based offset of the match within the line
  final String lineText;

  const SearchResult({
    required this.filePath,
    required this.lineNumber,
    required this.column,
    required this.lineText,
  });
}
