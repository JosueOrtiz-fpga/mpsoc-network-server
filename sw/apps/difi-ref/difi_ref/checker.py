"""Stream checker: each packet and the stream rules, against DIFI and this design.

Feed packets in arrival order and read the report:

    report = check(packets)                     # or Checker(); feed() each; .report

Each rule in RULES yields a Finding (rule, packet index, message) wherever it fails, and
report.checked counts how often each rule was evaluated, so a rule that never applied
shows up in report.not_checked instead of passing silently.

Strict mode is for this design's stream. Lenient mode is for the DIFI-Certification
reference captures: it checks every context packet in full, but data packets only
for what needs no context (prologue constants, stream ID, the next-data timestamp
of a context packet); it skips version packets and accepts the Gain word, 8- to
16-bit samples and the change indicator on every context packet.

Timing works from the context packet in force: the data packets' period comes from
its sample rate and payload format, so the checker needs no settings of its own. A
context packet that fails its own checks does not change how later data is read.
Iteration 4 adds the committed registers (context values and commit points) and
iteration 5 overflow and the context rate.
"""
import argparse
import sys
from collections import Counter
from dataclasses import dataclass, field
from fractions import Fraction
from typing import Iterable, NamedTuple, Optional

from . import fields
from .config import MAX_SAMPLES_PER_PKT, MIN_SAMPLES_PER_PKT
from .decode import ContextPacket, DataPacket, DecodeError, OtherPacket, decode, iq16, samples_in

RULES = {
    "decode": "the packet splits into a DIFI prologue and body: its size field matches its length",
    "packet-type": "data and context packets only (lenient: version packets are skipped)",
    "header": "header bits 31:20 are 0x18E in data and 0x49E in context packets",
    "class-id": "OUI 0x6A621E, pad bits 0, information class 0, packet class 0 (data) or 1 (context)",
    "stream-id": "every packet carries the first packet's stream ID",
    "timestamp": "the fractional timestamp is below one second",
    "cif0": "CIF0 without the change indicator is 0x7BB98000",
    "ref-point": "the reference point ID is 100, 75, 25 or 15",
    "frequencies": "bandwidth, IF and RF reference frequency, IF band offset and sample rate are "
                   "whole hertz; bandwidth and sample rate are positive",
    "ref-level": "Reference Level's Scaling sub-field (bits 31:16) is 0",
    "gain": "the Gain word is 0, reserved since v1.2.1 (strict)",
    "payload-format": "link-efficient, complex Cartesian, signed fixed point, packing size equal to "
                      "item size, 16-bit (lenient: 4- to 16-bit)",
    "context-first": "the stream starts with a context packet (strict)",
    "change-indicator": "the change indicator is set on the first context packet only (strict)",
    "count": "data and context packets keep separate continuous 4-bit counts, across gaps "
             "sized by timestamps (lenient: context packets only)",
    "context-timestamp": "each context packet carries the timestamp of the next data packet",
    "size": f"{MIN_SAMPLES_PER_PKT} to {MAX_SAMPLES_PER_PKT} samples per data packet (strict)",
    "timestamp-step": "data timestamps step by a whole number of packet periods, within 1 ps (strict)",
    "gap": "no data packet is missing, by timestamps (strict)",
    "samples": "each data packet's samples match the source at its timestamp (strict, given a source)",
}

STEP_TOLERANCE_PS = 1       # the Q32.32 timebase rounds each timestamp (iteration 5)
_DATA_HEADER = fields.data_header(0, 0) >> 20
_CONTEXT_HEADER = fields.context_header(0) >> 20
_FREQUENCIES = ("bandwidth", "if_ref_freq", "rf_ref_freq", "if_band_offset", "sample_rate")


class Finding(NamedTuple):
    rule: str
    index: int          # packet index, in the order fed
    message: str


class Gap(NamedTuple):
    index: int          # the first data packet after the gap
    missing: int        # data packets missing, from the timestamps


class StreamFormat(NamedTuple):
    sample_rate_hz: Fraction
    item_bits: int


