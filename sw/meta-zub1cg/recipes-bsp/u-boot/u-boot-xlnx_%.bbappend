# Board needs on top of the generic ZynqMP U-Boot (see files/zub1cg-uboot.cfg).
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append = " file://zub1cg-uboot.cfg"
