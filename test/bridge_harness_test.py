#!/usr/bin/env python3
"""CPython harness for the REAL pyrunner_bridge.py (G).

Runs the bridge exactly as MainActivity drives it on Android, but under
the system CPython with mock queues standing in for the Java
LinkedBlockingQueue objects and a mock ArrayList standing in for the
java.util.ArrayList Kotlin passes as `args`.

This is the strongest test possible without a device/emulator
(/dev/kvm does not exist here, so no emulator can boot). It proves
end-to-end, on a real Python runtime:

  1. init() wires the console streams.
  2. run_script() on the BUNDLED sample main.py (extracted verbatim
     from lib/services/project_service.dart _writeSample) with a
     Java-ArrayList-like args object — the exact call that crashed in
     v1.0.0 with `TypeError: 'ArrayList' object is not iterable` —
     returns exit code 0 and prints "Hello from PyRunner!", with the
     input() prompt fed from the mock input queue.
  3. run_module() passes Java-List args through to sys.argv.
  4. pip_list() runs without crashing (smoke only; pip may be absent
     or offline here — that is reported, not fatal).
  5. installed_packages() returns parseable 'name==version' lines.
  6. The VENDORED pip (src/main/python/pip/, shipped because Chaquopy
     does not bundle pip) is the copy the bridge uses, and a REAL pip
     install of the tiny pure-Python package `six` into the shared
     store succeeds — from PyPI when reachable, otherwise from a local
     wheel (test/fixtures/six-1.17.0-py2.py3-none-any.whl) — plus the
     exact command the user ran, `pip install -r requirements.txt`.

Run:  python3 test/bridge_harness_test.py
Exit: 0 when every hard check passes, 1 otherwise.
"""

import importlib.util
import json
import os
import queue
import re
import sys
import tempfile
import threading
import time

BRIDGE_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..",
    "android",
    "app",
    "src",
    "main",
    "python",
    "pyrunner_bridge.py",
)
DART_SERVICE_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..",
    "lib",
    "services",
    "project_service.dart",
)


class MockQueue:
    """Mimics java.util.concurrent.LinkedBlockingQueue (put/take/offer)."""

    def __init__(self, items=()):
        self._items = list(items)
        self.puts = []

    def put(self, item):
        self.puts.append(item)

    def take(self):
        if not self._items:
            raise RuntimeError("take() called with no input queued")
        return self._items.pop(0)

    def offer(self, item):
        self.puts.append(item)
        return True


class FakeJavaList:
    """Mimics java.util.ArrayList: size()/get(), NOT iterable."""

    def __init__(self, items):
        self._items = list(items)

    def size(self):
        return len(self._items)

    def get(self, i):
        return self._items[i]

    def __iter__(self):
        raise TypeError("'ArrayList' object is not iterable")


class BlockingQueue:
    """Blocking queue with the Java LinkedBlockingQueue API, for the
    live (async) tests in section 10: take() blocks like the Kotlin
    executor's thread does, offer()/put() never block, poll() returns
    None when empty."""

    def __init__(self):
        self._q = queue.Queue()

    def put(self, item):
        self._q.put(item)

    def take(self):
        return self._q.get()

    def offer(self, item):
        self._q.put(item)
        return True

    def poll(self):
        try:
            return self._q.get_nowait()
        except queue.Empty:
            return None

    def qsize(self):
        return self._q.qsize()


class LiveDriver:
    """Drives the bridge the way MainActivity does: one worker thread
    runs the script (Kotlin's single-thread executor) while the main
    thread feeds input and calls request_stop(). A drain thread
    collects the output queue so the main thread can wait for
    input_request / run_finished events."""

    def __init__(self, bridge):
        self.bridge = bridge
        self.input_q = BlockingQueue()
        self.output_q = BlockingQueue()
        self.lines = []
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._drain_t = threading.Thread(target=self._drain, daemon=True)

    def start(self):
        self.bridge._input_queue = self.input_q
        self.bridge._output_queue = self.output_q
        self._drain_t.start()

    def _drain(self):
        while not self._stop.is_set():
            try:
                item = self.output_q._q.get(timeout=0.05)
            except queue.Empty:
                continue
            with self._lock:
                self.lines.append(item)

    def text(self, since=0):
        with self._lock:
            return "\n".join(self.lines[since:])

    def mark(self):
        with self._lock:
            return len(self.lines)

    def wait_for(self, fragment, timeout=5.0):
        end = time.time() + timeout
        while time.time() < end:
            with self._lock:
                if any(fragment in l for l in self.lines):
                    return True
            time.sleep(0.02)
        return False

    def count(self, fragment):
        with self._lock:
            return sum(1 for l in self.lines if fragment in l)

    def wait_for_count(self, fragment, n, timeout=5.0):
        end = time.time() + timeout
        while time.time() < end:
            if self.count(fragment) >= n:
                return True
            time.sleep(0.02)
        return False

    def wait_for_new(self, fragment, since, timeout=5.0):
        """Wait until a line containing `fragment` appears at index
        >= `since` — i.e. wait for the drain thread to catch up with
        everything the run emitted, up to and including that line."""
        end = time.time() + timeout
        while time.time() < end:
            with self._lock:
                for line in self.lines[since:]:
                    if fragment in line:
                        return True
            time.sleep(0.02)
        return False

    def run_in_thread(self, fn):
        result = {}

        def _run():
            try:
                result["code"] = fn()
            except BaseException as e:  # noqa: BLE001
                result["exc"] = e

        t = threading.Thread(target=_run, daemon=True)
        t.start()
        return t, result

    def close(self):
        self._stop.set()