@dataclass
class Report:
    lenient: bool
    packets: Counter = field(default_factory=Counter)       # by kind: data, context, version, ...
    findings: list = field(default_factory=list)
    gaps: list = field(default_factory=list)
    checked: Counter = field(default_factory=Counter)       # evaluations per rule
    stream: Optional[StreamFormat] = None                   # from the first usable context packet

    @property
    def ok(self) -> bool:
        return not self.findings

    @property
    def rules_failed(self) -> set:
        return {f.rule for f in self.findings}

    @property
    def not_checked(self) -> list:
        return [r for r in RULES if not self.checked[r]]

    def summary(self, max_per_rule: int = 5) -> str:
        kinds = ", ".join(f"{n} {kind}" for kind, n in sorted(self.packets.items()))
        lines = [f"{sum(self.packets.values())} packets ({kinds or 'none'}), "
                 f"{'lenient' if self.lenient else 'strict'} mode"]
        if self.stream:
            lines.append(f"stream: {_hz(self.stream.sample_rate_hz)} S/s, {self.stream.item_bits}-bit samples")
        if self.gaps:
            lines.append(f"gaps: {len(self.gaps)}, {sum(g.missing for g in self.gaps)} data packets missing")
            lines += [f"  before packet {g.index}: {g.missing} missing" for g in self.gaps[:max_per_rule]]
        if self.not_checked:
            lines.append("not checked: " + ", ".join(self.not_checked))
        by_rule = Counter(f.rule for f in self.findings)
        for rule in RULES:
            if by_rule[rule]:
                lines.append(f"{rule}: {by_rule[rule]} finding{'s' * (by_rule[rule] > 1)}: {RULES[rule]}")
                shown = [f for f in self.findings if f.rule == rule][:max_per_rule]
                lines += [f"  packet {f.index}: {f.message}" for f in shown]
                if by_rule[rule] > len(shown):
                    lines.append(f"  ... and {by_rule[rule] - len(shown)} more")
        lines.append("PASS" if self.ok else f"FAIL: {len(self.findings)} findings")
        return "\n".join(lines)


class _Previous(NamedTuple):
    """The last data packet, as the next one is checked against it."""
    time_ps: int
    count: int
    samples: Optional[int]          # None before any usable context packet
    fmt: Optional[StreamFormat]
    sample_index: Optional[int]


def _hz(value: Fraction) -> str:
    return str(value.numerator) if value.denominator == 1 else f"{float(value):.6f}"


def _time(sec: int, ps: int) -> str:
    return f"{sec}.{ps:012d}" if ps < fields.PS_PER_S else f"{sec} s + {ps} ps"


