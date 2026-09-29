# Top-level entry points. Hardware targets delegate to hw/Makefile.
# CI jobs (when set up) call exactly these targets.

.DEFAULT_GOAL := help

HW_MAKE := $(MAKE) --no-print-directory -C hw

.PHONY: help \
        hw-lint hw-sim hw-project hw-bit hw-xsa hw-plpkg hw-wrapper hw-clean \
        platform platform-check sw-image sw-sdk hil clean

help:
	@echo "Hardware (implemented):"
	@echo "  make hw-lint      Verilator lint of own RTL in hw/rtl (BD wrappers excluded)"
	@echo "  make hw-sim       Run testbenches in hw/sim (skipped if none)"
	@echo "  make hw-project   Recreate the throwaway Vivado project under build/hw"
	@echo "  make hw-bit       Synthesis + implementation + bitstream (fails on timing)"
	@echo "  make hw-xsa       Export versioned XSA to out/hw (+ system.xsa link)"
	@echo "  make hw-plpkg     Bitstream -> .bit.bin + device-tree overlay (.dtbo) for FPGA Manager."
	@echo "  make hw-wrapper   Regenerate hw/rtl/<bd>_wrapper.v after BD port changes"
	@echo "  make hw-clean     Remove build/hw and out/hw"
	@echo ""
	@echo "Planned (not implemented yet):"
	@echo "  make platform | platform-check | sw-image | sw-sdk | hil"

hw-lint:    ; @$(HW_MAKE) lint
hw-sim:     ; @$(HW_MAKE) sim
hw-project: ; @$(HW_MAKE) project
hw-bit:     ; @$(HW_MAKE) bit
hw-xsa:     ; @$(HW_MAKE) xsa
hw-wrapper: ; @$(HW_MAKE) wrapper
hw-clean:   ; @$(HW_MAKE) clean

platform platform-sdt platform-machine platform-check sw-image sw-sdk sw-lock sw-shell:
	$(MAKE) -C sw $@

hw-plpkg:
	@$(HW_MAKE) plpkg
	@$(MAKE) -C sw pl-overlay
	@for d in out/hw/pl/*.dtbo; do \
	  [ -f "$${d%.dtbo}.bit.bin" ] || { echo "ERROR: $$d has no matching .bit.bin (XSA and bitstream from different builds?)"; exit 1; }; \
	done; echo "PL package:"; ls -1 out/hw/pl

# ---- HIL bench: JTAG boot + TFTP/NFS netboot (tests/hil/scripts/) ------------
HIL_SCRIPTS := tests/hil/scripts
XSDB ?= xsdb

hil-stage:
	$(HIL_SCRIPTS)/stage-netboot.sh $(if $(WITH_PL),--with-pl) out/sw

jtag-boot:
	@test -f out/hil/boot.scr || { echo "run 'make hil-stage' first"; exit 1; }
	$(XSDB) $(HIL_SCRIPTS)/jtag-boot.tcl out/sw/jtag out/hil/boot.scr
clean: hw-clean
