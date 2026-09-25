# Hardware build. Run from the repo root via `make hw-<target>`,
# or directly with `make -C hw <target>`.
#
# Prerequisites: Vivado $(VIVADO_VERSION) on PATH (source settings64.sh)
# and the ZUBoard board files installed where Vivado can find them.

HW_DIR    := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
REPO_ROOT := $(abspath $(HW_DIR)/..)

include $(REPO_ROOT)/versions.env

# --- Configuration (override on the command line if needed) ----------
PROJ_NAME       ?= zub1cg
BD_NAME         ?= mpsoc_bd
TOP             ?= $(BD_NAME)_wrapper
BUILD_DIR       ?= $(REPO_ROOT)/build/hw
OUT_DIR         ?= $(REPO_ROOT)/out/hw
JOBS            ?= $(shell nproc 2>/dev/null || echo 4)
# Extra board repository; leave empty when board files are in the Vivado
# install or the XHub board store.
BOARD_REPO_PATH ?=
# Set to 1 to keep going on timing failures (local experiments only).
ALLOW_TIMING_FAIL ?= 0

VIVADO       ?= vivado
VIVADO_BATCH := $(VIVADO) -mode batch -notrace

GIT_SHA   := $(shell git -C $(REPO_ROOT) rev-parse --short=10 HEAD 2>/dev/null || echo nogit)
GIT_DIRTY := $(shell git -C $(REPO_ROOT) diff --quiet HEAD -- 2>/dev/null || echo -dirty)

export HW_DIR BUILD_DIR OUT_DIR PROJ_NAME BD_NAME TOP JOBS \
       PART BOARD_PART BOARD_REPO_PATH VIVADO_VERSION ALLOW_TIMING_FAIL

# --- Artifacts -------------------------------------------------------
PROJ_STAMP := $(BUILD_DIR)/.project.stamp
BIT        := $(OUT_DIR)/$(TOP).bit
XSA        := $(OUT_DIR)/$(PROJ_NAME)-$(GIT_SHA)$(GIT_DIRTY)-vivado$(VIVADO_VERSION).xsa
PL_BIN     := $(OUT_DIR)/pl/$(TOP).bit.bin

HW_SRCS := $(wildcard $(HW_DIR)/bd/*.tcl) \
           $(wildcard $(HW_DIR)/rtl/*.v $(HW_DIR)/rtl/*.sv $(HW_DIR)/rtl/*.vhd) \
           $(wildcard $(HW_DIR)/ip/*.tcl $(HW_DIR)/ip/*.xci) \
           $(wildcard $(HW_DIR)/constraints/*.xdc) \
           $(wildcard $(HW_DIR)/scripts/*) \
           $(REPO_ROOT)/versions.env

# Own RTL for linting; generated BD wrappers need Vivado libraries.
LINT_SRCS := $(filter-out %_wrapper.v,$(wildcard $(HW_DIR)/rtl/*.v $(HW_DIR)/rtl/*.sv))

.PHONY: all lint sim project bit xsa plpkg wrapper clean check-vivado

all: xsa plpkg

check-vivado:
	@command -v $(VIVADO) >/dev/null 2>&1 || \
	  { echo "ERROR: '$(VIVADO)' not found. Source <Vivado $(VIVADO_VERSION)>/settings64.sh first."; exit 1; }

lint:
ifeq ($(strip $(LINT_SRCS)),)
	@echo "lint: no own RTL in hw/rtl yet (BD wrappers are excluded), skipping"
else
	verilator --lint-only -Wall -Wno-MULTITOP $(LINT_SRCS)
endif

sim:
	@if [ -f $(HW_DIR)/sim/Makefile ]; then \
	  $(MAKE) -C $(HW_DIR)/sim; \
	else \
	  echo "sim: no testbenches in hw/sim yet, skipping"; \
	fi

project: $(PROJ_STAMP)

$(PROJ_STAMP): $(HW_SRCS) | check-vivado
	@mkdir -p $(BUILD_DIR)
	cd $(BUILD_DIR) && $(VIVADO_BATCH) -log create_project.log -journal create_project.jou \
	  -source $(HW_DIR)/scripts/create_project.tcl
	@touch $@

bit: $(BIT)

$(BIT): $(PROJ_STAMP) | check-vivado
	@mkdir -p $(OUT_DIR)
	cd $(BUILD_DIR) && $(VIVADO_BATCH) -log build.log -journal build.jou \
	  -source $(HW_DIR)/scripts/build.tcl

xsa: $(XSA)

$(XSA): $(BIT) | check-vivado
	cd $(BUILD_DIR) && XSA_FILE=$(XSA) $(VIVADO_BATCH) -log export.log -journal export.jou \
	  -source $(HW_DIR)/scripts/export.tcl
	ln -sfn $(notdir $(XSA)) $(OUT_DIR)/system.xsa
	@echo "XSA: $(XSA)"

plpkg: $(PL_BIN)

$(PL_BIN): $(BIT)
	$(HW_DIR)/scripts/mk_plpkg.sh $(BIT) $(OUT_DIR)/pl

wrapper: $(PROJ_STAMP) | check-vivado
	cd $(BUILD_DIR) && $(VIVADO_BATCH) -log wrapper.log -journal wrapper.jou \
	  -source $(HW_DIR)/scripts/make_wrapper.tcl
	@echo "Review the diff: git diff -- hw/rtl/$(TOP).v"

clean:
	rm -rf $(BUILD_DIR) $(OUT_DIR)
