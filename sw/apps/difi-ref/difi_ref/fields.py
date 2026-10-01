"""DIFI v1.2.1 field values and encoders.

Values follow Field values in docs/difi-streaming-architecture.md. Where the
DIFI-Certification Construct definitions disagree with the spec (Reference Level in
bits 15:0, State and Event layout), the spec wins; see Oracle caveats there.
"""
from fractions import Fraction

PS_PER_S = 10**12

PKT_TYPE_DATA = 0x1
PKT_TYPE_CONTEXT = 0x4
TSI_POSIX = 3
TSF_REAL_TIME = 2

OUI = 0x6A621E
INFO_CLASS = 0x0000             # Basic Data Plane
PACKET_CLASS_DATA = 0x0000      # Standard Flow Signal Data
PACKET_CLASS_CONTEXT = 0x0001   # Standard Flow Signal Context

PROLOGUE_WORDS = 7              # header, stream ID, class ID (2), integer and fractional timestamp (1 + 2)
CONTEXT_WORDS = 27

CHANGE_INDICATOR = 1 << 31      # CIF0 bit 31
CIF0 = 0x7BB98000               # the field set this build emits, change indicator clear
REF_POINT_IDS = (100, 75, 25, 15)
STATE_EVENT_UNLOCKED = 0xA0000000  # calibrated-time and reference-lock enables, nothing locked

U64 = (1 << 64) - 1


def _header(pkt_type: int, tsm: int, count: int, size_words: int) -> int:
    if not 0 <= count <= 0xF:
        raise ValueError(f"packet count {count} is not 4 bits")
    if not 0 <= size_words <= 0xFFFF:
        raise ValueError(f"packet size {size_words} words does not fit 16 bits")
    # Bit 27: class ID present. Bits 26 and 25 (trailer and VITA 49.0 indicators in data
    # packets, reserved in context packets) stay 0.
    return ((pkt_type << 28) | (1 << 27) | (tsm << 24) | (TSI_POSIX << 22)
            | (TSF_REAL_TIME << 20) | (count << 16) | size_words)


def data_header(count: int, size_words: int) -> int:
    """Data packet header word: bits 31:20 are 0x18E."""
    return _header(PKT_TYPE_DATA, 0, count, size_words)


def context_header(count: int) -> int:
    """Context packet header word: bits 31:20 are 0x49E (TSM = 1, coarse)."""
    return _header(PKT_TYPE_CONTEXT, 1, count, CONTEXT_WORDS)


def class_id_words(packet_class: int) -> tuple[int, int]:
    """Class ID: pad bit count 0 and the OUI, then information and packet class."""
    return OUI, (INFO_CLASS << 16) | packet_class


def payload_format_words(item_bits: int = 16) -> tuple[int, int]:
    """Data Packet Payload Format: link-efficient, complex Cartesian, signed fixed point.

    Item packing field size equals data item size, as DIFI requires; 16-bit gives
    (0xA00003CF, 0x00000000).
    """
    if not 4 <= item_bits <= 16:
        raise ValueError(f"{item_bits}-bit samples are outside DIFI's 4 to 16 bits")
    size = item_bits - 1
    return (1 << 31) | (1 << 29) | (size << 6) | size, 0


def hz_to_q44_20(hz: int) -> int:
    """Frequency or rate in VITA Q44.20 hertz, as an unsigned 64-bit word.

    DIFI requires whole hertz, so only integers are accepted: the 20 fraction bits
    are always 0.
    """
    if not isinstance(hz, int):
        raise TypeError(f"DIFI frequencies are integer hertz, got {hz!r}")
    raw = hz << 20
    if not -(1 << 63) <= raw < (1 << 63):
        raise ValueError(f"{hz} Hz does not fit Q44.20")
    return raw & U64


def q44_20_to_hz(word: int) -> Fraction:
    """Inverse of hz_to_q44_20, for any word (fraction bits included)."""
    raw = word - (1 << 64) if word & (1 << 63) else word
    return Fraction(raw, 1 << 20)


def ref_level_word(dbm) -> int:
    """Reference Level word: Q9.7 dBm in bits 15:0, Scaling (bits 31:16) 0.

    Rounds to the nearest 1/128 dB, ties to even. Accepts int, float or Fraction.
    """
    raw = round(Fraction(dbm) * 128)
    if not -(1 << 15) <= raw < (1 << 15):
        raise ValueError(f"{dbm} dBm does not fit Q9.7")
    return raw & 0xFFFF


def ref_level_dbm(word: int) -> Fraction:
    """Inverse of ref_level_word; ignores the Scaling sub-field."""
    raw = word & 0xFFFF
    if raw & 0x8000:
        raw -= 1 << 16
    return Fraction(raw, 128)


def check_timestamp(sec: int, ps: int) -> None:
    """POSIX integer seconds in 32 bits and picoseconds below one second."""
    if not 0 <= sec <= 0xFFFFFFFF:
        raise ValueError(f"integer timestamp {sec} does not fit 32 bits")
    if not 0 <= ps < PS_PER_S:
        raise ValueError(f"fractional timestamp {ps} ps is not below one second")
