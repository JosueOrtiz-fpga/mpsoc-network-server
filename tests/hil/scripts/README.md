# tests/hil/scripts: JTAG boot and netboot

Boots the ZUBoard 1CG with no boot media. `xsdb` loads PMUFW, FSBL, TF-A and U-Boot over JTAG
(J16), then U-Boot fetches the kernel and device tree over TFTP and mounts the rootfs over NFS,
across a point-to-point Ethernet cable to the host. This covers steps 1-3 of "Boot flow under
test" in the top-level README. labgrid and the pytest suite in `tests/hil/` build on it later.

All commands run from the repository root.

| File | Role |
|---|---|
| `setup-host.sh` | One-time host setup (NIC address, TFTP, NFS, packages, groups) plus a `--check` mode |
| `hil.env` | Bench settings: IP addresses, served directory, fallback MAC |
| `stage-netboot.sh` | Copies an `out/sw` build into the served directory and builds `out/hil/boot.scr` |
| `netboot.cmd` | U-Boot script template: TFTP kernel and DTB, NFS root, `booti` |
| `jtag-boot.tcl` | `xsdb` script: PMUFW, FSBL, DTB, boot script, U-Boot, TF-A |

Make targets: `make hil-stage` (stages the PL package too; `PL_STEM=<stem>` picks another one), `make jtag-boot`, and `make hil`, which does both and runs the pytest suite in `tests/hil/`.

## Bench setup

| Connection | Purpose |
|---|---|
| Micro-USB J16 to the host | JTAG (`xsdb`) and the UART0 console (`/dev/ttyUSB1`) |
| Ethernet to a spare host NIC | TFTP and NFS. Static addresses: host `192.168.77.1`, board `192.168.77.2` |
| USB-C 45 W supply | Power. Press SW7 after connecting, until the INIT strap is modified |

The board's SW2 must be **ON-ON-ON-ON** (JTAG boot mode). Change it only with power off.

The link needs no DHCP server. The PHY (KSZ9131, MDIO address 7) leaves reset on its own, since its
reset line is gated only by POWER_GOOD. If `enp2s0` has no carrier, look at the cable and the
board's power first.

## One-time host setup

```sh
tests/hil/scripts/setup-host.sh
```

It is safe to re-run. `HIL_NIC=<name>` selects a different interface (default `enp2s0`). It does
this, in order:

1. Adds a NetworkManager profile `hil` with `192.168.77.1/24`, no gateway, no IPv6.
2. Writes `/etc/dnsmasq.d/hil.conf`: TFTP only, on that NIC only (`port=0` turns DNS off, so
   it does not fight systemd-resolved).
3. Installs `dnsmasq`, `nfs-kernel-server`, `u-boot-tools`, `device-tree-compiler`, `picocom`.
4. Creates `/srv/hil`, owned by you.
5. Exports `/srv/hil` to the board's address only, with `no_root_squash` (the rootfs is owned by
   root), in `/etc/exports.d/hil.exports`.
6. Enables and restarts the services.
7. Adds you to `dialout` for the serial console. This applies from the next login.

It finishes with a list of checks. `setup-host.sh --check` runs only that list, which is a quick
way to see whether the host side is still intact after a reboot or when a boot misbehaves.

Two things the script cannot do for you:

- **Vivado tools.** `xsdb` and `bootgen` only exist after `source <Vivado install>/settings64.sh`
  in the shell you use for `make jtag-boot`.
- **JTAG cable drivers.** They ship with Vivado. If the check reports missing udev rules, run
  `install_drivers` as root from `<Vivado>/data/xicom/cable_drivers/lin64/install_script/`, then
  replug J16.

## Booting

```sh
make sw-image          # once per change: BOOT.BIN, Image, system.dtb, rootfs, jtag/*.elf
make hil-stage         # or: make hil-stage PL_STEM=<stem>
picocom -b 115200 /dev/ttyUSB1      # in a second terminal, leave it open
make jtag-boot
```

`make hil-stage` checks the artifact checksums, confirms `system.dtb` carries `__symbols__`
(needed by the PL overlay), copies the kernel and DTB to `/srv/hil/<id>/`, extracts the rootfs
there (this needs sudo), and builds `out/hil/boot.scr`. `<id>` is the build's `git describe`, with
`-dirty` when the tree has local changes. A good run ends with `hil-stage: ready (...)` and no
warnings. A warning means the host is missing its export or its `192.168.77.1` address.

The PL package goes into the staged rootfs as well: the one `make hw-plpkg` recorded in
`out/hw/pl/current`, or `PL_STEM=<stem>` for another package in `out/hw/pl/`. It is staged as
dfx-mgr's default firmware: `.bit.bin`, `.dtbo` and a flat-shell `shell.json` in
`/lib/firmware/xilinx/zub1cg/` (`HIL_PL_PKG`), and `zub1cg` in `/etc/dfx-mgrd/default_firmware`.
`dfx-mgr-fw-load.service` loads it at boot.

`make jtag-boot` then goes through these stages:

1. Connects to `hw_server`, opens the CSU JTAG security gates so the PMU becomes visible, and
   does a system reset.
2. Reads the boot-mode pins and stops if they are not JTAG (0x0).
3. Loads and runs PMUFW on the PMU.
4. Loads the FSBL on A53 #0. It runs `psu_init` (MIO, clocks, DDR) and stops, because the boot
   mode is JTAG.
