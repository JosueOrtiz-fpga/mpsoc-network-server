"""Reference packetizer: every packet through the oracle, then the stream rules it must keep."""
import struct
from array import array
from fractions import Fraction

import pytest

import oracle
from conftest import NUM_DATA, SEED, assert_same, make_packetizer
from difi_ref import fields
from difi_ref.config import StreamConfig
from difi_ref.packetizer import context_packet, data_packet

DATA_BYTES = 4 * (7 + 360)      # 1468 B, 367 words
PERIOD_PS = 1_875_000_000       # 360 samples x 640 / 122.88 MHz


def split(packets):
    return [p for p in packets if p.is_context], [p for p in packets if not p.is_context]


def word(packet, index):
    return struct.unpack_from(">I", packet.data, 4 * index)[0]


# ---- the oracle --------------------------------------------------------------------------

def test_every_packet_passes_validate(example):
    _, _, packets = example
    failures = []
    for i, p in enumerate(packets):
        errors = oracle.validate_context(p.data) if p.is_context else oracle.validate_data(p.data)
        if errors:
            failures.append((i, errors))
    assert failures == []


def test_oracle_reads_back_context_fields(example):
    cfg, _, packets = example
    ctx = oracle.difi_context_definition.parse(packets[0].data)
    assert ctx.streamId == cfg.stream_id
    assert ctx.refPoint == "RF"
    assert ctx.bandwidth == cfg.ctx_bandwidth_hz
    assert ctx.ifFreq == 0
    assert ctx.rfFreq == cfg.ctx_rf_ref_freq_hz
    assert ctx.ifBandOffset == 0
    assert ctx.sampleRate == cfg.ctx_sample_rate_hz
    assert ctx.timeStampAdj == 0
    assert ctx.timeStampCal == SEED
    assert ctx.dataPacketFormat.data_item_size == 15
    assert ctx.dataPacketFormat.item_packing_field_size == 15


# ---- packet structure --------------------------------------------------------------------

def test_sizes_match_header(example):
    contexts, data = split(example[2])
    assert {len(p.data) for p in data} == {DATA_BYTES}
    assert {len(p.data) for p in contexts} == {108}
    for p in example[2]:
        assert word(p, 0) & 0xFFFF == len(p.data) // 4


def test_header_and_class_words(example):
    for p in example[2]:
        h = word(p, 0)
        assert h >> 20 == (0x49E if p.is_context else 0x18E)
        assert word(p, 2) == 0x006A621E
        assert word(p, 3) == (0x0001 if p.is_context else 0x0000)


def test_words_the_oracle_reads_differently():
    # Reference Level in bits 15:0 (the oracle reads 31:16), Gain 0, State and Event
    # copied verbatim: see Oracle caveats.
    cfg = StreamConfig(ctx_ref_level_dbm=Fraction(-25, 2), ctx_state_event=0xA0080000)
    p = context_packet(cfg, 0, SEED, 0, changed=True)
    words = struct.unpack(">27I", p)
    assert fields.ref_level_dbm(words[17]) == Fraction(-25, 2)
    assert words[17] >> 16 == 0
    assert words[18] == 0
    assert words[24] == 0xA0080000
    assert words[25:27] == (0xA00003CF, 0)


def test_payload_is_big_endian_i_then_q(example):
    _, source, packets = example
    _, data = split(packets)
    for k in (0, 1, 777):
        got = array("h", data[k].data[28:])
        got.byteswap()          # big-endian on the wire; the test host is little-endian
        assert_same(got, source.samples(k * 360, 360))


def test_stream_id_is_used():
    pkt = make_packetizer(StreamConfig(stream_id=0x12345678, ctx_ts_cal_time=SEED))
    assert {word(p, 1) for p in pkt.packets(3)} == {0x12345678}


def test_data_packet_needs_a_full_packet_of_samples():
    cfg = StreamConfig()
    with pytest.raises(ValueError):
        data_packet(cfg, 0, SEED, 0, array("h", bytes(4 * 359)))


# ---- stream rules ------------------------------------------------------------------------

def test_context_first_with_change_indicator(example):
    packets = example[2]
    assert packets[0].is_context
    assert word(packets[0], 7) == 0xFBB98000


def test_periodic_context_without_change_indicator(example):
    packets = example[2]
    # Context packets precede data packets 0, 533 and 1066.
    data_index, before = -1, []
    for p in packets:
        if p.is_context:
            before.append(data_index + 1)
        else:
            data_index += 1
    assert before == [0, 533, 1066]
    contexts, _ = split(packets)
    assert [word(c, 7) for c in contexts] == [0xFBB98000, 0x7BB98000, 0x7BB98000]


def test_context_carries_next_data_timestamp(example):
    packets = example[2]
    for i, p in enumerate(packets):
        if p.is_context:
            nxt = packets[i + 1]
            assert not nxt.is_context
            assert (p.sec, p.ps) == (nxt.sec, nxt.ps)
            assert struct.unpack_from(">IQ", p.data, 16) == struct.unpack_from(">IQ", nxt.data, 16)


def test_counts_continuous_per_type(example):
    contexts, data = split(example[2])
    assert_same([(word(p, 0) >> 16) & 0xF for p in data], [k % 16 for k in range(NUM_DATA)])
    assert [(word(p, 0) >> 16) & 0xF for p in contexts] == [0, 1, 2]


def test_data_timestamps_step_by_packet_period(example):
    _, data = split(example[2])
    assert (data[0].sec, data[0].ps) == (SEED, 0)
    times = [p.sec * fields.PS_PER_S + p.ps for p in data]
    assert {b - a for a, b in zip(times, times[1:])} == {PERIOD_PS}
    assert data[-1].sec == SEED + 2         # the stream crossed two seconds rollovers
    # The header fields carry the same values as the Packet tuple.
    assert all(struct.unpack_from(">IQ", p.data, 16) == (p.sec, p.ps) for p in data)


def test_state_persists_across_calls():
    whole = list(make_packetizer().packets(600))
    pkt = make_packetizer()
    parts = list(pkt.packets(550)) + list(pkt.packets(50))
    assert_same(parts, whole)


def test_ctx_interval_zero_means_start_only():
    pkt = make_packetizer(StreamConfig(ctx_interval=0, ctx_ts_cal_time=SEED))
    contexts, _ = split(list(pkt.packets(1100)))
    assert len(contexts) == 1


# ---- settings ----------------------------------------------------------------------------

@pytest.mark.parametrize("kwargs", [
    dict(ctx_sample_rate_hz=190_000),               # not FS_IN_HZ / DDC_DECIM
    dict(ddc_decim=642, ctx_sample_rate_hz=191_402),  # not a multiple of 4
    dict(samples_per_pkt=17),
    dict(samples_per_pkt=362),
    dict(payload_bits=8),
    dict(ctx_ref_point_id=50),
    dict(ctx_rf_ref_freq_hz=7_100_000.5),
    dict(stream_id=1 << 32),
])
def test_config_rejects(kwargs):
    with pytest.raises((TypeError, ValueError)):
        StreamConfig(**kwargs)
