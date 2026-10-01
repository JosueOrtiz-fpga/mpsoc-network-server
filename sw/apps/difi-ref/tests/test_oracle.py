"""The DIFI-Certification oracle is wired up: pinned, importable, and rejecting bad packets."""
import subprocess

import oracle


def test_oracle_at_pinned_commit():
    head = subprocess.run(["git", "-C", str(oracle.ORACLE_DIR), "rev-parse", "HEAD"],
                          capture_output=True, text=True, check=True).stdout.strip()
    assert head == oracle.ORACLE_COMMIT, \
        "DIFI-Certification moved: re-check the Oracle caveats before updating ORACLE_COMMIT"


def test_oracle_rejects_zeroed_data_packet():
    # A 28-byte prologue of zeros: wrong packet type, no class ID, wrong OUI.
    errors = oracle.validate_data(bytes(28))
    assert any("pktType" in e for e in errors)
    assert any("OUI" in e for e in errors)


def test_oracle_rejects_zeroed_context_packet():
    # 27 words of zeros: wrong packet type and size, nonstandard CIF0.
    errors = oracle.validate_context(bytes(108))
    assert any("pktType" in e for e in errors)
    assert any("27 words" in e for e in errors)
    assert any("CIF0" in e for e in errors)

