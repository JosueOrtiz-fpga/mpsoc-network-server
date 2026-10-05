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