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
	@echo "  make hw-plpkg     Bitstream -> .bit.bin for Linux FPGA Manager"
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
hw-plpkg:   ; @$(HW_MAKE) plpkg
hw-wrapper: ; @$(HW_MAKE) wrapper
hw-clean:   ; @$(HW_MAKE) clean

platform platform-check sw-image sw-sdk hil:
	@echo "$@: not implemented yet (see README, 'Open decisions and TODO')"
	@exit 1

clean: hw-clean
