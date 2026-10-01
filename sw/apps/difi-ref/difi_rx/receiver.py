"""gr-difi's DIFI Source block on a UDP port, recording its samples and tags.

What gr-difi at the pinned commit does, as seen from here:
- Samples come out as raw int16 values in complex64 (+/-32767), not scaled to +/-1.
- It reads samples in its host's byte order (gr-difi issue #19); difi_ref.replay's
  gr_difi_payload() compensates on the sending side.
- Packets with another stream ID are dropped with a warning: pass the stream's ID.
- The UDP socket is bound to every interface: the address argument is ignored for UDP.
- A "pck_n" tag marks the first data packet and every gap in the 4-bit count after it.
- A "context" tag carries each context packet's fields, on the first sample of the
  data packet that follows it.
- The block never ends its stream, so a run ends with stop().
"""
import math
import time
from dataclasses import dataclass, field

import difi
import numpy as np
import pmt
from gnuradio import audio, blocks, gr
from gnuradio import filter as grfilter

UDP = 2                 # gr-difi's socket type: 1 TCP, 2 UDP
THROW_ON_CONTEXT = 0    # context behaviour: raise on a context packet it considers non-compliant
AUDIO_RATE = 48_000
FULL_SCALE = 32768


@dataclass
class Tag:
    offset: int         # sample index
    key: str
    value: object       # the tag's PMT as Python: a dict for "context" and "pck_n"


@dataclass
class Capture:
    samples: np.ndarray                 # complex64 in int16 counts
    tags: list = field(default_factory=list)

    def tagged(self, key: str) -> list:
        return [t for t in self.tags if t.key == key]


def _to_python(p):
    """pmt.to_python, except that an s8vector (gr-difi's "raw" packet) becomes bytes.

    GNU Radio 3.10.1's pmt.to_python cannot convert an s8vector, nor a dict holding one:
    in pmt_to_python.py the uvector table's numpy.byte entry (int8, mapped to u8vector)
    overwrites its int8 entry, so no entry tests for an s8vector. Only dicts and
    s8vectors are handled here, which covers every tag gr-difi emits.
    """
    if pmt.is_dict(p):
        items = pmt.dict_items(p)
        out = {}
        while not pmt.is_null(items):
            item = pmt.car(items)
            out[pmt.symbol_to_string(pmt.car(item))] = _to_python(pmt.cdr(item))
            items = pmt.cdr(items)
        return out
    if pmt.is_s8vector(p):
        return np.array(pmt.s8vector_elements(p), np.int8).tobytes()
    return pmt.to_python(p)


def _tag(t) -> Tag:
    return Tag(t.offset, pmt.symbol_to_string(t.key), _to_python(t.value))


def describe(tag: Tag) -> str:
    """One line for a context or missed-packet tag."""
    v = tag.value
    if tag.key == "context":
        return (f"sample {tag.offset}: context, {v['samp_rate']:.0f} S/s at "
                f"{v['rf_reference_frequency'] / 1e6:.6f} MHz, timestamp {v['full']} s + {v['frac']} ps")
    if tag.key == "pck_n":
        return f"sample {tag.offset}: packet count {v['pck_n']} after a gap (or the first packet)"
    return f"sample {tag.offset}: {tag.key} {v}"


class _TagPrinter(gr.sync_block):
    """Prints context and missed-packet tags as they pass, for listen mode."""

    def __init__(self):
        gr.sync_block.__init__(self, "difi_tag_printer", in_sig=[np.complex64], out_sig=None)

    def work(self, input_items, output_items):
        n = len(input_items[0])
        for t in self.get_tags_in_window(0, 0, n):
            tag = _tag(t)
            if tag.key in ("context", "pck_n"):
                print(describe(tag), flush=True)
        return n


class Receiver:
    """A flowgraph around gr-difi's source: record, listen, or both.

    record keeps every sample and tag in memory for stop() to return; listen plays the
    real part through the sound card at 48 kHz and prints tags as they arrive. The
    socket is bound when this object is built, so packets sent before start() wait
    in the socket buffer.

    If gr-difi raises (a context packet it rejects), its thread ends but the flowgraph
    does not: samples stop arriving, which wait_for() reports as a timeout.
    """

    def __init__(self, port: int, stream_id: int, sample_rate_hz: int = 0, *,
                 record: bool = True, listen: bool = False):
        if not record and not listen:
            raise ValueError("record, listen, or both")
        if listen and sample_rate_hz <= 0:
            raise ValueError("listen needs the stream's sample rate")
        self.tb = gr.top_block("difi_rx")
        self.source = difi.difi_source_cpp_fc32("0.0.0.0", port, UDP, stream_id, 16, THROW_ON_CONTEXT)
        self.sink = None
        if record:
            self.sink = blocks.vector_sink_c()
            self.tb.connect(self.source, self.sink)
        if listen:
            g = math.gcd(AUDIO_RATE, sample_rate_hz)
            self.tb.connect(self.source, blocks.multiply_const_cc(1 / FULL_SCALE), blocks.complex_to_real(),
                            grfilter.rational_resampler_fff(AUDIO_RATE // g, sample_rate_hz // g),
                            audio.sink(AUDIO_RATE, "", True))
            self._printer = _TagPrinter()      # a Python block: keep a reference
            self.tb.connect(self.source, self._printer)

    def start(self) -> None:
        self.tb.start()

    def received(self) -> int:
        """Samples out of gr-difi so far."""
        return (self.sink or self._printer).nitems_read(0)

    def wait_for(self, samples: int, timeout_s: float) -> bool:
        """Wait until gr-difi has output at least this many samples; False on timeout.

        GNU Radio signals nothing here: gr-difi's source never ends its stream, and
        after it raises the flowgraph does not end either. So this polls.
        """
        deadline = time.monotonic() + timeout_s
        while self.received() < samples:
            if time.monotonic() > deadline:
                return False
            time.sleep(0.01)
        return True

    def stop(self) -> Capture:
        self.tb.stop()
        self.tb.wait()
        if self.sink is None:
            return Capture(np.zeros(0, np.complex64))
        return Capture(np.array(self.sink.data(), np.complex64), [_tag(t) for t in self.sink.tags()])
