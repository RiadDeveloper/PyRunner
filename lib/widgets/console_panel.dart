import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../models.dart';
import '../services/ansi_parser.dart';
import '../services/console_service.dart';
import '../services/python_service.dart';
import '../services/settings_service.dart';

/// The built-in console, VS Code-style (v1.0.4): scrollable output
/// with ANSI colours, and typing directly in the terminal — an inline
/// prompt line at the bottom (`pyrunner:~$` when idle, `input> ` while
/// a script waits for input()). There is no separate input box and no
/// send button: tapping anywhere in the console focuses the keyboard,
/// and Enter submits. Typed text goes to the command line when idle
/// and to the script's stdin when a script is waiting for input().
///
/// Output renders ANSI SGR colours (colorama output shows its colours,
/// not raw escape text), `\r` progress lines overwrite instead of
/// stacking (see ConsoleLogStore), and everything is monospace so
/// box-drawing borders stay aligned. Logs stay per project, and Clear
/// only clears the current project's log.
class ConsolePanel extends StatefulWidget {
  final ConsoleService console;
  final PythonService python;
  final SettingsService settings;
  final bool expanded;
  final VoidCallback onToggleExpanded;

  const ConsolePanel({
    super.key,
    required this.console,
    required this.python,
    required this.settings,
    required this.expanded,
    required this.onToggleExpanded,
  });

  @override
  State<ConsolePanel> createState() => _ConsolePanelState();
}

