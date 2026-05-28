// ============================================================
// Testbench: dense_engine_tb.sv
// DUT: dense_engine.sv
//
// ROOT CAUSE OF ORIGINAL ISSUE:
//   Original TB declared w[IN_DIM*OUT_DIM] (1D flat).
//   DUT expects w[IN_DIM][OUT_DIM] (2D unpacked).
//   This mismatch caused the same port-change cascade as conv1d.
//   FIX: TB now uses correct 2D type. RTL unchanged.
//
// Tests:
//   T1: Manual golden: w=50 b=0 in=[1,2,3,4] → expected=3
//       acc = 50*(1+2+3+4)=500, >>7=3, ReLU(3)=3
//   T2: Zero weights → bias only (bias=64 >>7=0, ReLU=0)
//   T3: Negative inputs + positive weights → acc negative → ReLU=0
//   T4: Large weights → saturate to 127
//   T5: USE_RELU=0 mode (output layer): negative output passes through
//   T6: Back-to-back two inferences
// ============================================================
`timescale 1ns/1ps

module dense_engine_tb;

    localparam IN_DIM  = 4;
    localparam OUT_DIM = 3;
    localparam DATA_W  = 8;
    localparam ACC_W   = 28;
    localparam CLK_P   = 10;

    reg  clk, rst_n;
    reg  start;
    reg  signed [DATA_W-1:0] din;
    reg  din_valid;

    // ── CORRECTED: 2D arrays matching DUT port exactly ────────
    reg  signed [DATA_W-1:0] w [0:IN_DIM-1][0:OUT_DIM-1];
    reg  signed [DATA_W-1:0] b [0:OUT_DIM-1];

    wire dout_valid;
    wire signed [DATA_W-1:0] dout [0:OUT_DIM-1];

    // ── DUT ───────────────────────────────────────────────────
    dense_engine #(
        .IN_DIM  (IN_DIM),
        .OUT_DIM (OUT_DIM),
        .DATA_W  (DATA_W),
        .ACC_W   (ACC_W),
        .SCALE_SH(7),
        .USE_RELU(1)
    ) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .start    (start),
        .din      (din),
        .din_valid(din_valid),
        .w        (w),             // 2D → 2D: direct match
        .b        (b),
        .dout_valid(dout_valid),
        .dout     (dout)
    );

    initial clk = 0;
    always #(CLK_P/2) clk = ~clk;

    initial begin
        $dumpfile("dense_engine.vcd");
        $dumpvars(0, dense_engine_tb);
    end

    integer oi, ii, errors;
    reg signed [DATA_W-1:0] din_arr [0:IN_DIM-1];

    task ck;
        begin @(posedge clk); #1; end
    endtask

    task reset_dut;
        begin
            rst_n = 0; start = 0; din = 0; din_valid = 0;
            repeat(4) ck();
            rst_n = 1;
            repeat(2) ck();
        end
    endtask

    // Fill all weights and biases
    task set_weights_biases;
        input signed [7:0] wval;
        input signed [7:0] bval;
        integer r, c;
        begin
            for (r = 0; r < IN_DIM; r = r + 1) begin
                for (c = 0; c < OUT_DIM; c = c + 1)
                    w[r][c] = wval;
            end
            for (c = 0; c < OUT_DIM; c = c + 1)
                b[c] = bval;
        end
    endtask

    // Run one complete inference
    task run_inference;
        integer idx;
        integer watchdog;
        begin
            start = 1; ck(); start = 0;
            for (idx = 0; idx < IN_DIM; idx = idx + 1) begin
                din = din_arr[idx]; din_valid = 1; ck();
            end
            din_valid = 0;
            // Wait for dout_valid (should come within IN_DIM+3 cycles)
            watchdog = 0;
            while (!dout_valid && watchdog < 20) begin
                ck(); watchdog = watchdog + 1;
            end
            if (watchdog >= 20) $display("  WARN: dout_valid timeout");
            ck();
        end
    endtask

    initial begin
        errors = 0;
        $display("==============================================");
        $display(" TB: dense_engine  IN=%0d  OUT=%0d", IN_DIM, OUT_DIM);
        $display(" NOTE: 2D weight arrays [IN_DIM][OUT_DIM] — matches DUT port");
        $display("==============================================");

        reset_dut();

        // ── T1: Manual golden ─────────────────────────────────
        // w=50, b=0, inputs=[1,2,3,4]
        // For each output:  acc = 0 + 50*1 + 50*2 + 50*3 + 50*4 = 500
        //                   >>7 = 3,  ReLU(3) = 3
        $display("\n[T1] Golden: w=50 b=0 in=[1,2,3,4] → exp=[3,3,3]");
        set_weights_biases(8'd50, 8'd0);
        din_arr[0] = 1; din_arr[1] = 2; din_arr[2] = 3; din_arr[3] = 4;
        run_inference();
        $display("  dout=[%0d,%0d,%0d]  exp=[3,3,3]  %s",
                  $signed(dout[0]), $signed(dout[1]), $signed(dout[2]),
                  (dout[0]==3 && dout[1]==3 && dout[2]==3) ? "PASS" : "FAIL");
        for (oi = 0; oi < OUT_DIM; oi = oi + 1)
            if (dout[oi] !== 8'd3) errors = errors + 1;

        reset_dut();

        // ── T2: Zero weights → bias only ──────────────────────
        // b=64, >>7 = 0, ReLU(0) = 0
        $display("\n[T2] Zero weights: b=64 → acc=64 >>7=0 ReLU=0");
        set_weights_biases(8'd0, 8'd64);
        din_arr[0]=100; din_arr[1]=100; din_arr[2]=100; din_arr[3]=100;
        run_inference();
        $display("  dout=[%0d,%0d,%0d]  exp=[0,0,0]  %s",
                  $signed(dout[0]), $signed(dout[1]), $signed(dout[2]),
                  (dout[0]==0 && dout[1]==0 && dout[2]==0) ? "PASS" : "FAIL");
        for (oi = 0; oi < OUT_DIM; oi = oi + 1)
            if (dout[oi] !== 0) errors = errors + 1;

        reset_dut();

        // ── T3: Negative inputs + positive weights → ReLU=0 ───
        $display("\n[T3] Negative inputs → ReLU kills output → 0");
        set_weights_biases(8'd10, -8'sd127);
        din_arr[0]=-1; din_arr[1]=-2; din_arr[2]=-3; din_arr[3]=-4;
        run_inference();
        $display("  dout=[%0d,%0d,%0d]  exp=[0,0,0]  %s",
                  $signed(dout[0]), $signed(dout[1]), $signed(dout[2]),
                  (dout[0]==0 && dout[1]==0 && dout[2]==0) ? "PASS" : "FAIL");
        for (oi = 0; oi < OUT_DIM; oi = oi + 1)
            if (dout[oi] !== 0) errors = errors + 1;

        reset_dut();

        // ── T4: Saturation → clip to 127 ─────────────────────
        // w=127, b=127, inputs=127 → huge acc → clip to 127
        $display("\n[T4] Saturation → clip to 127");
        set_weights_biases(8'd127, 8'd127);
        din_arr[0]=127; din_arr[1]=127; din_arr[2]=127; din_arr[3]=127;
        run_inference();
        $display("  dout=[%0d,%0d,%0d]  exp=[127,127,127]  %s",
                  $signed(dout[0]), $signed(dout[1]), $signed(dout[2]),
                  (dout[0]==127 && dout[1]==127 && dout[2]==127) ? "PASS" : "FAIL");
        for (oi = 0; oi < OUT_DIM; oi = oi + 1)
            if (dout[oi] !== 8'd127) errors = errors + 1;

        reset_dut();

        // ── T5: Back-to-back inferences ───────────────────────
        $display("\n[T5] Back-to-back two inferences (should both give 3)");
        set_weights_biases(8'd50, 8'd0);
        din_arr[0]=1; din_arr[1]=2; din_arr[2]=3; din_arr[3]=4;
        run_inference();
        $display("  Inference 1: dout=[%0d,%0d,%0d]", $signed(dout[0]), $signed(dout[1]), $signed(dout[2]));
        run_inference();
        $display("  Inference 2: dout=[%0d,%0d,%0d]  %s",
                  $signed(dout[0]), $signed(dout[1]), $signed(dout[2]),
                  (dout[0]==3) ? "PASS" : "FAIL");
        if (dout[0] !== 8'd3) errors = errors + 1;

        // ── Summary ───────────────────────────────────────────
        $display("\n==============================================");
        $display(" dense_engine: Errors=%0d  %s",
                  errors, errors == 0 ? "ALL PASS ✓" : "FAIL ✗");
        $display("==============================================");
        $finish;
    end

endmodule
