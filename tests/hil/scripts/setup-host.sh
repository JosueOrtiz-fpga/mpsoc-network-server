#!/usr/bin/env bash
# tests/hil/scripts/setup-host.sh - one-time host setup for the HIL bench
# (JTAG boot + TFTP/NFS netboot). Safe to re-run: every step is idempotent.
#
# Usage: tests/hil/scripts/setup-host.sh [--check]
#   (no args)  do the setup, then run the checks
#   --check    only run the checks (after a reboot, or when a boot misbehaves)
#
# Env: HIL_NIC   wired interface cabled to the board (default: enp2s0)
#      plus everything in hil.env (HIL_HOST_IP, HIL_BOARD_IP, HIL_NETMASK, HIL_SRV)
#
# Written for Ubuntu 22.04 with NetworkManager. Not covered: installing Vivado/Vitis
# (its JTAG cable drivers are only checked), and setting SW2 on the board to JTAG.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=hil.env
. "$here/hil.env"
: "${HIL_NIC:=enp2s0}"
user=${USER:-$(id -un)}

die()  { echo "setup-host: ERROR: $*" >&2; exit 1; }
say()  { echo "setup-host: $*"; }
step() { printf '\n== %s\n' "$*"; }
warns=0
ok()   { printf '  ok    %s\n' "$*"; }
warn() { printf '  WARN  %s\n' "$*"; warns=$((warns + 1)); }

mode=setup
case "${1:-}" in
  "")      ;;
  --check) mode=check ;;
  *)       die "usage: $0 [--check]" ;;
esac

# ---- setup -------------------------------------------------------------------------
setup() {
  # Prerequisites: fail early, before touching anything.
  [ "$(id -u)" -ne 0 ] || die "run as your normal user, not root: /srv/hil ownership and the dialout group are for \$USER"
  command -v apt-get >/dev/null || die "apt-get not found: this script is written for Ubuntu/Debian"
  command -v nmcli   >/dev/null || die "nmcli not found: needs NetworkManager (or set $HIL_HOST_IP/24 on $HIL_NIC by hand and skip step 1)"
  ip link show "$HIL_NIC" >/dev/null 2>&1 || die "no interface '$HIL_NIC' (set HIL_NIC=<name>, see 'ip -br link')"
  [ "$HIL_NETMASK" = 255.255.255.0 ] || die "this script assumes a /24 (HIL_NETMASK=255.255.255.0)"
  sudo -v   # ask for the sudo password once, up front

  step "1/7 Static address $HIL_HOST_IP/24 on $HIL_NIC (NetworkManager profile 'hil')"
  # Point-to-point link to the board: static address, no gateway, no IPv6, so it never
  # becomes the default route and never touches the home network. Autoconnects when the
  # cable is plugged in.
  existing=$(nmcli -g NAME con show)
  if grep -qx hil <<<"$existing"; then
    sudo nmcli con modify hil connection.interface-name "$HIL_NIC" \
      ipv4.method manual ipv4.addresses "$HIL_HOST_IP/24" ipv4.never-default yes ipv6.method disabled
  else
    sudo nmcli con add type ethernet con-name hil ifname "$HIL_NIC" \
      ipv4.method manual ipv4.addresses "$HIL_HOST_IP/24" ipv4.never-default yes ipv6.method disabled
  fi
  sudo nmcli con up hil >/dev/null 2>&1 || say "profile will activate once the link comes up (cable + board powered)"

  step "2/7 dnsmasq config: TFTP only, on $HIL_NIC only"
  # Written before the package is installed, so its first start does not try to serve
  # DNS on port 53 and fail against systemd-resolved (port=0 turns DNS off).
  # bind-dynamic keeps dnsmasq working while the NIC has no address (board off, cable out).
  sudo mkdir -p /etc/dnsmasq.d
  sudo tee /etc/dnsmasq.d/hil.conf >/dev/null <<EOF
# Managed by tests/hil/scripts/setup-host.sh
port=0
interface=$HIL_NIC
bind-dynamic
enable-tftp
tftp-root=$HIL_SRV
EOF

  step "3/7 Packages"
  # dnsmasq + nfs-kernel-server: the TFTP and NFS servers the board boots from.
  # u-boot-tools (mkimage) builds boot.scr, device-tree-compiler (fdtget) checks the DTB,
  # picocom is the serial console for J16.
  sudo apt-get install -y dnsmasq nfs-kernel-server u-boot-tools device-tree-compiler picocom

  step "4/7 Served directory $HIL_SRV"
  # Owned by you, so staging a build only needs sudo for the rootfs extraction.
  sudo install -d -o "$user" -g "$(id -gn)" "$HIL_SRV"

  step "5/7 NFS export to the board only"
  # no_root_squash: the rootfs is owned by root. Limited to the board's address.
  # /etc/exports.d does not exist on a fresh Ubuntu 22.04.
  sudo mkdir -p /etc/exports.d
  echo "$HIL_SRV $HIL_BOARD_IP(rw,no_root_squash,no_subtree_check,sync)" \
    | sudo tee /etc/exports.d/hil.exports >/dev/null
  sudo exportfs -ra

  step "6/7 Enable and (re)start the services"
  sudo systemctl enable dnsmasq >/dev/null 2>&1 || true
  sudo systemctl enable --now nfs-server
  sudo systemctl restart dnsmasq || {
    sudo journalctl -u dnsmasq -n 15 --no-pager || true
    die "dnsmasq failed to start (see the log above)"
  }

  step "7/7 Serial console access"
  # /dev/ttyUSB1 (J16 UART) belongs to the dialout group. Takes effect at the next login.
  sudo usermod -aG dialout "$user"
}

