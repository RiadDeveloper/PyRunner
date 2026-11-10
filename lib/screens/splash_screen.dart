import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_info.dart';
import '../services/python_service.dart';
import '../services/settings_service.dart';
import 'home_screen.dart';

/// Splash screen (v1.0.9) — the user's chosen logo, option 4: a cute
/// orange fox running with a laptop. No snakes at all.
///
/// The fox bounces in and keeps bobbing gently (running in place),
/// with tiny floating code symbols around it — only the pretty
/// coding symbols the user likes ('</>', '{ }', '[]'): no arrows,
/// no triangles, no '>>>' anywhere on the splash. "Riad developer"
/// sits at the very bottom of the screen, slightly above the edge.
/// Theme-exact colors, taken from [AppTheme.dark] in lib/main.dart:
/// background #0E1013 (scaffoldBackgroundColor), accent #00A884
/// (theme seed, "terminal green"), tagline #9AA3B2. The background
/// is flat — no gradient blobs, no drifting glows, no rings, no
/// circle box; just a very subtle glow pulse behind the fox.
///
/// Typography: the rounded friendly Nunito font (bundled in
/// assets/fonts/, family "Nunito") for the app name, tagline and
/// "Riad developer" — the old default-font writing style was
/// replaced. No typing, no cursor, no per-letter effect, no sound.
///
/// The mascot bounces in with a cute easeOutBack pop, then keeps
/// bobbing gently (running in place) while the symbols drift slowly.
/// Fast on purpose: at most ~2.0 s, tap anywhere to skip, and it
/// never waits for Python — the home screen warms the runtime up in
/// the background. The native launch screen stays a plain dark
/// #0E1013 background (no icon), so the app opens straight into
/// this animation.
class SplashScreen extends StatefulWidget {
  final SettingsService settings;
  final PythonService python;

  const SplashScreen({
    super.key,
    required this.settings,
    required this.python,
  });

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  Timer? _timer;
  bool _gone = false;

  /// How long the splash stays up before moving on (max).
  static const splashDuration = Duration(milliseconds: 2000);

  /// Theme-exact colors (AppTheme.dark, lib/main.dart).
  static const _background = Color(0xFF0E1013);
  static const _accent = Color(0xFF00A884);
  static const _tagline = Color(0xFF9AA3B2);

  /// Rounded friendly font, bundled in assets/fonts/.
  static const _fontFamily = 'Nunito';

  /// One cute entrance controller (~1.0 s): mascot pops in, then
  /// name, tagline and developer fade/slide in on staggered
  /// intervals of this one timeline.
  late final AnimationController _enterController;

  /// Gentle continuous bob (running in place): repeats for the
  /// whole splash, drives the mascot's up/down bounce, slight tilt,
  /// and the slow drift of the floating code symbols.
  late final AnimationController _bobController;

  @override
  void initState() {
    super.initState();
    _enterController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..forward();
    _bobController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();

    _timer = Timer(splashDuration, _goHome);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _enterController.dispose();
    _bobController.dispose();
    super.dispose();
  }

