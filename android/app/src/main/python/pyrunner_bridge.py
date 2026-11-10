"""PyRunner bridge: runs user Python code inside the Chaquopy runtime.

Kotlin (MainActivity) passes two Java LinkedBlockingQueue objects in:
  * input_queue  - lines typed by the user (for input() / REPL)
  * output_queue - tagged strings ("OUT|...", "ERR|...", "EVT|...") that
                   Kotlin drains and forwards to Flutter via an EventChannel.

sys.stdout / sys.stderr / sys.stdin are replaced with console streams so
that print(), tracebacks and input() all flow through the app console.

Stop support: run_script() installs a trace function that raises
KeyboardInterrupt when _stop is set.  A stop while blocked in input() is
handled by feeding the STOP_SENTINEL into the input queue.

pip support: pip_install() runs the pip module with
--target <HOME>/site-packages so packages persist across runs.  Only
pure-Python wheels (and Chaquopy Android wheels from chaquo.com/pypi-13.1)
can install on device - there is no C compiler on Android.  Chaquopy does
not bundle pip (no ensurepip), so the app ships pip itself: the pip wheel
(26.3) is vendored under src/main/python/pip/ next to this bridge, and
`import pip` resolves to that copy on device.

pycryptodome (v1.0.3): PyPI 4.x has no Android wheel, so an unbounded
requirement (`pycryptodome>=3.20.0`) resolves to the 4.x sdist and
fails to build on device. Two fixes: the app bundles pycryptodome
3.21.0 — the newest version with a Chaquopy Android wheel — in the
Chaquopy build-time pip block, so `from Crypto.Cipher import AES`
works with no install at all; and _run_pip rewrites an unbounded
pycryptodome requirement to `pycryptodome==3.21.0` before pip runs
(explicit pins and upper bounds are left alone).
"""

import io
import os
import runpy
import sys
import traceback

_input_queue = None
_output_queue = None
_stop = False

#: Last project directory a script/module ran from; the REPL reuses it
#: so `import helper` works there too (audit fix, v1.0.3).
_last_project_dir = ""

STOP_SENTINEL = "__PYRUNNER_STOP__"
EOF_SENTINEL = "__PYRUNNER_EOF__"

_repl_globals = {}


def _emit(tag, text):
    if _output_queue is not None:
        try:
            _output_queue.put(tag + "|" + text)
        except Exception:
            pass


class _OutputStream(io.TextIOBase):
    """Line-buffered text stream that forwards each line to the UI.

    Terminal line discipline (v1.0.4): a chunk ending in ``\\n`` is a
    complete line (tag OUT/ERR). A chunk flushed without a newline —
    a ``\\r`` progress line, or an input() prompt — is a *partial* line
    (tag OUTR/ERRR): it replaces the console's current partial line
    instead of stacking underneath it, exactly like a terminal. Any
    ``\\r`` inside a chunk keeps only the text after the last ``\\r``,
    because later text overwrites earlier text on the same line.
    """

    def __init__(self, tag):
        super().__init__()
        self._tag = tag
        self._buf = ""

    @staticmethod
    def _clean(chunk):
        """Text after the last carriage return (terminal overwrite)."""
        if "\r" in chunk:
            chunk = chunk.rsplit("\r", 1)[1]
        return chunk

    def write(self, s):
        if not s:
            return 0
        if not isinstance(s, str):
            s = str(s)
        self._buf += s
        while "\n" in self._buf:
            line, self._buf = self._buf.split("\n", 1)
            _emit(self._tag, self._clean(line))
        return len(s)

    def flush(self):
        if self._buf:
            text = self._clean(self._buf)
            self._buf = ""
            if text:
                _emit(self._tag + "R", text)

    def writable(self):
        return True

    def readable(self):
        return False

    def seekable(self):
        return False

    @property
    def encoding(self):
        return "utf-8"

    @property
    def errors(self):
        return "strict"