class Checker:
    """Checks packets fed one at a time; report holds the result so far.

    source, for strict mode, is the sample source the stream should carry (for example
    CounterRamp()), first_sample the index of the first data packet's first sample.
    """

    def __init__(self, lenient: bool = False, source=None, first_sample: int = 0):
        self.lenient = lenient
        self.source = source
        self.first_sample = first_sample
        self.report = Report(lenient)
        self._index = 0
        self._started = False
        self._stream_id = None
        self._format = None             # from the latest usable context packet
        self._contexts = 0
        self._context_count = None
        self._pending = []              # (index, (sec, ps)) of context packets awaiting data
        self._previous = None

    def _check(self, rule: str, index: int, problem: Optional[str]) -> bool:
        """Count one evaluation of rule; problem is None when it holds."""
        self.report.checked[rule] += 1
        if problem is not None:
            self.report.findings.append(Finding(rule, index, problem))
        return problem is None

    def feed(self, data: bytes) -> None:
        i = self._index
        self._index += 1
        try:
            pkt = decode(data)
        except DecodeError as e:
            self.report.packets["undecodable"] += 1
            self._check("decode", i, str(e))
            return
        self._check("decode", i, None)
        if isinstance(pkt, OtherPacket):
            t = pkt.prologue.pkt_type
            if t == fields.PKT_TYPE_VERSION:
                self.report.packets["version"] += 1
                if self.lenient:
                    return
            else:
                self.report.packets["other"] += 1
            self._check("packet-type", i, f"packet type {t:#x}")
            return
        self._check("packet-type", i, None)
        is_context = isinstance(pkt, ContextPacket)
        self.report.packets["context" if is_context else "data"] += 1
        if not self._started:
            self._started = True
            if not self.lenient:
                self._check("context-first", i, None if is_context else "the stream starts with a data packet")
        self._prologue(i, pkt.prologue, is_context)
        if is_context:
            self._context(i, pkt)
        else:
            self._data(i, pkt)

    def _prologue(self, i: int, p, is_context: bool) -> None:
        expected = _CONTEXT_HEADER if is_context else _DATA_HEADER
        self._check("header", i, None if p.header >> 20 == expected
                    else f"header bits 31:20 {p.header >> 20:#05x}, expected {expected:#05x}")
        class_id = fields.class_id_words(fields.PACKET_CLASS_CONTEXT if is_context else fields.PACKET_CLASS_DATA)
        self._check("class-id", i, None if (p.class_id_1, p.class_id_2) == class_id
                    else f"class ID {p.class_id_1:08x} {p.class_id_2:08x}, expected "
                         f"{class_id[0]:08x} {class_id[1]:08x}")
        if self._stream_id is None:
            self._stream_id = p.stream_id
        self._check("stream-id", i, None if p.stream_id == self._stream_id
                    else f"stream ID {p.stream_id:#x}, the stream's is {self._stream_id:#x}")
        self._check("timestamp", i, None if p.ps < fields.PS_PER_S
                    else f"fractional timestamp {p.ps} ps is not below one second")

    def _context(self, i: int, c: ContextPacket) -> None:
        usable = self._check("cif0", i, None if c.cif0 & ~fields.CHANGE_INDICATOR == fields.CIF0
                             else f"CIF0 {c.cif0:#010x}")
        self._check("ref-point", i, None if c.ref_point_id in fields.REF_POINT_IDS
                    else f"reference point ID {c.ref_point_id}")
        bad = [f"{name} {_hz(fields.q44_20_to_hz(getattr(c, name)))} Hz" for name in _FREQUENCIES
               if getattr(c, name) & 0xFFFFF]
        bad += [f"{name} not positive" for name in ("bandwidth", "sample_rate")
                if fields.q44_20_to_hz(getattr(c, name)) <= 0]
        usable &= self._check("frequencies", i, "; ".join(bad) or None)
        self._check("ref-level", i, None if c.ref_level >> 16 == 0
                    else f"Reference Level word {c.ref_level:#010x}: Scaling is not 0")
        if not self.lenient:
            self._check("gain", i, None if c.gain == 0 else f"Gain word {c.gain:#010x}")
        bits = c.item_bits
        allowed = range(4, 17) if self.lenient else (16,)
        dif_form = bits in allowed and (c.payload_format_1, c.payload_format_2) == fields.payload_format_words(bits)
        usable &= self._check("payload-format", i, None if dif_form else
                              f"payload format {c.payload_format_1:08x} {c.payload_format_2:08x}")
        if not self.lenient:
            first = self._contexts == 0
            self._check("change-indicator", i, None if c.changed == first else
                        f"change indicator {'set' if c.changed else 'clear'} on "
                        f"{'the first' if first else 'a later'} context packet")
        if self._context_count is not None:
            expected = (self._context_count + 1) % 16
            self._check("count", i, None if c.prologue.count == expected
                        else f"context count {c.prologue.count}, expected {expected}")
        self._context_count = c.prologue.count
        self._contexts += 1
        if usable:
            self._format = StreamFormat(c.sample_rate_hz, bits)
            if self.report.stream is None:
                self.report.stream = self._format
        self._pending.append((i, (c.prologue.sec, c.prologue.ps)))

    def _data(self, i: int, d: DataPacket) -> None:
        p = d.prologue
        for ci, ts in self._pending:
            self._check("context-timestamp", ci, None if ts == (p.sec, p.ps) else
                        f"context timestamp {_time(*ts)}, next data packet's {_time(p.sec, p.ps)}")
        self._pending.clear()
        if self.lenient:
            return
        fmt = self._format
        samples = samples_in(d.payload, fmt.item_bits) if fmt else None
        if samples is not None:
            self._check("size", i, None if MIN_SAMPLES_PER_PKT <= samples <= MAX_SAMPLES_PER_PKT
                        else f"{samples} samples")
        time_ps = p.sec * fields.PS_PER_S + p.ps
        prev = self._previous
        missing, sample_index = 0, (self.first_sample if prev is None else None)
        if prev is not None and prev.fmt is not None:
            period = Fraction(prev.samples * fields.PS_PER_S) / prev.fmt.sample_rate_hz
            step = time_ps - prev.time_ps
            k = round(step / period)
            if self._check("timestamp-step", i, None if k >= 1 and abs(step - k * period) <= STEP_TOLERANCE_PS
                           else f"timestamp step {step} ps, packet period {_hz(period)} ps"):
                missing = k - 1
                self._check("gap", i, None if not missing else f"{missing} data packets missing before this one")
                if missing:
                    self.report.gaps.append(Gap(i, missing))
            if prev.sample_index is not None:
                sample_index = prev.sample_index + round(step * prev.fmt.sample_rate_hz / fields.PS_PER_S)
        if prev is not None:
            expected = (prev.count + 1 + missing) % 16
            self._check("count", i, None if p.count == expected else
                        f"data count {p.count}, expected {expected}"
                        + (f" after {missing} missing" if missing else ""))
        if self.source is not None and fmt is not None and fmt.item_bits == 16 and sample_index is not None:
            self._check("samples", i, self._compare(d.payload, sample_index))
        self._previous = _Previous(time_ps, p.count, samples, fmt, sample_index)

    def _compare(self, payload: bytes, start: int) -> Optional[str]:
        got = iq16(payload)
        if start < 0:
            return f"timestamp places the first sample at index {start}"
        expected = self.source.samples(start, len(got) // 2)
        if got == expected:
            return None
        k = next(k for k in range(len(got)) if got[k] != expected[k])
        return (f"sample {k // 2} {'IQ'[k % 2]} = {got[k]}, expected {expected[k]} "
                f"(source sample {start + k // 2})")


def check(packets: Iterable, **options) -> Report:
    """Check a whole stream: packets as bytes, packetizer Packets or capture Records."""
    checker = Checker(**options)
    for p in packets:
        checker.feed(p if isinstance(p, (bytes, bytearray)) else p[0])
    return checker.report


def main(argv=None) -> int:
    from .pcap import CaptureError, read_udp
    from .sources import CounterRamp

    p = argparse.ArgumentParser(prog="python3 -m difi_ref.checker",
                                description="Check the DIFI stream in a pcap or pcapng capture. "
                                            "Exits 0 if it passes, 1 on any finding, 2 if unreadable.")
    p.add_argument("capture", nargs="?")
    p.add_argument("--lenient", action="store_true",
                   help="for the DIFI-Certification reference captures: context packets in full, "
                        "data packets' prologues only")
    p.add_argument("--ramp", action="store_true", help="the stream carries the counter ramp: check every sample")
    p.add_argument("--port", type=int, help="only UDP datagrams to this port")
    p.add_argument("--max-per-rule", type=int, default=5, metavar="N", help="findings listed per rule (default 5)")
    p.add_argument("--rules", action="store_true", help="list the rules and exit")
    args = p.parse_args(argv)
    if args.rules:
        print("\n".join(f"{rule:18} {text}" for rule, text in RULES.items()))
        return 0
    if args.capture is None:
        p.error("give a capture to check")
    if args.ramp and args.lenient:
        p.error("--ramp applies to strict mode only")
    try:
        with open(args.capture, "rb") as f:
            report = check(read_udp(f, args.port), lenient=args.lenient,
                           source=CounterRamp() if args.ramp else None)
    except (OSError, CaptureError) as e:
        print(f"{args.capture}: {e}", file=sys.stderr)
        return 2
    print(f"{args.capture}: {report.summary(args.max_per_rule)}")
    return 0 if report.ok else 1


if __name__ == "__main__":
    sys.exit(main())
