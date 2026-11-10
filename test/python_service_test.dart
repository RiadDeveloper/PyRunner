// PythonService per-project log API (v1.0.3).
//
// setActiveProject scopes lines / isRunning / clear to one project, so
// switching projects never shows another project's log and Clear only
// clears the current project's log. No MethodChannel is touched here
// (init() is not called), so no platform mocks are needed.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pyrunner/services/python_service.dart';

void main() {
  test('lines follow the active project; clear only clears it', () {
    final python = PythonService();

    python.setActiveProject('/a');
    python.addSystem('hello A');

    python.setActiveProject('/b');
    expect(python.lines, isEmpty);
    python.addSystem('hello B');
    expect(python.lines.map((l) => l.text), ['hello B']);

    python.setActiveProject('/a');
    expect(python.lines.map((l) => l.text), ['hello A']);

    python.clear();
    expect(python.lines, isEmpty);

    python.setActiveProject('/b');
    expect(python.lines.map((l) => l.text), ['hello B']);
  });

  test('setActiveProject to the same project keeps its log', () {
    final python = PythonService();
    python.setActiveProject('/a');
    python.addSystem('hello A');
    python.setActiveProject('/a');
    expect(python.lines.map((l) => l.text), ['hello A']);
  });

  test('clearAllLogs erases every project log', () {
    final python = PythonService();
    python.setActiveProject('/a');
    python.addSystem('hello A');
    python.setActiveProject('/b');
    python.addSystem('hello B');

    python.clearAllLogs();

    expect(python.lines, isEmpty);
    python.setActiveProject('/a');
    expect(python.lines, isEmpty);
  });

  // Event-stream routing (v1.0.4): the bridge tags flushed partial
  // lines (\r progress, input() prompts) with replace=true, and the
  // service routes them to the store's partial-line handling.
  testWidgets('partial out events replace the open line', (tester) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final python = PythonService();
    python.setActiveProject('/a');

    MockStreamHandlerEventSink? sink;
    const channel = EventChannel('com.pyrunner.app/python_output');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
      channel,
      MockStreamHandler.inline(
        onListen: (args, events) {
          sink = events;
        },
      ),
    );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance
          .defaultBinaryMessenger
          .setMockStreamHandler(channel, null),
    );

    python.init();
    await tester.pump();
    expect(sink, isNotNull);

    void send(Map<String, Object> event) => sink!.success(event);

    send({'type': 'out', 'text': 'step 1 done'});
    await tester.pump();
    send({'type': 'out', 'text': 'Loading 10%', 'replace': true});
    await tester.pump();
    send({'type': 'out', 'text': 'Loading 50%', 'replace': true});
    await tester.pump();
    expect(
      python.lines.map((l) => l.text),
      ['step 1 done', 'Loading 50%'],
    );

    // A complete line finishes the open progress line.
    send({'type': 'out', 'text': 'Loading done'});
    await tester.pump();
    expect(
      python.lines.map((l) => l.text),
      ['step 1 done', 'Loading done'],
    );

    python.dispose();
  });

  testWidgets('run_started / run_finished events drive isRunning',
      (tester) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final python = PythonService();
    python.setActiveProject('/a');

    MockStreamHandlerEventSink? sink;
    const channel = EventChannel('com.pyrunner.app/python_output');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
      channel,
      MockStreamHandler.inline(
        onListen: (args, events) {
          sink = events;
        },
      ),
    );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance
          .defaultBinaryMessenger
          .setMockStreamHandler(channel, null),
    );

    python.init();
    await tester.pump();
    expect(sink, isNotNull);

    sink!.success(
      {'type': 'event', 'name': 'run_started', 'text': '/a'},
    );
    await tester.pump();
    expect(python.isRunning, isTrue);

    sink!.success(
      {'type': 'event', 'name': 'run_finished', 'text': '/a|0'},
    );
    await tester.pump();
    expect(python.isRunning, isFalse);
    expect(
      python.lines.map((l) => l.text),
      contains('Process finished (exit code 0).'),
    );

    python.dispose();
  });
}
