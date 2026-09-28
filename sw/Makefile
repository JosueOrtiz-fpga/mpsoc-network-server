# sw/Makefile - Linux side of the ZUBoard 1CG project
#
#   XSA --(SDTGen)--> platform/sdt --(gen-machine-conf)--> platform/machine
#       --(kas/Yocto, AMD EDF 25.11)--> BOOT.BIN, Image, system.dtb, rootfs, SD image
#
# Called from the top-level Makefile (make -C sw <target>) or directly.
# Targets:
#   platform-sdt      XSA -> platform/sdt            (needs Vivado: SDTGen runs on HSI)
#   platform-machine  platform/sdt -> platform/machine (inside kas)
#   platform          both of the above
#   platform-check    regenerate platform/ and fail if it differs from git
#   sw-image          BOOT.BIN + Linux artifacts into out/sw/
#   sw-sdk            EDF application SDK
#   sw-lock           pin every layer to a commit (writes sw/kas/base.lock.yml)
#   sw-shell          interactive kas/BitBake shell (image configuration)

ROOT := $(abspath $(CURDIR)/..)

# versions.env is plain KEY=VALUE; make keeps whitespace before a trailing
# comment, hence the $(strip).
include $(ROOT)/versions.env
EDF_RELEASE := $(strip $(EDF_RELEASE))
KAS_VERSION := $(strip $(KAS_VERSION))

