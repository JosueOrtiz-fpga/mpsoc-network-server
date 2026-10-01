"""Reference packetizer: DIFI data and context packets from settings, a source and a timebase.

Iteration 1 implements the context rules that need no registers: a context packet
with the change indicator first, periodic context packets every CTX_INTERVAL data
packets without it, each carrying the timestamp of the data packet that follows, and
separate 4-bit counts for data and context packets. Commits, FORCE_CONTEXT and
overflow come in iterations 4 and 5.
"""
import struct
import sys
from array import array
from typing import Iterator, NamedTuple

from . import fields
from .config import StreamConfig

_PROLOGUE = struct.Struct(">IIIIIQ")
# CIF0, reference point, bandwidth, IF reference frequency, RF reference frequency,
# IF band offset, reference level, gain, sample rate, timestamp adjustment, timestamp
# calibration time, State and Event, payload format (2 words).
_CONTEXT_BODY = struct.Struct(">IIQQQQIIQqIIII")
assert _PROLOGUE.size + _CONTEXT_BODY.size == 4 * fields.CONTEXT_WORDS


class Packet(NamedTuple):
    data: bytes
    sec: int        # integer timestamp
    ps: int         # fractional timestamp, picoseconds

    @property
    def is_context(self) -> bool:
        return self.data[0] >> 4 == fields.PKT_TYPE_CONTEXT


def _prologue(header: int, cfg: StreamConfig, packet_class: int, sec: int, ps: int) -> bytes:
    fields.check_timestamp(sec, ps)
    return _PROLOGUE.pack(header, cfg.stream_id, *fields.class_id_words(packet_class), sec, ps)


def data_packet(cfg: StreamConfig, count: int, sec: int, ps: int, iq: array) -> bytes:
    """One data packet; iq is interleaved int16 I, Q for SAMPLES_PER_PKT samples."""
    if len(iq) != 2 * cfg.samples_per_pkt:
        raise ValueError(f"{len(iq) // 2} samples for a {cfg.samples_per_pkt}-sample packet")
    payload = array("h", iq)
    if sys.byteorder == "little":
        payload.byteswap()          # DIFI payloads are big-endian, I then Q
    size_words = fields.PROLOGUE_WORDS + cfg.samples_per_pkt   # 16-bit I/Q: one word per sample
    header = fields.data_header(count, size_words)
    return _prologue(header, cfg, fields.PACKET_CLASS_DATA, sec, ps) + payload.tobytes()


def context_packet(cfg: StreamConfig, count: int, sec: int, ps: int, changed: bool) -> bytes:
    """One Standard Flow Signal Context packet, fields copied from cfg."""
    header = fields.context_header(count)
    cif0 = fields.CIF0 | (fields.CHANGE_INDICATOR if changed else 0)
    body = _CONTEXT_BODY.pack(
        cif0,
        cfg.ctx_ref_point_id,
        fields.hz_to_q44_20(cfg.ctx_bandwidth_hz),
        fields.hz_to_q44_20(cfg.ctx_if_ref_freq_hz),
        fields.hz_to_q44_20(cfg.ctx_rf_ref_freq_hz),
        fields.hz_to_q44_20(cfg.ctx_if_band_offset_hz),
        fields.ref_level_word(cfg.ctx_ref_level_dbm),
        0,                                          # Gain: reserved since v1.2.1
        fields.hz_to_q44_20(cfg.ctx_sample_rate_hz),
        cfg.ctx_ts_adjust_fs,
        cfg.ctx_ts_cal_time,
        cfg.ctx_state_event,
        *fields.payload_format_words(cfg.payload_bits),
    )
    return _prologue(header, cfg, fields.PACKET_CLASS_CONTEXT, sec, ps) + body


class Packetizer:
    """Emits the stream from ENABLE on: context first, then data with periodic context.

    cfg stands in for the active register set, source for SRC_SEL's source, and
    timebase for the PL timebase. State (sample index, counts) persists across calls
    to packets(), as the PL's does while enabled.
    """

    def __init__(self, cfg: StreamConfig, source, timebase):
        self.cfg = cfg
        self.source = source
        self.timebase = timebase
        self.next_sample = 0        # output sample index of the next data packet
        self.data_packets = 0       # data packets emitted since ENABLE
        self.data_count = 0         # 4-bit counts, separate per packet type
        self.context_count = 0

    def _context_due(self) -> tuple[bool, bool]:
        """(emit a context packet before the next data packet, with the change indicator)."""
        if self.data_packets == 0:
            return True, True
        interval = self.cfg.ctx_interval
        return interval != 0 and self.data_packets % interval == 0, False

    def packets(self, num_data_packets: int) -> Iterator[Packet]:
        """The next num_data_packets data packets, with the context packets due before them."""
        cfg = self.cfg
        for _ in range(num_data_packets):
            sec, ps = self.timebase.timestamp(self.next_sample)
            due, changed = self._context_due()
            if due:
                yield Packet(context_packet(cfg, self.context_count, sec, ps, changed), sec, ps)
                self.context_count = (self.context_count + 1) % 16
            iq = self.source.samples(self.next_sample, cfg.samples_per_pkt)
            yield Packet(data_packet(cfg, self.data_count, sec, ps, iq), sec, ps)
            self.data_count = (self.data_count + 1) % 16
            self.data_packets += 1
            self.next_sample += cfg.samples_per_pkt
