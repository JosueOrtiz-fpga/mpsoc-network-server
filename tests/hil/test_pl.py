"""PL package: overlay load and unload, and the fabric design's registers and sensor.

Follows edf-2026_1-followups.md, section 3. The PL clock runs only while the overlay
is loaded and a PL register read without it would probably hang the board, so every
test leaves the overlay loaded. Load/unload cycles leak a little kernel memory per
cycle (section 5), hence the small count.

Until pl-loader.service is in the image (R0 work package 5), the test loads the
overlay itself; once the unit exists, it must have applied the overlay at boot.
"""
import time

import pytest

OVERLAY = "/sys/kernel/config/device-tree/overlays/pl"
IIC_DEV = "/sys/bus/platform/devices/b0000000.i2c"
IIC_BASE = 0xB000_0000
IIC_SR = 0x104                 # AXI IIC status register; idle value 0xC0
SENSOR = 0x3F                  # STTS22H, ADDR pin tied to ground
CYCLES = 3


def overlay_status(board):
    return board.run(f"cat {OVERLAY}/status 2>/dev/null || true").stdout.strip()


def default_dtbo(board):
    out = board.run("cd /lib/firmware && if [ -e pl-default.dtbo ]; then echo pl-default.dtbo; "
                    "else ls *.dtbo 2>/dev/null; fi", check=False).stdout.split()
    if len(out) != 1:
        pytest.fail(f"expected one PL overlay in /lib/firmware, found {out or 'none'}", pytrace=False)
    return out[0]


def load(board):
    board.sudo(f"mkdir {OVERLAY} && printf %s {default_dtbo(board)} > {OVERLAY}/path")


def unload(board):
    board.sudo(f"[ ! -d {OVERLAY} ] || rmdir {OVERLAY}")


def ensure_loaded(board):
    if overlay_status(board) != "applied":
        unload(board)
        load(board)


def has_loader(board):
    return board.run("systemctl cat pl-loader.service", check=False).returncode == 0


def i2c_bus(board):
    out = board.run(f"cd {IIC_DEV} && ls -d i2c-*", check=False).stdout.split()
    assert len(out) == 1, f"no single I2C adapter under {IIC_DEV}: {out}"
    return int(out[0].split("-")[1])


def check_loaded(board):
    assert overlay_status(board) == "applied"
    assert board.run("cat /sys/class/fpga_manager/fpga0/state").stdout.strip() == "operating"
    driver = board.run(f"basename $(readlink {IIC_DEV}/driver)", check=False).stdout.strip()
    assert driver == "xiic-i2c", f"{IIC_DEV} driver: {driver or 'none'}"
    i2c_bus(board)


def check_unloaded(board):
    # The PL stays programmed after removal, so fpga0 still reads "operating":
    # check that the overlay's devices are gone instead.
    assert board.run(f"test -e {IIC_DEV}", check=False).returncode != 0, f"{IIC_DEV} still present"


def test_pl_load(board):
    if has_loader(board):
        assert overlay_status(board) == "applied", "pl-loader.service did not apply the PL overlay at boot"
    else:
        ensure_loaded(board)
    check_loaded(board)
    try:
        for _ in range(CYCLES):
            unload(board)
            check_unloaded(board)
            load(board)
            check_loaded(board)
    finally:
        ensure_loaded(board)


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


def test_pl_regs(board, record_property):
    ensure_loaded(board)
    enabled = int(board.sudo("cat /sys/kernel/debug/clk/pl0_ref/clk_enable_count").stdout)
    assert enabled >= 1, "pl0_ref is off: reading PL registers now could hang the board"

    assert board.read32(IIC_BASE + IIC_SR) == 0xC0
    bus = i2c_bus(board)
    assert board.i2c_get(bus, SENSOR, 0x01) == 0xA0, "STTS22H WHOAMI"
    t = read_temperature(board, bus)
    record_property("board_temperature_c", t)
    assert 5.0 < t < 80.0, f"implausible board temperature {t} C"
