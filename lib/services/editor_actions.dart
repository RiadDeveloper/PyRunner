import 'package:flutter/services.dart';

/// Pure editor smarts for the code editor (auto-indent, auto-close
/// brackets/quotes, Tab indent). Kept free of widgets so it can be unit
/// tested without pumping the IDE.
///
/// The auto-edit logic works on the *text change* (old text -> new text),
/// not on raw key events, because Android soft keyboards send typed
/// characters through the text-input channel, not as key events. Tab /
/// Shift+Tab are the exception: they only exist on hardware keyboards,
/// so they are handled through [indentLines] from a key handler.

/// A text + selection replacement to apply to the editor controller.
class EditorEdit {
  final String text;
  final TextSelection selection;
  const EditorEdit(this.text, this.selection);
}

const _openers = '([{';
const _closers = ')]}';
const _pairs = {'(': ')', '[': ']', '{': '}', '"': '"', "'": "'"};

/// Called after the editor text changed by one user keystroke.
/// Returns a follow-up edit to apply, or null when the change needs
/// nothing extra. Only single-character insertions/deletions at the
/// cursor are considered; pastes, replacements and undo/redo (multi-char
/// changes) are left alone.
EditorEdit? autoEditOnTextChange({
  required String oldText,
  required String newText,
  required TextSelection selection,
  int indentSize = 4,
}) {
  if (!selection.isValid || !selection.isCollapsed) return null;
  final cursor = selection.extentOffset;
  if (cursor < 0 || cursor > newText.length) return null;

  // --- single-character insertion ---
  // The cursor sits right after the inserted char, so the insertion
  // index is cursor - 1. (A common-prefix diff mislocates the insertion
  // when the typed char equals the following char, e.g. typing ')' right
  // before an existing ')'.)
  if (newText.length == oldText.length + 1) {
    final i = cursor - 1;
    if (i < 0) return null;
    // Verify the change is exactly one inserted char at the cursor.
    if (newText.substring(0, i) + newText.substring(i + 1) != oldText) {
      return null;
    }
    final inserted = newText[i];

    if (inserted == '\n') {
      final indent = _indentForNewLine(oldText, i, indentSize);
      if (indent.isEmpty) return null;
      return EditorEdit(
        newText.substring(0, cursor) + indent + newText.substring(cursor),
        TextSelection.collapsed(offset: cursor + indent.length),
      );
    }

    if (_openers.contains(inserted)) {
      final closer = _pairs[inserted]!;
      return EditorEdit(
        newText.substring(0, cursor) + closer + newText.substring(cursor),
        TextSelection.collapsed(offset: cursor),
      );
    }

    if (inserted == '"' || inserted == "'") {
      // Type-over: the cursor sits right before the same quote.
      if (cursor < newText.length && newText[cursor] == inserted) {
        return EditorEdit(
          newText.substring(0, i) + newText.substring(i + 1),
          TextSelection.collapsed(offset: i + 1),
        );
      }
      // Odd number of this quote earlier on the line means the cursor is
      // inside a string already: the user is closing it, so insert just
      // the one quote.
      final lineStart = oldText.lastIndexOf('\n', i - 1) + 1;
      final before = oldText.substring(lineStart, i);
      var count = 0;
      for (var k = 0; k < before.length; k++) {
        if (before[k] == inserted) count++;
      }
      if (count.isOdd) return null;
      // Only auto-close when the next char can end a string literal.
      final next = cursor < newText.length ? newText[cursor] : '';
      if (next.isEmpty ||
          next == ' ' ||
          next == '\t' ||
          next == '\n' ||
          ')]}:;,'.contains(next)) {
        return EditorEdit(
          newText.substring(0, cursor) + inserted + newText.substring(cursor),
          TextSelection.collapsed(offset: cursor),
        );
      }
      return null;
    }

    if (_closers.contains(inserted)) {
      // Type-over an auto-inserted closer.
      if (cursor < newText.length && newText[cursor] == inserted) {
        return EditorEdit(
          newText.substring(0, i) + newText.substring(i + 1),
          TextSelection.collapsed(offset: i + 1),
        );
      }
      return null;
    }
    return null;
  }

  // --- single-character deletion (Backspace on an empty pair) ---
  // After a deletion the cursor sits where the deleted char was.
  if (newText.length == oldText.length - 1) {
    final i = cursor;
    if (i < 0 || i >= oldText.length) return null;
    if (oldText.substring(0, i) + oldText.substring(i + 1) != newText) {
      return null;
    }
    final deleted = oldText[i];
    final closer = _pairs[deleted];
    if (closer != null && i < newText.length && newText[i] == closer) {
      return EditorEdit(
        newText.substring(0, i) + newText.substring(i + 1),
        TextSelection.collapsed(offset: i),
      );
    }
  }
  return null;
}