class _InputStream(io.TextIOBase):
    """Text stream whose readline() blocks on the Kotlin input queue.

    A STOP_SENTINEL is honoured only when a stop was actually
    requested for THIS run (_stop is True). A sentinel left in the
    queue by an earlier run's Stop — request_stop() offers it even
    when the script was NOT blocked in input(), so it lingers — is
    stale and must be discarded, never allowed to kill this run
    (v1.0.10 regression: the sample project died at its first
    input() with KeyboardInterrupt although the user never pressed
    Stop, because a previous stop had left a sentinel behind).
    """

    def readline(self, size=-1):
        _emit("EVT", "input_request|")
        try:
            while True:
                line = _input_queue.take()
                if line == STOP_SENTINEL:
                    if _stop:
                        raise KeyboardInterrupt()
                    # Stale sentinel from a previous run's Stop:
                    # discard it and keep waiting for real input.
                    continue
                if line == EOF_SENTINEL:
                    return ""
                return line if line.endswith("\n") else line + "\n"
        finally:
            _emit("EVT", "input_done|")

    def read(self, size=-1):
        return self.readline(size)

    def readable(self):
        return True

    def writable(self):
        return False

    def seekable(self):
        return False


def _trace(frame, event, arg):
    if _stop:
        raise KeyboardInterrupt()
    return _trace


def init(input_queue, output_queue):
    """Called once from Kotlin after Python.start()."""
    global _input_queue, _output_queue
    _input_queue = input_queue
    _output_queue = output_queue
    sys.stdout = _OutputStream("OUT")
    sys.stderr = _OutputStream("ERR")
    sys.stdin = _InputStream()
    # Installed packages must be importable from the very first run,
    # not only after a pip command has run (audit fix, v1.0.3:
    # _site_packages_dir() used to be called from _run_pip only).
    _site_packages_dir()
    _emit("EVT", "python_ready|" + sys.version.split()[0])


def request_stop():
    """Called from Kotlin when the user taps Stop."""
    global _stop
    _stop = True
    try:
        if _input_queue is not None:
            _input_queue.offer(STOP_SENTINEL)
    except Exception:
        pass


def python_version():
    return sys.version.split()[0]


def _to_py_list(value):
    """Convert whatever Chaquopy hands us into a plain Python list of str.

    Kotlin passes args as a java.util.List (ArrayList) or a Java array.
    Chaquopy Java Lists are NOT iterable from Python, so a plain
    ``[str(a) for a in args]`` raises
    ``TypeError: 'ArrayList' object is not iterable``.  Convert via the
    Java API instead: List -> size()/get(i), array -> len()/indexing.
    """
    if value is None:
        return []
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [str(v) for v in value]
    # Java List (java.util.ArrayList / List): size() + get(i).
    try:
        n = value.size()
        return [str(value.get(i)) for i in range(int(n))]
    except Exception:
        pass
    # Java array (or any sized, indexable sequence): len() + [i].
    try:
        return [str(value[i]) for i in range(len(value))]
    except Exception:
        pass
    # Last resort: toArray() if present, else a single string.
    try:
        arr = value.toArray()
        return [str(v) for v in arr]
    except Exception:
        return [str(value)]


def _chdir_for_run(cwd, project_dir, script_path):
    """chdir to the run's working directory; return the old cwd to
    restore (or None when nothing changed).

    A script's relative file reads/writes land in the run's working
    directory — the console's cwd when Dart passes one, else the
    project dir, else the script's own directory. This is what makes
    in-place projects (v1.0.4) work: files a script creates land in
    the real project folder, not in the app's process directory.
    """
    target = ""
    if cwd and os.path.isdir(cwd):
        target = cwd
    elif project_dir and os.path.isdir(project_dir):
        target = project_dir
    elif script_path:
        d = os.path.dirname(os.path.abspath(script_path))
        if os.path.isdir(d):
            target = d
    if not target:
        return None
    try:
        old = os.getcwd()
        if os.path.normcase(os.path.abspath(old)) == os.path.normcase(
            os.path.abspath(target)
        ):
            return None  # Already there; nothing to restore.
        os.chdir(target)
        return old
    except Exception:
        return None


def _restore_cwd(old_cwd):
    if old_cwd is not None:
        try:
            os.chdir(old_cwd)
        except Exception:
            pass


def _flush_console():
    """Emit any partial last line (e.g. a \\r progress line) before the
    run_finished event, so the console shows the final state."""
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.flush()
        except Exception:
            pass


