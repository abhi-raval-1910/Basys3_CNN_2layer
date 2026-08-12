`timescale 1ns / 1ps
// =====================================================================
//  conv_engine.v  —  Streaming 3x3 convolution with line buffer + 9-MAC
// =====================================================================
//  Replaces the old sequential single-MAC engine.  Key ideas:
//
//  * Line buffer: 3-row circular buffer (INPUT_W pixels per row per
//    input channel) held in flip-flops.  As pixels stream in from the
//    input RAM in raster order, the full 3x3 window for every input
//    channel is available combinationally from registers — no RAM
//    reads are needed during the compute phase.
//
//  * 9-MAC array: nine signed 8x8 multipliers fire in parallel for
//    one (filter, input_channel) pair, plus a 9-input adder tree.
//    Vivado infers 9 DSP48E1s per instance (=> 18 total for two
//    instances, well within the 90-DSP budget of the Basys3).
//
//  * Compute flow per output pixel:
//      for each output filter f (0..OUTPUT_CH-1):
//          acc = 0
//          for each input channel c (0..INPUT_CH-1):
//              load 9 weights for (f, c) from weight ROM
//              partial = sum(window[c][k] * weight[f][c][k])  // 9 DSPs, 1 cycle
//              acc += partial
//          write ReLU(quantize(acc >> SHIFT)) to conv_out RAM
//
//  * State machine (matches the spec):
//      S_IDLE -> S_FETCH -> S_SHIFT -> S_CHECK
//              -> (if window valid) S_WLOAD -> S_MAC -> S_NEXT_CH
//                                        -> S_RELU -> S_NEXT_FILTER
//                                        -> S_NEXT_PIX -> S_FETCH
//              -> (no more pixels) S_DONE
//
//  Fully parameterized: instantiates cleanly for both conv layers.
//      Conv1: INPUT_CH=1,  OUTPUT_CH=8,  INPUT=28x28, OUTPUT=26x26
//      Conv2: INPUT_CH=8,  OUTPUT_CH=16, INPUT=13x13, OUTPUT=11x11
// =====================================================================
module conv_engine #(
    parameter INPUT_CH     = 1,     // number of input channels
    parameter OUTPUT_CH    = 8,     // number of output filters
    parameter INPUT_H      = 28,    // input image height
    parameter INPUT_W      = 28,    // input image width
    parameter OUTPUT_H     = 26,    // output height  (= INPUT_H - 2)
    parameter OUTPUT_W     = 26,    // output width   (= INPUT_W - 2)
    parameter WEIGHT_DEPTH = 72,    // OUTPUT_CH * INPUT_CH * 9
    parameter WEIGHT_AW    = 7,     // address width for weight ROM
    parameter SHIFT        = 4,     // requantization shift
    parameter IMG_AW       = 10,    // address width for input RAM
    parameter OUT_AW       = 13     // address width for output RAM
)(
    input  wire clk,
    input  wire rst,
    input  wire start,
    output reg  done,

    // Input RAM read port (1-cycle registered read)
    output reg  [IMG_AW-1:0]     img_addr,
    input  wire [7:0]            img_data,

    // Weight ROM read port (1-cycle registered read)
    output reg  [WEIGHT_AW-1:0]  w_addr,
    input  wire signed [7:0]     w_data,

    // Output RAM write port
    output reg                   co_we,
    output reg  [OUT_AW-1:0]     co_addr,
    output reg  [7:0]            co_data
);
    // -----------------------------------------------------------------
    // States
    // -----------------------------------------------------------------
    localparam S_IDLE         = 4'd0,
               S_FETCH        = 4'd1,   // issue input RAM read
               S_SHIFT        = 4'd2,   // capture pixel into line buffer
               S_CHECK        = 4'd3,   // window valid? -> compute or advance
               S_WLOAD        = 4'd4,   // stream 9 weights from ROM
               S_MAC          = 4'd5,   // 9 DSPs fire in 1 cycle
               S_NEXT_CH      = 4'd6,   // next input channel
               S_RELU         = 4'd7,   // quantize + write output
               S_NEXT_FILTER  = 4'd8,   // next output filter
               S_NEXT_PIX     = 4'd9,   // next output pixel position
               S_DONE         = 4'd10;
    reg [3:0] state;

    // -----------------------------------------------------------------
    // Counters
    // -----------------------------------------------------------------
    reg [5:0] in_y;        // 0..INPUT_H-1
    reg [5:0] in_x;        // 0..INPUT_W-1
    reg [4:0] in_c;        // 0..INPUT_CH-1     (stream loop)

    reg [5:0] oy, ox;      // 0..OUTPUT_H-1, 0..OUTPUT_W-1
    reg [4:0] f;           // 0..OUTPUT_CH-1
    reg [4:0] c;           // 0..INPUT_CH-1   (weight-load / MAC loop)
    reg [3:0] k;           // 0..9            (k=9 means "all 9 captured")

    reg signed [31:0] acc;

    // -----------------------------------------------------------------
    // Line buffer: INPUT_CH channels * 3 rows * INPUT_W cols
    //   lb[c][r][col]
    //   r=0,1,2 — three rows in a circular buffer indexed by in_y%3
    //   Vivado will pack this into flip-flops because reads are
    //   combinational and the array is small (max 8*3*13 = 312 bytes).
    // -----------------------------------------------------------------
    reg [7:0] lb [0:INPUT_CH-1][0:2][0:INPUT_W-1];

    // Weight register (9 weights for the current (f, c) pair)
    reg signed [7:0] weights [0:8];

    // -----------------------------------------------------------------
    // Line-buffer row mapping (circular buffer, 3 rows)
    //   When in_y = N, the just-written row is at lb[*][N%3][*].
    //   For an output at row oy, we need input rows oy, oy+1, oy+2.
    //   At compute time, in_y = oy+2, so:
    //     row oy   -> lb[*][(oy  )%3] = lb[*][(in_y-2)%3] = lb[*][(cur+1)%3]  (top)
    //     row oy+1 -> lb[*][(oy+1)%3] = lb[*][(in_y-1)%3] = lb[*][(cur+2)%3]  (mid)
    //     row oy+2 -> lb[*][(oy+2)%3] = lb[*][(in_y  )%3] = lb[*][(cur  )%3]  (bot)
    //   where cur = cur_wr_row = in_y % 3.
    //
    //   IMPORTANT: must compute modulo on the FULL-width in_y (6 bits).
    //   Writing `in_y[1:0] % 3` slices to 2 bits first, giving wrong
    //   results for any in_y >= 4 (e.g. in_y=4 -> in_y[1:0]=0 -> cur=0
    //   instead of 1). That bug corrupts the line buffer for rows 4+
    //   and silently breaks classification accuracy. The fix is to
    //   evaluate % 3 at the full input width, then narrow.
    // -----------------------------------------------------------------
    wire [5:0] in_y_mod3  = in_y % 6'd3;     // full-width modulo
    wire [1:0] cur_wr_row = in_y_mod3[1:0];  // safe: result is always 0/1/2
    wire [1:0] r_bot      = cur_wr_row;                              // in_y
    wire [1:0] r_mid      = (cur_wr_row == 2'd0) ? 2'd2 : (cur_wr_row - 2'd1);  // in_y-1
    wire [1:0] r_top      = (cur_wr_row == 2'd2) ? 2'd0 : (cur_wr_row + 2'd1);  // in_y-2

    // -----------------------------------------------------------------
    // 3x3 window for the current channel c (combinational reads from lb)
    //   window index k = ky*3 + kx  (ky=0..2, kx=0..2)
    // -----------------------------------------------------------------
    wire [7:0] win0 = lb[c][r_top][ox    ];
    wire [7:0] win1 = lb[c][r_top][ox + 1];
    wire [7:0] win2 = lb[c][r_top][ox + 2];
    wire [7:0] win3 = lb[c][r_mid][ox    ];
    wire [7:0] win4 = lb[c][r_mid][ox + 1];
    wire [7:0] win5 = lb[c][r_mid][ox + 2];
    wire [7:0] win6 = lb[c][r_bot][ox    ];
    wire [7:0] win7 = lb[c][r_bot][ox + 1];
    wire [7:0] win8 = lb[c][r_bot][ox + 2];

    // -----------------------------------------------------------------
    // 9 parallel signed 8x8 multipliers + adder tree
    //   Pixels are unsigned 8-bit, weights are signed 8-bit, so we
    //   zero-extend the pixels to signed 9-bit before multiplying.
    //   Vivado infers one DSP48E1 per multiply.
    // -----------------------------------------------------------------
    wire signed [16:0] m0 = $signed({1'b0, win0}) * weights[0];
    wire signed [16:0] m1 = $signed({1'b0, win1}) * weights[1];
    wire signed [16:0] m2 = $signed({1'b0, win2}) * weights[2];
    wire signed [16:0] m3 = $signed({1'b0, win3}) * weights[3];
    wire signed [16:0] m4 = $signed({1'b0, win4}) * weights[4];
    wire signed [16:0] m5 = $signed({1'b0, win5}) * weights[5];
    wire signed [16:0] m6 = $signed({1'b0, win6}) * weights[6];
    wire signed [16:0] m7 = $signed({1'b0, win7}) * weights[7];
    wire signed [16:0] m8 = $signed({1'b0, win8}) * weights[8];

    wire signed [20:0] partial = m0 + m1 + m2 + m3 + m4 + m5 + m6 + m7 + m8;

    // -----------------------------------------------------------------
    // Master FSM
    // -----------------------------------------------------------------
    integer ii;
    always @(posedge clk) begin
        if (rst) begin
            state  <= S_IDLE;
            done   <= 1'b0;
            co_we  <= 1'b0;
            in_y   <= 0;  in_x  <= 0;  in_c  <= 0;
            oy     <= 0;  ox    <= 0;  f     <= 0;  c <= 0;  k <= 0;
            acc    <= 0;
            img_addr <= 0;
            w_addr   <= 0;
            for (ii = 0; ii < 9; ii = ii + 1) weights[ii] <= 8'sd0;
        end else begin
            co_we <= 1'b0;
            case (state)
                // -----------------------------------------------------
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        in_y <= 0;  in_x <= 0;  in_c <= 0;
                        oy   <= 0;  ox   <= 0;
                        f    <= 0;  c    <= 0;  k <= 0;
                        acc  <= 0;
                        state <= S_FETCH;
                    end
                end

                // -----------------------------------------------------
                // Issue a read for the next input pixel
                //   addr = in_c * (INPUT_H*INPUT_W) + in_y * INPUT_W + in_x
                // -----------------------------------------------------
                S_FETCH: begin
                    img_addr <= in_c * (INPUT_H * INPUT_W) + in_y * INPUT_W + in_x;
                    state    <= S_SHIFT;
                end

                // -----------------------------------------------------
                // Capture pixel into the line buffer
                // -----------------------------------------------------
                S_SHIFT: begin
                    lb[in_c][cur_wr_row][in_x] <= img_data;
                    if (in_c < INPUT_CH - 1) begin
                        in_c  <= in_c + 1;
                        state <= S_FETCH;
                    end else begin
                        in_c  <= 0;
                        state <= S_CHECK;
                    end
                end

                // -----------------------------------------------------
                // Decide: window valid for output (oy=in_y-2, ox=in_x-2)?
                // -----------------------------------------------------
                S_CHECK: begin
                    if (in_y >= 2 && in_x >= 2) begin
                        oy    <= in_y - 2;
                        ox    <= in_x - 2;
                        f     <= 0;
                        c     <= 0;
                        k     <= 0;
                        acc   <= 0;
                        state <= S_WLOAD;
                    end else begin
                        // No valid window at this position — advance
                        if (in_x < INPUT_W - 1) begin
                            in_x  <= in_x + 1;
                            state <= S_FETCH;
                        end else begin
                            in_x <= 0;
                            if (in_y < INPUT_H - 1) begin
                                in_y  <= in_y + 1;
                                state <= S_FETCH;
                            end else begin
                                state <= S_DONE;
                            end
                        end
                    end
                end

                // -----------------------------------------------------
                // Stream 9 weights for the current (f, c) pair.
                //   Weight ROM has 1-cycle registered output, so we
                //   issue addr k on cycle k and capture w_data on
                //   cycle k+1.  Total: 10 cycles in S_WLOAD (k=0..9).
                // -----------------------------------------------------
                S_WLOAD: begin
                    if (k < 9) begin
                        w_addr <= f * (INPUT_CH * 9) + c * 9 + k;
                        if (k > 0) weights[k - 1] <= w_data;
                        k <= k + 1;
                    end else begin
                        weights[8] <= w_data;     // capture the last one
                        state      <= S_MAC;
                    end
                end

                // -----------------------------------------------------
                // 9 DSPs fire in 1 cycle; accumulate the partial
                // -----------------------------------------------------
                S_MAC: begin
                    acc   <= acc + partial;
                    state <= S_NEXT_CH;
                end

                // -----------------------------------------------------
                // Loop over input channels
                // -----------------------------------------------------
                S_NEXT_CH: begin
                    if (c < INPUT_CH - 1) begin
                        c     <= c + 1;
                        k     <= 0;
                        state <= S_WLOAD;
                    end else begin
                        state <= S_RELU;
                    end
                end

                // -----------------------------------------------------
                // ReLU + saturate to [0,255] + write to conv_out RAM
                //   addr = f * (OUTPUT_H*OUTPUT_W) + oy * OUTPUT_W + ox
                // -----------------------------------------------------
                S_RELU: begin
                    if (acc[31]) begin
                        co_data <= 8'd0;                       // ReLU: clip negatives
                    end else if ((acc >>> SHIFT) > 32'sd255) begin
                        co_data <= 8'd255;                     // saturate
                    end else begin
                        co_data <= (acc >>> SHIFT);            // normal
                    end
                    co_addr <= f * (OUTPUT_H * OUTPUT_W) + oy * OUTPUT_W + ox;
                    co_we   <= 1'b1;
                    state   <= S_NEXT_FILTER;
                end

                // -----------------------------------------------------
                // Loop over output filters
                // -----------------------------------------------------
                S_NEXT_FILTER: begin
                    if (f < OUTPUT_CH - 1) begin
                        f     <= f + 1;
                        c     <= 0;
                        k     <= 0;
                        acc   <= 0;
                        state <= S_WLOAD;
                    end else begin
                        state <= S_NEXT_PIX;
                    end
                end

                // -----------------------------------------------------
                // Done with all filters for this (oy, ox) — advance to
                // the next input pixel position (= next output position)
                // -----------------------------------------------------
                S_NEXT_PIX: begin
                    if (in_x < INPUT_W - 1) begin
                        in_x  <= in_x + 1;
                        state <= S_FETCH;
                    end else begin
                        in_x <= 0;
                        if (in_y < INPUT_H - 1) begin
                            in_y  <= in_y + 1;
                            state <= S_FETCH;
                        end else begin
                            state <= S_DONE;
                        end
                    end
                end

                // -----------------------------------------------------
                S_DONE: begin
                    done <= 1'b1;
                    if (!start) state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
