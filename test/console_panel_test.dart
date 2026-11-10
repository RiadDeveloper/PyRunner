// The real terminal (v1.0.4, C): typing directly in the console
// submits a command (no separate input box, no send button), and ANSI
// colours render as styled spans.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pyrunner/models.dart';
import 'package:pyrunner/services/console_service.dart';
import 'package:pyrunner/services/project_service.dart';
import 'package:pyrunner/services/python_service.dart';
import 'package:pyrunner/services/settings_service.dart';
import 'package:pyrunner/widgets/console_panel.dart';

void main() {
  late Directory tmp;
  late SettingsService settings;
  late PythonService python;
  late ConsoleService console;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService();
    await settings.init();
    python = PythonService();
    tmp = await Directory.systemTemp.createTemp('pyrunner-console-');
    await File('${tmp.path}/main.py').writeAsString('print(1)\n');
    console = ConsoleService(
      project: Project(name: 't', path: tmp.path),
      python: python,
      projects: ProjectService(),
    );
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Future<void> pumpConsole(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConsolePanel(
            console: console,
            python: python,
            settings: settings,
            expanded: true,
            onToggleExpanded: () {},
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('no send button; typing in the prompt submits a command',
      (tester) async {
    await pumpConsole(tester);

    // The old separate input box + send button are gone.
    expect(find.byIcon(Icons.send), findsNothing);
    // One inline prompt line, styled like the terminal.
    expect(find.text('pyrunner:~\$ '), findsWidgets);

    await tester.enterText(find.byType(TextField), 'help');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(
      python.lines.map((l) => l.text).join('\n'),
      contains('Available commands'),
    );
  });

  testWidgets('ANSI colours render as styled spans, not raw escapes',
      (tester) async {
    await pumpConsole(tester);

    python.addLine(
      ConsoleKind.output,
      '\x1b[31mred text\x1b[0m plain',
    );
    await tester.pump();

    // No raw escape text is visible anywhere.
    expect(find.textContaining('\x1b'), findsNothing);

    // The red span is rendered with the ANSI red colour.
    final rich = find.byWidgetPredicate((widget) {
      if (widget is! SelectableText) return false;
      final span = widget.textSpan;
      if (span == null) return false;
      return _flatten(span).any(
        (s) =>
            s.text == 'red text' &&
            s.style?.color == const Color(0xFFCD0000),
      );
    });
    expect(rich, findsOneWidget);
  });

  testWidgets('the console uses the console font size setting',
      (tester) async {
    await settings.setConsoleFontSize(18);
    await pumpConsole(tester);

    python.addLine(ConsoleKind.output, 'hello');
    await tester.pump();

    final rich = find.byWidgetPredicate((widget) {
      if (widget is! SelectableText) return false;
      final span = widget.textSpan;
      if (span == null) return false;
      return _flatten(span).any(
        (s) => s.text == 'hello' && s.style?.fontSize == 18,
      );
    });
    expect(rich, findsOneWidget);
  });
}

/// All TextSpans in a tree, depth-first.
List<TextSpan> _flatten(TextSpan span) {
  final out = <TextSpan>[span];
  for (final child in span.children ?? const <InlineSpan>[]) {
    if (child is TextSpan) out.addAll(_flatten(child));
  }
  return out;
}
