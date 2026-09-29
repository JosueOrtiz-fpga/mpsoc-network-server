#!/usr/bin/env bash
# Collect boot/Linux artifacts from both EDF builds into one directory and
# assemble the SD card image.
#
# Runs INSIDE `kas shell` (cwd = BitBake build dir), called by `make sw-image`.
# Usage: collect-artifacts.sh <out-dir> <boot-machine> <image-machine> <image-recipe>
#
# Output:
#   BOOT.BIN         PMUFW + FSBL + TF-A + U-Boot + system.dtb (board-specific)
#   system.dtb       Linux/U-Boot device tree (same one BOOT.BIN carries)
#   Image            kernel (generic ZynqMP CG/DR build)
#   rootfs.tar.gz    rootfs for NFS root on the HIL bench
#   zub1cg-sd.wic    EDF disk image with BOOT.BIN copied into its ESP (SD1 boot)
#   jtag/            pmufw.elf fsbl.elf bl31.elf u-boot.elf system.dtb (xsdb boot)
#   SHA256SUMS
set -euo pipefail

die() { echo "collect: ERROR: $*" >&2; exit 1; }
[ $# -eq 4 ] || die "usage: $0 <out-dir> <boot-machine> <image-machine> <image-recipe>"
out=$1 bm=$2 im=$3 image=$4

deploy_dir=$(bitbake-getvar --value DEPLOY_DIR 2>/dev/null | tail -n1)
[ -d "$deploy_dir/images" ] || die "cannot resolve DEPLOY_DIR (got '$deploy_dir')"
bdir="$deploy_dir/images/$bm"
idir="$deploy_dir/images/$im"
[ -d "$bdir" ] || die "no deploy dir for boot machine: $bdir"
[ -d "$idir" ] || die "no deploy dir for image machine: $idir"

# pick <dir> <glob>... : first existing match, resolved through symlinks.
# Deploy names differ slightly between recipe versions, hence the alternatives.
pick() {
  local d=$1 p f; shift
  for p in "$@"; do
    for f in "$d"/$p; do
      [ -e "$f" ] && { readlink -f "$f"; return 0; }
    done
  done
  echo "collect: none of [$*] found in $d; it contains:" >&2
  ls -1 "$d" >&2 || true
  return 1
}

mkdir -p "$out/jtag"

# ---- boot firmware (board machine) ----------------------------------------------
cp -L "$(pick "$bdir" boot.bin "BOOT-$bm.bin" 'BOOT*.bin')"                          "$out/BOOT.BIN"
cp -L "$(pick "$bdir" system.dtb "system-$bm.dtb" 'system*.dtb')"                    "$out/system.dtb"
cp -L "$(pick "$bdir" pmufw.elf "pmu-firmware-$bm.elf" 'pmu*firmware*.elf' 'pmufw*.elf')" "$out/jtag/pmufw.elf"
cp -L "$(pick "$bdir" fsbl.elf "fsbl-$bm.elf" '*fsbl*.elf')"                         "$out/jtag/fsbl.elf"
cp -L "$(pick "$bdir" bl31.elf arm-trusted-firmware.elf '*trusted-firmware*.elf')"   "$out/jtag/bl31.elf"
cp -L "$(pick "$bdir" u-boot.elf "u-boot-$bm.elf" 'u-boot*.elf')"                    "$out/jtag/u-boot.elf"
cp "$out/system.dtb" "$out/jtag/system.dtb"   # xsdb loads it at 0x100000 for U-Boot

# ---- Linux (common machine) -------------------------------------------------------
cp -L "$(pick "$idir" Image)" "$out/Image"
cp -L "$(pick "$idir" "$image-$im.rootfs.tar.gz" "$image-$im.tar.gz")" "$out/rootfs.tar.gz"

wic_src=$(pick "$idir" "$image-$im.rootfs.wic" "$image-$im.rootfs.wic.xz" \
  "$image-$im.rootfs.wic.zst" "$image-$im.rootfs.wic.gz" "$image-$im.rootfs.wic.bz2")
sd="$out/zub1cg-sd.wic"
case "$wic_src" in
  *.wic.xz)  xz    -dc "$wic_src" > "$sd" ;;
  *.wic.zst) zstd  -dc "$wic_src" > "$sd" ;;
  *.wic.gz)  gzip  -dc "$wic_src" > "$sd" ;;
  *.wic.bz2) bzip2 -dc "$wic_src" > "$sd" ;;
  *)         cp --sparse=always "$wic_src" "$sd" ;;
esac

# ---- SD image: BOOT.BIN into the ESP (partition 1), as AMD documents for EDF ----
# wic finds mtools through the wic-tools native sysroot (built by image.yml).
# wic doesn't locate the wic-tools native sysroot on its own here, so pass it explicitly.
native=$(bitbake -e wic-tools | sed -n 's/^RECIPE_SYSROOT_NATIVE="\(.*\)"$/\1/p')
[ -d "$native" ] || die "wic-tools native sysroot not found; run: bitbake wic-tools"
wic cp -n "$native" "$out/BOOT.BIN" "$sd:1"
wic ls -n "$native" "$sd:1" | grep -qiE 'boot[[:space:]]+bin' || die "BOOT.BIN missing from the ESP after wic cp"

# ---- checksums --------------------------------------------------------------------
( cd "$out" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS )
echo "collect: artifacts written to $out"
