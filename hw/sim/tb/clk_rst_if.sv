// Board clock and resets into the simulation BD, driven by the testbench:
// the 100 MHz reference into clk_wiz, its active-high reset, and the
// active-low external reset of proc_sys_reset.
`timescale 1ns/1ps

interface clk_rst_if;
  logic clk_100MHz  = 1'b0;
  logic reset_rtl   = 1'b1;
  logic n_reset_rtl = 1'b0;
endinterface
