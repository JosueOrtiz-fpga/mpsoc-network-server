`default_nettype none

module top#(SIM=0)
   (inout wire tempsensor_i2c_pl_scl_io,
    inout wire tempsensor_i2c_pl_sda_io);

    // AXI PROT setting for unsecure (LINUX) accesses
    localparam AX_PROT = 3'b010;

    localparam XCACHE_CACHEABLE = 4'hF; // reference guide indicates "any" non-zero value 
    localparam XUSER_DEFAULT    = 4'h0; // unused
    localparam CMD_TAG          = 8'h00; // unused

    localparam PKT_LENGTH = 360;

    // clocks, resets
    logic pl_clk0;
    logic[0:0] aresetn;
    logic[0:0] bus_struct_reset_0;

    logic [31:0]S_AXIS_S2MM_0_tdata;
    logic [3:0]S_AXIS_S2MM_0_tkeep;
    logic S_AXIS_S2MM_0_tlast;
    logic S_AXIS_S2MM_0_tready;
    logic S_AXIS_S2MM_0_tvalid;
    logic [111:0]S_AXIS_S2MM_CMD_0_tdata;
    logic S_AXIS_S2MM_CMD_0_tready;
    logic S_AXIS_S2MM_CMD_0_tvalid;

    // CTL BRAM
    logic [31:0]BRAM_PORTB_0_addr;
    logic BRAM_PORTB_0_clk;
    logic [31:0]BRAM_PORTB_0_din;
    logic [31:0]BRAM_PORTB_0_dout;
    logic BRAM_PORTB_0_en;
    logic BRAM_PORTB_0_rst;
    logic [3:0]BRAM_PORTB_0_we;

    // DMA BRAM
    logic pl_ps_irq1_0;
    logic [31:0]BRAM_PORTB_1_addr;
    logic BRAM_PORTB_1_clk;
    logic [31:0]BRAM_PORTB_1_din;
    logic [31:0]BRAM_PORTB_1_dout;
    logic BRAM_PORTB_1_en;
    logic BRAM_PORTB_1_rst;
    logic [3:0]BRAM_PORTB_1_we;

    // I2C
    logic tempsensor_i2c_pl_scl_i;
    logic tempsensor_i2c_pl_scl_o;
    logic tempsensor_i2c_pl_scl_t;
    logic tempsensor_i2c_pl_sda_i;
    logic tempsensor_i2c_pl_sda_o;
    logic tempsensor_i2c_pl_sda_t;

    // Simulation BD only (SIM=1). In the real design these sit inside
    // mpsoc_bd (A53 masters, HPC0, PS clocks); the sim BD exposes them so the
    // testbench (hw/sim) can drive and observe them. Unused when SIM=0.
    wire clk_100MHz;
    wire reset_rtl;
    wire n_reset_rtl;

    wire [11:0]S_AXI_BRAM_0_awaddr;  wire [11:0]S_AXI_BRAM_1_awaddr;
    wire [7:0] S_AXI_BRAM_0_awlen;   wire [7:0] S_AXI_BRAM_1_awlen;
    wire [2:0] S_AXI_BRAM_0_awsize;  wire [2:0] S_AXI_BRAM_1_awsize;
    wire [1:0] S_AXI_BRAM_0_awburst; wire [1:0] S_AXI_BRAM_1_awburst;
    wire       S_AXI_BRAM_0_awlock;  wire       S_AXI_BRAM_1_awlock;
    wire [3:0] S_AXI_BRAM_0_awcache; wire [3:0] S_AXI_BRAM_1_awcache;
    wire [2:0] S_AXI_BRAM_0_awprot;  wire [2:0] S_AXI_BRAM_1_awprot;
    wire       S_AXI_BRAM_0_awvalid; wire       S_AXI_BRAM_1_awvalid;
    wire       S_AXI_BRAM_0_awready; wire       S_AXI_BRAM_1_awready;
    wire [31:0]S_AXI_BRAM_0_wdata;   wire [31:0]S_AXI_BRAM_1_wdata;
    wire [3:0] S_AXI_BRAM_0_wstrb;   wire [3:0] S_AXI_BRAM_1_wstrb;
    wire       S_AXI_BRAM_0_wlast;   wire       S_AXI_BRAM_1_wlast;
    wire       S_AXI_BRAM_0_wvalid;  wire       S_AXI_BRAM_1_wvalid;
    wire       S_AXI_BRAM_0_wready;  wire       S_AXI_BRAM_1_wready;
    wire [1:0] S_AXI_BRAM_0_bresp;   wire [1:0] S_AXI_BRAM_1_bresp;
    wire       S_AXI_BRAM_0_bvalid;  wire       S_AXI_BRAM_1_bvalid;
    wire       S_AXI_BRAM_0_bready;  wire       S_AXI_BRAM_1_bready;
    wire [11:0]S_AXI_BRAM_0_araddr;  wire [11:0]S_AXI_BRAM_1_araddr;
    wire [7:0] S_AXI_BRAM_0_arlen;   wire [7:0] S_AXI_BRAM_1_arlen;
    wire [2:0] S_AXI_BRAM_0_arsize;  wire [2:0] S_AXI_BRAM_1_arsize;
    wire [1:0] S_AXI_BRAM_0_arburst; wire [1:0] S_AXI_BRAM_1_arburst;
    wire       S_AXI_BRAM_0_arlock;  wire       S_AXI_BRAM_1_arlock;
    wire [3:0] S_AXI_BRAM_0_arcache; wire [3:0] S_AXI_BRAM_1_arcache;
    wire [2:0] S_AXI_BRAM_0_arprot;  wire [2:0] S_AXI_BRAM_1_arprot;
    wire       S_AXI_BRAM_0_arvalid; wire       S_AXI_BRAM_1_arvalid;
    wire       S_AXI_BRAM_0_arready; wire       S_AXI_BRAM_1_arready;
    wire [31:0]S_AXI_BRAM_0_rdata;   wire [31:0]S_AXI_BRAM_1_rdata;
    wire [1:0] S_AXI_BRAM_0_rresp;   wire [1:0] S_AXI_BRAM_1_rresp;
    wire       S_AXI_BRAM_0_rlast;   wire       S_AXI_BRAM_1_rlast;
    wire       S_AXI_BRAM_0_rvalid;  wire       S_AXI_BRAM_1_rvalid;
    wire       S_AXI_BRAM_0_rready;  wire       S_AXI_BRAM_1_rready;

    wire [3:0] M_AXI_S2MM_0_awid;
    wire [31:0]M_AXI_S2MM_0_awaddr;
    wire [7:0] M_AXI_S2MM_0_awlen;
    wire [2:0] M_AXI_S2MM_0_awsize;
    wire [1:0] M_AXI_S2MM_0_awburst;
    wire [3:0] M_AXI_S2MM_0_awcache;
    wire [2:0] M_AXI_S2MM_0_awprot;
    wire [3:0] M_AXI_S2MM_0_awuser;
    wire       M_AXI_S2MM_0_awvalid;
    wire       M_AXI_S2MM_0_awready;
    wire [31:0]M_AXI_S2MM_0_wdata;
    wire [3:0] M_AXI_S2MM_0_wstrb;
    wire       M_AXI_S2MM_0_wlast;
    wire       M_AXI_S2MM_0_wvalid;
    wire       M_AXI_S2MM_0_wready;
    wire [1:0] M_AXI_S2MM_0_bresp;
    wire       M_AXI_S2MM_0_bvalid;
    wire       M_AXI_S2MM_0_bready;

    wire [7:0] M_AXIS_S2MM_STS_0_tdata;
    wire [0:0] M_AXIS_S2MM_STS_0_tkeep;
    wire       M_AXIS_S2MM_STS_0_tlast;
    wire       M_AXIS_S2MM_STS_0_tvalid;
    wire       M_AXIS_S2MM_STS_0_tready;


    // BRAM access
    task ctl_bram_access(input logic[31:0] addr, input logic [31:0] data, input logic wr_rd_n);
        BRAM_PORTB_0_addr <= addr;
        BRAM_PORTB_0_en   <= 1'b1;
        BRAM_PORTB_0_we   <= {3{wr_rd_n}};
        BRAM_PORTB_0_din  <= (wr_rd_n==1'b1) ? data : 32'h0;
    endtask : ctl_bram_access

    task dma_bram_access(input logic[31:0] addr, input logic [31:0] data, input logic wr_rd_n);
        BRAM_PORTB_1_addr <= addr;
        BRAM_PORTB_1_en   <= 1'b1;
        BRAM_PORTB_1_we   <= {3{wr_rd_n}};
        BRAM_PORTB_1_din  <= (wr_rd_n==1'b1) ? data : 32'h0;
    endtask : dma_bram_access


    // Settings Loading
    typedef enum {E_WR_READY, E_RD_READY, E_ACK, E_LOAD} t_state;
    t_state state;

    logic[31:0] ctl_reg;
    logic[31:0] dma_reg_LO;
    logic[31:0] dma_reg_HI;
    logic[31:0] temp_addr;

    logic load_done;

    always_ff@(posedge pl_clk0) begin
        if(!aresetn) begin
            state           <= E_WR_READY;
            BRAM_PORTB_0_en <= 1'b0;
            BRAM_PORTB_0_we <= 1'b0;
            load_done       <= 1'b0;
        end
        else begin
            // control lines to default values
            BRAM_PORTB_0_en <= 1'b0;
            BRAM_PORTB_0_we <= 1'b0;
            load_done       <= 1'b0;
            temp_addr       <= 32'h0;

            case (state)
                E_WR_READY: begin
                    ctl_bram_access(32'h0, 32'h1, 1'b1);
                    state <= E_RD_READY;
                end
                E_RD_READY: begin
                    // read access latency is set to 1 cycle
                    ctl_bram_access(32'h0, 32'h0, 1'b0);
                    state <= E_ACK;
                end
                E_ACK: begin
                    if(BRAM_PORTB_0_dout[1:0] == 2'b11) state <= E_LOAD;
                    // back to E_WR_READY:
                    // after a Power-Cycle software zero initializes the BRAM
                    // during operation, software may not have loaded new settings
                    else state <= E_WR_READY;
                end
                E_LOAD: begin
                    ctl_bram_access(temp_addr, 32'h0, 1'b1);
                    temp_addr <= temp_addr + 4;
                    // last word read at this cycle
                    if(BRAM_PORTB_0_addr==32'h8 && !BRAM_PORTB_0_we && BRAM_PORTB_0_en) begin
                        state     <= E_WR_READY;
                        load_done <= 1'b1;
                    end
                end
                default: state <= E_WR_READY;
            endcase
        end
    end

    always_ff@(posedge pl_clk0) begin
        if(aresetn) begin
            if(!BRAM_PORTB_0_we && BRAM_PORTB_0_en) begin
                case (BRAM_PORTB_0_addr)
                    32'h0: ctl_reg    <= BRAM_PORTB_0_dout;
                    32'h4: dma_reg_LO <= BRAM_PORTB_0_dout;
                    32'h8: dma_reg_HI <= BRAM_PORTB_0_dout;
                endcase
            end
        end
    end

    // DMA Loading
    logic[79:0] s2mm_cmd_reg;

    always_ff@(posedge pl_clk0) begin
        S_AXIS_S2MM_CMD_0_tvalid <= 1'b0;

        if(load_done) s2mm_cmd_reg <={CMD_TAG, XUSER_DEFAULT, XCACHE_CACHEABLE, dma_reg_HI, dma_reg_LO, 32'h0};
        if(pl_ps_irq1_0) begin
            // assumes SW has zero initialized BRAM slot
            // no backpressure support for now
            S_AXIS_S2MM_CMD_0_tvalid <= 1'b1;
            S_AXIS_S2MM_CMD_0_tdata <= s2mm_cmd_reg | 32'({1'b0, 1'b1, 6'h0, 1'b1, 23'(PKT_LENGTH)});
            dma_bram_access(32'h0, {31'(PKT_LENGTH), 1'b1}, 1'b1);
        end
    end

    // Dummy Data generation
    logic[22:0] byte_count;
    logic init_done;
    always_ff@(posedge pl_clk0) begin
        if(!aresetn) begin
            pl_ps_irq1_0 <= 1'b0;
            init_done    <= 1'b0;
        end
        else begin
            // default values
            S_AXIS_S2MM_0_tkeep <= '1;
            S_AXIS_S2MM_0_tlast <= 1'b0;
            byte_count          <= 0;
            pl_ps_irq1_0        <= 1'b0;

            // initialization control
            if(load_done) init_done <= 1'b1;

            // dummy data doesn't stop
            if(init_done) begin
                if(!S_AXIS_S2MM_0_tvalid || (S_AXIS_S2MM_0_tvalid && S_AXIS_S2MM_0_tready)) begin
                    S_AXIS_S2MM_0_tvalid <= 1'b1;
                    S_AXIS_S2MM_0_tdata <= byte_count;
                    S_AXIS_S2MM_0_tlast <= (byte_count ==PKT_LENGTH-1) ? 1'b1 : 1'b0;
                    // Software to compensate for delay between TLAST and buffer available in DDR
                    pl_ps_irq1_0        <= S_AXIS_S2MM_0_tlast;
                    byte_count          <= (byte_count ==PKT_LENGTH-1) ? 0 : byte_count + 1;
                end
            end
        end
    end

    // MPSOC BD
    generate
    if(SIM==0) begin : mpsoc_bd
        mpsoc_bd mpsoc_bd_i
        (.aresetn(aresetn),
            .bus_struct_reset_0(bus_struct_reset_0),
            .BRAM_PORTB_0_addr(BRAM_PORTB_0_addr),
            .BRAM_PORTB_0_clk(pl_clk0),
            .BRAM_PORTB_0_din(BRAM_PORTB_0_din),
            .BRAM_PORTB_0_dout(BRAM_PORTB_0_dout),
            .BRAM_PORTB_0_en(BRAM_PORTB_0_en),
            .BRAM_PORTB_0_rst(bus_struct_reset_0),
            .BRAM_PORTB_0_we(BRAM_PORTB_0_we),
            // DMA Descriptor BRAM
            .pl_ps_irq1_0(pl_ps_irq1_0),
            .BRAM_PORTB_1_addr(BRAM_PORTB_1_addr),
            .BRAM_PORTB_1_clk(pl_clk0),
            .BRAM_PORTB_1_din(BRAM_PORTB_1_din),
            .BRAM_PORTB_1_dout(BRAM_PORTB_1_dout),
            .BRAM_PORTB_1_en(BRAM_PORTB_1_en),
            .BRAM_PORTB_1_rst(bus_struct_reset_0),
            .BRAM_PORTB_1_we(BRAM_PORTB_1_we),
            //
            .S_AXIS_S2MM_0_tdata(S_AXIS_S2MM_0_tdata),
            .S_AXIS_S2MM_0_tkeep(S_AXIS_S2MM_0_tkeep),
            .S_AXIS_S2MM_0_tlast(S_AXIS_S2MM_0_tlast),
            .S_AXIS_S2MM_0_tready(S_AXIS_S2MM_0_tready),
            .S_AXIS_S2MM_0_tvalid(S_AXIS_S2MM_0_tvalid),
            .S_AXIS_S2MM_CMD_0_tdata(S_AXIS_S2MM_CMD_0_tdata),
            .S_AXIS_S2MM_CMD_0_tready(S_AXIS_S2MM_CMD_0_tready),
            .S_AXIS_S2MM_CMD_0_tvalid(S_AXIS_S2MM_CMD_0_tvalid),
            .pl_clk0(pl_clk0),
            .saxigp0_arprot_0(AX_PROT),
            .saxigp0_awprot_0(AX_PROT),
            .tempsensor_i2c_pl_scl_i(tempsensor_i2c_pl_scl_i),
            .tempsensor_i2c_pl_scl_o(tempsensor_i2c_pl_scl_o),
            .tempsensor_i2c_pl_scl_t(tempsensor_i2c_pl_scl_t),
            .tempsensor_i2c_pl_sda_i(tempsensor_i2c_pl_sda_i),
            .tempsensor_i2c_pl_sda_o(tempsensor_i2c_pl_sda_o),
            .tempsensor_i2c_pl_sda_t(tempsensor_i2c_pl_sda_t));

        // I2C I/O BUFs
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
    end
    else begin : sim_mpsoc_bd
        sim_mpsco_bd sim_mpsco_bd_i
        (.BRAM_PORTB_0_addr(BRAM_PORTB_0_addr),
            .BRAM_PORTB_0_clk(pl_clk0),
            .BRAM_PORTB_0_din(BRAM_PORTB_0_din),
            .BRAM_PORTB_0_dout(BRAM_PORTB_0_dout),
            .BRAM_PORTB_0_en(BRAM_PORTB_0_en),
            .BRAM_PORTB_0_rst(bus_struct_reset_0),
            .BRAM_PORTB_0_we(BRAM_PORTB_0_we),
            .BRAM_PORTB_1_addr(BRAM_PORTB_1_addr),
            .BRAM_PORTB_1_clk(pl_clk0),
            .BRAM_PORTB_1_din(BRAM_PORTB_1_din),
            .BRAM_PORTB_1_dout(BRAM_PORTB_1_dout),
            .BRAM_PORTB_1_en(BRAM_PORTB_1_en),
            .BRAM_PORTB_1_rst(bus_struct_reset_0),
            .BRAM_PORTB_1_we(BRAM_PORTB_1_we),
            .M_AXIS_S2MM_STS_0_tdata(M_AXIS_S2MM_STS_0_tdata),
            .M_AXIS_S2MM_STS_0_tkeep(M_AXIS_S2MM_STS_0_tkeep),
            .M_AXIS_S2MM_STS_0_tlast(M_AXIS_S2MM_STS_0_tlast),
            .M_AXIS_S2MM_STS_0_tready(M_AXIS_S2MM_STS_0_tready),
            .M_AXIS_S2MM_STS_0_tvalid(M_AXIS_S2MM_STS_0_tvalid),
            .M_AXI_S2MM_0_awaddr(M_AXI_S2MM_0_awaddr),
            .M_AXI_S2MM_0_awburst(M_AXI_S2MM_0_awburst),
            .M_AXI_S2MM_0_awcache(M_AXI_S2MM_0_awcache),
            .M_AXI_S2MM_0_awid(M_AXI_S2MM_0_awid),
            .M_AXI_S2MM_0_awlen(M_AXI_S2MM_0_awlen),
            .M_AXI_S2MM_0_awprot(M_AXI_S2MM_0_awprot),
            .M_AXI_S2MM_0_awready(M_AXI_S2MM_0_awready),
            .M_AXI_S2MM_0_awsize(M_AXI_S2MM_0_awsize),
            .M_AXI_S2MM_0_awuser(M_AXI_S2MM_0_awuser),
            .M_AXI_S2MM_0_awvalid(M_AXI_S2MM_0_awvalid),
            .M_AXI_S2MM_0_bready(M_AXI_S2MM_0_bready),
            .M_AXI_S2MM_0_bresp(M_AXI_S2MM_0_bresp),
            .M_AXI_S2MM_0_bvalid(M_AXI_S2MM_0_bvalid),
            .M_AXI_S2MM_0_wdata(M_AXI_S2MM_0_wdata),
            .M_AXI_S2MM_0_wlast(M_AXI_S2MM_0_wlast),
            .M_AXI_S2MM_0_wready(M_AXI_S2MM_0_wready),
            .M_AXI_S2MM_0_wstrb(M_AXI_S2MM_0_wstrb),
            .M_AXI_S2MM_0_wvalid(M_AXI_S2MM_0_wvalid),
            .S_AXIS_S2MM_0_tdata(S_AXIS_S2MM_0_tdata),
            .S_AXIS_S2MM_0_tkeep(S_AXIS_S2MM_0_tkeep),
            .S_AXIS_S2MM_0_tlast(S_AXIS_S2MM_0_tlast),
            .S_AXIS_S2MM_0_tready(S_AXIS_S2MM_0_tready),
            .S_AXIS_S2MM_0_tvalid(S_AXIS_S2MM_0_tvalid),
            .S_AXIS_S2MM_CMD_0_tdata(S_AXIS_S2MM_CMD_0_tdata),
            .S_AXIS_S2MM_CMD_0_tready(S_AXIS_S2MM_CMD_0_tready),
            .S_AXIS_S2MM_CMD_0_tvalid(S_AXIS_S2MM_CMD_0_tvalid),
            .S_AXI_BRAM_0_araddr(S_AXI_BRAM_0_araddr),
            .S_AXI_BRAM_0_arburst(S_AXI_BRAM_0_arburst),
            .S_AXI_BRAM_0_arcache(S_AXI_BRAM_0_arcache),
            .S_AXI_BRAM_0_arlen(S_AXI_BRAM_0_arlen),
            .S_AXI_BRAM_0_arlock(S_AXI_BRAM_0_arlock),
            .S_AXI_BRAM_0_arprot(S_AXI_BRAM_0_arprot),
            .S_AXI_BRAM_0_arready(S_AXI_BRAM_0_arready),
            .S_AXI_BRAM_0_arsize(S_AXI_BRAM_0_arsize),
            .S_AXI_BRAM_0_arvalid(S_AXI_BRAM_0_arvalid),
            .S_AXI_BRAM_0_awaddr(S_AXI_BRAM_0_awaddr),
            .S_AXI_BRAM_0_awburst(S_AXI_BRAM_0_awburst),
            .S_AXI_BRAM_0_awcache(S_AXI_BRAM_0_awcache),
            .S_AXI_BRAM_0_awlen(S_AXI_BRAM_0_awlen),
            .S_AXI_BRAM_0_awlock(S_AXI_BRAM_0_awlock),
            .S_AXI_BRAM_0_awprot(S_AXI_BRAM_0_awprot),
            .S_AXI_BRAM_0_awready(S_AXI_BRAM_0_awready),
            .S_AXI_BRAM_0_awsize(S_AXI_BRAM_0_awsize),
            .S_AXI_BRAM_0_awvalid(S_AXI_BRAM_0_awvalid),
            .S_AXI_BRAM_0_bready(S_AXI_BRAM_0_bready),
            .S_AXI_BRAM_0_bresp(S_AXI_BRAM_0_bresp),
            .S_AXI_BRAM_0_bvalid(S_AXI_BRAM_0_bvalid),
            .S_AXI_BRAM_0_rdata(S_AXI_BRAM_0_rdata),
            .S_AXI_BRAM_0_rlast(S_AXI_BRAM_0_rlast),
            .S_AXI_BRAM_0_rready(S_AXI_BRAM_0_rready),
            .S_AXI_BRAM_0_rresp(S_AXI_BRAM_0_rresp),
            .S_AXI_BRAM_0_rvalid(S_AXI_BRAM_0_rvalid),
            .S_AXI_BRAM_0_wdata(S_AXI_BRAM_0_wdata),
            .S_AXI_BRAM_0_wlast(S_AXI_BRAM_0_wlast),
            .S_AXI_BRAM_0_wready(S_AXI_BRAM_0_wready),
            .S_AXI_BRAM_0_wstrb(S_AXI_BRAM_0_wstrb),
            .S_AXI_BRAM_0_wvalid(S_AXI_BRAM_0_wvalid),
            .S_AXI_BRAM_1_araddr(S_AXI_BRAM_1_araddr),
            .S_AXI_BRAM_1_arburst(S_AXI_BRAM_1_arburst),
            .S_AXI_BRAM_1_arcache(S_AXI_BRAM_1_arcache),
            .S_AXI_BRAM_1_arlen(S_AXI_BRAM_1_arlen),
            .S_AXI_BRAM_1_arlock(S_AXI_BRAM_1_arlock),
            .S_AXI_BRAM_1_arprot(S_AXI_BRAM_1_arprot),
            .S_AXI_BRAM_1_arready(S_AXI_BRAM_1_arready),
            .S_AXI_BRAM_1_arsize(S_AXI_BRAM_1_arsize),
            .S_AXI_BRAM_1_arvalid(S_AXI_BRAM_1_arvalid),
            .S_AXI_BRAM_1_awaddr(S_AXI_BRAM_1_awaddr),
            .S_AXI_BRAM_1_awburst(S_AXI_BRAM_1_awburst),
            .S_AXI_BRAM_1_awcache(S_AXI_BRAM_1_awcache),
            .S_AXI_BRAM_1_awlen(S_AXI_BRAM_1_awlen),
            .S_AXI_BRAM_1_awlock(S_AXI_BRAM_1_awlock),
            .S_AXI_BRAM_1_awprot(S_AXI_BRAM_1_awprot),
            .S_AXI_BRAM_1_awready(S_AXI_BRAM_1_awready),
            .S_AXI_BRAM_1_awsize(S_AXI_BRAM_1_awsize),
            .S_AXI_BRAM_1_awvalid(S_AXI_BRAM_1_awvalid),
            .S_AXI_BRAM_1_bready(S_AXI_BRAM_1_bready),
            .S_AXI_BRAM_1_bresp(S_AXI_BRAM_1_bresp),
            .S_AXI_BRAM_1_bvalid(S_AXI_BRAM_1_bvalid),
            .S_AXI_BRAM_1_rdata(S_AXI_BRAM_1_rdata),
            .S_AXI_BRAM_1_rlast(S_AXI_BRAM_1_rlast),
            .S_AXI_BRAM_1_rready(S_AXI_BRAM_1_rready),
            .S_AXI_BRAM_1_rresp(S_AXI_BRAM_1_rresp),
            .S_AXI_BRAM_1_rvalid(S_AXI_BRAM_1_rvalid),
            .S_AXI_BRAM_1_wdata(S_AXI_BRAM_1_wdata),
            .S_AXI_BRAM_1_wlast(S_AXI_BRAM_1_wlast),
            .S_AXI_BRAM_1_wready(S_AXI_BRAM_1_wready),
            .S_AXI_BRAM_1_wstrb(S_AXI_BRAM_1_wstrb),
            .S_AXI_BRAM_1_wvalid(S_AXI_BRAM_1_wvalid),
            .aresetn(aresetn),
            .bus_struct_reset_0(bus_struct_reset_0),
            .clk_100MHz(clk_100MHz),
            .n_reset_rtl(n_reset_rtl),
            .pl_clk0(pl_clk0),
            .reset_rtl(reset_rtl));
    end
endmodule
`default_nettype wire