def run_script(path, args, project_dir, cwd=""):
    """Run a .py file as __main__. Returns an exit code (int)."""
    global _stop, _last_project_dir
    _stop = False
    if project_dir:
        _last_project_dir = project_dir
    # Installed packages must be importable even when no pip command
    # has run yet in this session (audit fix, v1.0.3) — and this must
    # happen BEFORE sys.path is snapshotted below, or the restore at
    # the end would drop the site-packages entry again.
    _site_packages_dir()
    # The run events carry the project dir, so the Dart side can route
    # output / run state to the right project's log even when the user
    # switches projects (or starts a run in another project) mid-run
    # (v1.0.3). An empty project_dir keeps the old bare format.
    if project_dir:
        _emit("EVT", "run_started|" + project_dir)
    else:
        _emit("EVT", "run_started|")
    old_argv = sys.argv
    old_path = list(sys.path)
    old_cwd = _chdir_for_run(cwd, project_dir, path)
    code = 0
    try:
        sys.argv = [path] + _to_py_list(args)
        script_dir = os.path.dirname(os.path.abspath(path))
        if script_dir not in sys.path:
            sys.path.insert(0, script_dir)
        if project_dir and project_dir not in sys.path:
            sys.path.insert(0, project_dir)
        sys.settrace(_trace)
        try:
            runpy.run_path(path, run_name="__main__")
        finally:
            sys.settrace(None)
    except SystemExit as e:
        if isinstance(e.code, int):
            code = e.code
        elif e.code is None:
            code = 0
        else:
            code = 1
    except KeyboardInterrupt:
        _emit("ERR", "KeyboardInterrupt: execution stopped by user")
        code = 130
    except BaseException:
        traceback.print_exc()
        code = 1
    finally:
        sys.argv = old_argv
        sys.path = old_path
        _restore_cwd(old_cwd)
        _flush_console()
    if project_dir:
        _emit("EVT", "run_finished|%s|%d" % (project_dir, code))
    else:
        _emit("EVT", "run_finished|%d" % code)
    return code


def run_module(module, args, project_dir, cwd=""):
    """Run a module with `python -m`. Returns an exit code (int)."""
    global _stop, _last_project_dir
    _stop = False
    if project_dir:
        _last_project_dir = project_dir
    _site_packages_dir()
    # Run events carry the project dir (see run_script).
    if project_dir:
        _emit("EVT", "run_started|" + project_dir)
    else:
        _emit("EVT", "run_started|-m " + module)
    old_argv = sys.argv
    old_path = list(sys.path)
    old_cwd = _chdir_for_run(cwd, project_dir, None)
    code = 0
    try:
        sys.argv = [module] + _to_py_list(args)
        if project_dir and project_dir not in sys.path:
            sys.path.insert(0, project_dir)
        sys.settrace(_trace)
        try:
            runpy.run_module(module, run_name="__main__", alter_sys=True)
        finally:
            sys.settrace(None)
    except SystemExit as e:
        if isinstance(e.code, int):
            code = e.code
        elif e.code is None:
            code = 0
        else:
            code = 1
    except KeyboardInterrupt:
        _emit("ERR", "KeyboardInterrupt: execution stopped by user")
        code = 130
    except BaseException:
        traceback.print_exc()
        code = 1
    finally:
        sys.argv = old_argv
        sys.path = old_path
        _restore_cwd(old_cwd)
        _flush_console()
    if project_dir:
        _emit("EVT", "run_finished|%s|%d" % (project_dir, code))
    else:
        _emit("EVT", "run_finished|%d" % code)
    return code


def repl_eval(code):
    """Evaluate one line in the persistent REPL namespace.

    Tries eval() first (prints repr of the result), then exec().
    Returns "" on success; error text is printed to the console stream.
    """
    global _stop
    # A previous Stop must not poison the REPL: _stop is reset by
    # run_script/run_module, but the REPL is a separate entry point
    # (audit fix, v1.0.3 — stopping a script used to make every later
    # REPL line raise KeyboardInterrupt).
    _stop = False
    _site_packages_dir()
    if _last_project_dir and _last_project_dir not in sys.path:
        sys.path.insert(0, _last_project_dir)
    _emit("EVT", "run_started|repl")
    try:
        sys.settrace(_trace)
        try:
            try:
                result = eval(code, _repl_globals)
                if result is not None:
                    print(repr(result))
            except SyntaxError:
                exec(compile(code, "<console>", "exec"), _repl_globals)
        finally:
            sys.settrace(None)
    except SystemExit:
        # exit() / quit() in the REPL just ends the line, like a real
        # REPL (audit fix, v1.0.3 — it used to print a traceback).
        pass
    except KeyboardInterrupt:
        _emit("ERR", "KeyboardInterrupt")
    except BaseException:
        traceback.print_exc()
    _emit("EVT", "run_finished|0")
    return ""


