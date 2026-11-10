/// App identity shown in the splash screen and the Settings About
/// section. Keep [version] in step with pubspec.yaml — there is no
/// package_info_plus dependency, so this is the single source the UI
/// reads from. Bump it with every release.
class AppInfo {
  static const String name = 'PyRunner';
  static const String version = '1.0.9';
  static const String developer = 'Riad developer';
  static const String logoAsset = 'assets/logo/pyrunner_logo.webp';
}
