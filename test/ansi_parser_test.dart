// ANSI SGR parsing for the console (v1.0.4): colorama output shows
// its colours, not raw escape text.

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pyrunner/services/ansi_parser.dart';

void main() {
  test('plain text without escapes is one unstyled span', () {
    final spans = parseAnsi('Hello, world!');
    expect(spans.length, 1);
    expect(spans.first.text, 'Hello, world!');
    expect(spans.first.foreground, isNull);
    expect(spans.first.background, isNull);
    expect(spans.first.bold, isFalse);
  });

  test('empty input gives no spans', () {
    expect(parseAnsi(''), isEmpty);
  });

  test('foreground colour spans (30-37)', () {
    final spans = parseAnsi('\x1b[31mred\x1b[0m plain');
    expect(spans.length, 2);
    expect(spans[0].text, 'red');
    expect(spans[0].foreground, const Color(0xFFCD0000));
    expect(spans[1].text, ' plain');
    expect(spans[1].foreground, isNull);
  });

  test('bright foreground colours (90-97)', () {
    final spans = parseAnsi('\x1b[92mbright green');
    expect(spans.length, 1);
    expect(spans.first.foreground, const Color(0xFF00FF00));
  });

  test('background colour spans (40-47)', () {
    final spans = parseAnsi('\x1b[41mred bg');
    expect(spans.first.background, const Color(0xFFCD0000));
    expect(spans.first.foreground, isNull);
  });

  test('bold flag', () {
    final spans = parseAnsi('\x1b[1mbold\x1b[22m normal');
    expect(spans[0].bold, isTrue);
    expect(spans[1].bold, isFalse);
  });

  test('combined codes in one sequence (bold + colour)', () {
    final spans = parseAnsi('\x1b[1;32mbold green\x1b[0m');
    expect(spans.length, 1);
    expect(spans.first.text, 'bold green');
    expect(spans.first.bold, isTrue);
    expect(spans.first.foreground, const Color(0xFF00CD00));
  });

  test('reset clears colour and bold', () {
    final spans = parseAnsi('\x1b[1;31mbold red\x1b[0mplain');
    expect(spans.length, 2);
    expect(spans[1].text, 'plain');
    expect(spans[1].foreground, isNull);
    expect(spans[1].bold, isFalse);
  });

  test('default colour codes 39 / 49 clear fg / bg', () {
    final spans = parseAnsi('\x1b[31;42mtext\x1b[39m fg-clear \x1b[49m bg-clear');
    expect(spans[0].foreground, const Color(0xFFCD0000));
    expect(spans[0].background, const Color(0xFF00CD00));
    expect(spans[1].foreground, isNull);
    expect(spans[1].background, const Color(0xFF00CD00));
    expect(spans[2].background, isNull);
  });

  test('256-colour foreground (38;5;n)', () {
    // 196 is bright red in the 6x6x6 cube.
    final spans = parseAnsi('\x1b[38;5;196mred196');
    expect(spans.first.foreground, const Color(0xFFFF0000));
  });

  test('truecolour foreground (38;2;r;g;b)', () {
    final spans = parseAnsi('\x1b[38;2;10;20;30mrgb');
    expect(spans.first.foreground, const Color(0xFF0A141E));
  });

  test('non-SGR sequences are dropped (clear screen, cursor moves)', () {
    final spans = parseAnsi('\x1b[2J\x1b[Hhello\x1b[1Aworld');
    expect(spans.map((s) => s.text).join(), 'helloworld');
  });

  test('a colourama-style banner keeps its text and colours', () {
    final spans = parseAnsi(
      '\x1b[36m║ \x1b[1;32m★ READY \x1b[0m\x1b[36m ║',
    );
    expect(spans.map((s) => s.text).join(), '║ ★ READY  ║');
    expect(spans[1].bold, isTrue);
    expect(spans[1].foreground, const Color(0xFF00CD00));
  });

  test('stripAnsi removes escapes for copy/share', () {
    expect(stripAnsi('\x1b[1;31mError:\x1b[0m boom'), 'Error: boom');
    expect(stripAnsi('plain text'), 'plain text');
    expect(stripAnsi(''), '');
  });
}
