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
//   s2mm_dma            after one handshake, top's packets reach DDR through
//                       the DataMover: commands, stream, DDR contents, status,
//                       DMA BRAM descriptor and interrupt; +PACKETS=<n>
//                       (default 3), +DDR_THROTTLE=<p> drops the DDR model's
//                       WREADY on p% of cycles, +IRQ_LATENCY=<n> (default 100)
//
// Outside s2mm_dma the DDR and status models only report what they saw.
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

  // --- S2MM monitors ----------------------------------------------------------
  // What top hands the DataMover and the PS, from reset on: commands and
  // stream beats as accepted (TVALID and TREADY), interrupt rising edges, and
  // port B writes to the DMA BRAM. The AXI4-Stream monitors sample through the
  // interfaces' clocking blocks, since TREADY comes from the DataMover; irq and
  // port B are top's own registers, sampled like the CTL monitor above.
  typedef struct { realtime t; logic [79:0] cmd; } cmd_rec_t;
  typedef struct { realtime t; logic [31:0] data; logic [3:0] keep; logic last; } beat_rec_t;
  typedef struct { realtime t; logic [31:0] addr; logic [31:0] data; logic [3:0] we; } dma_wr_t;

  cmd_rec_t  cmd_log[$];
  beat_rec_t beat_log[$];
  realtime   irq_log[$];
  dma_wr_t   dma_wr_log[$];
  logic      irq_q;

  initial begin : s2mm_cmd_mon
    cmd_vif_t vif;
    vif = dut.u_sim_bd_harness.cmd_if;
    forever begin
      @(vif.mon_cb);
      if (vif.mon_cb.tvalid === 1'b1 && vif.mon_cb.tready === 1'b1)
        cmd_log.push_back('{$realtime, vif.mon_cb.tdata});
    end
  end

  initial begin : s2mm_data_mon
    data_vif_t vif;
    vif = dut.u_sim_bd_harness.data_if;
    forever begin
      @(vif.mon_cb);
      if (vif.mon_cb.tvalid === 1'b1 && vif.mon_cb.tready === 1'b1)
        beat_log.push_back('{$realtime, vif.mon_cb.tdata, vif.mon_cb.tkeep, vif.mon_cb.tlast});
    end
  end

  always @(posedge bd_pl_clk0) begin
    if (dut.pl_ps_irq1_0 === 1'b1 && irq_q !== 1'b1) irq_log.push_back($realtime);
    irq_q <= dut.pl_ps_irq1_0;
    if (dut.BRAM_PORTB_1_en === 1'b1 && dut.BRAM_PORTB_1_we !== 4'b0)
      dma_wr_log.push_back('{$realtime, dut.BRAM_PORTB_1_addr, dut.BRAM_PORTB_1_din, dut.BRAM_PORTB_1_we});
  end

  function automatic int cycles(realtime from, realtime to);
    return int'((to - from) / PL_CLK0_NOM);
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
      "s2mm_dma":           test_s2mm_dma();
      default: $fatal(1, "unknown +TEST=%s (known: bringup, ctl_init_handshake, s2mm_dma)", test_name);
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

  // --- s2mm_dma --------------------------------------------------------------
  // top's S2MM path once one handshake has loaded a DMA address: the dummy
  // stream, one DataMover command per packet, the packet in DDR, its status,
  // the DMA BRAM descriptor and the interrupt. Expected values come from top's
  // own constants (PKT_LENGTH, XCACHE_CACHEABLE, XUSER_DEFAULT, CMD_TAG) and
  // from the DataMover as the BD configures it (PG022): 32-bit address with
  // xCACHE and xUSER, so the 80-bit command s2mm_cmd_t and the 8-bit status
  // s2mm_sts_t below.
  //
  // A packet is PKT_LENGTH 32-bit beats carrying 0, 1, ..., with TLAST on the
  // last. Its command must cover exactly that packet (BTT = 4 * PKT_LENGTH
  // bytes), so the DataMover writes it at SADDR and nowhere else. On each
  // interrupt the A53 waits +IRQ_LATENCY cycles, reads the DMA BRAM slot,
  // expects {PKT_LENGTH, valid}, and zeroes it again, as top assumes.
  typedef struct packed {
    bit [3:0]  xcache;
    bit [3:0]  xuser;
    bit [3:0]  rsvd;
    bit [3:0]  tag;
    bit [31:0] saddr;
    bit        drr;
    bit        eof;
    bit [5:0]  dsa;
    bit        incr;
    bit [22:0] btt;
  } s2mm_cmd_t;

  typedef struct packed {
    bit       okay;
    bit       slverr;
    bit       decerr;
    bit       interr;
    bit [3:0] tag;
  } s2mm_sts_t;

  localparam bit [31:0] DMA_SLOT = a53_model::DMA_BRAM_BASE;  // descriptor word

  function automatic string cmd_str(s2mm_cmd_t c);
    return $sformatf("BTT %0d, INCR %0d, DSA %0d, EOF %0d, DRR %0d, SADDR 0x%08h, TAG %0h, RSVD %0h, xUSER %0h, xCACHE %0h",
                     c.btt, c.incr, c.dsa, c.eof, c.drr, c.saddr, c.tag, c.rsvd, c.xuser, c.xcache);
  endfunction

  task automatic test_s2mm_dma();
    // A buffer in low DDR, which a 32-bit DataMover address can reach.
    localparam bit [31:0] DMA_LO = 32'h1000_0000;
    localparam bit [31:0] DMA_HI = 32'h0000_0000;

    int unsigned packets = 3, throttle = 0, latency = 100;
    int unsigned pkt_beats, pkt_bytes, timeout, waited, beat, k, n, bad;
    string       first_bad;
    s2mm_cmd_t   exp_cmd;
    s2mm_sts_t   status;
    bit [31:0]   exp_desc;
    bit [31:0]   desc_log[$];   // the slot as the A53 read it, per interrupt
    realtime     pkt_start[$], pkt_last[$];
    realtime     t0, t_ddr, lag_max;
    bit          ok, stop_a53;
    ddr_model::w_beat_t w;

    if (!$value$plusargs("PACKETS=%d", packets)) packets = 3;
    if (!$value$plusargs("DDR_THROTTLE=%d", throttle)) throttle = 0;
    if (!$value$plusargs("IRQ_LATENCY=%d", latency)) latency = 100;
    if (throttle > 90) $fatal(1, "+DDR_THROTTLE=%0d: at most 90", throttle);
    ddr.wready_throttle = throttle;

    pkt_beats = dut.PKT_LENGTH;
    pkt_bytes = 4 * pkt_beats;
    exp_cmd        = '0;
    exp_cmd.xcache = dut.XCACHE_CACHEABLE;
    exp_cmd.xuser  = dut.XUSER_DEFAULT;
    exp_cmd.tag    = 4'(dut.CMD_TAG);
    exp_cmd.saddr  = DMA_LO;
    exp_cmd.eof    = 1'b1;
    exp_cmd.incr   = 1'b1;
    exp_cmd.btt    = pkt_bytes;
    exp_desc       = {31'(pkt_beats), 1'b1};
    $display("[%0t] INFO  %0d packets of %0d beats, DDR WREADY low on %0d%% of cycles, A53 answers irq after %0d cycles",
             $time, packets, pkt_beats, throttle, latency);

    // 1. The A53 zeroes the descriptor slot and installs its interrupt
    // handler, then loads the DMA address through the CTL handshake.
    a53.write32(DMA_SLOT, 32'h0);
    stop_a53 = 0;
    fork
      begin
        int unsigned handled = 0;
        bit [31:0]   word;
        while (!stop_a53) begin
          @(posedge bd_pl_clk0);
          if (irq_log.size() > handled) begin
            handled++;
            repeat (latency) @(posedge bd_pl_clk0);
            a53.read32(DMA_SLOT, word);
            desc_log.push_back(word);
            a53.write32(DMA_SLOT, 32'h0);
          end
        end
      end
    join_none

    one_handshake(1, DMA_LO, DMA_HI, 1'b1, ok);
    if (!ok) begin
      stop_a53 = 1;
      return;
    end

    // 2. Wait for PACKETS interrupts, allowing each packet four times its
    // length at the throttled rate, then for the last one to drain.
    timeout = 1000 + packets * pkt_beats * 4 * 100 / (100 - throttle);
    for (waited = 0; irq_log.size() < packets && waited < timeout; waited++) @(posedge bd_pl_clk0);
    repeat (latency + 500) @(posedge bd_pl_clk0);
    stop_a53 = 1;

    // 3. The stream: whole packets of PKT_LENGTH beats counting from 0.
    bad = 0;
    beat = 0;
    foreach (beat_log[i]) begin
      if (pkt_last.size() >= packets) break;
      if (beat == 0) pkt_start.push_back(beat_log[i].t);
      if (beat_log[i].data !== beat || beat_log[i].keep !== 4'hF || beat_log[i].last !== (beat == pkt_beats - 1))
        if (bad++ == 0)
          first_bad = $sformatf("packet %0d beat %0d: TDATA 0x%08h TKEEP %b TLAST %b", pkt_last.size(), beat,
                                beat_log[i].data, beat_log[i].keep, beat_log[i].last);
      if (beat_log[i].last === 1'b1) begin
        pkt_last.push_back(beat_log[i].t);
        beat = 0;
      end else beat++;
    end
    check(pkt_last.size() >= packets,
          $sformatf("stream: DataMover accepted %0d whole packets (expect %0d); %0d beats in all, TVALID %b TREADY %b now",
                    pkt_last.size(), packets, beat_log.size(), dut.S_AXIS_S2MM_0_tvalid, dut.S_AXIS_S2MM_0_tready));
    check(bad == 0, bad == 0 ? $sformatf("stream: the %0d beats checked are in sequence (packets of %0d beats 0..%0d, TKEEP 1111, TLAST on the last)",
                                         beat_log.size() < packets * pkt_beats ? beat_log.size() : packets * pkt_beats,
                                         pkt_beats, pkt_beats - 1)
                             : $sformatf("stream: %0d beats wrong, first %s", bad, first_bad));

    // 4. One command per packet, covering that packet.
    check(cmd_log.size() >= packets,
          $sformatf("DataMover accepted %0d commands (expect at least %0d, one per packet)", cmd_log.size(), packets));
    foreach (cmd_log[i]) if (i < packets)
      check(!$isunknown(cmd_log[i].cmd) && s2mm_cmd_t'(cmd_log[i].cmd) == exp_cmd,
            $sformatf("command %0d: %s (expect %s)", i, cmd_str(cmd_log[i].cmd), cmd_str(exp_cmd)));

    // 5. One OKAY status per command, carrying its tag.
    check(sts.received.size() >= packets,
          $sformatf("DataMover returned %0d status words (expect at least %0d)", sts.received.size(), packets));
    foreach (sts.received[i]) if (i < packets) begin
      status = sts.received[i];
      check(status.okay && !status.slverr && !status.decerr && !status.interr && status.tag == exp_cmd.tag,
            $sformatf("status %0d: 0x%02h, OKAY %0d SLVERR %0d DECERR %0d INTERR %0d TAG %0h (expect OKAY only, TAG %0h)",
                      i, status, status.okay, status.slverr, status.decerr, status.interr, status.tag, exp_cmd.tag));
    end

    // 6. DDR: each packet lands at SADDR, beat n at SADDR + 4n holding n.
    check(ddr.w_log.size() >= packets * pkt_beats,
          $sformatf("DDR received %0d beats in %0d bursts (expect at least %0d for %0d packets)",
                    ddr.w_log.size(), ddr.burst_log.size(), packets * pkt_beats, packets));
    bad = 0;
    foreach (ddr.w_log[i]) if (i < packets * pkt_beats) begin
      w = ddr.w_log[i];
      n = i % pkt_beats;
      if (w.addr != DMA_LO + 4 * n || w.data != n || w.strb != 4'hF)
        if (bad++ == 0)
          first_bad = $sformatf("DDR beat %0d (packet %0d beat %0d): 0x%08h = 0x%08h, WSTRB %b (expect 0x%08h = 0x%08h)",
                                i, i / pkt_beats, n, w.addr, w.data, w.strb, DMA_LO + 4 * n, n);
    end
    if (ddr.w_log.size() > 0)
      check(bad == 0, bad == 0 ? $sformatf("DDR: every packet written to 0x%08h-0x%08h, in order, all bytes",
                                           DMA_LO, DMA_LO + pkt_bytes - 1)
                               : $sformatf("DDR: %0d beats wrong, first %s", bad, first_bad));
    bad = 0;
    n = 0;
    foreach (ddr.burst_log[i]) begin
      if (n >= packets * pkt_beats) break;
      n += ddr.burst_log[i].len;
      if (ddr.burst_log[i].cache != dut.XCACHE_CACHEABLE && bad++ == 0)
        first_bad = $sformatf("burst %0d at 0x%08h has 0x%h", i, ddr.burst_log[i].addr, ddr.burst_log[i].cache);
    end
    if (ddr.burst_log.size() > 0)
      check(bad == 0, bad == 0 ? $sformatf("DDR: every burst has AWCACHE 0x%h", dut.XCACHE_CACHEABLE)
                               : $sformatf("DDR: %0d bursts without AWCACHE 0x%h, first %s", bad, dut.XCACHE_CACHEABLE, first_bad));

    // 7. One interrupt per packet, after its TLAST and before the next one's.
    for (k = 0; k < packets; k++) begin
      if (k >= pkt_last.size() || k >= irq_log.size()) begin
        check(0, $sformatf("packet %0d: interrupt (%0d packets, %0d interrupts)", k, pkt_last.size(), irq_log.size()));
        break;
      end
      check(irq_log[k] > pkt_last[k] && (k + 1 >= pkt_last.size() || irq_log[k] < pkt_last[k + 1]),
            $sformatf("packet %0d: interrupt %0d cycles after its TLAST, before the next packet's", k,
                      cycles(pkt_last[k], irq_log[k])));
    end

    // 8. The descriptor: top writes {PKT_LENGTH, 1} to DMA BRAM word 0 per
    // packet, and the A53 reads it there.
    check(dma_wr_log.size() >= packets,
          $sformatf("PL wrote the DMA BRAM %0d times (expect at least %0d, one per packet)", dma_wr_log.size(), packets));
    foreach (dma_wr_log[i]) if (i < packets)
      check(dma_wr_log[i].addr === 32'h0 && dma_wr_log[i].we === 4'hF && dma_wr_log[i].data === exp_desc,
            $sformatf("PL descriptor write %0d: 0x%08h = 0x%08h, WE %b, %0d cycles after its interrupt (expect 0x0 = 0x%08h, WE 1111)",
                      i, dma_wr_log[i].addr, dma_wr_log[i].data, dma_wr_log[i].we,
                      i < irq_log.size() ? cycles(irq_log[i], dma_wr_log[i].t) : -1, exp_desc));
    check(desc_log.size() >= packets,
          $sformatf("A53 handled %0d interrupts (expect at least %0d)", desc_log.size(), packets));
    foreach (desc_log[i]) if (i < packets)
      check(desc_log[i] === exp_desc,
            $sformatf("A53 reads descriptor %0d = 0x%08h, %0d cycles after the interrupt (expect 0x%08h: length %0d, valid)",
                      i, desc_log[i], latency, exp_desc, pkt_beats));

    // 9. Timeline, cycles from the first stream beat. The last column is
    // what software must allow between the interrupt and reading DDR.
    t0 = beat_log.size() > 0 ? beat_log[0].t : $realtime;
    lag_max = 0;
    $display("[%0t] INFO  per packet, pl_clk0 cycles from the first beat:", $time);
    for (k = 0; k < packets && k < pkt_last.size(); k++) begin
      string cmd_at = k < cmd_log.size() ? $sformatf("%0d", cycles(t0, cmd_log[k].t)) : "-";
      string irq_at = k < irq_log.size() ? $sformatf("%0d", cycles(t0, irq_log[k])) : "-";
      string ddr_at = "-", lag = "-";
      if ((k + 1) * pkt_beats <= ddr.w_log.size()) begin
        t_ddr  = ddr.w_log[(k + 1) * pkt_beats - 1].t;
        ddr_at = $sformatf("%0d", cycles(t0, t_ddr));
        if (k < irq_log.size()) begin
          lag = $sformatf("%0d", cycles(irq_log[k], t_ddr));
          if (t_ddr - irq_log[k] > lag_max) lag_max = t_ddr - irq_log[k];
        end
      end
      $display("          packet %0d: beats %0d-%0d, command %s, irq %s, last DDR beat %s, irq to DDR %s",
               k, cycles(t0, pkt_start[k]), cycles(t0, pkt_last[k]), cmd_at, irq_at, ddr_at, lag);
    end
    if (lag_max > 0)
      $display("[%0t] INFO  last DDR beat lands up to %0d cycles after the interrupt", $time, cycles(0, lag_max));

    check(a53.errors == 0, $sformatf("A53 accesses all completed with OKAY (%0d errors)", a53.errors));
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
