"""Package-level rules for difi_ref."""
import subprocess
import sys
from pathlib import Path

PKG_DIR = Path(__file__).resolve().parents[1]


def test_core_imports_only_stdlib():
    # A fresh, isolated interpreter, so modules pytest or the oracle loaded do not hide an
    # import, and only what importing difi_ref adds counts (not the distribution's startup
    # hooks). -I leaves the package directory off sys.path, so the probe adds it.
    # Every module, not just the package: its __init__ imports nothing.
    probe = (f"import importlib, pkgutil, sys; sys.path.insert(0, {str(PKG_DIR)!r}); "
             "before = set(sys.modules); import difi_ref; "
             "[importlib.import_module('difi_ref.' + m.name) for m in pkgutil.iter_modules(difi_ref.__path__)]; "
             "bad = sorted({m.split('.')[0] for m in set(sys.modules) - before} "
             "- set(sys.stdlib_module_names) - {'difi_ref'}); "
             "print(' '.join(bad))")
    out = subprocess.run([sys.executable, "-I", "-c", probe],
                         capture_output=True, text=True, check=True).stdout.split()
    assert out == [], f"difi_ref imports non-stdlib modules: {out}"
