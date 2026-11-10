import 'dart:ui';

/// ANSI SGR (Select Graphic Rendition) parsing for the console
/// (v1.0.4): the user's projects use colorama, so their output is full
/// of escape sequences. The console renders them as styled spans —
/// like VS Code's terminal — instead of showing raw escape text.
///
/// Supported: foreground 30-37 / 90-97, background 40-47 / 100-107,
/// bold (1), reset (0), default colours (39 / 49), 256-colour
/// (38;5;n / 48;5;n) and truecolour (38;2;r;g;b / 48;2;r;g;b).
/// Other escape sequences (cursor moves, clear screen, …) are dropped.
/// Pure Dart — fully unit tested.
class AnsiSpan {
  final String text;
  final Color? foreground;
  final Color? background;
  final bool bold;

  const AnsiSpan({
    required this.text,
    this.foreground,
    this.background,
    this.bold = false,
  });

  @override
  bool operator ==(Object other) =>
      other is AnsiSpan &&
      other.text == text &&
      other.foreground == foreground &&
      other.background == background &&
      other.bold == bold;

  @override
  int get hashCode => Object.hash(text, foreground, background, bold);

  @override
  String toString() =>
      'AnsiSpan($text, fg=$foreground, bg=$background, bold=$bold)';
}

/// The 16 standard terminal colours (xterm palette).
const _ansiColors = <int, Color>{
  0: Color(0xFF000000), // black
  1: Color(0xFFCD0000), // red
  2: Color(0xFF00CD00), // green
  3: Color(0xFFCDCD00), // yellow
  4: Color(0xFF0000EE), // blue
  5: Color(0xFFCD00CD), // magenta
  6: Color(0xFF00CDCD), // cyan
  7: Color(0xFFE5E5E5), // white
  8: Color(0xFF7F7F7F), // bright black (grey)
  9: Color(0xFFFF0000), // bright red
  10: Color(0xFF00FF00), // bright green
  11: Color(0xFFFFFF00), // bright yellow
  12: Color(0xFF5C5CFF), // bright blue
  13: Color(0xFFFF00FF), // bright magenta
  14: Color(0xFF00FFFF), // bright cyan
  15: Color(0xFFFFFFFF), // bright white
};

Color _color256(int n) {
  if (n < 16) return _ansiColors[n]!;
  if (n < 232) {
    // 6x6x6 colour cube.
    final v = n - 16;
    int level(int c) => c == 0 ? 0 : 55 + c * 40;
    return Color.fromARGB(
      0xFF,
      level(v ~/ 36),
      level((v % 36) ~/ 6),
      level(v % 6),
    );
  }
  // Greyscale ramp.
  final g = 8 + (n - 232) * 10;
  return Color.fromARGB(0xFF, g, g, g);
}

/// Parse [input] into styled spans. Plain text (no escapes) comes back
/// as a single unstyled span; an empty input gives no spans.
List<AnsiSpan> parseAnsi(String input) {
  final spans = <AnsiSpan>[];
  Color? fg;
  Color? bg;
  var bold = false;
  final buf = StringBuffer();

  void flush() {
    if (buf.isEmpty) return;
    spans.add(
      AnsiSpan(
        text: buf.toString(),
        foreground: fg,
        background: bg,
        bold: bold,
      ),
    );
    buf.clear();
  }

  var i = 0;
  while (i < input.length) {
    final ch = input[i];
    if (ch == '\x1b' && i + 1 < input.length && input[i + 1] == '[') {
      // CSI sequence: ESC [ ... <final byte>. Only 'm' (SGR) changes
      // styling; every other CSI sequence is dropped.
      var j = i + 2;
      while (j < input.length) {
        final c = input[j];
        if ((c.codeUnitAt(0) >= 0x40 && c.codeUnitAt(0) <= 0x7E)) break;
        j++;
      }
      if (j >= input.length) break; // Truncated sequence: drop it.
      final finalByte = input[j];
      final params = input.substring(i + 2, j);
      i = j + 1;
      if (finalByte != 'm') continue;
      flush();
      final codes = params.isEmpty
          ? <int>[0]
          : params
              .split(';')
              .map((s) => int.tryParse(s) ?? -1)
              .toList();
      var k = 0;
      while (k < codes.length) {
        final code = codes[k];
        if (code == 0) {
          fg = null;
          bg = null;
          bold = false;
        } else if (code == 1) {
          bold = true;
        } else if (code == 22) {
          bold = false;
        } else if (code == 39) {
          fg = null;
        } else if (code == 49) {
          bg = null;
        } else if (code >= 30 && code <= 37) {
          fg = _ansiColors[code - 30];
        } else if (code >= 90 && code <= 97) {
          fg = _ansiColors[code - 90 + 8];
        } else if (code >= 40 && code <= 47) {
          bg = _ansiColors[code - 40];
        } else if (code >= 100 && code <= 107) {
          bg = _ansiColors[code - 100 + 8];
        } else if ((code == 38 || code == 48) && k + 1 < codes.length) {
          final targetFg = code == 38;
          if (codes[k + 1] == 5 && k + 2 < codes.length) {
            final color = _color256(codes[k + 2].clamp(0, 255));
            if (targetFg) {
              fg = color;
            } else {
              bg = color;
            }
            k += 2;
          } else if (codes[k + 1] == 2 && k + 4 < codes.length) {
            final color = Color.fromARGB(
              0xFF,
              codes[k + 2].clamp(0, 255),
              codes[k + 3].clamp(0, 255),
              codes[k + 4].clamp(0, 255),
            );
            if (targetFg) {
              fg = color;
            } else {
              bg = color;
            }
            k += 4;
          }
        }
        k++;
      }
      continue;
    }
    if (ch == '\x1b') {
      // A lone ESC (or a non-CSI sequence): drop it.
      i++;
      continue;
    }
    buf.write(ch);
    i++;
  }
  flush();
  return spans;
}

/// Strip every ANSI escape sequence, leaving plain text. Used for the
/// copy/share log actions so the clipboard never contains raw escapes.
String stripAnsi(String input) {
  final spans = parseAnsi(input);
  if (spans.isEmpty) return '';
  if (spans.length == 1 && spans.first.foreground == null) {
    // Fast path: parseAnsi already validated the text is escape-free.
    return spans.first.text;
  }
  return spans.map((s) => s.text).join();
}
