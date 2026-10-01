"""pcap writer: DIFI packets as UDP datagrams with synthetic Ethernet and IPv4 headers.

Classic pcap (microsecond timestamps, LINKTYPE_ETHERNET), which tcpdump, Wireshark,
scapy and certify_source.py all read. Standard library only, so R2's board-side
difi-uio can reuse it. Record times are the packets' own DIFI timestamps.
"""
import ipaddress
import struct
from typing import BinaryIO, Iterable

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
