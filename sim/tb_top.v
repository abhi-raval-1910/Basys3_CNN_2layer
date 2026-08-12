`timescale 1ns / 1ps
// =====================================================================
//  tb_top.v  —  Basic testbench for the upgraded 2-conv + 9-MAC design
// =====================================================================
//  Generates a 100MHz clock, releases reset, then bit-bangs 784 UART
//  bytes (a synthetic ramp image) into RsRx at 115200 baud and waits
//  for the master FSM to finish, then prints the predicted digit.
//
//  You must have conv1_weights.mem, conv2_weights.mem, and
//  fc_weights.mem in the simulation working directory before running
//  this (they live in rtl/ — see python/quantize_export.py).
// =====================================================================
module tb_top;
    reg clk = 0;
    reg btnC = 1;
    reg RsRx = 1;
    wire [3:0] an;
    wire [6:0] seg;
    wire [15:0] led;

    top dut (
        .clk(clk), .btnC(btnC), .RsRx(RsRx),
        .an(an), .seg(seg), .led(led)
    );

    always #5 clk = ~clk; // 100MHz

    localparam integer BAUD = 115200;
    localparam integer BIT_TIME_NS = 1_000_000_000 / BAUD;

    task send_byte(input [7:0] data);
        integer i;
        begin
            RsRx = 0; #(BIT_TIME_NS);              // start bit
            for (i = 0; i < 8; i = i + 1) begin
                RsRx = data[i];
                #(BIT_TIME_NS);
            end
            RsRx = 1; #(BIT_TIME_NS);               // stop bit
        end
    endtask

    integer p;
    initial begin
        #100;
        btnC = 1; #100; btnC = 0;   // release reset
        #100;

        // send a synthetic 28x28 ramp image
        for (p = 0; p < 784; p = p + 1) begin
            send_byte(p % 256);
        end

        // Sending 784 bytes at 115200 baud takes ~68ms by itself.
        // The compute pipeline (conv1 + pool1 + conv2 + pool2 + fc) runs
        // for hundreds of thousands of cycles at 100MHz, so allow up to
        // 500ms wall time before declaring a timeout.
        wait (led[4] == 1'b1 || $time > 500_000_000); // 500ms timeout

        if (led[4])
            $display("PASS: predicted digit = %0d at time %0t", led[3:0], $time);
        else
            $display("FAIL/TIMEOUT: pipeline never finished");

        #1000;
        $finish;
    end
endmodule
