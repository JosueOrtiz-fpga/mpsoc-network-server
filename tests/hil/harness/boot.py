"""Boot the staged build over JTAG and follow it on the console to the login prompt.

Same path as `make jtag-boot` by hand, plus the step U-Boot never does by itself on
this board: its autoboot falls through the EFI boot manager (mmc 0) to the ZynqMP>
prompt, where the netboot script has to be started with `source`. The console is
open before the JTAG boot starts, so console.log covers the whole boot.
"""
import os
import shutil
import subprocess

from .console import ConsoleError
from .env import REPO, SCRIPTS

# Lines that mean the kernel is in trouble. Fatal while booting; after the boot, the
# suite fails on any of these or on a kernel warning.
FATAL = [r"Kernel panic", r"Unable to handle kernel", r"Internal error: Oops",
         r"BUG: ", r"Call trace:", r"VFS: Unable to mount root"]
KERNEL_WARN = [r"WARNING: CPU: \d+ PID: \d+"]

# U-Boot reports a failed netboot with these before it would ever print "Starting kernel".
NETBOOT_FAIL = [r"ARP Retry count exceeded", r"Retry count exceeded", r"TFTP error",
                r"netboot: booti returned", r"Wrong Image"]


class BootError(Exception):
    """The board did not reach a login prompt running the staged build."""


def boot(con, env, run_dir):
    """JTAG-boot the build staged in out/hil and wait for its login prompt.
    Returns the build id the board announced."""
    xsdb = os.environ.get("XSDB", "xsdb")
    if not shutil.which(xsdb):
        raise BootError(f"{xsdb} not found: source <Vivado install>/settings64.sh first")
    jtag_dir = REPO / "out" / "sw" / "jtag"
    scr = REPO / "out" / "hil" / "boot.scr"
    for p in (jtag_dir, scr):
        if not p.exists():
            raise BootError(f"missing {p}: run 'make hil-stage'")

    t = lambda key: float(env[key])  # noqa: E731
    try:
        # Stop autoboot at its first countdown. This saves the EFI detour and keeps a
        # bootable SD card in the slot from starting some other image.
        con.respond(r"Hit any key to stop autoboot", " ")

        log = run_dir / "jtag-boot.log"
        with open(log, "wb") as out:
            try:
                p = subprocess.run([xsdb, str(SCRIPTS / "jtag-boot.tcl"), str(jtag_dir), str(scr)],
                                   cwd=REPO, stdout=out, stderr=subprocess.STDOUT,
                                   timeout=t("HIL_T_JTAG"))
            except subprocess.TimeoutExpired:
                raise BootError(f"jtag-boot did not finish within {env['HIL_T_JTAG']} s, see {log}") from None
        if p.returncode:
            raise BootError(f"jtag-boot failed (exit {p.returncode}), see {log}")

        con.expect(r"ZynqMP> ", t("HIL_T_UBOOT"))
        con.send(f"source {os.environ.get('SCRIPT_ADDR', '0x20000000')}\r")
        m = con.expect(r"netboot: build (\S+) from", 15)
        if m.group(1) != env["HIL_ID"]:
            raise BootError(f"the board started build {m.group(1)}, but {env['HIL_ID']} is staged")
        con.expect(r"Starting kernel \.\.\.", t("HIL_T_KERNEL"), fail=NETBOOT_FAIL)
        con.expect(r"login: ", t("HIL_T_LOGIN"), fail=FATAL)
        return m.group(1)
    except ConsoleError as e:
        raise BootError(str(e)) from None
