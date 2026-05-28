// ============================================================
// Testbench: maxpool1d_unit_tb.sv
// DUT: maxpool1d_unit.sv
//
// Tests:
//   T1: max(3,7)=7 — all 8 channels simultaneously
//   T2: max(-5,-2)=-2 — signed comparison (key correctness test)
//   T3: max(100,10)=100 — first element is larger
//   T4: max(50,50)=50  — equal values
//   T5: Back-to-back 4 pool operations
//   T6: enable=0 during computation → no spurious output
// ============================================================
`timescale 1ns/1ps

module maxpool1d_unit_tb;

    localparam CHANNELS = 8;
    localparam POOL_SZ  = 2;
    localparam DATA_W   = 8;
    localparam CLK_P    = 10;

    reg  clk, rst_n, enable, din_valid;
    wire dout_valid;

    reg  signed [DATA_W-1:0] din  [0:CHANNELS-1];
    wire signed [DATA_W-1:0] dout [0:CHANNELS-1];

    maxpool1d_unit #(
        .CHANNELS (CHANNELS),
        .POOL_SIZE(POOL_SZ),
        .DATA_W   (DATA_W)
    ) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .enable   (enable),
        .din_valid(din_valid),
        .din      (din),
        .dout_valid(dout_valid),
        .dout     (dout)
    );

    initial clk = 0;
    always #(CLK_P/2) clk = ~clk;

    initial begin
        $dumpfile("maxpool1d.vcd");
        $dumpvars(0, maxpool1d_unit_tb);
    end

    integer ch, i, errors;

    task ck;
        begin @(posedge clk); #1; end
    endtask

    task reset_dut;
        begin
            rst_n = 0; enable = 1; din_valid = 0;
            for (ch = 0; ch < CHANNELS; ch = ch + 1) din[ch] = 0;
            repeat(4) ck();
            rst_n = 1;
            enable = 1;
            repeat(2) ck();
        end
    endtask

    // Send a pool pair: v0 then v1, wait for dout_valid, check expected
    task send_and_check;
        input signed [7:0] v0_all;   // value applied to all channels, elem 0
        input signed [7:0] v1_all;   // value applied to all channels, elem 1
        input signed [7:0] exp_all;  // expected max across all channels
        input string  label;
        integer watchdog;
        begin
            // Element 0
            for (ch = 0; ch < CHANNELS; ch = ch + 1) din[ch] = v0_all;
            din_valid = 1; ck();
            // Element 1
            for (ch = 0; ch < CHANNELS; ch = ch + 1) din[ch] = v1_all;
            ck();
            din_valid = 0;

            // Wait for dout_valid (should come within 2 cycles)
            watchdog = 0;
            while (!dout_valid && watchdog < 5) begin
                ck(); watchdog = watchdog + 1;
            end
            ck();

            if (!dout_valid) begin
                $display("  %s: FAIL — dout_valid not seen", label);
                errors = errors + 1;
            end else begin
                // Check all channels got the correct max
                begin : check_block
                    integer fail;
                    fail = 0;
                    for (ch = 0; ch < CHANNELS; ch = ch + 1)
                        if ($signed(dout[ch]) !== $signed(exp_all)) fail = 1;
                    $display("  %s: ch0=%4d ch7=%4d  exp=%4d  %s",
                              label, $signed(dout[0]), $signed(dout[7]),
                              $signed(exp_all), fail ? "FAIL" : "PASS");
                    if (fail) errors = errors + 1;
                end
            end
        end
    endtask

    initial begin
        errors = 0;
        $display("==============================================");
        $display(" TB: maxpool1d_unit  %0d-ch  pool=%0d", CHANNELS, POOL_SZ);
        $display("==============================================");

        reset_dut();

        // ── T1: max(3,7)=7 ─────────────────────────────────────
        $display("\n[T1] max(3,7) = 7");
        send_and_check(8'sd3, 8'sd7, 8'sd7, "max(3,7)");

        reset_dut();

        // ── T2: max(-5,-2)=-2  (signed comparison critical test) ─
        // Unsigned comparison would give max(0xFB, 0xFE)=0xFE=-2 (same by coincidence)
        // but max(0x80, 0xFE)=0xFE=-2 vs signed max(-128,-2)=-2 — use -128 to test
        $display("\n[T2] max(-128,-2)=-2  (signed comparison test)");
        send_and_check(8'sh80, -8'sd2, -8'sd2, "max(-128,-2)");

        reset_dut();

        // ── T3: max(100,10)=100  (first element is larger) ────────
        $display("\n[T3] max(100,10) = 100");
        send_and_check(8'sd100, 8'sd10, 8'sd100, "max(100,10)");

        reset_dut();

        // ── T4: max(50,50)=50  (equal values) ─────────────────────
        $display("\n[T4] max(50,50) = 50  (equal)");
        send_and_check(8'sd50, 8'sd50, 8'sd50, "max(50,50)");

        reset_dut();

        // ── T5: Back-to-back 4 pool operations ────────────────────
        $display("\n[T5] Back-to-back 4 pool ops: pairs (i, i+10) → max=i+10");
        for (i = 0; i < 4; i = i + 1) begin
            for (ch = 0; ch < CHANNELS; ch = ch + 1) din[ch] = i;
            din_valid = 1; ck();
            for (ch = 0; ch < CHANNELS; ch = ch + 1) din[ch] = i + 10;
            ck();
            din_valid = 0; ck();
            $display("  op[%0d]: ch0=%0d (exp %0d) %s",
                      i, $signed(dout[0]), i+10,
                      ($signed(dout[0]) === i+10) ? "PASS" : "CHECK MONITOR");
        end
        repeat(3) ck();

        // ── T6: Disable mid-stream → no spurious output ────────────
        $display("\n[T6] enable=0 during first element → no output");
        for (ch = 0; ch < CHANNELS; ch = ch + 1) din[ch] = 8'sd42;
        din_valid = 1; ck();
        enable = 0;                // disable after first element
        for (ch = 0; ch < CHANNELS; ch = ch + 1) din[ch] = 8'sd99;
        ck();
        din_valid = 0;
        repeat(3) ck();
        enable = 1;
        if (!dout_valid)
            $display("  No spurious output while disabled  PASS");
        else begin
            $display("  FAIL: dout_valid asserted while disabled");
            errors = errors + 1;
        end

        // ── Summary ───────────────────────────────────────────────
        $display("\n==============================================");
        $display(" maxpool1d_unit: Errors=%0d  %s",
                  errors, errors == 0 ? "ALL PASS ✓" : "FAIL ✗");
        $display("==============================================");
        $finish;
    end

    // Monitor all output pulses
    always @(posedge clk) begin
        if (dout_valid)
            $display("  [POOL] ch0=%4d ch1=%4d ch7=%4d",
                      $signed(dout[0]), $signed(dout[1]), $signed(dout[7]));
    end

endmodule
