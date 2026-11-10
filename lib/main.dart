import 'package:flutter/material.dart';

import 'screens/splash_screen.dart';
import 'services/python_service.dart';
import 'services/settings_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = SettingsService();
  await settings.init();
  final python = PythonService();
  python.init();
  runApp(PyRunnerApp(settings: settings, python: python));
}

class PyRunnerApp extends StatelessWidget {
  final SettingsService settings;
  final PythonService python;

  const PyRunnerApp({super.key, required this.settings, required this.python});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        return MaterialApp(
          title: 'PyRunner',
          debugShowCheckedModeBanner: false,
          themeMode: switch (settings.theme) {
            'light' => ThemeMode.light,
            'system' => ThemeMode.system,
            _ => ThemeMode.dark,
          },
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          // Smooth animated transition when the theme is toggled.
          themeAnimationDuration: const Duration(milliseconds: 350),
          themeAnimationCurve: Curves.easeInOut,
          // v1.0.7: clean splash first (max ~1.9s, never waits on
          // Python), then the home screen.
          home: SplashScreen(settings: settings, python: python),
        );
      },
    );
  }
}

class AppTheme {
  static const _seed = Color(0xFF00A884); // terminal green

  static final light = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: Brightness.light,
    ),
    appBarTheme: const AppBarTheme(centerTitle: false),
    cardTheme: CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.black.withValues(alpha: 0.08)),
      ),
    ),
  );

  static final dark = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: Brightness.dark,
    ).copyWith(
      surface: const Color(0xFF12141A),
      surfaceContainerHighest: const Color(0xFF1B1E27),
    ),
    scaffoldBackgroundColor: const Color(0xFF0E1013),
    appBarTheme: const AppBarTheme(centerTitle: false),
    cardTheme: CardThemeData(
      elevation: 0,
      color: const Color(0xFF1B1E27),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
      ),
    ),
  );
}
