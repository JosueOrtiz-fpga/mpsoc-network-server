"""Receiver pre-check: the model's stream, replayed over UDP in real time, into gr-difi.

Runs under make ref-rx-check only (marker rx, selected by pytest's --rx option, see
conftest.py). GNU Radio and gr-difi are imported inside the fixtures, so make ref-test
still collects this file on a host without them.

gr-difi reads samples byte-swapped (gr-difi issue #19), so the replay sends data
payloads through gr_difi_payload(). test_gr_difi_issue_19_still_present shows the bug
at the pinned commit; when a newer commit fixes it, that test fails and the
compensation goes.
"""
import socket

import numpy as np
import pytest

from conftest import SEED, make_packetizer
from difi_ref import fields
from difi_ref.config import StreamConfig
from difi_ref.replay import gr_difi_payload, replay

pytestmark = pytest.mark.rx

NUM_DATA = 1100         # context packets at data packets 0, 533 and 1066
FFT_SIZE = 4096
ARRIVAL_TIMEOUT_S = 2.0

# The example run, and a second stream at twice the rate with a tone below the center,
# so a sign or I/Q error cannot pass. Both tones fall on a bin of a 4096-point FFT.
STREAMS = {
    "192k_7.1MHz_+12kHz": (StreamConfig(ctx_ts_cal_time=SEED), 12_000),
    "384k_14.2MHz_-1.5kHz": (StreamConfig(ddc_decim=320, ctx_sample_rate_hz=384_000, ctx_bandwidth_hz=307_200,
                                          ctx_rf_ref_freq_hz=14_200_000, ctx_ts_cal_time=SEED), -1_500),
}


def free_udp_port() -> int:
    # gr-difi binds every interface, so probe the same way. Another process could take
    # the port before gr-difi binds it; gr-difi then fails loudly ("Could not connect to port").
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.bind(("0.0.0.0", 0))
        return s.getsockname()[1]


def run(cfg, tone_hz, num_data, transform):
    """Replay num_data data packets of the stream into gr-difi; returns (packets, stats, capture)."""
    from difi_rx.receiver import Receiver

    pkt = make_packetizer(cfg, tone_hz)
    packets = list(pkt.packets(num_data))
    port = free_udp_port()
    rx = Receiver(port, cfg.stream_id)
    rx.start()
    want = num_data * cfg.samples_per_pkt
    try:
        replay(packets, ("127.0.0.1", port), transform=transform)
        # Fail here, with the cause, rather than in every test that uses the capture.
        assert rx.wait_for(want, ARRIVAL_TIMEOUT_S), (
            f"gr-difi output {rx.received()} of {want} samples within {ARRIVAL_TIMEOUT_S} s of the "
            "last packet: it dropped packets or stopped (its error, if any, is in the captured output below)")
    finally:
        capture = rx.stop()
    return pkt, packets, capture


def expected_samples(source, count) -> np.ndarray:
    iq = np.frombuffer(source.samples(0, count).tobytes(), dtype=np.int16).astype(np.float32)
    return (iq[0::2] + 1j * iq[1::2]).astype(np.complex64)


def first_difference(got, want) -> str:
    if len(got) != len(want):
        return f"{len(got)} samples, expected {len(want)}"
    i = int(np.flatnonzero(got != want)[0])
    return f"first difference at sample {i}: {got[i]} != {want[i]}"


def spectrum_peak(samples, sample_rate_hz):
    """(peak bin, its frequency, the next-highest bin relative to it in dB) of the last FFT_SIZE samples."""
    spec = np.abs(np.fft.fft(samples[-FFT_SIZE:]))
    peak = int(np.argmax(spec))
    return peak, np.fft.fftfreq(FFT_SIZE, 1 / sample_rate_hz)[peak], 20 * np.log10(np.sort(spec)[-2] / spec[peak])


@pytest.fixture(scope="module", params=list(STREAMS), ids=list(STREAMS))
def received(request):
    cfg, tone_hz = STREAMS[request.param]
    pkt, packets, capture = run(cfg, tone_hz, NUM_DATA, gr_difi_payload)
    return cfg, tone_hz, pkt.source, packets, capture


def test_every_sample_arrives_bit_exact(received):
    cfg, _, source, _, capture = received
    want = expected_samples(source, NUM_DATA * cfg.samples_per_pkt)
    assert np.array_equal(capture.samples, want), first_difference(capture.samples, want)


def test_gap_tag_only_on_the_first_packet(received):
    *_, packets, capture = received
    gaps = capture.tagged("pck_n")
    assert [(t.offset, t.value["pck_n"]) for t in gaps] == [(0, 0)], [str(t) for t in gaps[:5]]
    # The only data-packet timestamp gr-difi passes on.
    first = next(p for p in packets if not p.is_context)
    assert (gaps[0].value["full"], gaps[0].value["frac"]) == (first.sec, first.ps)


def test_context_tags_carry_the_configured_fields(received):
    cfg, _, _, packets, capture = received
    contexts = [p for p in packets if p.is_context]
    tags = capture.tagged("context")
    offsets, data_sent = [], 0       # each context tag lands on the next data packet's first sample
    for p in packets:
        if p.is_context:
            offsets.append(data_sent * cfg.samples_per_pkt)
        else:
            data_sent += 1
    assert [t.offset for t in tags] == offsets
    hi, lo = fields.class_id_words(fields.PACKET_CLASS_CONTEXT)
    for tag, p in zip(tags, contexts):
        v = tag.value
        assert v["samp_rate"] == cfg.ctx_sample_rate_hz
        assert v["rf_reference_frequency"] == cfg.ctx_rf_ref_freq_hz
        assert v["bandwidth"] == cfg.ctx_bandwidth_hz
        assert v["if_reference_frequency"] == cfg.ctx_if_ref_freq_hz
        assert v["if_band_offset"] == cfg.ctx_if_band_offset_hz
        assert v["reference_level"] == cfg.ctx_ref_level_dbm
        assert v["reference_point"] == cfg.ctx_ref_point_id
        assert v["stream_num"] == cfg.stream_id
        assert v["class_id"] == hi << 32 | lo
        assert (v["full"], v["frac"]) == (p.sec, p.ps)
        assert v["timestamp_calibration_time"] == cfg.ctx_ts_cal_time
        assert v["state_and_event_indicator"] == cfg.ctx_state_event


def test_tone_at_its_frequency(received):
    cfg, tone_hz, _, _, capture = received
    peak, freq, next_db = spectrum_peak(capture.samples, cfg.ctx_sample_rate_hz)
    assert freq == tone_hz
    assert next_db < -60, f"next-highest bin {next_db:.1f} dB below the tone"


def test_gr_difi_issue_19_still_present():
    # Without the compensation, gr-difi outputs every sample byte-swapped and the tone is lost.
    cfg, tone_hz = STREAMS["192k_7.1MHz_+12kHz"]
    num_data = 100
    pkt, _, capture = run(cfg, tone_hz, num_data, None)
    want = expected_samples(pkt.source, num_data * cfg.samples_per_pkt)
    swapped = (want.real.astype(np.int16).byteswap().astype(np.float32)
               + 1j * want.imag.astype(np.int16).byteswap().astype(np.float32)).astype(np.complex64)
    assert np.array_equal(capture.samples, swapped), (
        "gr-difi no longer byte-swaps samples: drop gr_difi_payload() from the replay "
        f"({first_difference(capture.samples, swapped)})")
    assert spectrum_peak(capture.samples, cfg.ctx_sample_rate_hz)[1] != tone_hz
