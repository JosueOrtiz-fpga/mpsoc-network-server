# v1.0.0 MVP evaluation

Evaluation of the pulled-in v1.0.0 minimum viable product against the repository as of 1 October 2026 (`feature/M1` at `f69653e`), the [development plan](development_plan.md) and the [architecture](difi-streaming-architecture.md).

> **Status:** evaluation, not approved. Nothing here changes the plan or the architecture until the [decisions](#decisions) are made and both documents carry a deviation note.

---

## Contents

- [Proposed MVP](#proposed-mvp)
- [Verdict](#verdict)
- [Gaps in the MVP as listed](#gaps-in-the-mvp-as-listed)
- [Recommendations](#recommendations)
- [Decisions](#decisions)
- [Effort](#effort)
- [Branch and order of work](#branch-and-order-of-work)

---

## Proposed MVP

| Part | Content |
|---|---|
| PL | RTL single-tone generator; full AXI4-Lite register map, one commit after initialization, retune untested; packetizer; PL-driven DMA into a DDR buffer; descriptor BRAM in the PL that Linux fills with packet destinations; interrupt to Linux per written packet; timebase to be decided |
| PS | Linux booted by U-Boot, PL applied at boot (the R0 bench baseline) |
| Host | `gr-difi` and GNU Radio; a GUI shows the tone and plays it as audio |

All of it on a separate branch.

## Verdict

Achievable, and most of its simplifications are good ones. The list is missing a few pieces, and two items are not true of the repository yet: the PS has no port the PL can write DDR through, and the host side does not work on a live stream.

---

## Gaps in the MVP as listed

1. **Nothing sends the packets.** The list ends at "the interrupt tells Linux a packet landed". A process on the PS has to read the slots, send each packet as one UDP datagram and release the slot. At the rate below that is about 140 packets/s, so a small Python sender (UIO for the interrupt, `mmap` for the ring, a UDP socket) is enough. Whether `python3` is in the image _(verify)_.
2. **The PS has no port for the PL to write DDR.** `hw/bd/mpsoc_bd.tcl` at R0 enables only `M_AXI_HPM1_FPD` and `IRQ0`; every `S_AXI_HP*` and `S_AXI_HPC*` port is off. A PL-driven DMA is therefore a PS change: BOOT.BIN, the platform and the Yocto image are rebuilt, and the R0 HIL tests rerun. Enable **`S_AXI_HPC0_FPD`**, the port the architecture plans, and use it non-coherently for now, so that the later PS freeze still holds.
3. **The DDR buffer comes from the image.** Either a `reserved-memory` node in `zub1cg-board.dtsi` or the u-dma-buf recipe, plus UIO bindings. Item 2 rebuilds the image anyway; `reserved-memory` is simpler, because it needs no out-of-tree module.
4. **The host side does not show the tone on a live stream yet.** `make ref-rx-check` passes only because the replay swaps the sample bytes before sending ([gr-difi#19](https://github.com/DIFI-Consortium/gr-difi/issues/19)). A live board stream gives a garbage spectrum and noise in the audio. The repository also has no GUI or audio flowgraph; the pre-check is headless. The fix belongs in the flowgraph: DIFI Source → Complex To IShort → Endian Swap (item size 2) → IShort To Complex. The board stream stays big-endian DIFI.
5. **A single real tone is not valid DIFI without a DDC.** DIFI requires complex samples; that is why the architecture puts a DDC after the real test tone. The [tone generator](#recommendations) below produces the DDC's output directly.

---

## Recommendations

| Topic | Recommendation |
|---|---|
| Clocking | Run the whole PL datapath on `pl_clk0` at 100 MHz and report `FS_IN_HZ` = 100,000,000. `DDC_DECIM` = 2000 gives 50 kS/s: a multiple of 4, inside `DECIM_RANGE`, a whole number of hertz. One clock domain removes all five CDC synchronizers, and the 10 ns period is exactly 10,000 ps. GNU Radio resamples 24/25 to 48 kHz for audio. |
| Tone generator | A phase accumulator that adds `TONE0_PHASE_INC − DDC_PHASE_INC` every clock, with a cos/sin lookup sampled every `DDC_DECIM` clocks and scaled by `TONE0_AMPL`. For a single tone this is exactly an ideal DDC's output, so the register meanings and `CTX_RF_REF_FREQ` stay honest, with no multipliers in the accumulator and no CIC. |
| Counter ramp | Also implement `SRC_SEL` = 2. A few lines of RTL, and the only way to check board packets bit-exactly against `difi_ref`. |
| Timebase | A PL counter: 32-bit seconds and a 40-bit picosecond count that adds 10,000 per clock and rolls over at 10¹². Linux writes `TB_SEED_SEC` and `TB_CTRL.LOAD_NOW` once, just after a second boundary. The packetizer latches the time at each packet's first sample; with no DDC in the path, `TS_PIPE_DELAY_PS` is 0. State and Event is `0xA0000000` (not locked), which is true without rate steering. Time drifts at the oscillator's error, about 90 ms/h at 25 ppm; release notes say so. |
| Register bank | Full decode. With one clock a commit is a one-cycle copy from the shadow to the active set. Any change while enabled is rejected with `0x03`, as the plan's [interim behaviour](development_plan.md#interim-behaviour) already specifies, so "retune untested" becomes "retune rejected", which is honest and testable. |
| Descriptor BRAM | Drop it. The buffer is physically contiguous, so per-slot descriptors carry no information. Registers instead: ring base address, slot count, a producer index advanced by the PL and a consumer index advanced by Linux. Slot address = base + index × 2 KB. |
| Packet writer | Build each packet in a small BRAM buffer and write it in one AXI4 burst: 92 beats at 128 bits, inside a 2 KB-aligned slot, so it never crosses a 4 KB boundary. When the ring is full, drop the whole packet, count it, and send a context packet before resuming: whole-packet drops without sizing a FIFO. |
| Coherency | Non-coherent: `AWCACHE` = `0011` (normal, non-cacheable, bufferable) and an uncached mapping on the PS. This avoids R1's largest open risk. |
| Biggest RTL risk | The custom AXI4 writer. It needs an AXI slave model in simulation (cocotbext-axi), which means a Python venv, because LNXPC has no pip. Fallback: the AXI DMA IP in simple mode, re-armed per packet by the sender through UIO; about 140 re-arms per second is easy. |

---

## Decisions

- [ ] **Tag.** The approved plan gives `v1.0.0` to R7 (baseline complete, 24 h soak, certified captures) and says releases do not change the architecture. This MVP does: 100 MHz input clock, no DDC, a custom writer instead of AXI DMA and a kernel driver, non-coherent DMA, no rate steering. Either tag the MVP `v1.0.0` and renumber the plan, or tag it `v0.3.0`. Both work; the plan and the architecture need a deviation note either way.
- [ ] **Standalone boot.** Today the board boots only on the bench (JTAG and netboot over NFS). If v1.0.0 must boot from SD with the PL package on the card, B2 is in scope: another 22–39 h.
- [ ] **Deadline.** The estimate below is 9–15 weeks at 10 h/week. If the date is earlier, cut further.

---

## Effort

Rough estimate for one developer, on the plan's [assumptions](development_plan.md#planning-assumptions).

| Item | Effort (h) |
|---|---|
| PS port, `reserved-memory`, UIO; full rebuild and R0 HIL regression | 6–12 |
| Register bank (single clock, commit while disabled, error codes, counters, `STICKY` and IRQ) with tests | 15–25 |
| Tone generator, ramp, sample strobe | 4–8 |
| Timebase | 2–4 |
| Packetizer (data and context, counts, periodic context, change indicator), bit-exact against `difi_ref` | 15–25 |
| AXI4 burst writer and slot ring, with an AXI slave model in simulation | 12–20 |
| Block design integration, timing, overlay and UIO binding | 6–12 |
| Board sender and initialization sequence | 12–20 |
| GNU Radio flowgraph: byte swap, waterfall, audio | 2–4 |
| HIL tests (registers, capture through the checker, stream smoke test) and `make release` | 8–15 |
| Documentation and plan amendment | 3–6 |
| **Total** | **85–150** |

That compares with 205–295 h for R1 to R3 in the plan; the savings come from the single clock domain, no kernel driver and no coherency work.

---

## Branch and order of work

Branch from `feature/M1` HEAD (`f69653e`), not `main`: `main` has only `difi_ref` iteration 1, without the checker, decoder, capture reader and ramp. M1 iterations 4 to 6 can wait.

1. PS port, `reserved-memory` and UIO; rerun the R0 HIL tests.
2. Register bank, timebase, ramp, tone, packetizer and writer, checked in simulation against `difi_ref`.
3. A board capture through the checker.
4. The sender, and the GNU Radio flowgraph with the byte swap and audio.
5. HIL tests and `make release`.
