"""Regression test for the Chaquopy ArrayList crash (v1.0.1).

Bug: MainActivity.kt passed Kotlin List<String> args to Chaquopy, which
arrives in Python as a java.util.ArrayList. The bridge did
``[str(a) for a in args]`` on it, and Chaquopy Java Lists are NOT
iterable from Python:

    TypeError: 'ArrayList' object is not iterable
    (pyrunner_bridge.py, run_script — seen on the user's phone)

Fix: pyrunner_bridge._to_py_list() converts via size()/get(i) (Java List)
or len()/indexing (Java array). MainActivity now also passes
args.toTypedArray().

This test runs WITHOUT a device: it loads the real bridge module and
drives it with fake Java-like objects (size()/get(), no __iter__).

Run:  python3 test/bridge_test.py
Exit code 0 = all checks pass.
"""

import importlib.util
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE_PATH = os.path.join(
    HERE, "..", "android", "app", "src", "main", "python",
    "pyrunner_bridge.py",
)

_REAL_STDOUT = sys.stdout
_REAL_STDERR = sys.stderr
_REAL_STDIN = sys.stdin

_failures = []


def check(name, cond, detail=""):
    if cond:
        print(f"  PASS  {name}", file=_REAL_STDOUT)
    else:
        print(f"  FAIL  {name}  {detail}", file=_REAL_STDOUT)
        _failures.append(name)


class FakeJavaList:
    """Mimics a Chaquopy java.util.ArrayList: size()/get(), NOT iterable."""

    def __init__(self, items):
        self._items = list(items)

    def size(self):
        return len(self._items)

    def get(self, i):
        return self._items[i]

    def __iter__(self):
        raise TypeError("'ArrayList' object is not iterable")


class FakeJavaArray:
    """Mimics a Chaquopy Java String[]: len() + indexing, no size()."""

    def __init__(self, items):
        self._items = list(items)

    def __len__(self):
        return len(self._items)

    def __getitem__(self, i):
        return self._items[i]


class FakeQueue:
    """Mimics java.util.concurrent.LinkedBlockingQueue (subset)."""

    def __init__(self):
        self.items = []

    def put(self, item):
        self.items.append(item)

    def offer(self, item):
        self.items.append(item)
        return True

    def take(self):
        raise RuntimeError("take() should not be called by this test")


def load_bridge():
    spec = importlib.util.spec_from_file_location(
        "pyrunner_bridge", BRIDGE_PATH
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_to_py_list(bridge):
    print(" _to_py_list conversions:", file=_REAL_STDOUT)
    check("None -> []", bridge._to_py_list(None) == [])
    check(
        "Python list passthrough",
        bridge._to_py_list(["a", "b"]) == ["a", "b"],
    )
    check(
        "Java ArrayList (size/get, no __iter__)",
        bridge._to_py_list(FakeJavaList(["x", "-r", "req.txt"]))
        == ["x", "-r", "req.txt"],
    )
    check(
        "empty Java ArrayList -> []",
        bridge._to_py_list(FakeJavaList([])) == [],
    )
    check(
        "Java array (len/index)",
        bridge._to_py_list(FakeJavaArray(["p", "q"])) == ["p", "q"],
    )
    check("tuple -> list", bridge._to_py_list(("a", 1)) == ["a", "1"])
    check("plain str -> [str]", bridge._to_py_list("single") == ["single"])
    # The exact old code must fail on a Java List (proves the test is real).
    try:
        [str(a) for a in FakeJavaList(["a"])]
        old_code_crashes = False
    except TypeError:
        old_code_crashes = True
    check("old list-comprehension code crashes on ArrayList", old_code_crashes)


def test_run_script_e2e(bridge):
    print(" run_script end-to-end (FakeJavaList args):", file=_REAL_STDOUT)
    with tempfile.TemporaryDirectory() as tmp:
        script = os.path.join(tmp, "main.py")
        argv_file = script + ".argv"
        with open(script, "w") as f:
            f.write(
                "import sys\n"
                "with open(sys.argv[0] + '.argv', 'w') as fh:\n"
                "    fh.write(repr(sys.argv))\n"
                "print('hello from script')\n"
            )
        code = bridge.run_script(
            script, FakeJavaList(["hello", "42"]), tmp
        )
        check("run_script returns 0", code == 0, f"got {code}")
        with open(argv_file) as f:
            argv = eval(f.read())
        check(
            "sys.argv inside script == [path, 'hello', '42']",
            argv == [script, "hello", "42"],
            f"got {argv!r}",
        )
        # The no-args case (Run button) crashed too: empty ArrayList.
        code = bridge.run_script(script, FakeJavaList([]), tmp)
        check("run_script with empty args returns 0", code == 0)
        with open(argv_file) as f:
            argv = eval(f.read())
        check("sys.argv with no args == [path]", argv == [script])


def test_run_module_e2e(bridge):
    print(" run_module end-to-end (FakeJavaList args):", file=_REAL_STDOUT)
    with tempfile.TemporaryDirectory() as tmp:
        mod = os.path.join(tmp, "mymod.py")
        argv_file = os.path.join(tmp, "mymod.argv")
        with open(mod, "w") as f:
            f.write(
                "import sys\n"
                "with open(%r, 'w') as fh:\n"
                "    fh.write(repr(sys.argv))\n" % argv_file
            )
        code = bridge.run_module("mymod", FakeJavaList(["a", "b"]), tmp)
        check("run_module returns 0", code == 0, f"got {code}")
        with open(argv_file) as f:
            argv = eval(f.read())
        # runpy.run_module(alter_sys=True) rewrites argv[0] to the module
        # file path — exactly like real `python -m` does. The args after
        # it are what matter: they must survive the Java List conversion.
        check(
            "sys.argv inside module == [mod path, 'a', 'b']",
            argv == [mod, "a", "b"],
            f"got {argv!r}",
        )


def test_pip_install_conversion(bridge):
    print(" pip_install arg conversion:", file=_REAL_STDOUT)
    captured = []
    orig = bridge._run_pip

    def fake_run_pip(argv):
        captured.append(list(argv))
        return 0

    bridge._run_pip = fake_run_pip
    try:
        code = bridge.pip_install(
            FakeJavaList(["-r", "requirements.txt"])
        )
        check("pip_install returns 0", code == 0)
        check(
            "_run_pip got ['install', '-r', 'requirements.txt']",
            captured == [["install", "-r", "requirements.txt"]],
            f"got {captured!r}",
        )
        code = bridge.pip_install(FakeJavaList(["requests"]))
        check(
            "_run_pip got ['install', 'requests']",
            captured[-1] == ["install", "requests"],
            f"got {captured[-1]!r}",
        )
    finally:
        bridge._run_pip = orig


def main():
    print("PyRunner bridge regression test", file=_REAL_STDOUT)
    bridge = load_bridge()
    test_to_py_list(bridge)

    # Wire fake queues so the bridge's stdout/stderr/input streams work.
    in_q = FakeQueue()
    out_q = FakeQueue()
    bridge.init(in_q, out_q)
    try:
        test_run_script_e2e(bridge)
        test_run_module_e2e(bridge)
        test_pip_install_conversion(bridge)
    finally:
        # Restore the real streams: init() replaced sys.stdout/stderr/stdin.
        sys.stdout = _REAL_STDOUT
        sys.stderr = _REAL_STDERR
        sys.stdin = _REAL_STDIN

    if _failures:
        print(f"\nFAILED: {len(_failures)} check(s): {_failures}",
              file=_REAL_STDOUT)
        return 1
    print("\nAll bridge checks passed.", file=_REAL_STDOUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
