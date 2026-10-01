"""Stream checker: clean streams pass, every corruption is flagged where it is, and the
reference captures pass in lenient mode.

The mutation tests corrupt one thing in a generated counter-ramp stream and expect the
exact set of findings, as (rule, packet index), in strict and in lenient mode. Every
rule must be provoked by at least one of them.
"""
import os
import struct
import subprocess
import sys
from pathlib import Path

import pytest

from conftest import SEED, TONE_HZ
from difi_ref import fields
from difi_ref.checker import RULES, Finding, Gap, StreamFormat, check
from difi_ref.config import StreamConfig
from difi_ref.packetizer import Packetizer
from difi_ref.pcap import write_pcap
from difi_ref.sources import CounterRamp, IdealTone
from difi_ref.timebase import IdealTimebase
from reference_captures import CAPTURE_DIR, CAPTURES, read_capture

PKG_DIR = Path(__file__).resolve().parents[1]
NUM_DATA = 600          # context packets before data packets 0 and 533; one seconds rollover
D = 100                 # packet index of data packet 99
C = 534                 # packet index of the periodic context packet
LENIENT_SKIPS = {"gain", "context-first", "change-indicator", "size", "timestamp-step", "gap", "samples"}


def ramp_packetizer(cfg=None):
    cfg = cfg or StreamConfig(ctx_ts_cal_time=SEED)
    return Packetizer(cfg, CounterRamp(), IdealTimebase(SEED, cfg.fs_in_hz, cfg.ddc_decim))


@pytest.fixture(scope="module")
def ramp():
    stream = [p.data for p in ramp_packetizer().packets(NUM_DATA)]
    assert [i for i, p in enumerate(stream) if p[0] >> 4 == fields.PKT_TYPE_CONTEXT] == [0, C]
    return stream


def found(report):
    return {(f.rule, f.index) for f in report.findings}


# ---- clean streams -----------------------------------------------------------------------

def test_ramp_stream_passes_every_rule(ramp):
    report = check(ramp, source=CounterRamp())
    assert report.findings == []
    assert report.not_checked == []
    assert report.stream == StreamFormat(192_000, 16)
    assert report.packets == {"data": NUM_DATA, "context": 2}


def test_tone_stream_passes_every_rule(example):
    cfg, _, packets = example
    report = check(packets, source=IdealTone(TONE_HZ, cfg.ctx_sample_rate_hz))
    assert report.findings == []
    assert report.not_checked == []


def test_lenient_skips_only_its_rules(ramp):
    report = check(ramp, lenient=True)
    assert report.findings == []
    assert set(report.not_checked) == LENIENT_SKIPS


def test_period_not_a_whole_number_of_picoseconds():
    # 361 samples at 192 kS/s is 1,880,208,333.3 ps: timestamps rounded down to the
    # picosecond step by 1 ps more or less than the period, which the 1 ps tolerance allows.
    pkt = ramp_packetizer(StreamConfig(samples_per_pkt=361, ctx_ts_cal_time=SEED))
    stream = [p.data for p in pkt.packets(50)]
    assert check(stream, source=CounterRamp()).findings == []
    bad = with_ps(stream[10], lambda ps: ps + 2)
    assert found(check(stream[:10] + [bad] + stream[11:])) == {("timestamp-step", 10), ("timestamp-step", 11)}


def test_one_picosecond_error_is_within_tolerance(ramp):
    assert check(edit(D, with_ps_by(1))(ramp)).findings == []


def test_first_sample_places_the_source(ramp):
    report = check(ramp, source=CounterRamp(), first_sample=1)
    assert found(report) == {("samples", i) for i, p in enumerate(ramp) if p[0] >> 4 == fields.PKT_TYPE_DATA}


# ---- mutations ---------------------------------------------------------------------------

def get(data, k):
    return struct.unpack_from(">I", data, 4 * k)[0]


def put(data, k, value):
    out = bytearray(data)
    struct.pack_into(">I", out, 4 * k, value & 0xFFFFFFFF)
    return bytes(out)


def word(k, fn):
    return lambda d: put(d, k, fn(get(d, k)))


def dword(k, fn):
    def apply(d):
        value = fn(get(d, k) << 32 | get(d, k + 1))
        return put(put(d, k, value >> 32), k + 1, value)
    return apply


def with_ps(d, fn):
    return dword(5, fn)(d)


def with_ps_by(delta):
    return lambda d: with_ps(d, lambda ps: ps + delta)


def edit(i, fn):
    return lambda s: s[:i] + [fn(s[i])] + s[i + 1:]


def insert(i, fn):
    return lambda s: s[:i] + [fn(s)] + s[i:]


def as_type(pkt_type):
    return lambda d: bytes([(d[0] & 0x0F) | pkt_type << 4]) + d[1:]


def payload(fn):
    return lambda d: d[:28] + fn(d[28:])


