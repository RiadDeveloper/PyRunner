// Unit tests for the editor smarts in lib/services/editor_actions.dart.
// Pure text/selection functions — no widgets, no device needed.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pyrunner/services/editor_actions.dart';

TextSelection collapsed(int offset) =>
    TextSelection.collapsed(offset: offset);

void main() {
  group('autoEditOnTextChange', () {
    test('auto-indent: extra level after a line ending with :', () {
      final edit = autoEditOnTextChange(
        oldText: 'if x:',
        newText: 'if x:\n',
        selection: collapsed(6),
      );
      expect(edit, isNotNull);
      expect(edit!.text, 'if x:\n    ');
      expect(edit.selection.extentOffset, 10);
    });

    test('auto-indent: carries the previous line indent', () {
      final edit = autoEditOnTextChange(
        oldText: 'def f():\n    pass',
        newText: 'def f():\n    pass\n',
        selection: collapsed(18),
      );
      expect(edit, isNotNull);
      expect(edit!.text, 'def f():\n    pass\n    ');
      expect(edit.selection.extentOffset, 22);
    });

    test('auto-indent: no indent after a blank line', () {
      final edit = autoEditOnTextChange(
        oldText: 'a = 1\n',
        newText: 'a = 1\n\n',
        selection: collapsed(6),
      );
      expect(edit, isNull);
    });

    test('auto-close: ( inserts ) with cursor between', () {
      final edit = autoEditOnTextChange(
        oldText: 'print',
        newText: 'print(',
        selection: collapsed(6),
      );
      expect(edit, isNotNull);
      expect(edit!.text, 'print()');
      expect(edit.selection.extentOffset, 6);
    });

    test('auto-close: [ inserts ]', () {
      final edit = autoEditOnTextChange(
        oldText: 'a = ',
        newText: 'a = [',
        selection: collapsed(5),
      );
      expect(edit, isNotNull);
      expect(edit!.text, 'a = []');
      expect(edit.selection.extentOffset, 5);
    });

    test('auto-close: " inserts closing quote', () {
      final edit = autoEditOnTextChange(
        oldText: 'x = ',
        newText: 'x = "',
        selection: collapsed(5),
      );
      expect(edit, isNotNull);
      expect(edit!.text, 'x = ""');
      expect(edit.selection.extentOffset, 5);
    });

    test('quote inside a string is NOT auto-closed', () {
      final edit = autoEditOnTextChange(
        oldText: 'x = "ab',
        newText: 'x = "ab"',
        selection: collapsed(8),
      );
      expect(edit, isNull);
    });

    test('type-over: typing ) before an auto-inserted ) just moves past',
        () {
      final edit = autoEditOnTextChange(
        oldText: 'print()',
        newText: 'print())',
        selection: collapsed(7),
      );
      expect(edit, isNotNull);
      expect(edit!.text, 'print()');
      expect(edit.selection.extentOffset, 7);
    });

    test('backspace on an empty pair deletes both', () {
      final edit = autoEditOnTextChange(
        oldText: '()',
        newText: ')',
        selection: collapsed(0),
      );
      expect(edit, isNotNull);
      expect(edit!.text, '');
      expect(edit.selection.extentOffset, 0);
    });

    test('plain typing and pastes are left alone', () {
      expect(
        autoEditOnTextChange(
          oldText: 'abc',
          newText: 'abcd',
          selection: collapsed(4),
        ),
        isNull,
      );
      expect(
        autoEditOnTextChange(
          oldText: '',
          newText: 'hello',
          selection: collapsed(5),
        ),
        isNull,
      );
    });
  });

  group('indentLines', () {
    test('Tab indents the current line by 4 spaces', () {
      final edit = indentLines(
        text: 'def f():\n    pass',
        selection: collapsed(0),
        outdent: false,
      );
      expect(edit.text, '    def f():\n    pass');
      expect(edit.selection.extentOffset, 4);
    });

    test('Shift+Tab removes one indent level', () {
      final edit = indentLines(
        text: '    pass',
        selection: collapsed(4),
        outdent: true,
      );
      expect(edit.text, 'pass');
      expect(edit.selection.extentOffset, 0);
    });

    test('Tab with a multi-line selection indents every line', () {
      final edit = indentLines(
        text: 'a = 1\nb = 2',
        selection: const TextSelection(baseOffset: 0, extentOffset: 9),
        outdent: false,
      );
      expect(edit.text, '    a = 1\n    b = 2');
      expect(edit.selection.baseOffset, 4);
      expect(edit.selection.extentOffset, 17);
    });

    test('Shift+Tab on an unindented line is a no-op', () {
      final edit = indentLines(
        text: 'pass',
        selection: collapsed(2),
        outdent: true,
      );
      expect(edit.text, 'pass');
      expect(edit.selection.extentOffset, 2);
    });
  });
}
