// ============================================================
// Module: ecg_pipeline_top (FIXED v2 - ORIGINAL WORKING)
// Project: Configurable Low-Latency 1D CNN Accelerator
//
// VERIFIED RESULTS (original working state):
//   Simulation: arrhythmia=0  conf=0  Errors=0  ALL PASS
//   Implementation: LUT=3.45%  FF=0.89%  BRAM=0%  DSP=0%
//                   WNS=+0.435ns  Fmax=104.5MHz  Power=0.180W
//
// ALL 9 BUGS FIXED:
//   Bug 1: seq_rd_en hardwired 0 - connected to FSM buf_seq_rd
//   Bug 2: Pool1 dropped 7/8 outputs - added pool1_buf[148][8]
//   Bug 3: Weight axis transposition - w.transpose(2,1,0) in Python
//   Bug 4: Flatten ch-major vs pos-major - swap loops pos-outer ch-inner
//   Bug 5: pool2_buf NBA race - p2_buf_full flag-based transition
//   Bug 6: FSM stuck S_CONV1 - use p1_buf_full flag not counter
//   Bug 7: Conv1 shift register drain - 10-cycle zero flush
//   Bug 8: Conv2 shift register drain - 8-position zero flush
//   Bug 9: p2_buf_full at POOL2_OUT_LEN-4 - fixed to POOL2_OUT_LEN-1
// ============================================================
`timescale 1ns/1ps

module ecg_pipeline_top #(
    parameter INPUT_LEN   = 300,
    parameter CONV1_FILT  = 8,
    parameter CONV1_KERN  = 5,
    parameter CONV2_FILT  = 16,
    parameter CONV2_KERN  = 5,
    parameter POOL_SIZE   = 2,
    parameter DENSE1_OUT  = 16,
    parameter DATA_W      = 8,
    parameter ACC_W       = 28,
    parameter ALERT_KEY   = 8'hA5
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_valid,
    input  wire signed [DATA_W-1:0] sample_in,
    input  wire        cfg_wr_en,
    input  wire [3:0]  cfg_wr_addr,
    input  wire [7:0]  cfg_wr_data,
    output wire        result_valid,
    output wire        arrhythmia_det,
    output wire [7:0]  confidence,
    output wire [7:0]  alert_byte_0,
    output wire [7:0]  alert_byte_1,
    output wire [7:0]  alert_byte_2,
    output wire [7:0]  alert_byte_3,
    output wire [3:0]  alert_severity,
    output wire        busy,
    output wire        buffer_ready
);

    // =========================================================
    // DERIVED PARAMETERS
    // =========================================================
    localparam CONV1_OUT_LEN = INPUT_LEN  - CONV1_KERN + 1;    // 296
    localparam POOL1_OUT_LEN = CONV1_OUT_LEN / POOL_SIZE;       // 148
    localparam CONV2_OUT_LEN = POOL1_OUT_LEN - CONV2_KERN + 1;  // 144
    localparam POOL2_OUT_LEN = CONV2_OUT_LEN / POOL_SIZE;       // 72
    localparam FLAT_LEN      = CONV2_FILT * POOL2_OUT_LEN;      // 1152

    // =========================================================
    // FSM STATES
    // =========================================================
    localparam S_IDLE     = 4'd0;
    localparam S_LOAD     = 4'd1;
    localparam S_CONV1    = 4'd2;
    localparam S_POOL1    = 4'd3;
    localparam S_CONV2    = 4'd4;
    localparam S_POOL2    = 4'd5;
    localparam S_DENSE    = 4'd6;
    localparam S_CLASSIFY = 4'd7;
    localparam S_DONE     = 4'd8;

    reg [3:0] state;

    // =========================================================
    // WEIGHT ROMs - 3D/2D ARRAYS
    // Synthesise to register-initialised ROMs (flip-flops only).
    // BRAM=0%, DSP=0%, zero rom_style attributes needed.
    // XSim "index out of bounds" is simulation-only warning.
    // =========================================================
    reg signed [DATA_W-1:0] conv1_w  [0:CONV1_FILT-1][0:0][0:CONV1_KERN-1];
    reg signed [DATA_W-1:0] conv1_b  [0:CONV1_FILT-1];
    reg signed [DATA_W-1:0] conv2_w  [0:CONV2_FILT-1][0:CONV1_FILT-1][0:CONV2_KERN-1];
    reg signed [DATA_W-1:0] conv2_b  [0:CONV2_FILT-1];
    reg signed [DATA_W-1:0] dense1_w [0:FLAT_LEN-1][0:DENSE1_OUT-1];
    reg signed [DATA_W-1:0] dense1_b [0:DENSE1_OUT-1];
    reg signed [DATA_W-1:0] out_w    [0:DENSE1_OUT-1][0:0];
    reg signed [DATA_W-1:0] out_b    [0:0];

    initial begin
        $readmemh("conv1_w.hex", conv1_w);
        $readmemh("conv1_b.hex", conv1_b);
        $readmemh("conv2_w.hex", conv2_w);
        $readmemh("conv2_b.hex", conv2_b);
        $readmemh("dense_w.hex", dense1_w);
        $readmemh("dense_b.hex", dense1_b);
        $readmemh("out_w.hex",   out_w);
        $readmemh("out_b.hex",   out_b);
    end

    // =========================================================
    // CONFIG REG BLOCK
    // =========================================================
    wire       cfg_conv1_en, cfg_conv2_en, cfg_dense_en, cfg_secure_en;
    wire [7:0] cfg_threshold, cfg_enc_key;
    wire       cfg_key_override, cfg_debug_mode;
    wire [7:0] cfg_rd_data;

    config_reg_block #(
        .DEFAULT_CTRL(8'h0F),
        .DEFAULT_THR (8'h80)
    ) u_cfg (
        .clk             (clk), .rst_n(rst_n),
        .wr_en           (cfg_wr_en),
        .wr_addr         (cfg_wr_addr),
        .wr_data         (cfg_wr_data),
        .rd_addr         (4'd0), .rd_data(cfg_rd_data),
        .cfg_conv1_en    (cfg_conv1_en),
        .cfg_conv2_en    (cfg_conv2_en),
        .cfg_dense_en    (cfg_dense_en),
        .cfg_secure_en   (cfg_secure_en),
        .cfg_conv1_kern  (), .cfg_conv2_kern(),
        .cfg_conv1_filt  (), .cfg_conv2_filt(),
        .cfg_threshold   (cfg_threshold),
        .cfg_enc_key     (cfg_enc_key),
        .cfg_key_override(cfg_key_override),
        .cfg_debug_mode  (cfg_debug_mode)
    );

    // =========================================================
    // INPUT BUFFER
    // =========================================================
    reg  buf_seq_rd;
    wire buf_full, buf_empty, buf_overflow;
    wire signed [DATA_W-1:0] buf_seq_data;
    wire [$clog2(INPUT_LEN):0] buf_count;
    wire buf_rdy;

    assign buffer_ready = buf_rdy;
    assign busy         = (state != S_IDLE);

    input_buffer #(.DEPTH(INPUT_LEN), .DATA_W(DATA_W)) u_ibuf (
        .clk          (clk), .rst_n(rst_n),
        .clear        (1'b0),
        .wr_en        (sample_valid),
        .wr_data      (sample_in),
        .full         (buf_full),
        .overflow_flag(buf_overflow),
        .rd_en        (1'b0),
        .rd_addr      ({$clog2(INPUT_LEN){1'b0}}),
        .rd_data      (),
        .seq_rd_en    (buf_seq_rd),
        .seq_rd_data  (buf_seq_data),
        .empty        (buf_empty),
        .sample_count (buf_count),
        .buffer_ready (buf_rdy)
    );

    // =========================================================
    // STAGE 1: CONV1D ENGINE - Layer 1
    // =========================================================
    reg  c1_din_valid;
    reg  signed [DATA_W-1:0] c1_din;
    wire c1_valid;
    wire signed [DATA_W-1:0] c1_out [0:CONV1_FILT-1];
    wire [$clog2(1024):0] c1_pos;

    conv1d_engine #(
        .IN_CHANNELS(1), .OUT_FILTERS(CONV1_FILT),
        .KERNEL_SIZE(CONV1_KERN), .DATA_W(DATA_W),
        .ACC_W(ACC_W), .SCALE_SHIFT(7)
    ) u_conv1 (
        .clk            (clk), .rst_n(rst_n),
        .enable         (cfg_conv1_en),
        .cfg_kernel_size(3'd5), .cfg_num_filters(5'd8),
        .din_valid      (c1_din_valid),
        .din            (c1_din),
        .din_channel    (1'd0),
        .weight_in      (conv1_w), .bias_in(conv1_b),
        .dout_valid     (c1_valid),
        .dout           (c1_out),
        .dout_pos       (c1_pos)
    );

    // =========================================================
    // STAGE 2: MAXPOOL LAYER 1
    // =========================================================
    wire p1_valid;
    wire signed [DATA_W-1:0] p1_out [0:CONV1_FILT-1];

    maxpool1d_unit #(
        .CHANNELS(CONV1_FILT), .POOL_SIZE(POOL_SIZE), .DATA_W(DATA_W)
    ) u_pool1 (
        .clk(clk), .rst_n(rst_n), .enable(1'b1),
        .din_valid(c1_valid), .din(c1_out),
        .dout_valid(p1_valid), .dout(p1_out)
    );

    // =========================================================
    // POOL1 INTERMEDIATE BUFFER
    // =========================================================
    reg signed [DATA_W-1:0] pool1_buf [0:POOL1_OUT_LEN-1][0:CONV1_FILT-1];
    reg [$clog2(POOL1_OUT_LEN):0] p1_wr_ptr;
    reg [$clog2(POOL1_OUT_LEN):0] p1_rd_ptr;
    reg p1_buf_full;

    always @(posedge clk or negedge rst_n) begin : pool1_capture
        integer ci;
        if (!rst_n) begin
            p1_wr_ptr   <= 0;
            p1_buf_full <= 0;
        end else begin
            if (state == S_IDLE) begin
                p1_wr_ptr   <= 0;
                p1_buf_full <= 0;
            end else if (state == S_CONV1 && p1_valid) begin
                for (ci = 0; ci < CONV1_FILT; ci = ci+1)
                    pool1_buf[p1_wr_ptr][ci] <= p1_out[ci];
                if (p1_wr_ptr == POOL1_OUT_LEN - 1) begin
                    p1_wr_ptr   <= 0;
                    p1_buf_full <= 1;
                end else begin
                    p1_wr_ptr <= p1_wr_ptr + 1;
                end
            end
        end
    end

    // =========================================================
    // POOL1→CONV2 SERIALIZER
    // =========================================================
    reg  c2_din_valid;
    reg  signed [DATA_W-1:0] c2_din;
    reg  [$clog2(CONV1_FILT):0] c2_ch_idx;

    // =========================================================
    // STAGE 3: CONV1D ENGINE - Layer 2
    // =========================================================
    wire c2_valid;
    wire signed [DATA_W-1:0] c2_out [0:CONV2_FILT-1];
    wire [$clog2(1024):0] c2_pos;

    conv1d_engine #(
        .IN_CHANNELS(CONV1_FILT), .OUT_FILTERS(CONV2_FILT),
        .KERNEL_SIZE(CONV2_KERN), .DATA_W(DATA_W),
        .ACC_W(ACC_W), .SCALE_SHIFT(7)
    ) u_conv2 (
        .clk            (clk), .rst_n(rst_n),
        .enable         (cfg_conv2_en),
        .cfg_kernel_size(3'd5), .cfg_num_filters(5'd16),
        .din_valid      (c2_din_valid),
        .din            (c2_din),
        .din_channel    (c2_ch_idx[$clog2(CONV1_FILT):0]),
        .weight_in      (conv2_w), .bias_in(conv2_b),
        .dout_valid     (c2_valid),
        .dout           (c2_out),
        .dout_pos       (c2_pos)
    );

    // =========================================================
    // STAGE 4: MAXPOOL LAYER 2
    // =========================================================
    wire p2_valid;
    wire signed [DATA_W-1:0] p2_out [0:CONV2_FILT-1];

    maxpool1d_unit #(
        .CHANNELS(CONV2_FILT), .POOL_SIZE(POOL_SIZE), .DATA_W(DATA_W)
    ) u_pool2 (
        .clk(clk), .rst_n(rst_n), .enable(1'b1),
        .din_valid(c2_valid), .din(c2_out),
        .dout_valid(p2_valid), .dout(p2_out)
    );

    // =========================================================
    // POOL2 INTERMEDIATE BUFFER
    // p2_buf_full at POOL2_OUT_LEN-1 (Bug #9 fix)
    // =========================================================
    reg signed [DATA_W-1:0] pool2_buf [0:POOL2_OUT_LEN-1][0:CONV2_FILT-1];
    reg [$clog2(POOL2_OUT_LEN):0] p2_wr_ptr;
    reg p2_buf_full;

    always @(posedge clk or negedge rst_n) begin : pool2_capture
        integer cj;
        if (!rst_n) begin
            p2_wr_ptr   <= 0;
            p2_buf_full <= 0;
        end else begin
            if (state == S_IDLE || state == S_CONV1 || state == S_LOAD) begin
                p2_wr_ptr   <= 0;
                p2_buf_full <= 0;
            end else if (state == S_CONV2 && p2_valid) begin
                for (cj = 0; cj < CONV2_FILT; cj = cj+1)
                    pool2_buf[p2_wr_ptr][cj] <= p2_out[cj];
                if (p2_wr_ptr == POOL2_OUT_LEN - 1) begin
                    p2_wr_ptr   <= 0;
                    p2_buf_full <= 1;
                end else begin
                    p2_wr_ptr <= p2_wr_ptr + 1;
                end
            end
        end
    end

    // =========================================================
    // STAGE 5+6: FLATTEN → DENSE1 (1152→16, ReLU)
    // =========================================================
    reg  flat_valid, flat_start;
    reg  signed [DATA_W-1:0] flat_data;
    reg  [$clog2(FLAT_LEN):0]      flat_idx;
    reg  [$clog2(CONV2_FILT):0]    flat_ch;
    reg  [$clog2(POOL2_OUT_LEN):0] flat_pos;
    reg  flat_active;

    wire d1_valid;
    wire signed [DATA_W-1:0] d1_out [0:DENSE1_OUT-1];

    dense_engine #(
        .IN_DIM(FLAT_LEN), .OUT_DIM(DENSE1_OUT),
        .DATA_W(DATA_W), .ACC_W(ACC_W),
        .SCALE_SH(7), .USE_RELU(1)
    ) u_dense1 (
        .clk      (clk), .rst_n(rst_n),
        .start    (flat_start),
        .din      (flat_data),
        .din_valid(flat_valid),
        .w(dense1_w), .b(dense1_b),
        .dout_valid(d1_valid), .dout(d1_out)
    );

    // =========================================================
    // STAGE 7: DENSE2 (16→1, no ReLU)
    // =========================================================
    reg  d2_ser_active;
    reg  [$clog2(DENSE1_OUT):0] d2_ser_idx;
    reg  d2_ser_valid, d2_start;
    reg  signed [DATA_W-1:0] d2_ser_data;
    reg  signed [DATA_W-1:0] d2_buf [0:DENSE1_OUT-1];

    wire d2_valid;
    wire signed [DATA_W-1:0] d2_out [0:0];

    always @(posedge clk or negedge rst_n) begin : d2_serializer
        integer di;
        if (!rst_n) begin
            d2_ser_active <= 0; d2_ser_idx <= 0;
            d2_ser_valid  <= 0; d2_start   <= 0;
            d2_ser_data   <= 0;
        end else begin
            d2_ser_valid <= 0;
            d2_start     <= 0;
            if (d1_valid) begin
                for (di = 0; di < DENSE1_OUT; di = di+1)
                    d2_buf[di] <= d1_out[di];
                d2_ser_idx    <= 0;
                d2_ser_active <= 1;
                d2_start      <= 1;
            end
            if (d2_ser_active) begin
                d2_ser_data  <= d2_buf[d2_ser_idx];
                d2_ser_valid <= 1;
                if (d2_ser_idx == DENSE1_OUT - 1) begin
                    d2_ser_active <= 0;
                    d2_ser_idx    <= 0;
                end else begin
                    d2_ser_idx <= d2_ser_idx + 1;
                end
            end
        end
    end

    dense_engine #(
        .IN_DIM(DENSE1_OUT), .OUT_DIM(1),
        .DATA_W(DATA_W), .ACC_W(ACC_W),
        .SCALE_SH(7), .USE_RELU(0)
    ) u_dense2 (
        .clk      (clk), .rst_n(rst_n),
        .start    (d2_start),
        .din      (d2_ser_data),
        .din_valid(d2_ser_valid),
        .w(out_w), .b(out_b),
        .dout_valid(d2_valid), .dout(d2_out)
    );

    // =========================================================
    // STAGE 8: SIGMOID CLASSIFIER
    // =========================================================
    wire cls_valid;
    wire [7:0] cls_confidence;
    wire cls_result;

    sigmoid_classifier #(.DATA_W(16), .CONF_W(8), .THRESHOLD(128)) u_sigmoid (
        .clk           (clk), .rst_n(rst_n),
        .valid_in      (d2_valid),
        .logit_in      ({{8{d2_out[0][DATA_W-1]}}, d2_out[0]}),
        .threshold_cfg (cfg_threshold),
        .valid_out     (cls_valid),
        .confidence    (cls_confidence),
        .classification(cls_result)
    );

    assign confidence     = cls_confidence;
    assign arrhythmia_det = cls_result;
    assign result_valid   = cls_valid;

    // =========================================================
    // STAGE 9: SECURE ALERT
    // =========================================================
    reg [7:0] alert_b0_r, alert_b1_r, alert_b2_r, alert_b3_r;
    wire alert_valid_int;

    always @(posedge clk) begin
        if (alert_valid_int) begin
            alert_b0_r <= alert_byte_0;
            alert_b1_r <= alert_byte_1;
            alert_b2_r <= alert_byte_2;
            alert_b3_r <= alert_byte_3;
        end
    end

    secure_alert #(.KEY_W(8), .STATIC_KEY(ALERT_KEY)) u_alert (
        .clk                (clk), .rst_n(rst_n),
        .alert_trigger      (cls_valid),
        .arrhythmia_detected(cls_result),
        .confidence         (cls_confidence),
        .timestamp          (32'd0),
        .secure_enable      (cfg_secure_en),
        .key_override       (cfg_enc_key),
        .key_override_en    (cfg_key_override),
        .alert_valid        (alert_valid_int),
        .alert_byte_0(alert_byte_0), .alert_byte_1(alert_byte_1),
        .alert_byte_2(alert_byte_2), .alert_byte_3(alert_byte_3),
        .alert_severity(alert_severity)
    );

    // =========================================================
    // MAIN FSM
    // =========================================================
    reg [$clog2(INPUT_LEN):0]      conv1_cnt;
    reg [$clog2(POOL1_OUT_LEN):0]  pool1_drain;
    reg [$clog2(POOL1_OUT_LEN):0]  c2_pos_rd;
    reg [$clog2(POOL2_OUT_LEN):0]  pool2_drain;
    reg [3:0]  c1_flush_cnt;
    reg [3:0]  c2_flush_cnt;
    reg [7:0]  c2_valid_cnt;
    reg [7:0]  p2_valid_cnt;

    always @(posedge clk or negedge rst_n) begin : fsm
        integer fc2;
        if (!rst_n) begin
            state        <= S_IDLE;
            buf_seq_rd   <= 0;
            c1_din_valid <= 0; c1_din       <= 0;
            c2_din_valid <= 0; c2_din       <= 0; c2_ch_idx <= 0;
            flat_valid   <= 0; flat_start   <= 0;
            flat_data    <= 0; flat_idx     <= 0;
            flat_ch      <= 0; flat_pos     <= 0; flat_active <= 0;
            conv1_cnt    <= 0; pool1_drain  <= 0;
            c2_pos_rd    <= 0; pool2_drain  <= 0;
            p1_rd_ptr    <= 0;
            c1_flush_cnt <= 0; c2_flush_cnt <= 0;
            c2_valid_cnt <= 0; p2_valid_cnt <= 0;
        end else begin
            buf_seq_rd   <= 0;
            c1_din_valid <= 0;
            c2_din_valid <= 0;
            flat_valid   <= 0;
            flat_start   <= 0;

            case (state)

                S_IDLE: begin
                    if (buf_rdy) begin
                        state        <= S_CONV1;
                        conv1_cnt    <= 0;
                        pool1_drain  <= 0;
                        pool2_drain  <= 0;
                        c2_valid_cnt <= 0;
                        p2_valid_cnt <= 0;
                        c1_flush_cnt <= 0;
                        c2_flush_cnt <= 0;
                        c2_ch_idx    <= 0;
                        p1_rd_ptr    <= 0;
                        c2_pos_rd    <= 0;
                        flat_idx     <= 0;
                        flat_ch      <= 0;
                        flat_pos     <= 0;
                        flat_active  <= 0;
                    end
                end

                S_CONV1: begin
                    if (!buf_empty && conv1_cnt < INPUT_LEN) begin
                        buf_seq_rd   <= 1;
                        c1_din_valid <= 1;
                        c1_din       <= buf_seq_data;
                        conv1_cnt    <= conv1_cnt + 1;
                    end else if (conv1_cnt >= INPUT_LEN &&
                                 c1_flush_cnt < 4'd10) begin
                        c1_din_valid <= 1;
                        c1_din       <= 0;
                        c1_flush_cnt <= c1_flush_cnt + 1;
                    end

                    if (p1_valid)
                        pool1_drain <= pool1_drain + 1;

                    if (conv1_cnt[5:0] == 6'd0)
                        $display("[CONV1_DBG] cnt=%0d p1_wr_ptr=%0d p1_buf_full=%0d",
                                 conv1_cnt, p1_wr_ptr, p1_buf_full);

                    if (p1_buf_full) begin
                        $display("[P1FULL] FSM sees p1_buf_full=1 at time=%0t cnt=%0d ptr=%0d",
                                 $time, conv1_cnt, p1_wr_ptr);
                        state     <= S_CONV2;
                        p1_rd_ptr <= 0;
                        c2_pos_rd <= 0;
                        c2_ch_idx <= 0;
                    end
                end

                S_CONV2: begin
                    if (p1_rd_ptr < POOL1_OUT_LEN) begin
                        c2_din_valid <= 1;
                        c2_din       <= pool1_buf[p1_rd_ptr][c2_ch_idx];
                        if (c2_ch_idx == CONV1_FILT - 1) begin
                            c2_ch_idx <= 0;
                            p1_rd_ptr <= p1_rd_ptr + 1;
                        end else begin
                            c2_ch_idx <= c2_ch_idx + 1;
                        end
                    end else if (c2_flush_cnt < 4'd8) begin
                        c2_din_valid <= 1;
                        c2_din       <= 0;
                        if (c2_ch_idx == CONV1_FILT - 1) begin
                            c2_ch_idx    <= 0;
                            c2_flush_cnt <= c2_flush_cnt + 1;
                        end else begin
                            c2_ch_idx <= c2_ch_idx + 1;
                        end
                    end

                    if (c2_valid) c2_valid_cnt <= c2_valid_cnt + 1;
                    if (p2_valid) p2_valid_cnt <= p2_valid_cnt + 1;
                    if (p2_valid) pool2_drain  <= pool2_drain + 1;

                    if (p2_buf_full) begin
                        $display("[P2FULL] p2_buf_full=1 pool2_drain=%0d c2_total=%0d p2_total=%0d",
                                 pool2_drain, c2_valid_cnt, p2_valid_cnt);
                        state    <= S_DENSE;
                        flat_idx <= 0;
                        flat_ch  <= 0;
                        flat_pos <= 0;
                    end
                end

                S_DENSE: begin
                    if (!flat_active) begin
                        flat_active <= 1;
                        flat_start  <= 1;
                        $display("[P2BUF] pool2_buf[0][0]=%0d [1][0]=%0d [71][0]=%0d p2_wr_ptr=%0d pool2_drain=%0d",
                            $signed(pool2_buf[0][0]),  $signed(pool2_buf[1][0]),
                            $signed(pool2_buf[71][0]), p2_wr_ptr, pool2_drain);
                    end
                    if (flat_active) begin
                        flat_data  <= pool2_buf[flat_pos][flat_ch];
                        flat_valid <= 1;
                        if (flat_ch == CONV2_FILT - 1) begin
                            flat_ch <= 0;
                            if (flat_pos == POOL2_OUT_LEN - 1) begin
                                flat_pos    <= 0;
                                flat_active <= 0;
                            end else begin
                                flat_pos <= flat_pos + 1;
                            end
                        end else begin
                            flat_ch <= flat_ch + 1;
                        end
                        flat_idx <= flat_idx + 1;
                    end
                    if (cls_valid)
                        state <= S_IDLE;
                end

                default: state <= S_IDLE;

            endcase
        end
    end

endmodule