def count_plus_one(h):
    return h & ~0xF0000 | (((h >> 16) + 1) & 0xF) << 16


def truncate(samples):
    return lambda d: put(d[:28 + 4 * samples], 0, get(d, 0) & ~0xFFFF | (7 + samples))


def one_bit(p):
    return p[:31] + bytes([p[31] ^ 1]) + p[32:]          # Q of sample 7, LSB


def byte_swapped(p):
    return b"".join(p[k + 1:k + 2] + p[k:k + 1] for k in range(0, len(p), 2))


def iq_swapped(p):
    return b"".join(p[k + 2:k + 4] + p[k:k + 2] for k in range(0, len(p), 4))


def swap_first_two(s):
    return [s[1], s[0]] + s[2:]


PF_8BIT = fields.payload_format_words(8)[0]
PF_15BIT_PACKING = fields.payload_format_words(16)[0] ^ 1 << 6   # packing size 15, item size 16
CI = fields.CHANGE_INDICATOR

# name: (mutation, strict findings, lenient findings)
MUTATIONS = {
    "size-field": (edit(D, word(0, lambda h: h - 1)), {("decode", D), ("gap", D + 1)}, {("decode", D)}),
    "version-packet": (insert(D + 1, lambda s: as_type(5)(s[C])), {("packet-type", D + 1)}, set()),
    "command-packet": (insert(D + 1, lambda s: as_type(7)(s[C])), {("packet-type", D + 1)},
                       {("packet-type", D + 1)}),
    "tsi": (edit(D, word(0, lambda h: h ^ 1 << 22)), {("header", D)}, {("header", D)}),
    "trailer-bit": (edit(D, word(0, lambda h: h | 1 << 26)), {("header", D)}, {("header", D)}),
    "oui": (edit(D, word(2, lambda w: w + 1)), {("class-id", D)}, {("class-id", D)}),
    "context-packet-class": (edit(C, word(3, lambda w: 0)), {("class-id", C)}, {("class-id", C)}),
    "stream-id": (edit(D, word(1, lambda w: 1)), {("stream-id", D)}, {("stream-id", D)}),
    "fraction-over-1s": (edit(D, lambda d: word(4, lambda s: s - 1)(with_ps(d, lambda ps: ps + fields.PS_PER_S))),
                         {("timestamp", D)}, {("timestamp", D)}),
    "17-samples": (edit(D, truncate(17)), {("size", D), ("timestamp-step", D + 1)}, set()),
    "cif0": (edit(C, word(7, lambda w: w & ~0x8000)), {("cif0", C)}, {("cif0", C)}),
    "ref-point": (edit(C, word(8, lambda w: 50)), {("ref-point", C)}, {("ref-point", C)}),
    "rf-fraction": (edit(C, dword(13, lambda q: q + 1)), {("frequencies", C)}, {("frequencies", C)}),
    # Half a hertz: the data after it is still read at the last usable rate, so only this.
    "rate-fraction": (edit(C, dword(19, lambda q: q + (1 << 19))), {("frequencies", C)}, {("frequencies", C)}),
    "ref-level-scaling": (edit(C, word(17, lambda w: w | 1 << 16)), {("ref-level", C)}, {("ref-level", C)}),
    "gain": (edit(C, word(18, lambda w: 0xF960)), {("gain", C)}, set()),
    "8-bit": (edit(C, word(25, lambda w: PF_8BIT)), {("payload-format", C)}, set()),
    "8-bit-first": (edit(0, word(25, lambda w: PF_8BIT)), {("payload-format", 0)}, set()),
    "packing-size": (edit(C, word(25, lambda w: PF_15BIT_PACKING)), {("payload-format", C)},
                     {("payload-format", C)}),
    "data-first": (swap_first_two, {("context-first", 0), ("context-timestamp", 1)}, {("context-timestamp", 1)}),
    "no-change-indicator": (edit(0, word(7, lambda w: w & ~CI)), {("change-indicator", 0)}, set()),
    "periodic-change-indicator": (edit(C, word(7, lambda w: w | CI)), {("change-indicator", C)}, set()),
    "data-count": (edit(D, word(0, count_plus_one)), {("count", D), ("count", D + 1)}, set()),
    "context-count": (edit(C, word(0, count_plus_one)), {("count", C)}, {("count", C)}),
    "timestamp-2ps": (edit(D, with_ps_by(2)), {("timestamp-step", D), ("timestamp-step", D + 1)}, set()),
    "context-timestamp": (edit(C, with_ps_by(1)), {("context-timestamp", C)}, {("context-timestamp", C)}),
    "drop-1": (lambda s: s[:D] + s[D + 1:], {("gap", D)}, set()),
    # 16 missing leave the 4-bit count continuous: only the timestamps show the gap.
    "drop-16": (lambda s: s[:D] + s[D + 16:], {("gap", D)}, set()),
    "duplicate": (insert(D + 1, lambda s: s[D]), {("count", D + 1), ("timestamp-step", D + 1)}, set()),
    "sample-bit": (edit(D, payload(one_bit)), {("samples", D)}, set()),
    "little-endian": (edit(D, payload(byte_swapped)), {("samples", D)}, set()),
    "i-q-swapped": (edit(D, payload(iq_swapped)), {("samples", D)}, set()),
}


