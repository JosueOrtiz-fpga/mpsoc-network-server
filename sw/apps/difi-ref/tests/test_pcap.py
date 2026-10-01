"""Capture I/O: the writer read back by scapy, and the reader checked against scapy.

scapy is the independent parser for the Ethernet, IPv4 and UDP layers. The reference
captures cover classic pcap and the dissector's capture pcapng; hand-built files cover
the byte orders, timestamp resolutions and errors they do not.
"""
import io
import struct

import pytest
from scapy.all import IP, UDP, Ether, rdpcap
from scapy.utils import RawPcapNgReader

from difi_ref import pcap
from difi_ref.pcap import CaptureError, Record, read_udp
from reference_captures import CAPTURE_DIR, CAPTURES, PCAPNG, read_capture


@pytest.fixture(scope="module")
def capture(example, tmp_path_factory):
    path = tmp_path_factory.mktemp("pcap") / "example.pcap"
    with open(path, "wb") as f:
        n = pcap.write_pcap(f, example[2])
    return path, n, example[2]


def test_scapy_reads_every_packet(capture):
    path, n, packets = capture
    frames = rdpcap(str(path))
    assert n == len(packets) == len(frames)
    for frame, p in zip(frames, packets):
        assert bytes(frame[UDP].payload) == p.data
        assert frame[IP].src == pcap.DEFAULT_SRC_IP and frame[IP].dst == pcap.DEFAULT_DST_IP
        assert frame[UDP].dport == pcap.DEFAULT_PORT
        assert frame[IP].flags == "DF"


def test_record_times_are_packet_timestamps(capture):
    path, _, packets = capture
    for frame, p in zip(rdpcap(str(path)), packets):
        assert int(frame.time) == p.sec
        assert round((frame.time - p.sec) * 10**6) == p.ps // 10**6


def test_checksums(capture):
    path, _, _ = capture
    for frame in rdpcap(str(path))[:20]:
        # scapy recomputes a checksum that is deleted before rebuilding the frame.
        rebuilt = frame.copy()
        del rebuilt[IP].chksum
        del rebuilt[UDP].chksum
        rebuilt = Ether(bytes(rebuilt))
        assert frame[IP].chksum == rebuilt[IP].chksum
        assert frame[UDP].chksum == rebuilt[UDP].chksum


def test_largest_data_packet_fits_the_mtu():
    pcap.udp_frame(bytes(1472), 0)              # 1500-byte IPv4 packet
    with pytest.raises(ValueError):
        pcap.udp_frame(bytes(1473), 0)


def test_global_header():
    f = io.BytesIO()
    assert pcap.write_pcap(f, []) == 0
    assert f.getvalue() == bytes.fromhex("d4c3b2a1 0200 0400 00000000 00000000 ffff0000 01000000")


# ---- reader: real captures ----------------------------------------------------------------

