# tests/hil/scripts: JTAG boot and netboot

Boots the ZUBoard 1CG without any boot media: `xsdb` loads PMUFW, FSBL, TF-A and U-Boot over
JTAG (J16), and U-Boot fetches the kernel and device tree over TFTP and mounts the rootfs over
NFS through a point-to-point Ethernet link. This is step 1-3 of the README's "Boot flow under
test"; labgrid and `tests/hil` build on top of it later.

| File | Role |
|---|---|
| `hil.env` | Bench settings: IP addresses, `/srv/hil`, fallback MAC |
| `stage-netboot.sh` | Copies an `out/sw` build to `/srv/hil/<id>/`, builds `out/hil/boot.scr` |
| `netboot.cmd` | U-Boot script template: TFTP kernel + DTB, NFS root, `booti` |
| `jtag-boot.tcl` | `xsdb` script: PMUFW, FSBL, DTB, boot.scr, U-Boot, TF-A |

The link uses static addresses on both ends (host `192.168.77.1`, board `192.168.77.2`), so no
DHCP server is needed. Change them in `hil.env` if that subnet is taken at home.

## One-time host setup

Replace `<hil-nic>` with the spare NIC or USB Ethernet adapter the board is cabled to.

**Packages.** `u-boot-tools` (mkimage), `device-tree-compiler` (fdtget, optional check),
`dnsmasq` (TFTP only), `nfs-kernel-server`, and a serial terminal such as `picocom`. Add
yourself to the `dialout` group for the UART.

**JTAG cable drivers.** `hw_server` needs the udev rules that ship with Vivado. Run the
`install_drivers` script under `<Vivado>/data/xicom/cable_drivers/lin64/install_script/` as
root, then replug J16. `xsdb` comes from `<Vivado>/settings64.sh`.

**Static address on the HIL NIC** (NetworkManager):

```sh
nmcli con add type ethernet ifname <hil-nic> con-name hil \
  ipv4.method manual ipv4.addresses 192.168.77.1/24 ipv4.never-default yes ipv6.method disabled
```

**Served tree.** Owned by you, so staging only needs sudo for the rootfs:

```sh
sudo install -d -o "$USER" -g "$USER" /srv/hil
```

**TFTP** with dnsmasq, `/etc/dnsmasq.d/hil.conf`. `bind-dynamic` copes with the NIC losing its
address while the board is off, and `port=0` turns off DNS, so it does not clash with a local
resolver:

```
port=0
interface=<hil-nic>
bind-dynamic
enable-tftp
tftp-root=/srv/hil
```

**NFS**, one line in `/etc/exports`, then `sudo exportfs -ra`:

```
/srv/hil 192.168.77.2(rw,no_root_squash,no_subtree_check,sync)
```

`no_root_squash` is required: the rootfs is owned by root. The export is limited to the board's
address, and the rootfs is test-only.

**Firewall.** If ufw or firewalld is active, allow all traffic in on `<hil-nic>`
(TFTP is UDP 69 plus ephemeral ports; NFSv3 uses rpcbind and mountd).

## First boot

1. `make sw-image`
2. `make hil-stage` (or `make hil-stage WITH_PL=1` to add the PL package to `/lib/firmware`)
3. Board: SW2 = ON-ON-ON-ON (JTAG), Ethernet to `<hil-nic>`, J16 to the host, USB-C power,
   press SW7.
4. Console: `picocom -b 115200 /dev/ttyUSB1` (the FT2232H's second interface; the first is JTAG).
5. `make jtag-boot`

Expected on the console, in order: FSBL banner (reports JTAG boot mode), TF-A `NOTICE` lines,
U-Boot banner, `netboot: build <id> ...`, two TFTP transfers, the `__symbols__` check, the
kernel log, and finally a login prompt.

If U-Boot's autoboot does not pick up the script (it depends on how the U-Boot environment
handles JTAG boot mode), stop autoboot with a key press and type `source 0x20000000`.

Useful overrides: `JTAG_CABLE=<serial>` (several boards), `JTAG_RESET=0`,
`FSBL_WAIT_MS=8000`, `HW_SERVER_URL=tcp:<host>:3121` (hw_server on another machine).

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `no JTAG target matching ...` | Board off (press SW7), cable drivers missing, or another hw_server / Vivado Hardware Manager holds the cable |
| `boot mode pins read 0x5` etc. | SW2 is not in JTAG mode. Fix and power-cycle |
| Board switches itself off when the FSBL runs | psu_init drives MIO34 (PMU GPO2, POWER_KILL_N) low. Check the PMU GPO polarity for MIO34 in `hw/bd/mpsoc_bd.tcl` |
| U-Boot prints nothing | Wrong tty, or TF-A/U-Boot mismatch. Retry with a longer `FSBL_WAIT_MS` |
| TFTP: `ARP Retry count exceeded` | Host IP not up, dnsmasq not listening on the NIC (`sudo ss -ulpn 'sport = :69'`), or firewall |
| `Waiting for PHY auto negotiation` forever | PHY not found at address 7 or no link; check the RJ-45 LEDs and the `&gem2` node in `zub1cg-board.dtsi` |
| TFTP starts, then times out or corrupts at 1000 Mb/s | RGMII delays: `rgmii-id` and the U-Boot KSZ90X1 driver (`zub1cg-uboot.cfg`) |
| `VFS: Unable to mount root fs via NFS` | Export missing (`showmount -e 192.168.77.1`), or NFSv3 disabled on the server |
| Boots, then hangs with `nfs: server ... not responding` | A network manager in the rootfs reconfigured `eth0` under the NFS root; tell it to leave that interface alone |

Old builds stay in `/srv/hil/<id>/`; remove them with `sudo rm -rf /srv/hil/<id>`.
