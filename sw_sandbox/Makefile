HERE  := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

SHELL       := bash
.SHELLFLAGS := -eu -o pipefail -c
MAKEFLAGS   += --warn-undefined-variables

export GIT_TERMINAL_PROMPT := 0


include $(HERE)/versions.env

#---------------------
# Output directories
#---------------------
BUILD := $(HERE)/build
DL:=$(BUILD)/dl
TC:=$(BUILD)/toolchain
SRC:=$(BUILD)/src

REPO := $(abspath $(HERE)/..)
OUT   := $(REPO)/out
HW    := $(OUT)/hw

#---------------------------
# Xilinx install repository
#---------------------------
XILINX_ROOT ?=/tools/Xilinx

#---------------------------
# GNU Tool Chain variables
#---------------------------
#  - names
#  - tarball download locations
#  - (target) timestamp locations
#  - path to binaries
#---------------------------
TOOLCHAINS :=GNU_LINUX GNU_ELF

TC_TARBALLS    := $(TOOLCHAINS:%=$(DL)/%-$(GNU_TOOLCHAIN_TAG).tar.xz)
TC_LINUX_STAMP := $(TC)/GNU_LINUX-$(GNU_TOOLCHAIN_TAG)/.extracted
TC_ELF_STAMP   := $(TC)/GNU_ELF-$(GNU_TOOLCHAIN_TAG)/.extracted
TC_STAMPS      := $(TC_LINUX_STAMP) $(TC_ELF_STAMP)

CROSS_LINUX := $(TC)/GNU_LINUX-$(GNU_TOOLCHAIN_TAG)/bin/aarch64-none-linux-gnu-
CROSS_ELF   := $(TC)/GNU_ELF-$(GNU_TOOLCHAIN_TAG)/bin/aarch64-none-elf-
CROSS_MB    := $(XILINX_ROOT)/$(VITIS_VER)/Vitis/gnu/microblaze/lin/bin/mb-
CROSS_BINS  := $(CROSS_LINUX) $(CROSS_ELF) $(CROSS_MB)

#---------------------------
# Xilinx Source Repos variables
#---------------------------
#  - names
#  - (target) timestamp locations
#---------------------------
REPOS                := XLNX_UBOOT XLNX_LINUX XLNX_EMBD_SW XLNX_TFA

XLNX_UBOOT_STAMP     := $(SRC)/XLNX_UBOOT.cloned
XLNX_LINUX_STAMP     := $(SRC)/XLNX_LINUX.cloned
XLNX_EMBD_SW_STAMP   := $(SRC)/XLNX_EMBD_SW.cloned
XLNX_TFA_STAMP       := $(SRC)/XLNX_TFA.cloned
SRC_STAMPS           := $(XLNX_UBOOT_STAMP) $(XLNX_LINUX_STAMP) \
                        $(XLNX_EMBD_SW_STAMP) $(XLNX_TFA_STAMP)

#---------------------------
# SDT FLow Variables
#---------------------------
XSA  ?= $(REPO)/out/hw/system.xsa

SDT_DIR := $(BUILD)/sdt

#---------------------------
# kas and Yoctco
#---------------------------
KAS_WORK_DIR  ?= $(BUILD)/kas
KAS_BUILD_DIR ?= $(BUILD)/yocto
DL_DIR        ?= $(HOME)/.cache/zub1cg-yocto/downloads
SSTATE_DIR    ?= $(HOME)/.cache/zub1cg-yocto/sstate-cache

KAS_BASE      :=$(HERE)/kas/base.yml
KAS_IMG       :=$(HERE)/kas/image.yml

# overridable variables for debugging ease
KAS_CFG ?= $(KAS_BASE):$(KAS_IMG)

# from versions.env
export KAS_IMAGE_VERSION
export KAS_CONTAINER_IMAGE_DISTRO
#
export KAS_WORK_DIR
export KAS_BUILD_DIR
export DL_DIR
export SSTATE_DIR

# pattern rules
check-url-%:
	@curl -fsSIL -o /dev/null '$($*_URL)' \
	&& echo "OK    $*" \
	|| { echo "FAIL $*  $($*_URL)"; exit 1; }

check-pin-%:
	@want='$($*_HASH)'; \
	if ! got=$$(git ls-remote '$($*_URL)' 'refs/tags/$($*_TAG)' 'refs/tags/$($*_TAG)^{}' | tail -n1 | cut -f1); then \
	  echo "FAIL  $*  cannot query $($*_URL)"; exit 1; \
	fi; \
	if [ "$$got" = "$$want" ]; then \
	  echo "OK    $*  $($*_TAG) -> $$got"; \
	else \
	  echo "FAIL  $*  $($*_TAG): pinned $$want, upstream $${got:-<tag not found>}"; exit 1; \
	fi

