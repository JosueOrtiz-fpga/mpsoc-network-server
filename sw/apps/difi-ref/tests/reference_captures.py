"""The DIFI-Certification captures the tests read.

The three example captures are classic pcap despite their .pcapng names, and hold 100
data packets, then 10 context packets with 2 version packets among them (see Oracle
caveats in docs/difi-streaming-architecture.md). The Wireshark dissector's test
capture is real pcapng, from a pre-standard gr-difi: for the pcapng reader only.
"""
from fractions import Fraction

import oracle
from difi_ref.pcap import read_udp

CAPTURE_DIR = oracle.ORACLE_DIR / "example_pcaps"
# File name: (sample rate in Hz, bits per I or Q item, samples per data packet).
CAPTURES = {
    "Example1_1Msps_8bits.pcapng": (Fraction(1_000_000), 8, 720),
    "Example2_100Msps_12bits.pcapng": (Fraction(100_000_000), 12, 2976),
    "Example3_500Msps_8bits.pcapng": (Fraction(500_000_000), 8, 4472),
}
PCAPNG = oracle.ORACLE_DIR / "wireshark-dissector" / "tests" / "difi-gnuradio-example.pcapng"


def read_capture(name):
    with open(CAPTURE_DIR / name, "rb") as f:
        return list(read_udp(f))
