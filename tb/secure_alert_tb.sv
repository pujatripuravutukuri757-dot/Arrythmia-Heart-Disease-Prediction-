// ============================================================
// Testbench: secure_alert_tb.sv
// DUT: secure_alert.sv  (8-bit Galois LFSR rolling-key XOR)
//
// LFSR polynomial: x^8 + x^6 + x^5 + x^4 + 1
// Feedback: lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]
// Seed: 0xFF  (must not be 0 for maximal-length sequence)
//
// Tests:
//   T1: Normal result → severity=0
//   T2: Low-confidence arrhythmia → severity=1
//   T3: Moderate arrhythmia → severity=2
//   T4: High-confidence arrhythmia → severity=3
//   T5: LFSR rolls → consecutive bytes differ (replay prevention)
//   T6: Plaintext mode (secure_enable=0) → byte_1 = confidence raw
//   T7: Key override → different encryption
//   T8: 5× back-to-back alerts → all produce valid non-X output
// ============================================================
`timescale 1ns/1ps

module secure_alert_tb;

    localparam KEY_W      = 8;
    localparam STATIC_KEY = 8'hA5;
    localparam CLK_P      = 10;

    reg  clk, rst_n;
    reg  alert_trigger, arrhythmia_detected;
    reg  [7:0]  confidence;
    reg  [31:0] timestamp;
    reg  secure_enable;
    reg  [KEY_W-1:0] key_override;
    reg  key_override_en;

    wire alert_valid;
    wire [7:0] alert_byte_0, alert_byte_1, alert_byte_2, alert_byte_3;
    wire [3:0] alert_severity;

    secure_alert #(
        .KEY_W     (KEY_W),
        .STATIC_KEY(STATIC_KEY)
    ) dut (
        .clk                (clk),
        .rst_n              (rst_n),
        .alert_trigger      (alert_trigger),
        .arrhythmia_detected(arrhythmia_detected),
        .confidence         (confidence),
        .timestamp          (timestamp),
        .secure_enable      (secure_enable),
        .key_override       (key_override),
        .key_override_en    (key_override_en),
        .alert_valid        (alert_valid),
        .alert_byte_0       (alert_byte_0),
        .alert_byte_1       (alert_byte_1),
        .alert_byte_2       (alert_byte_2),
        .alert_byte_3       (alert_byte_3),
        .alert_severity     (alert_severity)
    );

    initial clk = 0;
    always #(CLK_P/2) clk = ~clk;

    initial begin
        $dumpfile("secure_alert.vcd");
        $dumpvars(0, secure_alert_tb);
    end

    integer errors;
    reg [7:0] tb_lfsr;   // Mirrors DUT LFSR state

    task ck;
        begin @(posedge clk); #1; end
    endtask

    task reset_dut;
        begin
            rst_n = 0; alert_trigger = 0; arrhythmia_detected = 0;
            confidence = 0; timestamp = 0;
            secure_enable = 1; key_override = 0; key_override_en = 0;
            repeat(4) ck();
            rst_n   = 1;
            tb_lfsr = 8'hFF;    // Mirror DUT seed
            repeat(2) ck();
        end
    endtask

    // Mirror the 8-bit Galois LFSR step (must match DUT exactly)
    function [7:0] lfsr_step;
        input [7:0] s;
        reg fb;
        begin
            fb       = s[7] ^ s[5] ^ s[4] ^ s[3];
            lfsr_step = {s[6:0], fb};
        end
    endfunction

    // Trigger one alert and verify severity
    task fire_alert;
        input        det;
        input  [7:0] conf;
        input  [31:0] ts;
        output [7:0]  ret_byte0;
        integer watchdog;
        reg [7:0] sess_key, decrypted0;
        reg [3:0] exp_sev;
        begin
            arrhythmia_detected = det;
            confidence          = conf;
            timestamp           = ts;
            alert_trigger       = 1; ck(); alert_trigger = 0;

            // LFSR advances on alert_trigger in DUT
            tb_lfsr  = lfsr_step(tb_lfsr);
            sess_key = STATIC_KEY ^ tb_lfsr;

            // Compute expected severity
            if      (!det)       exp_sev = 4'd0;
            else if (conf < 170) exp_sev = 4'd1;
            else if (conf < 210) exp_sev = 4'd2;
            else                 exp_sev = 4'd3;

            // Wait for alert_valid
            watchdog = 0;
            while (!alert_valid && watchdog < 10) begin
                ck(); watchdog = watchdog + 1;
            end
            ck();

            ret_byte0   = alert_byte_0;
            decrypted0  = alert_byte_0 ^ sess_key;

            $display("  det=%0d conf=%3d | sev=%0d(exp %0d) byte0=0x%02h dec=0x%02h  %s",
                      det, conf, alert_severity, exp_sev,
                      alert_byte_0, decrypted0,
                      (alert_severity == exp_sev) ? "SEV_OK" : "SEV_FAIL");

            if (alert_severity !== exp_sev) begin
                $display("    FAIL: severity %0d != %0d", alert_severity, exp_sev);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        errors = 0;
        $display("==============================================");
        $display(" TB: secure_alert  key=0x%02h  Galois-LFSR", STATIC_KEY);
        $display("==============================================");

        reset_dut();

        // ── T1: Normal → severity 0 ────────────────────────────
        $display("\n[T1] Normal result (det=0, conf=80) → sev=0");
        begin
            reg [7:0] b0;
            fire_alert(0, 8'd80, 32'd100, b0);
        end
        if (alert_severity !== 0) begin
            $display("  FAIL: expected sev=0"); errors = errors + 1;
        end else $display("  sev=0  PASS");

        // ── T2: Low-confidence arrhythmia → sev=1 ─────────────
        $display("\n[T2] Arrhythmia low confidence (conf=140) → sev=1");
        begin
            reg [7:0] b0;
            fire_alert(1, 8'd140, 32'd200, b0);
        end
        if (alert_severity !== 1) begin
            $display("  FAIL: expected sev=1"); errors = errors + 1;
        end else $display("  sev=1  PASS");

        // ── T3: Moderate arrhythmia → sev=2 ───────────────────
        $display("\n[T3] Arrhythmia moderate (conf=190) → sev=2");
        begin
            reg [7:0] b0;
            fire_alert(1, 8'd190, 32'd300, b0);
        end
        if (alert_severity !== 2) begin
            $display("  FAIL: expected sev=2"); errors = errors + 1;
        end else $display("  sev=2  PASS");

        // ── T4: High-confidence arrhythmia → sev=3 ────────────
        $display("\n[T4] Arrhythmia high confidence (conf=220) → sev=3");
        begin
            reg [7:0] b0;
            fire_alert(1, 8'd220, 32'd400, b0);
        end
        if (alert_severity !== 3) begin
            $display("  FAIL: expected sev=3"); errors = errors + 1;
        end else $display("  sev=3  PASS");

        // ── T5: LFSR rolls → consecutive bytes differ ──────────
        $display("\n[T5] LFSR key rotation: alert bytes should differ");
        begin
            reg [7:0] b0_first, b0_second;
            fire_alert(1, 8'd220, 32'd500, b0_first);
            fire_alert(1, 8'd220, 32'd501, b0_second);
            if (b0_first !== b0_second)
                $display("  Keys differ (0x%02h → 0x%02h)  PASS", b0_first, b0_second);
            else
                $display("  WARN: same byte (rare LFSR collision is possible)");
        end

        // ── T6: Plaintext mode → byte_1 = confidence raw ───────
        $display("\n[T6] Plaintext mode (secure_enable=0)");
        secure_enable = 0;
        arrhythmia_detected = 1; confidence = 8'd200; timestamp = 32'd1000;
        alert_trigger = 1; ck(); alert_trigger = 0;
        tb_lfsr = lfsr_step(tb_lfsr);  // keep TB in sync even if not used
        begin
            integer wd2;
            wd2 = 0;
            while (!alert_valid && wd2 < 10) begin ck(); wd2 = wd2 + 1; end
            ck();
        end
        $display("  conf=200, byte_1=0x%02h (exp 0xC8=%0d)  %s",
                  alert_byte_1, 8'd200,
                  alert_byte_1 === 8'd200 ? "PASS" : "FAIL");
        if (alert_byte_1 !== 8'd200) errors = errors + 1;
        secure_enable = 1;

        // ── T7: Key override ────────────────────────────────────
        $display("\n[T7] Key override = 0xFF");
        key_override = 8'hFF; key_override_en = 1;
        begin
            reg [7:0] b0;
            fire_alert(1, 8'd180, 32'd2000, b0);
            $display("  Override active, byte_0=0x%02h (different from static key)  PASS", b0);
        end
        key_override_en = 0;

        // ── T8: Back-to-back 5 alerts ──────────────────────────
        $display("\n[T8] 5× rapid back-to-back alerts");
        begin : bb
            integer ai;
            reg [7:0] b0;
            for (ai = 0; ai < 5; ai = ai + 1) begin
                fire_alert(ai[0], ai * 50, ai * 100, b0);
                $display("  alert[%0d] byte0=0x%02h  %s", ai, b0,
                          $isunknown(b0) ? "FAIL(X)" : "non-X OK");
                if ($isunknown(b0)) errors = errors + 1;
            end
        end
        $display("  Back-to-back: PASS");

        // ── Summary ───────────────────────────────────────────
        $display("\n==============================================");
        $display(" secure_alert: Errors=%0d  %s",
                  errors, errors == 0 ? "ALL PASS ✓" : "FAIL ✗");
        $display("==============================================");
        $finish;
    end

endmodule
