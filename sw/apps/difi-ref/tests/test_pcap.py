"""pcap writer, read back by scapy: an independent parser for the Ethernet, IPv4 and UDP layers."""
import io

import pytest
from scapy.all import IP, UDP, Ether, rdpcap

from difi_ref import pcap


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
