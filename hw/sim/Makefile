# xsim testbench for top with the simulation block design (SIM=1).
#
#   make            build the sim BD if needed, compile, elaborate and run
#                   every test in TESTS, one xsim run (and log) per test
#   make TESTS=ctl_init_handshake            run one test
#   make PLUSARGS="A53_DELAY=2"              pass +A53_DELAY=2 to every run
#   make project    rebuild the sim BD and its xsim export only
#   make run WAVES=1  also record all signals to tb_top_<test>.wdb
#   make clean
#
# Prerequisite: Vivado $(VIVADO_VERSION) on PATH (source settings64.sh).
# Normally reached through `make hw-sim` from the repository root.

SIM_DIR   := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
HW_DIR    := $(abspath $(SIM_DIR)/..)
REPO_ROOT := $(abspath $(HW_DIR)/..)

include $(REPO_ROOT)/versions.env

SIM_BD_NAME   ?= sim_mpsco_bd
SIM_BUILD_DIR ?= $(REPO_ROOT)/build/sim
XSIM_DIR      := $(SIM_BUILD_DIR)/export/$(SIM_BD_NAME)/xsim
WAVES         ?= 0
TESTS         ?= bringup ctl_init_handshake
PLUSARGS      ?=

VIVADO       ?= vivado
VIVADO_BATCH := $(VIVADO) -mode batch -notrace

export HW_DIR SIM_BUILD_DIR SIM_BD_NAME VIVADO_VERSION PART BOARD_PART

PROJ_STAMP := $(SIM_BUILD_DIR)/.sim_project.stamp
PROJ_SRCS  := $(HW_DIR)/bd/$(SIM_BD_NAME).tcl $(SIM_DIR)/scripts/create_sim_project.tcl \
              $(HW_DIR)/scripts/common.tcl $(REPO_ROOT)/versions.env

# Compile order: interfaces, then the package that names them, then the
# harness, the design and the testbench.
TB_SRCS  := $(SIM_DIR)/tb/clk_rst_if.sv $(SIM_DIR)/tb/axi4_if.sv $(SIM_DIR)/tb/axis_if.sv \
            $(SIM_DIR)/tb/tb_pkg.sv $(SIM_DIR)/tb/sim_bd_harness.sv
RTL_SRCS := $(HW_DIR)/rtl/top.sv
TOP_SRC  := $(SIM_DIR)/tb/tb_top.sv

.PHONY: all project compile elab run clean check-vivado

all: run

check-vivado:
	@command -v $(VIVADO) >/dev/null 2>&1 && command -v xelab >/dev/null 2>&1 || \
	  { echo "ERROR: Vivado tools not found. Source <Vivado $(VIVADO_VERSION)>/settings64.sh first."; exit 1; }

project: $(PROJ_STAMP)

$(PROJ_STAMP): $(PROJ_SRCS) | check-vivado
	@mkdir -p $(SIM_BUILD_DIR)
	cd $(SIM_BUILD_DIR) && $(VIVADO_BATCH) -log create_sim_project.log -journal create_sim_project.jou \
	  -source $(SIM_DIR)/scripts/create_sim_project.tcl
	@touch $@

# The exported prj files use paths relative to XSIM_DIR, so every step
# runs there and shares its xsim.dir library tree.
compile: $(PROJ_STAMP) | check-vivado
	cd $(XSIM_DIR) && xvlog --relax -prj vlog.prj -log compile_bd_vlog.log
	cd $(XSIM_DIR) && xvhdl --relax -prj vhdl.prj -log compile_bd_vhdl.log
	cd $(XSIM_DIR) && xvlog --sv --relax --work xil_defaultlib -log compile_tb.log \
	  $(TB_SRCS) $(RTL_SRCS) $(TOP_SRC)

elab: compile
	cd $(XSIM_DIR) && xelab --relax --debug typical --timescale 1ns/1ps \
	  $$(sed 's/^/-L /' elab_libs.txt) \
	  --snapshot tb_top xil_defaultlib.tb_top xil_defaultlib.glbl -log elaborate.log

run: elab
	cd $(XSIM_DIR) && printf '%s\n' \
	  $(if $(filter 1,$(WAVES)),'log_wave -recursive *') 'run all' 'quit' > run.tcl
	@cd $(XSIM_DIR) && failed=; for t in $(TESTS); do \
	  xsim tb_top -testplusarg TEST=$$t $(foreach p,$(PLUSARGS),-testplusarg $(p)) \
	    $(if $(filter 1,$(WAVES)),--wdb tb_top_$$t.wdb) --tclbatch run.tcl -log simulate_$$t.log; \
	  grep -q '^TEST PASSED' simulate_$$t.log || failed="$$failed $$t"; \
	done; \
	for t in $(TESTS); do \
	  case " $$failed " in *" $$t "*) r=FAILED;; *) r=passed;; esac; \
	  echo "hw-sim: $$t $$r (log: $(XSIM_DIR)/simulate_$$t.log)"; \
	done; \
	[ -z "$$failed" ]

clean:
	rm -rf $(SIM_BUILD_DIR)
