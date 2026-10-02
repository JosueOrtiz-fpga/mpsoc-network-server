// Connects the simulation BD's exposed signals in top (SIM=1) to testbench
// interfaces. tb_top binds it into top:
//
//   bind top sim_bd_harness u_sim_bd_harness (.*);
//
// so every port name here matches a signal name in top. The testbench
// reaches the interfaces as tb_top.dut.u_sim_bd_harness.<name>_if.
//
//   crst_if   clocks and resets into the BD           driven by the TB
//   bram0_if  S_AXI_BRAM_0, the A53 into the CTL BRAM  TB is the master
//   bram1_if  S_AXI_BRAM_1, the A53 into the DMA BRAM  TB is the master
//   ddr_if    M_AXI_S2MM_0, DataMover into HPC0/DDR    TB is the slave
//   sts_if    M_AXIS_S2MM_STS_0, DataMover status      TB is the sink
//   data_if   S_AXIS_S2MM_0, top's packet stream       monitor only
//   cmd_if    S_AXIS_S2MM_CMD_0, top's DMA commands    monitor only
`timescale 1ns/1ps
`default_nettype none

`define SIM_BD_HARNESS_BRAM_PORTS(P) \
  output wire [11:0] P``_awaddr, \
  output wire [7:0]  P``_awlen, \
  output wire [2:0]  P``_awsize, \
  output wire [1:0]  P``_awburst, \
  output wire        P``_awlock, \
  output wire [3:0]  P``_awcache, \
  output wire [2:0]  P``_awprot, \
  output wire        P``_awvalid, \
  input  wire        P``_awready, \
  output wire [31:0] P``_wdata, \
  output wire [3:0]  P``_wstrb, \
  output wire        P``_wlast, \
  output wire        P``_wvalid, \
  input  wire        P``_wready, \
  input  wire [1:0]  P``_bresp, \
  input  wire        P``_bvalid, \
  output wire        P``_bready, \
  output wire [11:0] P``_araddr, \
  output wire [7:0]  P``_arlen, \
  output wire [2:0]  P``_arsize, \
  output wire [1:0]  P``_arburst, \
  output wire        P``_arlock, \
  output wire [3:0]  P``_arcache, \
  output wire [2:0]  P``_arprot, \
  output wire        P``_arvalid, \
  input  wire        P``_arready, \
  input  wire [31:0] P``_rdata, \
  input  wire [1:0]  P``_rresp, \
  input  wire        P``_rlast, \
  input  wire        P``_rvalid, \
  output wire        P``_rready

// TB is the AXI master: requests from the interface to the BD, responses back.
`define SIM_BD_HARNESS_BRAM_CONNECT(P, IF) \
  assign P``_awaddr  = IF.awaddr; \
  assign P``_awlen   = IF.awlen; \
  assign P``_awsize  = IF.awsize; \
  assign P``_awburst = IF.awburst; \
  assign P``_awlock  = IF.awlock; \
  assign P``_awcache = IF.awcache; \
  assign P``_awprot  = IF.awprot; \
  assign P``_awvalid = IF.awvalid; \
  assign IF.awready  = P``_awready; \
  assign P``_wdata   = IF.wdata; \
  assign P``_wstrb   = IF.wstrb; \
  assign P``_wlast   = IF.wlast; \
  assign P``_wvalid  = IF.wvalid; \
  assign IF.wready   = P``_wready; \
  assign IF.bid      = '0; \
  assign IF.bresp    = P``_bresp; \
  assign IF.bvalid   = P``_bvalid; \
  assign P``_bready  = IF.bready; \
  assign P``_araddr  = IF.araddr; \
  assign P``_arlen   = IF.arlen; \
  assign P``_arsize  = IF.arsize; \
  assign P``_arburst = IF.arburst; \
  assign P``_arlock  = IF.arlock; \
  assign P``_arcache = IF.arcache; \
  assign P``_arprot  = IF.arprot; \
  assign P``_arvalid = IF.arvalid; \
  assign IF.arready  = P``_arready; \
  assign IF.rid      = '0; \
  assign IF.rdata    = P``_rdata; \
  assign IF.rresp    = P``_rresp; \
  assign IF.rlast    = P``_rlast; \
  assign IF.rvalid   = P``_rvalid; \
  assign P``_rready  = IF.rready;

