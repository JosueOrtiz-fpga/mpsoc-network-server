"""Sample sources: complex int16 samples at the output rate, by global sample index.

A source returns interleaved I, Q as array('h') for samples [start, start + count).
Taking the phase from the global index keeps the signal continuous across packets
and, later, across dropped packets.
"""
import math
from array import array


class IdealTone:
    """A complex tone, I = A cos(2 pi f n / fs) and Q = A sin(...), rounded to int16.

    f is the offset from the band center in whole hertz; positive is above it. The
    phase is computed from (f * n) mod fs in integers, so it never drifts. This stands
    in for R4's two-tone source and DDC.
    """

    def __init__(self, freq_hz: int, sample_rate_hz: int, amplitude: float = 0.5):
        if not isinstance(freq_hz, int):
            raise TypeError(f"tone frequency must be integer hertz, got {freq_hz!r}")
        if not 2 * abs(freq_hz) < sample_rate_hz:
            raise ValueError(f"tone at {freq_hz} Hz is outside +/- {sample_rate_hz / 2} Hz")
        if not 0 < amplitude <= 1:
            raise ValueError(f"amplitude {amplitude} is outside (0, 1] of full scale")
        self.freq_hz = freq_hz
        self.sample_rate_hz = sample_rate_hz
        self.amplitude = amplitude

    def samples(self, start: int, count: int) -> array:
        scale = self.amplitude * 32767
        step = 2 * math.pi / self.sample_rate_hz
        out = array("h", bytes(4 * count))
        for k in range(count):
            angle = step * ((self.freq_hz * (start + k)) % self.sample_rate_hz)
            out[2 * k] = round(scale * math.cos(angle))
            out[2 * k + 1] = round(scale * math.sin(angle))
        return out