def _site_packages_dir():
    home = os.environ.get("HOME", "")
    target = os.path.join(home, "site-packages")
    os.makedirs(target, exist_ok=True)
    if target not in sys.path:
        sys.path.insert(0, target)
    return target


class _TeeStream:
    """Wraps a text stream, forwarding writes and recording them.

    Used while pip runs so a failure can be explained afterwards in
    plain language (v1.0.3): pip's own error ("Failed to build ...")
    means nothing to most users on its own.
    """

    def __init__(self, target):
        self._target = target
        self.recorded = []

    def write(self, s):
        if s:
            self.recorded.append(s)
            if len(self.recorded) > 400:
                del self.recorded[:len(self.recorded) - 400]
        return self._target.write(s)

    def flush(self):
        return self._target.flush()

    def __getattr__(self, name):
        return getattr(self._target, name)


def _strip_specifier(token):
    """'pycryptodome>=3.20.0' -> 'pycryptodome'; paths/URLs -> ''."""
    import re
    if "/" in token or "\\" in token or token.endswith(
        (".whl", ".zip", ".tar.gz")
    ):
        return ""
    m = re.match(r"^([A-Za-z0-9_.\-]+)", token)
    return m.group(1) if m else ""


def _requirement_names(path):
    """Package names listed in a requirements.txt file."""
    names = []
    try:
        with open(path, encoding="utf-8", errors="ignore") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith(("#", "-")):
                    continue
                line = line.split(";", 1)[0].strip()
                line = line.split(" #", 1)[0].strip()
                name = _strip_specifier(line)
                if name:
                    names.append(name)
    except Exception:
        pass
    return names


def _pip_target_names(argv):
    """Package names a `pip install ...` argv is trying to install.

    Skips flags (and the values of flags that take one) and reads
    `-r requirements.txt` files so the names inside are reported too.
    """
    names = []
    value_flags = {
        "-r", "--requirement", "-c", "--constraint",
        "--target", "-t", "--extra-index-url",
        "--index-url", "--find-links", "-f",
    }
    i = 0
    # Tolerate a leading subcommand ('install') when called directly.
    if argv and argv[0] in ("install", "download"):
        i = 1
    while i < len(argv):
        tok = argv[i]
        if tok in ("-r", "--requirement") and i + 1 < len(argv):
            names.extend(_requirement_names(argv[i + 1]))
            i += 2
            continue
        if tok in value_flags:
            i += 2
            continue
        if tok.startswith("-"):
            i += 1
            continue
        names.append(_strip_specifier(tok))
        i += 1
    seen = []
    for n in names:
        if n and n not in seen:
            seen.append(n)
    return seen