# ---- checks (never fatal, they only report) ----------------------------------------------
verify() {
  step "Checks"
  local out groups_db groups_now t

  # Link and address.
  if [ "$(cat "/sys/class/net/$HIL_NIC/carrier" 2>/dev/null || echo 0)" = 1 ]; then
    ok "$HIL_NIC link up ($(cat "/sys/class/net/$HIL_NIC/speed" 2>/dev/null || echo '?') Mb/s)"
  else
    warn "$HIL_NIC has no carrier: check the cable and that the board is powered (D23 green, SW7 pressed)"
  fi
  out=$(ip -br addr show "$HIL_NIC" 2>/dev/null || true)
  if [[ $out == *"$HIL_HOST_IP/"* ]]; then ok "$HIL_NIC has $HIL_HOST_IP"
  else warn "$HIL_NIC does not have $HIL_HOST_IP (sudo nmcli con up hil)"; fi

  # Servers.
  out=$(sudo ss -ulpn 'sport = :69' 2>/dev/null || true)
  if [[ $out == *dnsmasq* ]]; then ok "dnsmasq serves TFTP on UDP 69"
  else warn "nothing serving TFTP on UDP 69 (systemctl status dnsmasq)"; fi

  out=$(showmount -e localhost 2>/dev/null || true)
  if grep -Eq "^$HIL_SRV[[:space:]]+$HIL_BOARD_IP" <<<"$out"; then ok "NFS exports $HIL_SRV to $HIL_BOARD_IP"
  else warn "$HIL_SRV is not exported to $HIL_BOARD_IP (sudo exportfs -ra; systemctl status nfs-server)"; fi

  out=$(sudo cat /proc/fs/nfsd/versions 2>/dev/null || true)
  if [[ $out == *"+3"* ]]; then ok "NFSv3 enabled (the kernel command line mounts with vers=3)"
  else warn "NFSv3 not enabled on the server ('$out')"; fi

  # A firewall in the way looks like TFTP/NFS timeouts on the board.
  if command -v ufw >/dev/null && [[ $(sudo ufw status 2>/dev/null || true) == *"Status: active"* ]]; then
    warn "ufw is active: sudo ufw allow in on $HIL_NIC"
  else
    ok "no active ufw"
  fi

  # Host tools. xsdb/bootgen only exist after sourcing Vivado's settings64.sh.
  for t in mkimage fdtget picocom; do
    command -v "$t" >/dev/null && ok "$t found" || warn "$t not found (setup step 3)"
  done
  for t in xsdb bootgen; do
    command -v "$t" >/dev/null && ok "$t found" || warn "$t not on PATH: source <Vivado install>/settings64.sh in this shell"
  done

  # JTAG cable and console.
  if compgen -G "/etc/udev/rules.d/52-xilinx-ftdi-usb.rules" >/dev/null \
     || compgen -G "/lib/udev/rules.d/52-xilinx-ftdi-usb.rules" >/dev/null; then
    ok "Xilinx FTDI udev rules installed"
  else
    warn "Xilinx udev rules missing: run install_drivers (as root) from <Vivado>/data/xicom/cable_drivers/lin64/install_script/, then replug J16"
  fi
  if [ -e /dev/ttyUSB1 ]; then ok "console port /dev/ttyUSB1 present"
  else warn "no /dev/ttyUSB1 (J16 connected? other USB serial adapters shift the numbering)"; fi

  groups_db=" $(id -nG "$user") "
  groups_now=" $(id -nG) "
  if [[ $groups_db != *" dialout "* ]]; then
    warn "$user is not in the dialout group (run this script without --check)"
  elif [[ $groups_now != *" dialout "* ]]; then
    warn "dialout is set but this login predates it: log out and back in (or: sg dialout -c 'picocom -b 115200 /dev/ttyUSB1')"
  else
    ok "$user can use the serial console"
  fi

  printf '\n%d warning(s)\n' "$warns"
}

if [ "$mode" = setup ]; then setup; fi
verify
if [ "$mode" = setup ]; then
  say "done. Next: make hil-stage, then make jtag-boot (see tests/hil/scripts/README.md)"
fi