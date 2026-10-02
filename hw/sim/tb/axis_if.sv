// AXI4-Stream interface for the testbench: master, slave and monitor
// clocking blocks, plus the handshake rules of AXI4-Stream (AMBA IHI0051,
// 2.2.1): once TVALID is high it stays high, with a stable payload, until
// TREADY.
`timescale 1ns/1ps

interface axis_if #(
    parameter int DATA_W = 32,
    parameter int KEEP_W = (DATA_W + 7) / 8
) (
    input logic aclk,
    input logic aresetn
);
  logic [DATA_W-1:0] tdata;
  logic [KEEP_W-1:0] tkeep;
  logic              tlast;
  logic              tvalid;
  logic              tready;

  clocking mst_cb @(posedge aclk);
    default input #1step output #1ps;
    output tdata, tkeep, tlast, tvalid;
    input  tready;
  endclocking

  clocking slv_cb @(posedge aclk);
    default input #1step output #1ps;
    input  tdata, tkeep, tlast, tvalid;
    output tready;
  endclocking

  clocking mon_cb @(posedge aclk);
    default input #1step;
    input tdata, tkeep, tlast, tvalid, tready;
  endclocking

  // Protocol checks as clocked processes rather than concurrent assertions:
  // xsim prints a line for every failing assertion, so an output stuck at X
  // would flood the log. Each failure is counted; the first three print.
  int unsigned violations = 0;
  logic              stalled;
  logic [DATA_W-1:0] held_tdata;
  logic [KEEP_W-1:0] held_tkeep;
  logic              held_tlast;

  function automatic void violation(string what);
    violations++;
    if (violations <= 3) $error("%m: %s", what);
    if (violations == 3) $display("%m: further violations are counted, not printed");
  endfunction

  always @(posedge aclk) begin
    if (aresetn !== 1'b1) begin
      stalled <= 1'b0;
    end else begin
      if ($isunknown(tvalid))
        violation("t_known: TVALID is X or Z after reset");
      else if (stalled && (tvalid !== 1'b1 || tdata !== held_tdata ||
                           tkeep !== held_tkeep || tlast !== held_tlast))
        violation("t_hold: TVALID dropped or payload changed while waiting for TREADY");
      stalled    <= (tvalid === 1'b1 && tready !== 1'b1);
      held_tdata <= tdata;
      held_tkeep <= tkeep;
      held_tlast <= tlast;
    end
  end
endinterface
