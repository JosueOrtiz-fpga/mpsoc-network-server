import sys
from pathlib import Path

import pytest

# pytest 6 has no pythonpath setting: make difi_ref importable from the package directory.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from difi_ref.config import StreamConfig  # noqa: E402
from difi_ref.packetizer import Packetizer  # noqa: E402
from difi_ref.sources import IdealTone  # noqa: E402
from difi_ref.timebase import IdealTimebase  # noqa: E402

SEED = 1_790_000_000        # 2026-09-21, a fixed POSIX second for reproducible streams
TONE_HZ = 12_000
NUM_DATA = 1100             # crosses two periodic context packets (533, 1066) and a seconds rollover


def pytest_addoption(parser):
    parser.addoption("--rx", action="store_true",
                     help="run only the receiver pre-check (marker rx; needs GNU Radio and gr-difi)")


def pytest_collection_modifyitems(config, items):
    # rx tests run only with --rx (make ref-rx-check), whatever -m PYTEST_ARGS passes.
    rx = config.getoption("--rx")
    keep = [i for i in items if bool(i.get_closest_marker("rx")) == rx]
    if len(keep) != len(items):
        config.hook.pytest_deselected(items=[i for i in items if i not in keep])
        items[:] = keep


def assert_same(got, expected):
    """Compare long sequences, reporting only the first difference.

    A plain assert on two long lists makes pytest diff them with difflib, which takes
    minutes and then fails with RecursionError.
    """
    got, expected = list(got), list(expected)
    for i, (g, e) in enumerate(zip(got, expected)):
        if g != e:
            raise AssertionError(f"first difference at index {i}: {g!r} != {e!r}")
    if len(got) != len(expected):
        raise AssertionError(f"lengths differ: {len(got)} != {len(expected)}")


def make_packetizer(cfg=None, tone_hz=TONE_HZ, seed=SEED):
    cfg = cfg or StreamConfig(ctx_ts_cal_time=seed)
    source = IdealTone(tone_hz, cfg.ctx_sample_rate_hz)
    return Packetizer(cfg, source, IdealTimebase(seed, cfg.fs_in_hz, cfg.ddc_decim))


@pytest.fixture(scope="session")
def example():
    """The example run's packetizer settings and NUM_DATA data packets of its stream."""
    pkt = make_packetizer()
    return pkt.cfg, pkt.source, list(pkt.packets(NUM_DATA))
