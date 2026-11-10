/// When to re-list the file tree while a script runs (v1.0.4, bug fix
/// for the 13:24 report: a file a script creates did not appear in the
/// tree until the project was reopened).
///
/// Rule: refresh immediately when a run finishes, and at most once per
/// second while a run is in progress (a run can print hundreds of
/// lines; re-listing the directory on every one would stutter). The
/// IDE also has a manual refresh button in the file panel header.
///
/// Pure Dart — fully unit tested.
class TreeRefreshThrottler {
  /// Minimum gap between refreshes while a run is in progress.
  final Duration interval;

  DateTime _lastRefresh = DateTime.fromMillisecondsSinceEpoch(0);
  bool _wasRunning = false;

  TreeRefreshThrottler({this.interval = const Duration(seconds: 1)});

  /// Call whenever the console/run state may have changed. Returns
  /// true when the tree should be re-listed now.
  bool shouldRefresh({required bool running, DateTime? now}) {
    final at = now ?? DateTime.now();
    // A run just finished: refresh right away so files the script
    // created (e.g. active_and_generated_accounts.json) appear.
    if (_wasRunning && !running) {
      _wasRunning = false;
      _lastRefresh = at;
      return true;
    }
    _wasRunning = running;
    if (running && at.difference(_lastRefresh) >= interval) {
      _lastRefresh = at;
      return true;
    }
    return false;
  }
}
