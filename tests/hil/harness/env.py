"""Bench settings for the HIL suite, read from the same files the shell scripts use.

tests/hil/scripts/hil.env (defaults, overridable from the environment) and
out/hil/stage.env (HIL_ID and HIL_DIR of the last `make hil-stage`) are sourced by
bash, so Python and the scripts always agree.
"""
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
SCRIPTS = REPO / "tests" / "hil" / "scripts"
STAGE_ENV = REPO / "out" / "hil" / "stage.env"

_DUMP = ('. "$1"; [ ! -f "$2" ] || . "$2"; '
         'for v in $(compgen -v HIL_); do printf "%s=%s\\0" "$v" "${!v}"; done')


def load_env():
    """All HIL_* settings as a dict."""
    out = subprocess.run(["bash", "-c", _DUMP, "load-env", str(SCRIPTS / "hil.env"), str(STAGE_ENV)],
                         check=True, capture_output=True).stdout.decode()
    return dict(item.split("=", 1) for item in out.split("\0") if "=" in item)
