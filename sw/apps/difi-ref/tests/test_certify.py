"""certify_source.py --pcap on a generated capture: iteration 1's exit check.

certify_source.py exits 0 even when the capture fails, so the verdict comes from its
output. It also skips data packets that arrive before any context packet without
counting them, so the compliant counts are checked against what was generated.
"""
import os
import re
import subprocess
import sys

import pytest

import oracle
from conftest import make_packetizer
from difi_ref import pcap

NUM_DATA = 1100


def certify(path, cwd, *extra):
    out = subprocess.run(
        [sys.executable, str(oracle.ORACLE_DIR / "certify_source.py"), "--pcap", str(path),
         "--difi-version", "1.2.1", "--error-log", str(cwd / "errors.txt"), *extra],
        cwd=cwd, env={**os.environ, "MPLBACKEND": "Agg"},     # it writes plots and a summary to cwd
        capture_output=True, text=True, timeout=300).stdout
    counts = {k: int(v) for k, v in re.findall(r"^(\w+_count): (\d+)$", out, re.M)}
    result = re.search(r"^Overall Result: (\w+)$", out, re.M)
    return (result.group(1) if result else None), counts, out


@pytest.fixture(scope="module")
def stream():
    pkt = make_packetizer()
    return pkt.cfg, list(pkt.packets(NUM_DATA))


def write(path, packets):
    with open(path, "wb") as f:
        pcap.write_pcap(f, packets)


def test_generated_capture_passes(stream, tmp_path):
    cfg, packets = stream
    write(tmp_path / "gen.pcap", packets)
    result, counts, out = certify(tmp_path / "gen.pcap", tmp_path,
                                  "--validate-rf-freq", str(cfg.ctx_rf_ref_freq_hz),
                                  "--validate-bandwidth", str(cfg.ctx_bandwidth_hz))
    assert result == "PASS", out
    assert counts["compliant_data_count"] == NUM_DATA
    assert counts["compliant_context_count"] == sum(p.is_context for p in packets)
    assert counts["noncompliant_data_count"] == counts["noncompliant_context_count"] == 0


def test_corrupted_capture_fails(stream, tmp_path):
    # Guards the test above: a wrong OUI in one data packet must turn the verdict to FAIL.
    _, packets = stream
    bad = bytearray(packets[5].data)
    bad[9:12] = b"\x12\x34\x56"
    packets = packets[:5] + [packets[5]._replace(data=bytes(bad))] + packets[6:]
    write(tmp_path / "bad.pcap", packets)
    result, counts, out = certify(tmp_path / "bad.pcap", tmp_path)
    assert result == "FAIL", out
    assert counts["noncompliant_data_count"] == 1
