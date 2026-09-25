//Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
//Copyright 2022-2026 Advanced Micro Devices, Inc. All Rights Reserved.
//--------------------------------------------------------------------------------
//Tool Version: Vivado v.2026.1 (lin64) Build 6511674 Tue Jun 16 11:01:26 MDT 2026
//Date        : Fri Sep 25 13:56:32 2026
//Host        : LNXPC running 64-bit Ubuntu 22.04.5 LTS
//Command     : generate_target mpsoc_bd_wrapper.bd
//Design      : mpsoc_bd_wrapper
//Purpose     : IP block netlist
//--------------------------------------------------------------------------------
`timescale 1 ps / 1 ps

module mpsoc_bd_wrapper
   (tempsensor_i2c_pl_scl_io,
    tempsensor_i2c_pl_sda_io);
  inout tempsensor_i2c_pl_scl_io;
  inout tempsensor_i2c_pl_sda_io;

  wire tempsensor_i2c_pl_scl_i;
  wire tempsensor_i2c_pl_scl_io;
  wire tempsensor_i2c_pl_scl_o;
  wire tempsensor_i2c_pl_scl_t;
  wire tempsensor_i2c_pl_sda_i;
  wire tempsensor_i2c_pl_sda_io;
  wire tempsensor_i2c_pl_sda_o;
  wire tempsensor_i2c_pl_sda_t;

  mpsoc_bd mpsoc_bd_i
       (.tempsensor_i2c_pl_scl_i(tempsensor_i2c_pl_scl_i),
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
