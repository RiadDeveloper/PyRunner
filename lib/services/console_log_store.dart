import '../models.dart';

/// Per-project console state.
///
/// Each project's log lines, run state and input-wait state live under
/// its project path, so switching projects never shows another
/// project's log and a script running in project A never leaks output
/// into project B's console (v1.0.3 — before this, PythonService held
/// one app-wide `lines` list and one `isRunning` flag).
///
/// Partial lines (v1.0.4): a script's `\r` progress writes and input()
/// prompts arrive without a trailing newline. The bridge tags those
/// chunks as partial, and the store keeps at most one *open* line per
/// project: a new partial chunk replaces the open line, and the next
/// complete output line replaces it too — exactly like a terminal, so
/// a loading bar never stacks into dozens of duplicate lines. Input
/// and system lines always append, so a prompt is never overwritten
/// by the echoed answer.
///
/// Pure Dart, no platform calls — fully unit tested.
class ConsoleLogStore {
  final Map<String, List<ConsoleLine>> _logs = {};
  final Map<String, bool> _running = {};
  final Map<String, bool> _waitingForInput = {};

  /// Projects whose last line is still open (a partial line: no
  /// trailing newline yet). Only output/error lines can be open.
  final Set<String> _openLine = {};

  /// The log lines for [projectPath] (created on first use).
  List<ConsoleLine> linesFor(String projectPath) =>
      _logs.putIfAbsent(projectPath, () => []);

  /// Whether the last line of [projectPath] is an open partial line.
  bool hasOpenLine(String projectPath) => _openLine.contains(projectPath);

  /// Add a complete line. When the last line is an open output/error
  /// line and this line is output/error too, it *completes* that line
  /// (replaces its text) instead of appending — e.g. `print("hi",
  /// end="")` flushed as a partial line, then `print(" there")`
  /// completing it into one "hi there" line.
  void add(String projectPath, ConsoleKind kind, String text) {
    final lines = linesFor(projectPath);
    if (_openLine.contains(projectPath) &&
        lines.isNotEmpty &&
        (kind == ConsoleKind.output || kind == ConsoleKind.error) &&
        (lines.last.kind == ConsoleKind.output ||
            lines.last.kind == ConsoleKind.error)) {
      lines[lines.length - 1] = ConsoleLine(kind: kind, text: text);
      _openLine.remove(projectPath);
      return;
    }
    lines.add(ConsoleLine(kind: kind, text: text));
    _openLine.remove(projectPath);
    // Keep memory bounded on very long runs.
    if (lines.length > 5000) {
      lines.removeRange(0, lines.length - 5000);
    }
  }

  /// Add (or replace) a partial line: a `\r` progress update or an
  /// input() prompt. When the last line is already open, its text is
  /// replaced; otherwise a new open line is appended.
  void addPartial(String projectPath, ConsoleKind kind, String text) {
    final lines = linesFor(projectPath);
    if (_openLine.contains(projectPath) &&
        lines.isNotEmpty &&
        (lines.last.kind == ConsoleKind.output ||
            lines.last.kind == ConsoleKind.error)) {
      lines[lines.length - 1] = ConsoleLine(kind: kind, text: text);
    } else {
      lines.add(ConsoleLine(kind: kind, text: text));
      if (lines.length > 5000) {
        lines.removeRange(0, lines.length - 5000);
      }
    }
    _openLine.add(projectPath);
  }

  /// Clear only [projectPath]'s log; other projects are untouched.
  void clear(String projectPath) {
    _logs[projectPath]?.clear();
    _openLine.remove(projectPath);
  }

  /// Clear every project's log (Settings: "Clear all console logs").
  void clearAll() {
    _logs.clear();
    _openLine.clear();
  }

  bool isRunning(String projectPath) => _running[projectPath] ?? false;

  void setRunning(String projectPath, bool value) {
    _running[projectPath] = value;
  }

  bool isWaitingForInput(String projectPath) =>
      _waitingForInput[projectPath] ?? false;

  void setWaitingForInput(String projectPath, bool value) {
    _waitingForInput[projectPath] = value;
  }
}
