"""Capture I/O: DIFI packets as UDP datagrams in pcap files, and back.

write_pcap() writes classic pcap (microsecond timestamps, LINKTYPE_ETHERNET) with
synthetic Ethernet and IPv4 headers, which tcpdump, Wireshark, scapy and
certify_source.py all read; record times are the packets' own DIFI timestamps.
read_udp() reads classic pcap and pcapng, whatever the file is called (the reference
captures are classic pcap named .pcapng), and returns the UDP payloads. Standard library
only, so R2's board-side difi-uio can reuse it.
"""
import ipaddress
import struct
from typing import BinaryIO, Iterable, Iterator, NamedTuple

PS_PER_US = 10**6
MTU = 1500                      # no jumbo frames
LINKTYPE_ETHERNET = 1
_ETHERTYPE_IPV4 = 0x0800
_IPPROTO_UDP = 17

DEFAULT_SRC_MAC = bytes.fromhex("020000000001")    # locally administered
DEFAULT_DST_MAC = bytes.fromhex("020000000002")
DEFAULT_SRC_IP = "192.0.2.1"                       # TEST-NET-1 (RFC 5737)
DEFAULT_DST_IP = "192.0.2.2"
DEFAULT_PORT = 50000


def _checksum(data: bytes) -> int:
    """RFC 1071 Internet checksum."""
    if len(data) % 2:
        data += b"\0"
    total = sum(struct.unpack(f">{len(data) // 2}H", data))
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return ~total & 0xFFFF


def udp_frame(payload: bytes, ident: int, src_ip: str = DEFAULT_SRC_IP, dst_ip: str = DEFAULT_DST_IP,
              src_port: int = DEFAULT_PORT, dst_port: int = DEFAULT_PORT,
              src_mac: bytes = DEFAULT_SRC_MAC, dst_mac: bytes = DEFAULT_DST_MAC) -> bytes:
    """One Ethernet frame (no FCS) carrying payload in an IPv4/UDP datagram."""
    src = ipaddress.IPv4Address(src_ip).packed
    dst = ipaddress.IPv4Address(dst_ip).packed
    udp_len = 8 + len(payload)
    ip_len = 20 + udp_len
    if ip_len > MTU:
        raise ValueError(f"{ip_len}-byte IPv4 packet exceeds the {MTU}-byte MTU")
    pseudo = src + dst + struct.pack(">BBH", 0, _IPPROTO_UDP, udp_len)
    udp_sum = _checksum(pseudo + struct.pack(">HHHH", src_port, dst_port, udp_len, 0) + payload) or 0xFFFF
    udp = struct.pack(">HHHH", src_port, dst_port, udp_len, udp_sum)
    # Version 4, IHL 5; don't fragment; TTL 64.
    ip = struct.pack(">BBHHHBBH4s4s", 0x45, 0, ip_len, ident & 0xFFFF, 0x4000, 64, _IPPROTO_UDP, 0, src, dst)
    ip = ip[:10] + struct.pack(">H", _checksum(ip)) + ip[12:]
    return dst_mac + src_mac + struct.pack(">H", _ETHERTYPE_IPV4) + ip + udp + payload


