`timescale 1ns / 1ps
// Drives the Basys 3's 4-digit 7-segment display, showing digit_in (0-9)
// on the rightmost digit and blanking the other three.
module display_7seg (
    input  wire       clk,
    input  wire [3:0] digit_in,
    output reg  [3:0] an,
    output reg  [6:0] seg
);
    // Basys 3 anodes are active-LOW, segments are active-LOW.
    always @(*) begin
        an = 4'b1110; // enable only the rightmost digit
        case (digit_in)
            4'd0: seg = 7'b1000000;
            4'd1: seg = 7'b1111001;
            4'd2: seg = 7'b0100100;
            4'd3: seg = 7'b0110000;
            4'd4: seg = 7'b0011001;
            4'd5: seg = 7'b0010010;
            4'd6: seg = 7'b0000010;
            4'd7: seg = 7'b1111000;
            4'd8: seg = 7'b0000000;
            4'd9: seg = 7'b0010000;
            default: seg = 7'b1111111; // blank
        endcase
    end
endmodule
