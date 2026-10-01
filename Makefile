# Top-level entry points. Hardware targets delegate to hw/Makefile.
# CI jobs (when set up) call exactly these targets.

.DEFAULT_GOAL := help

HW_MAKE := $(MAKE) --no-print-directory -C hw

.PHONY: help \
        hw-lint hw-sim hw-project hw-bit hw-xsa hw-plpkg hw-wrapper hw-clean \
        platform platform-check sw-image sw-sdk sw-lock sw-shell hil hil-stage jtag-boot ref-test release clean

help:
	@echo "Hardware (implemented):"
	@echo "  make hw-lint      Verilator lint of own RTL in hw/rtl (BD wrappers excluded)"
	@echo "  make hw-sim       Run testbenches in hw/sim (skipped if none)"
	@echo "  make hw-project   Recreate the throwaway Vivado project under build/hw"
	@echo "  make hw-bit       Synthesis + implementation + bitstream (fails on timing)"
	@echo "  make hw-xsa       Export versioned XSA to out/hw (+ system.xsa link)"
	@echo "  make hw-plpkg     Bitstream -> .bit.bin + device-tree overlay (.dtbo); sets out/hw/pl/current"
	@echo "  make hw-wrapper   Regenerate hw/rtl/<bd>_wrapper.v after BD port changes"
	@echo "  make hw-clean     Remove build/hw and out/hw"
	@echo ""
	@echo "Platform and software (delegated to sw/Makefile):"
	@echo "  make platform | platform-check | sw-image | sw-sdk | sw-lock | sw-shell"
	@echo ""
	@echo "HIL bench (tests/hil):"
	@echo "  make hil-stage    Stage out/sw and the PL package for netboot (PL_STEM=<stem> picks another)"
	@echo "  make jtag-boot    Boot the staged build over JTAG (console by hand)"
	@echo "  make hil          hil-stage, JTAG-boot and run the pytest suite (PYTEST_ARGS=...)"
	@echo ""
	@echo "DIFI reference model (sw/apps/difi-ref, host only):"
	@echo "  make ref-test     Run the difi-ref tests against the DIFI-Certification oracle (PYTEST_ARGS=...)"
	@echo ""
	@echo "Release:"
	@echo "  make release      Clean checkout on a v* tag: full build + HIL in a worktree -> /srv/releases/<tag>"

hw-lint:    ; @$(HW_MAKE) lint
hw-sim:     ; @$(HW_MAKE) sim
hw-project: ; @$(HW_MAKE) project
hw-bit:     ; @$(HW_MAKE) bit
hw-xsa:     ; @$(HW_MAKE) xsa
hw-wrapper: ; @$(HW_MAKE) wrapper
hw-clean:   ; @$(HW_MAKE) clean

platform platform-sdt platform-machine platform-check sw-image sw-sdk sw-lock sw-shell:
	$(MAKE) -C sw $@

# Also records the package it produced in out/hw/pl/current, which hil-stage installs.
hw-plpkg:
	@$(HW_MAKE) plpkg
	@$(MAKE) -C sw pl-overlay
	@for d in out/hw/pl/*.dtbo; do \
	  [ -f "$${d%.dtbo}.bit.bin" ] || { echo "ERROR: $$d has no matching .bit.bin (XSA and bitstream from different builds?)"; exit 1; }; \
	done
	@stem=$$($(HW_MAKE) -s stem) \
	  && for f in $$stem.bit.bin $$stem.dtbo; do \
	    [ -f out/hw/pl/$$f ] || { echo "ERROR: no out/hw/pl/$$f after the build"; exit 1; }; \
	  done \
	  && echo $$stem > out/hw/pl/current \
	  && echo "PL package (out/hw/pl/current): $$stem"; ls -1 out/hw/pl

# ---- HIL bench: JTAG boot + TFTP/NFS netboot (tests/hil/scripts/) ------------
HIL_SCRIPTS := tests/hil/scripts
XSDB ?= xsdb
export XSDB

# PL_STEM=<stem> stages another package from out/hw/pl instead of out/hw/pl/current.
hil-stage:
	$(HIL_SCRIPTS)/stage-netboot.sh $(if $(PL_STEM),--pl-stem $(PL_STEM)) out/sw

jtag-boot:
	@test -f out/hil/boot.scr || { echo "run 'make hil-stage' first"; exit 1; }
	$(XSDB) $(HIL_SCRIPTS)/jtag-boot.tcl out/sw/jtag out/hil/boot.scr

# Stage the last sw-image with the PL package (PL_STEM= as for hil-stage), boot it over JTAG and run tests/hil.
# Each run gets out/hil/<build id>/<UTC time>/ (console.log, jtag-boot.log, junit.xml),
# with out/hil/<build id>/latest pointing at it. Needs Vivado's settings64.sh (xsdb)
# and no picocom on the console. PYTEST_ARGS passes options through, e.g. -k pl.
PYTEST ?= python3 -m pytest
hil: hil-stage
	@. out/hil/stage.env && run=out/hil/$$HIL_ID/$$(date -u +%Y%m%dT%H%M%SZ) \
	  && mkdir -p $$run && ln -sfn $$(basename $$run) out/hil/$$HIL_ID/latest \
	  && echo "hil: run directory $$run" \
	  && HIL_RUN_DIR=$(CURDIR)/$$run $(PYTEST) tests/hil --junitxml=$$run/junit.xml $(PYTEST_ARGS)

# ---- DIFI reference model (docs/m1-reference-model.md) -----------------------
# Host only, no board. Needs the DIFI-Certification submodule and the Python
# packages that tests/hil/scripts/setup-host.sh installs.
ORACLE_DIR := third_party/DIFI-Certification
ref-test:
	@test -f $(ORACLE_DIR)/certify_source.py \
	  || { echo "ref-test: $(ORACLE_DIR) is empty: run git submodule update --init"; exit 1; }
	$(PYTEST) sw/apps/difi-ref $(PYTEST_ARGS)

# ---- Release (ci/release.sh) -------------------------------------------------
# Refuses local changes, untracked files and a HEAD without its v* tag; builds the
# tag in build/release/<tag>/ and collects into $HIL_RELEASES/<tag>/ (never
# overwritten). TAG= names the tag explicitly; it must still be HEAD.
release:
	ci/release.sh $(TAG)

clean: hw-clean