@pytest.mark.parametrize("name", MUTATIONS)
def test_mutation_strict(ramp, name):
    mutate, strict, _ = MUTATIONS[name]
    assert found(check(mutate(ramp), source=CounterRamp())) == strict


@pytest.mark.parametrize("name", MUTATIONS)
def test_mutation_lenient(ramp, name):
    mutate, _, lenient = MUTATIONS[name]
    assert found(check(mutate(ramp), lenient=True)) == lenient


def test_every_rule_is_provoked():
    provoked = {rule for _, strict, lenient in MUTATIONS.values() for rule, _ in strict | lenient}
    assert provoked == set(RULES)


def test_gaps_are_sized_by_timestamps(ramp):
    assert check(MUTATIONS["drop-16"][0](ramp)).gaps == [Gap(D, 16)]
    report = check(MUTATIONS["drop-1"][0](ramp), source=CounterRamp())
    assert report.gaps == [Gap(D, 1)]
    assert report.findings == [Finding("gap", D, "1 data packets missing before this one")]


# ---- reference captures ------------------------------------------------------------------

@pytest.mark.parametrize("name", CAPTURES)
def test_reference_capture_lenient(name):
    rate, bits, _ = CAPTURES[name]
    report = check(read_capture(name), lenient=True)
    assert report.findings == []
    assert report.packets == {"data": 100, "context": 10, "version": 2}
    assert report.stream == StreamFormat(rate, bits)
    # No data packet follows a context packet in these extracts.
    assert set(report.not_checked) == LENIENT_SKIPS | {"context-timestamp"}


@pytest.mark.parametrize("name", CAPTURES)
def test_reference_capture_strict(name):
    # What lenient mode lets through, as strict mode sees it.
    report = check(read_capture(name))
    expected = {"packet-type", "gain", "payload-format", "context-first", "change-indicator"}
    if name.startswith("Example3"):
        expected.add("count")
    assert report.rules_failed == expected


def test_example3_misses_six_packets():
    # The count jumps by 7 at packet 51 and the timestamp by 7 packet periods (4472 samples
    # at 500 MS/s): 6 data packets are missing from the capture.
    records = read_capture("Example3_500Msps_8bits.pcapng")
    times = [struct.unpack_from(">IQ", r.payload, 16) for r in records[50:52]]
    step = (times[1][0] - times[0][0]) * fields.PS_PER_S + times[1][1] - times[0][1]
    assert step == 7 * 4472 * fields.PS_PER_S // 500_000_000
    assert [(f.index, f.message) for f in check(records).findings if f.rule == "count"] == \
        [(51, "data count 8, expected 2")]


# ---- command line ------------------------------------------------------------------------

def run(*args):
    return subprocess.run([sys.executable, "-m", "difi_ref.checker", *map(str, args)], cwd=PKG_DIR,
                          capture_output=True, text=True, timeout=60, env={**os.environ, "PYTHONPATH": ""})


def test_cli_reference_capture():
    path = CAPTURE_DIR / "Example3_500Msps_8bits.pcapng"
    lenient = run(path, "--lenient")
    assert lenient.returncode == 0 and lenient.stdout.rstrip().endswith("PASS"), lenient.stdout
    strict = run(path)
    assert strict.returncode == 1 and "context-first: 1 finding" in strict.stdout, strict.stdout


def test_cli_generated_ramp(ramp, tmp_path):
    path = tmp_path / "ramp.pcap"
    with open(path, "wb") as f:
        write_pcap(f, ((p, SEED, 0) for p in ramp))     # record times do not matter here
    assert run(path, "--ramp").returncode == 0
    with open(path, "wb") as f:
        write_pcap(f, ((p, SEED, 0) for p in MUTATIONS["little-endian"][0](ramp)))
    result = run(path, "--ramp")
    assert result.returncode == 1 and f"packet {D}: sample 0 I" in result.stdout, result.stdout


def test_cli_errors(tmp_path):
    (tmp_path / "junk").write_bytes(b"junk" * 10)
    result = run(tmp_path / "junk")
    assert result.returncode == 2 and "not a pcap or pcapng file" in result.stderr
    assert run(tmp_path / "missing").returncode == 2
    assert run(tmp_path / "junk", "--ramp", "--lenient").returncode == 2
    rules = run("--rules")
    assert rules.returncode == 0 and all(rule in rules.stdout for rule in RULES)