5. Writes `system.dtb` to `0x100000` and `boot.scr` to `0x20000000`, loads U-Boot and TF-A,
   and starts execution in TF-A, which enters U-Boot.

On the console you should see, in order: the FSBL banner, TF-A `NOTICE` lines, the U-Boot banner,
`netboot: build <id> ...`, two TFTP transfers, `netboot: system.dtb has __symbols__`, the kernel
log, and a login prompt.

If U-Boot's autoboot does not run the script, press a key to stop autoboot and type:

```
source 0x20000000
```

## Loading and unloading the PL

dfx-mgr loads the staged package at boot (overlay `zub1cg_image_1`). By hand:

```
sudo dfx-mgr-client -listPackage
sudo dfx-mgr-client -unloadByName zub1cg
sudo dfx-mgr-client -loadByName zub1cg
ls /sys/kernel/config/device-tree/overlays/
```

Always go through `dfx-mgr-client`. Once dfx-mgr has loaded the PL, applying an overlay
directly through configfs (`mkdir .../overlays/<name>`, write `path`) oopses the kernel in
`dma_buf_dynamic_attach`: dfx-mgr leaves FPGA Manager flags and the firmware search path set.

## Configuration

`hil.env` holds the bench settings. Every value can be overridden from the environment.

| Variable | Default | Meaning |
|---|---|---|
| `HIL_HOST_IP` | `192.168.77.1` | Host end of the link (TFTP and NFS server) |
| `HIL_BOARD_IP` | `192.168.77.2` | Board address, also the NFS export target |
| `HIL_NETMASK` | `255.255.255.0` | Must stay a /24: `setup-host.sh` assumes it |
| `HIL_SRV` | `/srv/hil` | TFTP root and NFS export root |
| `HIL_BOARD_MAC` | `02:00:5a:b1:1c:01` | Used only if U-Boot has no `ethaddr` yet |

If you change these after running `setup-host.sh`, run it again, then `make hil-stage`.

`jtag-boot.tcl` reads these from the environment:

| Variable | Default | Meaning |
|---|---|---|
| `HW_SERVER_URL` | (local server) | Use an `hw_server` elsewhere, e.g. `tcp:host:3121` |
| `JTAG_CABLE` | (any) | Cable serial filter when several boards are attached |
| `JTAG_RESET` | `1` | Set `0` to skip the initial system reset |
| `FSBL_WAIT_MS` | `5000` | Time given to the FSBL for `psu_init` |
| `SCRIPT_ADDR` | `0x20000000` | DDR address for `boot.scr` |

## Where things live

```
out/sw/                    input: make sw-image output (BOOT.BIN, Image, system.dtb, rootfs.tar.gz, jtag/)
out/hil/                   generated: netboot.cmd (filled in), boot.scr, stage.env
/srv/hil/<id>/             served: Image, system.dtb, boot.scr, rootfs/  (rootfs is NFS-exported)
/etc/dnsmasq.d/hil.conf    TFTP config
/etc/exports.d/hil.exports NFS export
```

Old builds stay in `/srv/hil/<id>/` until removed: `sudo rm -rf /srv/hil/<id>`.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `xsdb: command not found` | Vivado environment not sourced in this shell |
| `no JTAG target matching ...` | Board off (press SW7), cable drivers missing, or another `hw_server` or Vivado Hardware Manager holds the cable (`pkill hw_server`) |
| `boot mode pins read 0x5` (or similar) | SW2 is not in JTAG mode. Fix it and power-cycle |
| `picocom`: permission denied on `/dev/ttyUSB1` | Not in `dialout` yet: log out and back in, or `sg dialout -c 'picocom -b 115200 /dev/ttyUSB1'` |
| Board switches itself off when the FSBL runs | `psu_init` is driving MIO34 (POWER_KILL_N) low. Check its PMU GPO configuration and polarity |
| U-Boot prints nothing | Wrong tty, or a TF-A/U-Boot mismatch. Retry with a longer `FSBL_WAIT_MS` |
| TFTP: `ARP Retry count exceeded` | Host IP not up, dnsmasq not listening on the NIC, or a firewall. Run `setup-host.sh --check` |
| `Waiting for PHY auto negotiation` forever | No link or PHY not found at address 7. Check the RJ-45 LEDs and the `&gem2` node in `zub1cg-board.dtsi` |
| TFTP starts, then times out or corrupts | RGMII delays: `rgmii-id` and the U-Boot KSZ90X1 driver (`zub1cg-uboot.cfg`) |
| `VFS: Unable to mount root fs via NFS` | Export missing (`showmount -e localhost`) or NFSv3 not enabled (`sudo cat /proc/fs/nfsd/versions` should list `+3`) |
| Boots, then hangs with `nfs: server ... not responding` | A network manager in the rootfs reconfigured `eth0` under the NFS root. Tell it to leave that interface alone |

To see whether the board is talking at all, watch the link from the host:

```sh
sudo tcpdump -ni enp2s0 arp or udp port 69
```

## Not covered here

- Booting from SD card or QSPI (SW2 SD1 or QSPI32). Deferred to a later release-test stage.
- The labgrid environment and the pytest suite in `tests/hil/`.
- Reset over the FT2232H (PS_POR_N and PS_SRST_N), and the INIT strap change for unattended
  power-up. Both are open items in the top-level README.