`timescale 1ns / 1ps
// Weight ROM. Vivado infers Block RAM and initializes it from a plain
// hex text file (one byte per line, e.g. "FA", "03", ...) at synthesis time.
// No IP Catalog / .coe file needed.
module weight_rom #(
    parameter DEPTH    = 36,
    parameter AW        = 6,
    parameter FILENAME = "conv1_weights.mem"
)(
    input  wire            clk,
    input  wire [AW-1:0]   addr,
    output reg  signed [7:0] dout
);
    reg signed [7:0] mem [0:DEPTH-1];

    initial begin
        $readmemh(FILENAME, mem);
    end

    always @(posedge clk) begin
        dout <= mem[addr]; // registered -> 1 clock latency
    end
endmodule
