#!/usr/bin/env bash
# XSA -> System Device Tree (platform/sdt) with SDTGen.
#
# SDTGen's Tcl is open source (Xilinx/system-device-tree-xlnx) but it runs on
# Vivado's HSI, so this step needs a Vivado 2025.2 environment.
#
# Usage: gen-sdt.sh <xsa> <out-dir> <board-dtsi>
#   SDTGEN            sdtgen binary (default: sdtgen from PATH)
#   PLATFORM_PS_ONLY  1 (default): drop bitstream and PL device tree, see below
set -euo pipefail

die() { echo "gen-sdt: ERROR: $*" >&2; exit 1; }
[ $# -eq 3 ] || die "usage: $0 <xsa> <out-dir> <board-dtsi>"

xsa=$(realpath "$1")
out=$(realpath -m "$2")
dtsi=$(realpath "$3")
SDTGEN=${SDTGEN:-sdtgen}

[ -f "$xsa" ]  || die "XSA not found: $xsa"
[ -f "$dtsi" ] || die "board dtsi not found: $dtsi"
command -v "$SDTGEN" >/dev/null 2>&1 \
  || die "'$SDTGEN' not found - source <Vivado 2025.2>/settings64.sh or set SDTGEN"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Run from the scratch dir so journal/log files never land in the repo.
# -user_dts copies the board dtsi into the SDT and #includes it from system-top.dts.
( cd "$work" && "$SDTGEN" -xsa "$xsa" -dir "$work/sdt" -user_dts "$dtsi" )

[ -f "$work/sdt/system-top.dts" ] || die "SDTGen produced no system-top.dts"

# ---- normalise ---------------------------------------------------------------
# platform/ is committed and diff-checked in CI. It must change only when the
# PS side changes (MIO, clocks, DDR, PS-PL ports); see "What rebuilds when" in
# the README. The bitstream and PL device tree belong to the PL package
# (make hw-plpkg), which is loaded at runtime through FPGA Manager.
find "$work/sdt" -type f \( -name '*.bit' -o -name '*.mmi' -o -name '*.html' \
  -o -name '*.log' -o -name '*.jou' \) -delete

if [ "${PLATFORM_PS_ONLY:-1}" = 1 ] && [ -f "$work/sdt/pl.dtsi" ]; then
  cat > "$work/sdt/pl.dtsi" <<'EOF'
/*
 * PL content intentionally removed by sw/scripts/gen-sdt.sh (PLATFORM_PS_ONLY=1).
 * The fabric is programmed at runtime via FPGA Manager; its device tree ships
 * as an overlay in the PL package (make hw-plpkg).
 */
EOF
fi

# Scrub host-specific strings (scratch path, XSA file name with its git sha) so
# that platform-check only reports real PS changes. Usually nothing matches:
# grep then exits 1, which must not abort the script under `set -e -o pipefail`.
xsa_base=$(basename "$xsa")
{ grep -rlIF -e "$work" -e "$xsa_base" "$work/sdt" || true; } | while IFS= read -r f; do
  echo "gen-sdt: scrubbing host-specific strings in ${f#"$work"/sdt/}"
  W="$work/sdt" X="$xsa_base" perl -pi -e 's/\Q$ENV{W}\E/./g; s/\Q$ENV{X}\E/system.xsa/g' "$f"
done

# ---- install -----------------------------------------------------------------
rm -rf "$out"
mkdir -p "$(dirname "$out")"
cp -a "$work/sdt" "$out"
echo "gen-sdt: system device tree written to $out"