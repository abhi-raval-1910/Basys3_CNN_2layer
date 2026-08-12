`timescale 1ns / 1ps
// =====================================================================
//  pool_engine.v  —  Parameterized 2x2 / stride-2 max pooling
// =====================================================================
//  Reads conv_out RAM (one address at a time), writes pool_out RAM.
//  Now parameterized over INPUT_CH, INPUT_H, INPUT_W, OUTPUT_H,
//  OUTPUT_W so a single source file serves both pool stages:
//      Pool1: INPUT_CH=8,  INPUT=26x26, OUTPUT=13x13
//      Pool2: INPUT_CH=16, INPUT=11x11, OUTPUT=5x5
// =====================================================================
module pool_engine #(
    parameter INPUT_CH  = 8,    // number of channels
    parameter INPUT_H   = 26,
    parameter INPUT_W   = 26,
    parameter OUTPUT_H  = 13,   // = INPUT_H / 2
    parameter OUTPUT_W  = 13,   // = INPUT_W / 2
    parameter IN_AW     = 13,   // address width of conv_out RAM
    parameter OUT_AW    = 11    // address width of pool_out RAM
)(
    input  wire clk,
    input  wire rst,
    input  wire start,
    output reg  done,

    output reg  [IN_AW-1:0]  co_addr,    // conv_out read address
    input  wire [7:0]        co_data,

    output reg               po_we,
    output reg  [OUT_AW-1:0] po_addr,    // 0..INPUT_CH*OUTPUT_H*OUTPUT_W-1
    output reg  [7:0]        po_data
);
    localparam S_IDLE=3'd0, S_ADDR=3'd1, S_WAIT=3'd2, S_CMP=3'd3,
               S_STORE=3'd4, S_NEXT=3'd5, S_DONE=3'd6;
    reg [2:0] state;

    reg [4:0] f;            // 0..INPUT_CH-1
    reg [4:0] py, px;       // 0..OUTPUT_H-1, 0..OUTPUT_W-1
    reg [1:0] d;            // 0..3  (which of the 4 taps: (0,0)(0,1)(1,0)(1,1))
    reg [7:0] best;

    // conv_out address for filter f, pool position (py, px), tap dd:
    //   addr = f * (INPUT_H*INPUT_W) + (py*2 + dd[1]) * INPUT_W + (px*2 + dd[0])
    function [IN_AW-1:0] conv_addr_f;
        input [4:0] ff;
        input [4:0] pyy, pxx;
        input [1:0] dd;
        reg [5:0] yy, xx;
        begin
            yy = pyy*2 + dd[1];
            xx = pxx*2 + dd[0];
            conv_addr_f = ff * (INPUT_H * INPUT_W) + yy * INPUT_W + xx;
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            state<=S_IDLE; done<=0; f<=0; py<=0; px<=0; d<=0; best<=0; po_we<=0;
        end else begin
            po_we <= 1'b0;
            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        f<=0; py<=0; px<=0; d<=0; best<=0;
                        state <= S_ADDR;
                    end
                end

                S_ADDR: begin
                    co_addr <= conv_addr_f(f, py, px, d);
                    state   <= S_WAIT;
                end

                S_WAIT: state <= S_CMP;

                S_CMP: begin
                    if (d == 2'd0 || co_data > best) best <= co_data;
                    if (d == 2'd3) state <= S_STORE;
                    else begin
                        d     <= d + 1;
                        state <= S_ADDR;
                    end
                end

                S_STORE: begin
                    po_data <= best;
                    po_addr <= f * (OUTPUT_H * OUTPUT_W) + py * OUTPUT_W + px;
                    po_we   <= 1'b1;
                    d       <= 0;
                    state   <= S_NEXT;
                end

                S_NEXT: begin
                    if (px == OUTPUT_W - 1) begin
                        px <= 0;
                        if (py == OUTPUT_H - 1) begin
                            py <= 0;
                            if (f == INPUT_CH - 1) state <= S_DONE;
                            else begin f <= f + 1; state <= S_ADDR; end
                        end else begin py <= py + 1; state <= S_ADDR; end
                    end else begin px <= px + 1; state <= S_ADDR; end
                end

                S_DONE: begin
                    done <= 1'b1;
                    if (!start) state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