def load_bridge():
    spec = importlib.util.spec_from_file_location(
        "pyrunner_bridge", BRIDGE_PATH
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


GUEST_PROJECT_SRC = "/tmp/guestgen/Guest_gen-main/Guest_gen-main"
GUEST_DEPS_DIR = "/tmp/refguest"
GUEST_DEPS = (
    "pycryptodome",
    "colorama",
    "requests",
    "PyJWT",
    "protobuf",
    "protobuf-decoder",
    "urllib3",
)


def ensure_guest_deps():
    """Make the Guest_gen-main dependencies importable.

    The user's real project needs Crypto, colorama, requests, jwt,
    google.protobuf and protobuf_decoder. Reuse /tmp/refguest when it
    already has them (installed during development); otherwise install
    them there with the system pip (pure-Python wheels + the Linux
    pycryptodome wheel — the Android wheel is verified inside the APK
    instead). Returns the dir, or None when it cannot be provided
    (offline) — the Guest_gen checks are then skipped with a note.
    Returns None also when the packages are already importable from
    the ambient environment (no dir needed).
    """
    import subprocess

    needed = ("Crypto", "colorama", "requests", "jwt",
              "google.protobuf", "protobuf_decoder")

    def _all_present():
        return all(
            importlib.util.find_spec(n) is not None for n in needed
        )

    if _all_present():
        return None
    if os.path.isdir(GUEST_DEPS_DIR) and GUEST_DEPS_DIR not in sys.path:
        sys.path.insert(0, GUEST_DEPS_DIR)
    if _all_present():
        return GUEST_DEPS_DIR
    try:
        r = subprocess.run(
            [sys.executable, "-m", "pip", "install", "--quiet",
             "--target", GUEST_DEPS_DIR, *GUEST_DEPS],
            capture_output=True, timeout=240,
        )
    except Exception:
        return None
    if r.returncode != 0:
        return None
    if GUEST_DEPS_DIR not in sys.path:
        sys.path.insert(0, GUEST_DEPS_DIR)
    return GUEST_DEPS_DIR if _all_present() else None


def extract_sample_main_py():
    """The exact sample main.py the app writes, straight from the Dart
    source (project_service.dart _writeSample), so the harness can never
    drift from what the user actually runs."""
    with open(DART_SERVICE_PATH, encoding="utf-8") as f:
        dart = f.read()
    # Anchor to _writeSample: the file now also holds _writeTemplate
    # (v1.0.10), whose main.py files must NOT be mistaken for the
    # sample — the unanchored regex matched the CLI template first.
    m = re.search(
        r"Future<void> _writeSample\(Directory target\) async \{\s*"
        r"await File\(p\.join\(target\.path, 'main\.py'\)\)"
        r"\.writeAsString\('''(.*?)'''\)",
        dart, re.DOTALL,
    )
    if not m:
        raise RuntimeError("could not extract the sample main.py from Dart")
    return m.group(1)


def main():
    checks = []
    notes = []

    def check(name, cond, detail=""):
        checks.append((name, bool(cond)))
        status = "PASS" if cond else "FAIL"
        print(f"[{status}] {name}" + (f" — {detail}" if detail else ""))
        if not cond:
            # check() prints go through the bridge's _OutputStream
            # (sys.stdout is swapped by bridge.init), so a failure's
            # detail never reaches the terminal — also log it to a
            # real file for debugging.
            try:
                with open("/tmp/harness_failures.txt", "a",
                          encoding="utf-8") as fh:
                    fh.write(f"[FAIL] {name} — {detail}\n")
            except OSError:
                pass

    bridge = load_bridge()

    # The vendored pip lives next to the bridge; put the bridge source
    # dir first on sys.path so `import pip` inside the bridge resolves
    # to the VENDORED copy — exactly as Chaquopy puts src/main/python on
    # sys.path on device. This proves the app ships its own pip.
    bridge_dir = os.path.dirname(BRIDGE_PATH)
    old_path = list(sys.path)
    sys.path.insert(0, bridge_dir)

    # Real Crypto for the end-to-end script checks in section 7, when
    # available in this environment. The app bundles the real
    # pycryptodome wheel (3.21.0, Chaquopy Android wheel) — this machine
    # cannot import an Android wheel, so the reference copy installed
    # at /tmp/refcrypto during development stands in for it. When it
    # is absent, those two checks are skipped with a note (the bundled
    # wheel is verified inside the APK instead, see README).
    refcrypto = "/tmp/refcrypto"
    has_real_crypto = os.path.isdir(os.path.join(refcrypto, "Crypto"))
    if has_real_crypto and refcrypto not in sys.path:
        sys.path.insert(0, refcrypto)

    # --- 1. init() + run_script() on the bundled sample ---------------
    input_q = MockQueue(items=["Tester\n"])
    output_q = MockQueue()
    old_stdout, old_stderr, old_stdin = sys.stdout, sys.stderr, sys.stdin
    tmp_home = tempfile.mkdtemp(prefix="pyrunner_harness_home_")
    old_home = os.environ.get("HOME")
    os.environ["HOME"] = tmp_home
    try:
        bridge.init(input_q, output_q)

        sample = extract_sample_main_py()
        check("sample main.py extracted from Dart source",
              'print("Hello from PyRunner!")' in sample)

        with tempfile.TemporaryDirectory(
            prefix="pyrunner_harness_project_"
        ) as proj:
            main_py = os.path.join(proj, "main.py")
            with open(main_py, "w", encoding="utf-8") as f:
                f.write(sample)
            # Empty args as a FakeJavaList: exactly what the Run button
            # sends, and exactly what crashed in v1.0.0.
            code = bridge.run_script(main_py, FakeJavaList([]), proj)

        out_lines = [p for p in output_q.puts if p.startswith("OUT|")]
        err_lines = [p for p in output_q.puts if p.startswith("ERR|")]
        out_text = "\n".join(out_lines)
        check("run_script returns exit code 0", code == 0, f"code={code}")
        check('"Hello from PyRunner!" printed',
              "Hello from PyRunner!" in out_text)
        check('input() fed from the queue ("Tester")',
              "Nice to meet you, Tester!" in out_text)
        check('sample runs to the end ("Done. Edit me")',
              "Done. Edit me and run again!" in out_text)
        check("no traceback / error output", not err_lines,
              "; ".join(err_lines[:2]) if err_lines else "")

        # --- 2. run_module() with Java-List args -----------------------
        with tempfile.TemporaryDirectory(
            prefix="pyrunner_harness_module_"
        ) as proj:
            with open(os.path.join(proj, "args_echo.py"), "w") as f:
                f.write("import sys\nprint('ARGV:', sys.argv)\n")
            code = bridge.run_module(
                "args_echo", FakeJavaList(["a", "b"]), proj
            )
        out_text = "\n".join(
            p for p in output_q.puts if p.startswith("OUT|")
        )
        check("run_module returns exit code 0", code == 0, f"code={code}")
        check("run_module passes Java-List args to sys.argv",
              "'a'" in out_text and "'b'" in out_text, out_text.strip())

        # --- 3. _to_py_list direct conversion -------------------------
        check("_to_py_list converts a Java-List-like object",
              bridge._to_py_list(FakeJavaList(["x", "y"])) == ["x", "y"])
        check("_to_py_list(None) -> []",
              bridge._to_py_list(None) == [])

        # --- 4. pip_list smoke ----------------------------------------
        # Regression: _run_pip used to append --target to every pip
        # subcommand, and `pip list` rejects it ("no such option:
        # --target"), so pip list silently returned empty output.
        # Note: pip prints nothing at all for an empty store (not even
        # a header), so seed a fake distribution first to prove the
        # command really runs.
        try:
            fake_dist = os.path.join(
                tmp_home, "site-packages", "fakepkg-1.2.3.dist-info"
            )
            os.makedirs(fake_dist, exist_ok=True)
            with open(os.path.join(fake_dist, "METADATA"), "w") as f:
                f.write("Metadata-Version: 2.1\nName: fakepkg\n"
                        "Version: 1.2.3\n")
            text = bridge.pip_list()
            notes.append(f"pip_list returned {len(text)} chars")
            check("pip_list lists the shared store",
                  isinstance(text, str) and "fakepkg" in text,
                  repr(text[:120]))
        except Exception as e:  # noqa: BLE001 - report, don't crash
            notes.append(f"pip_list raised {type(e).__name__}: {e}")
            check("pip_list lists the shared store", False, str(e))

        # --- 5. installed_packages ------------------------------------
        try:
            text = bridge.installed_packages()
            lines = [ln for ln in text.splitlines() if "==" in ln]
            check("installed_packages returns name==version lines",
                  isinstance(text, str) and len(lines) > 0,
                  f"{len(lines)} packages")
        except Exception as e:  # noqa: BLE001
            check("installed_packages returns name==version lines",
                  False, str(e))

        # --- 6. vendored pip: real install ----------------------------
        # Chaquopy does not bundle pip, so the app ships pip 26.3 in
        # src/main/python/pip/. Prove the bridge uses THAT copy and can
        # really install a package into the shared store.
        try:
            import pip as _pip_mod
            check("pip resolves to the vendored copy",
                  _pip_mod.__file__.startswith(bridge_dir),
                  _pip_mod.__file__)
            check("vendored pip version is 26.3",
                  _pip_mod.__version__.startswith("26.3"),
                  _pip_mod.__version__)
        except Exception as e:  # noqa: BLE001
            check("pip resolves to the vendored copy", False, str(e))
            check("vendored pip version is 26.3", False, str(e))

        target = bridge._site_packages_dir()
        installed_from = None
        code = bridge.pip_install(FakeJavaList(["six"]))
        if code == 0 and os.path.exists(os.path.join(target, "six.py")):
            installed_from = "PyPI"
        else:
            notes.append(f"PyPI install of six failed (code={code}); "
                         "falling back to the local wheel")
            wheel = os.path.join(
                os.path.dirname(os.path.abspath(__file__)),
                "fixtures", "six-1.17.0-py2.py3-none-any.whl")
            code = bridge.pip_install(FakeJavaList([wheel]))
            if code == 0 and os.path.exists(
                    os.path.join(target, "six.py")):
                installed_from = "local wheel"
        check("pip install six succeeds (exit 0, six.py in store)",
              installed_from is not None,
              f"from={installed_from} code={code}")
        try:
            if target not in sys.path:
                sys.path.insert(0, target)
            import six as _six
            check("installed six is importable (1.17.0)",
                  _six.__version__ == "1.17.0", _six.__version__)
        except Exception as e:  # noqa: BLE001
            check("installed six is importable (1.17.0)", False, str(e))
        text = bridge.pip_list()
        check("pip list shows six after install", "six" in text,
              repr(text[:200]))
        # The exact command the user ran: pip install -r requirements.txt
        with tempfile.TemporaryDirectory(
            prefix="pyrunner_harness_reqs_"
        ) as reqdir:
            req = os.path.join(reqdir, "requirements.txt")
            with open(req, "w") as f:
                f.write("six\n")
            code = bridge.pip_install(FakeJavaList(["-r", req]))
        check("pip install -r requirements.txt succeeds",
              code == 0, f"code={code}")

        # --- 7. pycryptodome pin + v1.0.3 bridge audit fixes -----------
        # (a) Unbounded pycryptodome requirements are rewritten to the
        # pinned Android-wheel version before pip runs; explicit pins,
        # upper bounds and exclusions are the user's choice and are
        # left alone.
        rewrite_cases = [
            (["install", "pycryptodome"],
             ["install", "pycryptodome==3.21.0"]),
            (["install", "pycryptodome>=3.20.0"],
             ["install", "pycryptodome==3.21.0"]),
            (["install", "pycryptodome>3.0"],
             ["install", "pycryptodome==3.21.0"]),
            (["install", "requests", "pycryptodome>=3.20.0"],
             ["install", "requests", "pycryptodome==3.21.0"]),
            (["install", "pycryptodome==4.4.0"],
             ["install", "pycryptodome==4.4.0"]),
            (["install", "pycryptodome>=3.20.0,<4.0"],
             ["install", "pycryptodome>=3.20.0,<4.0"]),
            (["install", "pycryptodome~=3.21"],
             ["install", "pycryptodome~=3.21"]),
            (["list"], ["list"]),
        ]
        rewrite_ok = True
        for argv, expected in rewrite_cases:
            got, _, _ = bridge._rewrite_pycryptodome_argv(argv)
            if got != expected:
                rewrite_ok = False
                notes.append(f"rewrite {argv} -> {got}, want {expected}")
        check("unbounded pycryptodome specs rewritten to ==3.21.0; "
              "explicit pins/bounds left alone", rewrite_ok)
        # ... and a -r requirements.txt gets a rewritten TEMP copy
        # while the user's file is left untouched.
        with tempfile.TemporaryDirectory(
            prefix="pyrunner_harness_reqrewrite_"
        ) as reqdir:
            req = os.path.join(reqdir, "requirements.txt")
            with open(req, "w") as f:
                f.write("requests\npycryptodome>=3.20.0  # crypto\n"
                        "pycryptodome==4.4.0\n")
            got, rewritten, temp_files = (
                bridge._rewrite_pycryptodome_argv(["install", "-r", req])
            )
            tmp_ok = (
                len(temp_files) == 1
                and got[0:2] == ["install", "-r"]
                and got[2] != req
                and os.path.exists(got[2])
            )
            if tmp_ok:
                with open(got[2]) as f:
                    tmp_text = f.read()
                tmp_ok = ("pycryptodome==3.21.0" in tmp_text
                          and "# crypto" in tmp_text
                          and "pycryptodome==4.4.0" in tmp_text
                          and "pycryptodome>=3.20.0" not in tmp_text)
            with open(req) as f:
                orig_ok = "pycryptodome>=3.20.0" in f.read()
            for tmp in temp_files:
                try:
                    os.remove(tmp)
                except Exception:
                    pass
        check("requirements.txt rewritten via temp copy; original "
              "untouched", tmp_ok and orig_ok and rewritten
              == [("pycryptodome>=3.20.0", "pycryptodome==3.21.0")],
              repr(rewritten))
        # (b) Run events carry the project dir, so the Dart side can
        # route output to the right project's log.
        with tempfile.TemporaryDirectory(
            prefix="pyrunner_harness_tag_"
        ) as proj:
            with open(os.path.join(proj, "main.py"), "w") as f:
                f.write("print('tag-me')\n")
            code = bridge.run_script(
                os.path.join(proj, "main.py"), FakeJavaList([]), proj
            )
        check("run_finished event is tagged with the project dir",
              code == 0 and any(
                  p == "EVT|run_finished|%s|0" % proj
                  for p in output_q.puts),
              [p for p in output_q.puts if "run_finished" in p][:1])
        # (c) The user's exact failing import now works end to end:
        # a script doing `from Crypto.Cipher import AES` runs through
        # run_script and prints success — against the REAL pycryptodome
        # (the app bundles the real 3.21.0 wheel; here the reference
        # copy at /tmp/refcrypto stands in for it).
        if has_real_crypto:
            with tempfile.TemporaryDirectory(
                prefix="pyrunner_harness_crypto_"
            ) as proj:
                with open(os.path.join(proj, "main.py"), "w") as f:
                    f.write(
                        "from Crypto.Cipher import AES\n"
                        "from Crypto.Util.Padding import pad, unpad\n"
                        "from Crypto.Random import get_random_bytes\n"
                        "key = get_random_bytes(32)\n"
                        "iv = get_random_bytes(16)\n"
                        "ct = AES.new(key, AES.MODE_CBC, iv).encrypt(\n"
                        "    pad(b'Hello from PyRunner!', 16))\n"
                        "pt = unpad(AES.new(key, AES.MODE_CBC, iv)\n"
                        "           .decrypt(ct), 16)\n"
                        "assert pt == b'Hello from PyRunner!'\n"
                        "print('CRYPTO_OK')\n"
                    )
                before = len(output_q.puts)
                code = bridge.run_script(
                    os.path.join(proj, "main.py"), FakeJavaList([]), proj
                )
            new_out = "\n".join(output_q.puts[before:])
            check("run_script: `from Crypto.Cipher import AES` works "
                  "(real pycryptodome)",
                  code == 0 and "CRYPTO_OK" in new_out, f"code={code}")
            # GCM round-trip through the bridge too.
            with tempfile.TemporaryDirectory(
                prefix="pyrunner_harness_gcm_"
            ) as proj:
                with open(os.path.join(proj, "main.py"), "w") as f:
                    f.write(
                        "from Crypto.Cipher import AES\n"
                        "from Crypto.Random import get_random_bytes\n"
                        "key = get_random_bytes(32)\n"
                        "nonce = get_random_bytes(12)\n"
                        "c = AES.new(key, AES.MODE_GCM, nonce=nonce)\n"
                        "c.update(b'header')\n"
                        "ct, tag = c.encrypt_and_digest(b'secret!')\n"
                        "d = AES.new(key, AES.MODE_GCM, nonce=nonce)\n"
                        "d.update(b'header')\n"
                        "assert d.decrypt_and_verify(ct, tag) "
                        "== b'secret!'\n"
                        "print('GCM_OK')\n"
                    )
                before = len(output_q.puts)
                code = bridge.run_script(
                    os.path.join(proj, "main.py"), FakeJavaList([]), proj
                )
            new_out = "\n".join(output_q.puts[before:])
            check("run_script: AES-GCM round-trip works (real "
                  "pycryptodome)",
                  code == 0 and "GCM_OK" in new_out, f"code={code}")
        else:
            notes.append("no real Crypto in this environment — AES/GCM "
                         "script checks skipped; the bundled wheel is "
                         "verified inside the APK instead")
        # (d) installed_packages() lists the real Crypto when one is
        # present (on device, the bundled 3.21.0 wheel shows up here).
        text = bridge.installed_packages()
        if has_real_crypto:
            check("installed_packages lists the real pycryptodome",
                  "pycryptodome==" in text, repr(text[:200]))
        else:
            notes.append("installed_packages Crypto check skipped "
                         "(no real Crypto here)")
        # (e) Audit fix: installed packages are importable on the FIRST
        # run, with no pip command having run yet in this session.
        # (Seed a package straight into the shared store, then run a
        # script that imports it — run_script must have site-packages
        # on sys.path from the start.)
        with open(os.path.join(target, "first_run_pkg.py"), "w") as f:
            f.write("VALUE = 42\n")
        with tempfile.TemporaryDirectory(
            prefix="pyrunner_harness_firstrun_"
        ) as proj:
            with open(os.path.join(proj, "main.py"), "w") as f:
                f.write("import first_run_pkg\n"
                        "print('FIRST_RUN_PKG', first_run_pkg.VALUE)\n")
            before = len(output_q.puts)
            code = bridge.run_script(
                os.path.join(proj, "main.py"), FakeJavaList([]), proj
            )
        new_out = "\n".join(output_q.puts[before:])
        check("site-packages importable on first run (no prior pip)",
              code == 0 and "FIRST_RUN_PKG 42" in new_out,
              f"code={code}")
        # (f) Audit fix: the REPL works after a Stop, and exit() is
        # quiet. (Simulate a stop, then eval.)
        bridge._stop = True
        before = len(output_q.puts)
        bridge.repl_eval("1 + 1")
        new_out = "\n".join(output_q.puts[before:])
        check("REPL works after a stop (no stale KeyboardInterrupt)",
              "2" in new_out and "KeyboardInterrupt" not in new_out,
              new_out.strip()[:200])
        before = len(output_q.puts)
        bridge.repl_eval("exit()")
        new_out = "\n".join(output_q.puts[before:])
        check("REPL exit() is quiet (no traceback)",
              "Traceback" not in new_out and "SystemExit" not in new_out,
              new_out.strip()[:200])
        # (g) Audit fix: the REPL can import from the project dir of
        # the last run.
        with tempfile.TemporaryDirectory(
            prefix="pyrunner_harness_replproj_"
        ) as proj:
            with open(os.path.join(proj, "helper.py"), "w") as f:
                f.write("VALUE = 'from-helper'\n")
            with open(os.path.join(proj, "main.py"), "w") as f:
                f.write("print('ran')\n")
            bridge.run_script(
                os.path.join(proj, "main.py"), FakeJavaList([]), proj
            )
            before = len(output_q.puts)
            bridge.repl_eval("import helper; print(helper.VALUE)")
        new_out = "\n".join(output_q.puts[before:])
        check("REPL imports from the last run's project dir",
              "from-helper" in new_out, new_out.strip()[:200])
        # (h) pip failure messaging: the explainer names the package,
        # says why it cannot build on Android, and points at the
        # pinned wheel version for pycryptodome — without running a
        # real (slow) pip build. (An unbounded spec would have been
        # rewritten to ==3.21.0 first, so this simulates the user
        # pinning 4.4.0 explicitly.)
        before = len(output_q.puts)
        bridge._explain_pip_failure(
            ["install", "pycryptodome==4.4.0"],
            "ERROR: Failed to build 'pycryptodome'\n"
            "ERROR: Failed to build installable wheels for some "
            "pyproject.toml based projects (pycryptodome)\n",
        )
        err_text = "\n".join(
            p for p in output_q.puts[before:] if p.startswith("ERR|")
        )
        check("pip failure explains the missing wheel + 3.21.0 pin",
              "pycryptodome" in err_text
              and "3.21.0" in err_text
              and "Android wheel" in err_text,
              err_text[:300])
        # ... and the requirement names are read out of the -r file.
        with tempfile.TemporaryDirectory(
            prefix="pyrunner_harness_reqnames_"
        ) as reqdir:
            req = os.path.join(reqdir, "requirements.txt")
            with open(req, "w") as f:
                f.write("requests\npycryptodome>=3.20.0\n# comment\n")
            names = bridge._pip_target_names(["install", "-r", req])
        check("pip target names parsed from requirements.txt",
              names == ["requests", "pycryptodome"], repr(names))

        # --- 8. The user's real project: Guest_gen-main --------------
        # The user sent their real project (ZIP, extracted read-only at
        # /tmp/guestgen/Guest_gen-main/Guest_gen-main). It is interactive
        # (main_menu with input()), imports Crypto, colorama, requests,
        # jwt, protobuf and protobuf_decoder, and writes
        # active_and_generated_accounts.json atomically (.tmp + rename)
        # into the project root. Network calls to the game API cannot
        # work in this sandbox, so this section asserts startup +
        # imports + menu + file I/O — not a full account generation.
        # The project is never modified: tests run on temp COPIES.
        import shutil

        guest_dir = ensure_guest_deps()
        if guest_dir is not None and guest_dir not in sys.path:
            sys.path.insert(0, guest_dir)
        if not os.path.isdir(GUEST_PROJECT_SRC):
            notes.append("Guest_gen-main source not present at "
                         f"{GUEST_PROJECT_SRC} — section 8 skipped")
        elif guest_dir is None and not all(
                importlib.util.find_spec(n) is not None
                for n in ("Crypto", "colorama", "requests", "jwt",
                          "google.protobuf", "protobuf_decoder")):
            notes.append("Guest_gen deps unavailable (offline?) — "
                         "section 8 skipped")
        else:
            # The project's clear_screen() runs os.system('clear');
            # TERM=dumb keeps that quiet in this sandbox.
            old_term = os.environ.get("TERM")
            os.environ["TERM"] = "dumb"
            try:
                # (a) Menu starts, renders, exits on "0".
                with tempfile.TemporaryDirectory(
                    prefix="pyrunner_harness_guest_"
                ) as proj:
                    shutil.copytree(GUEST_PROJECT_SRC, proj,
                                    dirs_exist_ok=True)
                    bridge._input_queue = MockQueue(items=["0\n"])
                    before = len(output_q.puts)
                    code = bridge.run_script(
                        os.path.join(proj, "main.py"),
                        FakeJavaList([]), proj,
                    )
                new_out = "\n".join(output_q.puts[before:])
                new_err = "\n".join(
                    p for p in output_q.puts[before:]
                    if p.startswith("ERR|")
                )
                check("Guest_gen-main: menu starts and exits on '0'",
                      code == 0
                      and "MASTER AUTOMATION MENU" in new_out
                      and "ACTIVATED" in new_out,
                      f"code={code}")
                check("Guest_gen-main: no traceback on menu exit",
                      "Traceback" not in new_err, new_err[:200])

                # (b) "View Saved Accounts" reads the project's JSON
                # at the project root and prints the stats, then
                # returns to the menu and exits.
                with tempfile.TemporaryDirectory(
                    prefix="pyrunner_harness_guest_view_"
                ) as proj:
                    shutil.copytree(GUEST_PROJECT_SRC, proj,
                                    dirs_exist_ok=True)
                    bridge._input_queue = MockQueue(
                        items=["4\n", "\n", "0\n"]
                    )
                    before = len(output_q.puts)
                    code = bridge.run_script(
                        os.path.join(proj, "main.py"),
                        FakeJavaList([]), proj,
                    )
                new_out = "\n".join(output_q.puts[before:])
                check("Guest_gen-main: 'View Saved Accounts' prints "
                      "the stats from the project-root JSON",
                      code == 0
                      and "Total accounts" in new_out,
                      f"code={code}")

                # (c) The atomic save writes
                # active_and_generated_accounts.json into the PROJECT
                # ROOT (not app/), with no .tmp left behind.
                with tempfile.TemporaryDirectory(
                    prefix="pyrunner_harness_guest_save_"
                ) as proj:
                    shutil.copytree(GUEST_PROJECT_SRC, proj,
                                    dirs_exist_ok=True)
                    json_path = os.path.join(
                        proj, "active_and_generated_accounts.json"
                    )
                    if os.path.exists(json_path):
                        os.remove(json_path)
                    driver = os.path.join(proj, "driver_save_test.py")
                    with open(driver, "w", encoding="utf-8") as f:
                        f.write(
                            "from pathlib import Path\n"
                            "PROJECT_ROOT = Path(__file__).resolve()"
                            ".parent\n"
                            "APP_DIR = PROJECT_ROOT / 'app'\n"
                            "MODULE_FILES = ('config.py', 'protocol.py',"
                            " 'generation.py', 'activation.py',"
                            " 'workflow.py')\n"
                            "def load_application():\n"
                            "    namespace = {'__name__': '__main__',"
                            " '__file__': str(PROJECT_ROOT / 'main.py'),"
                            " '__package__': None}\n"
                            "    for module_name in MODULE_FILES:\n"
                            "        module_path = APP_DIR / module_name\n"
                            "        source = module_path.read_text("
                            "encoding='utf-8')\n"
                            "        exec(compile(source,"
                            " str(module_path), 'exec'), namespace,"
                            " namespace)\n"
                            "    return namespace\n"
                            "ns = load_application()\n"
                            "ok = ns['_save_normal_account_impl']("
                            "{'uid': '987654321',"
                            " 'password': 'pw-test',"
                            " 'account_id': 'acc-1', 'jwt': 'jwt-test',"
                            " 'name': 'test-name'}, 'BD')\n"
                            "print('SAVE_OK' if ok else 'SAVE_FAIL')\n"
                        )
                    bridge._input_queue = MockQueue(items=[])
                    before = len(output_q.puts)
                    code = bridge.run_script(
                        driver, FakeJavaList([]), proj
                    )
                    new_out = "\n".join(output_q.puts[before:])
                    saved = os.path.exists(json_path)
                    saved_in_app = os.path.exists(os.path.join(
                        proj, "app",
                        "active_and_generated_accounts.json"))
                    tmp_left = os.path.exists(json_path + ".tmp")
                    saved_uid = None
                    if saved:
                        with open(json_path, encoding="utf-8") as f:
                            saved_data = json.load(f)
                        saved_uid = (
                            saved_data[0].get("uid")
                            if isinstance(saved_data, list)
                            and saved_data else None
                        )
                check("Guest_gen-main: atomic save writes the JSON "
                      "into the project root",
                      code == 0 and "SAVE_OK" in new_out and saved
                      and saved_uid == "987654321"
                      and not saved_in_app and not tmp_left,
                      f"code={code} saved={saved} uid={saved_uid} "
                      f"in_app={saved_in_app} tmp_left={tmp_left}")
            finally:
                if old_term is None:
                    os.environ.pop("TERM", None)
                else:
                    os.environ["TERM"] = old_term
                bridge._input_queue = input_q

        # --- 9. v1.0.4: run cwd + partial (\r) lines -----------------
        # (a) A script's relative file writes land in the run's working
        # directory (the project dir by default) — this is what makes
        # in-place projects work: files a script creates appear in the
        # real folder, not in the app's process directory.
        with tempfile.TemporaryDirectory(
            prefix="pyrunner_harness_cwd_"
        ) as proj:
            writer = os.path.join(proj, "writer.py")
            with open(writer, "w", encoding="utf-8") as f:
                f.write("open('created_by_script.txt', 'w')"
                        ".write('hello')\n"
                        "print('wrote it')\n")
            cwd_before = os.getcwd()
            bridge._input_queue = MockQueue(items=[])
            code = bridge.run_script(
                writer, FakeJavaList([]), proj,
            )
            check("run_script chdirs: relative write lands in the "
                  "project dir",
                  code == 0 and os.path.exists(
                      os.path.join(proj, "created_by_script.txt")),
                  f"code={code}")
            # (b) An explicit cwd wins: a subfolder run writes into
            # the subfolder (the "Run in terminal" case).
            sub = os.path.join(proj, "sub")
            os.makedirs(sub)
            bridge._input_queue = MockQueue(items=[])
            code = bridge.run_script(
                writer, FakeJavaList([]), proj, sub,
            )
            check("run_script honours an explicit cwd (subfolder)",
                  code == 0 and os.path.exists(
                      os.path.join(sub, "created_by_script.txt")),
                  f"code={code}")
            # (c) The process cwd is restored after the run.
            check("cwd is restored after the run",
                  os.getcwd() == cwd_before,
                  f"cwd={os.getcwd()} before={cwd_before}")
            bridge._input_queue = input_q

        # (d) Partial lines: a \r progress write flushed without a
        # newline is tagged OUTR (replace), and \r keeps only the text
        # after the last carriage return.
        before = len(output_q.puts)
        stream = bridge._OutputStream("OUT")
        stream.write("Loading 10%")
        stream.flush()
        stream.write("\rLoading 50%")
        stream.flush()
        stream.write("Loading 100%\n")
        stream.write("a\rb\n")
        partials = output_q.puts[before:]
        check("progress flushes are tagged OUTR with the \\r tail",
              partials == ["OUTR|Loading 10%", "OUTR|Loading 50%",
                           "OUT|Loading 100%", "OUT|b"],
              repr(partials))

        # --- 10. v1.0.10: stop/input regression + robustness --------
        # The bug: the sample project died at its first input() with
        # KeyboardInterrupt although the user never pressed Stop. Root
        # cause: request_stop() offers STOP_SENTINEL into the input
        # queue even when the script is NOT blocked in input(), so the
        # sentinel lingers and the NEXT run's input() consumes it.
        # Fix: readline() honours a sentinel only when _stop is True
        # for the current run; a stale one is discarded and the read
        # keeps waiting for real input.
        #
        # These tests drive the bridge LIVE (worker thread + blocking
        # queues), exactly like MainActivity's executor does — the
        # pre-loaded MockQueue in the sections above cannot express
        # "stop while looping, then run again".
        live = LiveDriver(bridge)
        live.start()
        try:
            with tempfile.TemporaryDirectory(
                prefix="pyrunner_harness_live_"
            ) as proj:
                sample = extract_sample_main_py()
                main_py = os.path.join(proj, "main.py")
                with open(main_py, "w", encoding="utf-8") as f:
                    f.write(sample)

                # (a) Live feed happy path: run sample in a thread,
                # wait for THIS run's input_request, feed "Riad" -> exit 0.
                mark_a = live.mark()
                base_a = live.count("input_request")
                t, res = live.run_in_thread(
                    lambda: bridge.run_script(main_py, [], proj)
                )
                saw = live.wait_for_count(
                    "input_request", base_a + 1, 5.0)
                if saw:
                    live.input_q.offer("Riad")
                t.join(timeout=10)
                live.wait_for_new("run_finished", mark_a, 5.0)
                out = live.text(mark_a)
                check("live feed: sample completes after input",
                      saw and not t.is_alive() and res.get("code") == 0
                      and "Nice to meet you, Riad!" in out
                      and "Done. Edit me and run again!" in out,
                      f"code={res.get('code')} saw={saw}")

                # (b) STALE SENTINEL REGRESSION: stop a looping script
                # (not in input()), then run the sample and feed input.
                loop_py = os.path.join(proj, "loop.py")
                with open(loop_py, "w", encoding="utf-8") as f:
                    f.write("import time\nwhile True:\n"
                            "    time.sleep(0.01)\n")
                t2, res2 = live.run_in_thread(
                    lambda: bridge.run_script(loop_py, [], proj)
                )
                time.sleep(0.5)
                bridge.request_stop()
                t2.join(timeout=10)
                check("stop while looping exits 130",
                      not t2.is_alive() and res2.get("code") == 130,
                      f"code={res2.get('code')}")
                mark = live.mark()
                base_b = live.count("input_request")
                t3, res3 = live.run_in_thread(
                    lambda: bridge.run_script(main_py, [], proj)
                )
                saw = live.wait_for_count(
                    "input_request", base_b + 1, 5.0)
                if saw:
                    live.input_q.offer("Riad")
                t3.join(timeout=10)
                live.wait_for_new("run_finished", mark, 5.0)
                out3 = live.text(mark)
                check("REGRESSION: run after a stop is NOT poisoned "
                      "by the stale STOP_SENTINEL",
                      saw and not t3.is_alive()
                      and res3.get("code") == 0
                      and "Nice to meet you, Riad!" in out3
                      and "KeyboardInterrupt" not in out3,
                      f"code={res3.get('code')} saw={saw}")

                # (c) Stop WHILE waiting at input() still works.
                mark4 = live.mark()
                base4 = live.count("input_request")
                t4, res4 = live.run_in_thread(
                    lambda: bridge.run_script(main_py, [], proj)
                )
                saw = live.wait_for_count(
                    "input_request", base4 + 1, 5.0)
                if saw:
                    bridge.request_stop()
                t4.join(timeout=10)
                live.wait_for_new("run_finished", mark4, 5.0)
                out4 = live.text(mark4)
                check("stop while waiting at input() exits 130",
                      saw and not t4.is_alive()
                      and res4.get("code") == 130
                      and "KeyboardInterrupt" in out4,
                      f"code={res4.get('code')} saw={saw}")

                # (d) A plain run after a stopped run works.
                trivial = os.path.join(proj, "trivial.py")
                with open(trivial, "w", encoding="utf-8") as f:
                    f.write("print('trivial ok')\n")
                t5, res5 = live.run_in_thread(
                    lambda: bridge.run_script(trivial, [], proj)
                )
                t5.join(timeout=10)
                check("run after a stop works (no input involved)",
                      not t5.is_alive() and res5.get("code") == 0,
                      f"code={res5.get('code')}")

                # (e) Multiple input() calls, empty input, and EOF.
                multi = os.path.join(proj, "multi.py")
                with open(multi, "w", encoding="utf-8") as f:
                    f.write(
                        "a = input('first? ')\n"
                        "b = input('second? ')\n"
                        "print(f'got:{a}|{b}')\n"
                        "try:\n"
                        "    c = input('third? ')\n"
                        "except EOFError:\n"
                        "    print('EOF handled')\n"
                    )
                mark6 = live.mark()
                base6 = live.count("input_request")
                t6, res6 = live.run_in_thread(
                    lambda: bridge.run_script(multi, [], proj)
                )
                ok6 = live.wait_for_count(
                    "input_request", base6 + 1, 5.0)
                if ok6:
                    live.input_q.offer("one")
                ok6 = ok6 and live.wait_for_count(
                    "input_request", base6 + 2, 5.0)
                if ok6:
                    live.input_q.offer("two")
                ok6 = ok6 and live.wait_for_count(
                    "input_request", base6 + 3, 5.0)
                if ok6:
                    live.input_q.offer(bridge.EOF_SENTINEL)
                t6.join(timeout=10)
                live.wait_for_new("run_finished", mark6, 5.0)
                out6 = live.text(mark6)
                check("multiple input() + EOF handled cleanly",
                      ok6 and not t6.is_alive()
                      and res6.get("code") == 0
                      and "got:one|two" in out6
                      and "EOF handled" in out6,
                      f"code={res6.get('code')} ok={ok6}")

                empty_py = os.path.join(proj, "empty.py")
                with open(empty_py, "w", encoding="utf-8") as f:
                    f.write("s = input('say? ')\n"
                            "print(f'empty:<{s}>')\n")
                mark7 = live.mark()
                base7 = live.count("input_request")
                t7, res7 = live.run_in_thread(
                    lambda: bridge.run_script(empty_py, [], proj)
                )
                saw = live.wait_for_count(
                    "input_request", base7 + 1, 5.0)
                if saw:
                    live.input_q.offer("")
                t7.join(timeout=10)
                live.wait_for_new("run_finished", mark7, 5.0)
                out7 = live.text(mark7)
                check("empty input line returns '' (no crash)",
                      saw and not t7.is_alive()
                      and res7.get("code") == 0
                      and "empty:<>" in out7,
                      f"code={res7.get('code')} saw={saw}")
        finally:
            live.close()
            bridge._input_queue = input_q
            bridge._output_queue = output_q

        # (f) File/dir names with spaces and Bengali characters, and
        # UTF-8 (Bengali) output.
        with tempfile.TemporaryDirectory(
            prefix="pyrunner_harness_names_"
        ) as base:
            beng = os.path.join(base, "আমার প্রজেক্ট")
            os.makedirs(beng)
            spaced = os.path.join(beng, "my script.py")
            with open(spaced, "w", encoding="utf-8") as f:
                f.write("print('নমস্কার')\n")
            before = len(output_q.puts)
            bridge._input_queue = MockQueue(items=[])
            code = bridge.run_script(spaced, FakeJavaList([]), beng)
            out = "\n".join(p for p in output_q.puts[before:]
                            if p.startswith("OUT|"))
            check("Bengali dir + spaced filename run, UTF-8 output",
                  code == 0 and "নমস্কার" in out, f"code={code}")
            bridge._input_queue = input_q

        # (g) Deep nesting + relative / __file__ / absolute writes,
        # for run_script and run_module.
        with tempfile.TemporaryDirectory(
            prefix="pyrunner_harness_deep_"
        ) as proj:
            deep = os.path.join(proj, "a", "b", "c", "d")
            os.makedirs(deep)
            script = os.path.join(deep, "writer.py")
            with open(script, "w", encoding="utf-8") as f:
                f.write(
                    "import os\n"
                    "open('rel.txt', 'w').write('rel')\n"
                    "here = os.path.dirname("
                    "os.path.abspath(__file__))\n"
                    "open(os.path.join(here, 'via_file.txt'), 'w')"
                    ".write('file')\n"
                    "open(os.path.join(os.getcwd(), 'abs.txt'), 'w')"
                    ".write('abs')\n"
                    "print('wrote all')\n"
                )
            bridge._input_queue = MockQueue(items=[])
            code = bridge.run_script(script, FakeJavaList([]), proj)
            check("deep nesting: relative/__file__/absolute writes",
                  code == 0
                  and os.path.exists(os.path.join(proj, "rel.txt"))
                  and os.path.exists(
                      os.path.join(deep, "via_file.txt"))
                  and os.path.exists(os.path.join(proj, "abs.txt")),
                  f"code={code}")
            pkg = os.path.join(proj, "mypkg")
            os.makedirs(pkg)
            open(os.path.join(pkg, "__init__.py"), "w").close()
            with open(os.path.join(pkg, "__main__.py"), "w") as f:
                f.write("open('mod_rel.txt', 'w').write('m')\n"
                        "print('module ran')\n")
            bridge._input_queue = MockQueue(items=[])
            code = bridge.run_module("mypkg", FakeJavaList([]), proj)
            check("run_module package __main__ + relative write",
                  code == 0 and os.path.exists(
                      os.path.join(proj, "mod_rel.txt")),
                  f"code={code}")
            bridge._input_queue = input_q

        # (h) Large output (5000 lines) completes.
        with tempfile.TemporaryDirectory(
            prefix="pyrunner_harness_bigout_"
        ) as proj:
            big = os.path.join(proj, "big.py")
            with open(big, "w", encoding="utf-8") as f:
                f.write("for i in range(5000):\n"
                        "    print(f'line {i}')\n")
            before = len(output_q.puts)
            bridge._input_queue = MockQueue(items=[])
            code = bridge.run_script(big, FakeJavaList([]), proj)
            new_out = [p for p in output_q.puts[before:]
                       if p.startswith("OUT|")]
            check("large output (5000 lines) completes",
                  code == 0 and len(new_out) >= 5000,
                  f"code={code} lines={len(new_out)}")
            bridge._input_queue = input_q

        # (i) Requirements with pins, ranges, and markers: only an
        # UNBOUNDED pycryptodome spec is rewritten to the Android-wheel
        # version; pins, ranges with upper bounds, and markers stay.
        check("pycryptodome pin is left alone",
              bridge._rewrite_pycryptodome_spec(
                  "pycryptodome==3.21.0") is None)
        check("pycryptodome>= is rewritten to ==3.21.0",
              bridge._rewrite_pycryptodome_spec(
                  "pycryptodome>=3.20.0") == "pycryptodome==3.21.0")
        check("pycryptodome>= with marker keeps the marker",
              bridge._rewrite_pycryptodome_spec(
                  "pycryptodome>=3.20.0; python_version>='3.9'")
              == "pycryptodome==3.21.0; python_version>='3.9'")
        check("pycryptodome range with upper bound is left alone",
              bridge._rewrite_pycryptodome_spec(
                  "pycryptodome>=3.20.0,<4.0") is None)
        check("other packages are left alone",
              bridge._rewrite_pycryptodome_spec("requests>=2.0") is None
              and bridge._rewrite_pycryptodome_spec("six==1.17.0")
              is None)
        with tempfile.TemporaryDirectory(
            prefix="pyrunner_harness_reqs_"
        ) as d:
            req = os.path.join(d, "requirements.txt")
            with open(req, "w", encoding="utf-8") as f:
                f.write("pycryptodome>=3.20.0\nrequests>=2.31.0\n"
                        "six==1.17.0\n")
            tmp, changed = bridge._rewrite_requirements_file(req)
            check("requirements file: only pycryptodome is rewritten",
                  tmp is not None and len(changed) == 1
                  and changed[0][0] == "pycryptodome>=3.20.0"
                  and changed[0][1] == "pycryptodome==3.21.0",
                  repr(changed))
            if tmp:
                with open(tmp, encoding="utf-8") as f:
                    content = f.read()
                check("rewritten requirements file keeps other lines",
                      "requests>=2.31.0" in content
                      and "six==1.17.0" in content
                      and "pycryptodome==3.21.0" in content)
                os.remove(tmp)
    finally:
        sys.stdout, sys.stderr, sys.stdin = old_stdout, old_stderr, old_stdin
        sys.path = old_path
        if old_home is None:
            os.environ.pop("HOME", None)
        else:
            os.environ["HOME"] = old_home

    print()
    for note in notes:
        print(f"note: {note}")
    failed = [name for name, ok in checks if not ok]
    print(f"\n{len(checks) - len(failed)}/{len(checks)} checks passed")
    if failed:
        print("FAILED: " + ", ".join(failed))
        return 1
    print("Bridge harness: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
