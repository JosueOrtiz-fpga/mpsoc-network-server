// Testbench for top with the simulation BD (SIM=1).
//
// Every run brings up the BD's clock and reset and checks them, then runs
// the test named by +TEST=<name> (hw/sim/Makefile runs each name in TESTS):
//
//   bringup             the A53 model reaches both BRAMs through the BD's
//                       AXI BRAM controllers
//   ctl_init_handshake  the CTL BRAM word-0 handshake between the A53 and
//                       top's settings loader; +A53_DELAY=<n> starts the A53
//                       n pl_clk0 cycles after aresetn is released,
//                       +A53_ZERO=0 skips its zeroing of the CTL BRAM, and
//                       +HANDSHAKES=<n> runs n handshakes (default 2)
//
// The DDR and status models only report what they saw.
`timescale 1ns/1ps

module tb_top;
  import tb_pkg::*;

  wire scl, sda;
  pullup (scl);
  pullup (sda);

  top #(.SIM(1)) dut (
    .tempsensor_i2c_pl_scl_io(scl),
    .tempsensor_i2c_pl_sda_io(sda)
  );

  // .* connects top's own signals; the SIM=1-only ones live inside the
  // sim_mpsoc_bd generate branch and are connected by hierarchical name.
  bind top sim_bd_harness u_sim_bd_harness
    (.*, `SIM_BD_HARNESS_SIM_BD_PORTS(sim_mpsoc_bd));

  // Elaboration fails here unless SIM=1 instantiated the simulation BD:
  // this path exists only in that generate branch.
  wire bd_pl_clk0 = dut.sim_mpsoc_bd.sim_mpsco_bd_i.pl_clk0;

  localparam realtime REF_PERIOD   = 10.0ns;  // clk_100MHz into clk_wiz
  localparam realtime PL_CLK0_NOM  = 10.0ns;  // clk_wiz CLKOUT1, 100 MHz
  localparam int      SETTLE_EDGES = 64;      // pl_clk0 edges before releasing n_reset_rtl

  // CTL BRAM layout, as the A53 addresses it.
  localparam bit [31:0] CTL_STATUS = a53_model::CTL_BRAM_BASE + 32'h0;
  localparam bit [31:0] CTL_DMA_LO = a53_model::CTL_BRAM_BASE + 32'h4;
  localparam bit [31:0] CTL_DMA_HI = a53_model::CTL_BRAM_BASE + 32'h8;
  // CTL_STATUS bits. Each side sets only its own bit and preserves the other.
  localparam bit [31:0] PL_WRITTEN  = 32'h1;
  localparam bit [31:0] A53_WRITTEN = 32'h2;

  crst_vif_t crst;
  a53_model  a53;
  ddr_model  ddr;
  axis_sink #(sts_vif_t, 8) sts;

  string       test_name;
  int unsigned checks, failures;

  function automatic void check(bit ok, string what);
    checks++;
    if (ok) $display("[%0t] PASS  %s", $time, what);
    else begin
      failures++;
      $error("FAIL  %s", what);
    end
  endfunction

  // pl_clk0 period over 16 cycles, once the clock runs.
  task automatic measure_pl_clk0(output realtime period);
    realtime t0;
    @(posedge bd_pl_clk0);
    t0 = $realtime;
    repeat (16) @(posedge bd_pl_clk0);
    period = ($realtime - t0) / 16;
  endtask

  task automatic bram_round_trip(string label, bit [31:0] addr, bit [31:0] value);
    bit [31:0] got;
    a53.write32(addr, value);
    a53.read32(addr, got);
    check(got === value, $sformatf("%s: 0x%08h reads back 0x%08h (wrote 0x%08h)", label, addr, got, value));
  endtask

  // --- PL-side CTL BRAM monitor ---------------------------------------------
  // Records top's port B accesses to the CTL words (0x0-0x8) while pl_log_on
  // is set. Sampled at the edge the BRAM sees them; top's nonblocking
  // updates for that edge land after this process has read the old values.
  typedef struct {
    int unsigned cycle;
    bit          wr;
    bit [31:0]   addr;
    logic [31:0] data;   // 4-state, so an X the PL drives shows as X
  } pl_access_t;

  pl_access_t  pl_log[$];
  bit          pl_log_on;
  int unsigned pl_cycle;
  int unsigned pl_loads;   // cycles with top's load_done high, while pl_log_on

  always @(posedge bd_pl_clk0) begin
    pl_cycle++;
    if (pl_log_on && dut.BRAM_PORTB_0_en === 1'b1 && dut.BRAM_PORTB_0_addr <= 32'h8)
      pl_log.push_back('{pl_cycle, dut.BRAM_PORTB_0_we != 0, dut.BRAM_PORTB_0_addr,
                         dut.BRAM_PORTB_0_din});
    if (pl_log_on && dut.load_done === 1'b1) pl_loads++;
  end

  function automatic string pl_access_str(pl_access_t a, int unsigned t0);
    if (a.wr) return $sformatf("+%0d  PL write 0x%01h = 0x%08h", a.cycle - t0, a.addr, a.data);
    else      return $sformatf("+%0d  PL read  0x%01h", a.cycle - t0, a.addr);
  endfunction

  initial begin : clock_ref
    crst = dut.u_sim_bd_harness.crst_if;
    forever #(REF_PERIOD / 2) crst.clk_100MHz = ~crst.clk_100MHz;
  end

  initial begin : watchdog
    #500us;
    $fatal(1, "watchdog: test did not finish within 500 us");
  end

  initial begin : test
    if (!$value$plusargs("TEST=%s", test_name)) test_name = "bringup";

    crst = dut.u_sim_bd_harness.crst_if;
    a53  = new(dut.u_sim_bd_harness.bram0_if, dut.u_sim_bd_harness.bram1_if);
    ddr  = new(dut.u_sim_bd_harness.ddr_if);
    sts  = new("sts", dut.u_sim_bd_harness.sts_if);
    a53.idle();
    ddr.idle();
    sts.idle();

    $display("[%0t] tb_top: top elaborated with SIM=1, test %s (%m)", $time, test_name);

    clock_and_reset();
    ddr.run();
    sts.run();

    case (test_name)
      "bringup":            test_bringup();
      "ctl_init_handshake": test_ctl_init_handshake();
      default: $fatal(1, "unknown +TEST=%s (known: bringup, ctl_init_handshake)", test_name);
    endcase

    finish();
  end

  // Brings up clk_wiz and proc_sys_reset; returns in the time step aresetn
  // goes high.
  task automatic clock_and_reset();
    realtime period;

    crst.reset_rtl   = 1'b1;
    crst.n_reset_rtl = 1'b0;
    #(20 * REF_PERIOD);
    crst.reset_rtl = 1'b0;   // clk_wiz starts locking

    fork
      begin
        repeat (SETTLE_EDGES) @(posedge bd_pl_clk0);
      end
      begin
        #50us;
        $fatal(1, "pl_clk0 did not start within 50 us of releasing reset_rtl");
      end
    join_any
    disable fork;
    measure_pl_clk0(period);
    check(period > 0.99 * PL_CLK0_NOM && period < 1.01 * PL_CLK0_NOM,
          $sformatf("pl_clk0 runs at %.3f ns (nominal %.1f ns)", period, PL_CLK0_NOM));

    check(dut.aresetn === 1'b0, "aresetn held low while n_reset_rtl is low");
    crst.n_reset_rtl = 1'b1;
    fork
      wait (dut.aresetn === 1'b1);
      begin
        #10us;
      end
    join_any
    disable fork;
    check(dut.aresetn === 1'b1, $sformatf("aresetn released by proc_sys_reset (%0t)", $time));
    check(dut.bus_struct_reset_0 === 1'b0, "bus_struct_reset_0 released");
  endtask

  // --- bringup ---------------------------------------------------------------
  task automatic test_bringup();
    bit [31:0] word;

    repeat (8) @(posedge bd_pl_clk0);

    // top's settings loader rewrites CTL word 0 continuously, so the round
    // trips use words it does not touch.
    bram_round_trip("CTL BRAM", a53_model::CTL_BRAM_BASE + 32'h100, 32'hC0DE_0100);
    bram_round_trip("CTL BRAM", a53_model::CTL_BRAM_BASE + 32'hFFC, 32'hC0DE_0FFC);
    bram_round_trip("DMA BRAM", a53_model::DMA_BRAM_BASE + 32'h100, 32'hD3A0_0100);
    bram_round_trip("DMA BRAM", a53_model::DMA_BRAM_BASE + 32'hFFC, 32'hD3A0_0FFC);

    // Same offset in both: the two ports must reach two different memories.
    a53.write32(a53_model::CTL_BRAM_BASE + 32'h200, 32'h1111_1111);
    a53.write32(a53_model::DMA_BRAM_BASE + 32'h200, 32'h2222_2222);
    a53.read32(a53_model::CTL_BRAM_BASE + 32'h200, word);
    check(word === 32'h1111_1111, $sformatf("CTL and DMA BRAMs are separate (CTL +0x200 = 0x%08h)", word));

    check(a53.errors == 0, $sformatf("A53 accesses all completed with OKAY (%0d errors)", a53.errors));

    // What top itself has done so far: reported, not checked.
    a53.read32(a53_model::CTL_BRAM_BASE, word);
    $display("[%0t] INFO  CTL BRAM word 0 = 0x%08h (written by top's settings loader)", $time, word);
    $display("[%0t] INFO  DDR model: %0d bursts, %0d beats; status sink: %0d words; irq %s",
             $time, ddr.bursts, ddr.beats, sts.received.size(),
             dut.u_sim_bd_harness.irq === 1'b1 ? string'("high") : string'("low"));
  endtask

  // --- ctl_init_handshake ----------------------------------------------------
  // The PL is configured before the A53's application starts, so the PL has
  // already set PL_WRITTEN. Each handshake:
  //
  //   A53  optionally zeroes the CTL BRAM (+A53_ZERO=1, the default; this
  //        clears PL_WRITTEN), writes the settings, waits for 0x1
  //   A53  sets A53_WRITTEN on top of PL_WRITTEN                   -> 0x3
  //   PL   clears PL_WRITTEN, reads 0x4 and 0x8, holds             -> 0x2
  //   A53  sees 0x2, clears A53_WRITTEN                            -> 0x0
  //   PL   sets PL_WRITTEN, ready for the next handshake           -> 0x1
  //
  // +HANDSHAKES=<n> (default 2) runs n of them, each with its own DMA
  // address, so a second handshake has to reload the PL's registers. Then
  // the PL must stay at 0x1 without loading again.
  localparam int unsigned STATUS_POLLS  = 1000;  // A53 reads of CTL_STATUS before giving up
  localparam int unsigned HOLD_WINDOW   = 200;   // pl_clk0 cycles the A53 waits at 0x2 before acking
  localparam int unsigned SETTLE_WINDOW = 2000;  // pl_clk0 cycles watched after the last handshake
  localparam int unsigned LOG_SHOWN     = 16;    // PL accesses printed per handshake

  // Reads CTL_STATUS until it equals EXPECT or STATUS_POLLS reads have gone by.
  task automatic poll_status(bit [31:0] expect_val, output bit [31:0] word, output int unsigned polls);
    polls = 0;
    do begin
      a53.read32(CTL_STATUS, word);
      polls++;
    end while (word !== expect_val && polls < STATUS_POLLS);
  endtask

  task automatic test_ctl_init_handshake();
    // DMA buffers from 0x8_0010_0000 up, in the ZynqMP's upper DDR region,
    // so neither word is zero; each handshake moves the low word.
    localparam bit [31:0] DMA_LO_BASE = 32'h0010_0000;
    localparam bit [31:0] DMA_HI      = 32'h0000_0008;

    int unsigned delay = 0;
    int unsigned zero  = 1;
    int unsigned handshakes = 2;

    if (!$value$plusargs("A53_DELAY=%d", delay)) delay = 0;
    if (!$value$plusargs("A53_ZERO=%d", zero)) zero = 1;
    if (!$value$plusargs("HANDSHAKES=%d", handshakes)) handshakes = 2;
    $display("[%0t] INFO  A53 starts %0d pl_clk0 cycles after aresetn release, %0d handshakes, %s the CTL BRAM",
             $time, delay, handshakes, zero ? string'("zeroing") : string'("not zeroing"));
    repeat (delay) @(posedge bd_pl_clk0);

    for (int unsigned h = 1; h <= handshakes; h++) begin
      bit ok;
      one_handshake(h, DMA_LO_BASE + (h - 1) * 32'h0010_0000, DMA_HI, zero, ok);
      if (!ok) return;
    end

    settle();
    check(a53.errors == 0, $sformatf("A53 accesses all completed with OKAY (%0d errors)", a53.errors));
  endtask

  // One handshake; OK is 0 when the PL did not re-arm, which leaves the next
  // handshake nothing to start from.
  task automatic one_handshake(int unsigned h, bit [31:0] lo, bit [31:0] hi, bit zero, output bit ok);
    string       tag = $sformatf("handshake %0d: ", h);
    bit [31:0]   word;
    int unsigned polls, t0, t_clr;
    int          ack, rearm;
    bit          saw_lo, saw_hi, pl_wrote_settings;
    pl_access_t  a;
    ok = 0;

    // 1. Optionally zero the CTL BRAM, then write the settings.
    if (zero)
      for (bit [31:0] off = 0; off < a53_model::SIM_BRAM_BYTES; off += 4)
        a53.write32(a53_model::CTL_BRAM_BASE + off, 32'h0);
    a53.write32(CTL_DMA_LO, lo);
    a53.write32(CTL_DMA_HI, hi);
    $display("[%0t] INFO  %sA53 %swrote the DMA address 0x%08h_%08h", $time, tag,
             zero ? string'("zeroed the CTL BRAM and ") : string'(""), hi, lo);

    // 2. Wait for the PL to be ready.
    poll_status(PL_WRITTEN, word, polls);
    check(word === PL_WRITTEN, $sformatf("%sA53 reads CTL_STATUS = 0x%08h after %0d polls (expect 0x%08h)",
                                         tag, word, polls, PL_WRITTEN));
    if (word !== PL_WRITTEN) return;

    // 3. Set A53_WRITTEN without clearing PL_WRITTEN. The monitor runs from
    // before the write is issued, so it also sees PL writes that race it.
    pl_log.delete();
    pl_loads  = 0;
    pl_log_on = 1;
    t0 = pl_cycle;
    a53.write32(CTL_STATUS, word | A53_WRITTEN);

    // 4. Wait for the PL to finish loading, then give it time to misbehave.
    poll_status(A53_WRITTEN, word, polls);
    check(word === A53_WRITTEN, $sformatf("%sA53 reads CTL_STATUS = 0x%08h after %0d polls (expect 0x%08h, loaded)",
                                          tag, word, polls, A53_WRITTEN));
    if (word === A53_WRITTEN) begin
      repeat (HOLD_WINDOW) @(posedge bd_pl_clk0);
      a53.read32(CTL_STATUS, word);
      check(word === A53_WRITTEN, $sformatf("%sPL holds CTL_STATUS = 0x%08h for %0d cycles until the A53 acks (expect 0x%08h)",
                                            tag, word, HOLD_WINDOW, A53_WRITTEN));

      // 5. Acknowledge, then wait for the PL to re-arm.
      t_clr = pl_cycle;
      a53.write32(CTL_STATUS, word & ~A53_WRITTEN);
      poll_status(PL_WRITTEN, word, polls);
      check(word === PL_WRITTEN, $sformatf("%sPL re-arms: A53 reads CTL_STATUS = 0x%08h %0d polls after clearing A53_WRITTEN (expect 0x%08h)",
                                           tag, word, polls, PL_WRITTEN));
    end
    pl_log_on = 0;

    $display("[%0t] INFO  %sPL accesses to CTL 0x0-0x8 from the A53's 0x3 write (first %0d of %0d):",
             $time, tag, LOG_SHOWN < pl_log.size() ? LOG_SHOWN : pl_log.size(), pl_log.size());
    foreach (pl_log[i]) if (i < LOG_SHOWN) $display("          %s", pl_access_str(pl_log[i], t0));

    // 6. The PL's sequence, from the log. Before the A53's write lands the
    // PL may still be writing 0x1; afterwards, rewriting 0x3 is harmless.
    // The first write of anything else is the PL's answer, and must be 0x2.
    foreach (pl_log[i]) if (pl_log[i].wr && pl_log[i].addr != 0) pl_wrote_settings = 1;
    check(!pl_wrote_settings, {tag, "PL never writes the settings words (0x4, 0x8)"});

    ack = -1;
    foreach (pl_log[i]) begin
      a = pl_log[i];
      if (a.wr && a.addr == 0 && a.data !== (PL_WRITTEN | A53_WRITTEN) && a.data !== PL_WRITTEN) begin
        ack = i;
        break;
      end
    end
    check(ack >= 0 && pl_log[ack].data === A53_WRITTEN,
          ack < 0 ? $sformatf("%sPL clears PL_WRITTEN (writes 0x%08h): it never did", tag, A53_WRITTEN)
                  : $sformatf("%sPL clears PL_WRITTEN: first new CTL_STATUS write is 0x%08h at +%0d (expect 0x%08h)",
                              tag, pl_log[ack].data, pl_log[ack].cycle - t0, A53_WRITTEN));
    if (ack >= 0 && pl_log[ack].data === A53_WRITTEN) begin
      // Settings read after the clear; the next CTL_STATUS write is the
      // re-arm, 0x1, and only after the A53 has acked.
      rearm = -1;
      for (int i = ack + 1; i < pl_log.size(); i++) begin
        a = pl_log[i];
        if (!a.wr && a.addr == 32'h4) saw_lo = 1;
        if (!a.wr && a.addr == 32'h8) saw_hi = 1;
        if (a.wr && a.addr == 0) begin
          rearm = i;
          break;
        end
      end
      check(saw_lo && saw_hi, $sformatf("%sPL reads 0x4 and 0x8 after clearing PL_WRITTEN (0x4 %s, 0x8 %s)", tag,
                                        saw_lo ? string'("read") : string'("not read"),
                                        saw_hi ? string'("read") : string'("not read")));
      check(rearm >= 0 && pl_log[rearm].data === PL_WRITTEN && pl_log[rearm].cycle > t_clr,
            rearm < 0 ? $sformatf("%sPL's next CTL_STATUS write is the re-arm: it never wrote again", tag)
                      : $sformatf("%sPL's next CTL_STATUS write is 0x%08h at +%0d, A53 acked at +%0d (expect 0x%08h after the ack)",
                                  tag, pl_log[rearm].data, pl_log[rearm].cycle - t0, t_clr - t0, PL_WRITTEN));
    end

    check(pl_loads == 1, $sformatf("%sPL pulses load_done once (%0d times)", tag, pl_loads));
    check(dut.dma_reg_LO === lo && dut.dma_reg_HI === hi,
          $sformatf("%sPL holds DMA address 0x%08h_%08h (A53 wrote 0x%08h_%08h)",
                    tag, dut.dma_reg_HI, dut.dma_reg_LO, hi, lo));
    ok = (word === PL_WRITTEN);
  endtask

  // After the last handshake: no CTL_STATUS writes, no loads.
  task automatic settle();
    bit [31:0]   word;
    int unsigned writes = 0;
    int unsigned t0;
    pl_log.delete();
    pl_loads  = 0;
    pl_log_on = 1;
    t0 = pl_cycle;
    repeat (SETTLE_WINDOW) @(posedge bd_pl_clk0);
    pl_log_on = 0;
    foreach (pl_log[i]) if (pl_log[i].wr) begin
      writes++;
      $display("          %s", pl_access_str(pl_log[i], t0));
    end
    check(writes == 0 && pl_loads == 0,
          $sformatf("PL stays idle for %0d cycles after the last handshake (%0d CTL writes, %0d loads)",
                    SETTLE_WINDOW, writes, pl_loads));
    a53.read32(CTL_STATUS, word);
    check(word === PL_WRITTEN, $sformatf("A53 reads CTL_STATUS = 0x%08h at the end (expect 0x%08h)", word, PL_WRITTEN));
  endtask

  // --- summary ---------------------------------------------------------------
  task automatic finish();
    int unsigned tb_side, dut_side;
    // Interfaces the testbench drives, or answers as a slave.
    tb_side = dut.u_sim_bd_harness.bram0_if.violations
            + dut.u_sim_bd_harness.bram1_if.violations
            + dut.u_sim_bd_harness.ddr_if.violations
            + dut.u_sim_bd_harness.sts_if.violations;
    // Interfaces top drives.
    dut_side = dut.u_sim_bd_harness.data_if.violations
             + dut.u_sim_bd_harness.cmd_if.violations;

    $display("");
    $display("==== tb_top summary: %s ====", test_name);
    $display("checks:  %0d run, %0d failed", checks, failures);
    $display("protocol checks, testbench and BD side: %0d violations", tb_side);
    $display("protocol checks, top's outputs:  data %0d, cmd %0d",
             dut.u_sim_bd_harness.data_if.violations, dut.u_sim_bd_harness.cmd_if.violations);
    if (failures == 0 && tb_side == 0 && dut_side == 0) $display("TEST PASSED");
    else if (failures == 0 && tb_side == 0) $display("TEST FAILED: checks passed, top violates AXI4-Stream (see the first errors above)");
    else $display("TEST FAILED");
    $finish;
  endtask
endmodule