def write_pcap(f: BinaryIO, packets: Iterable[tuple[bytes, int, int]], **addressing) -> int:
    """Write (payload, seconds, picoseconds) tuples as a pcap; returns the packet count.

    addressing passes src_ip, dst_ip, src_port, dst_port, src_mac and dst_mac through
    to udp_frame. difi_ref.packetizer.Packet is such a tuple.
    """
    f.write(struct.pack("<IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, LINKTYPE_ETHERNET))
    n = 0
    for payload, sec, ps in packets:
        frame = udp_frame(payload, n, **addressing)
        f.write(struct.pack("<IIII", sec, ps // PS_PER_US, len(frame), len(frame)))
        f.write(frame)
        n += 1
    return n


# ---- reading ------------------------------------------------------------------------------

class CaptureError(ValueError):
    pass


class Record(NamedTuple):
    """One UDP payload and its capture time; the same shape write_pcap takes."""
    payload: bytes
    sec: int
    ps: int


_ETHERTYPE_VLAN = (0x8100, 0x88A8)      # 802.1Q and 802.1ad tags, stripped
# Classic pcap magic, as read little-endian: (struct byte order, ticks per second).
_PCAP_MAGIC = {0xA1B2C3D4: ("<", 10**6), 0xD4C3B2A1: (">", 10**6),
               0xA1B23C4D: ("<", 10**9), 0x4D3CB2A1: (">", 10**9)}
_PCAPNG_SHB = 0x0A0D0D0A
_PCAPNG_BYTE_ORDER = 0x1A2B3C4D
_PCAPNG_IDB, _PCAPNG_SPB, _PCAPNG_EPB, _PCAPNG_OBSOLETE_PB = 1, 3, 6, 2
_OPT_TSRESOL, _OPT_TSOFFSET = 9, 14


def read_udp(f: BinaryIO, port: int = None) -> Iterator[Record]:
    """The UDP payloads in a pcap or pcapng capture, in file order.

    Frames that are not IPv4/UDP are skipped, as are datagrams to other ports when port
    is given. Raises CaptureError for anything that would lose a datagram silently: a
    truncated record or file, an IPv4 fragment, or a link type other than Ethernet.
    """
    head = f.read(4)
    if len(head) < 4:
        raise CaptureError("not a capture: shorter than 4 bytes")
    magic = struct.unpack("<I", head)[0]
    if magic == _PCAPNG_SHB:
        frames = _pcapng_frames(f, head)
    elif magic in _PCAP_MAGIC:
        frames = _pcap_frames(f, *_PCAP_MAGIC[magic])
    else:
        raise CaptureError(f"not a pcap or pcapng file (magic {head.hex()})")
    for n, (linktype, frame, sec, ps) in enumerate(frames):
        if linktype != LINKTYPE_ETHERNET:
            raise CaptureError(f"record {n}: link type {linktype}; only Ethernet ({LINKTYPE_ETHERNET}) is read")
        try:
            udp = _udp(frame)
        except CaptureError as e:
            raise CaptureError(f"record {n}: {e}") from None
        if udp is not None and (port is None or udp[0] == port):
            yield Record(udp[1], sec, ps)


def _read(f: BinaryIO, size: int, what: str) -> bytes:
    data = f.read(size)
    if len(data) != size:
        raise CaptureError(f"capture ends inside {what}")
    return data


def _ps(frac: int, per_second: int) -> int:
    """A fraction of a second in capture ticks, as picoseconds (rounded down)."""
    return frac * 10**12 // per_second


def _pcap_frames(f: BinaryIO, order: str, per_second: int):
    _, _, _, _, _, linktype = struct.unpack(order + "HHiIII", _read(f, 20, "the pcap header"))
    linktype &= 0xFFFF          # the upper bits can carry FCS information
    n = 0
    while head := f.read(16):
        if len(head) < 16:
            raise CaptureError(f"capture ends inside record {n}'s header")
        sec, frac, caplen, origlen = struct.unpack(order + "IIII", head)
        if caplen < origlen:
            raise CaptureError(f"record {n} truncated to {caplen} of {origlen} bytes (snapshot length)")
        if frac >= per_second:
            raise CaptureError(f"record {n}: fractional time {frac} is not below one second")
        yield linktype, _read(f, caplen, f"record {n}"), sec, _ps(frac, per_second)
        n += 1


def _pcapng_frames(f: BinaryIO, first: bytes):
    order = "<"
    interfaces = []             # (link type, ticks per second, offset in seconds), per section
    n = 0
    while True:
        if first:
            head, first = first + _read(f, 4, "a block header"), None
        else:
            head = f.read(8)
            if not head:
                return
            if len(head) < 8:
                raise CaptureError("capture ends inside a block header")
        block_type = struct.unpack(order + "I", head[:4])[0]
        if block_type == _PCAPNG_SHB:
            bom = _read(f, 4, "a section header")
            order = "<" if struct.unpack("<I", bom)[0] == _PCAPNG_BYTE_ORDER else ">"
            if struct.unpack(order + "I", bom)[0] != _PCAPNG_BYTE_ORDER:
                raise CaptureError(f"section header with byte-order magic {bom.hex()}")
            length = struct.unpack(order + "I", head[4:])[0]
            if length < 28 or length % 4:
                raise CaptureError(f"pcapng section header of {length} bytes")
            body = bom + _read(f, length - 16, "a section header")
            interfaces = []
        else:
            length = struct.unpack(order + "I", head[4:])[0]
            if length < 12 or length % 4:
                raise CaptureError(f"pcapng block of {length} bytes")
            body = _read(f, length - 12, "a block")
        trailer = struct.unpack(order + "I", _read(f, 4, "a block"))[0]
        if trailer != length:
            raise CaptureError(f"pcapng block lengths {length} and {trailer} differ")

        if block_type == _PCAPNG_IDB:
            linktype, _, _ = struct.unpack_from(order + "HHI", body)
            per_second, offset = 10**6, 0
            for code, value in _options(body[8:], order):
                if code == _OPT_TSRESOL:
                    per_second = 2 ** (value[0] & 0x7F) if value[0] & 0x80 else 10 ** value[0]
                elif code == _OPT_TSOFFSET:
                    offset = struct.unpack(order + "q", value[:8])[0]
            interfaces.append((linktype, per_second, offset))
        elif block_type == _PCAPNG_EPB:
            iface, ts_hi, ts_lo, caplen, origlen = struct.unpack_from(order + "IIIII", body)
            if iface >= len(interfaces):
                raise CaptureError(f"packet {n} on interface {iface}, which is not described")
            if caplen < origlen:
                raise CaptureError(f"packet {n} truncated to {caplen} of {origlen} bytes (snapshot length)")
            linktype, per_second, offset = interfaces[iface]
            sec, frac = divmod(ts_hi << 32 | ts_lo, per_second)
            yield linktype, body[20:20 + caplen], sec + offset, _ps(frac, per_second)
            n += 1
        elif block_type in (_PCAPNG_SPB, _PCAPNG_OBSOLETE_PB):
            raise CaptureError(f"pcapng block type {block_type} is not read (use enhanced packet blocks)")
        # Name resolution, statistics, custom and other blocks carry no packets.


def _options(data: bytes, order: str):
    off = 0
    while off + 4 <= len(data):
        code, length = struct.unpack_from(order + "HH", data, off)
        if code == 0:
            return
        yield code, data[off + 4:off + 4 + length]
        off += 4 + (length + 3) // 4 * 4


def _udp(frame: bytes):
    """(destination port, payload) of an IPv4/UDP frame, or None for any other frame."""
    off = 12
    ethertype = struct.unpack_from(">H", frame, off)[0] if len(frame) >= 14 else None
    while ethertype in _ETHERTYPE_VLAN and len(frame) >= off + 6:
        off += 4
        ethertype = struct.unpack_from(">H", frame, off)[0]
    if ethertype != _ETHERTYPE_IPV4:
        return None
    ip = frame[off + 2:]
    if len(ip) < 20 or ip[0] >> 4 != 4:
        raise CaptureError("malformed IPv4 header")
    ihl = 4 * (ip[0] & 0xF)
    total = struct.unpack_from(">H", ip, 2)[0]
    if ip[9] != _IPPROTO_UDP:
        return None
    if struct.unpack_from(">H", ip, 6)[0] & 0x3FFF:    # more fragments, or an offset
        raise CaptureError("IPv4 fragment: fragments are not reassembled")
    if not 20 <= ihl <= total - 8 or total > len(ip):
        raise CaptureError(f"IPv4 lengths: header {ihl}, total {total}, {len(ip)} bytes captured")
    dport, udp_len = struct.unpack_from(">HH", ip, ihl + 2)
    if not 8 <= udp_len <= total - ihl:
        raise CaptureError(f"UDP length {udp_len} in a {total - ihl}-byte IPv4 payload")
    return dport, ip[ihl + 8:ihl + udp_len]
