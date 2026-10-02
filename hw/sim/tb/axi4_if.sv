// AXI4 (full) interface for the testbench: master, slave and monitor
// clocking blocks, plus the handshake rules every channel must keep.
`timescale 1ns/1ps

interface axi4_if #(
    parameter int ADDR_W = 32,
    parameter int DATA_W = 32,
    parameter int ID_W   = 1,
    parameter int USER_W = 1
) (
    input logic aclk,
    input logic aresetn
);
  localparam int STRB_W = DATA_W / 8;

  logic [ID_W-1:0]   awid;
  logic [ADDR_W-1:0] awaddr;
  logic [7:0]        awlen;
  logic [2:0]        awsize;
  logic [1:0]        awburst;
  logic              awlock;
  logic [3:0]        awcache;
  logic [2:0]        awprot;
  logic [USER_W-1:0] awuser;
  logic              awvalid;
  logic              awready;

  logic [DATA_W-1:0] wdata;
  logic [STRB_W-1:0] wstrb;
  logic              wlast;
  logic              wvalid;
  logic              wready;

  logic [ID_W-1:0]   bid;
  logic [1:0]        bresp;
  logic              bvalid;
  logic              bready;

  logic [ID_W-1:0]   arid;
  logic [ADDR_W-1:0] araddr;
  logic [7:0]        arlen;
  logic [2:0]        arsize;
  logic [1:0]        arburst;
  logic              arlock;
  logic [3:0]        arcache;
  logic [2:0]        arprot;
  logic              arvalid;
  logic              arready;

  logic [ID_W-1:0]   rid;
  logic [DATA_W-1:0] rdata;
  logic [1:0]        rresp;
  logic              rlast;
  logic              rvalid;
  logic              rready;

  clocking mst_cb @(posedge aclk);
    default input #1step output #1ps;
    output awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awuser, awvalid;
    input  awready;
    output wdata, wstrb, wlast, wvalid;
    input  wready;
    input  bid, bresp, bvalid;
    output bready;
    output arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot, arvalid;
    input  arready;
    input  rid, rdata, rresp, rlast, rvalid;
    output rready;
  endclocking

  clocking slv_cb @(posedge aclk);
    default input #1step output #1ps;
    input  awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awuser, awvalid;
    output awready;
    input  wdata, wstrb, wlast, wvalid;
    output wready;
    output bid, bresp, bvalid;
    input  bready;
    input  arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot, arvalid;
    output arready;
    output rid, rdata, rresp, rlast, rvalid;
    input  rready;
  endclocking

  clocking mon_cb @(posedge aclk);
    default input #1step;
    input awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awuser, awvalid, awready;
    input wdata, wstrb, wlast, wvalid, wready;
    input bid, bresp, bvalid, bready;
    input arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot, arvalid, arready;
    input rid, rdata, rresp, rlast, rvalid, rready;
  endclocking

  // --- Protocol checks (AMBA AXI4, A3.2.1 and A3.2.2) -------------------
  // Once VALID is high it stays high, with a stable payload, until READY;
  // VALID is never X or Z after reset. Written as clocked processes rather
  // than concurrent assertions: xsim prints a line for every failing
  // assertion, so a signal stuck at X would flood the log. Each failure is
  // counted; the first three print, and the testbench reports the count.
  int unsigned violations = 0;

  function automatic void violation(string what);
    violations++;
    if (violations <= 3) $error("%m: %s", what);
    if (violations == 3) $display("%m: further violations are counted, not printed");
  endfunction

  `define AXI4_IF_CHECK(CH, V, R, P) \
    logic CH``_stalled; \
    logic [$bits(P)-1:0] CH``_held; \
    always @(posedge aclk) begin \
      if (aresetn !== 1'b1) begin \
        CH``_stalled <= 1'b0; \
      end else begin \
        if ($isunknown(V)) \
          violation({`"CH`", "_known: VALID is X or Z after reset"}); \
        else if (CH``_stalled && (V !== 1'b1 || P !== CH``_held)) \
          violation({`"CH`", "_hold: VALID dropped or payload changed while waiting for READY"}); \
        CH``_stalled <= (V === 1'b1 && R !== 1'b1); \
        CH``_held    <= P; \
      end \
    end

  `AXI4_IF_CHECK(aw, awvalid, awready,
                 {awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awuser})
  `AXI4_IF_CHECK(w,  wvalid,  wready,  {wdata, wstrb, wlast})
  `AXI4_IF_CHECK(b,  bvalid,  bready,  {bid, bresp})
  `AXI4_IF_CHECK(ar, arvalid, arready,
                 {arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot})
  `AXI4_IF_CHECK(r,  rvalid,  rready,  {rid, rdata, rresp, rlast})

  `undef AXI4_IF_CHECK
endinterface
