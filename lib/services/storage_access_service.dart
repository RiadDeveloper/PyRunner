import 'package:flutter/services.dart';

/// All-files access (MANAGE_EXTERNAL_STORAGE) for in-place projects
/// (v1.0.4). Android 11+ only lets an app read arbitrary folders on
/// shared storage with this permission; without it, projects must be
/// copied into the app's private workspace instead.
///
/// The native side lives in MainActivity (channel
/// `com.pyrunner.app/storage`). Calls are safe to make in tests: a
/// missing channel reports "not granted" instead of throwing.
class StorageAccessService {
  static const _channel = MethodChannel('com.pyrunner.app/storage');

  /// True when the app may read any folder (or on Android < 11, where
  /// the permission does not exist).
  Future<bool> hasAllFilesAccess() async {
    try {
      return await _channel.invokeMethod<bool>('hasAllFilesAccess') ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Open the Android Settings page where the user grants all-files
  /// access for this app. Returns immediately; the caller re-checks
  /// when the app comes back to the foreground.
  Future<void> openAllFilesAccessSettings() async {
    try {
      await _channel.invokeMethod<void>('openAllFilesAccessSettings');
    } on PlatformException {
      // Nothing to do: the settings page could not be opened.
    } on MissingPluginException {
      // Nothing to do (tests / unsupported platform).
    }
  }
}
