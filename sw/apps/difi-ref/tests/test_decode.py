"""Packet decoder: the packetizer's output decoded back, and checked against the oracle's parser."""
import struct
from fractions import Fraction

import pytest

import oracle
from conftest import SEED, assert_same
from difi_ref import fields
from difi_ref.config import StreamConfig
from difi_ref.decode import (ContextPacket, DataPacket, DecodeError, OtherPacket, decode, iq16,
                             samples_in)
from difi_ref.packetizer import context_packet
from reference_captures import CAPTURES, read_capture


def test_data_packets_round_trip(example):
    _, source, packets = example
    data = [p for p in packets if not p.is_context]
    for k in (0, 1, 777):
        d = decode(data[k].data)
        assert isinstance(d, DataPacket)
        assert (d.prologue.sec, d.prologue.ps) == (data[k].sec, data[k].ps)
        assert d.prologue.count == k % 16
        assert d.prologue.size_words == 367
        assert samples_in(d.payload, 16) == 360
        assert_same(iq16(d.payload), source.samples(360 * k, 360))


def test_context_packet_round_trip():
    cfg = StreamConfig(stream_id=0x12345678, ctx_rf_ref_freq_hz=14_200_000, ctx_ref_level_dbm=Fraction(-25, 2),
                       ctx_ts_adjust_fs=-5, ctx_ts_cal_time=SEED, ctx_state_event=0xA0080000)
    c = decode(context_packet(cfg, 9, SEED, 123, changed=True))
    assert isinstance(c, ContextPacket)
    assert c.prologue.stream_id == 0x12345678
    assert (c.prologue.count, c.prologue.sec, c.prologue.ps) == (9, SEED, 123)
    assert c.changed and c.cif0 == fields.CIF0 | fields.CHANGE_INDICATOR
    assert c.ref_point_id == 75
    assert c.sample_rate_hz == 192_000 and c.rf_ref_freq_hz == 14_200_000
    assert fields.q44_20_to_hz(c.bandwidth) == cfg.ctx_bandwidth_hz
    assert fields.ref_level_dbm(c.ref_level) == Fraction(-25, 2)
    assert c.gain == 0
    assert c.ts_adjust == -5 and c.ts_cal_time == SEED
    assert c.state_event == 0xA0080000
    assert c.item_bits == 16 and (c.payload_format_1, c.payload_format_2) == fields.payload_format_words(16)
    assert not decode(context_packet(cfg, 0, SEED, 0, changed=False)).changed


def test_agrees_with_the_oracle(example):
    # The oracle's Construct parser was written independently of ours.
    _, _, packets = example
    for p in packets[:3]:
        ours = decode(p.data)
        theirs = (oracle.difi_context_definition if p.is_context else oracle.difi_data_definition).parse(p.data)
        assert theirs.header.pktType == ours.prologue.pkt_type
        assert theirs.header.seqNum == ours.prologue.count
        assert theirs.header.pktSize == ours.prologue.size_words
        assert theirs.streamId == ours.prologue.stream_id
        assert theirs.classId.oui == ours.prologue.class_id_1 & 0xFFFFFF
        assert theirs.classId.packetClassCode == ours.prologue.class_id_2 & 0xFFFF
        assert (theirs.intSecsTimestamp, theirs.fracSecsTimestamp) == (ours.prologue.sec, ours.prologue.ps)
        if p.is_context:
            assert theirs.rfFreq == ours.rf_ref_freq_hz
            assert theirs.sampleRate == ours.sample_rate_hz
            assert theirs.timeStampCal == ours.ts_cal_time
            assert theirs.dataPacketFormat.data_item_size + 1 == ours.item_bits
        else:
            assert theirs.payload == ours.payload


@pytest.mark.parametrize("name", CAPTURES)
def test_reference_captures_decode(name):
    rate, bits, samples = CAPTURES[name]
    kinds = {DataPacket: 0, ContextPacket: 0, OtherPacket: 0}
    for record in read_capture(name):
        p = decode(record.payload)
        kinds[type(p)] += 1
        if isinstance(p, ContextPacket):
            assert (p.sample_rate_hz, p.item_bits) == (rate, bits)
        elif isinstance(p, DataPacket):
            assert samples_in(p.payload, bits) == samples
        else:
            assert p.prologue.pkt_type == fields.PKT_TYPE_VERSION
    assert kinds == {DataPacket: 100, ContextPacket: 10, OtherPacket: 2}


def test_samples_in_link_efficient_payloads():
    assert samples_in(bytes(4 * 360), 16) == 360
    assert samples_in(bytes(4 * 360), 8) == 720
    assert samples_in(bytes(4 * 2232), 12) == 2976
    assert samples_in(bytes(4 * 3), 12) == 4           # 96 bits: four 24-bit samples, no padding
    assert samples_in(bytes(4 * 1), 12) == 1           # 32 bits: one sample and 8 bits of padding


def _context(**changes) -> bytes:
    data = bytearray(context_packet(StreamConfig(), 0, SEED, 0, changed=True))
    for word, value in changes.items():
        struct.pack_into(">I", data, 4 * int(word[1:]), value)
    return bytes(data)


DECODE_ERRORS = {
    "empty": (b"", "whole number of words"),
    "short-prologue": (bytes(24), "7-word prologue"),
    "partial-word": (_context()[:-2], "whole number of words"),
    "size-field": (_context()[:-4], "header gives 27 words, the packet has 26"),
    "no-class-id": (_context(w0=0x40000000 | 27), "no class ID"),
    "context-26-words": (_context(w0=fields.context_header(0) - 1)[:-4], "26-word context packet"),
}


@pytest.mark.parametrize("data, message", DECODE_ERRORS.values(), ids=DECODE_ERRORS)
def test_rejects(data, message):
    with pytest.raises(DecodeError, match=message):
        decode(data)


def test_other_packet_types_keep_their_body():
    data = bytearray(_context())
    data[0] = (data[0] & 0x0F) | 0x50
    p = decode(bytes(data))
    assert isinstance(p, OtherPacket)
    assert p.prologue.pkt_type == 5 and p.body == bytes(data[28:])
