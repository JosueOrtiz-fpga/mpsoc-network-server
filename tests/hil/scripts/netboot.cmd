# tests/hil/scripts/netboot.cmd - U-Boot netboot script for the HIL bench.
#
# Template: tests/hil/scripts/stage-netboot.sh fills in the placeholders and wraps the
# result with mkimage into out/hil/boot.scr. jtag-boot.tcl loads that image
# into DDR at 0x20000000; if autoboot does not run it, type:
#   source 0x20000000
#
# Kernel and DTB over TFTP, rootfs over NFS, all from @HIL_SRV@/@HIL_ID@/.
# The Linux DTB is system.dtb, the same tree U-Boot runs on: EDF hands the
# board device tree to the generic amd-cortexa53-common kernel.

echo "netboot: build @HIL_ID@ from @HIL_HOST_IP@"

setenv serverip @HIL_HOST_IP@
setenv ipaddr   @HIL_BOARD_IP@
setenv netmask  @HIL_NETMASK@
# U-Boot may already have picked a random MAC; only set one if it has none.
env exists ethaddr || setenv ethaddr @HIL_BOARD_MAC@

# Fixed low addresses (the ones meta-xilinx's boot.scr uses on ZynqMP), so the
# script does not depend on the U-Boot environment layout. All inside 1 GB DDR.
setenv hil_faddr 0x00100000
setenv hil_kaddr 0x00200000

tftpboot ${hil_kaddr} @HIL_ID@/Image      || exit
tftpboot ${hil_faddr} @HIL_ID@/system.dtb || exit

# The PL overlay needs labels from the base
# DTB, so it must carry __symbols__ (dtc -@). Warn only; Linux still boots.
fdt addr ${hil_faddr}
if fdt get value hil_sym /__symbols__ amba; then
  echo "netboot: system.dtb has __symbols__"
else
  echo "netboot: WARNING: system.dtb has no __symbols__/amba, PL overlays will not apply"
fi

setenv bootargs "console=ttyPS0,115200 earlycon root=/dev/nfs rw nfsroot=@HIL_HOST_IP@:@HIL_SRV@/@HIL_ID@/rootfs,vers=3,tcp ip=@HIL_BOARD_IP@::@HIL_HOST_IP@:@HIL_NETMASK@:zub1cg::off rootwait"
booti ${hil_kaddr} - ${hil_faddr}

echo "netboot: booti returned: kernel Image or DTB rejected"
