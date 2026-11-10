// File-tree refresh throttling (v1.0.4, B): refresh immediately when
// a run finishes, at most once per second while one runs.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyrunner/services/tree_refresh.dart';

void main() {
  test('no refresh when idle', () {
    final t = TreeRefreshThrottler();
    expect(t.shouldRefresh(running: false), isFalse);
    expect(t.shouldRefresh(running: false), isFalse);
  });

  test('run finishing refreshes immediately', () {
    final t = TreeRefreshThrottler();
    final start = DateTime(2026, 11, 10, 13, 0, 0);
    // A run starts: first refresh is allowed (nothing refreshed yet).
    expect(
      t.shouldRefresh(running: true, now: start),
      isTrue,
    );
    // Still running 200ms later: throttled.
    expect(
      t.shouldRefresh(running: true, now: start.add(
        const Duration(milliseconds: 200),
      )),
      isFalse,
    );
    // Still running 1.5s later: allowed again.
    expect(
      t.shouldRefresh(running: true, now: start.add(
        const Duration(milliseconds: 1500),
      )),
      isTrue,
    );
    // The run finishes 100ms after that refresh: immediate refresh.
    expect(
      t.shouldRefresh(running: false, now: start.add(
        const Duration(milliseconds: 1600),
      )),
      isTrue,
    );
    // Idle afterwards: no more refreshes.
    expect(
      t.shouldRefresh(running: false, now: start.add(
        const Duration(milliseconds: 1700),
      )),
      isFalse,
    );
  });

  test('a run that finishes without ever starting refreshes once', () {
    final t = TreeRefreshThrottler();
    final at = DateTime(2026, 11, 10, 13, 0, 0);
    expect(t.shouldRefresh(running: true, now: at), isTrue);
    expect(t.shouldRefresh(running: false, now: at), isTrue);
    expect(t.shouldRefresh(running: false, now: at), isFalse);
  });
}
