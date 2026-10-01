"""The DIFI Consortium's Construct definitions, used as an external oracle.

third_party/DIFI-Certification is the oracle, not the spec: see Oracle caveats in
docs/difi-streaming-architecture.md for where it and the spec disagree. Bumping the
submodule means re-checking those caveats and then updating ORACLE_COMMIT.
"""
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[4]
ORACLE_DIR = REPO_ROOT / "third_party" / "DIFI-Certification"
# The commit the Oracle caveats were checked at.
ORACLE_COMMIT = "6ee49d1e83c89bc4c35da7b3dd1e52c2a2d0063b"

if not (ORACLE_DIR / "packet_definitions").is_dir():
    raise ImportError(f"{ORACLE_DIR} is empty: run git submodule update --init")
try:
    import construct  # noqa: F401
except ImportError as e:
    raise ImportError("Construct is missing: sudo apt install python3-construct "
                      "(see tests/hil/scripts/setup-host.sh)") from e

sys.path.insert(0, str(ORACLE_DIR))
from packet_definitions.difi_context_v1_2_1 import difi_context_definition  # noqa: E402
from packet_definitions.difi_data_v1_2_1 import difi_data_definition  # noqa: E402


def validate_data(packet: bytes) -> list[str]:
    """Errors the oracle reports for a DIFI v1.2.1 data packet; empty if it accepts it."""
    return difi_data_definition.validate(difi_data_definition.parse(packet))


def validate_context(packet: bytes) -> list[str]:
    """Errors the oracle reports for a DIFI v1.2.1 context packet; empty if it accepts it."""
    return difi_context_definition.validate(difi_context_definition.parse(packet))
