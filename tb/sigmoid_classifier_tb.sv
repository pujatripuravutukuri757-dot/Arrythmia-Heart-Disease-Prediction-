// ============================================================
// Testbench: sigmoid_classifier_tb.sv
// DUT: sigmoid_classifier.sv  (9-segment piecewise linear)
//
// Tests all 9 sigmoid segments plus runtime threshold change.
// Matches DUT interface exactly (DATA_W=16 logit input).
// ============================================================
`timescale 1ns/1ps

module sigmoid_classifier_tb;

    localparam DATA_W = 16;
    localparam CONF_W = 8;
    localparam CLK_P  = 10;

    reg  clk, rst_n, valid_in;
    reg  signed [DATA_W-1:0] logit_in;
    reg  [CONF_W-1:0] threshold_cfg;

    wire valid_out;
    wire [CONF_W-1:0] confidence;
    wire classification;

    sigmoid_classifier #(
        .DATA_W   (DATA_W),
        .CONF_W   (CONF_W),
        .THRESHOLD(128)
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .valid_in      (valid_in),
        .logit_in      (logit_in),
        .threshold_cfg (threshold_cfg),
        .valid_out     (valid_out),
        .confidence    (confidence),
        .classification(classification)
    );

    initial clk = 0;
    always #(CLK_P/2) clk = ~clk;

    initial begin
        $dumpfile("sigmoid_classifier.vcd");
        $dumpvars(0, sigmoid_classifier_tb);
    end

    integer errors;

    task ck;
        begin @(posedge clk); #1; end
    endtask

    task reset_dut;
        begin
            rst_n = 0; valid_in = 0; logit_in = 0; threshold_cfg = 128;
            repeat(4) ck();
            rst_n = 1;
            repeat(2) ck();
        end
    endtask

    // Send logit, wait for result, check class and confidence range
    task check_logit;
        input signed [15:0]  x;
        input integer        exp_class;
        input integer        exp_conf_min;
        input integer        exp_conf_max;
        integer watchdog;
        begin
            logit_in = x; valid_in = 1; ck(); valid_in = 0;
            watchdog = 0;
            while (!valid_out && watchdog < 5) begin
                ck(); watchdog = watchdog + 1;
            end
            $display("  logit=%4d → conf=%3d class=%0d  (exp cls=%0d, conf[%0d..%0d])  %s",
                      $signed(x), confidence, classification,
                      exp_class, exp_conf_min, exp_conf_max,
                      (classification == exp_class &&
                       confidence >= exp_conf_min &&
                       confidence <= exp_conf_max) ? "PASS" : "FAIL");
            if (classification !== exp_class || confidence < exp_conf_min || confidence > exp_conf_max)
                errors = errors + 1;
        end
    endtask

    initial begin
        errors = 0;
        $display("==============================================");
        $display(" TB: sigmoid_classifier  9-segment PW-linear");
        $display("==============================================");

        reset_dut();
        threshold_cfg = 128;

        // ── T1: All 9 sigmoid segments ─────────────────────────
        $display("\n[T1] 9-segment sigmoid (threshold=128=0.5)");
        //           logit    cls  conf_min  conf_max
        check_logit(-16'd20,  0,    0,   2);   // x << -8  → conf ≈ 0
        check_logit(-16'd8,   0,    0,   4);   // segment 1 boundary
        check_logit(-16'd6,   0,    2,  12);   // segment 2
        check_logit(-16'd4,   0,    8,  30);   // segment 3
        check_logit(-16'd2,   0,   24,  68);   // segment 4
        check_logit( 16'd0,   1,  126, 130);   // x=0 → conf=128, class=1 (≥threshold)
        check_logit( 16'd2,   1,  188, 196);   // segment 6
        check_logit( 16'd4,   1,  224, 236);   // segment 7
        check_logit( 16'd6,   1,  244, 250);   // segment 8
        check_logit( 16'd8,   1,  250, 255);   // segment 9
        check_logit( 16'd20,  1,  255, 255);   // x >> +8  → conf=255

        // ── T2: Runtime threshold — sensitivity control ─────────
        $display("\n[T2] Runtime threshold change (no RTL re-synthesis needed)");
        // x=0 gives conf=128. With threshold=200 → class should flip to 0
        threshold_cfg = 8'd200;
        check_logit(16'd0, 0, 126, 130);       // conf=128 < threshold=200 → class=0
        $display("  threshold=200: x=0 → class=0 (less sensitive)");

        // With threshold=64 → class=1 even for small positive logit
        threshold_cfg = 8'd64;
        check_logit(16'd0, 1, 126, 130);       // conf=128 ≥ threshold=64 → class=1
        $display("  threshold=64: x=0 → class=1 (more sensitive)");

        threshold_cfg = 8'd128;                // Restore

        // ── T3: Extreme negative → conf→0 ──────────────────────
        $display("\n[T3] Strongly negative logit → confidence → 0");
        check_logit(-16'd1000, 0, 0, 2);

        // ── T4: Extreme positive → conf→255 ───────────────────
        $display("\n[T4] Strongly positive logit → confidence → 255");
        check_logit(16'd1000, 1, 253, 255);

        // ── T5: No spurious output when valid_in=0 ─────────────
        $display("\n[T5] No output when valid_in=0");
        valid_in = 0;
        repeat(5) ck();
        if (valid_out) begin
            $display("  FAIL: spurious valid_out during idle");
            errors = errors + 1;
        end else
            $display("  No spurious output  PASS");

        // ── Summary ───────────────────────────────────────────
        $display("\n==============================================");
        $display(" sigmoid_classifier: Errors=%0d  %s",
                  errors, errors == 0 ? "ALL PASS ✓" : "FAIL ✗");
        $display("==============================================");
        $finish;
    end

endmodule
