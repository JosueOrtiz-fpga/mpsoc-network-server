# DIFI streaming architecture

Architecture of the VITA 49.2 / DIFI I/Q stream from the ZUBoard 1CG to GNU Radio: data path, packet format, PS-mastered control plane, PL register map, bring-up sequences and design review.

> **Status:** design phase, draft. Nothing here is implemented yet. Register offsets and field layouts are proposals and may change until the first RTL tag; the `VERSION` register major number protects the driver from mismatches after that. DIFI field values follow the v1.2.1 text as published in the Consortium's `DIFI-Certification` repository (see [Standard version](#standard-version)). Items still marked _(verify)_ need hardware or board documentation.

---

## Contents

- [Goals and scope](#goals-and-scope)
- [Standard version](#standard-version)
- [System overview](#system-overview)
- [Data path](#data-path)
- [Packet format](#packet-format)
- [Control plane](#control-plane)
- [Register map](#register-map)
- [Sequences](#sequences)
- [Timebase and timestamps](#timebase-and-timestamps)
- [Loss accounting and error handling](#loss-accounting-and-error-handling)
- [Design review](#design-review)
- [Verification plan](#verification-plan)
- [Proposed code layout](#proposed-code-layout)
- [Future features](#future-features)
- [Open decisions and TODO](#open-decisions-and-todo)
- [References](#references)

---

## Goals and scope

The board produces a stream of HF I/Q samples from a synthetic test source in the PL and sends it to a host PC over Ethernet in a form that open-source SDR software can consume without custom code.

The stream format is **DIFI** (IEEE-ISTO Std 4900-2021, conformance target v1.2.1, see [Standard version](#standard-version)), a published, constrained profile of ANSI/VITA 49.2. DIFI pins down the packet types, prologue fields, timestamp modes and sample format. The reference receiver is GNU Radio with the `gr-difi` out-of-tree module, the only mainstream open-source SDR stack that ingests this format natively.

In scope: the PL signal chain and packetizer, the PS control plane and UDP transport, and the host-side receive chain. Out of scope for now: VITA 49.2 command/control packets over the network, transmit, multiple channels, and PTP time transfer.

---

## Standard version

**Decision.** Conform to **DIFI v1.2.1** (March 2025), Information Class `0x0000` (Basic Data Plane) only: a one-way stream of Standard Flow Signal Data packets (packet class `0x0000`) and Standard Flow Signal Context packets (`0x0001`). No version flow, command, flow-control or link-establishment packets are emitted. Information Class `0x0000` is unchanged in v1.3.0, whose additions all live in new information classes, so this stream is also a valid v1.3.0 Basic Data Plane.

**Sources.** The DIFI Consortium's `DIFI-Certification` repository (pinned at commit `6ee49d1e`) contains condensed references for v1.1, v1.2.1 and v1.3.0 in `.claude/skills/difi/`. This document's field values come from the v1.2.1 reference, cross-checked against the Consortium's Construct packet definitions (`packet_definitions/`) and the three reference captures (`example_pcaps/`). The references are summaries, not the normative text, and the tooling disagrees with them in a few places (see [Oracle caveats](#oracle-caveats)). Each disagreement that affects this design is settled by at least two independent sources, so the official DIFI text is not needed before RTL.

**Deviation: no jumbo frames.** DIFI §2.2 requires every endpoint to support 9000-byte jumbo frames. This design deliberately does not: packets are limited to a 1500-byte MTU (at most 361 samples). Every packet it sends is still valid DIFI, because DIFI allows any Ethernet payload from 128 to 9000 octets; only the endpoint capability is missing. We control both ends of the link, so no sink will need larger packets, and the choice keeps switches, the host NIC and GEM2 out of the requirements. It does rule out a formal conformance claim. The project README records this deviation.

**Deviation: no State and Event indicators.** DIFI §4.3.1 expects the context packet's State and Event word to report calibrated-time lock (bit 19) and frequency-reference lock (bit 17), updated about once per second. This design does not report them: the word is always `0x00000000`, with every enable bit clear, which VITA 49.2 defines as no indicator in use. The context packet stays structurally valid, because the word is present as CIF0 requires; only the reporting is missing. Receivers therefore cannot tell from the stream how accurate the timestamps are; Timestamp Calibration Time still says when the timebase was last seeded. In DIFI the transmit side uses these bits (for example, to decide whether Programmed Delay mode is possible), and this design has no transmit side, so nothing in our chain consumes them. Like the jumbo-frame deviation, it rules out a formal conformance claim, and the project README records it.

---

## System overview

![ZUBoard DIFI stream: PL packetizer with PS-mastered control plane](zuboard_pl_packetizer_with_ps_control_plane.svg)

Solid arrows carry samples and packets; dashed arrows carry control and status. Purple nodes are the data path, coral nodes the control plane, grey nodes the host.

The split of responsibilities is deliberate. The **PL** owns everything that must be exact: sample generation, down-conversion, timestamping, and building complete DIFI packets (headers, prologue, payload, context). The **PS** owns everything that must be flexible: initialization, configuration, policy, and moving finished packets onto the network. The **host** runs stock open-source software.

---

## Data path

### PL

The **test source** generates real samples at the input sample rate `FS_IN`, quantized to a build-time input width and left-justified in 16 bits: two independently configurable NCO tones, or zeros. A deterministic **counter ramp** for bit-exact packetizer tests is injected after the DDC instead, as complex samples at the output rate, paced by the DDC's output valid strobe, so packet timing and the context sample rate are the same as for the other sources.

The **DDC** mixes the selected input to baseband with a tunable NCO, decimates it with a CIC plus compensating FIR chain, and outputs complex signed 16-bit I/Q. The test source's samples are real, and DIFI requires complex samples, so the DDC is needed even for a single tone.

The **DIFI packetizer** accumulates `SAMPLES_PER_PKT` samples, byte-swaps them to big-endian, and prepends the 28-byte DIFI prologue: header, stream ID, class ID, and integer and fractional timestamps. The timestamp is the time the packet's first sample left the signal source (see [Timebase and timestamps](#timebase-and-timestamps)). It also emits context packets according to the [context rules](#context-packet-rules). Both packet types leave through the same AXI4-Stream, so their ordering is preserved end to end.

**AXI DMA** in S2MM mode writes packets into a DDR ring of fixed 2 KB slots (the largest packet is 1,472 B), one packet per slot, delimited by `TLAST`. Each packet's own header size field gives its length, so no side-channel length information is needed.

### PS

The **control driver** owns the register bank and the DMA ring. It initializes the pipeline in a defined order, applies configuration through the commit mechanism, services interrupts, and exposes counters. It is described under [Control plane](#control-plane).

The **UDP sender** is a userspace process. It reads completed slots from the ring and sends each packet, unchanged, as one UDP datagram using `sendmmsg`. It never parses or modifies packet contents; if it did, the PL would no longer be the single source of truth for the stream.

The **kernel UDP/IP stack**, the `macb` driver on GEM2, and the KSZ9131 PHY put frames on the wire. This is the board's only Ethernet path. The PHY is wired to PS GEM2 over MIO (see `sw/meta-zub1cg/board-dts/zub1cg-board.dtsi`), so the PL cannot transmit frames without the PS.

### Host

`gr-difi`'s DIFI Source block listens on a UDP port, parses data and context packets, outputs a `complex64` stream, and emits stream tags on context changes and on missed packets. Downstream is an ordinary GNU Radio flowgraph: a waterfall, filters, and demodulators. An optional SigMF file sink produces recordings that inspectrum, SDRangel and GNU Radio can open.

### Throughput

HF bandwidths put little load on this path. At 1 MS/s output with 360 samples per packet, the stream is about 2,800 packets/s and about 33 Mbit/s including headers, a small fraction of GEM2's 1 Gbit/s. The first bottleneck at much higher rates would be per-packet cost in the kernel, not link bandwidth.

---

## Packet format

### Encapsulation

| Layer | Header size | Carried by | Built by |
|---|---|---|---|
| Ethernet II | 14 B header + 4 B FCS | wire | GEM2 |
| IPv4 | 20 B | Ethernet payload | kernel |
| UDP | 8 B | IPv4 payload | kernel |
| DIFI / VRT packet | 28 B prologue | UDP payload | **PL packetizer** |
| I/Q samples | none | VRT payload | **PL DDC** |

### DIFI data packet layout

All words are 32-bit, big-endian (network byte order).

```
 word | bits 31 ......................................................... 0
------+----------------------------------------------------------------------
   0  | Header: packet type | C | indicators | TSI | TSF | count | size (words)
   1  | Stream ID
   2  | Class ID: pad bit count (5 b) | reserved (3 b) | OUI (24 b)
   3  | Class ID: information class code (16 b) | packet class code (16 b)
   4  | Integer-seconds timestamp (POSIX)
   5  | Fractional-seconds timestamp, high 32 b (picoseconds)
   6  | Fractional-seconds timestamp, low 32 b
   7  | I0 (16 b, signed) | Q0 (16 b, signed)
   8  | I1                | Q1
  ... | ...
```

Context packets are always 27 words: the same seven-word prologue, carrying the stream ID of the data stream they describe, then CIF0 and 19 words of context fields in a fixed order (see [Context field values](#context-field-values-0x180)). The 4-bit packet count in the header increments per packet, separately for the data and context streams. Receivers use it to detect loss.

### Field values

| Field | Value | Sources |
|---|---|---|
| Class ID word 1 | Pad bit count 0, reserved 0, OUI `0x6A621E` | Spec §4.1; validator; captures |
| Information class | `0x0000` for both packet types | Spec §3.1; validator; captures |
| Packet class | Data `0x0000`, context `0x0001` | Spec Table 4-7; validator; captures |
| Data header bits 31:20 | `0x18E`: type 1, class ID 1, trailer 0, VITA 49.0 0, spectrum/time 0, TSI POSIX, TSF real-time | Spec §4.2; validator; captures |
| Context header bits 31:20 | `0x49E`: type 4, class ID 1, reserved 0, TSM 1 (coarse), TSI POSIX, TSF real-time | Spec §4.3.1, Table 4-16; validator; captures |
| Context size | 27 words (108 B) | Spec; validator; captures |
| CIF0 | `0xFBB98000` when a value changed, `0x7BB98000` otherwise | Spec Figure 9; validator |
| Reference point | 75 (`0x4B`), RF converter analog port | Spec §5.2 |
| Data packet payload format, 16-bit | `0xA00003CF`, `0x00000000` | Spec Figure 10; validator; captures (8-bit form `0xA00001C7`) |
| Reference Level word | Level in bits 15:0 (Q9.7 dBm), Scaling in bits 31:16 = 0 | Spec §4.3.1 and v1.3.0 §1.5 deviation table; Wireshark dissector. The Construct definition disagrees (see [Oracle caveats](#oracle-caveats)). |
| Gain word | `0x00000000` | Spec §4.3.1 (reserved since 1.2.1) |
| State and Event word | `0x00000000`: every enable bit clear, so no indicator is asserted. Not supported, by design (see the deviation note under [Standard version](#standard-version)). | VITA 49.2 convention (a clear enable marks its indicator as unused). The field stays present, as CIF0 requires. |
| I/Q order | I then Q for each sample; for 16-bit, I in bits 31:16 | Spec §4.2; `certify_source.py` |

**TSI is POSIX, not UTC.** DIFI's UTC code counts leap seconds since 1970; POSIX time does not. The timebase is seeded from the Linux clock, which is POSIX time, so labelling it UTC would be wrong by the leap seconds inserted since 1972 (27 so far). The Consortium's generator, all reference captures and `gr-difi`'s sink use POSIX as well. GPS becomes the natural choice if a GPS-disciplined PPS is added; `TSI_SEL` allows that without a rebuild.

**Reference point 75.** The test source is described as entering at the RF converter analog port, with no analog IF. Consequently IF Reference Frequency is 0, IF Band Offset is 0 (zero-IF output), and RF Reference Frequency is the center of the output band. See [Future features](#direct-sampling-hf-adc) for why this reference point was chosen.

**Integer hertz.** DIFI requires bandwidth, sample rate and frequencies in whole hertz: the 20 bits right of the radix point must be 0. The output sample rate `FS_IN_HZ` / `DDC_DECIM` must therefore be an integer for every supported decimation, which constrains the choice of `FS_IN`. RF Reference Frequency is the NCO's actual frequency rounded to the nearest hertz; the NCO's step (`FS_IN` / 2³²) is not an integer, so the reported value can differ by up to 0.5 Hz.

### Context packet rules

- A context packet precedes the first data packet after `ENABLE`, the first data packet after every applied commit, and the first data packet after an overflow. Periodic context packets precede every `CTX_INTERVAL`-th data packet.
- Every context packet carries the timestamp of the data packet that follows it. v1.3.0 states this explicitly for changes: new context values and the first data packet using them share a timestamp, and values never change mid-packet.
- CIF0 bit 31 (change indicator) is set on the first context packet after `ENABLE` and after every applied commit, and clear otherwise.
- The total rate must stay within 0–20 context packets per second, and a context packet is mandatory on every change. The driver sets `CTX_INTERVAL` for about one per second and spaces commits at least 100 ms apart, so that commit-driven packets cannot exceed the limit.

### Sizing

| Item | Bytes |
|---|---|
| MTU (IPv4 packet) | 1500 |
| IPv4 + UDP headers | −28 |
| DIFI prologue | −28 |
| Maximum I/Q payload | 1444 → 361 complex int16 samples (`CAPS` maximum) |
| **Chosen payload** | **360 samples = 1440 B** |
| VRT packet size | 1468 B = 367 words (header size field) |

Jumbo frames are not supported (see the deviation note under [Standard version](#standard-version)). The minimum is 18 samples, from DIFI's 128-octet minimum Ethernet payload. 802.1Q VLANs, which DIFI also requires endpoints to support, are handled by the Linux network stack.

With 16-bit samples, each sample is exactly one word, so any sample count is legal; Information Class `0x0000` forbids pad bits, and none are ever needed.

---

## Control plane

The PS is the only bus master for the PL register bank, over AXI4-Lite through an HPM port. Nothing in the PL configures itself, and nothing on the network can write registers.

### Principles

**Context and data never disagree.** VITA 49.2 semantics depend on every data packet being described by the most recent context packet for its stream. If a retune took effect mid-packet, the receiver would attribute samples to the wrong frequency. Every setting that affects the stream is therefore written to a *shadow* register and applied only by an explicit commit, at a packet boundary.

**Commits are atomic and announced.** On commit, the PL finishes the packet in progress. It then copies all shadow registers to the active set in one sample-clock cycle, emits a context packet with the context field change indicator set, and only then emits data at the new settings. The context packet and that first data packet carry the same timestamp. This also makes multi-word writes, such as 64-bit frequencies, tear-free without special ordering rules.

**The PL emits context; the PS supplies its values.** The PS writes the context field values in their VITA 49.2 fixed-point formats. The PL inserts them into context packets. A single packet stream carries both packet types, so ordering is guaranteed.

**Structural settings are locked while running.** Settings that change the stream's shape (stream ID, packet size, payload format, timestamp mode, decimation) are *locked*: a commit that changes them while `ENABLE=1` is rejected. Settings that are legitimate runtime changes, such as tuning and tone parameters, may be committed while running.

**Clock-domain crossing is confined to one place.** Registers live in the AXI clock domain; the datapath runs in the sample clock domain. Shadow-to-active transfer uses a request/acknowledge handshake synchronizer triggered by `COMMIT`. Counters and timebase readback use a snapshot handshake. No other signals cross.

### Driver

Bring-up uses UIO for the register bank plus a `udmabuf` region for the ring, which is enough to exercise the PL from userspace. The target is a small kernel driver that owns the register bank, the DMA channel through dmaengine, and the interrupt. It exposes a character device: `ioctl` for configuration and `mmap` for the ring.

The PL is loaded at runtime by FPGA Manager and can be replaced at runtime, as described in `edf-2026_1-followups.md`, section 3. The driver must therefore stop the stream and release the DMA ring in its `remove` path, before the overlay is removed.

The interrupt must be wired to `pl_ps_irq0` in `hw/bd/mpsoc_bd.tcl`, so that Lopper generates `interrupts`/`interrupt-parent` in the overlay. This is the same issue already open for `axi_iic_0`.

---

## Register map

One AXI4-Lite slave, 4 KB aperture. The base address is assigned in the block design and appears in the generated PL overlay. All registers are 32-bit and word-aligned; reserved bits read as 0 and must be written as 0; unmapped offsets read as 0 and ignore writes.

### Conventions

| Access | Meaning |
|---|---|
| RO | Read-only |
| RW | Read/write |
| W1C | Read; writing 1 to a bit clears it |
| SC | Write 1 to trigger; self-clearing, reads as 0 |

| Flag | Meaning |
|---|---|
| **S** | Shadowed: the write lands in the shadow set and takes effect on the next `COMMIT`. Reads return the shadow value. |
| **L** | Locked: a commit that changes this register while `CTRL.ENABLE=1` is rejected with error `0x03` |
| **N** | Read value comes from the last `SNAP_CTRL.SNAPSHOT` |

64-bit quantities are split `_HI` (bits 63:32) / `_LO` (bits 31:0). They are either shadowed, so the commit makes them atomic, or snapshotted, so readback is coherent.

**RSVD (growth)** marks a bit or field encoding already claimed by a planned feature; [Future features](#future-features) lists each claim. Growth bits and registers are not implemented in this build: they read as 0 and writes to them are ignored, and software writes 0 to them. A growth encoding of a commit-checked field is rejected with the error code given in that field's description. Growth allocations are not reassigned to anything else.

### Block summary

| Offset | Block |
|---|---|
| `0x000`–`0x01F` | Identification and capabilities |
| `0x020`–`0x03F` | Control and commit |
| `0x040`–`0x0FF` | Status, interrupts, counters |
| `0x100`–`0x13F` | Stream configuration (`0x130`–`0x13F` reserved for version flow) |
| `0x140`–`0x17F` | Signal chain |
| `0x180`–`0x1FF` | Context field values |
| `0x200`–`0x23F` | Timebase |
| `0x240`–`0xFFF` | Reserved |

### Identification and capabilities (`0x000`)

| Offset | Name | Access | Bits | Reset | Description |
|---|---|---|---|---|---|
| `0x000` | `ID` | RO | 31:0 | `0x4449_4649` | ASCII `"DIFI"`. The first read after overlay load; HIL `test_pl_regs` checks it. |
| `0x004` | `VERSION` | RO | 31:24 major, 23:16 minor, 15:0 patch | build | Register map version. The major number changes on any incompatible change; the driver refuses unknown majors. |
| `0x008` | `BUILD_SHA` | RO | 31:0 | build | First 32 bits of the git SHA used for the bitstream (`GIT_SHA` in `hw/Makefile`); ties the running PL to its `<stem>`. |
| `0x00C` | `CAPS` | RO | 0 test source, 1 RSVD (growth), 2 RSVD (growth), 3 decimation power-of-two only, 15:8 sample bits, 31:16 max samples per packet | build | Build-time features the driver must check before configuring. Max samples per packet is 361 (1500-byte MTU; see [Sizing](#sizing)). |
| `0x010` | `DECIM_RANGE` | RO | 15:0 min, 31:16 max | build | Legal `DDC_DECIM` range. |
| `0x014` | `FS_IN_HZ` | RO | 31:0 | build | Nominal input sample rate in Hz. The driver derives output rate, NCO increments and timebase increment from it. |
| `0x018` | `SCRATCH` | RW | 31:0 | `0` | Bus sanity check; no effect. |
| `0x01C` | `DIFI_SPEC` | RO | 31:24 major, 23:16 minor, 15:8 patch | `0x0102_0100` | DIFI revision this build conforms to (1.2.1; see [Standard version](#standard-version)). Also declared in version context packets. The driver logs it and refuses revisions it does not know. |

### Control and commit (`0x020`)

| Offset | Name | Access | Bits | Reset | Description |
|---|---|---|---|---|---|
| `0x020` | `CTRL` | RW | 0 `ENABLE`, 1 `SOFT_RESET` (SC) | `0` | `ENABLE` 0→1 starts the stream; the first packet out is always a context packet. 1→0 finishes the current packet, then stops. `SOFT_RESET` clears datapath, FIFOs and packet counts, but keeps register values. |
| `0x024` | `COMMIT` | SC | 0 `COMMIT`, 1 `FORCE_CONTEXT` | `0` | `COMMIT` applies the shadow set at the next packet boundary (immediately when disabled). `FORCE_CONTEXT` emits an extra context packet without changing settings. |
| `0x028` | `COMMIT_STATUS` | RO | 0 `PENDING`, 1 `ERROR`, 15:8 `ERROR_CODE`, 31:16 `SEQ` | `0` | `PENDING` stays set until the commit is applied or rejected. `SEQ` increments on every applied commit. |

Commit error codes:

| Code | Meaning |
|---|---|
| `0x00` | None |
| `0x01` | `SAMPLES_PER_PKT` is below 18 or above the `CAPS` maximum |
| `0x02` | `DDC_DECIM` is outside `DECIM_RANGE`, or not a power of two when `CAPS[3]` is set |
| `0x03` | A locked (**L**) register changed while `ENABLE=1` |
| `0x04` | `PAYLOAD_FORMAT` is not supported by this build |
| `0x05` | `SRC_SEL` selects a source this build does not have |
| `0x06` | `TSI_SEL` is 0 (not allowed in DIFI) |
| `0x07` | `CTX_REF_POINT_ID` is not 100, 75, 25 or 15 |

A rejected commit leaves the active set unchanged and sets `STICKY.COMMIT_REJECTED`.

### Status, interrupts, counters (`0x040`)

| Offset | Name | Access | Bits | Reset | Description |
|---|---|---|---|---|---|
| `0x040` | `STATUS` | RO | 0 `RUNNING`, 1 `TIMEBASE_VALID`, 2 RSVD (growth) | `0` | Live state. `TIMEBASE_VALID` is set after the first seed load. |
| `0x044` | `STICKY` | W1C | 0 `FIFO_OVERFLOW`, 1 `COMMIT_REJECTED`, 2 RSVD (growth), 3 `TIMEBASE_STEP`, 4 `DDC_CLIP`, 5 `COMMIT_DONE` | `0` | Latched events. `TIMEBASE_STEP` marks a seed loaded while running. `DDC_CLIP` marks saturation at the DDC output. |
| `0x048` | `IRQ_ENABLE` | RW | same bits as `STICKY` | `0` | IRQ output = OR of (`STICKY` AND `IRQ_ENABLE`). Level-sensitive, to `pl_ps_irq0`. |
| `0x050` | `SNAP_CTRL` | SC | 0 `SNAPSHOT`, 1 `CLEAR_COUNTERS` | `0` | `SNAPSHOT` latches all **N** registers coherently across clock domains. `CLEAR_COUNTERS` zeroes the counters and the FIFO high-water mark. |
| `0x054` | `CNT_DATA_PKTS` | RO N | 31:0 | `0` | Data packets emitted (wraps). |
| `0x058` | `CNT_CTX_PKTS` | RO N | 31:0 | `0` | Context packets emitted (wraps). |
| `0x05C` | `CNT_DROPPED_SAMPLES` | RO N | 31:0 | `0` | Samples lost to FIFO overflow. |
| `0x060` | `CNT_OVERFLOW_EVENTS` | RO N | 31:0 | `0` | Distinct overflow events. |
| `0x064` | `CNT_CLIP_EVENTS` | RO N | 31:0 | `0` | DDC saturation events. |
| `0x068` | `FIFO_HIGH_WATER` | RO N | 15:0 | `0` | Deepest FIFO fill seen, in 32-bit words. Used to size the FIFO from measurements rather than guesses. |

### Stream configuration (`0x100`)

| Offset | Name | Access | Bits | Reset | Description |
|---|---|---|---|---|---|
| `0x100` | `STREAM_ID` | RW S L | 31:0 | `0` | Stream ID for data packets and their context packets. DIFI's default is 0. |
| `0x104` | `CLASS_OUI` | RO | 23:0 | `0x6A621E` | DIFI OUI. Build constant. |
| `0x108` | `CLASS_INFO_CODE` | RO | 15:0 | `0x0000` | Information class code (Basic Data Plane). Build constant. |
| `0x10C` | `CLASS_DATA_CODE` | RO | 15:0 | `0x0000` | Packet class code for data packets. Build constant. |
| `0x110` | `CLASS_CTX_CODE` | RO | 15:0 | `0x0001` | Packet class code for context packets. Build constant. |
| `0x114` | `SAMPLES_PER_PKT` | RW S L | 15:0 | `360` | Complex samples per data packet, 18 to the `CAPS` maximum; see [Sizing](#sizing). |
| `0x118` | `CTX_INTERVAL` | RW S | 23:0 | `0` | Data packets between periodic context packets; 0 = only on start, commit and overflow recovery. The driver sets it for about one context packet per second; DIFI allows at most 20 per second in total. |
| `0x11C` | `PAYLOAD_FORMAT` | RW S L | 4:0 item bits − 1 | `15` | Sample width. This build accepts only 16-bit. The other format fields (complex Cartesian, signed fixed-point) are fixed by DIFI; the PL builds the context packet's payload format field from them. |
| `0x120` | `TSI_SEL` | RW S L | 1:0 | `3` | Integer-seconds timestamp type: 1 = UTC, 2 = GPS, 3 = POSIX. 0 is rejected. Must match how the timebase was seeded; see [Field values](#field-values). |

### Signal chain (`0x140`)

| Offset | Name | Access | Bits | Reset | Description |
|---|---|---|---|---|---|
| `0x140` | `SRC_SEL` | RW S L | 1:0 | `1` | 0 = RSVD (growth), rejected with `0x05`; 1 = test tones; 2 = counter ramp, injected after the DDC at the output rate (I = n mod 2¹⁶, Q = ¬I, for bit-exact tests); 3 = zeros. |
| `0x144` | `TONE0_PHASE_INC` | RW S | 31:0 | `0` | Tone 0 frequency: f = inc × `FS_IN_HZ` / 2³². |
| `0x148` | `TONE0_AMPL` | RW S | 15:0 Q1.15 | `0x2000` | Tone 0 amplitude (about −12 dBFS). |
| `0x14C` | `TONE1_PHASE_INC` | RW S | 31:0 | `0` | Tone 1 frequency. |
| `0x150` | `TONE1_AMPL` | RW S | 15:0 Q1.15 | `0` | Tone 1 amplitude (off). |
| `0x160` | `DDC_PHASE_INC` | RW S | 31:0 signed | `0` | Mixer NCO; retune by committing while running. The driver updates `CTX_RF_REF_FREQ` in the same commit. |
| `0x164` | `DDC_DECIM` | RW S L | 15:0 | build | Total decimation. Output rate = `FS_IN_HZ` / `DDC_DECIM`. |
| `0x168` | `DDC_SHIFT` | RW S | 4:0 | build | Right-shift after the filter chain to compensate CIC gain; tune using `DDC_CLIP`. |

### Context field values (`0x180`)

These registers are copied verbatim into context packets. The driver computes them in VITA 49.2 formats; the PL does no arithmetic on them. The field set and order are fixed by DIFI (27-word Standard Flow Signal Context); the PL emits them in register order, with the Gain word as 0.

| Offset | Name | Access | Format | Description |
|---|---|---|---|---|
| `0x180` | `CTX_REF_POINT_ID` | RW S | 32-bit | Reference point: 100, 75, 25 or 15; reset 75 (RF converter analog port). |
| `0x184`/`0x188` | `CTX_BANDWIDTH_HI/_LO` | RW S | Q44.20 Hz, integer | Usable bandwidth after the decimation filters. |
| `0x18C`/`0x190` | `CTX_IF_REF_FREQ_HI/_LO` | RW S | Q44.20 Hz, integer | IF reference frequency; 0, because there is no analog IF. |
| `0x194`/`0x198` | `CTX_RF_REF_FREQ_HI/_LO` | RW S | Q44.20 Hz, integer | Center of the output band at the reference point; the NCO's actual frequency rounded to the nearest hertz. Follows `DDC_PHASE_INC`. |
| `0x19C`/`0x1A0` | `CTX_IF_BAND_OFFSET_HI/_LO` | RW S | Q44.20 Hz, integer | IF band offset; 0 for zero-IF output. |
| `0x1A4` | `CTX_REF_LEVEL` | RW S | 15:0 Q9.7 dBm | Power at the reference point of a sine wave that produces a full-scale sine in the payload. The PL emits the Scaling sub-field (bits 31:16, transmit only) as 0. |
| `0x1A8` | — | — | — | Reserved. The Gain word is reserved in v1.2.1; the PL always emits 0. |
| `0x1AC`/`0x1B0` | `CTX_SAMPLE_RATE_HI/_LO` | RW S | Q44.20 Hz, integer | Output sample rate; must equal `FS_IN_HZ` / `DDC_DECIM` exactly. |
| `0x1B4`/`0x1B8` | `CTX_TS_ADJUST_HI/_LO` | RW S | 64-bit signed, fs | Delay from the reference point to the SID location; 0 for the test source. Not the DDC delay (see [Timebase](#timebase-and-timestamps)). |
| `0x1BC` | `CTX_TS_CAL_TIME` | RW S | 32-bit, s | Last time the timestamp was known correct: integer seconds (in the `TSI_SEL` epoch) of the last seed. |
| `0x1C0` | — | — | — | Reserved. State and Event indicators are not supported (see [Standard version](#standard-version)); the PL always emits 0. |
| `0x1C4` | `CTX_CIF0` | RO | 32-bit | `0x7BB98000`, the field set this build emits. The PL sets bit 31 on context packets that announce a change. |

The sample rate is supplied by software rather than derived in the PL, which keeps the PL free of division. The driver is responsible for keeping it consistent with `DDC_DECIM`. The verification plan checks this.

### Timebase (`0x200`)

| Offset | Name | Access | Bits | Reset | Description |
|---|---|---|---|---|---|
| `0x200` | `TB_CTRL` | RW | 0 `LOAD_NOW` (SC), 3:1 RSVD (growth) | `0` | `LOAD_NOW` loads the seed immediately. |
| `0x204` | `TB_SEED_SEC` | RW | 31:0 | `0` | Integer seconds to load, in the `TSI_SEL` epoch (POSIX by default); fractional part resets to 0 on load. |
| `0x208` | `TB_INC_PS_INT` | RW | 31:0 | build | Picoseconds per `FS_IN` clock, integer part. |
| `0x20C` | `TB_INC_PS_FRAC` | RW | 31:0 | build | Fractional part, in units of 2⁻³² ps. |
| `0x210` | `TB_NOW_SEC` | RO N | 31:0 | `0` | Current integer seconds. |
| `0x214`/`0x218` | `TB_NOW_PS_HI/_LO` | RO N | 63:0 | `0` | Current fractional seconds, in picoseconds. |
| `0x21C` | — | — | — | — | RSVD (growth). |
| `0x220`/`0x224` | `TS_PIPE_DELAY_PS_HI/_LO` | RW S L | 63:0 | build | Delay from the SID location to the packetizer, in picoseconds (the DDC group delay for the committed decimation). Subtracted from every latched timestamp. 0 when `SRC_SEL` selects the counter ramp, which bypasses the DDC. |

---

## Sequences

### Initialization

1. **Load the PL.** FPGA Manager applies the overlay (`<stem>.bit.bin` + `<stem>.dtbo`); the register bank, DMA and interrupt nodes appear, and the driver probes.
2. **Identify.** Read `ID`, `VERSION`, `BUILD_SHA`, `CAPS`, `DECIM_RANGE`, `FS_IN_HZ`, `DIFI_SPEC`. Abort on a wrong `ID` or unknown `VERSION` major. Write and read back `SCRATCH`.
3. **Quiesce.** Write `CTRL.SOFT_RESET`, confirm `STATUS.RUNNING=0`, write 1s to clear `STICKY`, write `SNAP_CTRL.CLEAR_COUNTERS`.
4. **Seed the timebase.** Write `TB_INC_PS_INT/FRAC` (10¹² / `FS_IN_HZ`) and `TB_SEED_SEC` (POSIX seconds from the Linux clock). Then write `TB_CTRL.LOAD_NOW` just after a second boundary of the system clock, and confirm `STATUS.TIMEBASE_VALID`.
5. **Configure.** Write all stream, signal chain and context registers (shadow set). Derive `CTX_SAMPLE_RATE`, `CTX_BANDWIDTH` and `CTX_RF_REF_FREQ` from the same inputs used for `DDC_DECIM` and `DDC_PHASE_INC`, and refuse a decimation whose output rate is not a whole number of hertz. Write `TS_PIPE_DELAY_PS` for the decimation (0 for the counter ramp), and `CTX_TS_CAL_TIME` from the seed in step 4.
6. **Commit.** Write `COMMIT.COMMIT`, wait for `COMMIT_STATUS.PENDING=0`, check `ERROR=0`. While disabled, the commit applies immediately.
7. **Arm the DMA ring.** Queue all slots to the S2MM channel before the source can produce data.
8. **Enable interrupts.** Set `IRQ_ENABLE` for at least `FIFO_OVERFLOW`, `COMMIT_REJECTED` and `COMMIT_DONE`.
9. **Start.** Start the UDP sender, then set `CTRL.ENABLE`. The first packet on the wire is a context packet with the change indicator set, followed by the data packet with the same timestamp.

### Runtime reconfiguration (for example, a retune)

1. Write the changed shadow registers, such as `DDC_PHASE_INC` and `CTX_RF_REF_FREQ_HI/_LO`, together.
2. Write `COMMIT.COMMIT` and wait for `COMMIT_DONE` or `PENDING=0`. Space commits at least 100 ms apart (see [context rules](#context-packet-rules)).
3. The PL applies the change at the next packet boundary and emits a context packet with the change indicator set; `gr-difi` tags the stream accordingly.

To change a locked setting, such as packet size or decimation: disable, reconfigure, commit, then re-enable.

### Shutdown and PL removal

1. Clear `CTRL.ENABLE`; wait for `STATUS.RUNNING=0` (the current packet completes).
2. Let the UDP sender drain the completed ring slots, then stop it.
3. Terminate the DMA channel and free the ring; disable interrupts.
4. Only then may the overlay be removed. The driver's `remove` path performs steps 1–3 itself if the overlay is removed while streaming.

---

## Timebase and timestamps

Timestamps use TSI POSIX by default (`TSI_SEL`) and TSF real-time picoseconds, as Information Class `0x0000` requires.

The timebase is a counter in the `FS_IN` clock domain. Each clock it adds `TB_INC_PS` (a Q32.32 value in picoseconds, so non-integer periods accumulate without drift) and rolls fractional seconds over at 10¹² ps.

**What a timestamp means.** DIFI defines a data packet's timestamp as the time its first sample is present at the SID location, which for a receive device is where the ADC generates samples (spec §5.1). For the tones and zeros the SID location is the test source output; for the counter ramp, which is injected after the DDC, it is the DDC output. The packetizer latches the timebase when the packet's first output sample leaves the DDC, which is later than the corresponding input instant by the DDC's group delay. It subtracts `TS_PIPE_DELAY_PS` from the latched value (borrowing from the integer seconds when needed), so the prologue carries the SID-location time. The driver writes the group delay for the committed decimation, which is why the register is locked with `DDC_DECIM`, and writes 0 for the counter ramp, whose samples never pass through the DDC. `SRC_SEL` is locked too, so the source and the delay can only change together while disabled.

An earlier draft put the DDC delay in the context packet's Timestamp Adjustment field instead. DIFI gives that field a different meaning: the delay from the reference point (the RF input) to the SID location. For the test source it is 0.

The driver seeds the timebase from the Linux system clock (NTP or PTP disciplined) with `LOAD_NOW`, giving accuracy of a few milliseconds, and updates `CTX_TS_CAL_TIME` after each seed. Lock state is not signalled in the stream: State and Event indicators are not supported, and the word is always 0 (see the deviation note under [Standard version](#standard-version)).

---

## Loss accounting and error handling

UDP has no backpressure, so every loss point is counted rather than prevented:

| Where | Cause | Detected by |
|---|---|---|
| PL FIFO before DMA | DMA stalled (ring full) | `STICKY.FIFO_OVERFLOW`, `CNT_DROPPED_SAMPLES`, `CNT_OVERFLOW_EVENTS` |
| DDR ring | UDP sender fell behind | Sender's ring-overrun counter (the PL sees this as backpressure, then as overflow) |
| Network | Congestion, NIC drops | 4-bit packet count at the receiver; `gr-difi` emits a missed-packet tag |

After an overflow, the packetizer drops whole packets, never partial ones. It continues the packet count so receivers see the gap, and emits a context packet before resuming. That context packet re-synchronizes receivers and marks the discontinuity.

The PL FIFO only needs to cover DMA descriptor turnaround, not Linux scheduling latency, because the DDR ring absorbs the latter. Size it from `FIFO_HIGH_WATER` measured under load, not from worst-case guesses. BRAM on the ZU1 is limited.

---

## Design review

**Verdict.** Packetizing in the PL is the right architecture. The decisive reason is timestamp fidelity. Only the PL can latch the timestamp on the exact clock where a packet's first sample exists, which is what VITA 49 timestamps mean. A software packetizer can only approximate this after DMA and scheduling jitter. Secondary benefits:

- Byte-swapping and header generation cost nothing.
- Context is guaranteed consistent with data.
- The A53s stay idle.

**Board constraint.** The only Ethernet PHY is on PS GEM2 via MIO, so this is necessarily a split design: the PL builds complete packets and the PS transports them as UDP payloads. At HF rates this is what we would choose anyway; a few thousand datagrams per second is trivial for an A53 with `sendmmsg`.

Full hardware offload would need a UDP/IP stack and MAC in the PL plus a second PHY on an expansion connector. The ZU1 appears to have no PL multi-gigabit transceivers _(verify)_, so that would mean an RGMII PHY on HSIO. It is not justified at these rates.

**Keep the control plane internal.** VITA 49.2 defines control and acknowledge packets for configuring radios over the network, and this register bank is the natural backend for them later. `gr-difi` does not use them, so no network control endpoint is built until something needs one, and raw register access is never exposed over the network.

**Keep a software reference packetizer.** A host-side reference implementation that turns the same input samples into packets is the most valuable test asset in this design. Bit-exact diffs against PL output catch packetizer bugs before GNU Radio is involved.

**Risks.**

- **DIFI details:** Field values come from the Consortium's condensed v1.2.1 reference and its tooling, which disagree in places (see [Oracle caveats](#oracle-caveats)). All disagreements that affect this design are settled by independent sources.
- **Receiver strictness:** `gr-difi` targets DIFI 1.0 and by default raises errors on context packets it considers non-compliant. The interoperability test is the check.
- **CDC:** The commit and snapshot handshakes are the only multi-clock logic and deserve dedicated simulation.
- **Timestamp consistency:** The driver, not the PL, must keep `CTX_SAMPLE_RATE` and `TS_PIPE_DELAY_PS` consistent with `DDC_DECIM`.

---

## Verification plan

**RTL simulation** (`hw/sim/`, cocotb) covers seven areas:

- **Packetizer:** fed the counter-ramp source, which bypasses the DDC, and compared bit-exactly against the Python reference model. The packetizer is therefore checked independently of the DDC.
- **Commit semantics:** a commit mid-packet takes effect at the boundary, with a context packet first, the change indicator set, and the same timestamp as the following data packet.
- **Context rules:** context packets appear exactly where the [context rules](#context-packet-rules) require, with the change indicator only on start and commit.
- **Timestamps:** a single test tone with a known phase at a known timebase instant; the output phase at each packet's timestamp must match the prediction, which checks `TS_PIPE_DELAY_PS` for each decimation.
- **Rejection:** locked-register changes while enabled are rejected with the right codes.
- **Overflow:** whole-packet drops, a continuing packet count, and a context packet before resume.
- **CDC:** commit and snapshot handshakes under randomized clock ratios.

Every packet from the reference model and from RTL simulation also goes through the Consortium's Construct `validate()` functions at the pinned commit. The reference model's checker must parse the three reference captures without errors.

**HIL** (`tests/hil/`) covers four areas:

- **`test_pl_regs`:** reads `ID` = `0x4449_4649` and checks `VERSION` against the driver.
- **`test_difi_stream`** _(planned)_: enables the ramp source, captures on the runner's HIL NIC, and checks every packet against the reference model, including packet count continuity, timestamp monotonicity, and context before data.
- **`test_difi_retune`** _(planned)_: commits a new `DDC_PHASE_INC` while running and checks for exactly one context packet with the change indicator before the retuned data.
- **Interoperability** _(planned)_: runs a headless `gr-difi` flowgraph on the runner against the live stream, checks for no missed-packet tags over N seconds, and checks for a tone at the expected frequency. Captures must also pass `certify_source.py --difi-version 1.2.1` from `DIFI-Certification` at the pinned commit.

### Oracle caveats

The Consortium's tooling is the best available oracle, but it is not the spec. Known differences, all checked at commit `6ee49d1e`:

- **Reference Level and Gain words.** The Construct context definition swaps the halves of both words: it reads Reference Level from bits 31:16 and Gain 1 from bits 31:16, and carries a TODO doubting its own order. The spec reference (§4.3.1), the v1.3.0 deviation table (VITA's reserved upper bits became the Scaling sub-field) and the independently written Wireshark dissector all put Reference Level and Gain 1 in bits 15:0. The validator checks neither value, so a spec-correct packet still passes; our checker follows the spec.
- **Payload format word.** The Construct definition and the spec reference lay out the size sub-fields differently. Both layouts place every non-zero sub-field at the same bits, because DIFI requires Data Item Size and Item Packing Field Size to be equal, so the word is `0xA00003CF` either way and the difference needs no resolution for this design.
- **State and Event word.** The Construct definition models 8 enable bits and 4 reserved bits, where VITA 49 has 12 enables in bits 31:20, and it checks nothing in this word. Irrelevant here, because we emit 0; the reference captures set enables (`0xA0020000`), so they differ from our packets in this word too.
- **What the validator does not check.** `certify_source.py` accepts either CIF0 value on any context packet, and does not check change-indicator placement, context timestamps against data timestamps, context rate or integer-hertz fields. Our checker must.
- **Reference captures.** The three captures carry a value in the Gain word and 0 in Reference Level, consistent with pre-1.2.1 usage. They also set the change indicator on every context packet and send version packets as type `0x5`. Use them for parser tests, not as a template for our field values.
- **Wireshark test capture.** `wireshark-dissector/tests/difi-gnuradio-example.pcapng` comes from a pre-standard `gr-difi` (OUI `0x7C386C`) and is not a valid DIFI reference.

---

## Proposed code layout

| Path | Contents |
|---|---|
| `hw/rtl/difi/` | Test source, DDC wrapper, packetizer, timebase, register bank |
| `hw/sim/difi/` | cocotb testbenches; imports the Python reference model |
| `hw/bd/mpsoc_bd.tcl` | Adds register bank, AXI DMA, interrupt to `pl_ps_irq0` |
| `sw/apps/difi-sender/` | UDP sender (C) |
| `sw/apps/difi-ref/` | Python reference packetizer and packet checker, shared by sim and HIL |
| `sw/meta-<project>/recipes-kernel/difi-ctrl/` | Control driver (kernel module) |
| `sw/meta-<project>/recipes-apps/difi-sender/` | Sender recipe and systemd unit |
| `tests/hil/test_difi_*.py` | HIL tests above |
| `third_party/DIFI-Certification/` | Git submodule pinned at `6ee49d1e`, used as an external oracle and spec reference. Not vendored: the repository has no license file (only the Wireshark dissector is MIT-licensed). |
| `docs/difi-streaming-architecture.md` | This document |
| `docs/img/difi-pl-packetizer.png` | System diagram used in this document |

---

## Future features

Features planned beyond the baseline. The baseline does not implement them, but the register map already reserves what they need, marked **RSVD (growth)**, so adding one does not move existing registers. Each entry lists its claimed allocations.

### Direct-sampling HF ADC

A direct-sampling HF ADC is added as a second signal input, selected by the source mux ahead of the DDC; the test source stays available. The ADC produces real samples at `FS_IN`, which the DDC converts to complex baseband, as it already does for the test tones. The test source mimics this input (real samples, the same input width, left-justified in 16 bits), so the DDC and everything after it are exercised today as they will be with the ADC.

- **Reference point.** The board has no analog IF, so the RF converter analog port (the ADC input connector) is the natural reference point. The test source already uses reference point 75, so the context field values do not change when the ADC is added.
- **Timestamp Adjustment.** With the ADC, `CTX_TS_ADJUST` becomes a per-board calibration of the analog front end plus ADC latency, from the input connector to the point where the ADC generates samples; negative on receive.
- **Bit-true DDC check.** With a real counter ramp fed into the DDC input, the DDC can be compared bit-exactly against a bit-true model (own RTL, or the C models of the AMD CIC and FIR compilers). This is separate from the packetizer check, which uses the post-DDC ramp.

| Claimed allocation | Use |
|---|---|
| `CAPS` bit 1 | Build has an ADC input |
| `SRC_SEL` = 0 | Select the ADC input (rejected with `0x05` until then) |

### PPS timebase alignment

A PPS input aligns the timebase to the sample clock, beyond the few milliseconds that seeding from the Linux clock gives. The driver writes `TB_SEED_SEC` for the coming second, sets `PPS_EN` and `ARM_PPS`, and waits for `STATUS.TIMEBASE_VALID`; the PL loads the seed on the next PPS edge and clears `ARM_PPS`. At every later edge the PL records the fractional seconds in `TB_PPS_ERR_PS` (ideally 0) as a drift monitor, and `STICKY.PPS_LOST` latches when expected edges stop arriving. The driver updates `CTX_TS_CAL_TIME` after each alignment, as it does after each seed.

- **Pin.** The ZUBoard has no dedicated PPS input; it would come in on a Click or Pmod pin _(verify pinout)_.
- **Clock-domain crossing.** PPS is an asynchronous external input and needs its own synchronizer into the `FS_IN` domain. It is a third crossing, an exception to the principle that the commit and snapshot handshakes are the only ones (see [Principles](#principles)).
- **State and Event indicators.** With PPS alignment, DIFI's calibrated-time lock indicator would have something real to report. The deviation (see [Standard version](#standard-version)) could be reconsidered then; the word at `0x1C0` is plain reserved, not claimed.

| Claimed allocation | Use |
|---|---|
| `CAPS` bit 2 | Build has a PPS input |
| `STATUS` bit 2 | `PPS_PRESENT`: PPS edges are arriving |
| `STICKY` bit 2 (and `IRQ_ENABLE` bit 2) | `PPS_LOST`: expected PPS edges stopped |
| `TB_CTRL` bits 3:1 | `ARM_PPS` (load the seed on the next edge, self-clearing), `PPS_EN`, `PPS_INVERT` |
| `0x21C` | `TB_PPS_ERR_PS`: signed fractional seconds at the last PPS edge, in picoseconds |

---

## Open decisions and TODO

- [x] Choose the DIFI revision: v1.2.1, Information Class `0x0000` (see [Standard version](#standard-version)).
- [x] Resolve the DIFI field values from the Consortium's spec references, packet definitions and captures (see [Field values](#field-values)).
- [ ] Optional: cross-check against the official DIFI v1.2.1 text if it becomes available (request form at dificonsortium.org, business email required, sends 1.3.0 by default). Nothing in the design depends on it.
- [ ] Fix `FS_IN` and the input sample width for the test-source build, and the decimation range for the target HF bandwidths, so that `FS_IN_HZ` / `DDC_DECIM` is a whole number of hertz for every supported decimation. Check the rates against DIFI's Sample Rate Vendor Interoperability list.
- [ ] Choose the DDC implementation: AMD CIC and FIR compilers, or own RTL. Its group delay per decimation feeds `TS_PIPE_DELAY_PS`.
- [x] Jumbo frames: not supported, by design (see [Standard version](#standard-version)); recorded in the project README.
- [x] State and Event indicators: not supported, by design (see [Standard version](#standard-version)); recorded in the project README.
- [ ] Decide the UDP destination model: fixed host IP and port from config, or discovery.
- [ ] Consider `TSI_SEL` = GPS if a GPS-disciplined PPS is added.
- [ ] Add Version Flow (Information Class `0x0001`) only if a consumer appears.
- [ ] Revisit the revision when `certify_source.py` supports 1.3.x.
- [ ] Decide when to move from UIO + `udmabuf` to the kernel driver.
- [ ] Wire the interrupt to `pl_ps_irq0` (same fix as `axi_iic_0`).

---

## References

- IEEE-ISTO Std 4900-2021, *Digital IF Interoperability Standard*, v1.2.1 (March 2025, conformance target) and v1.3.0 (July 2025, cross-check) (DIFI Consortium, dificonsortium.org, request form)
- `DIFI-Certification` at commit `6ee49d1e`: `.claude/skills/difi/DIFI_v1.2.1.md` and `DIFI_v1.3.0.md` (condensed spec references), `packet_definitions/` (Construct definitions and validators), `example_pcaps/` (reference captures), `certify_source.py`, `certify_sink.py`
- ANSI/VITA 49.2-2017, *VITA Radio Transport (VRT) Standard for Electromagnetic Spectrum*
- DIFI Consortium GitHub: `gr-difi` (based on DIFI 1.0); `DIFI-Certification` DIFI 101 tutorial and Wireshark dissector (targets 1.2)
- `vita49` Rust crate (Voyager), Geon `vrtgen` and `wireshark-vrtgen`: open-source VITA 49.2 implementations useful as cross-checks
- AMD PG021: AXI DMA LogiCORE IP product guide
- AMD UG1085: Zynq UltraScale+ Device Technical Reference Manual
- ZUBoard 1CG Hardware User Guide v1.0 and schematic AES-ZUB-1CG-DK-G Rev 1 (Ethernet: sheet 7)
- Project: `README.md`, `edf-2026_1-followups.md` (section 3, PL overlay), `sw/meta-zub1cg/board-dts/zub1cg-board.dtsi`