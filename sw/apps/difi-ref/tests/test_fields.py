"""Field encoders against the values in the architecture's Field values table."""
from fractions import Fraction

import pytest

from difi_ref import fields


def test_header_constants():
    assert fields.data_header(0, 367) >> 20 == 0x18E
    assert fields.context_header(0) >> 20 == 0x49E
    assert fields.data_header(0xA, 367) & 0xFFFFF == 0xA0000 | 367
    assert fields.context_header(3) & 0xFFFFF == 0x30000 | 27


@pytest.mark.parametrize("count", [-1, 16])
def test_header_count_is_4_bits(count):
    with pytest.raises(ValueError):
        fields.data_header(count, 367)


def test_class_id():
    assert fields.class_id_words(fields.PACKET_CLASS_DATA) == (0x006A621E, 0x00000000)
    assert fields.class_id_words(fields.PACKET_CLASS_CONTEXT) == (0x006A621E, 0x00000001)


def test_payload_format():
    assert fields.payload_format_words(16) == (0xA00003CF, 0)
    assert fields.payload_format_words(8) == (0xA00001C7, 0)    # the reference captures' 8-bit form


def test_cif0():
    assert fields.CIF0 == 0x7BB98000
    assert fields.CIF0 | fields.CHANGE_INDICATOR == 0xFBB98000


@pytest.mark.parametrize("hz, word", [
    (0, 0),
    (1, 1 << 20),
    (7_100_000, 7_100_000 << 20),
    (-1, 0xFFFF_FFFF_FFF0_0000),
])
def test_q44_20(hz, word):
    assert fields.hz_to_q44_20(hz) == word
    assert fields.q44_20_to_hz(word) == hz


def test_q44_20_rejects_fractional_hertz():
    with pytest.raises(TypeError):
        fields.hz_to_q44_20(7_100_000.0)


def test_q44_20_range():
    fields.hz_to_q44_20((1 << 43) - 1)
    with pytest.raises(ValueError):
        fields.hz_to_q44_20(1 << 43)


def test_q44_20_decodes_fraction_bits():
    assert fields.q44_20_to_hz((5 << 20) | (1 << 19)) == Fraction(11, 2)


@pytest.mark.parametrize("dbm, word", [
    (0, 0x0000),
    (-1, 0xFF80),
    (1.5, 0x00C0),
    (Fraction(-25, 2), 0xF9C0),
    (Fraction(1, 256), 0x0000),     # half an LSB: ties to even
    (Fraction(3, 256), 0x0002),
])
def test_ref_level(dbm, word):
    assert fields.ref_level_word(dbm) == word


def test_ref_level_round_trip_and_range():
    assert fields.ref_level_dbm(fields.ref_level_word(-12.5)) == Fraction(-25, 2)
    assert fields.ref_level_dbm(0xABCD_0080) == 1      # Scaling sub-field ignored
    with pytest.raises(ValueError):
        fields.ref_level_word(256)


@pytest.mark.parametrize("sec, ps", [(-1, 0), (1 << 32, 0), (0, -1), (0, fields.PS_PER_S)])
def test_timestamp_range(sec, ps):
    with pytest.raises(ValueError):
        fields.check_timestamp(sec, ps)
