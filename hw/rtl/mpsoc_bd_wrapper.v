//Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
//Copyright 2022-2026 Advanced Micro Devices, Inc. All Rights Reserved.
//--------------------------------------------------------------------------------
//Tool Version: Vivado v.2026.1 (lin64) Build 6511674 Tue Jun 16 11:01:26 MDT 2026
//Date        : Thu Oct  1 18:45:25 2026
//Host        : LNXPC running 64-bit Ubuntu 22.04.5 LTS
//Command     : generate_target mpsoc_bd_wrapper.bd
//Design      : mpsoc_bd_wrapper
//Purpose     : IP block netlist
//--------------------------------------------------------------------------------
`timescale 1 ps / 1 ps

module mpsoc_bd_wrapper
   (BRAM_PORTB_0_addr,
    BRAM_PORTB_0_clk,
    BRAM_PORTB_0_din,
    BRAM_PORTB_0_dout,
    BRAM_PORTB_0_en,
    BRAM_PORTB_0_rst,
    BRAM_PORTB_0_we,
    BRAM_PORTB_1_addr,
    BRAM_PORTB_1_clk,
    BRAM_PORTB_1_din,
    BRAM_PORTB_1_dout,
    BRAM_PORTB_1_en,
    BRAM_PORTB_1_rst,
    BRAM_PORTB_1_we,
    M_AXIS_S2MM_STS_0_tdata,
    M_AXIS_S2MM_STS_0_tkeep,
    M_AXIS_S2MM_STS_0_tlast,
    M_AXIS_S2MM_STS_0_tready,
    M_AXIS_S2MM_STS_0_tvalid,
    S_AXIS_S2MM_0_tdata,
    S_AXIS_S2MM_0_tkeep,
    S_AXIS_S2MM_0_tlast,
    S_AXIS_S2MM_0_tready,
    S_AXIS_S2MM_0_tvalid,
    S_AXIS_S2MM_CMD_0_tdata,
    S_AXIS_S2MM_CMD_0_tready,
    S_AXIS_S2MM_CMD_0_tvalid,
    aresetn,
    bus_struct_reset_0,
    pl_clk0,
    pl_ps_irq1_0,
    saxigp0_arprot_0,
    saxigp0_awprot_0,
    tempsensor_i2c_pl_scl_io,
    tempsensor_i2c_pl_sda_io);
  input [31:0]BRAM_PORTB_0_addr;
  input BRAM_PORTB_0_clk;
  input [31:0]BRAM_PORTB_0_din;
  output [31:0]BRAM_PORTB_0_dout;
  input BRAM_PORTB_0_en;
  input BRAM_PORTB_0_rst;
  input [3:0]BRAM_PORTB_0_we;
  input [31:0]BRAM_PORTB_1_addr;
  input BRAM_PORTB_1_clk;
  input [31:0]BRAM_PORTB_1_din;
  output [31:0]BRAM_PORTB_1_dout;
  input BRAM_PORTB_1_en;
  input BRAM_PORTB_1_rst;
  input [3:0]BRAM_PORTB_1_we;
  output [7:0]M_AXIS_S2MM_STS_0_tdata;
  output [0:0]M_AXIS_S2MM_STS_0_tkeep;
  output M_AXIS_S2MM_STS_0_tlast;
  input M_AXIS_S2MM_STS_0_tready;
  output M_AXIS_S2MM_STS_0_tvalid;
  input [31:0]S_AXIS_S2MM_0_tdata;
  input [3:0]S_AXIS_S2MM_0_tkeep;
  input S_AXIS_S2MM_0_tlast;
  output S_AXIS_S2MM_0_tready;
  input S_AXIS_S2MM_0_tvalid;
  input [79:0]S_AXIS_S2MM_CMD_0_tdata;
  output S_AXIS_S2MM_CMD_0_tready;
  input S_AXIS_S2MM_CMD_0_tvalid;
  output [0:0]aresetn;
  output [0:0]bus_struct_reset_0;
  output pl_clk0;
  input [0:0]pl_ps_irq1_0;
  input [2:0]saxigp0_arprot_0;
  input [2:0]saxigp0_awprot_0;
  inout tempsensor_i2c_pl_scl_io;
  inout tempsensor_i2c_pl_sda_io;

  wire [31:0]BRAM_PORTB_0_addr;
  wire BRAM_PORTB_0_clk;
  wire [31:0]BRAM_PORTB_0_din;
  wire [31:0]BRAM_PORTB_0_dout;
  wire BRAM_PORTB_0_en;
  wire BRAM_PORTB_0_rst;
  wire [3:0]BRAM_PORTB_0_we;
  wire [31:0]BRAM_PORTB_1_addr;
  wire BRAM_PORTB_1_clk;
  wire [31:0]BRAM_PORTB_1_din;
  wire [31:0]BRAM_PORTB_1_dout;
  wire BRAM_PORTB_1_en;
  wire BRAM_PORTB_1_rst;
  wire [3:0]BRAM_PORTB_1_we;
  wire [7:0]M_AXIS_S2MM_STS_0_tdata;
  wire [0:0]M_AXIS_S2MM_STS_0_tkeep;
  wire M_AXIS_S2MM_STS_0_tlast;
  wire M_AXIS_S2MM_STS_0_tready;
  wire M_AXIS_S2MM_STS_0_tvalid;
  wire [31:0]S_AXIS_S2MM_0_tdata;
  wire [3:0]S_AXIS_S2MM_0_tkeep;
  wire S_AXIS_S2MM_0_tlast;
  wire S_AXIS_S2MM_0_tready;
  wire S_AXIS_S2MM_0_tvalid;
  wire [79:0]S_AXIS_S2MM_CMD_0_tdata;
  wire S_AXIS_S2MM_CMD_0_tready;
  wire S_AXIS_S2MM_CMD_0_tvalid;
  wire [0:0]aresetn;
  wire [0:0]bus_struct_reset_0;
  wire pl_clk0;
  wire [0:0]pl_ps_irq1_0;
  wire [2:0]saxigp0_arprot_0;
  wire [2:0]saxigp0_awprot_0;
  wire tempsensor_i2c_pl_scl_i;
  wire tempsensor_i2c_pl_scl_io;
  wire tempsensor_i2c_pl_scl_o;
  wire tempsensor_i2c_pl_scl_t;
  wire tempsensor_i2c_pl_sda_i;
  wire tempsensor_i2c_pl_sda_io;
  wire tempsensor_i2c_pl_sda_o;
  wire tempsensor_i2c_pl_sda_t;

  mpsoc_bd mpsoc_bd_i
       (.BRAM_PORTB_0_addr(BRAM_PORTB_0_addr),
        .BRAM_PORTB_0_clk(BRAM_PORTB_0_clk),
        .BRAM_PORTB_0_din(BRAM_PORTB_0_din),
        .BRAM_PORTB_0_dout(BRAM_PORTB_0_dout),
        .BRAM_PORTB_0_en(BRAM_PORTB_0_en),
        .BRAM_PORTB_0_rst(BRAM_PORTB_0_rst),
        .BRAM_PORTB_0_we(BRAM_PORTB_0_we),
        .BRAM_PORTB_1_addr(BRAM_PORTB_1_addr),
        .BRAM_PORTB_1_clk(BRAM_PORTB_1_clk),
        .BRAM_PORTB_1_din(BRAM_PORTB_1_din),
        .BRAM_PORTB_1_dout(BRAM_PORTB_1_dout),
        .BRAM_PORTB_1_en(BRAM_PORTB_1_en),
        .BRAM_PORTB_1_rst(BRAM_PORTB_1_rst),
        .BRAM_PORTB_1_we(BRAM_PORTB_1_we),
        .M_AXIS_S2MM_STS_0_tdata(M_AXIS_S2MM_STS_0_tdata),
        .M_AXIS_S2MM_STS_0_tkeep(M_AXIS_S2MM_STS_0_tkeep),
        .M_AXIS_S2MM_STS_0_tlast(M_AXIS_S2MM_STS_0_tlast),
        .M_AXIS_S2MM_STS_0_tready(M_AXIS_S2MM_STS_0_tready),
        .M_AXIS_S2MM_STS_0_tvalid(M_AXIS_S2MM_STS_0_tvalid),
        .S_AXIS_S2MM_0_tdata(S_AXIS_S2MM_0_tdata),
        .S_AXIS_S2MM_0_tkeep(S_AXIS_S2MM_0_tkeep),
        .S_AXIS_S2MM_0_tlast(S_AXIS_S2MM_0_tlast),
        .S_AXIS_S2MM_0_tready(S_AXIS_S2MM_0_tready),
        .S_AXIS_S2MM_0_tvalid(S_AXIS_S2MM_0_tvalid),
        .S_AXIS_S2MM_CMD_0_tdata(S_AXIS_S2MM_CMD_0_tdata),
        .S_AXIS_S2MM_CMD_0_tready(S_AXIS_S2MM_CMD_0_tready),
        .S_AXIS_S2MM_CMD_0_tvalid(S_AXIS_S2MM_CMD_0_tvalid),
        .aresetn(aresetn),
        .bus_struct_reset_0(bus_struct_reset_0),
        .pl_clk0(pl_clk0),
        .pl_ps_irq1_0(pl_ps_irq1_0),
        .saxigp0_arprot_0(saxigp0_arprot_0),
        .saxigp0_awprot_0(saxigp0_awprot_0),
        .tempsensor_i2c_pl_scl_i(tempsensor_i2c_pl_scl_i),
        .tempsensor_i2c_pl_scl_o(tempsensor_i2c_pl_scl_o),
        .tempsensor_i2c_pl_scl_t(tempsensor_i2c_pl_scl_t),
        .tempsensor_i2c_pl_sda_i(tempsensor_i2c_pl_sda_i),
        .tempsensor_i2c_pl_sda_o(tempsensor_i2c_pl_sda_o),
        .tempsensor_i2c_pl_sda_t(tempsensor_i2c_pl_sda_t));
  IOBUF tempsensor_i2c_pl_scl_iobuf
       (.I(tempsensor_i2c_pl_scl_o),
        .IO(tempsensor_i2c_pl_scl_io),
        .O(tempsensor_i2c_pl_scl_i),
        .T(tempsensor_i2c_pl_scl_t));
  IOBUF tempsensor_i2c_pl_sda_iobuf
       (.I(tempsensor_i2c_pl_sda_o),
        .IO(tempsensor_i2c_pl_sda_io),
        .O(tempsensor_i2c_pl_sda_i),
        .T(tempsensor_i2c_pl_sda_t));
endmodule
