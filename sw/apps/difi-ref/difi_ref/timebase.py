"""Timestamps: an ideal timebase, a stand-in for the Q32.32 timebase until iteration 5.

Integer arithmetic only: a POSIX time in picoseconds (about 1.8e21) is far beyond a
double's 53-bit mantissa.
"""
from .fields import PS_PER_S, check_timestamp


class IdealTimebase:
    """The exact time of output sample n, from a seed in whole POSIX seconds.

    Output sample n leaves the source n * DDC_DECIM input clocks after the seed. That
    is a whole number of picoseconds at every packet start for the main rates; between
    them the time is rounded down. The real timebase's rounding rule comes in
    iteration 5.
    """

    def __init__(self, seed_sec: int, fs_in_hz: int, ddc_decim: int):
        check_timestamp(seed_sec, 0)
        self.seed_sec = seed_sec
        self.fs_in_hz = fs_in_hz
        self.ddc_decim = ddc_decim

    def timestamp(self, n: int) -> tuple[int, int]:
        """(integer seconds, picoseconds) of output sample n."""
        if n < 0:
            raise ValueError(f"sample index {n} is negative")
        ps = n * self.ddc_decim * PS_PER_S // self.fs_in_hz
        sec, ps = divmod(self.seed_sec * PS_PER_S + ps, PS_PER_S)
        check_timestamp(sec, ps)
        return sec, ps
