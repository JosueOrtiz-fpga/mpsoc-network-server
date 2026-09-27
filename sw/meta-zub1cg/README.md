# meta-zub1cg

Board support for the Avnet ZUBoard 1CG (AES-ZUB-1CG-DK-G, PCB rev 1) on AMD EDF 25.11
(Vivado/EDF 2025.2, Yocto scarthgap).

## How the board reaches Linux

EDF splits the build in two:

| Build | MACHINE | Output | Board-specific? |
|---|---|---|---|
| `sw/kas/base.yml:sw/kas/bootbin.yml` | `zynqmp-zub1cg-sdt` (generated, `platform/machine`) | BOOT.BIN: PMUFW, FSBL, TF-A, U-Boot, `system.dtb` | Yes |
| `sw/kas/base.yml:sw/kas/image.yml` | `amd-cortexa53-common` (ZynqMP CG/DR, no Mali) | kernel, rootfs, WIC | No |

U-Boot hands its device tree (`system.dtb`, from BOOT.BIN) to the kernel. So board
knowledge lives in two places:

- **`board-dts/zub1cg-board.dtsi`**: passed to SDTGen with `-user_dts`. SDTGen includes it
  from `system-top.dts`, and it ends up in `system.dtb`. Change it, then run
  `make platform` and commit the `platform/` diff.
- **`recipes-*`**: kernel and U-Boot config fragments (PHY driver built in, NFS root).

## Board facts used (from the schematic, rev 1)

| Item | Value | Where |
|---|---|---|
| Console | UART0, MIO10/11, FT2232H on J16 | UG 5.6 |
| Ethernet | GEM2, RGMII MIO52-63, MDIO MIO76/77, KSZ9131RNX | UG 5.5, sheet 7 |
| PHY address | 7 (PHYAD2..0 pulled up, pull-downs DNP) | sheet 7 |
| PHY reset | MIO12 AND POWER_GOOD (U15), pulled up | sheet 7 |
| MAC EEPROM | AT24MAC602 on I2C1 (MIO8/9): EEPROM 0x50, EUI page 0x58 | sheet 7 |
| microSD | SD1 MIO45-51, CD on MIO45; PI4ULS3V4857 with SEL tied low, so `no-1-8-v` | sheet 5 |
| QSPI | IS25WP256E, 32 MB, x4, MIO0-5 | sheet 5 |
| Power | MIO26 = PWR_INT from on/off controller, MIO34 = POWER_KILL_N | UG table 2 |

## Open items

- [ ] **Clean power-off.** PMUFW must act on MIO26 and drive MIO34 after shutdown.
  Ultra96 also drives its on/off controller's KILL_N from MIO34, and AMD's PMUFW has
  an Ultra96 module (`ENABLE_MOD_ULTRA96`) that is worth comparing against. Check how
  `meta-avnet` handles zub1cg, and how to pass PMUFW build flags in the SDT flow.
  **Never drive MIO34 low from Linux or U-Boot** (gpio-hog, gpio-poweroff tests, a PS
  config that makes it a low output): the controller cuts power at once.
- [ ] **MAC address.** The AT24MAC602 holds an EUI-64, not an EUI-48, so the MAC-48 must
  be derived. Check what Avnet's image does, then wire it into U-Boot (`ethaddr`) and/or
  Linux (`nvmem-cells`). Until then the MAC is random per boot; for fixed DHCP
  leases on the HIL bench, set `ethaddr` in the U-Boot netboot script.
- [ ] **USB.** USB1 through the USB3320 ULPI PHY and the USB5744 hub (reset lines,
  hub configuration).
- [ ] **User I/O.** LEDs (MIO7/24/25/33) and switches/buttons as gpio-leds/gpio-keys,
  once the transistor polarity is checked.
