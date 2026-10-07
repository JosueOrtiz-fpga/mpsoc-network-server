#
## Tool Chains and Xilinx Repos

Cross-toolchain name anatomy:
```
  aarch64  -  none  -  linux  -  gnu
  ───┬───    ──┬──    ──┬──    ─┬─
     │         │        │       └─ ABI / C library: how the produced programs talk to the
     │         │        │          library underneath (gnu = glibc)
     │         │        └───────── OS: what the produced programs expect below them
     │         │                   (linux = Linux system calls are available)
     │         └────────────────── vendor: who packaged the toolchain. Mostly cosmetic
     │                             ("none", "pc", "xilinx", "unknown", or left out entirely)
     └──────────────────────────── arch: which CPU instruction set to emit
```

arch-vendor-os-libc. It describes where the output runs. -elf means bare metal. Freestanding code (kernel, U-Boot, TF-A) only depends on the arch, so either aarch64 toolchain builds it. Userspace depends on the whole name.

|Name|Read as|Produces programs that|
|-|-|-|
|aarch64-none-linux-gnu|Arm 64-bit, Linux, glibc|run as normal programs on Linux on the A53|
|aarch64-linux-gnu|same, vendor left out|same. This is Ubuntu's and Vitis's name for it.|
|aarch64-none-elf|Arm 64-bit, no OS, output format ELF|run directly on the hardware with nothing underneath|
|microblazeel-xilinx-elf|MicroBlaze little-endian, Xilinx, no OS|run directly on the PMU|

## Vivado SDT Flow (sdtgen)
Device tree: a description of hardware for software that can't discover it. We covered it in the first conversation.
System Device Tree (SDT): a device tree for the whole chip: all CPUs (A53s, R5s, PMU), every peripheral, and which CPU can see what. A normal device tree only describes what Linux sees. Tools (lopper, gen-machine-conf) derive the Linux device tree, the FSBL configuration and the PMUFW configuration from the SDT.
sdtgen: reads the XSA, and writes the SDT plus psu_init.c/h.

### Device Tree Files
*.dtsi - device tree files for including
*.dts  - main device tree

.dtsi files included later can override earlier ones, example:
```
#include "zynqmp.dtsi"
#include "zynqmp-u-boot.dtsi"
#include "zynqmp-clk-ccf.dtsi"
#include "pl.dtsi"
#include "pcw.dtsi"
```
Where `pcw.dtsi` are user overrides for the base `zynqmp.dtsi` which lists all PS peripherals seen by the processor but holds everything `status = "disabled"` by default.

To override, the `&` operator is required, example:
```
# -- zynqmp.dtsi
uart0: serial@ff000000 {
			bootph-all;
			compatible = "xlnx,zynqmp-uart", "cdns,uart-r1p12";
			status = "disabled";
			interrupt-parent = <&imux>;
			interrupts = <GIC_SPI 21 IRQ_TYPE_LEVEL_HIGH>;
			reg = <0x0 0xff000000 0x0 0x1000>;
			clock-names = "uart_clk", "pclk";
			power-domains = <&zynqmp_firmware PD_UART_0>;
			resets = <&zynqmp_reset ZYNQMP_RESET_UART0>;
		};

# -- pcw.dtsi
&uart0 {
		xlnx,has-modem = <0>;
		xlnx,uart-clk-freq-hz = <100000000>;
		port-number = <0>;
		xlnx,ip-name = "psu_uart";
		xlnx,uart-board-interface = "custom";
		xlnx,baudrate = <115200>;
		cts-override;
		u-boot,dm-pre-reloc;
		device_type = "serial";
		status = "okay";
		xlnx,clock-freq = <100000000>;
		xlnx,name = "psu_uart_0";
	};

```
Note: `xlnx,*` properties are extra information for AMD's own tools

To produce the flattened tree, use a command like so:

```
# system-top.dts : top-level device tree files
# merged.dts     : output file
cpp -nostdinc -I include -I . -undef -x assembler-with-cpp system-top.dts \
  | dtc -q -I dts -O dts -o merged.dts -

```
## kas and Yocto

kas handles cloning git repos (i.e., layers), generating a bblayers.conf that lists them and a local.conf with user settings. All this from a single YAML file.

`kas-container` is a container image for running kas. Alternatives are `repo` tool.

Useful YAML file parser:
```
python3 -c 'import yaml,json,sys; print(json.dumps(yaml.safe_load(open(sys.argv[1])), indent=1))' sw_sandbox/kas/base.yml

```
Usfeul `LAYERDEPENDS` printout:
```
grep -A8 LAYERDEPENDS sw_sandbox/build/kas/layers/*/conf/layer.conf sw_sandbox/build/kas/layers/*/*/conf/layer.conf

```
Debugging layer dependency issues:
```
bitbake-layers show-layers
```
Checking sstate misses prior to building:
```
bitbake -S printdiff edf-linux-disk-image
```
