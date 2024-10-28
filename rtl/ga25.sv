//============================================================================
//  Copyright (C) 2024 Martin Donlon
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================

module GA25(
    input clk,
    input clk_ram,

    input ce,
    input ce_pix,

    input paused,

    input reset,

    input mem_cs,
    input mem_wr,
    input mem_rd,
    input io_wr,
    input io_rd,

    output busy,

    input [15:0] addr,
    input [15:0] cpu_din,
    output reg [15:0] cpu_dout,
    
    input NL,

    input [63:0] sdr_data,
    output [24:0] sdr_addr,
    output sdr_req,
    input sdr_rdy,

    output reg vblank,
    output reg vsync,
    output reg hblank,
    output reg hsync,

    output reg [10:0] color_out,

    input [2:0] dbg_en_layers
);

// VRAM
reg [14:0] vram_addr;
reg [15:0] vram_data;
wire [15:0] vram_q;
reg vram_we;

singleport_ram #(.widthad(15), .width(16), .name("VRAM")) vram(
    .clock(clk),
    .address(vram_addr),
    .q(vram_q),
    .wren(vram_we),
    .data(vram_data)
);

//// VIDEO TIMING
reg [9:0] hcnt, vcnt;
reg vpulse, hpulse;

wire [9:0] VE = vcnt ^ {1'b0, {9{NL}}};



always_ff @(posedge clk) begin
    bit _hblank, _vblank;

    if (ce_pix) begin
        hcnt <= hcnt + 10'd1;
        if (hcnt == 10'd469) begin
            hcnt <= 10'd46;
            vcnt <= vcnt + 10'd1;
            if (vcnt == 10'd375) begin
                vcnt <= 10'd114;
            end
        end

        _hblank = hcnt < 10'd102 || hcnt > 10'd421;
        _vblank = vcnt > 10'd375 || vcnt < 10'd136;

        hblank <= _hblank;
        vblank <= _vblank;
        hsync <= hcnt < 10'd71 || hcnt > 10'd454;
        vsync <= vcnt > 10'd114 && vcnt < 10'd125;
        hpulse <= hcnt == 10'd46;
        vpulse <= (vcnt == 10'd124 && hcnt > 10'd260) || (vcnt == 10'd125 && hcnt < 10'd260);
    end
end

wire [21:0] rom_addr[2];
wire [31:0] rom_data[2];
wire        rom_req[2];
wire        rom_rdy[2];

ga23_sdram sdram(
    .clk(clk),
    .clk_ram(clk_ram),

    .addr_a(rom_addr[0]),
    .data_a(rom_data[0]),
    .req_a(rom_req[0]),
    .rdy_a(rom_rdy[0]),

    .addr_b(rom_addr[1]),
    .data_b(rom_data[1]),
    .req_b(rom_req[1]),
    .rdy_b(rom_rdy[1]),

    .addr_c(0),
    .data_c(),
    .req_c(0),
    .rdy_c(),

    .sdr_addr(sdr_addr),
    .sdr_data(sdr_data),
    .sdr_req(sdr_req),
    .sdr_rdy(sdr_rdy)
);

//// MEMORY ACCESS
reg [2:0] mem_cyc;
reg [3:0] rs_cyc;
reg busy_we;

reg [9:0] x_ofs[2], y_ofs[2];
reg [7:0] control[2];
reg [9:0] rowscroll[2];
reg [9:0] rowselect[4];

wire [14:0] layer_vram_addr[2];
reg layer_load[2];
wire layer_prio[2];
wire [7:0] layer_color[2];
wire layer_enabled[2];
reg [15:0] vram_latch;

reg [1:0] cpu_access_st;
reg cpu_access_we;
reg [15:0] cpu_access_din;

reg [47:0] control_save_0[512];
reg [47:0] control_save_1[512];

reg [47:0] control_restore[2];

reg rowscroll_active, rowscroll_pending;

assign busy = |cpu_access_st;
reg prev_access;

always_ff @(posedge clk) begin
    bit [9:0] rs_y;
    if (reset) begin
        mem_cyc <= 0;
        cpu_access_st <= 2'd0;
        vram_we <= 0;
        
        // layer regs
        x_ofs[0] <= 10'd0; x_ofs[1] <= 10'd0;
        y_ofs[0] <= 10'd0; y_ofs[1] <= 10'd0;
        control[0] <= 8'd0; control[1] <= 8'd0;

        rowscroll_pending <= 0;
        rowscroll_active <= 0;

    end else begin
        prev_access <= mem_cs & (mem_rd | mem_wr);
        if (mem_cs & (mem_rd | mem_wr) & ~busy & ~prev_access) begin
            cpu_access_st <= 2'd1;
            cpu_access_we <= mem_wr;
            cpu_access_din <= cpu_din;
        end
        
        vram_we <= 0;

        if (ce) begin
            if (ce_pix) begin
                layer_load[0] <= 0; layer_load[1] <= 0;
                mem_cyc <= mem_cyc + 3'd1;

                if (hpulse) begin
                    mem_cyc <= 3'd7;
                    rowscroll_pending <= 1;
                end
            end

            if (rowscroll_active) begin
                rs_cyc <= rs_cyc + 4'd1;
                case(rs_cyc)
                0: begin
                    rs_y = y_ofs[0] + VE;
                    vram_addr <= 15'h7800 + rs_y;
                end
                1: rowscroll[0] <= vram_q[9:0];
                2: begin
                    rs_y = y_ofs[1] + VE;
                    vram_addr <= 15'h7a00 + rs_y;
                end
                3: rowscroll[1] <= vram_q[9:0];
                8: begin
                    rs_y = y_ofs[0] + VE;
                    vram_addr <= 15'h7c00 + { VE[7], VE[6:0] };
                end
                9: rowselect[0] <= vram_q[9:0];
                10: begin
                    rs_y = y_ofs[1] + VE;
                    vram_addr <= 15'h7e00 + { VE[7], VE[6:0] };
                end
                11: rowselect[1] <= vram_q[9:0];
                15: begin
                    rowscroll_active <= 0;
                end
                default: begin end
                endcase
 
            end else begin
                if (ce_pix) begin
                    case(mem_cyc)
                        3'd0: begin
                            vram_addr <= layer_vram_addr[0];
                        end
                        3'd2: begin
                            vram_addr <= layer_vram_addr[1];
                        end
                        default: begin
                            if (cpu_access_st == 2'd1) begin
                                vram_addr <= addr[15:1];
                                vram_we <= cpu_access_we;
                                vram_data <= cpu_access_din;
                                cpu_access_st <= 2'd2;
                            end
                        end
                    endcase

                    //prio_out <= layer_prio[0] | layer_prio[1] | layer_prio[2] | layer_prio[3];

                    // determine base opaque color
                    color_out <= layer_color[1];

                    // override with transparent
                    if (|layer_color[0][3:0]) begin
                        color_out <= layer_color[0];
                    end

                end else if (ce) begin
                    case(mem_cyc)
                        3'd1: begin
                            vram_addr[0] <= 1;
                            vram_latch <= vram_q;
                            layer_load[0] <= 1;
                        end
                        3'd3: begin
                            vram_addr[0] <= 1;
                            vram_latch <= vram_q;
                            layer_load[1] <= 1;
                        end
                        default: begin
                            if (cpu_access_st == 2'd2) begin
                                cpu_access_st <= 2'd0;
                                cpu_access_we <= 0;
                                cpu_dout <= vram_q;
                            end
                            
                            if (rowscroll_pending && cpu_access_st == 2'd0) begin
                                rowscroll_pending <= 0;
                                rowscroll_active <= 1;
                                rs_cyc <= 4'd0;
                            end
                        end
                    endcase
                end
            end
        end

        if (io_wr) begin
            case(addr[7:0])
            'h80: y_ofs[0][9:0] <= cpu_din[9:0];
            'h82: x_ofs[0][9:0] <= cpu_din[9:0];
            
            'h84: y_ofs[1][9:0] <= cpu_din[9:0];
            'h86: x_ofs[1][9:0] <= cpu_din[9:0];
            
            'h8a: control[0] <= cpu_din[7:0];
            'h8c: control[1] <= cpu_din[7:0];
            endcase
        end

        if (hcnt == 10'd104 && ~paused) begin // end of hblank
            control_save_0[vcnt] <= { y_ofs[0], x_ofs[0], control[0], rowselect[0], rowscroll[0] };
            control_save_1[vcnt] <= { y_ofs[1], x_ofs[1], control[1], rowselect[1], rowscroll[1] };
        end else if (paused) begin
            control_restore[0] <= control_save_0[vcnt];
            control_restore[1] <= control_save_1[vcnt];
        end
    end
end



//// LAYERS
generate
	genvar i;
    for(i = 0; i < 2; i = i + 1 ) begin : generate_layer
        wire [9:0] _y_ofs = paused ? control_restore[i][47:38] : y_ofs[i];
        wire [9:0] _x_ofs = paused ? control_restore[i][37:28] : x_ofs[i];
        wire [7:0] _control = paused ? control_restore[i][27:20] : control[i];
        wire [9:0] _rowselect = paused ? control_restore[i][19:10] : rowselect[i];
        wire [9:0] _rowscroll = paused ? control_restore[i][9:0] : rowscroll[i];


        ga23_layer layer(
            .clk(clk),
            .ce_pix(ce_pix),

            .NL(NL),

            .control(_control),

            .x_ofs(_x_ofs),
            .y_ofs(_y_ofs),
  
            .x_base({hcnt[9:3] ^ {7{NL}}, 3'd0}),
            .y_base(VE),
            .rowscroll(_rowscroll),
            .rowselect(_rowselect),

            .vram_addr(layer_vram_addr[i]),

            .load(layer_load[i]),
            .attrib(vram_q),
            .index(vram_latch),

            .color_out(layer_color[i]),
            .prio_out(layer_prio[i]),
            .color_enabled(layer_enabled[i]),

            .sdr_addr(rom_addr[i]),
            .sdr_data(rom_data[i]),
            .sdr_req(rom_req[i]),
            .sdr_rdy(rom_rdy[i]),

            .dbg_enabled(dbg_en_layers[i])
        );
    end
endgenerate
endmodule

