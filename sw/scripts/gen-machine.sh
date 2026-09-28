#!/usr/bin/env bash
# platform/sdt -> platform/machine/conf (Yocto machine + multiconfigs) with gen-machine-conf.
#
# Runs INSIDE `kas shell` (cwd = BitBake build dir), called by `make platform-machine`.
# Usage: gen-machine.sh <repo-root> <machine-name>
#   GMC_PL_OVERLAY  value for gen-machine-conf -g (default: full = PL loaded at
#                   runtime, no bitstream in BOOT.BIN); empty to omit -g.
set -euo pipefail

die() { echo "gen-machine: ERROR: $*" >&2; exit 1; }
[ $# -eq 2 ] || die "usage: $0 <repo-root> <machine-name>"

repo=$(realpath "$1")
machine=$2
sdt="$repo/platform/sdt"
layer="$repo/platform/machine"
pl_overlay=${GMC_PL_OVERLAY-full}

[ -f "$sdt/system-top.dts" ]   || die "no $sdt/system-top.dts - run 'make platform-sdt' first"
[ -f "$layer/conf/layer.conf" ] || die "missing $layer/conf/layer.conf"
[ -f conf/bblayers.conf ]       || die "not in a BitBake build dir - run through 'kas shell'"

# shellcheck source=gmc-lib.sh
source "$(dirname "$(realpath "$0")")/gmc-lib.sh"
gmc_set_tmpdir
gmc=$(gmc_locate)

# ---- generate into a scratch dir ------------------------------------------------
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/conf"
: > "$work/gmc.conf"      # receives what gen-machine-conf would add to local.conf

args=(parse-sdt --hw-description "$sdt" -c "$work/conf" -l "$work/gmc.conf"
      --machine-name "$machine")
[ -n "$pl_overlay" ] && args+=(-g "$pl_overlay")
"$gmc" "${args[@]}"

[ -f "$work/conf/machine/$machine.conf" ] \
  || die "expected $work/conf/machine/$machine.conf was not generated (see output above)"

# local.conf fragment: keep BBMULTICONFIG & co., drop MACHINE (kas sets MACHINE per
# build: the boot machine for BOOT.BIN, amd-cortexa53-common for the disk image).
sed -i -E '/^[[:space:]]*MACHINE[[:space:]]*[?:]*=/d' "$work/gmc.conf"
mv "$work/gmc.conf" "$work/conf/zub1cg-gmc.conf"
rm -f "$work/conf/layer.conf"   # never let the generator replace ours

# ---- make it relocatable --------------------------------------------------------
# Absolute paths differ between a dev checkout, kas-container (/repo) and CI.
# layer.conf defines ZUB1CG_MACHINE_LAYER and ZUB1CG_SDT_DIR from LAYERDIR.
while IFS= read -r -d '' f; do
  grep -qI . "$f" || continue   # skip binaries
  WORK="$work/conf" SDT="$sdt" LAYER="$layer" perl -pi -e '
    s/\Q$ENV{WORK}\E/\${ZUB1CG_MACHINE_LAYER}\/conf/g;
    s/\Q$ENV{SDT}\E/\${ZUB1CG_SDT_DIR}/g;
    s/\Q$ENV{LAYER}\E/\${ZUB1CG_MACHINE_LAYER}/g;' "$f"
done < <(find "$work/conf" -type f -print0)

# Fail loudly on anything that would only work on this host or in build/conf.
leftover=$(grep -rnIF -e "$work" -e "$repo" "$work/conf" || true)
[ -z "$leftover" ] || { echo "$leftover" >&2; die "generated files still contain host paths"; }
topdir=$(grep -rnIF '${TOPDIR}/conf/' "$work/conf" || true)
[ -z "$topdir" ] || { echo "$topdir" >&2; die "generated files expect content in the build conf/ dir"; }

# ---- install ---------------------------------------------------------------------
find "$layer/conf" -mindepth 1 -maxdepth 1 ! -name layer.conf -exec rm -rf {} +
cp -a "$work/conf/." "$layer/conf/"

echo "gen-machine: machine '$machine' written to platform/machine/conf:"
( cd "$layer" && find conf -type f | sort )