class _ConsolePanelState extends State<ConsolePanel>
    with SingleTickerProviderStateMixin {
  final _inputController = TextEditingController();
  final _focusNode = FocusNode();
  final _scrollController = ScrollController();
  bool _stickToBottom = true;
  List<ConsoleSuggestion> _suggestions = [];

  /// Subtle "running" pulse (v1.0.10, D): the Running indicator in
  /// the header gently fades 0.55 → 1.0 while a run is in flight.
  /// 1.2 s, easeInOut — noticeable, never distracting.
  late final AnimationController _pulseController;
  late final Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _pulse = Tween<double>(begin: 0.55, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _pulseController.repeat(reverse: true);
    _inputController.addListener(_updateSuggestions);
    _scrollController.addListener(() {
      if (!_scrollController.hasClients) return;
      final pos = _scrollController.position;
      _stickToBottom = pos.pixels >= pos.maxScrollExtent - 40;
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _inputController.removeListener(_updateSuggestions);
    _inputController.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _updateSuggestions() {
    final next = widget.console.suggestionsFor(_inputController.text);
    if (!_sameSuggestions(_suggestions, next)) {
      setState(() => _suggestions = next);
    }
  }

  bool _sameSuggestions(
    List<ConsoleSuggestion> a,
    List<ConsoleSuggestion> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].insert != b[i].insert) return false;
    }
    return true;
  }

  void _applySuggestion(ConsoleSuggestion suggestion) {
    _inputController.text = suggestion.insert;
    _inputController.selection = TextSelection.fromPosition(
      TextPosition(offset: suggestion.insert.length),
    );
    _focusNode.requestFocus();
  }

  /// Chips are only useful while the user is typing a shell command:
  /// not while a script waits for input(), in the Python REPL, or while
  /// a script is running (the input line is disabled then).
  bool get _showSuggestions {
    if (!widget.expanded || _suggestions.isEmpty) return false;
    if (_inputController.text.isEmpty) return false;
    if (widget.python.waitingForInput || widget.console.replMode) {
      return false;
    }
    if (widget.python.isRunning) return false;
    return true;
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
    );
  }

  void _submit() {
    final text = _inputController.text;
    _inputController.clear();
    widget.console.execute(text);
    _focusNode.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    // Ctrl+C is the keyboard equivalent of Stop.
    if (event.logicalKey == LogicalKeyboardKey.keyC &&
        HardwareKeyboard.instance.isControlPressed) {
      if (widget.python.isRunning) {
        widget.python.stopRun();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    // Ctrl+D sends EOF to the running script (v1.0.10): input()
    // raises EOFError instead of waiting forever.
    if (event.logicalKey == LogicalKeyboardKey.keyD &&
        HardwareKeyboard.instance.isControlPressed) {
      if (widget.python.isRunning) {
        widget.console.sendEof();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      if (_suggestions.isNotEmpty) {
        _applySuggestion(_suggestions.first);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      final text = widget.console.historyUp(_inputController.text);
      _inputController.text = text;
      _inputController.selection = TextSelection.fromPosition(
        TextPosition(offset: text.length),
      );
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      final text = widget.console.historyDown(_inputController.text);
      _inputController.text = text;
      _inputController.selection = TextSelection.fromPosition(
        TextPosition(offset: text.length),
      );
      return KeyEventResult.ignored;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final mono = TextStyle(
      fontFamily: 'monospace',
      fontSize: widget.settings.consoleFontSize,
    );
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
        border: Border(
          top: BorderSide(color: cs.outlineVariant),
        ),
      ),
      child: Column(
        children: [
          // Header
          InkWell(
            onTap: widget.onToggleExpanded,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  Icon(Icons.terminal, size: 18, color: cs.primary),
                  const SizedBox(width: 6),
                  const Text(
                    'Console',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ListenableBuilder(
                      listenable: widget.console,
                      builder: (context, _) => Text(
                        widget.console.prompt,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: cs.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  ListenableBuilder(
                    listenable: widget.python,
                    builder: (context, _) {
                      if (!widget.python.isRunning) {
                        return const SizedBox.shrink();
                      }
                      // Subtle pulse while running (v1.0.10, D).
                      return Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: FadeTransition(
                          opacity: _pulse,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: cs.primary,
                                ),
                              ),
                              const SizedBox(width: 6),
                              const Text('Running',
                                  style: TextStyle(fontSize: 12)),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                  IconButton(
                    tooltip: 'Copy log',
                    icon: const Icon(Icons.copy, size: 20),
                    onPressed: () {
                      final text = widget.python.lines
                          .map((l) => '${_time(l.time)} ${stripAnsi(l.text)}')
                          .join('\n');
                      Clipboard.setData(ClipboardData(text: text));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Console log copied.'),
                        ),
                      );
                    },
                  ),
                  IconButton(
                    tooltip: 'Share log',
                    icon: const Icon(Icons.share, size: 20),
                    onPressed: () {
                      final text = widget.python.lines
                          .map((l) => '${_time(l.time)} ${stripAnsi(l.text)}')
                          .join('\n');
                      SharePlus.instance.share(
                        ShareParams(
                          text: text,
                          subject: 'PyRunner console log',
                        ),
                      );
                    },
                  ),
                  IconButton(
                    tooltip: 'Clear console',
                    icon: const Icon(Icons.clear_all, size: 20),
                    onPressed: widget.python.clear,
                  ),
                  if (widget.expanded)
                    IconButton(
                      tooltip: 'Stop',
                      icon: Icon(Icons.stop, size: 20, color: cs.error),
                      onPressed: widget.python.isRunning
                          ? () => widget.python.stopRun()
                          : null,
                    ),
                  Icon(
                    widget.expanded
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_up,
                    size: 20,
                  ),
                ],
              ),
            ),
          ),
          if (widget.expanded) ...[
            const Divider(height: 1),
            // Output — tapping anywhere focuses the keyboard so the
            // user types straight into the terminal.
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _focusNode.requestFocus,
                child: Stack(
                  children: [
                    ListenableBuilder(
                      listenable: widget.python,
                      builder: (context, _) {
                        // Auto-scroll when new lines arrive.
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (_stickToBottom) _scrollToBottom();
                        });
                        final lines = widget.python.lines;
                        return ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          itemCount: lines.length,
                          itemBuilder: (context, i) {
                            final line = lines[i];
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 1.5),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _time(line.time),
                                    style: mono.copyWith(
                                      color: cs.onSurfaceVariant.withValues(
                                        alpha: 0.65,
                                      ),
                                      fontSize: mono.fontSize! - 2,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: SelectableText.rich(
                                      TextSpan(
                                        children:
                                            _spansFor(line, mono, cs),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        );
                      },
                    ),
                    if (!_stickToBottom)
                      Positioned(
                        right: 12,
                        bottom: 8,
                        child: FloatingActionButton.small(
                          tooltip: 'Jump to latest output',
                          onPressed: () {
                            _stickToBottom = true;
                            _scrollToBottom();
                          },
                          child: const Icon(Icons.arrow_downward),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            // Suggestion chips (commands, history, file names).
            if (_showSuggestions) ...[
              const Divider(height: 1),
              SizedBox(
                height: 40,
                child: ListenableBuilder(
                  listenable:
                      Listenable.merge([widget.python, widget.console]),
                  builder: (context, _) {
                    if (!_showSuggestions) return const SizedBox.shrink();
                    return ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      itemCount: _suggestions.length,
                      itemBuilder: (context, i) {
                        final s = _suggestions[i];
                        return Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ActionChip(
                            label: Text(
                              s.display,
                              style: mono.copyWith(fontSize: 12),
                            ),
                            onPressed: () => _applySuggestion(s),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
            // Inline prompt line — part of the terminal, not a
            // separate input box. The prompt text is the shell prompt
            // (pyrunner:~$), the REPL prompt (>>>) or `input> ` while
            // a script waits for input().
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ListenableBuilder(
                    listenable: Listenable.merge(
                      [widget.console, widget.python],
                    ),
                    builder: (context, _) => Text(
                      widget.console.prompt,
                      style: mono.copyWith(
                        color: cs.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Focus(
                      onKeyEvent: _onKey,
                      child: ListenableBuilder(
                        listenable: widget.python,
                        builder: (context, _) {
                          final running = widget.python.isRunning;
                          final waiting = widget.python.waitingForInput;
                          return TextField(
                            controller: _inputController,
                            focusNode: _focusNode,
                            style: mono,
                            // v1.0.10: the input stays enabled while a
                            // script runs, so the user can type ahead
                            // into the script's stdin even if the
                            // input_request event was dropped — the
                            // console routes it to stdin, never to
                            // stop. A run is only stopped by the Stop
                            // button, `stop`, or Ctrl+C.
                            enabled: true,
                            autocorrect: false,
                            enableSuggestions: false,
                            textCapitalization: TextCapitalization.none,
                            maxLines: 1,
                            decoration: InputDecoration(
                              isDense: true,
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.zero,
                              hintText: waiting
                                  ? 'Type input for the script…'
                                  : running
                                      ? 'Type input for the running script… (stop to stop)'
                                      : widget.console.replMode
                                          ? 'Python code (exit() to leave REPL)…'
                                          : 'Type a command… (help for list)',
                              hintStyle: mono.copyWith(
                                color: cs.onSurfaceVariant.withValues(
                                  alpha: 0.6,
                                ),
                              ),
                            ),
                            onSubmitted: (_) => _submit(),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _time(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  Color _colorFor(ConsoleKind kind, ColorScheme cs) {
    return switch (kind) {
      ConsoleKind.input => cs.primary,
      ConsoleKind.output => cs.onSurface,
      ConsoleKind.error => cs.error,
      ConsoleKind.system => cs.onSurfaceVariant,
    };
  }

  /// Styled spans for one console line: ANSI colours win; a span
  /// without its own colour falls back to the kind colour (input =
  /// green, error = red, system = grey italic).
  List<TextSpan> _spansFor(
    ConsoleLine line,
    TextStyle mono,
    ColorScheme cs,
  ) {
    final parsed = parseAnsi(line.text);
    if (parsed.isEmpty) {
      return [TextSpan(text: ' ', style: mono)];
    }
    final baseColor = _colorFor(line.kind, cs);
    return parsed
        .map(
          (span) => TextSpan(
            text: span.text,
            style: mono.copyWith(
              color: span.foreground ?? baseColor,
              backgroundColor: span.background,
              fontWeight: span.bold || line.kind == ConsoleKind.input
                  ? FontWeight.w700
                  : FontWeight.w400,
              fontStyle: line.kind == ConsoleKind.system
                  ? FontStyle.italic
                  : FontStyle.normal,
            ),
          ),
        )
        .toList();
  }
}
