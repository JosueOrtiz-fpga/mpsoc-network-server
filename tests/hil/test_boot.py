"""The staged build boots to a login prompt and a usable system."""

from harness.boot import FATAL, KERNEL_WARN

# Units allowed to fail, by description, with the reason.
ALLOWED_FAILED_UNITS = {
    "Grow Root File System": "nothing to grow on the NFS root of the HIL bench",
}


def test_booted_staged_build(board, hil_env):
    assert board.booted_id == hil_env["HIL_ID"]
    assert board.run("uname -r").stdout.strip()


def test_console_clean_until_login(board):
    hits = board.console.find_all(FATAL + KERNEL_WARN, end=board.login_pos)
    assert not hits, "kernel trouble during boot:\n" + "\n".join(hits)


def test_no_unexpected_failed_units(board):
    out = board.run("systemctl --failed --plain --no-legend --no-pager").stdout
    failed = {}
    for line in out.splitlines():
        parts = line.split(None, 4)          # UNIT LOAD ACTIVE SUB DESCRIPTION
        if len(parts) == 5:
            failed[parts[0]] = parts[4].strip()
    unexpected = {u: d for u, d in failed.items() if d not in ALLOWED_FAILED_UNITS}
    assert not unexpected, f"failed units: {unexpected}"
