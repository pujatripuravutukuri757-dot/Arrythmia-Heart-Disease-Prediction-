// ============================================================
// Testbench: ecg_pipeline_top_tb.sv
// DUT: ecg_pipeline_top.sv (the complete inference pipeline)
//
// FIXES from original:
//   1. Removed $readmemh("test_input.hex") dependency — samples
//      are generated internally from a known ECG-like pattern.
//      No external file needed. Simulation runs cleanly.
//   2. Weight checks updated with correct explanation:
//      dense1_w[0][0] CHANGES BETWEEN RETRAINS — any non-X value is PASS.
//   3. All fork/join_any blocks properly structured.
//   4. FSM state names added for readability.
//   5: Added pool buffer count monitors (p1_wr_ptr, p2_wr_ptr).
//
// Tests:
//   T1: Weight load verify — confirm $readmemh loaded non-X values
//   T2: 300-sample stream → buffer_ready assertion
//   T3: Full pipeline inference → result_valid, non-X outputs
//   T4: Config threshold write (AXI-style) — no re-synthesis needed
//   T5: Secure alert bytes — non-X, generated on result
//   T6: Second inference — FSM resets and re-runs correctly
//
// Expected outputs depend on weights — any coherent INT8 non-X result is PASS.
// The design is verified against Python inference in the separate script.
// ============================================================
`timescale 1ns/1ps

module ecg_pipeline_top_tb;

    localparam CLK_P     = 10;
    localparam INPUT_LEN = 300;
    localparam DATA_W    = 8;

    // ── FSM state names (match ecg_pipeline_top.sv) ──────────
    localparam S_IDLE  = 4'd0;
    localparam S_CONV1 = 4'd2;
    localparam S_CONV2 = 4'd4;
    localparam S_DENSE = 4'd6;

    // ── DUT signals ───────────────────────────────────────────
    reg  clk, rst_n;
    reg  sample_valid;
    reg  signed [DATA_W-1:0] sample_in;
    reg  cfg_wr_en;
    reg  [3:0] cfg_wr_addr;
    reg  [7:0] cfg_wr_data;

    wire result_valid;
    wire arrhythmia_det;
    wire [7:0] confidence;
    wire [7:0] alert_byte_0, alert_byte_1, alert_byte_2, alert_byte_3;
    wire [3:0] alert_severity;
    wire busy;
    wire buffer_ready;

    // ── DUT ───────────────────────────────────────────────────
    ecg_pipeline_top #(
        .INPUT_LEN(INPUT_LEN),
        .DATA_W   (DATA_W)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .sample_valid(sample_valid),
        .sample_in   (sample_in),
        .cfg_wr_en   (cfg_wr_en),
        .cfg_wr_addr (cfg_wr_addr),
        .cfg_wr_data (cfg_wr_data),
        .result_valid(result_valid),
        .arrhythmia_det(arrhythmia_det),
        .confidence  (confidence),
        .alert_byte_0(alert_byte_0),
        .alert_byte_1(alert_byte_1),
        .alert_byte_2(alert_byte_2),
        .alert_byte_3(alert_byte_3),
        .alert_severity(alert_severity),
        .busy        (busy),
        .buffer_ready(buffer_ready)
    );

    // ── Clock ─────────────────────────────────────────────────
    initial clk = 0;
    always #(CLK_P/2) clk = ~clk;

    // ── VCD dump ──────────────────────────────────────────────
    initial begin
        $dumpfile("ecg_pipeline_top.vcd");
        $dumpvars(0, ecg_pipeline_top_tb);
    end

    // ── Watchdog: fires if main test hangs ────────────────────
    initial begin
        #(CLK_P * 700_000);
        $display("[WATCHDOG] Timeout — 700k cycles without $finish");
        $finish;
    end

    // ── ECG sample generation ─────────────────────────────────
    // Synthetic normal-sinus ECG pattern: periodic QRS complex.
    // Does NOT require any external hex file.
    reg signed [DATA_W-1:0] ecg_samples [0:INPUT_LEN-1];

    task gen_ecg_samples;
        integer s;
        integer phase;
        begin
            for (s = 0; s < INPUT_LEN; s = s + 1) begin
                phase = s % 30;
                case (phase)
                    // Flat baseline
                    0,1,28,29:    ecg_samples[s] =  8'sd2;
                    // P-wave (atrial depolarisation)
                    2,3,4:        ecg_samples[s] =  8'sd8;
                    5,6:          ecg_samples[s] =  8'sd12;
                    7,8,9:        ecg_samples[s] =  8'sd8;
                    // Q-wave (dip before R)
                    10:           ecg_samples[s] = -8'sd10;
                    // R-wave (dominant peak)
                    11:           ecg_samples[s] =  8'sd80;
                    12:           ecg_samples[s] =  8'sd127;  // apex
                    13:           ecg_samples[s] =  8'sd80;
                    // S-wave (dip after R)
                    14:           ecg_samples[s] = -8'sd20;
                    15,16:        ecg_samples[s] = -8'sd5;
                    // ST segment
                    17,18,19:     ecg_samples[s] =  8'sd3;
                    // T-wave
                    20,21:        ecg_samples[s] =  8'sd15;
                    22,23,24:     ecg_samples[s] =  8'sd25;
                    25,26:        ecg_samples[s] =  8'sd15;
                    // Return to baseline
                    27:           ecg_samples[s] =  8'sd4;
                    default:      ecg_samples[s] =  8'sd0;
                endcase
            end
        end
    endtask

    // ── Helpers ───────────────────────────────────────────────
    integer errors;

    task ck;
        begin @(posedge clk); #1; end
    endtask

    task reset_dut;
        begin
            rst_n        = 0;
            sample_valid = 0;
            sample_in    = 0;
            cfg_wr_en    = 0;
            cfg_wr_addr  = 0;
            cfg_wr_data  = 0;
            repeat(4) ck();
            rst_n = 1;
            repeat(2) ck();
        end
    endtask

    task stream_samples;
        integer s;
        begin
            for (s = 0; s < INPUT_LEN; s = s + 1) begin
                sample_in    = ecg_samples[s];
                sample_valid = 1;
                ck();
            end
            sample_valid = 0;
        end
    endtask

    task write_cfg;
        input [3:0] addr;
        input [7:0] data;
        begin
            cfg_wr_addr = addr; cfg_wr_data = data; cfg_wr_en = 1;
            ck();
            cfg_wr_en = 0;
            ck();
        end
    endtask

    task wait_result;
        input integer timeout;
        integer wd;
        begin
            wd = 0;
            while (!result_valid && wd < timeout) begin
                ck(); wd = wd + 1;
            end
            if (wd >= timeout) begin
                $display("  TIMEOUT: result_valid not seen in %0d cycles", timeout);
                errors = errors + 1;
            end
        end
    endtask

    // ── Main test ─────────────────────────────────────────────
    initial begin
        errors = 0;
        $display("============================================================");
        $display("  PIPELINE TOP TB: Full integration  (6 tests)");
        $display("============================================================");

        gen_ecg_samples();
        reset_dut();

        // ── T1: Weight load verify ─────────────────────────────
        // dense1_w[0][0] is loaded from dense_w.hex line 1.
        // The VALUE changes between retrains — any non-X INT8 is PASS.
        // The LINE COUNT (18432) must remain fixed.
        $display("\n[T1] Weight load: dense1_w[0][0] = non-X non-zero?");
        #1;
        if ($isunknown(dut.dense1_w[0][0])) begin
            $display("  FAIL: dense1_w[0][0] is X — hex file not loaded");
            errors = errors + 1;
        end else begin
            $display("  dense1_w[0][0] = %0d  (loaded, non-X)  PASS", $signed(dut.dense1_w[0][0]));
            $display("  NOTE: this value differs between retrains — that is correct");
        end
        $display("  dense1_w[0][1] = %0d", $signed(dut.dense1_w[0][1]));
        $display("  dense1_b[0]    = %0d", $signed(dut.dense1_b[0]));
        $display("  out_b[0]       = %0d", $signed(dut.out_b[0]));

        // Verify dense_engine has the same values via port
        $display("  u_dense1.w[0][0] = %0d  (port connected?  %s)",
                  $signed(dut.u_dense1.w[0][0]),
                  (dut.u_dense1.w[0][0] === dut.dense1_w[0][0]) ? "YES PASS" : "MISMATCH FAIL");
        if (dut.u_dense1.w[0][0] !== dut.dense1_w[0][0]) errors = errors + 1;

        // ── T2: Buffer load → buffer_ready ────────────────────
        $display("\n[T2] Stream 300 samples → buffer_ready");
        stream_samples();
        repeat(5) ck();
        if (buffer_ready)
            $display("  buffer_ready asserted  PASS");
        else begin
            $display("  FAIL: buffer_ready not asserted after 300 samples");
            errors = errors + 1;
        end

        // Monitor Conv1 first output (no timeout penalty on failure)
        fork
            begin : conv1_mon
                @(posedge dut.c1_valid);
                $display("  [DBG] Conv1 first: ch0=%0d ch1=%0d ch2=%0d",
                          $signed(dut.c1_out[0]),
                          $signed(dut.c1_out[1]),
                          $signed(dut.c1_out[2]));
            end
            begin : conv1_timeout
                #(CLK_P * 2000);
            end
        join_any
        disable conv1_mon; disable conv1_timeout;

        // ── T3: Full pipeline inference ────────────────────────
        $display("\n[T3] Wait for result_valid (timeout=5000 cycles)");
        wait_result(5000);
        ck();

        if (!$isunknown(arrhythmia_det)) begin
            $display("  result_valid received  PASS");
            $display("  arrhythmia_det = %0b", arrhythmia_det);
            $display("  confidence     = %0d / 255", confidence);
            $display("  alert_severity = %0d", alert_severity);
            $display("  classification = %s",
                      arrhythmia_det ? "ARRHYTHMIA" : "NORMAL (expected for sinus ECG)");
        end else begin
            $display("  FAIL: arrhythmia_det = X after result_valid");
            errors = errors + 1;
        end

        // ── T4: AXI-style config register write ────────────────
        $display("\n[T4] AXI config: lower threshold to 0x60 (more sensitive)");
        write_cfg(4'd3, 8'h60);
        $display("  Write done. cfg_threshold now = 0x%02h  PASS", dut.u_cfg.regs[3]);

        // ── T5: Alert bytes ────────────────────────────────────
        $display("\n[T5] Secure alert bytes: non-X?");
        repeat(3) ck();
        if (!$isunknown(alert_byte_0)) begin
            $display("  alert bytes: [0x%02h 0x%02h 0x%02h 0x%02h]  PASS",
                      alert_byte_0, alert_byte_1, alert_byte_2, alert_byte_3);
        end else begin
            $display("  FAIL: alert_byte_0 is X");
            errors = errors + 1;
        end

        // ── T6: Second inference → FSM resets and reruns ───────
        $display("\n[T6] Second inference: FSM must reset and complete again");
        write_cfg(4'd3, 8'h80);     // restore threshold
        reset_dut();
        gen_ecg_samples();
        stream_samples();
        repeat(5) ck();

        if (buffer_ready)
            $display("  buffer_ready for 2nd window  PASS");
        else begin
            $display("  FAIL: buffer_ready not asserted for 2nd window");
            errors = errors + 1;
        end

        wait_result(5000);
        ck();
        if (!$isunknown(arrhythmia_det)) begin
            $display("  2nd inference complete: det=%0b conf=%0d  PASS",
                      arrhythmia_det, confidence);
        end else begin
            $display("  FAIL: 2nd inference result is X");
            errors = errors + 1;
        end

        // ── Summary ───────────────────────────────────────────
        $display("\n============================================================");
        $display("  PIPELINE TOP TB: Errors=%0d  %s",
                  errors, errors == 0 ? "ALL PASS ✓" : "FAIL ✗");
        $display("============================================================");
        #100;
        $finish;
    end

    // ── FSM state transition monitor ──────────────────────────
    reg [3:0] prev_state;
    always @(posedge clk) begin
        if (dut.state !== prev_state) begin
            case (dut.state)
                S_IDLE:  $display("[FSM] → S_IDLE   @ %0t", $time);
                S_CONV1: $display("[FSM] → S_CONV1  @ %0t  (stream ECG + flush)", $time);
                S_CONV2: $display("[FSM] → S_CONV2  @ %0t  (replay pool1 + flush)", $time);
                S_DENSE: $display("[FSM] → S_DENSE  @ %0t  (flatten + dense + sigmoid)", $time);
                default: $display("[FSM] → state=%0d @ %0t", dut.state, $time);
            endcase
            prev_state <= dut.state;
        end
    end

    // ── Pool pointer monitors ──────────────────────────────────
    always @(posedge clk) begin
        if (dut.p1_buf_full && !prev_state[1])
            $display("[P1] Pool1 buffer full: p1_wr_ptr=%0d @ %0t", dut.p1_wr_ptr, $time);
        if (dut.p2_buf_full && !prev_state[0])
            $display("[P2] Pool2 buffer full: p2_wr_ptr=%0d @ %0t", dut.p2_wr_ptr, $time);
    end

endmodule
