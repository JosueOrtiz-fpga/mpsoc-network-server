"""Session fixtures for the HIL suite.

`board` boots the staged build once per run (JTAG, U-Boot netboot, login prompt,
SSH) and is shared by every test. Everything the run produces goes to the run
directory: console.log from before the boot, jtag-boot.log, commands.log (every
command run on the board, with its output) and the JUnit report that `make hil`
asks pytest for.
"""
import os
import shutil
import tempfile
import time
from pathlib import Path

import pytest

from harness.board import Board, BoardError
from harness.boot import FATAL, KERNEL_WARN, BootError, boot
from harness.console import Console, ConsoleError
from harness.env import REPO, load_env


@pytest.fixture(scope="session")
def hil_env():
    env = load_env()
    if "HIL_ID" not in env:
        pytest.exit("no staged build in out/hil: run 'make hil' (or 'make hil-stage')", returncode=2)
    return env


@pytest.fixture(scope="session")
def run_dir(hil_env):
    d = os.environ.get("HIL_RUN_DIR")
    d = Path(d) if d else (REPO / "out" / "hil" / hil_env["HIL_ID"]
                           / time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()))
    d.mkdir(parents=True, exist_ok=True)
    return d


@pytest.fixture(scope="session")
def board(hil_env, run_dir):
    try:
        con = Console(hil_env["HIL_CONSOLE"], run_dir / "console.log")
    except ConsoleError as e:
        pytest.fail(str(e), pytrace=False)
    control_dir = tempfile.mkdtemp(prefix="hil-ssh-")   # short path: socket names are limited
    b = Board(hil_env, con, control_dir, run_dir / "commands.log")
    try:
        b.booted_id = boot(con, hil_env, run_dir)
        b.login_pos = con.pos
        b.wait_ssh(float(hil_env["HIL_T_SSH"]))
    except (BootError, BoardError, ConsoleError) as e:
        tail = con.tail(40)
        b.close()
        con.close()
        shutil.rmtree(control_dir, ignore_errors=True)
        pytest.fail(f"{e}\n--- console tail ({run_dir / 'console.log'}) ---\n{tail}", pytrace=False)

    yield b

    b.close()
    hits = con.find_all(FATAL + KERNEL_WARN)
    con.close()
    shutil.rmtree(control_dir, ignore_errors=True)
    if hits:
        pytest.fail("kernel trouble on the console during the run:\n" + "\n".join(hits), pytrace=False)


@pytest.fixture(autouse=True)
def _commands_heading(request, board):
    """Group commands.log by test."""
    board.note(request.node.nodeid)
