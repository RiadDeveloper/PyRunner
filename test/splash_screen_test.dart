// Cute mascot splash screen (v1.0.9): the user's chosen logo,
// option 4 — a cute orange fox running with a laptop — bouncing
// in and bobbing, tiny floating code symbols around it (only the
// pretty coding symbols: '</>', '{ }', '[]' — NO arrows, NO
// triangles, NO '>>>'), "Riad developer" at the very bottom of
// the screen, "PyRunner" + tagline in the rounded Nunito font,
// then navigates to the home screen within ~2.0 s — without
// waiting for Python. NO snakes, NO typing at all, NO sound, no
// rings, no drifting glows, flat #0E1013 theme background.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pyrunner/main.dart';
import 'package:pyrunner/services/python_service.dart';
import 'package:pyrunner/services/settings_service.dart';

void main() {
  testWidgets('splash shows the cute mascot and developer, then goes home',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService();
    await settings.init();
    final python = PythonService();
    // Do not call python.init() here: there is no platform channel in tests.
    tester.view.physicalSize = const Size(800, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      PyRunnerApp(settings: settings, python: python),
    );
    await tester.pump();

    // Splash is up: mascot + app name + developer are all in the
    // tree from the start (they fade in — nothing types in), home
    // not shown.
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('PyRunner'), findsOneWidget);
    expect(find.text('Riad developer'), findsOneWidget);
    expect(find.text('Your projects'), findsNothing);

    // The mascot is NOT in a circle anymore: no solid circle-shaped
    // container anywhere on the splash (v1.0.7's round logo is gone).
    // The very subtle glow behind the fox IS a radial-gradient
    // circle — that is allowed; it is a soft light, not a visible
    // ring, box or border.
    final anySolidCircle = find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).shape == BoxShape.circle &&
          ((w.decoration as BoxDecoration).color != null ||
              (w.decoration as BoxDecoration).border != null),
    );
    expect(anySolidCircle, findsNothing);

    // Tiny floating code symbols around the mascot — only the
    // pretty coding symbols the user likes. No arrows, no
    // triangles, no '>>>' anywhere on the splash.
    expect(find.text('</>'), findsOneWidget);
    expect(find.text('{ }'), findsOneWidget);
    expect(find.text('[]'), findsOneWidget);
    expect(find.text('▶'), findsNothing);

    // "Riad developer" sits at the very bottom of the screen,
    // slightly above the edge (Positioned, 32 px from the bottom).
    final devPositioned = find.ancestor(
      of: find.text('Riad developer'),
      matching: find.byType(Positioned),
    );
    expect(devPositioned, findsOneWidget);
    expect(tester.widget<Positioned>(devPositioned).bottom, 32);

    // Rounded Nunito typography on the app name and developer.
    final nameText = tester.widget<Text>(find.text('PyRunner'));
    expect(nameText.style?.fontFamily, 'Nunito');
    expect(nameText.style?.fontWeight, FontWeight.w800);
    final devText = tester.widget<Text>(find.text('Riad developer'));
    expect(devText.style?.fontFamily, 'Nunito');
    expect(devText.style?.fontWeight, FontWeight.w700);

    // Splash background is the theme scaffold color, exactly.
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(scaffold.backgroundColor, const Color(0xFF0E1013));

    // Entrance completes at ~1.0 s; still on the splash, no home yet.
    await tester.pump(const Duration(milliseconds: 1000));
    expect(find.text('Your projects'), findsNothing);

    // After the splash duration (2.0 s) the home screen fades in.
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Your projects'), findsOneWidget);
    expect(find.text('Open folder (in place)'), findsOneWidget);
    // Let the staggered entrance animations fire before teardown.
    await tester.pump(const Duration(milliseconds: 600));
  });
}
