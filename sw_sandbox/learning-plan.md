# sw_sandbox learning plan

Goal: be able to rebuild the ZUBoard 1CG Linux build (AMD EDF, Yocto, kas) from scratch,
understand each step, and get through it without friction. The reference is the
production build in `sw/`; each stage below says which part of it you are reproducing.
The aim is a working understanding of each layer, not becoming a Yocto specialist.

How each stage works: Claude explains the stage and assigns a task with acceptance criteria.
You write the files and run the commands, and Claude reviews. Once a pattern has been
practiced, Claude may write the repetitive parts as a commented template.

Status: `[x]` done, `[~]` in progress, `[ ]` not started.

```
XSA --(sdtgen)--> SDT --(gen-machine-conf)--> machine conf
                                                   |
   kas YAML --> layers + local.conf --> bitbake --> BOOT.BIN, Image, system.dtb, rootfs, WIC
```

---

## Stage 0: Toolchains and source repos `[x]`

Done on 2026-10-05 (commit `ca905c7`). This was a primer for the by-hand route.

- Cross-toolchain naming: `arch-vendor-os-libc`. When to use `-linux-gnu` and when `-elf`, and why
  freestanding code (kernel, U-Boot, TF-A) only cares about the arch.
- Pinned Arm GNU toolchains (URL + SHA256 in `versions.env`), download and extract
  in `Makefile`.
- Shallow clones of u-boot-xlnx, linux-xlnx, embeddedsw and TF-A at release tags, with each
  HEAD checked against a pinned hash.
- Make patterns: stamp files, pattern rules, `print-%`, `.DELETE_ON_ERROR`.

## Pivot on 2026-10-05: by-hand route parked

