`timescale 1ns / 1ps
// =====================================================================
//  fc_engine.v  —  Parameterized fully connected layer
// =====================================================================
//  NUM_INPUTS (default 400) -> 10 outputs (no bias).
//  Computes each of the 10 class scores sequentially (NUM_INPUTS MACs
//  each).  Now parameterized so a single source file serves the new
//  400-input FC stage directly.
// =====================================================================
module fc_engine #(
    parameter NUM_INPUTS   = 400,    // pool2 output flattened size
    parameter WEIGHT_DEPTH = 4000,   // 10 * NUM_INPUTS
    parameter WEIGHT_AW    = 12,
    parameter IN_AW        = 9        // address width of pool_out RAM
)(
    input  wire clk,
    input  wire rst,
    input  wire start,
    output reg  done,

    output reg  [IN_AW-1:0]      po_addr,    // pool_out read address (0..NUM_INPUTS-1)
    input  wire [7:0]            po_data,

    output reg  [WEIGHT_AW-1:0]  w_addr,     // fc weight ROM address
    input  wire signed [7:0]     w_data,

    output reg                   out_valid,
    output reg  [3:0]            out_idx,
    output reg  signed [31:0]    out_val
);
    localparam S_IDLE=4'd0, S_ADDR=4'd1, S_WAIT=4'd2, S_MAC=4'd3,
               S_NEXTIN=4'd4, S_STORE=4'd5, S_NEXTOUT=4'd6, S_DONE=4'd7;
    reg [3:0] state;

    reg [3:0]  o;          // 0..9
    reg [10:0] i;          // 0..NUM_INPUTS-1
    reg signed [31:0] acc;

    always @(posedge clk) begin
        if (rst) begin
            state<=S_IDLE; done<=0; o<=0; i<=0; acc<=0; out_valid<=0;
        end else begin
            out_valid <= 1'b0;
            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        o<=0; i<=0; acc<=0;
                        state <= S_ADDR;
                    end
                end

                S_ADDR: begin
                    po_addr <= i[IN_AW-1:0];
                    w_addr  <= o * NUM_INPUTS + i;
                    state   <= S_WAIT;
                end

                S_WAIT: state <= S_MAC;

                S_MAC: begin
                    acc <= acc + ($signed({1'b0, po_data}) * w_data);
                    state <= S_NEXTIN;
                end

                S_NEXTIN: begin
                    if (i == NUM_INPUTS - 1) state <= S_STORE;
                    else begin i <= i + 1; state <= S_ADDR; end
                end

                S_STORE: begin
                    out_idx   <= o;
                    out_val   <= acc;
                    out_valid <= 1'b1;
                    acc       <= 0;
                    i         <= 0;
                    state     <= S_NEXTOUT;
                end

                S_NEXTOUT: begin
                    if (o == 4'd9) state <= S_DONE;
                    else begin o <= o + 1; state <= S_ADDR; end
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
