// Testbench models for top with the simulation BD (SIM=1).
//
//   axi4_master   single-beat AXI4 reads and writes on one port
//   a53_model     the PS as Linux sees it: 32-bit accesses at the real PL
//                 addresses, decoded onto the sim BD's two BRAM ports
//   ddr_model     AXI4 write slave behind the DataMover (HPC0 and DDR in
//                 the real design), with a sparse byte memory
//   axis_sink     always-ready AXI4-Stream sink that keeps what it receives
`timescale 1ns/1ps

package tb_pkg;

  typedef virtual axi4_if #(.ADDR_W(12), .DATA_W(32), .ID_W(1), .USER_W(1)) bram_vif_t;
  typedef virtual axi4_if #(.ADDR_W(32), .DATA_W(32), .ID_W(4), .USER_W(4)) ddr_vif_t;
  typedef virtual axis_if #(.DATA_W(8)) sts_vif_t;
  typedef virtual clk_rst_if crst_vif_t;

  localparam bit [1:0] RESP_OKAY = 2'b00;

  // Cycles a single handshake may take before the access counts as hung.
  localparam int unsigned HANDSHAKE_TIMEOUT = 1000;

  // ---------------------------------------------------------------------
  class axi4_master #(type VIF = bram_vif_t);
    string name;
    VIF    vif;

    function new(string name, VIF vif);
      this.name = name;
      this.vif  = vif;
    endfunction

    // Drive every master output to its idle value (before and during reset).
    function void idle();
      vif.awvalid = 1'b0; vif.wvalid = 1'b0; vif.bready = 1'b0;
      vif.arvalid = 1'b0; vif.rready = 1'b0;
      vif.awid = '0; vif.awaddr = '0; vif.awlen = '0; vif.awsize = '0; vif.awburst = '0;
      vif.awlock = '0; vif.awcache = '0; vif.awprot = '0; vif.awuser = '0;
      vif.wdata = '0; vif.wstrb = '0; vif.wlast = '0;
      vif.arid = '0; vif.araddr = '0; vif.arlen = '0; vif.arsize = '0; vif.arburst = '0;
      vif.arlock = '0; vif.arcache = '0; vif.arprot = '0;
    endfunction

    // Waits for the next clock edge at which CHAN completes its handshake
    // (READY for AW/W/AR, VALID for B/R, whose READY the caller holds high).
    // Returns ok=0 after HANDSHAKE_TIMEOUT cycles.
    local task automatic wait_hs(string chan, output bit ok);
      int unsigned n = 0;
      bit done;
      ok = 1;
      forever begin
        @(vif.mst_cb);
        case (chan)
          "AW": done = (vif.mst_cb.awready === 1'b1);
          "W":  done = (vif.mst_cb.wready  === 1'b1);
          "B":  done = (vif.mst_cb.bvalid  === 1'b1);
          "AR": done = (vif.mst_cb.arready === 1'b1);
          "R":  done = (vif.mst_cb.rvalid  === 1'b1);
          default: $fatal(1, "%s: unknown channel %s", name, chan);
        endcase
        if (done) return;
        if (++n >= HANDSHAKE_TIMEOUT) begin
          $error("%s: no %s handshake after %0d cycles", name, chan, HANDSHAKE_TIMEOUT);
          ok = 0;
          return;
        end
      end
    endtask

    // One 32-bit write: AW and W together, then B. AxPROT 3'b010
    // (non-secure, unprivileged, data), as the A53 issues it under Linux.
    task automatic write32(bit [31:0] offset, bit [31:0] data, output bit [1:0] resp);
      bit aw_ok, w_ok, b_ok;
      resp = 2'bxx;
      @(vif.mst_cb);
      vif.mst_cb.awaddr  <= offset;
      vif.mst_cb.awlen   <= 8'd0;
      vif.mst_cb.awsize  <= 3'd2;
      vif.mst_cb.awburst <= 2'b01;
      vif.mst_cb.awcache <= 4'b0011;
      vif.mst_cb.awprot  <= 3'b010;
      vif.mst_cb.awvalid <= 1'b1;
      vif.mst_cb.wdata   <= data;
      vif.mst_cb.wstrb   <= '1;
      vif.mst_cb.wlast   <= 1'b1;
      vif.mst_cb.wvalid  <= 1'b1;
      vif.mst_cb.bready  <= 1'b1;
      fork
        begin
          wait_hs("AW", aw_ok);
          vif.mst_cb.awvalid <= 1'b0;
        end
        begin
          wait_hs("W", w_ok);
          vif.mst_cb.wvalid <= 1'b0;
          vif.mst_cb.wlast  <= 1'b0;
        end
      join
      if (aw_ok && w_ok) begin
        wait_hs("B", b_ok);
        if (b_ok) resp = vif.mst_cb.bresp;
      end
      vif.mst_cb.bready <= 1'b0;
    endtask

    // One 32-bit read: AR, then R.
    task automatic read32(bit [31:0] offset, output bit [31:0] data, output bit [1:0] resp);
      bit ar_ok, r_ok;
      data = 'x;
      resp = 2'bxx;
      @(vif.mst_cb);
      vif.mst_cb.araddr  <= offset;
      vif.mst_cb.arlen   <= 8'd0;
      vif.mst_cb.arsize  <= 3'd2;
      vif.mst_cb.arburst <= 2'b01;
      vif.mst_cb.arcache <= 4'b0011;
      vif.mst_cb.arprot  <= 3'b010;
      vif.mst_cb.arvalid <= 1'b1;
      vif.mst_cb.rready  <= 1'b1;
      wait_hs("AR", ar_ok);
      vif.mst_cb.arvalid <= 1'b0;
      if (ar_ok) begin
        wait_hs("R", r_ok);
        if (r_ok) begin
          data = vif.mst_cb.rdata;
          resp = vif.mst_cb.rresp;
          if (vif.mst_cb.rlast !== 1'b1)
            $error("%s: single-beat read returned RLAST=%b", name, vif.mst_cb.rlast);
        end
      end
      vif.mst_cb.rready <= 1'b0;
    endtask
  endclass

  // ---------------------------------------------------------------------
  // The PS's view of the PL, at the addresses mpsoc_bd assigns
  // (hw/bd/mpsoc_bd.tcl). The sim BD's BRAMs are 4 KB where the real
  // apertures are 8 KB, so offsets at or above SIM_BRAM_BYTES are refused
  // rather than silently wrapped.
  class a53_model;
    localparam bit [31:0] CTL_BRAM_BASE  = 32'hB001_0000;
    localparam bit [31:0] DMA_BRAM_BASE  = 32'hB001_2000;
    localparam bit [31:0] APERTURE_BYTES = 32'h0000_2000;
    localparam bit [31:0] SIM_BRAM_BYTES = 32'h0000_1000;

    axi4_master #(bram_vif_t) ctl;
    axi4_master #(bram_vif_t) dma;
    int unsigned errors;

    function new(bram_vif_t ctl_vif, bram_vif_t dma_vif);
      ctl = new("a53.ctl_bram", ctl_vif);
      dma = new("a53.dma_bram", dma_vif);
    endfunction

    function void idle();
      ctl.idle();
      dma.idle();
    endfunction

    local function bit decode(bit [31:0] addr, output axi4_master #(bram_vif_t) port,
                              output bit [31:0] offset);
      if (addr[1:0] != 2'b00) begin
        $error("a53: unaligned 32-bit access at 0x%08h", addr);
        return 0;
      end
      if (addr >= CTL_BRAM_BASE && addr < CTL_BRAM_BASE + APERTURE_BYTES) begin
        port = ctl; offset = addr - CTL_BRAM_BASE;
      end else if (addr >= DMA_BRAM_BASE && addr < DMA_BRAM_BASE + APERTURE_BYTES) begin
        port = dma; offset = addr - DMA_BRAM_BASE;
      end else begin
        $error("a53: 0x%08h is not a PL address in this design", addr);
        return 0;
      end
      if (offset >= SIM_BRAM_BYTES) begin
        $error("a53: 0x%08h is inside the real 8 KB aperture but beyond the sim BD's 4 KB BRAM", addr);
        return 0;
      end
      return 1;
    endfunction

    task automatic write32(bit [31:0] addr, bit [31:0] data);
      axi4_master #(bram_vif_t) port;
      bit [31:0] offset;
      bit [1:0]  resp;
      if (!decode(addr, port, offset)) begin errors++; return; end
      port.write32(offset, data, resp);
      if (resp !== RESP_OKAY) begin
        errors++;
        $error("a53: write 0x%08h = 0x%08h failed, BRESP=%b", addr, data, resp);
      end
    endtask

    task automatic read32(bit [31:0] addr, output bit [31:0] data);
      axi4_master #(bram_vif_t) port;
      bit [31:0] offset;
      bit [1:0]  resp;
      data = 'x;
      if (!decode(addr, port, offset)) begin errors++; return; end
      port.read32(offset, data, resp);
      if (resp !== RESP_OKAY) begin
        errors++;
        $error("a53: read 0x%08h failed, RRESP=%b", addr, resp);
      end
    endtask
  endclass

  // ---------------------------------------------------------------------
  // Accepts INCR write bursts from the DataMover into a sparse byte memory.
  // WREADY is held low until a burst's AW has been accepted, which AXI
  // allows a slave to do, so every W beat has a known address.
  class ddr_model;
    ddr_vif_t        vif;
    bit [7:0]        mem[bit [31:0]];
    int unsigned     bursts;
    int unsigned     beats;
    typedef struct { bit [31:0] addr; int unsigned len; bit [3:0] id; } aw_t;
    local mailbox #(aw_t) aw_q = new();
    local mailbox #(bit [3:0]) b_q = new();

    function new(ddr_vif_t vif);
      this.vif = vif;
    endfunction

    function void idle();
      vif.awready = 1'b0; vif.wready = 1'b0;
      vif.bvalid = 1'b0; vif.bid = '0; vif.bresp = '0;
      vif.arready = 1'b0; vif.rvalid = 1'b0; vif.rid = '0; vif.rdata = '0;
      vif.rresp = '0; vif.rlast = 1'b0;
    endfunction

    function bit [31:0] read32(bit [31:0] addr);
      for (int b = 0; b < 4; b++)
        read32[8*b +: 8] = mem.exists(addr + b) ? mem[addr + b] : 8'h00;
    endfunction

    task run();
      fork
        accept_aw();
        accept_w();
        respond_b();
      join_none
    endtask

    local task accept_aw();
      vif.slv_cb.awready <= 1'b1;
      forever begin
        @(vif.slv_cb);
        if (vif.slv_cb.awvalid === 1'b1) begin  // AWREADY is held high
          aw_t aw;
          aw.addr = vif.slv_cb.awaddr;
          aw.len  = vif.slv_cb.awlen + 1;
          aw.id   = vif.slv_cb.awid;
          if (vif.slv_cb.awburst !== 2'b01 || vif.slv_cb.awsize !== 3'd2)
            $error("ddr: unsupported burst type %b / size %0d at 0x%08h",
                   vif.slv_cb.awburst, vif.slv_cb.awsize, aw.addr);
          aw_q.put(aw);
        end
      end
    endtask

    local task accept_w();
      forever begin
        aw_t aw;
        aw_q.get(aw);
        bursts++;
        vif.slv_cb.wready <= 1'b1;
        for (int unsigned beat = 0; beat < aw.len; ) begin
          @(vif.slv_cb);
          if (vif.slv_cb.wvalid === 1'b1) begin
            for (int b = 0; b < 4; b++)
              if (vif.slv_cb.wstrb[b]) mem[aw.addr + 4 * beat + b] = vif.slv_cb.wdata[8*b +: 8];
            if (vif.slv_cb.wlast !== (beat == aw.len - 1))
              $error("ddr: WLAST=%b on beat %0d of a %0d-beat burst at 0x%08h",
                     vif.slv_cb.wlast, beat, aw.len, aw.addr);
            beats++;
            beat++;
          end
        end
        vif.slv_cb.wready <= 1'b0;
        b_q.put(aw.id);
      end
    endtask

    local task respond_b();
      forever begin
        bit [3:0] id;
        b_q.get(id);
        vif.slv_cb.bid    <= id;
        vif.slv_cb.bresp  <= RESP_OKAY;
        vif.slv_cb.bvalid <= 1'b1;
        do @(vif.slv_cb); while (vif.slv_cb.bready !== 1'b1);
        vif.slv_cb.bvalid <= 1'b0;
      end
    endtask
  endclass

  // ---------------------------------------------------------------------
  class axis_sink #(type VIF = sts_vif_t, int DATA_W = 8);
    string name;
    VIF    vif;
    bit [DATA_W-1:0] received[$];

    function new(string name, VIF vif);
      this.name = name;
      this.vif  = vif;
    endfunction

    function void idle();
      vif.tready = 1'b0;
    endfunction

    task run();
      fork
        begin
          vif.slv_cb.tready <= 1'b1;
          forever begin
            @(vif.slv_cb);
            if (vif.slv_cb.tvalid === 1'b1) received.push_back(vif.slv_cb.tdata);
          end
        end
      join_none
    endtask
  endclass

endpackage
