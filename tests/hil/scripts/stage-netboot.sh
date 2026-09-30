#!/usr/bin/env bash
# tests/hil/scripts/stage-netboot.sh - put a `make sw-image` build where the netboot finds it.
#
#   out/sw/Image, system.dtb   -> $HIL_SRV/<id>/          (TFTP)
#   out/sw/rootfs.tar.gz       -> $HIL_SRV/<id>/rootfs/   (NFS root, extracted as root)
#   tests/hil/scripts/netboot.cmd         -> out/hil/boot.scr        (loaded over JTAG by jtag-boot.tcl)
#   out/hw/pl/<stem>.bit.bin + .dtbo      -> rootfs/lib/firmware/xilinx/$HIL_PL_PKG/, as
#                                            dfx-mgr's default firmware (loaded at boot);
#                                            <stem> is the one in out/hw/pl/current
#                                            (make hw-plpkg) or --pl-stem
#   test login: $HIL_SSH_KEY.pub for $HIL_SSH_USER, no forced password change, sudo
#               without a password (in the staged rootfs only, never in the image)
#
# <id> is the build's `git describe` from out/sw/manifest.txt, so several builds
# can sit side by side. The rootfs is re-extracted on every run, so nothing from
# an earlier boot leaks into the next one. Everything that needs root goes through
# hil-rootfs, which setup-host.sh installs with a password-free sudo rule, so this
# script runs unattended.
#
# Usage: tests/hil/scripts/stage-netboot.sh [--pl-stem <stem>] [out-sw-dir]
set -euo pipefail

die() { echo "hil-stage: ERROR: $*" >&2; exit 1; }
say() { echo "hil-stage: $*"; }

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
# shellcheck source=hil.env
. "$here/hil.env"
helper=/usr/local/sbin/hil-rootfs

pl_stem=
if [ "${1:-}" = --pl-stem ]; then pl_stem=${2:?--pl-stem needs a stem}; shift 2; fi
[ $# -le 1 ] || die "usage: $0 [--pl-stem <stem>] [out-sw-dir]"
sw=$(realpath "${1:-$root/out/sw}")
out_hil="$root/out/hil"
pl_dir="$root/out/hw/pl"

# ---- inputs -----------------------------------------------------------------------
for f in Image system.dtb rootfs.tar.gz manifest.txt SHA256SUMS \
         jtag/pmufw.elf jtag/fsbl.elf jtag/bl31.elf jtag/u-boot.elf jtag/system.dtb; do
  [ -f "$sw/$f" ] || die "missing $sw/$f (run 'make sw-image')"
done
command -v mkimage >/dev/null || die "mkimage not found (Debian/Ubuntu: apt install u-boot-tools)"
[ -d "$HIL_SRV" ] && [ -w "$HIL_SRV" ] \
  || die "$HIL_SRV missing or not writable (one-time host setup in tests/hil/scripts/README.md)"
[ -f "$HIL_SSH_KEY.pub" ] || die "no $HIL_SSH_KEY.pub (run tests/hil/scripts/setup-host.sh)"

# PL package: the last make hw-plpkg, unless --pl-stem (PL_STEM=) names another one.
if [ -z "$pl_stem" ]; then
  [ -f "$pl_dir/current" ] || die "no $pl_dir/current (run 'make hw-plpkg', or pick a package with PL_STEM=)"
  pl_stem=$(cat "$pl_dir/current")
fi
for f in "$pl_stem.bit.bin" "$pl_stem.dtbo"; do
  [ -f "$pl_dir/$f" ] || die "no PL package file $pl_dir/$f (packages: $(cd "$pl_dir" 2>/dev/null && ls *.dtbo 2>/dev/null | sed 's/\.dtbo$//' | tr '\n' ' '))"
done

# The installed helper must be this repo's version, and sudo must allow it without a
# password (-k ignores cached credentials, so a recent sudo elsewhere cannot hide a
# missing rule).
sed "s|@HIL_SRV@|$HIL_SRV|" "$here/hil-rootfs" | cmp -s - "$helper" \
  || die "$helper is missing or differs from tests/hil/scripts/hil-rootfs (run tests/hil/scripts/setup-host.sh)"
sudo -n -k "$helper" check >/dev/null \
  || die "sudo does not allow $helper without a password (run tests/hil/scripts/setup-host.sh)"

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
say "extracting rootfs"
sudo -n "$helper" extract "$id" "$sw/rootfs.tar.gz"

sudo -n "$helper" pl-package "$id" "$HIL_PL_PKG" "$pl_dir/$pl_stem.bit.bin" "$pl_dir/$pl_stem.dtbo"
say "PL package: $pl_stem (dfx-mgr default firmware $HIL_PL_PKG)"

say "test login: $HIL_SSH_USER with $HIL_SSH_KEY"
sudo -n "$helper" seed-login "$id" "$HIL_SSH_USER" "$HIL_SSH_KEY.pub"

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
printf 'HIL_ID=%s\nHIL_DIR=%s\nHIL_PL_STEM=%s\n' "$id" "$dest" "$pl_stem" > "$out_hil/stage.env"

# ---- host sanity (warnings only) ---------------------------------------------------------
grep -qsE "^[[:space:]]*$HIL_SRV([[:space:]]|$)" /etc/exports /etc/exports.d/*.exports \
  || say "WARNING: $HIL_SRV is not in /etc/exports, the NFS root mount will fail"
ip -brief addr 2>/dev/null | grep -q "[[:space:]]$HIL_HOST_IP/" \
  || say "WARNING: no interface has $HIL_HOST_IP (is the HIL link up?)"

cat <<EOF
hil-stage: ready ($dest)
  1. Open the J16 console at 115200 8N1: picocom -b 115200 $HIL_CONSOLE
  2. make jtag-boot
  3. Once booted: ssh -i $HIL_SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR $HIL_SSH_USER@$HIL_BOARD_IP
EOF
