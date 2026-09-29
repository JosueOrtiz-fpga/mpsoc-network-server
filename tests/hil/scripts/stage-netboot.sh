#!/usr/bin/env bash
# tests/hil/scripts/stage-netboot.sh - put a `make sw-image` build where the netboot finds it.
#
#   out/sw/Image, system.dtb   -> $HIL_SRV/<id>/          (TFTP)
#   out/sw/rootfs.tar.gz       -> $HIL_SRV/<id>/rootfs/   (NFS root, extracted as root)
#   tests/hil/scripts/netboot.cmd         -> out/hil/boot.scr        (loaded over JTAG by jtag-boot.tcl)
#   --with-pl: out/hw/pl/*.bit.bin + *.dtbo -> rootfs/lib/firmware/
#
# <id> is the build's `git describe` from out/sw/manifest.txt, so several builds
# can sit side by side. The rootfs is re-extracted on every run, so nothing from
# an earlier boot leaks into the next one. Needs sudo for the rootfs only.
#
# Usage: tests/hil/scripts/stage-netboot.sh [--with-pl] [out-sw-dir]
set -euo pipefail

die() { echo "hil-stage: ERROR: $*" >&2; exit 1; }
say() { echo "hil-stage: $*"; }

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
# shellcheck source=hil.env
. "$here/hil.env"

with_pl=0
if [ "${1:-}" = --with-pl ]; then with_pl=1; shift; fi
[ $# -le 1 ] || die "usage: $0 [--with-pl] [out-sw-dir]"
sw=$(realpath "${1:-$root/out/sw}")
out_hil="$root/out/hil"

# ---- inputs -----------------------------------------------------------------------
for f in Image system.dtb rootfs.tar.gz manifest.txt SHA256SUMS \
         jtag/pmufw.elf jtag/fsbl.elf jtag/bl31.elf jtag/u-boot.elf jtag/system.dtb; do
  [ -f "$sw/$f" ] || die "missing $sw/$f (run 'make sw-image')"
done
command -v mkimage >/dev/null || die "mkimage not found (Debian/Ubuntu: apt install u-boot-tools)"
[ -d "$HIL_SRV" ] && [ -w "$HIL_SRV" ] \
  || die "$HIL_SRV missing or not writable (one-time host setup in tests/hil/scripts/README.md)"

# Only the files used here; hashing the multi-GB WIC would just cost time.
( cd "$sw" && grep -E ' \./(Image|system\.dtb|rootfs\.tar\.gz|jtag/[^/]+)$' SHA256SUMS \
    | sha256sum -c --quiet ) || die "checksum mismatch in $sw (partial copy or stale build?)"

id=$(sed -n 's/^git: //p' "$sw/manifest.txt" | head -n1 | tr -c 'A-Za-z0-9._\n-' '_')
[ -n "$id" ] || id=local
dest="$HIL_SRV/$id"
case "$dest" in "$HIL_SRV"/?*) ;; *) die "refusing to use $dest" ;; esac

# Static version of the netboot script's __symbols__ check (followups section 2).
if command -v fdtget >/dev/null; then
  if fdtget -l "$sw/system.dtb" / | grep -qx __symbols__; then
    say "system.dtb has __symbols__"
  else
    say "WARNING: system.dtb has no __symbols__ (not built with -@): PL overlays will not apply"
  fi
fi

# ---- TFTP: kernel + DTB -------------------------------------------------------------
say "staging build $id -> $dest"
mkdir -p "$dest"
install -m 0644 "$sw/Image" "$sw/system.dtb" "$dest/"

# ---- NFS: rootfs --------------------------------------------------------------------
say "extracting rootfs (sudo)"
sudo rm -rf --one-file-system "$dest/rootfs"
sudo mkdir "$dest/rootfs"
sudo tar --numeric-owner -xpzf "$sw/rootfs.tar.gz" -C "$dest/rootfs"

if [ "$with_pl" = 1 ]; then
  shopt -s nullglob
  pl=("$root"/out/hw/pl/*.bit.bin "$root"/out/hw/pl/*.dtbo)
  shopt -u nullglob
  [ ${#pl[@]} -gt 0 ] || die "--with-pl: nothing in out/hw/pl (run 'make hw-plpkg')"
  sudo install -d "$dest/rootfs/lib/firmware"
  sudo install -m 0644 "${pl[@]}" "$dest/rootfs/lib/firmware/"
  say "PL package: ${pl[*]##*/}"
fi

# ---- boot.scr -------------------------------------------------------------------------
mkdir -p "$out_hil"
sed -e "s|@HIL_ID@|$id|g" \
    -e "s|@HIL_HOST_IP@|$HIL_HOST_IP|g" \
    -e "s|@HIL_BOARD_IP@|$HIL_BOARD_IP|g" \
    -e "s|@HIL_NETMASK@|$HIL_NETMASK|g" \
    -e "s|@HIL_SRV@|$HIL_SRV|g" \
    -e "s|@HIL_BOARD_MAC@|$HIL_BOARD_MAC|g" \
    "$here/netboot.cmd" > "$out_hil/netboot.cmd"
! grep -n '@[A-Z_]*@' "$out_hil/netboot.cmd" || die "unfilled placeholder in netboot.cmd"
mkimage -A arm64 -O linux -T script -C none -n "netboot $id" \
  -d "$out_hil/netboot.cmd" "$out_hil/boot.scr" >/dev/null
install -m 0644 "$out_hil/boot.scr" "$dest/boot.scr"   # reference copy next to the build
printf 'HIL_ID=%s\nHIL_DIR=%s\n' "$id" "$dest" > "$out_hil/stage.env"

# ---- host sanity (warnings only) ---------------------------------------------------------
grep -qsE "^[[:space:]]*$HIL_SRV([[:space:]]|$)" /etc/exports /etc/exports.d/*.exports \
  || say "WARNING: $HIL_SRV is not in /etc/exports, the NFS root mount will fail"
ip -brief addr 2>/dev/null | grep -q "[[:space:]]$HIL_HOST_IP/" \
  || say "WARNING: no interface has $HIL_HOST_IP (is the HIL link up?)"

cat <<EOF
hil-stage: ready ($dest)
  1. Open the J16 console at 115200 8N1 (usually /dev/ttyUSB1), e.g.: picocom -b 115200 /dev/ttyUSB1
  2. make jtag-boot
EOF
