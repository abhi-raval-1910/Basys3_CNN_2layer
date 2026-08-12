`timescale 1ns / 1ps
// =====================================================================
//  tb_timing.v  —  Stage-by-stage timing for the 2-conv + 9-MAC design
// =====================================================================
//  Measures FPGA compute time precisely, stage by stage, by watching
//  the master FSM's state transitions in top.v.
//
//  Master FSM state values (top.v):
//     0  = M_IDLE
//     1  = M_LOAD
//     2  = M_CONV1     3  = M_CONV1_W
//     4  = M_POOL1     5  = M_POOL1_W
//     6  = M_CONV2     7  = M_CONV2_W
//     8  = M_POOL2     9  = M_POOL2_W
//    10  = M_FC       11  = M_FC_W
//    12  = M_DONE
//
//  Run this the same way you ran tb_top.v: add as a Simulation Source,
//  set as simulation top, Run Behavioral Simulation, then `run all`.
// =====================================================================
module tb_timing;
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

    always #5 clk = ~clk; // 100MHz -> 10ns period

    localparam integer BAUD = 115200;
    localparam integer BIT_TIME_NS = 1_000_000_000 / BAUD;
    localparam real CLK_PERIOD_NS = 10.0;

    task send_byte(input [7:0] data);
        integer i;
        begin
            RsRx = 0; #(BIT_TIME_NS);
            for (i = 0; i < 8; i = i + 1) begin
                RsRx = data[i];
                #(BIT_TIME_NS);
            end
            RsRx = 1; #(BIT_TIME_NS);
        end
    endtask

    // ---------------------------------------------------------------
    // Stage timestamps, captured by watching dut.mstate transitions
    // ---------------------------------------------------------------
    real t_send_start, t_send_end;      // wall time spent shifting bytes over UART
    real t_conv1_start, t_conv1_end;
    real t_pool1_start, t_pool1_end;
    real t_conv2_start, t_conv2_end;
    real t_pool2_start, t_pool2_end;
    real t_fc_start,    t_fc_end;
    real t_result_ready;

    reg [3:0] prev_state = 0;
    always @(posedge clk) begin
        if (dut.mstate != prev_state) begin
            case (dut.mstate)
                4'd2:  t_conv1_start = $realtime;                                    // entering M_CONV1
                4'd4:  begin t_conv1_end = $realtime; t_pool1_start = $realtime; end  // entering M_POOL1
                4'd6:  begin t_pool1_end = $realtime; t_conv2_start = $realtime; end  // entering M_CONV2
                4'd8:  begin t_conv2_end = $realtime; t_pool2_start = $realtime; end  // entering M_POOL2
                4'd10: begin t_pool2_end = $realtime; t_fc_start    = $realtime; end  // entering M_FC
                4'd12: begin t_fc_end    = $realtime; t_result_ready = $realtime; end // entering M_DONE
                default: ;
            endcase
            prev_state <= dut.mstate;
        end
    end

    integer p;
    initial begin
        #100;
        btnC = 1; #100; btnC = 0;
        #100;

        t_send_start = $realtime;
        for (p = 0; p < 784; p = p + 1) begin
            send_byte(p % 256); // synthetic ramp image; swap for a real image if desired
        end
        t_send_end = $realtime;

        wait (led[4] == 1'b1 || $time > 500_000_000);   // 500ms timeout

        if (led[4]) begin
            $display("");
            $display("=========================================================");
            $display(" FPGA TIMING REPORT (Vivado behavioral simulation, 100MHz)");
            $display("=========================================================");
            $display(" Predicted digit               : %0d", led[3:0]);
            $display("---------------------------------------------------------");
            $display(" UART image transfer  : %10.4f ms  (%0d bytes @ %0d baud)",
                      (t_send_end - t_send_start) / 1e6, 784, BAUD);
            $display(" Conv1 (1->8,  9-MAC)  : %10.4f ms  (%0d cycles)",
                      (t_conv1_end - t_conv1_start) / 1e6,
                      $rtoi((t_conv1_end - t_conv1_start) / CLK_PERIOD_NS));
            $display(" MaxPool1 (2x2, 8ch)   : %10.4f ms  (%0d cycles)",
                      (t_pool1_end - t_pool1_start) / 1e6,
                      $rtoi((t_pool1_end - t_pool1_start) / CLK_PERIOD_NS));
            $display(" Conv2 (8->16, 9-MAC)  : %10.4f ms  (%0d cycles)",
                      (t_conv2_end - t_conv2_start) / 1e6,
                      $rtoi((t_conv2_end - t_conv2_start) / CLK_PERIOD_NS));
            $display(" MaxPool2 (2x2, 16ch)  : %10.4f ms  (%0d cycles)",
                      (t_pool2_end - t_pool2_start) / 1e6,
                      $rtoi((t_pool2_end - t_pool2_start) / CLK_PERIOD_NS));
            $display(" FC (400->10)          : %10.4f ms  (%0d cycles)",
                      (t_fc_end - t_fc_start) / 1e6,
                      $rtoi((t_fc_end - t_fc_start) / CLK_PERIOD_NS));
            $display("---------------------------------------------------------");
            $display(" COMPUTE ONLY (conv1+pool1+conv2+pool2+fc) : %8.4f ms",
                      (t_fc_end - t_conv1_start) / 1e6);
            $display(" TOTAL (UART load + full compute)          : %8.4f ms",
                      (t_result_ready - t_send_start) / 1e6);
            $display("=========================================================");
            $display(" Compare the COMPUTE ONLY number directly against");
            $display(" benchmark_cpu.py's per-image timing on your PC.");
            $display("=========================================================");
        end else begin
            $display("FAIL/TIMEOUT: pipeline never finished");
        end

        #1000;
        $finish;
    end
endmodule
