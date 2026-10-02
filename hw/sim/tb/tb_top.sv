// Bring-up testbench for top with the simulation BD (SIM=1).
//
// Proves that the flow elaborates top with sim_mpsco_bd, that the BD's
// clock and reset come up, and that the A53 model reaches both BRAMs
// through the BD's AXI BRAM controllers. It does not exercise top's own
// logic yet; the DDR and status models only report what they saw.
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

  bind top.sim_mpsoc_bd sim_bd_harness u_sim_bd_harness (.*);

  // Elaboration fails here unless SIM=1 instantiated the simulation BD:
  // this path exists only in that generate branch.
  wire bd_pl_clk0 = dut.sim_mpsoc_bd.sim_mpsco_bd_i.pl_clk0;

  localparam realtime REF_PERIOD   = 10.0ns;  // clk_100MHz into clk_wiz
  localparam realtime PL_CLK0_NOM  = 10.0ns;  // clk_wiz CLKOUT1, 100 MHz
  localparam int      SETTLE_EDGES = 64;      // pl_clk0 edges before releasing n_reset_rtl

  crst_vif_t crst;
  a53_model  a53;
  ddr_model  ddr;
  axis_sink #(sts_vif_t, 8) sts;

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

  initial begin : clock_ref
    crst = dut.u_sim_bd_harness.crst_if;
    forever #(REF_PERIOD / 2) crst.clk_100MHz = ~crst.clk_100MHz;
  end

  initial begin : watchdog
    #200us;
    $fatal(1, "watchdog: test did not finish within 200 us");
  end

  initial begin : test
    realtime   period;
    bit [31:0] word;

    crst = dut.u_sim_bd_harness.crst_if;
    a53  = new(dut.u_sim_bd_harness.bram0_if, dut.u_sim_bd_harness.bram1_if);
    ddr  = new(dut.u_sim_bd_harness.ddr_if);
    sts  = new("sts", dut.u_sim_bd_harness.sts_if);
    a53.idle();
    ddr.idle();
    sts.idle();

    $display("[%0t] tb_top: top elaborated with SIM=1 (%m)", $time);

    // --- Clock and reset -------------------------------------------------
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

    ddr.run();
    sts.run();
    repeat (8) @(posedge bd_pl_clk0);

    // --- A53 into both BRAMs ----------------------------------------------
    // top's settings FSM rewrites CTL word 0 continuously (see the review),
    // so the round trips use words it does not touch.
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
    $display("[%0t] INFO  CTL BRAM word 0 = 0x%08h (written by top's settings FSM)", $time, word);
    $display("[%0t] INFO  DDR model: %0d bursts, %0d beats; status sink: %0d words; irq %s",
             $time, ddr.bursts, ddr.beats, sts.received.size(),
             dut.u_sim_bd_harness.irq === 1'b1 ? string'("high") : string'("low"));

    finish();
  end

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
    $display("==== tb_top summary ====");
    $display("bring-up checks:  %0d run, %0d failed", checks, failures);
    $display("protocol checks, testbench and BD side: %0d violations", tb_side);
    $display("protocol checks, top's outputs:  data %0d, cmd %0d",
             dut.u_sim_bd_harness.data_if.violations, dut.u_sim_bd_harness.cmd_if.violations);
    if (failures == 0 && tb_side == 0 && dut_side == 0) $display("TEST PASSED");
    else if (failures == 0 && tb_side == 0) $display("TEST FAILED: bring-up passed, top violates AXI4-Stream (see the first errors above)");
    else $display("TEST FAILED");
    $finish;
  endtask
endmodule
