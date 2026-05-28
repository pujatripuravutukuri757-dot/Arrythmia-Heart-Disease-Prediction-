// ============================================================
// Module: dense_engine (ORIGINAL - 2D weight port)
// Description: Fully Connected (Dense) Layer Engine
//
// This is the ORIGINAL version that produced:
//   LUT=3.45%  FF=0.89%  BRAM=0%  DSP=0%  WNS=+0.435ns
//
// Weight port is 2D array [IN_DIM][OUT_DIM].
// This synthesises to register-initialised ROMs (flip-flops).
// No BRAM inference, no DSP multiplication for addressing.
//
// Features:
//   - Parameterized input/output size
//   - INT8 weights, INT28 accumulator
//   - Sequential MAC (1 input per clock, all outputs parallel)
//   - ReLU activation (configurable, USE_RELU=0 for output layer)
// ============================================================

`timescale 1ns/1ps

module dense_engine #(
    parameter IN_DIM    = 1152,
    parameter OUT_DIM   = 16,
    parameter DATA_W    = 8,
    parameter ACC_W     = 28,
    parameter SCALE_SH  = 7,
    parameter USE_RELU  = 1
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,

    input  wire signed [DATA_W-1:0] din,
    input  wire                     din_valid,

    // 2D weight array - synthesises to flip-flop ROM, BRAM=0%, DSP=0%
    input  wire signed [DATA_W-1:0] w [0:IN_DIM-1][0:OUT_DIM-1],
    input  wire signed [DATA_W-1:0] b [0:OUT_DIM-1],

    output reg          dout_valid,
    output reg signed [DATA_W-1:0] dout [0:OUT_DIM-1]
);

    localparam ST_IDLE    = 2'd0;
    localparam ST_COMPUTE = 2'd1;
    localparam ST_STORE   = 2'd2;

    reg [1:0]              state;
    reg signed [ACC_W-1:0] acc [0:OUT_DIM-1];
    reg [$clog2(IN_DIM):0] in_idx;

    integer oi;
    reg signed [ACC_W-1:0] scaled;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= ST_IDLE;
            in_idx     <= 0;
            dout_valid <= 0;
            for (oi = 0; oi < OUT_DIM; oi = oi+1) begin
                acc[oi]  <= 0;
                dout[oi] <= 0;
            end
        end else begin
            case (state)

                ST_IDLE: begin
                    dout_valid <= 0;
                    if (start) begin
                        for (oi = 0; oi < OUT_DIM; oi = oi+1)
                            acc[oi] <= $signed(b[oi]);
                        in_idx <= 0;
                        state  <= ST_COMPUTE;
                    end
                end

                ST_COMPUTE: begin
                    if (din_valid) begin
                        for (oi = 0; oi < OUT_DIM; oi = oi+1)
                            acc[oi] <= acc[oi] +
                                       ($signed(din) * $signed(w[in_idx][oi]));
                        if (in_idx == IN_DIM - 1)
                            state <= ST_STORE;
                        else
                            in_idx <= in_idx + 1;
                    end
                end

                ST_STORE: begin
                    for (oi = 0; oi < OUT_DIM; oi = oi+1) begin
                        scaled = acc[oi] >>> SCALE_SH;
                        if (USE_RELU) begin
                            if      (scaled <= 0)      dout[oi] <= 8'h00;
                            else if (scaled > 8'sh7F)  dout[oi] <= 8'h7F;
                            else                       dout[oi] <= scaled[DATA_W-1:0];
                        end else begin
                            if      (scaled < -128)    dout[oi] <= 8'sh80;
                            else if (scaled > 127)     dout[oi] <= 8'sh7F;
                            else                       dout[oi] <= scaled[DATA_W-1:0];
                        end
                    end
                    dout_valid <= 1;
                    state      <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule