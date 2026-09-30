"""PL package: loading through dfx-mgr, and the fabric design's registers and sensor.

Follows edf-2026_1-followups.md, section 3. The PL clock runs only while the overlay
is loaded and a PL register read without it would probably hang the board, so every
test leaves the overlay loaded. Load/unload cycles leak a little kernel memory per
cycle (section 5), hence the small count.

make hil-stage installs one PL package as dfx-mgr's default firmware
(/lib/firmware/xilinx/$HIL_PL_PKG/), which dfx-mgr-fw-load.service loads at boot.
Every load and unload here goes through dfx-mgr-client: once dfx-mgr has loaded the
PL, applying an overlay directly through configfs oopsed the kernel (dfx-mgr spike,
30 September 2026).
"""
import time

OVERLAYS = "/sys/kernel/config/device-tree/overlays"
IIC_DEV = "/sys/bus/platform/devices/b0000000.i2c"
IIC_BASE = 0xB000_0000
IIC_SR = 0x104                 # AXI IIC status register; idle value 0xC0
SENSOR = 0x3F                  # STTS22H, ADDR pin tied to ground
CYCLES = 3


def overlays(board):
    """{name: (status, path)} for every applied configfs overlay."""
    out = board.run(f"for d in {OVERLAYS}/*/; do [ -d \"$d\" ] || continue; "
                    "echo \"$(basename $d) $(cat $d/status) $(cat $d/path)\"; done", check=False).stdout
    found = {}
    for line in out.splitlines():
        name, status, path = (line.split(" ", 2) + ["", ""])[:3]
        found[name] = (status, path)
    return found


def dfx(board, *args):
    r = board.sudo("dfx-mgr-client " + " ".join(args), timeout=90, check=False)
    assert r.returncode == 0, f"dfx-mgr-client {' '.join(args)} exited {r.returncode}: {r.stdout}{r.stderr}"
    return r.stdout


def load(board, pkg):
    dfx(board, "-loadByName", pkg)


def unload(board, pkg):
    dfx(board, "-unloadByName", pkg)


def is_loaded(board, pkg, stem):
    return overlays(board) == {f"{pkg}_image_1": ("applied", f"{stem}.dtbo")}


def ensure_loaded(board, pkg, stem):
    if not is_loaded(board, pkg, stem):
        load(board, pkg)


def i2c_bus(board):
    out = board.run(f"cd {IIC_DEV} && ls -d i2c-*", check=False).stdout.split()
    assert len(out) == 1, f"no single I2C adapter under {IIC_DEV}: {out}"
    return int(out[0].split("-")[1])


def check_loaded(board, pkg, stem):
    ovl = overlays(board)
    assert ovl == {f"{pkg}_image_1": ("applied", f"{stem}.dtbo")}, f"overlays: {ovl}"
    assert board.run("cat /sys/class/fpga_manager/fpga0/state").stdout.strip() == "operating"
    driver = board.run(f"basename $(readlink {IIC_DEV}/driver)", check=False).stdout.strip()
    assert driver == "xiic-i2c", f"{IIC_DEV} driver: {driver or 'none'}"
    i2c_bus(board)


def check_unloaded(board):
    # The PL stays programmed after removal, so fpga0 still reads "operating":
    # check that the overlay and its devices are gone instead.
    assert overlays(board) == {}, f"overlays left: {overlays(board)}"
    assert board.run(f"test -e {IIC_DEV}", check=False).returncode != 0, f"{IIC_DEV} still present"


def test_pl_load(board, hil_env):
    pkg, stem = hil_env["HIL_PL_PKG"], hil_env["HIL_PL_STEM"]
    staged = board.run(f"cat /etc/dfx-mgrd/default_firmware; ls /lib/firmware/xilinx/{pkg}").stdout.split()
    assert staged[0] == pkg and {f"{stem}.bit.bin", f"{stem}.dtbo", "shell.json"} <= set(staged[1:]), \
        f"staged dfx-mgr package: {staged}"
    log = board.sudo("journalctl -b -u dfx-mgr-fw-load.service --no-pager").stdout
    assert f"Loaded default firmware: {pkg}" in log, "dfx-mgr-fw-load.service did not load the PL at boot"
    check_loaded(board, pkg, stem)
    try:
        for _ in range(CYCLES):
            unload(board, pkg)
            check_unloaded(board)
            load(board, pkg)
            check_loaded(board, pkg, stem)
    finally:
        ensure_loaded(board, pkg, stem)


def read_temperature(board, bus):
    """One-shot STTS22H conversion (followups section 3): reset, one-shot, wait for
    BUSY to clear, read the signed 16-bit result in 0.01 C steps."""
    for reg, value in ((0x0C, 0x02), (0x0C, 0x00), (0x04, 0x01)):
        board.i2c_set(bus, SENSOR, reg, value)
    deadline = time.monotonic() + 2
    while board.i2c_get(bus, SENSOR, 0x05) & 0x01:
        assert time.monotonic() < deadline, "STTS22H stayed busy"
        time.sleep(0.05)
    raw = board.i2c_get(bus, SENSOR, 0x07) << 8 | board.i2c_get(bus, SENSOR, 0x06)
    return (raw - 0x10000 if raw & 0x8000 else raw) / 100


def test_pl_regs(board, hil_env, record_property):
    ensure_loaded(board, hil_env["HIL_PL_PKG"], hil_env["HIL_PL_STEM"])
    enabled = int(board.sudo("cat /sys/kernel/debug/clk/pl0_ref/clk_enable_count").stdout)
    assert enabled >= 1, "pl0_ref is off: reading PL registers now could hang the board"

    assert board.read32(IIC_BASE + IIC_SR) == 0xC0
    bus = i2c_bus(board)
    assert board.i2c_get(bus, SENSOR, 0x01) == 0xA0, "STTS22H WHOAMI"
    t = read_temperature(board, bus)
    record_property("board_temperature_c", t)
    assert 5.0 < t < 80.0, f"implausible board temperature {t} C"