Other priorities came first, so building FSBL, PMUFW, TF-A, U-Boot and the kernel by hand is
on hold. The plan now treats EDF/Yocto as the baseline. The by-hand work may come back later
(see [Later](#later-by-hand-route-revisited)).

---

## Stage 1: Hardware description, XSA to SDT `[x]`

Reproduces: `make platform-sdt` (`sw/scripts/gen-sdt.sh`).

- What a device tree is for, `.dts` vs `.dtsi`, include order, overriding with `&label`, and
  `status = "okay"/"disabled"`.
- What a System Device Tree is: the whole chip (A53, R5, PMU) rather than only Linux's view.
- `sdtgen` turns the XSA into the SDT plus `psu_init.c/h`.
- Flatten a tree with `cpp | dtc` to see what the include chain finally produces.

Done when: `make sdt` produces `build/sdt/` from the XSA, and the Makefile changes are
committed. Done in commit `17b9201`.

## Stage 2: kas skeleton, layers and local.conf `[x]`

Reproduces: the `repos:` part of `sw/kas/base.yml`.

- What kas does: clones layers, writes `bblayers.conf` and `local.conf`, and runs BitBake in a
  container.
- Layers, `layer.conf`, `LAYERDEPENDS` and `LAYERSERIES_COMPAT`. Why EDF pulls in meta-ros, Qt5
  and so on.
- `HOSTTOOLS` and how a layer can add host requirements (the gfortran error).
- kas does **not** use EDF's `local.conf.sample` (`TEMPLATECONF`), so you add the settings you
  need with `local_conf_header`.

Done when:
- [x] `bitbake-layers show-layers` lists every layer inside `kas-container shell`.
- [x] The fortran skip is in the generated `local.conf`, and `gfortran` is not in `HOSTTOOLS`.
- [x] You have reviewed EDF's `local.conf.sample` and listed the settings you kept, with a
      reason for each. Kept: fortran skip, `xilinx` license flag, `BB_DISKMON_DIRS`
      (commit `17b9201`).

## Stage 3: Reproducible, scripted builds `[x]`

Reproduces: `sw/Makefile` (`kas-dirs`, `sw-shell`, `sw-lock`, `check-versions`) and
`sw/kas/base.lock.yml`.

- Calling kas from make: `KAS_WORK_DIR`, `KAS_BUILD_DIR`, and make vs shell variable syntax
  (`$(CURDIR)`, `$(HOME)`).
- `DL_DIR` and `SSTATE_DIR` outside the checkout. What shared state is and why a clean build can
  still be incremental.
- Pinning: `kas lock` writes a lock file, and kas applies it automatically. This clears the
  "branch without commit" warnings.
- Pinning `kas-container` itself (`KAS_IMAGE_VERSION`) and its distro
  (`KAS_CONTAINER_IMAGE_DISTRO=debian-bookworm`: the default Debian 13 image's GCC 14 fails
  to build `bootgen-native`).

Done when: `make` targets open a shell and write a lock file, a second checkout resolves the
same commits, and kas prints no "unsafe" warnings. Done in commits `6b9bf70` and `565c408`.

## Stage 4: First generic image `[~]`

Reproduces: `sw/kas/image.yml`.

- Splitting kas config into files and chaining them with `base.yml:image.yml`. How later files
  override earlier ones.
- Machine vs distro vs image. Why `amd-cortexa53-common` (ZU1CG has no Mali).
- `bitbake <image>`, the deploy directory and what each artifact is.
- Debugging tools: `bitbake -e`, `bitbake-layers show-appends`, `oe-pkgdata-util`, task logs
  in `tmp/work/...`.

Done when: `edf-linux-disk-image` builds, and you can name every file in `deploy/images/` that
you will put on the board.

## Stage 5: Board machine and BOOT.BIN `[ ]`

Reproduces: `make platform-machine` (`gen-machine.sh`, `platform/machine/`) and
`sw/kas/bootbin.yml`.

- The ZynqMP boot chain at concept level: CSU ROM, FSBL, PMUFW, TF-A, U-Boot, kernel. What
  each stage does and which core it runs on.
- `gen-machine-conf`: from the SDT to a machine `.conf`, plus multiconfigs for the bare-metal
  FSBL and PMUFW builds.
- Multiconfig (`BBMULTICONFIG`) and why `bootbin.yml` uses a different machine than the image.
- The `xilinx-bootbin` recipe and what bootgen packs into BOOT.BIN.

Done when: a board-specific machine is generated from your own SDT and `xilinx-bootbin`
produces a BOOT.BIN.

## Stage 6: Your own layer `[ ]`

Reproduces: `sw/meta-zub1cg/`.

- `bitbake-layers create-layer`, `layer.conf`, priority, and where your layer goes in kas.
- `.bbappend` files: changing a recipe without forking it.
- Kernel and U-Boot config fragments (`.cfg`), and `menuconfig` / `diffconfig` to produce
  them.
- Board device tree additions (`zub1cg-board.dtsi`) and where they enter the tree.
- `devtool modify` for a quick edit-build loop.

Done when: a kernel config fragment and a device tree change of your own show up in the built
image, and you can show where each one came from with `bitbake -e`.

## Stage 7: Boot the board `[ ]`

Reproduces: `make sw-image` and `sw/scripts/collect-artifacts.sh`.

- The WIC layout: boot partition (BOOT.BIN, boot script) and rootfs.
- Writing the SD card, the serial console, and the U-Boot environment and boot flow.
- Collecting artifacts and a manifest out of the build directory.

Done when: the ZUBoard boots your image from SD to a login prompt.

## Stage 8: Applications and SDK `[ ]`

Reproduces: `sw/meta-zub1cg-app/` and `make sw-sdk`.

- Writing a recipe: `SRC_URI`, `LIC_FILES_CHKSUM`, `do_compile` / `do_install`, `FILES`,
  packaging.
- Adding a package to the image (`IMAGE_INSTALL`) and systemd services.
- The EDF application SDK (`meta-edf-app-sdk`): cross-compiling outside Yocto.

Done when: a small app built by your recipe runs on the board, and the same source also builds
with the SDK.

## Stage 9: PL overlays and dfx-mgr `[ ]`

Reproduces: `make pl-sdt`, `make pl-overlay` (`gen-pl-overlay.sh`).

- Device tree overlays (`.dtso` / `.dtbo`) for logic in the PL.
- A full SDT with the PL vs a PS-only one.
- dfx-mgr: how a PL package (`.bit.bin`, `.dtbo`, `shell.json`) is loaded at boot and at
  run time.

Done when: a PL package you generated loads on the board through `dfx-mgr-client`.

---

## Later: by-hand route revisited

Optional, picks up after Stage 0 when time allows. Build each boot component outside Yocto with
the Stage 0 toolchains and sources: PMUFW and FSBL from embeddedsw, TF-A, U-Boot and the kernel.
Then put BOOT.BIN together by hand with `bootgen` and a `.bif`. The point is to see what EDF's
recipes do for you.
