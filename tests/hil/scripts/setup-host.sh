#!/usr/bin/env bash
# tests/hil/scripts/setup-host.sh - one-time host setup for the HIL bench
# (JTAG boot + TFTP/NFS netboot) and the host tools make release needs beyond Vivado
# and kas (Verilator), plus GNU Radio and gr-difi for make ref-rx-check. Safe to re-run:
# every step is idempotent.
#
# Usage: tests/hil/scripts/setup-host.sh [--check]
#   (no args)  do the setup, then run the checks
#   --check    only run the checks (after a reboot, or when a boot misbehaves)
#
# Env: HIL_NIC   wired interface cabled to the board (default: enp2s0)
#      plus everything in hil.env (HIL_HOST_IP, HIL_BOARD_IP, HIL_NETMASK, HIL_SRV, HIL_RELEASES,
#      HIL_CONSOLE, HIL_SSH_USER, HIL_SSH_KEY)
#
# Written for Ubuntu 22.04 with NetworkManager. Not covered: installing Vivado/Vitis
# (its JTAG cable drivers are only checked), and setting SW2 on the board to JTAG.
# Re-run it after changing hil-rootfs: stage-netboot.sh refuses a stale installed copy.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=hil.env
. "$here/hil.env"
# shellcheck source=../../../versions.env
. "$here/../../../versions.env"
: "${HIL_NIC:=enp2s0}"
user=${USER:-$(id -un)}
helper=/usr/local/sbin/hil-rootfs
sudo_rule=/etc/sudoers.d/zub1cg-hil
verilator_prefix=/opt/verilator-$VERILATOR_VERSION
gr_difi_prefix=/opt/gr-difi-$GR_DIFI_COMMIT

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

  step "1/12 Static address $HIL_HOST_IP/24 on $HIL_NIC (NetworkManager profile 'hil')"
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

  step "2/12 dnsmasq config: TFTP only, on $HIL_NIC only"
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

  step "3/12 Packages"
  # dnsmasq + nfs-kernel-server: the TFTP and NFS servers the board boots from.
  # u-boot-tools (mkimage) builds boot.scr, device-tree-compiler (fdtget) checks the DTB,
  # picocom is the serial console for J16, openssh-client logs in to the board,
  # python3-pytest runs the suite in tests/hil (make hil). python3-construct is the DIFI
  # oracle's packet parser (make ref-test); numpy, scapy, matplotlib and yaml are what
  # DIFI-Certification's certify_source.py imports. GNU Radio 3.10.1 runs the receiver
  # pre-check (make ref-rx-check); its -dev package, pybind11, liborc and cmake build
  # gr-difi (step 5). The rest builds Verilator (step 4) and the models it generates.
  sudo apt-get install -y dnsmasq nfs-kernel-server u-boot-tools device-tree-compiler picocom \
    openssh-client python3-pytest \
    python3-construct python3-numpy python3-scapy python3-matplotlib python3-yaml \
    gnuradio gnuradio-dev pybind11-dev liborc-0.4-dev cmake \
    git autoconf flex bison help2man g++ make perl python3 libfl2 libfl-dev zlib1g-dev

  step "4/12 Verilator $VERILATOR_VERSION in $verilator_prefix (make hw-lint, cocotb)"
  # Built once from the release tag into a prefix of its own and linked into /usr/local/bin.
  # Bumping VERILATOR_VERSION builds the new release next to the old one and relinks.
  if [ -x "$verilator_prefix/bin/verilator" ]; then
    say "already built, kept"
  else
    local src
    src=$(mktemp -d)
    say "building (about 10 minutes; log: $src.log)"
    ( git clone -q --depth 1 --branch "v$VERILATOR_VERSION" https://github.com/verilator/verilator.git "$src" \
        && cd "$src" && autoconf && ./configure --prefix="$verilator_prefix" && make -j"$(nproc)"
    ) > "$src.log" 2>&1 || die "Verilator build failed, see $src.log (sources kept in $src)"
    sudo make -C "$src" install >> "$src.log" 2>&1 || die "Verilator install failed, see $src.log"
    sudo rm -rf "$src" "$src.log"
  fi
  for t in verilator verilator_coverage; do
    sudo ln -sfn "$verilator_prefix/bin/$t" "/usr/local/bin/$t"
  done

  step "5/12 gr-difi $GR_DIFI_COMMIT in $gr_difi_prefix (make ref-rx-check)"
  # Built unmodified from the pinned commit into a prefix of its own, outside the system
  # GNU Radio. Its Python module goes to $gr_difi_prefix/python, which make ref-rx-check
  # puts on PYTHONPATH; RUNPATH points the module at its library, so nothing else needs
  # a path. Bumping GR_DIFI_COMMIT builds the new commit next to the old one.
  if PYTHONPATH="$gr_difi_prefix/python" python3 -c 'import difi' 2>/dev/null; then
    say "already built, kept"
  else
    local src
    src=$(mktemp -d)
    say "building (about a minute; log: $src.log)"
    ( git clone -q https://github.com/DIFI-Consortium/gr-difi.git "$src" \
        && git -C "$src" checkout -q "$GR_DIFI_COMMIT" \
        && cmake -S "$src" -B "$src/build" -DCMAKE_BUILD_TYPE=Release \
             -DCMAKE_INSTALL_PREFIX="$gr_difi_prefix" -DGR_PYTHON_DIR="$gr_difi_prefix/python" \
             -DCMAKE_INSTALL_RPATH="$gr_difi_prefix/lib/$(gcc -print-multiarch)" \
        && make -C "$src/build" -j"$(nproc)"
    ) > "$src.log" 2>&1 || die "gr-difi build failed, see $src.log (sources kept in $src)"
    sudo make -C "$src/build" install >> "$src.log" 2>&1 || die "gr-difi install failed, see $src.log"
    sudo rm -rf "$src" "$src.log"
  fi

  step "6/12 Served directory $HIL_SRV, release directory $HIL_RELEASES"
  # Owned by you, so staging a build only needs root for the rootfs (through hil-rootfs),
  # and make release writes its artifacts without sudo.
  sudo install -d -o "$user" -g "$(id -gn)" "$HIL_SRV" "$HIL_RELEASES"

  step "7/12 $HIL_SRV mounted nosuid,nodev (bind mount onto itself)"
  # hil-rootfs extracts rootfs tarballs as root without a password. Set-uid files in a
  # staged rootfs must work on the board (its sudo is one) but never on this host.
  # The NFS client mounts with its own options, so the board is unaffected.
  if ! findmnt --fstab -n "$HIL_SRV" >/dev/null; then
    echo "$HIL_SRV $HIL_SRV none bind,nosuid,nodev 0 0" | sudo tee -a /etc/fstab >/dev/null
    sudo systemctl daemon-reload
  fi
  findmnt -n "$HIL_SRV" >/dev/null || sudo mount "$HIL_SRV"

  step "8/12 NFS export to the board only"
  # no_root_squash: the rootfs is owned by root. Limited to the board's address.
  # /etc/exports.d does not exist on a fresh Ubuntu 22.04.
  sudo mkdir -p /etc/exports.d
  echo "$HIL_SRV $HIL_BOARD_IP(rw,no_root_squash,no_subtree_check,sync)" \
    | sudo tee /etc/exports.d/hil.exports >/dev/null
  sudo exportfs -ra

  step "9/12 Enable and (re)start the services"
  sudo systemctl enable dnsmasq >/dev/null 2>&1 || true
  sudo systemctl enable --now nfs-server
  sudo systemctl restart dnsmasq || {
    sudo journalctl -u dnsmasq -n 15 --no-pager || true
    die "dnsmasq failed to start (see the log above)"
  }

  step "10/12 Serial console access"
  # The J16 UART belongs to the dialout group. Takes effect at the next login.
  sudo usermod -aG dialout "$user"

  step "11/12 Test login key $HIL_SSH_KEY"
  # Only the public half goes into staged rootfs trees; the private key stays here.
  install -d -m 0700 "$(dirname "$HIL_SSH_KEY")"
  if [ -f "$HIL_SSH_KEY" ]; then
    say "key exists, kept"
  else
    ssh-keygen -q -t ed25519 -N '' -C "zub1cg-hil@$(hostname)" -f "$HIL_SSH_KEY"
  fi

  step "12/12 Staging helper $helper and its sudo rule"
  # Root-owned copy with the served directory filled in; the rule allows this one path
  # without a password, so make hil-stage (and make hil) run unattended.
  local tmp
  tmp=$(mktemp)
  sed "s|@HIL_SRV@|$HIL_SRV|" "$here/hil-rootfs" > "$tmp"
  sudo install -o root -g root -m 0755 "$tmp" "$helper"
  echo "$user ALL=(root) NOPASSWD: $helper" > "$tmp"
  sudo visudo -cqf "$tmp" || { rm -f "$tmp"; die "generated sudo rule fails visudo -c"; }
  sudo install -o root -g root -m 0440 "$tmp" "$sudo_rule"
  rm -f "$tmp"
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

  # Unattended staging.
  out=$(findmnt -n -o OPTIONS "$HIL_SRV" 2>/dev/null || true)
  if [[ ,$out, == *,nosuid,* ]]; then ok "$HIL_SRV mounted nosuid"
  else warn "$HIL_SRV is not a nosuid mount (run this script without --check)"; fi
  if [ -f "$HIL_SSH_KEY" ] && [ -f "$HIL_SSH_KEY.pub" ]; then ok "test login key $HIL_SSH_KEY"
  else warn "no test login key at $HIL_SSH_KEY (run this script without --check)"; fi
  if sed "s|@HIL_SRV@|$HIL_SRV|" "$here/hil-rootfs" | cmp -s - "$helper"; then ok "$helper installed and current"
  else warn "$helper missing or older than tests/hil/scripts/hil-rootfs (run this script without --check)"; fi
  if [ -d "$HIL_RELEASES" ] && [ -w "$HIL_RELEASES" ]; then ok "$HIL_RELEASES writable (make release)"
  else warn "$HIL_RELEASES missing or not writable (run this script without --check)"; fi
  # -k: ignore cached credentials, so this tests the NOPASSWD rule itself.
  if sudo -n -k "$helper" check >/dev/null 2>&1; then ok "sudo allows $helper without a password"
  else warn "no password-free sudo rule for $helper (run this script without --check)"; fi

  # Host tools. xsdb/bootgen only exist after sourcing Vivado's settings64.sh.
  for t in mkimage fdtget picocom ssh; do
    command -v "$t" >/dev/null && ok "$t found" || warn "$t not found (setup step 3)"
  done
  for t in pytest construct numpy scapy matplotlib yaml gnuradio; do
    if python3 -c "import $t" 2>/dev/null; then ok "python3 module $t found"
    else warn "python3 module $t not found (setup step 3)"; fi
  done
  for t in xsdb bootgen; do
    command -v "$t" >/dev/null && ok "$t found" || warn "$t not on PATH: source <Vivado install>/settings64.sh in this shell"
  done
  out=$(verilator --version 2>/dev/null || true)
  if [[ $out == "Verilator $VERILATOR_VERSION "* ]]; then ok "verilator $VERILATOR_VERSION"
  else warn "verilator is '${out:-missing}', versions.env pins $VERILATOR_VERSION (setup step 4)"; fi
  if PYTHONPATH="$gr_difi_prefix/python" python3 -c 'import difi' 2>/dev/null; then ok "gr-difi $GR_DIFI_COMMIT in $gr_difi_prefix"
  else warn "gr-difi $GR_DIFI_COMMIT does not import from $gr_difi_prefix/python (setup step 5)"; fi

  # JTAG cable and console.
  if compgen -G "/etc/udev/rules.d/52-xilinx-ftdi-usb.rules" >/dev/null \
     || compgen -G "/lib/udev/rules.d/52-xilinx-ftdi-usb.rules" >/dev/null; then
    ok "Xilinx FTDI udev rules installed"
  else
    warn "Xilinx udev rules missing: run install_drivers (as root) from <Vivado>/data/xicom/cable_drivers/lin64/install_script/, then replug J16"
  fi
  if [ -e "$HIL_CONSOLE" ]; then ok "console $HIL_CONSOLE present"
  else warn "no $HIL_CONSOLE (J16 connected? see ls -l /dev/serial/by-id/ and HIL_CONSOLE in hil.env)"; fi

  groups_db=" $(id -nG "$user") "
  groups_now=" $(id -nG) "
  if [[ $groups_db != *" dialout "* ]]; then
    warn "$user is not in the dialout group (run this script without --check)"
  elif [[ $groups_now != *" dialout "* ]]; then
    warn "dialout is set but this login predates it: log out and back in (or: sg dialout -c 'picocom -b 115200 $HIL_CONSOLE')"
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