/// Leading whitespace for the line created by the Enter at [newlineIndex]
/// in [oldText] (the '\n' was inserted at that index). Carries the
/// previous line's indent, plus one extra level when it ends with ':'.
String _indentForNewLine(String oldText, int newlineIndex, int indentSize) {
  final lineStart = oldText.lastIndexOf('\n', newlineIndex - 1) + 1;
  final prevLine = oldText.substring(lineStart, newlineIndex);
  if (prevLine.trim().isEmpty) return '';
  final leading = RegExp(r'^[ \t]*').firstMatch(prevLine)?.group(0) ?? '';
  var indent = leading;
  if (prevLine.trimRight().endsWith(':')) indent += ' ' * indentSize;
  return indent;
}

/// Tab / Shift+Tab: indent or outdent the lines covered by [selection]
/// (the current line when the selection is collapsed). Returns the new
/// text + selection.
EditorEdit indentLines({
  required String text,
  required TextSelection selection,
  required bool outdent,
  int indentSize = 4,
}) {
  final anchor = selection.start < 0 ? 0 : selection.start;
  final extent = selection.end < 0 ? 0 : selection.end;
  final lo = anchor <= extent ? anchor : extent;
  final hi = anchor <= extent ? extent : anchor;

  final lineStarts = <int>[0];
  for (var i = 0; i < text.length; i++) {
    if (text[i] == '\n') lineStarts.add(i + 1);
  }
  int lineOf(int offset) {
    var line = 0;
    for (var i = 0; i < lineStarts.length; i++) {
      if (lineStarts[i] <= offset) line = i;
    }
    return line;
  }

  final firstLine = lineOf(lo);
  final lastLine = hi > lo ? lineOf(hi - 1) : firstLine;

  var newText = text;
  var newAnchor = anchor;
  var newExtent = extent;
  // Last line first, so earlier lines' offsets stay valid.
  for (var line = lastLine; line >= firstLine; line--) {
    final s = lineStarts[line];
    if (outdent) {
      var r = 0;
      while (r < indentSize &&
          s + r < newText.length &&
          newText[s + r] == ' ') {
        r++;
      }
      if (r == 0 && s < newText.length && newText[s] == '\t') r = 1;
      if (r == 0) continue;
      newText = newText.substring(0, s) + newText.substring(s + r);
      newAnchor = _shiftAfterRemoval(newAnchor, s, r);
      newExtent = _shiftAfterRemoval(newExtent, s, r);
    } else {
      final unit = ' ' * indentSize;
      newText = newText.substring(0, s) + unit + newText.substring(s);
      if (newAnchor >= s) newAnchor += unit.length;
      if (newExtent >= s) newExtent += unit.length;
    }
  }
  return EditorEdit(
    newText,
    TextSelection(baseOffset: newAnchor, extentOffset: newExtent),
  );
}

int _shiftAfterRemoval(int offset, int lineStart, int removed) {
  if (offset >= lineStart + removed) return offset - removed;
  if (offset > lineStart) return lineStart;
  return offset;
}
