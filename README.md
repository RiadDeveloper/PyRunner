# PyRunner — Run & edit Python projects on your Android phone

PyRunner is a Flutter Android app that lets you **run and edit Python projects
directly on your phone**. It embeds a real CPython interpreter (via
[Chaquopy](https://chaquo.com/chaquopy/)) so your `.py` files actually execute
on-device — no server, no cloud, no root needed.

## What it does

- **Open a project folder** (or a `.zip`) and browse it as an expandable file
  tree — create, rename and delete files and folders.
- **Tabbed code editor** with Python syntax highlighting, line numbers, Save
  button, and an autosave toggle (persisted).
- **Built-in console** (scrollable output + input line at the bottom, command
  history with Up/Down, keyboard input works) with commands:
  `help`, `clear`, `ls`, `cd`, `pwd`, `cat <file>`, `python <file> [args]`,
  `python -m <module>`, `python` (interactive REPL), `pip install <pkg>`,
  `pip install -r requirements.txt`, `pip list`, `run`, `stop`.
  `python` output streams live into the console (stdout normal, stderr red,
  each line timestamped). A **Stop** button interrupts a running script
  (best effort — it raises `KeyboardInterrupt` inside the script).
- **Run button (▶)** in the editor runs the current file (or `main.py` if the
  open file isn't runnable), with a run-status indicator.
- **Create sample project** — a demo project (`main.py` hello world +
  `input()` demo + `requirements.txt` with `requests`) created in the app's
  own storage, so you can test immediately without importing anything.
- **Dark & light themes** (toggle persisted), Material 3 design, animated
  transitions and staggered list entrances.
- **Recent projects** list (persisted) for quick re-opening.

## Install

1. Copy `app-release.apk` to your phone (USB, Drive, Telegram, etc.).
2. On the phone, tap the APK to install. If Android blocks it, allow
   **"Install unknown apps"** for the app you used to open the file
   (Files / Chrome / Telegram).
3. Open **PyRunner**. No account, no sign-in, no internet required to run
   code (internet is only needed for `pip install`).

**APK:** `build/app/outputs/flutter-apk/app-release.apk` — **85.7 MB**
(81.77 MiB), release-signed (APK Signature Scheme v2).  
SHA-256: `572fb32f6c07e1272f51f23547c5adf5bde91a5373f8cb39540855d8dfd87f14`

**Requirements:** Android 7.0 (API 24) or newer, **64-bit device**
(arm64-v8a or x86_64). 32-bit-only ARM phones are not supported, because
Python 3.13 is 64-bit only.

## Changelog

### v1.0.10 (2026-11-10) — fix the run-stop bug + robustness for any project + more functions + prettier animations

The user reported the sample project dying at its first `input()`
with "KeyboardInterrupt: execution stopped by user" although they
never pressed Stop — and asked that such problems never happen
again, that any Python project run beautifully, that any file/path
work, plus more functions and prettier animations.

- **THE BUG — root cause** (`android/app/src/main/python/pyrunner_bridge.py`,
  `_InputStream.readline()` + `request_stop()`): `request_stop()`
  sets `_stop = True` AND offers `STOP_SENTINEL` into the input
  queue even when the script is NOT blocked in `input()`. If the
  script was looping/computing, the trace kills it but the sentinel
  lingers in the queue — and the NEXT run's `input()` consumes the
  stale sentinel and dies with KeyboardInterrupt (exit 130). The
  input queue is global to the app process, so a Stop in any
  project/session poisoned the next run. Reproduced in the harness
  (stop a looping script, then run the sample + feed "Riad" → exit
  130 before the fix). **Fix (bridge only):** `readline()` now
  loops on `take()`: a STOP_SENTINEL is honoured ONLY when `_stop`
  is True for the current run; a stale one is discarded and the
  read keeps waiting for real input. `input_request`/`input_done`
  bracket the whole wait, so Dart's `waitingForInput` stays
  correct. Deliberately NO drain-at-run-start (that would discard
  the pre-loaded input the harness section 1 relies on).
- **Dart-side hardening** (`lib/services/console_service.dart`,
  `lib/services/python_service.dart`, `lib/widgets/console_panel.dart`):
  - Type-ahead: when a script run is in flight and the text is not
    a control command (`stop`/`clear`/`help`), it is fed to the
    script's stdin — never parsed as a command, never a stop. This
    covers the `input_request`-event-drop race (the EventChannel
    can lose the event on re-subscription, leaving
    `waitingForInput` false while the script still waits at
    `input()`). Only script runs accept type-ahead
    (`PythonService.isScriptRunning`, set at the call site and
    corrected by the `run_started` event tag); REPL/pip runs fall
    through to normal handling. The console input line now stays
    enabled while a run is active so type-ahead is possible.
  - A run stops ONLY via the explicit Stop button, the `stop`
    console command, or Ctrl+C. `python <file>` / `run` while a
    run is active is refused with "A script is already running —
    press Stop first." (never queued on the native executor).
    Pressing Play while a run is active is ignored with a SnackBar
    saying why (the button itself morphs into Stop while running).
  - Ctrl+D sends EOF (`PythonService.feedEof()`, sentinel
    `__PYRUNNER_EOF__`, matching the bridge): `input()` raises
    EOFError instead of waiting forever. The bridge already
    handled the sentinel; the Kotlin `feedInput` passes any string
    through, so no native change was needed.
  - Best-effort channel calls (`feedInput`, `stopRun`, `pipList`,
    `installedPackages`, `fetchPythonVersion`, `ensurePython`,
    `pipInstall`, `replEval`, `runScript`, `runModule`) now catch
    `Exception` instead of only `PlatformException`, so a missing
    plugin (tests / an unregistered channel) is swallowed instead
    of crashing the call.
- **Robustness for any project** (harness section 10, live):
  Bengali + spaced file/dir names run and print UTF-8; deep
  nesting + relative / `__file__` / absolute writes work for
  `run_script` AND `run_module` (package `__main__.py`); multiple
  `input()` calls, empty input (`''`), and EOF (clean `EOFError`,
  no crash); 5000-line output completes (the console store already
  caps stored lines at 5000 — now covered by a test); requirements
  pins/ranges/markers: only an UNBOUNDED pycryptodome spec is
  rewritten to `==3.21.0` (pins, upper-bounded ranges and markers
  are left alone). Entry-point detection
  (`ProjectService.resolveEntryFile`, used by Play/`run`): the
  configured entry file, then `main.py`, then `__main__.py`, then
  `app.py`, then the project's only `.py` file.
- **New functions:**
  - Share/export project as ZIP: already existed on the home
    screen; now also in the project screen's ⋮ menu. The zip
    building is split out as `ProjectService.buildExportZip`
    (unit-tested: the .zip holds every project file).
  - Run with arguments: a per-project run-args field
    (`SettingsService.runArgsFor`/`setRunArgs`, JSON map like
    entry files), edited from the ⋮ menu ("Run arguments…").
    Used by the Play button, the `run` command and "Run in
    terminal". The console `python file.py args` command keeps its
    own explicit arguments and never adds these.
  - `doctor` console command (`ConsoleService._doctor`): checks
    Python version, pip availability, pycryptodome presence,
    project-folder readability, all-files access, the current
    project's entry file, and requirements status (missing
    packages named). Also reachable from the ⋮ menu.
  - `open <file>` / `edit <file>` console command: opens the file
    in the editor tab (via `ConsoleService.onOpenFile`, wired by
    the project screen). Path completion now covers `open`/`edit`.
  - New-project templates (`ProjectService.templates`,
    home-screen "From template"): Hello World, CLI tool (argparse
    `--name`/`--count`), Data script (input + writes `output.csv`
    via `__file__`).
- **Animations (tasteful, 200–350 ms, easeOutCubic/easeInOutCubic,
  no sound, no clutter):** the Run button morphs play ▶ → stop ■
  with a scale+fade `AnimatedSwitcher` (250 ms) while a run is
  active; a subtle "Running" pulse on the console header (opacity
  0.55→1.0, 1.2 s); smooth editor tab switching (200 ms
  cross-fade, `AnimatedSwitcher` keyed by tab path); file-tree
  expand/collapse easing (`AnimatedSize` 250 ms + a rotating
  chevron); gentle staggered entrance for the project list
  (fade+slide, 60 ms apart, capped, 250 ms).
- **Tests:** `flutter test` 118/118 (93 existing + 25 new in
  `test/v1010_regression_test.dart`: console input routing incl.
  the dropped-event type-ahead, stop-only paths, second run after
  a stop, `python` while running refused, Ctrl+D EOF, `open`,
  `doctor` incl. missing-requirement flag; entry detection ×8;
  templates ×3; .zip export; run-args splitting; 5000-line cap).
  Bridge harness 49/49 (was 35; +14 in section 10, incl. the
  stale-sentinel regression, live feed, stop-while-waiting,
  multi-input+EOF, Bengali/spaced names, deep nesting, run_module,
  large output, requirements pins/ranges/markers). Two test-infra
  lessons worth keeping: (1) a mock EventChannel stream handler
  registered in `setUp` captures the subscription but its sink's
  events are silently dropped — register mocks in the test body,
  immediately before `python.init()`; (2) real file I/O inside
  `testWidgets` must run in `tester.runAsync`, or the test stalls
  forever. The harness's sample extractor is now anchored to
  `_writeSample` (the unanchored regex matched the new CLI
  template first).
- **Build:** 287.4 s, exit 0, with the documented env
  (GRADLE_OPTS + GRADLE_USER_HOME + JDK_JAVA_OPTIONS). The Hatch
  CA had rotated (new fingerprint 9B:B9:C9:6B:AB:5B:07:19:…,
  re-imported into `~/workspace/tools/hatch-cacerts` before the
  build); the Maven proxy had died and was restarted. Build log:
  `~/workspace/v1010_build.log`. APK verified: 85,880,398 bytes,
  SHA-256 `5e765549b8ccbfb7e5623e7d56251a533ce45f833b8e4327611b101abb9abe6e`,
  versionCode 11 / versionName 1.0.10, `apksigner verify` v2 true,
  same signer (2907e5f1…), libpython3.13.so both ABIs, pycryptodome
  3.21.0 bundled (319 Crypto files in requirements-common.imy),
  pip 589 files in app.imy, fox logo in flutter_assets
  (fox-orange 22,523 px vs robot-emerald 2 px), Nunito 4 TTFs,
  zero .wav / zero audioplayers.

### v1.0.9 (2026-11-10) — the user's chosen logo (option 4: orange fox) + splash fixes

The user picked logo option 4 of 5 from `~/workspace/logo-options/`
(the cute orange fox running with a laptop) and asked for splash
fixes: remove the arrow mark at the bottom, keep only the pretty
coding symbols, put "Riad developer" at the very bottom, and make
the animation prettier.

- **New logo — option 4, the orange fox** (`assets/logo/`): cute
  orange fox running with green motion lines, holding a tiny green
  laptop, big sparkly eyes, fluffy tail. Source:
  `~/workspace/logo-options/option-4.png` (transparent, 1308×972);
  processing script `~/workspace/v109_make_logo.py` (the file was
  already transparent, so it was used as-is). Splash/About asset
  `assets/logo/pyrunner_logo.webp` (1297×962) and launcher icons at
  all 5 densities regenerated from it. Old v1.0.8 robot mascot
  source file deleted. Verified visually composited over #0E1013
  and by pixel check of the logo inside the built APK
  (fox-orange 16,730 px vs robot-emerald 37 px).
- **Splash fixes** (`lib/screens/splash_screen.dart`):
  - The bottom arrow is GONE: the floating '▶' play triangle was
    removed. The only floating symbols are now the pretty coding
    symbols the user likes — '</>', '{ }' and a new '[]' (bottom
    left, where the arrow was). No '>>>' anywhere on the splash
    (the REPL prompt '>>>' in the console is unrelated and
    untouched).
  - "Riad developer" moved to the VERY BOTTOM of the screen
    (Positioned, 32 px above the bottom edge), fading in last with
    a gentle rise. No typing, no cursor.
  - Prettier animation: the fox pops in (easeOutBack) and keeps
    its gentle running bob, now over a very subtle glow pulse
    behind it (accent at 0.05–0.09 opacity, breathing with the
    bob); the floating symbols fade in with the entrance and drift
    in a slow lazy loop (vertical + horizontal); title + tagline
    fade/slide in staggered as before. Still flat #0E1013 theme
    background, no rings, no blobs, no sound, ~2.0 s max, tap to
    skip, native launch stays icon-free.
- Tests: `flutter analyze` clean (fixed two new `withOpacity`
  deprecation infos by switching the glow to `.withValues()`),
  `flutter test` 93/93, bridge harness 35/35. The splash test now
  asserts no '▶' anywhere, the '[]' symbol, and the developer
  Positioned at bottom 32; its circle check now only forbids solid
  circles (the glow's radial-gradient circle is allowed).
- Build: 172.4 s, exit 0, with the documented env
  (GRADLE_OPTS + GRADLE_USER_HOME + JDK_JAVA_OPTIONS). Hatch CA
  had not rotated (still 04:74:91:FF…), Maven proxy already
  running. Build log: `~/workspace/v109_build.log`.

### v1.0.8 (2026-11-10) — cute mascot logo + cute splash, NO snakes at all

User changed direction completely: no more snake logos ("why are you
making snake-like logos?"), they want something different and cute —
a cartoon, doll-type mascot running Python, a cute-cute flash screen,
and better typography. Redone from scratch:

- **New mascot logo — NO snakes** (`assets/logo/`): a cute chibi robot
  doll (round green robot, big sparkly eyes, joyful smile) running
  mid-stride with motion lines, holding a glowing emerald play button,
  with tiny floating code symbols (`</>`, `{ }`, `>>>`) around it.
  Generated with the media image tool, black keyed out to transparency
  with PIL (`~/workspace/v108_make_logo.py`), verified visually
  composited over #0E1013. Launcher icons at all 5 densities
  (mascot on a dark rounded-square gradient). Old blue+yellow snake
  logo files deleted.
- **Splash redesign** (`lib/screens/splash_screen.dart`): the mascot
  is the star — pops in with a cute easeOutBack bounce, then keeps
  bobbing gently (running in place, small up/down + slight tilt) on a
  second repeating controller; three tiny code symbols drift slowly
  around it at low opacity. Flat theme background #0E1013, no rings,
  no blobs, no circle box. Total ~2.0 s max, tap to skip, never waits
  for Python. Native launch stays icon-free plain dark.
- **Typography fixed**: the rounded friendly **Nunito** font is now
  bundled (static 400/600/700/800 instances from the variable font,
  `assets/fonts/`, registered in pubspec.yaml) — "PyRunner" in
  ExtraBold 32, tagline SemiBold 15, "Riad developer" Bold 16, all
  with generous spacing. No typing, no cursor, no sound (unchanged).
- **Build incident (worth knowing for the next build):** the Gradle
  daemon kept failing with "Could not dispatch a message to the
  daemon" (broken pipe) because the client JVM was missing
  `-Djava.net.preferIPv4Stack=true` — this VM's network stack resets
  IPv4-mapped IPv6 connections, and Java defaults to dual-stack
  sockets. The flag is already in `android/gradle.properties`
  (`org.gradle.jvmargs`) for the daemon, but it MUST also be on the
  client: run builds with `GRADLE_OPTS="-Djava.net.preferIPv4Stack=true"`.
  Also: the wrapper tried to re-download the Gradle distribution
  because Java's `user.home` is /root (not $HOME), so its dist cache
  is /root/.gradle — set `GRADLE_USER_HOME=/home/hatch/.gradle`
  (where the complete 9.3.1 dist already lives) for every build.
  Build took 279.7 s after the fix. Log: `~/workspace/v108_build.log`.

### v1.0.7 (2026-11-10) — logo + splash redo, exactly per the user's checklist

User feedback on v1.0.6 (frustrated): the green+cyan logo was the WRONG
colors (they wanted Python's yellow), the splash was cramped/odd, and
they wanted the typing gone. Redone exactly to their 8-point checklist:

- **New logo — Python's OWN colors** (`assets/logo/`): an original
  design in the style of the Python logo — TWO intertwined snakes,
  one Python blue (#3776AB-ish) and one Python yellow (#FFD43B-ish),
  coiled together forming a play-button triangle, glossy flat vector
  style, with two visible snake heads. Generated, then the black was
  keyed out to transparency with PIL (`~/workspace/v107_make_logo.py`),
  verified visually composited over #0E1013 (clean; the raw webp's
  transparent pixels carry magenta/red RGB garbage — invisible when
  composited). The splash / About asset is the transparent symbol
  (`pyrunner_logo.webp`, 1220×1364); launcher icons at all 5 densities
  are the same symbol composited on a dark rounded-square gradient
  background (48/72/96/144/192 px). Old green+cyan v2 logo files deleted.
- **Splash rewritten** (`lib/screens/splash_screen.dart`, pure Flutter
  animation, no video file): theme-EXACT colors from `AppTheme.dark`
  (`lib/main.dart`) — background #0E1013 (scaffoldBackgroundColor),
  circle fill #12141A (surface), accent #00A884 (theme seed),
  tagline #9AA3B2. The logo sits in a ROUND 150 px circle (thin accent
  border) at a minimal ~118 px logo size (not the oversized 200 px of
  v1.0.6). Flat background, no gradient blobs, no drifting glows, no
  rings, no halo fireworks — just one extremely subtle radial accent
  glow (opacity 0.05) behind the circle. Generous spacing (36 px /
  44 px gaps), minimal elements, airy. "Riad developer" is static text
  that fades in gently — the typewriter is GONE completely: no typing,
  no cursor, no per-letter effect. One calm ~1.0 s entrance timeline
  (`easeOutCubic` intervals): circle fades + scales in, name/tagline/
  developer fade in staggered. Total ~1.9 s max, tap to skip, never
  waits for Python. Native launch screen stays icon-free plain dark
  #0E1013 (same color, seamless transition; no `launch_image.png`).
- **Still no sound:** no WAVs, no `audioplayers`, no toggle (verified
  in the built APK). Everything else from v1.0.6 unchanged (in-place
  projects, live tree, terminal, run-in-terminal, settings).

### v1.0.6 (2026-11-10) — new logo, splash redesign, sound removed, smoothness pass

User feedback on v1.0.5 (with a screenshot): the splash looked ugly —
the logo sat inside a big plain black rounded square, the orbit ring
was a broken-looking partial arc, the glow was blotchy, and the
composition was sparse. Redesigned:

- **New logo** (`assets/logo/`): an original design in the style of the
  Python logo — TWO intertwined snakes (emerald green + cyan/teal) coiled
  together forming a play-button triangle, glossy flat vector style, on
  a pure black background (generated, then the black was keyed out to
  transparency with PIL: `~/workspace/v106_make_logo.py`). The splash /
  About asset is the transparent symbol (`pyrunner_logo.webp`, 1224×1194);
  launcher icons at all 5 densities are the same symbol composited on a
  dark rounded-square gradient background (48/72/96/144/192 px).
- **Splash redesigned** (`lib/screens/splash_screen.dart`, pure Flutter
  animation, no video file): the logo floats free — no box, no broken
  arc — with a soft breathing halo and one complete thin ring behind it;
  the background is three large, very soft glows (emerald / teal / blue)
  drifting very slowly at low opacity (no blotchy hotspots); the whole
  entrance is one choreographed timeline (one 1.2 s master controller,
  `easeOutCubic` intervals): logo fades + scales in gently then floats
  slowly, "PyRunner" + tagline slide up, and "Riad developer" still
  types letter by letter (~70 ms per letter, starting at 650 ms, done
  at ~1.63 s) with a blinking cursor and a soft glow on completion.
  Still ~2.2 s max, tap to skip, never waits for Python. Native launch
  screen stays icon-free plain dark (no `launch_image.png`).
- **Sound fully removed:** the `audioplayers` dependency is gone, the
  `assets/sounds/` WAVs are deleted, and the "Splash sound" toggle +
  `SettingsService.splashSound` are removed. The splash is completely
  silent (verified: no `.wav` and no `audioplayers` in the built APK).
- **Smoothness pass:** sidebar collapse/expand and console resize now
  300 ms `easeInOutCubic` (was 250 ms `easeInOut`); console auto-scroll
  200 ms `easeOutCubic`; theme-switch `AnimatedSwitcher` uses
  `easeOutCubic`/`easeInCubic` curves; splash→home fade uses a
  `CurvedAnimation` (`easeOutCubic`).
- Tests: 93 Flutter tests (the 2 sound tests removed; splash tests
  updated to the new composition/timing). Bridge harness still 35/35.
- Build note: the first build failed — the Gradle wrapper download hit
  an SSL error because `JDK_JAVA_OPTIONS` (ALPN agent + truststore) was
  missing AND the Hatch egress CA had rotated again (truststore still
  had `B8:88:02:DA…`, current CA is `04:74:91:FF…`). Re-imported the CA
  and rebuilt with the full documented env; build took 164 s.

### v1.0.5 (2026-11-10) — splash rework: no icon flash, video-like animation, typing + sound

User feedback on v1.0.4: the startup showed the app icon statically first,
then a plain text animation. Reworked from scratch:

- **No icon flash at startup:** the native launch drawables
  (`drawable/launch_background.xml`, `drawable-v21/`) are now a plain
  dark `#0E1013` background with no image, and the Android 12+ system
  splash (`values-v31/styles.xml`) uses a transparent animated icon
  (`drawable/transparent.xml`) with the same dark background. The app
  opens straight into the animated Flutter splash on every Android
  version. The old `drawable/launch_image.png` is deleted.
- **Video-like animated splash** (`lib/screens/splash_screen.dart`, pure
  Flutter animation, no video file): three large soft glows (green / teal
  / blue) drift slowly over the dark base; the logo pops in with an
  elastic scale + fade, a slowly rotating gradient orbit ring, and a
  breathing green glow that keeps pulsing. "PyRunner" and the tagline
  fade/slide in behind it.
- **Typewriter "Riad developer":** the name types letter by letter
  (~75 ms per letter, starting at 350 ms, done at ~1.4 s) with a
  blinking cursor block; once complete it glows softly (pulsing shadow).
- **Sound** (`assets/sounds/`, synthesized with Python's `wave` + `math`,
  no downloads): a soft sine arpeggio chime `splash_chime.wav` (E5–G5–
  B5–E6, 1.5 s, exponential decay) at splash start, and a 40 ms soft
  tick `type_tick.wav` per typed letter. Played with the `audioplayers`
  package (new dependency, `^6.8.1`); every call is wrapped in
  try/catch so a missing audio device can never crash the splash.
  New **"Splash sound"** toggle in Settings (default ON, persisted as
  `splash_sound` in `SettingsService`, included in reset-to-defaults).
- Splash is now **~2.2 s max** (was ~1.2 s), still tap-to-skip and never
  waits for Python.
- Tests: 95 Flutter tests (splash tests updated to the typewriter
  timing, a sound-off splash test, a splash-sound toggle test; the
  settings About test now reads the version from `AppInfo` instead of
  hardcoding it). Bridge harness still 35/35.

### v1.0.4 (2026-11-10) — in-place projects, real terminal, Settings, logo + splash

- **In-place projects (A):** "Open folder" now opens the project **where it
  is** — no copy into the app's storage. Runs, edits, and files a script
  creates (e.g. generated JSON) all happen in the original directory and
  show in the tree. First run asks for All-files access
  (`MANAGE_EXTERNAL_STORAGE`, `StorageAccessService`) with a dialog that
  offers "Open settings" or "Import a copy instead" as fallback; copy-import
  still works as before. In-place projects are never deleted by the app,
  and folders that disappear are pruned from the recent list
  (`ProjectService.openInPlace`, `lib/screens/home_screen.dart`).
- **Live tree refresh (B):** files created by a running script appear in the
  file tree without reopening the project — the tree refreshes immediately
  when a run finishes and at most once per second while one runs
  (`TreeRefreshThrottler` in `lib/screens/project_screen.dart`), plus a
  manual **Refresh** button. Fixes the reported bug where a generated JSON
  file only appeared after closing/reopening the project.
- **Real terminal (C):** type directly in the console — no separate input box
  and no send button; tapping anywhere in the console focuses the keyboard,
  and Enter submits. ANSI colours render as styled spans
  (`lib/services/ansi_parser.dart`, `lib/widgets/console_panel.dart`), so
  colourised output (e.g. `colorama`) looks like VS Code's terminal.
- **Run in terminal (F):** long-press any `.py` file → **Run in terminal**
  runs exactly that file from its own folder (no `cd` needed). Only shown
  for `.py` files.
- **Settings screen (E):** a real Settings screen — theme, editor font size,
  console font size, autosave on/off, sidebar default, word wrap, indent
  size, default entry file, clear logs, reset all settings, About
  (`lib/screens/settings_screen.dart`).
- **Logo + animated splash (G):** new app logo (green Python snake coiled
  into a play button in a dark terminal window,
  `assets/logo/pyrunner_logo.webp`) as the launcher icon at all densities
  (`res/mipmap-*`) and as the native `launch_image`; animated splash
  (~1.2 s, tap to skip) shows the logo, "PyRunner", and developer name
  **"Riad developer"** (`lib/screens/splash_screen.dart`,
  `lib/app_info.dart`). The native launch background is dark too, so there
  is no white flash while the engine starts.
- **Chdir (kept from the audit):** the Python bridge `chdir`s into the
  project directory for runs and restores the previous directory afterwards
  (bridge harness section 9, 35/35 checks).
- **Fixes found while finishing this build:**
  - *Autosave fired ~500 ms late (real product bug):* `CodeController`
    re-notifies listeners when code analysis finishes (~500 ms after an
    edit), and `_onTextChanged` restarted the 1.2 s autosave debounce on
    every notification — so autosave effectively fired at ~1.7 s. It now
    returns early when the text is unchanged, so autosave fires at the
    configured 1.2 s (`lib/screens/project_screen.dart`).
  - *Autosave test (test bug):* `enterText` delivers text via a simulated
    platform message that is only processed on the next pump, so the test
    must pump once to start the debounce and then 1.3 s to fire it.
  - *Build failure (product bug):* the new `launch_background.xml` used a
    raw colour literal (`#0E1013`) in `android:drawable`, which aapt2
    rejects (reference-only attribute). The colour now lives in
    `res/values/colors.xml` as `@color/launch_background` in both
    `drawable/` and `drawable-v21/` launch backgrounds.
  - *Stale failures in the earlier test log:* `python_service_test`,
    `run_in_terminal_test`, and the pruning test did not reproduce — they
    pass consistently in the current code (the old log's line numbers no
    longer match the files, i.e. it predates the final code). Hardened
    anyway: the pruning test's tearDown deletes are now try/catch, and the
    run-in-terminal test lets the bottom-sheet animation settle (500 ms)
    before tapping, so a tap can no longer land on the scrim mid-animation.
  - *Analyze:* removed an unnecessary `dart:ui` import in
    `test/console_panel_test.dart`.
- **Verification:** `flutter test` 93/93 (three consecutive green runs),
  `flutter analyze` clean, bridge harness 35/35. APK verified: 85,164,038
  bytes, SHA-256 `f3577cf0…d65`, versionCode 5 / versionName 1.0.4,
  apksigner v2 true, same signer as v1.0.0–v1.0.3 (`2907e5f1…`),
  `libpython3.13.so` both ABIs, pycryptodome 3.21.0 still bundled (319
  Crypto files in `requirements-common.imy`, `_raw_aes.so` in both ABI
  assets), vendored pip present (629 entries in `app.imy`), launcher icon
  set in the manifest. Build notes: Maven proxy had died (restarted), Hatch
  egress CA had rotated again (re-imported, now `B8:88:02:DA…`).

### v1.0.3 (2026-11-10) — real pycryptodome, flat imports, per-project logs

- **Crypto fixed with the REAL wheel (not a shim):** PyPI 4.x has no
  Android wheel, so `pycryptodome>=3.20.0` resolved to the 4.4.0 sdist
  and failed to build on device. Chaquopy ships
  `pycryptodome-3.21.0` Android wheels (cp313, arm64-v8a + x86_64), so
  the app now **bundles pycryptodome==3.21.0** in the Chaquopy
  build-time `pip {}` block (`android/app/build.gradle.kts`) — `from
  Crypto.Cipher import AES` works with no install at all (verified in
  the APK: 319 `Crypto/` files in `requirements-common.imy`, compiled
  `_raw_aes.so` in both ABI assets). The bridge (`_run_pip`) also
  **rewrites an unbounded pycryptodome requirement** — bare, `>=` or
  `>` with no upper bound — to `==3.21.0` before pip runs, including
  inside `-r requirements.txt` (rewritten via a temp copy; the user's
  file is never modified, and the temp copy is deleted after pip).
  Explicit pins (`==4.4.0`) and upper bounds are left alone (user's
  choice) and the failure message now explains the 3.21.0 pin. A
  pure-Python Crypto shim was built first, then **removed** once the
  real wheel was confirmed — it is not in this build.
- **Folder/zip import flattening:** a GitHub zip's single root folder
  (or a picked folder holding one wrapper folder) used to double the
  path (`projects/Guest_gen-main/Guest_gen-main/main.py`), so `main.py`
  and `requirements.txt` were not at the project root. Both
  `importFolder` and `importZip` now unwrap a single top-level wrapper
  folder (up to 3 levels); the Home screen says so when it happens,
  and the file tree auto-expands the top level after import.
- **Sidebar toggle:** an AppBar button (sidebar icon) collapses /
  expands the file panel on wide screens (>=600dp, animated, persisted
  in settings) and opens / closes the drawer on phones.
- **Autosave surfaced:** autosave itself is unchanged (1.2s debounce,
  Saved/Unsaved label) — it now has a toggle in the editor toolbar
  (save icon, "Autosave: on/off") so it can be found and turned off.
- **Per-project terminal logs:** console lines, run state and
  input-wait state are scoped per project (`ConsoleLogStore`, keyed by
  project path) — opening project B never shows project A's log, Clear
  clears only the current project's log, and a run in A cannot leak
  output into B (the bridge tags `run_started`/`run_finished` events
  with the project dir). Audit fix: nothing called
  `setActiveProject` before, so every project shared one log — the
  project screen's `ConsoleService` now activates its project.
- **New functions:** "Install requirements" one-tap button in the file
  panel (shown when `requirements.txt` exists) and "Open in terminal
  here" in the folder menu (cds the console into that folder).
- **Audit fixes:** installed packages are importable on the FIRST run
  (site-packages was only added to `sys.path` after a pip command);
  the REPL works after a Stop (stale `KeyboardInterrupt` cleared) and
  `exit()` is quiet; the REPL imports from the last run's project dir;
  `python main.py` / `pip install -r requirements.txt` resolve
  relative paths against the project root when the console cwd is a
  subfolder; folder expansion state survives tree refreshes (the
  `ValueKey` that rebuilt the whole tree is gone) and expanded folders
  re-list their children, so new files appear; pip failures explain in
  plain language why a package cannot build on Android (no wheel, no
  C compiler). `--only-binary` was deliberately NOT added globally: a
  pure-Python sdist-only package would then fail too.
- **Verification:** `flutter analyze` clean, `flutter test` 48/48,
  bridge harness 30/30 (incl. the pycryptodome rewrite rules and
  AES-CBC/GCM round-trips against the real pycryptodome). One known
  gap: the "Install requirements" widget test was removed — pumping
  the project screen with a `requirements.txt` present hangs the
  test's fake-async clock (other screen tests pump fine without it);
  the behaviour is covered by the bridge harness instead.

### v1.0.2 (2026-11-10) — pip is now bundled in the app

- **Fixed `pip install -r requirements.txt`:** it failed on the phone with
  "pip is not available inside this Python runtime". Chaquopy's Python
  runtime does not bundle `pip` at all, so the app now ships pip itself:
  the pip 26.3 wheel is vendored into `android/app/src/main/python/pip/`
  next to the bridge, and `import pip` resolves to that copy on device.
- **Fixed a pip 26 trap found while testing the fix:** pip 26's install
  command installs an import blocker that stays active for the life of
  the process when pip runs as a CLI — in this long-lived app that made
  every later `pip` run and even `import six` fail with
  `BlockedImportError`. The bridge now calls pip as a library
  (`pip._internal.cli.main.main`, `cli=False`) and disables the import
  guard for the call, then clears any leftover blocker state — verified
  in the harness: install → `import six` → `pip list` → second install
  all succeed with no warnings leaking into the console.
- **Better pip errors:** if pip ever can't be imported, the console now
  shows the underlying reason, not just "pip is not available".
- **Self-test:** the CPython harness (`test/bridge_harness_test.py`) now
  runs a REAL pip install of `six` into the shared store (from PyPI,
  with a local wheel fallback in `test/fixtures/`) and the exact command
  the user ran, `pip install -r requirements.txt` — 18/18 checks pass.
  Note: sdists (packages without wheels) still cannot install on device
  — there is no compiler on the phone.

### v1.0.1 (2026-11-10) — bug fixes + editor, terminal, and layout upgrades

- **Fixed the crash on Run:** `TypeError: 'ArrayList' object is not
  iterable` (bridge line 156). Kotlin now passes script/module/pip args
  as a typed array, and the Python bridge converts any Java List via
  `size()`/`get(i)` — `run_script`, `run_module`, and `pip_install`
  (so `pip install -r requirements.txt` works again too).
- **Fixed `pip list`:** it silently returned nothing because the bridge
  appended `--target` (an install-only flag) to every pip command.
  Install-only flags are now added for `install` only.
- **Fixed the folder-import bug:** importing a folder could leave an empty
  project with no files (the target dir was created before the source was
  checked, and a single bad file aborted the whole copy silently). Imports
  now preflight the source, show a progress dialog, copy past individual
  failures, report which files failed, and never leave a phantom project.
- **Packages screen (Home → Packages, or the IDE's Packages button):**
  the shared app-level package store is now visible — installed packages
  with versions, per-project `requirements.txt` status (installed ✓ /
  missing / version mismatch), and "Install requirements" / "Install
  missing only" buttons. Installs are idempotent: already-satisfied
  requirements are skipped and reported, never reinstalled.
- **Editor:** auto-indent on Enter, auto-close brackets/quotes (with
  type-over and pair-delete on Backspace), Tab inserts 4 spaces,
  Shift+Tab unindents, find & replace bar, undo/redo, font size +/−,
  word-wrap toggle (both persisted).
- **Terminal:** suggestion chips above the input (built-in commands,
  history, file/folder completion after `python`/`cat`/`cd`/`ls`),
  Tab completes the first suggestion, Ctrl+C stops a running script
  (same as the Stop button), `python` REPL exits cleanly on `exit()`,
  copy/share console log buttons.
- **Dialogs redesigned:** create/rename/delete dialogs are rounded with
  icons and live validation (no empty names, no illegal characters, no
  duplicates).
- **Responsive layouts:** phones (<600dp) keep the drawer file tree;
  tablets (≥600dp) show a persistent side panel, and the console is a
  resizable bottom panel (drag the handle).
- **More functions:** search across project files, per-project entry
  file (Run uses it, default `main.py`), duplicate file, go to line,
  staggered file-tree entrance, animated theme switch.
- **Self-test:** the bridge is now covered by a CPython harness
  (`test/bridge_harness_test.py`) that runs the real bridge file and the
  bundled sample project under system Python — no emulator was available
  here (`/dev/kvm` absent), so on-device testing still needs the phone.

## How to use

### Open a project
- **Home → "Open project folder"**: pick a folder. On Android 11+ the system
  file picker (SAF) is used; the app copies the folder into its own private
  storage so it can read/write it reliably. If the system picker refuses a
  folder, import the project as a **`.zip`** instead (always works), or use
  **"Create sample project"** to try the demo.
- **Home → "Import .zip"**: pick a `.zip` containing a Python project; it is
  extracted into the app's storage.
- Tap a project in **"Your projects"** to re-open it.
- **Export**: from a project, use the share/export action to send the whole
  project as a `.zip` (share sheet / save to Drive / send to yourself).

### Edit & run
- Tap a `.py` file in the tree to open it in a tab. Edit, then **Save**
  (or turn on **Autosave** — saves ~1.2 s after you stop typing).
- Press **▶ Run** (top bar) to run the current file. Output appears in the
  console panel at the bottom; pull the panel up to see more.
- **Stop** (■) interrupts a running script.
- `input()` in a script: when the script waits for input, type in the
  console's input line and press send — the text is fed to the script.

### The console
Type commands and press send (or Enter). Examples:
```
help
ls
python main.py
python main.py hello 42
python -m mymodule
pip install requests
pip install -r requirements.txt
pip list
python            # interactive REPL (type exit() to leave)
```
- `python` / `pip` commands run on a background thread; the UI stays
  responsive and output streams live.
- `pip install` installs into the app's private `site-packages`. It works
  for **pure-Python wheels** and for wheels built for Chaquopy/Android.
  It cannot compile C extensions on the phone (no compiler on device).

## Versions inside this build

| Component | Version |
|---|---|
| Flutter | 3.47.9 (stable) |
| Chaquopy | 17.2.0 |
| Embedded Python | 3.13 (Chaquopy runtime 3.13.16) |
| Vendored pip (in-app) | 26.3 |
| Dart | 3.13.7 |
| Android Gradle Plugin | 9.1.0 |
| Kotlin | 2.4.0 |
| compileSdk / targetSdk | 36 |
| minSdk | 24 (Android 7.0) |
| ABIs in the APK | arm64-v8a, x86_64 |

## Known limitations (please read)

- **No real POSIX shell.** Android apps don't get a Unix shell. The console
  is a built-in command interpreter (see the command list above) — it is not
  `bash`/`sh`, and there is no `apt`, `gcc`, `git`, etc. on the phone.
- **pip is limited.** Only pure-Python wheels and Chaquopy Android wheels
  install. Packages with C extensions (e.g. `numpy`, `pandas`, `cryptography`
  unless a Chaquopy wheel exists) will fail to install. Use
  `pip install` and check the error if a package doesn't install.
- **64-bit only.** The APK contains arm64-v8a and x86_64 native code only
  (Python 3.12+ dropped 32-bit ARM). It will not install on 32-bit-only
  phones.
- **Project folders are copied.** Because Android 11+ restricts direct
  access to arbitrary folders, an opened folder is copied into the app's
  private storage. Edits happen on that copy; use **Export (.zip)** to get
  the edited project back out.
- **`sys.stdin` in scripts** is fed from the console input line (see above);
  there is no real terminal/TTY, so terminal control sequences and
  interactive curses-style programs won't work.
- **Stop is best-effort.** It raises `KeyboardInterrupt` in the running
  script. A script stuck in a native call may not stop immediately.
- **Not tested on a real device.** This APK was built and verified in a Linux
  build environment (no Android device/emulator available here). The build,
  signing, embedded Python 3.13 runtime, and bundled `requests` package were
  verified, but first-run behaviour on a phone (Python startup time, editor,
  console) has not been observed live. If something doesn't start, the most
  likely culprit is storage permission — reinstall and grant the file
  permission when asked.

## Chaquopy license note

Chaquopy has been **MIT-licensed since version 12.0.1**, so it is free to use
in personal and commercial apps alike (the older "free only for open-source"
note in some docs is outdated). No license key or payment is needed for this
app. See https://chaquo.com/chaquopy/doc/current/ for the current terms.

## Release signing

The release APK is signed with a keystore generated for this project at
`android/app/keystore.jks` (alias `pyrunner`). The password is in
`android/key.properties` (not committed anywhere public).
**Back up `keystore.jks` + `key.properties`** — without them you cannot
publish an update to the same app (Android will reject it as a different
signer).

## Rebuilding (for the developer)

The build environment is unusual: the machine sits behind an authenticated
TLS-intercepting egress proxy that breaks Gradle's Java HTTP client
(specific `.module` GETs stall and time out). The working build uses:

- `~/workspace/tools/maven-proxy/proxy.py` — a local caching Maven proxy on
  `http://127.0.0.1:18080`. Gradle talks plain HTTP to it; it downloads the
  real artifacts with `curl` and caches them under
  `~/workspace/maven-cache/`. **Start it before building.**
- `~/.gradle/init.d/maven-proxy.init.gradle.kts` — points Gradle's
  pluginManagement, dependencyResolutionManagement, and all buildscript
  repositories at the local proxy.
- `android/build.gradle.kts` — the root `allprojects.repositories` also
  points at the local proxy (the Flutter template's `google()`/`mavenCentral()`
  bypass the proxy for plugin subprojects, so they are replaced here).
- `android/gradle.properties` — `disable-abi-filtering=true` (lets the
  `arm64-v8a + x86_64` `abiFilters` in `app/build.gradle.kts` survive
  Flutter's plugin, which otherwise forces 32-bit `armeabi-v7a` and Chaquopy
  rejects it), plus 120 s HTTP timeouts.
- `~/workspace/tools/alpn-agent/alpn-agent.jar` — a Java agent that adds an
  ALPN extension to Gradle's HTTPS handshakes (the proxy stalls handshakes
  without ALPN) and forces `Connection: close`. Loaded via `JDK_JAVA_OPTIONS`.
- `~/workspace/tools/hatch-cacerts` — JDK truststore with the current Hatch
  egress CA imported. **The CA rotates on service restarts — re-import it
  before a build** (`keytool -importcert -file
  /run/hatch/egress-tls/hatch-egress-ca.pem ...`).
- Env for every Gradle/Flutter invocation:
  `JAVA_HOME=~/workspace/tools/jdk-17`, `GRADLE_USER_HOME=~/.gradle`,
  `JDK_JAVA_OPTIONS="-Djava.net.preferIPv4Stack=true -javaagent:…/alpn-agent.jar -Djavax.net.ssl.trustStore=…/hatch-cacerts -Djavax.net.ssl.trustStorePassword=changeit"`,
  `GRADLE_OPTS="-Djava.net.preferIPv4Stack=true"`,
  `ANDROID_HOME=~/workspace/tools/android-sdk`.
- Android SDK 36 (platform + build-tools 36.0.0), NDK r28c (28.2.13676358),
  CMake 3.22.1 — all under `~/workspace/tools/android-sdk/` (the NDK was
  re-extracted with symlinks restored; the platform-36 and CMake
  `package.xml` files were written by hand because their zips ship none).

Build command (from `~/workspace/pyrunner`, proxy running, env as above):

```sh
flutter build apk --release --target-platform android-arm64,android-x64
```

Output: `build/app/outputs/flutter-apk/app-release.apk`.
`flutter analyze` is clean ("No issues found!") and all tests pass
(93 Flutter tests + the CPython bridge harness, `test/bridge_harness_test.py`).

## Project layout

- `lib/` — Dart UI: `main.dart`, `models.dart`, `services/` (settings,
  Python bridge client, project files, console), `screens/` (home, IDE),
  `widgets/` (file tree, console panel).
- `android/app/src/main/python/pyrunner_bridge.py` — the Python side: queue
  backed stdout/stderr/stdin, `runpy`-based script/module execution,
  `settrace` stop, REPL eval, and runtime `pip` (via `runpy` on the pip
  module, `--target` the app's site-packages, extra index
  `https://chaquo.com/pypi-13.1`).
- `android/app/src/main/kotlin/com/pyrunner/pyrunner/MainActivity.kt` —
  the MethodChannel/EventChannel bridge to Chaquopy.
- `test/widget_test.dart` — smoke test (home screen renders).
