# sw/scripts/gmc-lib.sh - shared helpers for scripts that run gen-machine-conf.
# Sourced (not executed) by gen-machine.sh and gen-pl-overlay.sh, INSIDE `kas shell`
# with cwd = BitBake build dir.

# Print the path of gen-machine-conf, or fail with a message on stderr.
#
# The EDF repo manifest syncs meta-xilinx with submodules; gen-machine-conf is one
# of them. kas does not init submodules, so do it here: this checks out exactly the
# commit that the pinned meta-xilinx revision records.
gmc_locate() {
  local gmc mx_core mx
  gmc=$(command -v gen-machine-conf || command -v gen-machineconf || true)
  if [ -z "$gmc" ]; then
    [ -f conf/bblayers.conf ] || { echo "gmc_locate: not in a BitBake build dir" >&2; return 1; }
    mx_core=$(grep -oE '[^" ]*/meta-xilinx-core' conf/bblayers.conf | head -n1)
    mx_core=${mx_core//\$\{TOPDIR\}/$PWD}
    [ -n "$mx_core" ] || { echo "gmc_locate: meta-xilinx-core not found in conf/bblayers.conf" >&2; return 1; }
    mx=$(realpath "$(dirname "$mx_core")")
    echo "gmc_locate: initialising submodules in $mx" >&2
    git -c safe.directory='*' -C "$mx" submodule update --init --recursive >&2
    gmc=$(find "$mx" -maxdepth 4 -type f \( -name gen-machine-conf -o -name gen-machineconf \) \
          -perm -u+x | head -n1)
    [ -n "$gmc" ] || { echo "gmc_locate: gen-machine-conf not found under $mx (submodule layout changed?)" >&2; return 1; }
  fi
  echo "gmc_locate: using $gmc" >&2
  echo "$gmc"
}

# gen-machine-conf hardlinks files from the build dir into its Python tempdir.
# Under kas-container /tmp is a different filesystem from the bind-mounted build
# dir (EXDEV / Errno 18), so keep temp files on the build dir's filesystem.
# Uses a dedicated name: BitBake's own TMPDIR is <build>/tmp.
gmc_set_tmpdir() {
  export TMPDIR="$PWD/gmc-tmp"
  mkdir -p "$TMPDIR"
}
