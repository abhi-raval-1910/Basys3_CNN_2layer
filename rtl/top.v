`timescale 1ns / 1ps
// =====================================================================
//  top.v  —  Basys3 CNN digit classifier (2-conv + parallel 9-MAC)
// =====================================================================
//  Architecture:
//    Conv1(1->8, 3x3) -> ReLU -> MaxPool(2x2)
//    -> Conv2(8->16, 3x3) -> ReLU -> MaxPool(2x2)
//    -> FC(400->10) -> Argmax -> 7-seg
//
//  Shapes:
//    28x28 -> 26x26x8 -> 13x13x8 -> 11x11x16 -> 5x5x16(=400) -> 10
//
//  Master FSM:
//    M_LOAD -> M_CONV1 -> M_CONV1_W
//           -> M_POOL1 -> M_POOL1_W
//           -> M_CONV2 -> M_CONV2_W
//           -> M_POOL2 -> M_POOL2_W
//           -> M_FC    -> M_FC_W
//           -> M_DONE
//
//  LED assignments:
//    led[3:0]  = predicted digit
//    led[4]    = result_ready
//    led[5]    = loading_done
//    led[15:6] = img_wr_addr (debug: watch pixels arrive)
// =====================================================================
module top (
    input  wire        clk,      // 100MHz onboard clock (W5)
    input  wire        btnC,     // center button = reset
    input  wire        RsRx,     // UART RX from micro-USB (B18)
    output wire [3:0]  an,
    output wire [6:0]  seg,
    output wire [15:0] led
);
    wire rst = btnC;

    // ---------------------------------------------------------------
    // UART receiver
    // ---------------------------------------------------------------
    wire [7:0] rx_data;
    wire       rx_valid;
    uart_rx uart_inst (
        .clk(clk), .rst(rst), .rx(RsRx),
        .data_out(rx_data), .valid(rx_valid)
    );

    // ---------------------------------------------------------------
    // Image RAM write-address counter (0..783) + auto-restart logic
    // ---------------------------------------------------------------
    reg [9:0] img_wr_addr = 0;
    reg       loading_done = 0;

    wire new_image_byte = rx_valid && (mstate == M_DONE);
    wire [9:0] img_waddr_eff = new_image_byte ? 10'd0 : img_wr_addr;
    wire       img_we        = rx_valid && (mstate == M_LOAD || mstate == M_DONE);

    always @(posedge clk) begin
        if (rst) begin
            img_wr_addr  <= 0;
            loading_done <= 0;
        end else if (new_image_byte) begin
            img_wr_addr  <= 1;   // byte 0 just written this cycle
            loading_done <= 0;
        end else if (rx_valid && !loading_done) begin
            if (img_wr_addr == 10'd783) begin
                loading_done <= 1;
            end else begin
                img_wr_addr <= img_wr_addr + 1;
            end
        end
    end

    // ---------------------------------------------------------------
    // Image RAM (784 x 8) — unchanged
    // ---------------------------------------------------------------
    wire [9:0] img_rd_addr;
    wire [7:0] img_rd_data;
    dp_ram #(.DEPTH(784), .AW(10)) image_ram (
        .clk(clk),
        .we(img_we), .waddr(img_waddr_eff), .wdata(rx_data),
        .raddr(img_rd_addr), .rdata(img_rd_data)
    );

    // ---------------------------------------------------------------
    // Conv1 weight ROM (72 x 8) — 8 filters * 1 channel * 9
    // ---------------------------------------------------------------
    wire [6:0] c1_w_addr;
    wire signed [7:0] c1_w_data;
    weight_rom #(.DEPTH(72), .AW(7), .FILENAME("conv1_weights.mem")) conv1_rom (
        .clk(clk), .addr(c1_w_addr), .dout(c1_w_data)
    );

    // ---------------------------------------------------------------
    // Conv1-out RAM (5408 x 8) = 8 filters * 26 * 26
    // ---------------------------------------------------------------
    wire         c1_co_we;
    wire [12:0]  c1_co_wr_addr;
    wire [7:0]   c1_co_wr_data;
    wire [12:0]  c1_co_rd_addr;
    wire [7:0]   c1_co_rd_data;
    dp_ram #(.DEPTH(5408), .AW(13)) conv1_out_ram (
        .clk(clk),
        .we(c1_co_we), .waddr(c1_co_wr_addr), .wdata(c1_co_wr_data),
        .raddr(c1_co_rd_addr), .rdata(c1_co_rd_data)
    );

    // ---------------------------------------------------------------
    // Pool1-out RAM (1352 x 8) = 8 channels * 13 * 13
    // ---------------------------------------------------------------
    wire         p1_po_we;
    wire [10:0]  p1_po_wr_addr;
    wire [7:0]   p1_po_wr_data;
    wire [10:0]  p1_po_rd_addr;
    wire [7:0]   p1_po_rd_data;
    dp_ram #(.DEPTH(1352), .AW(11)) pool1_out_ram (
        .clk(clk),
        .we(p1_po_we), .waddr(p1_po_wr_addr), .wdata(p1_po_wr_data),
        .raddr(p1_po_rd_addr), .rdata(p1_po_rd_data)
    );

    // ---------------------------------------------------------------
    // Conv2 weight ROM (1152 x 8) = 16 filters * 8 channels * 9
    // ---------------------------------------------------------------
    wire [10:0] c2_w_addr;
    wire signed [7:0] c2_w_data;
    weight_rom #(.DEPTH(1152), .AW(11), .FILENAME("conv2_weights.mem")) conv2_rom (
        .clk(clk), .addr(c2_w_addr), .dout(c2_w_data)
    );

    // ---------------------------------------------------------------
    // Conv2-out RAM (1936 x 8) = 16 filters * 11 * 11
    // ---------------------------------------------------------------
    wire         c2_co_we;
    wire [10:0]  c2_co_wr_addr;
    wire [7:0]   c2_co_wr_data;
    wire [10:0]  c2_co_rd_addr;
    wire [7:0]   c2_co_rd_data;
    dp_ram #(.DEPTH(1936), .AW(11)) conv2_out_ram (
        .clk(clk),
        .we(c2_co_we), .waddr(c2_co_wr_addr), .wdata(c2_co_wr_data),
        .raddr(c2_co_rd_addr), .rdata(c2_co_rd_data)
    );

    // ---------------------------------------------------------------
    // Pool2-out RAM (400 x 8) = 16 channels * 5 * 5
    // ---------------------------------------------------------------
    wire         p2_po_we;
    wire [8:0]   p2_po_wr_addr;
    wire [7:0]   p2_po_wr_data;
    wire [8:0]   p2_po_rd_addr;
    wire [7:0]   p2_po_rd_data;
    dp_ram #(.DEPTH(400), .AW(9)) pool2_out_ram (
        .clk(clk),
        .we(p2_po_we), .waddr(p2_po_wr_addr), .wdata(p2_po_wr_data),
        .raddr(p2_po_rd_addr), .rdata(p2_po_rd_data)
    );

    // ---------------------------------------------------------------
    // FC weight ROM (4000 x 8) = 10 outputs * 400 inputs
    // ---------------------------------------------------------------
    wire [11:0] fc_w_addr;
    wire signed [7:0] fc_w_data;
    weight_rom #(.DEPTH(4000), .AW(12), .FILENAME("fc_weights.mem")) fc_rom (
        .clk(clk), .addr(fc_w_addr), .dout(fc_w_data)
    );

    // ---------------------------------------------------------------
    // Compute engines
    // ---------------------------------------------------------------
    reg  conv1_start, pool1_start, conv2_start, pool2_start, fc_start;
    wire conv1_done,  pool1_done,  conv2_done,  pool2_done,  fc_done;

    // Conv1: 1->8, 28x28 -> 26x26
    // SHIFT=9 chosen empirically from the trained weight scales so that
    // RTL conv1 outputs stay in [0,255] without saturating. Verified to
    // give 100% accuracy on 100 MNIST test images against the PyTorch
    // float baseline (see python/ reference check).
    conv_engine #(
        .INPUT_CH(1),  .OUTPUT_CH(8),
        .INPUT_H(28),  .INPUT_W(28),
        .OUTPUT_H(26), .OUTPUT_W(26),
        .WEIGHT_DEPTH(72),  .WEIGHT_AW(7),
        .SHIFT(9),
        .IMG_AW(10), .OUT_AW(13)
    ) u_conv1 (
        .clk(clk), .rst(rst), .start(conv1_start), .done(conv1_done),
        .img_addr(img_rd_addr), .img_data(img_rd_data),
        .w_addr(c1_w_addr),     .w_data(c1_w_data),
        .co_we(c1_co_we), .co_addr(c1_co_wr_addr), .co_data(c1_co_wr_data)
    );

    // Pool1: 8 channels, 26x26 -> 13x13
    pool_engine #(
        .INPUT_CH(8),  .INPUT_H(26), .INPUT_W(26),
        .OUTPUT_H(13), .OUTPUT_W(13),
        .IN_AW(13), .OUT_AW(11)
    ) u_pool1 (
        .clk(clk), .rst(rst), .start(pool1_start), .done(pool1_done),
        .co_addr(c1_co_rd_addr), .co_data(c1_co_rd_data),
        .po_we(p1_po_we), .po_addr(p1_po_wr_addr), .po_data(p1_po_wr_data)
    );

    // Conv2: 8->16, 13x13 -> 11x11
    // SHIFT=8 chosen empirically (see conv1 comment above).
    conv_engine #(
        .INPUT_CH(8),  .OUTPUT_CH(16),
        .INPUT_H(13),  .INPUT_W(13),
        .OUTPUT_H(11), .OUTPUT_W(11),
        .WEIGHT_DEPTH(1152), .WEIGHT_AW(11),
        .SHIFT(8),
        .IMG_AW(11), .OUT_AW(11)
    ) u_conv2 (
        .clk(clk), .rst(rst), .start(conv2_start), .done(conv2_done),
        .img_addr(p1_po_rd_addr), .img_data(p1_po_rd_data),
        .w_addr(c2_w_addr),       .w_data(c2_w_data),
        .co_we(c2_co_we), .co_addr(c2_co_wr_addr), .co_data(c2_co_wr_data)
    );

    // Pool2: 16 channels, 11x11 -> 5x5
    pool_engine #(
        .INPUT_CH(16), .INPUT_H(11), .INPUT_W(11),
        .OUTPUT_H(5),  .OUTPUT_W(5),
        .IN_AW(11), .OUT_AW(9)
    ) u_pool2 (
        .clk(clk), .rst(rst), .start(pool2_start), .done(pool2_done),
        .co_addr(c2_co_rd_addr), .co_data(c2_co_rd_data),
        .po_we(p2_po_we), .po_addr(p2_po_wr_addr), .po_data(p2_po_wr_data)
    );

    // FC: 400 -> 10
    wire        fc_out_valid;
    wire [3:0]  fc_out_idx;
    wire signed [31:0] fc_out_val;

    fc_engine #(
        .NUM_INPUTS(400), .WEIGHT_DEPTH(4000), .WEIGHT_AW(12), .IN_AW(9)
    ) u_fc (
        .clk(clk), .rst(rst), .start(fc_start), .done(fc_done),
        .po_addr(p2_po_rd_addr), .po_data(p2_po_rd_data),
        .w_addr(fc_w_addr), .w_data(fc_w_data),
        .out_valid(fc_out_valid), .out_idx(fc_out_idx), .out_val(fc_out_val)
    );

    // Latch the 10 class scores as they stream out of fc_engine
    reg signed [31:0] scores [0:9];
    integer k;
    always @(posedge clk) begin
        if (rst) begin
            for (k = 0; k < 10; k = k + 1) scores[k] <= 0;
        end else if (fc_out_valid) begin
            scores[fc_out_idx] <= fc_out_val;
        end
    end

    wire [3:0] predicted_digit;
    argmax10 u_argmax (
        .clk(clk), .rst(rst),   
        .v0(scores[0]), .v1(scores[1]), .v2(scores[2]), .v3(scores[3]), .v4(scores[4]),
        .v5(scores[5]), .v6(scores[6]), .v7(scores[7]), .v8(scores[8]), .v9(scores[9]),
        .best_idx(predicted_digit)
    );

    // ---------------------------------------------------------------
    // Master FSM
    //   M_LOAD -> M_CONV1 -> M_CONV1_W
    //          -> M_POOL1 -> M_POOL1_W
    //          -> M_CONV2 -> M_CONV2_W
    //          -> M_POOL2 -> M_POOL2_W
    //          -> M_FC    -> M_FC_W
    //          -> M_DONE
    // ---------------------------------------------------------------
    localparam M_IDLE     = 4'd0,
               M_LOAD     = 4'd1,
               M_CONV1    = 4'd2,
               M_CONV1_W  = 4'd3,
               M_POOL1    = 4'd4,
               M_POOL1_W  = 4'd5,
               M_CONV2    = 4'd6,
               M_CONV2_W  = 4'd7,
               M_POOL2    = 4'd8,
               M_POOL2_W  = 4'd9,
               M_FC       = 4'd10,
               M_FC_W     = 4'd11,
               M_WAIT_ARGMAX = 4'd12,
               M_DONE        = 4'd13;
    reg [3:0] mstate;
    reg [3:0] latched_digit;
    reg       result_ready;
    reg [1:0] argmax_cnt;

    always @(posedge clk) begin
        if (rst) begin
            mstate <= M_LOAD;
            conv1_start <= 0; pool1_start <= 0;
            conv2_start <= 0; pool2_start <= 0;
            fc_start    <= 0;
            latched_digit <= 0; result_ready <= 0;
            argmax_cnt <= 0;
        end else begin
            case (mstate)
                M_LOAD: begin
                    result_ready <= 0;
                    if (loading_done) mstate <= M_CONV1;
                end
                M_CONV1: begin
                    conv1_start <= 1;
                    mstate <= M_CONV1_W;
                end
                M_CONV1_W: begin
                    if (conv1_done) begin
                        conv1_start <= 0;
                        mstate <= M_POOL1;
                    end
                end
                M_POOL1: begin
                    pool1_start <= 1;
                    mstate <= M_POOL1_W;
                end
                M_POOL1_W: begin
                    if (pool1_done) begin
                        pool1_start <= 0;
                        mstate <= M_CONV2;
                    end
                end
                M_CONV2: begin
                    conv2_start <= 1;
                    mstate <= M_CONV2_W;
                end
                M_CONV2_W: begin
                    if (conv2_done) begin
                        conv2_start <= 0;
                        mstate <= M_POOL2;
                    end
                end
                M_POOL2: begin
                    pool2_start <= 1;
                    mstate <= M_POOL2_W;
                end
                M_POOL2_W: begin
                    if (pool2_done) begin
                        pool2_start <= 0;
                        mstate <= M_FC;
                    end
                end
                M_FC: begin
                    fc_start <= 1;
                    mstate <= M_FC_W;
                end
                M_FC_W: begin
                    if (fc_done) begin
                        fc_start   <= 0;
                        argmax_cnt <= 0;
                        mstate     <= M_WAIT_ARGMAX;
                    end
                end
                M_WAIT_ARGMAX: begin
                    if (argmax_cnt == 2'd3) begin
                        mstate <= M_DONE;
                    end else begin
                        argmax_cnt <= argmax_cnt + 1'b1;
                    end
                end 
                M_DONE: begin
                    latched_digit <= predicted_digit;
                    result_ready  <= 1;
                    // Auto-restart: first byte of a new image drops
                    // us back into M_LOAD (img_wr_addr/loading_done
                    // are reset in the UART block above).
                    if (rx_valid) begin
                        mstate       <= M_LOAD;
                        result_ready <= 0;
                    end
                end
                default: mstate <= M_LOAD;
            endcase
        end
    end

    // ---------------------------------------------------------------
    // Output
    // ---------------------------------------------------------------
    display_7seg u_disp (.clk(clk), .digit_in(latched_digit), .an(an), .seg(seg));

    assign led[3:0]   = latched_digit;
    assign led[4]     = result_ready;
    assign led[5]     = loading_done;
    assign led[15:6]  = img_wr_addr[9:0];   // debug: watch pixels arrive

endmodule
