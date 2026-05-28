// ============================================================
// Module: conv1d_engine (ORIGINAL - 3D weight port)
// Description: Parameterized 1D Convolution Engine
//
// This is the ORIGINAL version that produced:
//   LUT=3.45%  FF=0.89%  BRAM=0%  DSP=0%  WNS=+0.435ns
//
// Weight port is 3D array [FILTERS][CHANNELS][KERNEL].
// This synthesises to register-initialised ROMs (flip-flops).
//
// Features:
//   - Configurable kernel size and filter count
//   - INT8 x INT8 MACs with INT28 accumulator
//   - Streaming sliding-window design
//   - Integrated ReLU activation
//   - 1 output per clock cycle after kernel_size latency
// ============================================================

`timescale 1ns/1ps

module conv1d_engine #(
    parameter IN_CHANNELS  = 1,
    parameter OUT_FILTERS  = 8,
    parameter KERNEL_SIZE  = 5,
    parameter DATA_W       = 8,
    parameter ACC_W        = 28,
    parameter SCALE_SHIFT  = 7
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire         enable,

    input  wire [2:0]   cfg_kernel_size,
    input  wire [4:0]   cfg_num_filters,

    input  wire         din_valid,
    input  wire signed [DATA_W-1:0] din,
    input  wire [$clog2(IN_CHANNELS):0] din_channel,

    // 3D weight port - synthesises to register ROM, BRAM=0% DSP=0%
    input  wire signed [DATA_W-1:0] weight_in [0:OUT_FILTERS-1][0:IN_CHANNELS-1][0:KERNEL_SIZE-1],
    input  wire signed [DATA_W-1:0] bias_in   [0:OUT_FILTERS-1],

    output reg          dout_valid,
    output reg signed [DATA_W-1:0] dout [0:OUT_FILTERS-1],
    output reg  [$clog2(1024):0]   dout_pos
);

    // ─────────────────────────────────────────────
    // SLIDING WINDOW BUFFER
    // ─────────────────────────────────────────────
    reg signed [DATA_W-1:0] window [0:IN_CHANNELS-1][0:KERNEL_SIZE-1];
    reg [$clog2(KERNEL_SIZE):0] window_fill;
    reg                          window_ready;
    reg [10:0] in_pos;

    integer ci, ki;

    // Window update block - does NOT touch dout_valid
    // (dout_valid is owned exclusively by the MAC block below)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            window_fill  <= 0;
            window_ready <= 0;
            in_pos       <= 0;
            for (ci = 0; ci < IN_CHANNELS; ci = ci+1)
                for (ki = 0; ki < KERNEL_SIZE; ki = ki+1)
                    window[ci][ki] <= 0;
        end else if (enable && din_valid) begin
            // Shift window backwards - non-blocking assignment safe
            for (ki = KERNEL_SIZE-1; ki > 0; ki = ki-1)
                window[din_channel][ki] <= window[din_channel][ki-1];
            window[din_channel][0] <= din;

            // Track fill on channel 0 (one position = all channels)
            if (din_channel == 0) begin
                in_pos <= in_pos + 1;
                if (window_fill < KERNEL_SIZE)
                    window_fill <= window_fill + 1;
                if (window_fill >= KERNEL_SIZE - 1)
                    window_ready <= 1;
            end
        end
    end

    // ─────────────────────────────────────────────
    // PARALLEL MAC ARRAY
    // This is the SINGLE block that drives dout_valid.
    // Default deassert at top prevents multi-driver conflict.
    // All OUT_FILTERS MACs computed in parallel each clock.
    // ─────────────────────────────────────────────
    reg signed [ACC_W-1:0] acc [0:OUT_FILTERS-1];
    reg [10:0] out_pos_mac;

    integer fi, chj, kj;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout_valid  <= 0;
            dout_pos    <= 0;
            out_pos_mac <= 0;
            for (fi = 0; fi < OUT_FILTERS; fi = fi+1) begin
                acc[fi]  <= 0;
                dout[fi] <= 0;
            end
        end else begin
            // ── Default: deassert valid every cycle ──────────
            // Single driver for dout_valid - no multi-driver conflict
            dout_valid <= 0;

            // ── MAC: fire when window full + last channel ────
            if (enable && window_ready && din_valid &&
                din_channel == IN_CHANNELS - 1) begin

                for (fi = 0; fi < OUT_FILTERS; fi = fi+1) begin
                    // Accumulate: bias + sum(window × weight) over all ch/kernel
                    acc[fi] = $signed(bias_in[fi]);
                    for (chj = 0; chj < IN_CHANNELS; chj = chj+1)
                        for (kj = 0; kj < KERNEL_SIZE; kj = kj+1)
                            acc[fi] = acc[fi] +
                                      ($signed(window[chj][kj]) *
                                       $signed(weight_in[fi][chj][kj]));

                    // Scale: divide by 2^SCALE_SHIFT (arithmetic right shift)
                    acc[fi] = acc[fi] >>> SCALE_SHIFT;

                    // ReLU activation + INT8 saturation clipping
                    if (acc[fi] <= 0)
                        dout[fi] <= 8'h00;
                    else if (acc[fi] > 8'sh7F)
                        dout[fi] <= 8'h7F;
                    else
                        dout[fi] <= acc[fi][DATA_W-1:0];
                end

                dout_valid  <= 1;
                dout_pos    <= out_pos_mac;
                out_pos_mac <= out_pos_mac + 1;
            end
        end
    end

endmodule