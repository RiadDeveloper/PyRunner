// Per-project console log isolation (v1.0.3).
//
// PythonService is a single shared instance, but its lines, run state
// and input-wait state live in a ConsoleLogStore keyed by project path,
// so opening project B never shows project A's log and a run in A never
// leaks output into B's console.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyrunner/models.dart';
import 'package:pyrunner/services/console_log_store.dart';

void main() {
  test('lines are isolated per project', () {
    final store = ConsoleLogStore();
    store.add('/a', ConsoleKind.output, 'hello A');
    store.add('/b', ConsoleKind.output, 'hello B');
    store.add('/a', ConsoleKind.error, 'boom A');

    expect(
      store.linesFor('/a').map((l) => l.text),
      ['hello A', 'boom A'],
    );
    expect(store.linesFor('/b').map((l) => l.text), ['hello B']);
    expect(store.linesFor('/c'), isEmpty);
  });

  test('clear only clears one project', () {
    final store = ConsoleLogStore();
    store.add('/a', ConsoleKind.output, 'hello A');
    store.add('/b', ConsoleKind.output, 'hello B');

    store.clear('/a');

    expect(store.linesFor('/a'), isEmpty);
    expect(store.linesFor('/b').length, 1);
    expect(store.linesFor('/b').first.text, 'hello B');
  });

  test('running / waiting-for-input flags are independent per project',
      () {
    final store = ConsoleLogStore();
    store.setRunning('/a', true);
    store.setWaitingForInput('/a', true);

    expect(store.isRunning('/a'), isTrue);
    expect(store.isRunning('/b'), isFalse);
    expect(store.isWaitingForInput('/a'), isTrue);
    expect(store.isWaitingForInput('/b'), isFalse);

    store.setRunning('/a', false);
    store.setWaitingForInput('/a', false);
    expect(store.isRunning('/a'), isFalse);
    expect(store.isWaitingForInput('/a'), isFalse);
  });

  // Partial lines (v1.0.4): \r progress writes and input() prompts
  // arrive without a trailing newline and must overwrite instead of
  // stacking, like a terminal.

  test('partial lines replace the open line instead of stacking', () {
    final store = ConsoleLogStore();
    store.addPartial('/a', ConsoleKind.output, 'Loading 10%');
    store.addPartial('/a', ConsoleKind.output, 'Loading 50%');
    store.addPartial('/a', ConsoleKind.output, 'Loading 100%');

    expect(store.linesFor('/a').map((l) => l.text), ['Loading 100%']);
    expect(store.hasOpenLine('/a'), isTrue);
  });

  test('a complete line completes (replaces) the open line', () {
    final store = ConsoleLogStore();
    store.addPartial('/a', ConsoleKind.output, 'hi');
    store.add('/a', ConsoleKind.output, 'hi there');

    expect(store.linesFor('/a').map((l) => l.text), ['hi there']);
    expect(store.hasOpenLine('/a'), isFalse);
  });

  test('a partial line after a complete line starts a new line', () {
    final store = ConsoleLogStore();
    store.add('/a', ConsoleKind.output, 'step 1 done');
    store.addPartial('/a', ConsoleKind.output, 'Loading 10%');
    store.addPartial('/a', ConsoleKind.output, 'Loading 20%');

    expect(
      store.linesFor('/a').map((l) => l.text),
      ['step 1 done', 'Loading 20%'],
    );
  });

  test('input and system lines never overwrite the open line', () {
    final store = ConsoleLogStore();
    store.addPartial('/a', ConsoleKind.output, 'Enter choice: ');
    store.add('/a', ConsoleKind.input, '4');
    store.add('/a', ConsoleKind.output, 'You chose 4');

    expect(
      store.linesFor('/a').map((l) => l.text),
      ['Enter choice: ', '4', 'You chose 4'],
    );
    expect(store.hasOpenLine('/a'), isFalse);
  });

  test('clearAll erases every project log', () {
    final store = ConsoleLogStore();
    store.add('/a', ConsoleKind.output, 'hello A');
    store.add('/b', ConsoleKind.output, 'hello B');
    store.addPartial('/b', ConsoleKind.output, 'partial B');

    store.clearAll();

    expect(store.linesFor('/a'), isEmpty);
    expect(store.linesFor('/b'), isEmpty);
    expect(store.hasOpenLine('/b'), isFalse);
  });
}
