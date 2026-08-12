`timescale 1ns / 1ps
module argmax10 (
    input wire signed [31:0] v0, v1, v2, v3, v4, v5, v6, v7, v8, v9,
    output reg [3:0] best_idx
);
    always @(*) begin
        best_idx = 0;
        if (v1 > v0 && v1>=v2 && v1>=v3 && v1>=v4 && v1>=v5 && v1>=v6 && v1>=v7 && v1>=v8 && v1>=v9) best_idx = 1;
        else if (v2 > v0 && v2>v1 && v2>=v3 && v2>=v4 && v2>=v5 && v2>=v6 && v2>=v7 && v2>=v8 && v2>=v9) best_idx = 2;
        else if (v3 > v0 && v3>v1 && v3>v2 && v3>=v4 && v3>=v5 && v3>=v6 && v3>=v7 && v3>=v8 && v3>=v9) best_idx = 3;
        else if (v4 > v0 && v4>v1 && v4>v2 && v4>v3 && v4>=v5 && v4>=v6 && v4>=v7 && v4>=v8 && v4>=v9) best_idx = 4;
        else if (v5 > v0 && v5>v1 && v5>v2 && v5>v3 && v5>v4 && v5>=v6 && v5>=v7 && v5>=v8 && v5>=v9) best_idx = 5;
        else if (v6 > v0 && v6>v1 && v6>v2 && v6>v3 && v6>v4 && v6>v5 && v6>=v7 && v6>=v8 && v6>=v9) best_idx = 6;
        else if (v7 > v0 && v7>v1 && v7>v2 && v7>v3 && v7>v4 && v7>v5 && v7>v6 && v7>=v8 && v7>=v9) best_idx = 7;
        else if (v8 > v0 && v8>v1 && v8>v2 && v8>v3 && v8>v4 && v8>v5 && v8>v6 && v8>v7 && v8>=v9) best_idx = 8;
        else if (v9 > v0 && v9>v1 && v9>v2 && v9>v3 && v9>v4 && v9>v5 && v9>v6 && v9>v7 && v9>v8) best_idx = 9;
        else best_idx = 0; // default / tie -> 0
    end
endmodule
