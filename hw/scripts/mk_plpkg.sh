#!/usr/bin/env bash
# Build the runtime-loadable PL package from a bitstream.
#
#   usage: mk_plpkg.sh <path/to/top.bit> <output dir>
#
# Produces <top>.bit.bin, the format expected by the Linux FPGA Manager
# on Zynq UltraScale+. bootgen ships with Vivado/Vitis (and is also
# available as open source from github.com/Xilinx/bootgen).
#
# TODO: add the matching device-tree overlay (.dtbo), generated from the
# XSA via the SDTGen/Lopper flow once the platform stage exists.

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <bitstream.bit> <output dir>" >&2
    exit 2
fi

bit=$(realpath "$1")
outdir=$2

command -v bootgen >/dev/null 2>&1 || {
    echo "ERROR: bootgen not found; source the Vivado settings64.sh first." >&2
    exit 1
}

name=$(basename "$bit")
mkdir -p "$outdir"
cd "$outdir"

cp "$bit" "$name"
cat > pl.bif <<BIF
all:
{
    [destination_device = pl] ${name}
}
BIF

bootgen -image pl.bif -arch zynqmp -process_bitstream bin -w on

if [[ ! -f "${name}.bin" ]]; then
    echo "ERROR: bootgen did not produce ${name}.bin" >&2
    exit 1
fi

rm -f "$name" pl.bif
echo "PL package: $(realpath "${name}.bin")"
