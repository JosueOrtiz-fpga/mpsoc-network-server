"""Ideal tone: int16 range, continuity across packets, frequency and purity."""
import numpy as np
import pytest

from conftest import assert_same
from difi_ref.sources import IdealTone

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
