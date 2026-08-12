`timescale 1ns / 1ps
// Generic synchronous RAM. Vivado infers this straight into Block RAM.
// One write port, one read port (registered output -> 1 cycle read latency).
module dp_ram #(
    parameter DEPTH = 784,
    parameter AW     = 10   // must satisfy 2^AW >= DEPTH
)(
    input  wire            clk,
    input  wire            we,
    input  wire [AW-1:0]   waddr,
    input  wire [7:0]      wdata,
    input  wire [AW-1:0]   raddr,
    output reg  [7:0]      rdata
);
    reg [7:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata <= mem[raddr]; // registered read -> 1 clock latency
    end
endmodule
