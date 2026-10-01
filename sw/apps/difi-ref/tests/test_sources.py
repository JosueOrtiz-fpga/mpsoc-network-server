"""Sources. Ideal tone: int16 range, continuity across packets, frequency and purity.
Counter ramp: I = n mod 2**16 and Q = NOT I, continuous across packets."""
from array import array

import numpy as np
import pytest

from conftest import assert_same
from difi_ref.sources import CounterRamp, IdealTone

FS = 192_000
NFFT = 4096


def spectrum_db(source, start=0):
    iq = np.array(source.samples(start, NFFT), dtype=np.float64)
    x = iq[0::2] + 1j * iq[1::2]
    return 20 * np.log10(np.abs(np.fft.fft(x)) + 1e-12)


def test_amplitude_and_range():
    iq = IdealTone(12_000, FS, amplitude=0.5).samples(0, 1000)
    assert max(abs(v) for v in iq) == 16384             # 0.5 * 32767, rounded
    full = IdealTone(12_000, FS, amplitude=1.0).samples(0, 1000)
    assert max(abs(v) for v in full) == 32767


def test_continuous_across_packets():
    tone = IdealTone(12_345, FS)
    assert_same(tone.samples(0, 720), tone.samples(0, 360) + tone.samples(360, 360))
    big = 10**12                # hours into a stream: the integer phase must not drift
    assert_same(tone.samples(big, 720), tone.samples(big, 360) + tone.samples(big + 360, 360))


@pytest.mark.parametrize("freq_hz, peak_bin", [(12_000, 256), (-12_000, NFFT - 256)])
def test_peak_on_its_bin_and_clean(freq_hz, peak_bin):
    # 12 kHz at 192 kS/s is bin 256 of a 4096-point FFT; negative frequencies mirror.
    db = spectrum_db(IdealTone(freq_hz, FS), start=123_456)
    assert int(np.argmax(db)) == peak_bin
    rest = np.delete(db, peak_bin)
    assert db[peak_bin] - rest.max() > 80               # only int16 rounding left


def test_phase_from_global_index():
    # Sample n has phase 2 pi f n / fs, wherever the block starts.
    tone = IdealTone(48_000, FS, amplitude=1.0)         # a quarter turn per sample
    assert list(tone.samples(0, 4)) == [32767, 0, 0, 32767, -32767, 0, 0, -32767]
    assert list(tone.samples(5, 1)) == [0, 32767]


@pytest.mark.parametrize("kwargs", [
    dict(freq_hz=96_000, sample_rate_hz=FS),
    dict(freq_hz=12_000.5, sample_rate_hz=FS),
    dict(freq_hz=12_000, sample_rate_hz=FS, amplitude=0),
    dict(freq_hz=12_000, sample_rate_hz=FS, amplitude=1.5),
])
def test_rejects_bad_settings(kwargs):
    with pytest.raises((TypeError, ValueError)):
        IdealTone(**kwargs)


# ---- counter ramp ------------------------------------------------------------------------

def test_ramp_values():
    ramp = CounterRamp()
    assert list(ramp.samples(0, 3)) == [0, -1, 1, -2, 2, -3]
    assert list(ramp.samples(0x7FFF, 2)) == [32767, -32768, -32768, 32767]
    assert list(ramp.samples(0xFFFF, 2)) == [-1, 0, 0, -1]
    assert_same(ramp.samples(5 * 2**16 + 123, 360), ramp.samples(123, 360))


def test_ramp_as_unsigned_words():
    # The register map's definition, on the 16-bit words: I = n mod 2**16, Q = NOT I.
    start = 10**12 + 65_000
    words = array("H", CounterRamp().samples(start, 1000).tobytes())
    assert_same(words[0::2], [(start + k) % 2**16 for k in range(1000)])
    assert_same(words[1::2], [~(start + k) & 0xFFFF for k in range(1000)])


def test_ramp_continuous_across_packets():
    ramp = CounterRamp()
    assert_same(ramp.samples(65_400, 720), ramp.samples(65_400, 360) + ramp.samples(65_760, 360))


def test_ramp_rejects_negative_index():
    with pytest.raises(ValueError):
        CounterRamp().samples(-1, 1)
