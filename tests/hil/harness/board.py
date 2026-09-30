"""Commands on the board over SSH, with the test login stage-netboot.sh seeds.

One SSH master connection per run (ControlMaster), so each command costs a round
trip instead of a new handshake. BatchMode makes a missing key fail at once instead
of stopping at a password prompt.
"""
import shlex
import subprocess
import time


class BoardError(Exception):
    """A command on the board failed or timed out, or SSH never came up."""


class Board:
    def __init__(self, env, console, control_dir):
        self.env = env
        self.console = console
        self.booted_id = None
        self.login_pos = 0   # console position of the login prompt
        self._ssh = [
            "ssh", "-i", env["HIL_SSH_KEY"],
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=5",
            "-o", "ControlMaster=auto", "-o", f"ControlPath={control_dir}/%C",
            "-o", "ControlPersist=120",
            f"{env['HIL_SSH_USER']}@{env['HIL_BOARD_IP']}",
        ]

    def run(self, cmd, timeout=30, check=True):
        """Run a shell command as the test user; returns CompletedProcess (text)."""
        try:
            r = subprocess.run(self._ssh + [cmd], capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            raise BoardError(f"timeout after {timeout} s: {cmd}") from None
        if check and r.returncode:
            raise BoardError(f"{cmd!r} exited {r.returncode}: {(r.stderr or r.stdout).strip()}")
        return r

    def sudo(self, cmd, timeout=30, check=True):
        """Run a shell command as root (password-free sudo from the staged rootfs)."""
        return self.run("sudo -n sh -c " + shlex.quote(cmd), timeout=timeout, check=check)

    def wait_ssh(self, timeout):
        deadline = time.monotonic() + timeout
        while True:
            try:
                r = self.run("true", timeout=10, check=False)
                if r.returncode == 0:
                    return
                last = r.stderr.strip() or f"exit {r.returncode}"
            except BoardError as e:
                last = str(e)
            if time.monotonic() > deadline:
                raise BoardError(f"no SSH login within {timeout:g} s: {last}")
            time.sleep(2)

    def read32(self, addr):
        """One aligned 32-bit read from a physical address (/dev/mem). The memoryview
        cast makes it a single 32-bit load, as AXI-Lite slaves expect."""
        page, off = addr & ~0xFFF, addr & 0xFFF
        code = ("import mmap,os;"
                "f=os.open('/dev/mem',os.O_RDONLY|os.O_SYNC);"
                f"m=mmap.mmap(f,4096,mmap.MAP_SHARED,mmap.PROT_READ,offset={page});"
                f"print(memoryview(m).cast('I')[{off // 4}])")
        return int(self.sudo("python3 -c " + shlex.quote(code)).stdout)

    def i2c_get(self, bus, addr, reg):
        return int(self.sudo(f"i2cget -y {bus} {addr:#x} {reg:#x} b").stdout, 16)

    def i2c_set(self, bus, addr, reg, value):
        self.sudo(f"i2cset -y {bus} {addr:#x} {reg:#x} {value:#x} b")

    def close(self):
        subprocess.run(self._ssh[:-1] + ["-O", "exit", self._ssh[-1]], capture_output=True)