def test_reads_back_what_it_writes(capture):
    path, n, packets = capture
    with open(path, "rb") as f:
        records = list(read_udp(f))
    assert len(records) == n
    assert all(r == Record(p.data, p.sec, p.ps // 10**6 * 10**6) for r, p in zip(records, packets))


@pytest.mark.parametrize("name", CAPTURES)
def test_reference_captures_agree_with_scapy(name):
    records = read_capture(name)
    frames = rdpcap(str(CAPTURE_DIR / name))
    assert len(records) == len(frames) == 112
    for r, frame in zip(records, frames):
        assert r.payload == bytes(frame[UDP].payload)
        assert r.sec * 10**6 + r.ps // 10**6 == round(frame.time * 10**6)


def test_pcapng_agrees_with_scapy():
    # The only real pcapng at hand: 22,624 packets, nanosecond timestamps.
    with open(PCAPNG, "rb") as f:
        records = list(read_udp(f))
    raw = list(RawPcapNgReader(str(PCAPNG)))
    assert len(records) == len(raw) == 22624
    for r, (frame, meta) in zip(records, raw):
        ticks = meta.tshigh << 32 | meta.tslow
        assert (r.sec, r.ps) == (ticks // meta.tsresol, ticks % meta.tsresol * 10**12 // meta.tsresol)
    for r, (frame, _) in list(zip(records, raw))[:200]:
        assert r.payload == bytes(Ether(frame)[UDP].payload)


# ---- reader: hand-built captures ----------------------------------------------------------

FRAMES = [(pcap.udp_frame(bytes([k]) * (40 + k), k), 1_790_000_000 + k, 250_000 * k) for k in range(3)]


def classic(frames, order="<", ns=False, linktype=pcap.LINKTYPE_ETHERNET):
    """A classic pcap: frames as (frame, seconds, microseconds or nanoseconds)."""
    out = struct.pack(order + "IHHiIII", 0xA1B23C4D if ns else 0xA1B2C3D4, 2, 4, 0, 0, 65535, linktype)
    for frame, sec, frac in frames:
        out += struct.pack(order + "IIII", sec, frac, len(frame), len(frame)) + frame
    return out


def block(order, block_type, body):
    body += bytes(-len(body) % 4)
    return struct.pack(order + "II", block_type, 12 + len(body)) + body + struct.pack(order + "I", 12 + len(body))


def section(order, interfaces, packets):
    """A pcapng section: interfaces as (link type, options), packets as (interface, ticks, frame)."""
    out = block(order, 0x0A0D0D0A, struct.pack(order + "IHHq", 0x1A2B3C4D, 1, 0, -1))
    for linktype, options in interfaces:
        opts = b"".join(struct.pack(order + "HH", code, len(v)) + v + bytes(-len(v) % 4) for code, v in options)
        out += block(order, 1, struct.pack(order + "HHI", linktype, 0, 65535) + opts + bytes(4))
    for iface, ticks, frame in packets:
        out += block(order, 6, struct.pack(order + "IIIII", iface, ticks >> 32, ticks & 0xFFFFFFFF,
                                           len(frame), len(frame)) + frame)
    return out


def records(data, **kwargs):
    return list(read_udp(io.BytesIO(data), **kwargs))


EXPECTED = [Record(bytes([k]) * (40 + k), 1_790_000_000 + k, 250_000 * k * 10**6) for k in range(3)]


@pytest.mark.parametrize("order", ["<", ">"])
def test_classic_byte_orders_and_resolutions(order):
    assert records(classic(FRAMES, order)) == EXPECTED
    in_ns = [(f, s, us * 1000 + 7) for f, s, us in FRAMES]
    assert records(classic(in_ns, order, ns=True)) == [r._replace(ps=r.ps + 7000) for r in EXPECTED]


def test_pcapng_sections_resolutions_and_offsets():
    frame = FRAMES[0][0]
    data = section("<", [(1, []), (1, [(9, bytes([0x94]))])],          # microseconds; 2**-20 s
                   [(0, 5 * 10**6 + 3, frame), (1, (7 << 20) + (1 << 19), frame)])
    data += block("<", 5, bytes(8))                                     # statistics: no packets
    data += section(">", [(1, [(9, bytes([9])), (14, struct.pack(">q", 100))])],   # ns, +100 s
                    [(0, 2 * 10**9 + 1, frame)])
    payload = FRAMES[0][0][42:]
    assert records(data) == [Record(payload, 5, 3 * 10**6), Record(payload, 7, 5 * 10**11),
                             Record(payload, 102, 1000)]


def test_vlan_tags_padding_and_other_frames():
    payload = b"difi"
    frame = pcap.udp_frame(payload, 0)
    tagged = frame[:12] + bytes.fromhex("8100 0064") + frame[12:]
    double = frame[:12] + bytes.fromhex("88a8 0001 8100 0064") + frame[12:]
    padded = frame + bytes(60 - len(frame))                     # Ethernet's minimum frame
    arp = frame[:12] + bytes.fromhex("0806") + bytes(28)
    tcp = bytearray(frame)
    tcp[23] = 6
    other_port = pcap.udp_frame(payload, 0, dst_port=4991)
    frames = [(f, 1, 0) for f in (frame, tagged, double, padded, arp, bytes(tcp), other_port)]
    assert [r.payload for r in records(classic(frames))] == [payload] * 5
    assert len(records(classic(frames), port=pcap.DEFAULT_PORT)) == 4


CAPTURE_ERRORS = {
    "empty": (b"\0\0", "shorter than 4 bytes"),
    "magic": (bytes(24), "not a pcap or pcapng file"),
    "ends-in-record": (classic(FRAMES)[:-1], "capture ends inside record 2"),
    "ends-in-header": (classic(FRAMES)[:30], "inside record 0's header"),
    "link-type": (classic(FRAMES, linktype=113), "link type 113"),
    "snapshot": (classic(FRAMES)[:24] + struct.pack("<IIII", 0, 0, 10, 60) + bytes(10), "truncated to 10 of 60"),
    "fragment": (classic([(pcap.udp_frame(b"x", 0)[:20] + b"\x20\x00" + pcap.udp_frame(b"x", 0)[22:], 0, 0)]),
                 "IPv4 fragment"),
    "byte-order": (block("<", 0x0A0D0D0A, bytes(16)), "byte-order magic"),
    "simple-block": (section("<", [(1, [])], []) + block("<", 3, struct.pack("<I", 4) + bytes(4)), "block type 3"),
    "interface": (section("<", [], [(0, 0, FRAMES[0][0])]), "interface 0, which is not described"),
}


@pytest.mark.parametrize("data, message", CAPTURE_ERRORS.values(), ids=CAPTURE_ERRORS)
def test_capture_errors(data, message):
    with pytest.raises(CaptureError, match=message):
        records(data)