def _explain_pip_failure(argv, output):
    """Plain-language explanation for a failed `pip install`.

    pip's own errors ("Failed to build 'pycryptodome'", exit code -6)
    say nothing about WHY it cannot work on Android: the package ships
    only source code, there is no Android wheel for it, and the phone
    has no C compiler. Say that, name the package, and point at the
    Crypto shim / a pinned wheel version when one applies.
    """
    import re
    if not argv or argv[0] != "install":
        return
    names = _pip_target_names(argv[1:])
    # The package pip actually choked on, from its own output.
    m = re.search(r"Failed to build ['\"]([^'\"]+)['\"]", output)
    if not m:
        m = re.search(
            r"Could not build wheels for ([A-Za-z0-9_.\-]+)", output
        )
    failed = m.group(1) if m else ""
    if failed and failed not in names:
        names.insert(0, failed)
    if "Failed to build" not in output and \
            "Could not build wheels" not in output:
        if "No matching distribution found" in output or \
                "Could not find a version" in output:
            _emit("ERR", "pip could not find that package. Check the "
                         "spelling, or it may need a newer Python.")
        elif "Connection error" in output or \
                "Could not fetch URL" in output:
            _emit("ERR", "pip could not reach the package index. "
                         "Check the phone's internet connection and "
                         "try again.")
        return
    shown = names[0] if names else "that package"
    _emit("ERR", "Why this failed: '%s' ships only source code — no "
                 "Android-compatible wheel exists for it, and this "
                 "device has no C compiler, so it cannot be built here."
          % shown)
    _emit("ERR", "Only pure-Python wheels and Chaquopy Android wheels "
                 "can install on this device.")
    lower = [n.lower() for n in names]
    if "pycryptodome" in lower or failed.lower() == "pycryptodome":
        # An unbounded spec would have been rewritten to ==3.21.0
        # before pip ran, so a build failure here means the user pinned
        # another version explicitly (e.g. ==4.4.0).
        _emit("ERR", "For pycryptodome: only version 3.21.0 has an "
                     "Android wheel. If you pinned another version "
                     "(e.g. ==4.4.0), it cannot install — use "
                     "pycryptodome==3.21.0 instead. (The app already "
                     "bundles 3.21.0, so `from Crypto.Cipher import "
                     "AES` works without installing anything.)")
    elif names:
        _emit("ERR", "If an older version of '%s' has an Android wheel, "
                     "try pinning it, e.g. pip install %s==<version>."
              % (shown, shown))


#: Newest pycryptodome with a Chaquopy Android wheel (cp313,
#: arm64-v8a + x86_64). PyPI 4.x has no Android wheel, so an unbounded
#: requirement (bare, `>=`/`>` with no upper bound) resolves to the
#: 4.x sdist and fails to build on device. The app also bundles this
#: exact version in the Chaquopy build-time pip block, so
#: `from Crypto.Cipher import AES` works with no install at all.
PYCRYPTODOME_PIN = "pycryptodome==3.21.0"


def _parse_requirement_token(token):
    """Split 'name[extras]spec; marker' into (name, extras, spec,
    marker). Returns None when the token is not a requirement."""
    import re
    marker = ""
    if ";" in token:
        token, marker = token.split(";", 1)
        marker = ";" + marker
    m = re.match(r"^([A-Za-z0-9_.\-]+)(\[[^\]]*\])?\s*(.*)$", token)
    if not m:
        return None
    return m.group(1), m.group(2) or "", (m.group(3) or "").strip(), marker


def _rewrite_pycryptodome_spec(token):
    """Rewrite an unbounded pycryptodome requirement to the pinned
    Android-wheel version, or return None when it must be left alone:
    an explicit ==/===/~/ pin, an upper bound, or an exclusion is the
    user's choice — the failure message explains if that cannot
    install (v1.0.3)."""
    parsed = _parse_requirement_token(token)
    if parsed is None:
        return None
    name, extras, spec, marker = parsed
    if name.lower().replace("_", "-") != "pycryptodome":
        return None
    if not spec:
        return "pycryptodome%s==3.21.0" % extras + marker
    if any(op in spec for op in ("==", "===", "~=", "!=", "<", "<=")):
        return None
    if ">=" in spec or ">" in spec:
        return "pycryptodome%s==3.21.0" % extras + marker
    return None


def _rewrite_requirements_file(path):
    """Rewrite unbounded pycryptodome lines in a requirements file.

    Returns (temp_path, [(original, replacement), ...]) for a rewritten
    TEMP copy written next to the original, or (None, []) when nothing
    needed rewriting (the original is used as-is). The caller's
    _run_pip deletes the temp copy after pip finishes; the user's file
    is never modified.
    """
    try:
        with open(path, encoding="utf-8", errors="ignore") as f:
            lines = f.read().splitlines()
    except Exception:
        return None, []
    changed = []
    out = []
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith(("#", "-")):
            out.append(line)
            continue
        req_part, sep, comment = stripped.partition(" #")
        new = _rewrite_pycryptodome_spec(req_part.strip())
        if new is not None:
            out.append(new + (sep + comment if sep else ""))
            changed.append((req_part.strip(), new))
        else:
            out.append(line)
    if not changed:
        return None, []
    tmp_path = os.path.join(
        os.path.dirname(os.path.abspath(path)),
        ".pyrunner-reqs-%d.txt" % os.getpid(),
    )
    try:
        with open(tmp_path, "w", encoding="utf-8") as f:
            f.write("\n".join(out) + "\n")
    except Exception:
        return None, []
    return tmp_path, changed


