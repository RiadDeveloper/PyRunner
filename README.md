# PyRunner

**Run and edit Python projects on your Android phone.**

PyRunner is an Android app that lets you open any Python project, edit its files, and run it — right on your phone. It embeds a real Python 3.13 interpreter, so your code actually executes on-device. No server, no cloud, no root, no account needed.

## Features

### Projects
- Open a project folder **in place** (your files stay where they are) or import a folder / `.zip` as a copy
- File tree with create, rename, delete, duplicate — works with any file type
- Recent projects list for quick re-opening
- Share / export a whole project as a `.zip`
- Project templates: Hello World, CLI tool, Data script

### Editor
- Tabbed code editor with Python syntax highlighting and line numbers
- Autosave (1.2 s after you stop typing), with an on/off toggle
- Auto-indent, auto-close brackets/quotes, Tab = 4 spaces, find & replace, undo/redo
- Font size, word wrap, indent size — all adjustable

### Console (built-in terminal)
- Type commands directly — output streams live, with ANSI colors (so `colorama` output looks right)
- `input()` works: type your answer in the console and it goes straight to the script
- Commands: `help`, `ls`, `cd`, `pwd`, `cat`, `python <file> [args]`, `python -m <module>`, `python` (interactive REPL), `pip install`, `pip install -r requirements.txt`, `pip list`, `run`, `stop`, `doctor`, `open <file>`
- Stop button / `stop` / Ctrl+C interrupts a running script; Ctrl+D sends EOF

### Running Python
- One-tap Run (▶) — runs the current file, or the project's entry file (`main.py`, `__main__.py`, `app.py`, or the project's only `.py` file)
- Run with arguments (saved per project)
- Per-file "Run in terminal" — runs a file from its own folder
- Runs from the project directory, so relative paths, `__file__`, and absolute paths all work

### Packages
- `pip` is built into the app — `pip install` and `pip install -r requirements.txt` work out of the box
- `pycryptodome` 3.21.0 is bundled, so `from Crypto.Cipher import AES` works with no install
- Shared package store: install once, use in every project
- Packages screen shows installed packages and each project's requirements status

### Design
- Dark and light themes (Material 3)
- Animated splash with the PyRunner fox mascot
- Smooth animations: the Run button morphs into Stop while a script runs, running pulse, smooth tabs and file tree

## How it works

- **Flutter** builds the UI (editor, file tree, console).
- **Chaquopy** embeds a real CPython 3.13 interpreter inside the Android app.
- A small Python bridge (`pyrunner_bridge.py`) runs your scripts, streams output back to the console, and feeds console input to `input()`.
- Kotlin (`MainActivity`) connects the Flutter UI to the Python runtime through method/event channels.

## Tech stack

| Component | Version |
|---|---|
| Flutter | 3.47.9 |
| Dart | 3.13.7 |
| Chaquopy | 17.2.0 |
| Python (embedded) | 3.13.16 |
| pip (vendored) | 26.3 |
| pycryptodome (bundled) | 3.21.0 |
| Kotlin | 2.4.0 |
| Android Gradle Plugin | 9.1.0 |
| compileSdk / targetSdk | 36 |
| minSdk | 24 (Android 7.0) |
| ABIs | arm64-v8a, x86_64 |

## Get the app

Download the latest APK from the [Releases](https://github.com/RiadDeveloper/PyRunner/releases) page and tap it to install. Allow "Install unknown apps" for the app you open the file with, if Android asks.

**Requirements:** Android 7.0 or newer, 64-bit device (arm64 or x86_64). 32-bit-only phones are not supported — Python 3.13 is 64-bit only.

## How to use

1. Open PyRunner and tap **Open project folder** (or **Import .zip**, or **Create sample project** to try the demo).
2. Tap a `.py` file to edit it. Save, or leave Autosave on.
3. Tap **▶ Run** (or type `python main.py` in the console).
4. If the script asks for input, type it in the console and press Enter.
5. Need a package? `pip install -r requirements.txt` — or tap **Install requirements**.

## Project structure

```
lib/                 # Flutter UI
  main.dart          # app entry, theme
  services/          # settings, python bridge client, projects, console
  screens/           # home, project (IDE), settings, splash
  widgets/           # file tree, console panel, editor
android/app/src/main/
  python/            # pyrunner_bridge.py + vendored pip
  kotlin/.../MainActivity.kt   # Flutter <-> Python bridge
assets/
  logo/              # fox mascot logo + splash art
  fonts/             # Nunito
test/                # Flutter tests + CPython bridge harness
```

## Build from source

Prerequisites: Flutter SDK, Android SDK (API 36), JDK 17.

```sh
flutter pub get
flutter test            # run the test suite
flutter build apk --release
```

The APK is produced at `build/app/outputs/flutter-apk/app-release.apk`.

For a signed release build, configure a release keystore (`android/app/keystore.jks` + `android/key.properties`). **Keep the keystore and its passwords backed up somewhere safe** — without them, you cannot publish an update to the same app (Android will reject it as a different signer).

## Version history

- **v1.0.10** — Fixed the run-stops-by-itself bug. Robustness for any project, file and path. New: share as ZIP, run with arguments, `doctor` diagnostics, `open` command, project templates. Animated Run button.
- **v1.0.9** — The fox logo (chosen by the user) and splash fixes.
- **v1.0.8** — Cute robot mascot, no snakes; better typography (Nunito).
- **v1.0.7** — Python blue + yellow snake logo; clean round splash; typing removed.
- **v1.0.6** — Emerald + cyan snake logo; sound removed; smoother animations.
- **v1.0.5** — Splash rework: no icon flash, video-like animation, typewriter + sound.
- **v1.0.4** — In-place projects, real terminal, Settings, logo + splash.
- **v1.0.3** — Real pycryptodome wheel, folder import fix, per-project logs.
- **v1.0.2** — pip bundled in the app.
- **v1.0.1** — Fixed the run crash; Packages screen; editor and terminal upgrades.
- **v1.0.0** — First release.

See the [Releases](https://github.com/RiadDeveloper/PyRunner/releases) page for the APK of each version.

## Limitations

- **No real POSIX shell.** The console is a built-in command interpreter, not `bash`. There is no `apt`, `gcc`, or `git` on the phone.
- **pip is limited.** Only pure-Python wheels and Chaquopy Android wheels install. Packages with C extensions (like `numpy` or `pandas`) cannot be compiled on the phone.
- **64-bit only.** The APK contains arm64-v8a and x86_64 code only.
- **Stop is best-effort.** It raises `KeyboardInterrupt` in the script; a script stuck in a native call may not stop immediately.

## Roadmap — what could come next

- A visual debugger (breakpoints, step through code, inspect variables)
- Code completion and smarter error hints in the editor
- Git integration (clone, commit, push from inside the app)
- More project templates (Flask, Telegram bot, automation scripts)
- Package browser: search and install packages from inside the app
- Cloud backup / sync of projects
- Tablet-optimized layout and split-screen editing

## Credits

Developed by **Riad Developer**.

Built with [Flutter](https://flutter.dev) and [Chaquopy](https://chaquo.com/chaquopy/) (MIT-licensed since v12).

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.