  void _goHome() {
    if (_gone || !mounted) return;
    _gone = true;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, _, _) => HomeScreen(
          settings: widget.settings,
          python: widget.python,
        ),
        transitionDuration: const Duration(milliseconds: 300),
        transitionsBuilder: (_, animation, _, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          );
          return FadeTransition(opacity: curved, child: child);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _background,
      body: GestureDetector(
        // A tap skips the wait — the splash never holds the user up.
        onTap: _goHome,
        behavior: HitTestBehavior.opaque,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Tiny floating code symbols drifting slowly around the
            // mascot, low opacity, for playfulness.
            _buildFloatingSymbols(),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildMascot(),
                  const SizedBox(height: 36),
                  _buildNameAndTagline(),
                ],
              ),
            ),
            // "Riad developer" sits at the very bottom of the
            // screen, slightly above the edge, fading in last.
            Positioned(
              left: 0,
              right: 0,
              bottom: 32,
              child: _buildDeveloper(),
            ),
          ],
        ),
      ),
    );
  }

  /// The cute fox: pops in with a bouncy easeOutBack scale +
  /// slide, then bobs gently up and down with a slight tilt, like
  /// running in place, over a very subtle glow pulse that breathes
  /// with the bob. Minimal size (~150 px wide), floating directly
  /// on the flat background — no box, no circle, no ring.
  Widget _buildMascot() {
    return AnimatedBuilder(
      animation: Listenable.merge([_enterController, _bobController]),
      builder: (context, _) {
        final enter = const Interval(
          0.0,
          0.5,
          curve: Curves.easeOutBack,
        ).transform(_enterController.value);
        final bob = math.sin(_bobController.value * 2 * math.pi);
        final tilt = bob * 0.02;
        // Very subtle glow pulse behind the fox, breathing with
        // the running bob — accent color at 0.05–0.09 opacity only.
        final glow = 0.07 + 0.02 * bob;
        return Opacity(
          opacity: _enterController.value.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, 24 * (1 - enter) + bob * 4),
            child: Transform.rotate(
              angle: tilt,
              child: Transform.scale(
                scale: 0.6 + 0.4 * enter,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: 260,
                      height: 260,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            _accent.withValues(alpha: glow),
                            _accent.withValues(alpha: 0.0),
                          ],
                        ),
                      ),
                    ),
                    Image.asset(
                      AppInfo.logoAsset,
                      width: 150,
                      fit: BoxFit.contain,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Three tiny code symbols drifting gracefully around the
  /// mascot at low opacity — only the pretty coding symbols the
  /// user likes ('</>', '{ }', '[]'). No arrows, no triangles,
  /// no '>>>' anywhere on the splash.
  Widget _buildFloatingSymbols() {
    return AnimatedBuilder(
      animation: Listenable.merge([_enterController, _bobController]),
      builder: (context, _) {
        final v = _bobController.value;
        return Stack(
          fit: StackFit.expand,
          children: [
            _floatingSymbol(
              text: '</>',
              left: 64,
              top: 240,
              phase: 0.0,
              value: v,
            ),
            _floatingSymbol(
              text: '{ }',
              right: 64,
              top: 280,
              phase: 0.33,
              value: v,
            ),
            _floatingSymbol(
              text: '[]',
              left: 84,
              bottom: 260,
              phase: 0.66,
              value: v,
            ),
          ],
        );
      },
    );
  }

  Widget _floatingSymbol({
    required String text,
    double? left,
    double? right,
    double? top,
    double? bottom,
    required double phase,
    required double value,
  }) {
    final drift = math.sin((value + phase) * 2 * math.pi) * 6;
    final driftX = math.cos((value + phase) * 2 * math.pi) * 4;
    // Symbols fade in gently with the entrance, then drift in a
    // slow lazy loop — vertical and horizontal.
    final fade = const Interval(
      0.2,
      0.5,
      curve: Curves.easeOutCubic,
    ).transform(_enterController.value);
    return Positioned(
      left: left != null ? left + driftX : null,
      right: right != null ? right - driftX : null,
      top: top != null ? top + drift : null,
      bottom: bottom,
      child: Opacity(
        opacity: 0.28 * fade,
        child: Text(
          text,
          style: const TextStyle(
            fontFamily: _fontFamily,
            color: _accent,
            fontSize: 20,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }

  /// "PyRunner" + tagline in the rounded Nunito font, fading in
  /// with a gentle rise, staggered after the mascot.
  Widget _buildNameAndTagline() {
    return AnimatedBuilder(
      animation: _enterController,
      builder: (context, _) {
        final enter = _enterController.value;
        final nameT = const Interval(
          0.30,
          0.60,
          curve: Curves.easeOutCubic,
        ).transform(enter);
        final tagT = const Interval(
          0.45,
          0.75,
          curve: Curves.easeOutCubic,
        ).transform(enter);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Opacity(
              opacity: nameT,
              child: Transform.translate(
                offset: Offset(0, 8 * (1 - nameT)),
                child: const Text(
                  AppInfo.name,
                  style: TextStyle(
                    fontFamily: _fontFamily,
                    color: Colors.white,
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Opacity(
              opacity: tagT,
              child: Transform.translate(
                offset: Offset(0, 8 * (1 - tagT)),
                child: const Text(
                  'Python, in your pocket',
                  style: TextStyle(
                    fontFamily: _fontFamily,
                    color: _tagline,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// "Riad developer" — static text in the rounded font, gentle
  /// fade-in with a small rise, at the very bottom of the screen.
  /// No typing, no cursor, no per-letter effect.
  Widget _buildDeveloper() {
    return AnimatedBuilder(
      animation: _enterController,
      builder: (context, _) {
        final t = const Interval(
          0.70,
          1.0,
          curve: Curves.easeOutCubic,
        ).transform(_enterController.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, 8 * (1 - t)),
            child: const Text(
              AppInfo.developer,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: _fontFamily,
                color: _accent,
                fontSize: 16,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
          ),
        );
      },
    );
  }
}