# ---- inputs -----------------------------------------------------------------
# Newest XSA from make hw-xsa unless given explicitly (XSA=path/to/file.xsa).
XSA           ?= $(shell ls -t $(ROOT)/out/hw/*.xsa 2>/dev/null | head -n1)
BOARD_DTSI    := $(ROOT)/sw/meta-zub1cg/board-dts/zub1cg-board.dtsi
SDT_DIR       := $(ROOT)/platform/sdt

BOOT_MACHINE  := zynqmp-zub1cg-sdt
# ZU1CG has no Mali GPU -> the non-mali common machine.
IMAGE_MACHINE := amd-cortexa53-common
IMAGE         := edf-linux-disk-image
SDK_IMAGE     := meta-edf-app-sdk

OUT_REL       := out/sw
OUT_SW        := $(ROOT)/$(OUT_REL)

# ---- tools ------------------------------------------------------------------
# SDTGen comes with Vivado 2025.2 (<install>/Vivado/bin/sdtgen). Use the same
# environment/container wrapper as hw-xsa, e.g. VIVADO_RUN="ci/containers/vivado-run".
VIVADO_RUN ?=
SDTGEN     ?= sdtgen
export SDTGEN

# kas-container runs the pinned kas image; KAS=kas uses a host install instead.
KAS ?= kas-container
export KAS_IMAGE_VERSION := $(KAS_VERSION)
export KAS_WORK_DIR  ?= $(ROOT)/build/kas
export KAS_BUILD_DIR ?= $(ROOT)/build/yocto
# DL_DIR and SSTATE_DIR: export them (CI: persistent volumes); kas forwards them.

# Path of the repo as seen by commands running inside kas.
ifneq ($(findstring kas-container,$(KAS)),)
REPO_IN := /repo
else
REPO_IN := $(ROOT)
endif

KAS_BOOT  := sw/kas/base.yml:sw/kas/bootbin.yml
KAS_IMAGE := sw/kas/base.yml:sw/kas/image.yml

COLLECT := bash $(REPO_IN)/sw/scripts/collect-artifacts.sh $(REPO_IN)/$(OUT_REL) \
           $(BOOT_MACHINE) $(IMAGE_MACHINE) $(IMAGE)

.PHONY: platform platform-sdt platform-machine platform-check \
        sw-image sw-sdk sw-lock sw-shell check-versions kas-dirs

# ---- sanity -----------------------------------------------------------------
check-versions:
	@grep -q 'branch: rel-v$(EDF_RELEASE)' $(ROOT)/sw/kas/base.yml || { \
	  echo "sw/kas/base.yml does not track rel-v$(EDF_RELEASE) (EDF_RELEASE in versions.env)"; exit 1; }

kas-dirs:
	@mkdir -p $(KAS_WORK_DIR) $(KAS_BUILD_DIR) $(if $(DL_DIR),$(DL_DIR)) $(if $(SSTATE_DIR),$(SSTATE_DIR))

# ---- platform ---------------------------------------------------------------
platform-sdt:
	@test -n "$(XSA)" && test -f "$(XSA)" || { \
	  echo "No XSA found in out/hw/ - run 'make hw-xsa' or pass XSA=<file>"; exit 1; }
	@echo "SDTGen: $(XSA)"
	$(VIVADO_RUN) $(ROOT)/sw/scripts/gen-sdt.sh "$(XSA)" "$(SDT_DIR)" "$(BOARD_DTSI)"

platform-machine: check-versions kas-dirs
	cd $(ROOT) && $(KAS) shell $(KAS_IMAGE) \
	  -c 'bash $(REPO_IN)/sw/scripts/gen-machine.sh $(REPO_IN) $(BOOT_MACHINE)'

platform: platform-sdt platform-machine

platform-check: platform
	@cd $(ROOT) && if [ -n "$$(git status --porcelain -- platform)" ]; then \
	  git status --short -- platform; \
	  git --no-pager diff --stat -- platform; \
	  echo "platform/ differs from the committed copy: review the diff and commit it."; \
	  exit 1; \
	fi
	@echo "platform/ matches the committed copy."

# ---- PL overlay for the runtime PL package (make hw-plpkg) ----------------------
PL_SDT_DIR := $(ROOT)/out/hw/sdt-full
PL_OUT_REL := out/hw/pl

pl-sdt:
	@test -n "$(XSA)" || { echo "ERROR: no XSA in out/hw - run 'make hw-xsa' first"; exit 1; }
	@echo "SDTGen (full, with PL): $(XSA)"
	$(VIVADO_RUN) env PLATFORM_PS_ONLY=0 $(ROOT)/sw/scripts/gen-sdt.sh "$(XSA)" "$(PL_SDT_DIR)" "$(BOARD_DTSI)"

pl-overlay: pl-sdt check-versions kas-dirs
	cd $(ROOT) && $(KAS) shell $(KAS_IMAGE) \
	  -c 'bash $(REPO_IN)/sw/scripts/gen-pl-overlay.sh $(REPO_IN)/out/hw/sdt-full $(REPO_IN)/$(PL_OUT_REL)'

# ---- images -----------------------------------------------------------------
sw-image: check-versions kas-dirs
	cd $(ROOT) && $(KAS) build $(KAS_BOOT)
	cd $(ROOT) && $(KAS) build $(KAS_IMAGE)
	rm -rf $(OUT_SW) && mkdir -p $(OUT_SW)
	cd $(ROOT) && $(KAS) shell $(KAS_IMAGE) -c '$(COLLECT)'
	@{ echo "git: $$(git -C $(ROOT) describe --always --dirty --abbrev=12)"; \
	   echo "built: $$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
	   echo "boot machine: $(BOOT_MACHINE)"; echo "image machine: $(IMAGE_MACHINE)"; \
	   echo "--- versions.env"; cat $(ROOT)/versions.env; } > $(OUT_SW)/manifest.txt
	cd $(ROOT) && $(KAS) dump --lock $(KAS_IMAGE) > $(OUT_SW)/layers.lock.yml
	@echo; echo "Artifacts in $(OUT_SW):"; ls -lR $(OUT_SW)

sw-sdk: check-versions kas-dirs
	cd $(ROOT) && $(KAS) build $(KAS_IMAGE) --target $(SDK_IMAGE)

# Resolve every branch to a commit and write sw/kas/base.lock.yml (commit it).
# kas applies a <config>.lock.yml automatically; base.yml is always first in
# the chain, so one lock file pins both the boot and the image build.
sw-lock: kas-dirs
	cd $(ROOT) && $(KAS) lock --update sw/kas/base.yml

sw-shell: kas-dirs
	cd $(ROOT) && $(KAS) shell $(KAS_IMAGE)
