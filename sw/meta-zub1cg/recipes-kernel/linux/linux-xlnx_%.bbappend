# Board needs on top of the generic ZynqMP kernel (see files/zub1cg.cfg).
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append = " file://zub1cg.cfg"
