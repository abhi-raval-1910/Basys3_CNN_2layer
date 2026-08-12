`timescale 1ns / 1ps
module uart_rx #(
    parameter CLKS_PER_BIT = 868 // 100,000,000 / 115200
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       rx,
    output reg  [7:0] data_out,
    output reg        valid
);
    localparam IDLE=3'b000, START=3'b001, DATA=3'b010, STOP=3'b011, CLEANUP=3'b100;

    reg [2:0] state = IDLE;
    reg [9:0] clk_count = 0;
    reg [2:0] bit_index = 0;
    reg rx_r = 1'b1, rx_rr = 1'b1;

    always @(posedge clk) begin
        rx_r  <= rx;
        rx_rr <= rx_r;
    end

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            valid <= 0;
            clk_count <= 0;
            bit_index <= 0;
        end else begin
            case (state)
                IDLE: begin
                    valid <= 0;
                    clk_count <= 0;
                    bit_index <= 0;
                    if (rx_rr == 1'b0) state <= START;
                end
                START: begin
                    if (clk_count == (CLKS_PER_BIT-1)/2) begin
                        if (rx_rr == 1'b0) begin
                            clk_count <= 0;
                            state <= DATA;
                        end else state <= IDLE;
                    end else clk_count <= clk_count + 1;
                end
                DATA: begin
                    if (clk_count == CLKS_PER_BIT-1) begin
                        clk_count <= 0;
                        data_out[bit_index] <= rx_rr;
                        if (bit_index < 7) bit_index <= bit_index + 1;
                        else state <= STOP;
                    end else clk_count <= clk_count + 1;
                end
                STOP: begin
                    if (clk_count == CLKS_PER_BIT-1) begin
                        valid <= 1;
                        state <= CLEANUP;
                    end else clk_count <= clk_count + 1;
                end
                CLEANUP: begin
                    valid <= 0;
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
