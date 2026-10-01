"""Ideal timebase: exact packet starts, seconds rollover, 32-bit seconds."""
import pytest

from difi_ref.fields import PS_PER_S
from difi_ref.timebase import IdealTimebase

FS_IN = 122_880_000
MAIN_DECIMATIONS = (64, 128, 320, 640, 1280, 2560)
SPP = 360


@pytest.mark.parametrize("decim", MAIN_DECIMATIONS)
def test_packet_period_is_whole_picoseconds(decim):
    period_num = SPP * decim * PS_PER_S
    assert period_num % FS_IN == 0
    tb = IdealTimebase(0, FS_IN, decim)
    for k in (1, 2, 1000, 123_457):
        sec, ps = tb.timestamp(k * SPP)
        assert sec * PS_PER_S + ps == k * period_num // FS_IN


def test_example_rate_step():
    tb = IdealTimebase(1000, FS_IN, 640)
    assert tb.timestamp(0) == (1000, 0)
    assert tb.timestamp(SPP) == (1000, 1_875_000_000)


def test_seconds_rollover():
    tb = IdealTimebase(1000, FS_IN, 640)
    assert tb.timestamp(533 * SPP) == (1000, 999_375_000_000)
    assert tb.timestamp(534 * SPP) == (1001, 1_250_000_000)
    assert tb.timestamp(192_000) == (1001, 0)       # exactly one second of samples


def test_between_packet_starts_rounds_down():
    # One sample at 192 kS/s is 5,208,333.33... ps.
    assert IdealTimebase(0, FS_IN, 640).timestamp(1) == (0, 5_208_333)


def test_32_bit_seconds():
    tb = IdealTimebase(0xFFFFFFFF, FS_IN, 640)
    assert tb.timestamp(SPP) == (0xFFFFFFFF, 1_875_000_000)
    with pytest.raises(ValueError):
        tb.timestamp(192_000)
    with pytest.raises(ValueError):
        IdealTimebase(1 << 32, FS_IN, 640)


def test_negative_index():
    with pytest.raises(ValueError):
        IdealTimebase(0, FS_IN, 640).timestamp(-1)
