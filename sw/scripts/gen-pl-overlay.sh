#!/usr/bin/env bash
# Full (PL-inclusive) SDT -> PL device-tree overlay for the Linux FPGA Manager.
#
# Runs INSIDE `kas shell` (cwd = BitBake build dir).
# Usage: gen-pl-overlay.sh <sdt-full-dir> <out-dir>
#
# <sdt-full-dir> is SDTGen output WITHOUT the PS-only blanking
# (PLATFORM_PS_ONLY=0 gen-sdt.sh ...). This script runs gen-machine-conf -g full
# on it, i.e. the exact Lopper step and version AMD pins for this EDF release,
# keeps only the generated pl.dtso and discards everything else. platform/ is
# never touched.
#
# Writes <out-dir>/<stem>.dtso and <out-dir>/<stem>.dtbo, where <stem> is the
# overlay's firmware-name minus ".bit.bin", so the .dtbo sits next to the
# matching <stem>.bit.bin produced by hw/scripts/mk_plpkg.sh.
set -euo pipefail

die() { echo "gen-pl-overlay: ERROR: $*" >&2; exit 1; }
[ $# -eq 2 ] || die "usage: $0 <sdt-full-dir> <out-dir>"

sdt=$(realpath "$1")
outdir=$2
machine=zub1cg-plpkg   # scratch name; avoids clashing with platform/machine's machine

[ -f "$sdt/system-top.dts" ] \
  || die "no $sdt/system-top.dts - run 'PLATFORM_PS_ONLY=0 gen-sdt.sh ...' first"
[ -f "$sdt/pl.dtsi" ] && grep -q 'firmware-name' "$sdt/pl.dtsi" \
  || die "$sdt/pl.dtsi has no PL content - was the SDT generated with PS-only blanking?"
[ -f conf/bblayers.conf ] || die "not in a BitBake build dir - run through 'kas shell'"

# shellcheck source=gmc-lib.sh
source "$(dirname "$(realpath "$0")")/gmc-lib.sh"
gmc=$(gmc_locate)
gmc_set_tmpdir

# ---- run gen-machine-conf in a scratch dir ---------------------------------------
# It writes Lopper's intermediate output to $PWD/output, so run it from the scratch
# dir: nothing lands in the build dir or the repo. mktemp honours TMPDIR, so the
# scratch dir is on the build filesystem too.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/conf"
( cd "$work" && "$gmc" parse-sdt --hw-description "$sdt" -c "$work/conf" -l "$work/gmc.conf" \
    --machine-name "$machine" -g full )

dtso=$(find "$work/conf" -type f -path '*/pl-overlay-full/pl.dtso' | head -n1)
[ -n "$dtso" ] || die "gen-machine-conf produced no pl-overlay-full/pl.dtso (see output above)"

# ---- name the outputs after the bitstream the overlay loads ----------------------
fw=$(sed -n 's/.*firmware-name[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$dtso" | head -n1)
[ -n "$fw" ] || die "no firmware-name in $dtso"
[[ "$fw" == *.bit.bin ]] || die "firmware-name '$fw' does not end in .bit.bin"
stem=${fw%.bit.bin}

# ---- compile ---------------------------------------------------------------------
# -@ keeps symbols and emits __fixups__, so &fpga_full, &amba, &zynqmp_clk ... are
# resolved against the running kernel's base DT when the overlay is applied.
if command -v dtc >/dev/null 2>&1; then
  dtc_cmd=(dtc)
else
  echo "gen-pl-overlay: no dtc on PATH, using dtc-native from the build" >&2
  bitbake dtc-native -c addto_recipe_sysroot >&2
  dtc_cmd=(oe-run-native dtc-native dtc)
fi

mkdir -p "$outdir"
cp "$dtso" "$outdir/$stem.dtso"
"${dtc_cmd[@]}" -@ -q -I dts -O dtb -o "$outdir/$stem.dtbo" "$outdir/$stem.dtso"

[ -s "$outdir/$stem.dtbo" ] || die "dtc did not produce $outdir/$stem.dtbo"
echo "gen-pl-overlay: $(realpath "$outdir/$stem.dtbo") (firmware-name = $fw)"