check-head-%:
	@want='$($*_HASH)'; \
	got=$$(git -C $(SRC)/$* rev-parse HEAD); \
	if [ "$$got" = "$$want" ]; then \
		echo "OK  $*  $($*_TAG) -> $$got"; \
	else \
		echo "FAIL  $*  $($*_TAG): pinned $$want, HEAD $${got}"; exit 1; \
	fi

check-cc-%:
	@cc='$(CROSS_$*)gcc'; \
	m=$$($$cc -dumpmachine); \
	v=$$($$cc -dumpversion); \
	echo "OK    $*  $$m  gcc $$v"


print-%: ; @echo '$*=$($*)'


# targets
.PHONY: help clean distclean sdt kas-dirs kas-shell kas-lock check-edf-version img-build clean-src clean-tc check check-urls download toolchain sources
.DELETE_ON_ERROR:

.DEFAULT_GOAL := help

help:
	@echo "Test"

check: $(REPOS:%=check-head-%) check-cc-MB check-cc-LINUX check-cc-ELF

check-urls: $(TOOLCHAINS:%=check-url-%) $(REPOS:%=check-pin-%)

download: $(TC_TARBALLS)

toolchain: $(TC_STAMPS)

sources: $(SRC_STAMPS)

clean-src:
	rm -rf $(SRC)

clean-tc:
	rm -rf $(TC)

clean: clean-src clean-tc

distclean: clean
	rm -rf $(BUILD)

sdt: $(XSA)
	$(if $(XSA),,$(error XSA is empty: pass XSA=/path/to/design.xsa))
	rm -rf $(SDT_DIR)
	cd $(BUILD) && sdtgen -xsa $(XSA) -dir $(SDT_DIR)


#-----------------------------------
# GNU tool chain download and extraction
#-----------------------------------

$(DL):
	mkdir -p $@

$(DL)/%-$(GNU_TOOLCHAIN_TAG).tar.xz: | $(DL)
	curl -fL --retry 3 -o '$@.part' '$($*_URL)'
	echo '$($*_SHA256)  $@.part' | sha256sum -c -
	mv '$@.part' '$@'

$(TC)/%-$(GNU_TOOLCHAIN_TAG)/.extracted: $(DL)/%-$(GNU_TOOLCHAIN_TAG).tar.xz
	rm -rf $(@D)
	mkdir -p $(@D)
	tar -xf $< --strip-components=1 -C $(@D)
	touch $@

#-----------------------------------
# Microblaze toolchain check
#-----------------------------------
check-cc-MB: $(CROSS_MB)gcc

$(CROSS_MB)gcc:
	@echo "ERROR: MicroBlaze toolchain not found: $@" >&2
	@echo "       Install Vitis $(VITIS_VER), or point to it: make XILINX_ROOT=/path/to/Xilinx <target>" >&2
	@exit 1

#-----------------------------------
# Xilinx Source Repos cloning
#-----------------------------------
$(SRC):
	mkdir -p $@

$(SRC)/%.cloned: | $(SRC)
	rm -rf $(SRC)/$*
	git clone --depth 1 --branch $($*_TAG) $($*_URL) $(SRC)/$*
	@$(MAKE) --no-print-directory check-head-$*
	touch $@

#-----------------------------------
# XSA check
#-----------------------------------
$(XSA):
	@echo "ERROR: no XSA at $@" >&2
	@echo "       Run 'make hw-xsa' in the repo root, or pass one: make sdt XSA=/path/to/design.xsa" >&2
	@exit 1

#-----------------------------------
# kas
#-----------------------------------
kas-dirs:
	@mkdir -p $(KAS_WORK_DIR)
	@mkdir -p $(KAS_BUILD_DIR)
	@mkdir -p $(DL_DIR)
	@mkdir -p $(SSTATE_DIR)

kas-shell: check-edf-version kas-dirs
	kas-container shell $(KAS_CFG)

kas-lock: check-edf-version kas-dirs
	kas-container lock --update $(KAS_BASE)

check-edf-version:
	@want='rel-v$(EDF_RELEASE)'; \
	got=$$(python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["defaults"]["repos"]["branch"])' \
	       $(KAS_BASE)); \
	if [ "$$got" = "$$want" ]; then \
	  echo "OK    EDF  kas/base.yml -> $$got"; \
	else \
	  echo "FAIL  EDF  kas/base.yml tracks $$got, versions.env wants $$want (EDF_RELEASE)"; exit 1; \
	fi

img-build: check-edf-version kas-dirs
	kas-container build $(KAS_CFG)

