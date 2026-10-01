<!--
Release-notes template. ci/release.sh (make release) fills in the @...@ fields and
writes RELEASE_NOTES.md into the release directory, without this comment. The
sections marked TODO are for a person: complete them before pushing the tag.
SHA256SUMS leaves the notes out, so editing them breaks no checksum. Contents
follow the release process in docs/development_plan.md.
-->
# @TAG@

| | |
|---|---|
| Released | @DATE@ |
| Commit | `@COMMIT@` |
| PL package | `@PL_STEM@` |
| Register map `VERSION` | TODO (none before R1: no DIFI register bank) |
| HIL suite | @HIL_SUMMARY@ |
| SDK | @SDK@ |
| Build and test time | @BUILD_TIME@ |

## What this release does

TODO: the release's goal from the development plan, and what you can do with it.

## Architecture sections implemented

TODO: the sections of `docs/difi-streaming-architecture.md` this release implements, fully or in part.

## Interim behaviour in effect

TODO: quote the rows of the plan's "Interim behaviour" table that apply to this release.

Until B2: the SD image (`zub1cg-sd.wic`) carries no PL package. The package is in `pl/`;
on the HIL bench, `make hil` stages it onto the NFS root as dfx-mgr's default firmware.

## Known issues

TODO: or "None".

## Artifacts

| Path | Content |
|---|---|
| `BOOT.BIN` | PMUFW, FSBL, TF-A, U-Boot, `system.dtb` |
| `zub1cg-sd.wic` | SD card image (BOOT.BIN in its ESP) |
| `Image`, `system.dtb`, `rootfs.tar.gz` | Kernel, device tree, root filesystem (NFS root on the bench) |
| `jtag/` | Boot chain for `jtag-boot.tcl` |
| `pl/` | PL package: `.bit.bin`, `.dtbo`, `.dtso` |
| `*.xsa` | Hardware handoff the PL package and `platform/` were built from |
| `sdk/` | EDF application SDK installer and its package lists (only with `RELEASE_SDK=1`) |
| `hil/` | HIL report: `junit.xml`, `console.log`, `jtag-boot.log`, `commands.log` |
| `manifest.txt`, `layers.lock.yml` | Build identity and pinned Yocto layers |
| `release.log` | Full build and test log |
| `SHA256SUMS` | Checksums of every file above (not of these notes, which are edited after the build) |