def _rewrite_pycryptodome_argv(pip_argv):
    """Rewrite unbounded pycryptodome requirements in a pip argv.

    Returns (new_argv, rewritten, temp_files): `rewritten` is a list
    of (original, replacement) for the console note, and `temp_files`
    are rewritten requirements-file copies to delete after pip runs.
    Only applies to `install`; anything else is returned unchanged.
    """
    if not pip_argv or pip_argv[0] != "install":
        return pip_argv, [], []
    value_flags = {
        "-r", "--requirement", "-c", "--constraint",
        "--target", "-t", "--extra-index-url",
        "--index-url", "--find-links", "-f",
    }
    out = []
    rewritten = []
    temp_files = []
    i = 0
    while i < len(pip_argv):
        tok = pip_argv[i]
        if tok in ("-r", "--requirement") and i + 1 < len(pip_argv):
            tmp, changed = _rewrite_requirements_file(pip_argv[i + 1])
            out.append(tok)
            if tmp is not None:
                temp_files.append(tmp)
                rewritten.extend(changed)
                out.append(tmp)
            else:
                out.append(pip_argv[i + 1])
            i += 2
            continue
        if tok in value_flags:
            out.append(tok)
            if i + 1 < len(pip_argv):
                out.append(pip_argv[i + 1])
            i += 2
            continue
        if tok.startswith("-"):
            out.append(tok)
            i += 1
            continue
        new = _rewrite_pycryptodome_spec(tok)
        if new is not None:
            rewritten.append((tok, new))
            out.append(new)
        else:
            out.append(tok)
        i += 1
    return out, rewritten, temp_files


def _run_pip(argv):
    """Run pip with the given argv list. Returns pip's exit code (int).

    pip is called as a library (``pip._internal.cli.main.main``) rather
    than via ``runpy`` on ``python -m pip``. Two reasons:

    * ``python -m pip`` runs pip as a CLI (``_cli=True``), and pip 26's
      install command then installs an import blocker that stays active
      until the process exits. This app is a long-lived process, so the
      next ``pip`` run -- and even ``import six`` afterwards -- would
      fail with ``BlockedImportError``. Calling ``main()`` runs pip as
      a library (``_cli=False``), so the blocker deactivates when the
      install finishes.
    * Even so, pip leaves the blocker on ``sys.meta_path`` and an audit
      hook behind, which would log one "Unsafe import" warning per
      newly-imported module into the console. The install command's
      import guard is therefore disabled for the duration of the call
      (it only protects against hooks importing half-installed packages
      mid-install; nothing else runs while pip installs in this app)
      and any leftover blocker state is cleared afterwards.
    """
    try:
        from pip._internal.cli.main import main as _pip_main
        from pip._internal.commands import install as _install_cmd
    except ImportError as e:
        _emit("ERR", "pip is not available inside this Python runtime: %s" % e)
        return 1
    target = _site_packages_dir()
    old_argv = sys.argv
    code = 0
    pip_argv = [str(a) for a in argv]
    # The explainer below gets the ORIGINAL request, not the rewritten
    # one (the temp requirements copy is deleted before it runs).
    orig_pip_argv = list(pip_argv)
    # pycryptodome (v1.0.3): rewrite an unbounded requirement to the
    # pinned Android-wheel version before pip runs, so `pip install
    # pycryptodome>=3.20.0` (or `-r requirements.txt` with that line)
    # does not resolve to the 4.x sdist and fail to build. Explicit
    # pins and upper bounds are left alone (user's choice).
    pip_argv, _rewritten, _temp_files = _rewrite_pycryptodome_argv(
        pip_argv
    )
    for _orig, _new in _rewritten:
        _emit("OUT", "Note: '%s' has no Android wheel, so installing "
                     "'%s' instead (the version with an Android wheel)."
              % (_orig, _new))
    # Install-only flags: --target and the Chaquopy wheel index make
    # sense for `install` only. `pip list` rejects --target outright
    # ("no such option: --target"), so it used to fail silently and
    # return empty output.
    if pip_argv and pip_argv[0] == "install":
        pip_argv += [
            "--target",
            target,
            "--no-warn-script-location",
            "--disable-pip-version-check",
            "--no-input",
            # Chaquopy's Android-wheel index, so native packages
            # (numpy, etc.) can install when a wheel exists for them.
            "--extra-index-url",
            "https://chaquo.com/pypi-13.1/",
        ]
    import contextlib

    @contextlib.contextmanager
    def _no_import_guard(*_args, **_kwargs):
        yield

    _orig_guard = getattr(_install_cmd, "_prevent_further_imports", None)
    if _orig_guard is not None:
        _install_cmd._prevent_further_imports = _no_import_guard
    # Tee the console streams while pip runs so a failure can be
    # explained in plain language afterwards (v1.0.3).
    old_out, old_err = sys.stdout, sys.stderr
    tee_out, tee_err = _TeeStream(old_out), _TeeStream(old_err)
    try:
        sys.stdout, sys.stderr = tee_out, tee_err
        sys.argv = ["pip"] + pip_argv
        try:
            code = _pip_main(pip_argv)
        except SystemExit as e:
            if isinstance(e.code, int):
                code = e.code
            elif e.code is None:
                code = 0
            else:
                code = 1
        if not isinstance(code, int):
            code = 0 if code is None else 1
    except BaseException:
        traceback.print_exc()
        code = 1
    finally:
        sys.stdout, sys.stderr = old_out, old_err
        if _orig_guard is not None:
            _install_cmd._prevent_further_imports = _orig_guard
        sys.argv = old_argv
        _reset_pip_import_state()
        for _tmp in _temp_files:
            try:
                os.remove(_tmp)
            except Exception:
                pass
    if code != 0:
        try:
            _explain_pip_failure(
                orig_pip_argv,
                "".join(tee_out.recorded + tee_err.recorded),
            )
        except Exception:
            pass
    return code


