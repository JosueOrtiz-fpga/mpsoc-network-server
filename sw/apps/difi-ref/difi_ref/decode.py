"""Packet decoder: DIFI packets back into their fields, the packetizer in reverse.

decode() splits a packet without judging it; the checker (checker.py) decides what is
allowed. It assumes the DIFI prologue (class ID and both timestamps present) and, for
a context packet, the 27-word layout of this build's CIF0, and raises DecodeError only
when a packet cannot be split that way at all.
"""
import sys
from array import array
from fractions import Fraction
from typing import NamedTuple, Union

from . import fields


class DecodeError(ValueError):
    pass


class Prologue(NamedTuple):
    header: int
    stream_id: int
    class_id_1: int     # pad bit count and OUI
    class_id_2: int     # information class and packet class
    sec: int            # integer timestamp
    ps: int             # fractional timestamp, picoseconds

    @property
    def pkt_type(self) -> int:
        return self.header >> 28

    @property
    def count(self) -> int:
        return (self.header >> 16) & 0xF

    @property
    def size_words(self) -> int:
        return self.header & 0xFFFF


class DataPacket(NamedTuple):
    prologue: Prologue
    payload: bytes


class ContextPacket(NamedTuple):
    """Fields in CONTEXT_BODY order, as raw words; the properties decode the ones in use."""
    prologue: Prologue
    cif0: int
    ref_point_id: int
    bandwidth: int          # Q44.20 Hz
    if_ref_freq: int        # Q44.20 Hz
    rf_ref_freq: int        # Q44.20 Hz
    if_band_offset: int     # Q44.20 Hz
    ref_level: int          # Q9.7 dBm in bits 15:0, Scaling in 31:16
    gain: int
    sample_rate: int        # Q44.20 Hz
    ts_adjust: int          # femtoseconds, signed
    ts_cal_time: int
    state_event: int
    payload_format_1: int
    payload_format_2: int

    @property
    def changed(self) -> bool:
        return bool(self.cif0 & fields.CHANGE_INDICATOR)

    @property
    def sample_rate_hz(self) -> Fraction:
        return fields.q44_20_to_hz(self.sample_rate)

    @property
    def rf_ref_freq_hz(self) -> Fraction:
        return fields.q44_20_to_hz(self.rf_ref_freq)

    @property
    def item_bits(self) -> int:
        """Data item size from the payload format (bits 5:0, plus one)."""
        return (self.payload_format_1 & 0x3F) + 1


class OtherPacket(NamedTuple):
    """Any other packet type, such as the reference captures' version packets."""
    prologue: Prologue
    body: bytes


Packet = Union[DataPacket, ContextPacket, OtherPacket]


def decode(data: bytes) -> Packet:
    if len(data) < fields.PROLOGUE.size or len(data) % 4:
        raise DecodeError(f"{len(data)} bytes is not a whole number of words "
                          f"of at least a {fields.PROLOGUE_WORDS}-word prologue")
    prologue = Prologue(*fields.PROLOGUE.unpack_from(data))
    if 4 * prologue.size_words != len(data):
        raise DecodeError(f"header gives {prologue.size_words} words, the packet has {len(data) // 4}")
    if not prologue.header & (1 << 27):
        raise DecodeError("no class ID (header bit 27 clear)")
    if prologue.pkt_type == fields.PKT_TYPE_DATA:
        return DataPacket(prologue, data[fields.PROLOGUE.size:])
    if prologue.pkt_type == fields.PKT_TYPE_CONTEXT:
        if prologue.size_words != fields.CONTEXT_WORDS:
            raise DecodeError(f"{prologue.size_words}-word context packet; "
                              f"CIF0's field set takes {fields.CONTEXT_WORDS}")
        return ContextPacket(prologue, *fields.CONTEXT_BODY.unpack_from(data, fields.PROLOGUE.size))
    return OtherPacket(prologue, data[fields.PROLOGUE.size:])


def samples_in(payload: bytes, item_bits: int) -> int:
    """Complex samples in a link-efficient payload; any bits left over are padding."""
    return 8 * len(payload) // (2 * item_bits)


def iq16(payload: bytes) -> array:
    """A 16-bit payload as interleaved int16 I, Q, in host order."""
    iq = array("h", payload)
    if sys.byteorder == "little":
        iq.byteswap()           # DIFI payloads are big-endian
    return iq
