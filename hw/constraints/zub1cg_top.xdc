# ZUBoard 1CG top-level constraints.
#
# Pin locations for PL interfaces that use the board flow (currently the
# AXI IIC on the temperature sensor, board interface "tempsensor_i2c_pl")
# come from the Avnet/Tria board files: IP Integrator generates an
# IP-level *_board.xdc for them. Do not duplicate them here unless the
# board flow is dropped.
#
# Anything not covered by the board flow (own RTL ports, extra PL I/O)
# goes in this file.

# --- Bitstream settings -------------------------------------------------
# Compressed bitstreams load faster and work with the Linux FPGA Manager.
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

# --- Fallback: temperature sensor I2C (STTS22H, U1), HD bank 44, 1.8 V ---
# Only needed if USE_BOARD_FLOW is turned off on axi_iic_0.
#
# WARNING: the ZUBoard 1CG HW User Guide v1.0 is inconsistent here.
# Table 7 (bank 44) lists SCL = A6 and SDA = B7, while Table 17 (I2C)
# lists SCL = B7 and SDA = A6. Check the board files or the schematic
# (net names HD_SENSOR_I2C_SCL / HD_SENSOR_I2C_SDA) before enabling.
#
# set_property -dict {PACKAGE_PIN <SCL pin> IOSTANDARD LVCMOS18} [get_ports tempsensor_i2c_pl_scl_io]
# set_property -dict {PACKAGE_PIN <SDA pin> IOSTANDARD LVCMOS18} [get_ports tempsensor_i2c_pl_sda_io]