def _reset_pip_import_state():
    """Clear any import-blocking state pip left behind.

    Belt-and-braces for _run_pip: if a pip version installs its import
    blocker anyway, remove it from sys.meta_path and clear the active
    installation set, so later imports (and the next pip run) work.
    The audit hook pip registers cannot be unregistered, but with the
    active set empty it only warns, and the guard patch above means it
    is never installed in the first place.
    """
    try:
        from pip._internal.commands import install as _install_cmd
    except Exception:
        return
    try:
        _install_cmd._ACTIVE_INSTALLATIONS.clear()
    except Exception:
        pass
    try:
        blocker = _install_cmd._IMPORT_BLOCKER
        while blocker in sys.meta_path:
            sys.meta_path.remove(blocker)
    except Exception:
        pass


def pip_install(args):
    """pip install <args...>. Returns pip's exit code (int)."""
    _emit("EVT", "run_started|pip install")
    code = _run_pip(["install"] + _to_py_list(args))
    _emit("EVT", "run_finished|%d" % code)
    return code


def pip_list():
    """Return the text of `pip list` for the runtime site-packages."""
    target = _site_packages_dir()
    buf = io.StringIO()
    old_out = sys.stdout
    sys.stdout = buf
    try:
        _run_pip(["list", "--path", target])
    finally:
        sys.stdout = old_out
    return buf.getvalue()


def installed_packages():
    """Return 'name==version' lines for the installed packages (shared
    site-packages store plus Chaquopy-bundled ones), sorted by name.
    Used by the Packages screen. First occurrence wins on duplicates,
    and the shared store is first on sys.path, so it takes precedence.
    """
    try:
        from importlib import metadata
    except ImportError:
        return ""
    seen = {}
    try:
        for dist in metadata.distributions():
            name = (dist.metadata.get("Name") or "").strip()
            if not name:
                continue
            key = name.lower()
            if key not in seen:
                seen[key] = "%s==%s" % (name, dist.version)
    except Exception:
        return ""
    return "\n".join(sorted(seen.values(), key=str.lower))