module sim_bd_harness (
  // From the BD
  input  wire        pl_clk0,
  input  wire [0:0]  aresetn,
  input  wire [0:0]  bus_struct_reset_0,
  // Board clock and resets into the BD
  output wire        clk_100MHz,
  output wire        reset_rtl,
  output wire        n_reset_rtl,
  // A53 into the two BRAM controllers
  `SIM_BD_HARNESS_BRAM_PORTS(S_AXI_BRAM_0),
  `SIM_BD_HARNESS_BRAM_PORTS(S_AXI_BRAM_1),
  // DataMover write master (HPC0 in the real design)
  input  wire [3:0]  M_AXI_S2MM_0_awid,
  input  wire [31:0] M_AXI_S2MM_0_awaddr,
  input  wire [7:0]  M_AXI_S2MM_0_awlen,
  input  wire [2:0]  M_AXI_S2MM_0_awsize,
  input  wire [1:0]  M_AXI_S2MM_0_awburst,
  input  wire [3:0]  M_AXI_S2MM_0_awcache,
  input  wire [2:0]  M_AXI_S2MM_0_awprot,
  input  wire [3:0]  M_AXI_S2MM_0_awuser,
  input  wire        M_AXI_S2MM_0_awvalid,
  output wire        M_AXI_S2MM_0_awready,
  input  wire [31:0] M_AXI_S2MM_0_wdata,
  input  wire [3:0]  M_AXI_S2MM_0_wstrb,
  input  wire        M_AXI_S2MM_0_wlast,
  input  wire        M_AXI_S2MM_0_wvalid,
  output wire        M_AXI_S2MM_0_wready,
  output wire [1:0]  M_AXI_S2MM_0_bresp,
  output wire        M_AXI_S2MM_0_bvalid,
  input  wire        M_AXI_S2MM_0_bready,
  // DataMover status
  input  wire [7:0]  M_AXIS_S2MM_STS_0_tdata,
  input  wire [0:0]  M_AXIS_S2MM_STS_0_tkeep,
  input  wire        M_AXIS_S2MM_STS_0_tlast,
  input  wire        M_AXIS_S2MM_STS_0_tvalid,
  output wire        M_AXIS_S2MM_STS_0_tready,
  // top's own outputs into the BD, observed only
  input  wire [31:0] S_AXIS_S2MM_0_tdata,
  input  wire [3:0]  S_AXIS_S2MM_0_tkeep,
  input  wire        S_AXIS_S2MM_0_tlast,
  input  wire        S_AXIS_S2MM_0_tvalid,
  input  wire        S_AXIS_S2MM_0_tready,
  input  wire [111:0] S_AXIS_S2MM_CMD_0_tdata,
  input  wire        S_AXIS_S2MM_CMD_0_tvalid,
  input  wire        S_AXIS_S2MM_CMD_0_tready,
  input  wire        pl_ps_irq1_0
);

  clk_rst_if crst_if ();
  assign clk_100MHz  = crst_if.clk_100MHz;
  assign reset_rtl   = crst_if.reset_rtl;
  assign n_reset_rtl = crst_if.n_reset_rtl;

  axi4_if #(.ADDR_W(12), .DATA_W(32), .ID_W(1), .USER_W(1)) bram0_if (.aclk(pl_clk0), .aresetn(aresetn[0]));
  axi4_if #(.ADDR_W(12), .DATA_W(32), .ID_W(1), .USER_W(1)) bram1_if (.aclk(pl_clk0), .aresetn(aresetn[0]));
  `SIM_BD_HARNESS_BRAM_CONNECT(S_AXI_BRAM_0, bram0_if)
  `SIM_BD_HARNESS_BRAM_CONNECT(S_AXI_BRAM_1, bram1_if)

  // TB is the AXI slave on the write channels; the DataMover has no read channel.
  axi4_if #(.ADDR_W(32), .DATA_W(32), .ID_W(4), .USER_W(4)) ddr_if (.aclk(pl_clk0), .aresetn(aresetn[0]));
  assign ddr_if.awid    = M_AXI_S2MM_0_awid;
  assign ddr_if.awaddr  = M_AXI_S2MM_0_awaddr;
  assign ddr_if.awlen   = M_AXI_S2MM_0_awlen;
  assign ddr_if.awsize  = M_AXI_S2MM_0_awsize;
  assign ddr_if.awburst = M_AXI_S2MM_0_awburst;
  assign ddr_if.awlock  = 1'b0;
  assign ddr_if.awcache = M_AXI_S2MM_0_awcache;
  assign ddr_if.awprot  = M_AXI_S2MM_0_awprot;
  assign ddr_if.awuser  = M_AXI_S2MM_0_awuser;
  assign ddr_if.awvalid = M_AXI_S2MM_0_awvalid;
  assign M_AXI_S2MM_0_awready = ddr_if.awready;
  assign ddr_if.wdata   = M_AXI_S2MM_0_wdata;
  assign ddr_if.wstrb   = M_AXI_S2MM_0_wstrb;
  assign ddr_if.wlast   = M_AXI_S2MM_0_wlast;
  assign ddr_if.wvalid  = M_AXI_S2MM_0_wvalid;
  assign M_AXI_S2MM_0_wready  = ddr_if.wready;
  assign M_AXI_S2MM_0_bresp   = ddr_if.bresp;
  assign M_AXI_S2MM_0_bvalid  = ddr_if.bvalid;
  assign ddr_if.bready  = M_AXI_S2MM_0_bready;
  assign ddr_if.arid    = '0;
  assign ddr_if.araddr  = '0;
  assign ddr_if.arlen   = '0;
  assign ddr_if.arsize  = '0;
  assign ddr_if.arburst = '0;
  assign ddr_if.arlock  = 1'b0;
  assign ddr_if.arcache = '0;
  assign ddr_if.arprot  = '0;
  assign ddr_if.arvalid = 1'b0;
  assign ddr_if.rready  = 1'b0;

  axis_if #(.DATA_W(8)) sts_if (.aclk(pl_clk0), .aresetn(aresetn[0]));
  assign sts_if.tdata  = M_AXIS_S2MM_STS_0_tdata;
  assign sts_if.tkeep  = M_AXIS_S2MM_STS_0_tkeep;
  assign sts_if.tlast  = M_AXIS_S2MM_STS_0_tlast;
  assign sts_if.tvalid = M_AXIS_S2MM_STS_0_tvalid;
  assign M_AXIS_S2MM_STS_0_tready = sts_if.tready;

  axis_if #(.DATA_W(32)) data_if (.aclk(pl_clk0), .aresetn(aresetn[0]));
  assign data_if.tdata  = S_AXIS_S2MM_0_tdata;
  assign data_if.tkeep  = S_AXIS_S2MM_0_tkeep;
  assign data_if.tlast  = S_AXIS_S2MM_0_tlast;
  assign data_if.tvalid = S_AXIS_S2MM_0_tvalid;
  assign data_if.tready = S_AXIS_S2MM_0_tready;

  // The DataMover's command port is 80 bits; top drives 112.
  axis_if #(.DATA_W(112), .KEEP_W(1)) cmd_if (.aclk(pl_clk0), .aresetn(aresetn[0]));
  assign cmd_if.tdata  = S_AXIS_S2MM_CMD_0_tdata;
  assign cmd_if.tkeep  = 1'b1;
  assign cmd_if.tlast  = 1'b1;
  assign cmd_if.tvalid = S_AXIS_S2MM_CMD_0_tvalid;
  assign cmd_if.tready = S_AXIS_S2MM_CMD_0_tready;

  wire irq = pl_ps_irq1_0;
endmodule

`undef SIM_BD_HARNESS_BRAM_PORTS
`undef SIM_BD_HARNESS_BRAM_CONNECT
`default_nettype wire
