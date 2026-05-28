// ============================================================
// Testbench: config_reg_block_tb.sv
// DUT: config_reg_block.sv
//
// Tests all 16 registers, power-on defaults, decoded outputs,
// simultaneous read/write, and reset restoration.
// Interface matches config_reg_block.sv exactly.
// ============================================================
`timescale 1ns/1ps

module config_reg_block_tb;

    localparam CLK_P = 10;

    reg  clk, rst_n;
    reg  wr_en;
    reg  [3:0] wr_addr, rd_addr;
    reg  [7:0] wr_data;
    wire [7:0] rd_data;

    wire        cfg_conv1_en, cfg_conv2_en, cfg_dense_en, cfg_secure_en;
    wire [2:0]  cfg_conv1_kern, cfg_conv2_kern;
    wire [3:0]  cfg_conv1_filt, cfg_conv2_filt;
    wire [7:0]  cfg_threshold, cfg_enc_key;
    wire        cfg_key_override, cfg_debug_mode;

    config_reg_block #(
        .DEFAULT_CTRL(8'h0F),
        .DEFAULT_THR (8'h80)
    ) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .wr_en           (wr_en),
        .wr_addr         (wr_addr),
        .wr_data         (wr_data),
        .rd_addr         (rd_addr),
        .rd_data         (rd_data),
        .cfg_conv1_en    (cfg_conv1_en),
        .cfg_conv2_en    (cfg_conv2_en),
        .cfg_dense_en    (cfg_dense_en),
        .cfg_secure_en   (cfg_secure_en),
        .cfg_conv1_kern  (cfg_conv1_kern),
        .cfg_conv2_kern  (cfg_conv2_kern),
        .cfg_conv1_filt  (cfg_conv1_filt),
        .cfg_conv2_filt  (cfg_conv2_filt),
        .cfg_threshold   (cfg_threshold),
        .cfg_enc_key     (cfg_enc_key),
        .cfg_key_override(cfg_key_override),
        .cfg_debug_mode  (cfg_debug_mode)
    );

    initial clk = 0;
    always #(CLK_P/2) clk = ~clk;

    initial begin
        $dumpfile("config_reg_block.vcd");
        $dumpvars(0, config_reg_block_tb);
    end

    integer i, errors;

    task ck;
        begin @(posedge clk); #1; end
    endtask

    task reset_dut;
        begin
            rst_n = 0; wr_en = 0; wr_addr = 0; wr_data = 0; rd_addr = 0;
            repeat(4) ck();
            rst_n = 1;
            repeat(2) ck();
        end
    endtask

    task write_reg;
        input [3:0] addr;
        input [7:0] data;
        begin
            wr_addr = addr; wr_data = data; wr_en = 1; ck(); wr_en = 0;
        end
    endtask

    task read_reg;
        input [3:0] addr;
        begin
            rd_addr = addr; ck(); ck();   // 2-cycle synchronous read latency
        end
    endtask

    initial begin
        errors = 0;
        $display("==============================================");
        $display(" TB: config_reg_block  16 registers");
        $display("==============================================");

        reset_dut();

        // ── T1: Power-on defaults ─────────────────────────────
        $display("\n[T1] Power-on defaults");
        $display("  conv1=%0d conv2=%0d dense=%0d secure=%0d  threshold=0x%02h  key=0x%02h",
                  cfg_conv1_en, cfg_conv2_en, cfg_dense_en, cfg_secure_en,
                  cfg_threshold, cfg_enc_key);
        if (!cfg_conv1_en || !cfg_conv2_en || !cfg_dense_en) begin
            $display("  FAIL: layer enables not all 1 after reset"); errors = errors + 1;
        end
        if (cfg_threshold !== 8'h80) begin
            $display("  FAIL: threshold=0x%02h (exp 0x80)", cfg_threshold); errors = errors + 1;
        end
        if (cfg_enc_key !== 8'hA5) begin
            $display("  FAIL: enc_key=0x%02h (exp 0xA5)", cfg_enc_key); errors = errors + 1;
        end
        $display("  Defaults: %s", (errors == 0) ? "PASS" : "FAIL");

        // ── T2: Write/Read all 16 registers ───────────────────
        $display("\n[T2] Write pattern 0xAA+i to all 16 registers");
        for (i = 0; i < 16; i = i + 1)
            write_reg(i[3:0], 8'hAA + i);
        begin : t2_check
            integer fail2;
            fail2 = 0;
            for (i = 0; i < 16; i = i + 1) begin
                read_reg(i[3:0]);
                if (rd_data !== (8'hAA + i)) begin
                    $display("  FAIL reg[%0d]: got 0x%02h exp 0x%02h", i, rd_data, 8'hAA+i);
                    fail2 = 1; errors = errors + 1;
                end
            end
            if (!fail2) $display("  All 16 reg write/read  PASS");
        end

        // ── T3: Reg[0] bit-decode ─────────────────────────────
        $display("\n[T3] Reg[0] decode: 0x05 → conv1=1,conv2=0,dense=1,secure=0");
        write_reg(4'd0, 8'h05);     // 0000_0101
        ck(); ck();
        $display("  conv1=%0d conv2=%0d dense=%0d secure=%0d  %s",
                  cfg_conv1_en, cfg_conv2_en, cfg_dense_en, cfg_secure_en,
                  (cfg_conv1_en && !cfg_conv2_en && cfg_dense_en && !cfg_secure_en)
                  ? "PASS" : "FAIL");
        if (!cfg_conv1_en || cfg_conv2_en || !cfg_dense_en || cfg_secure_en)
            errors = errors + 1;
        write_reg(4'd0, 8'h0F);     // Restore: all layers on

        // ── T4: Threshold register ────────────────────────────
        $display("\n[T4] Threshold register: write 0x60 (lower sensitivity)");
        write_reg(4'd3, 8'h60);
        ck(); ck();
        $display("  cfg_threshold=0x%02h (exp 0x60)  %s",
                  cfg_threshold, cfg_threshold == 8'h60 ? "PASS" : "FAIL");
        if (cfg_threshold !== 8'h60) errors = errors + 1;

        // ── T5: Key override flag ─────────────────────────────
        $display("\n[T5] Key override flag: reg[5] bit[0]=1");
        write_reg(4'd5, 8'h01);
        ck(); ck();
        $display("  key_override=%0d debug=%0d  %s",
                  cfg_key_override, cfg_debug_mode,
                  cfg_key_override ? "PASS" : "FAIL");
        if (!cfg_key_override) errors = errors + 1;

        // ── T6: Simultaneous write and read ───────────────────
        $display("\n[T6] Simultaneous write reg[2] + read reg[1]");
        rd_addr = 4'd1; wr_addr = 4'd2; wr_data = 8'hCC; wr_en = 1;
        ck(); wr_en = 0; ck();
        $display("  rd_data=0x%02h (read issued simultaneously with write to reg[2])", rd_data);

        // ── T7: Reset restores defaults ───────────────────────
        $display("\n[T7] Reset restores defaults");
        rst_n = 0; repeat(4) ck(); rst_n = 1; repeat(2) ck();
        $display("  threshold=0x%02h conv1=%0d enc_key=0x%02h  %s",
                  cfg_threshold, cfg_conv1_en, cfg_enc_key,
                  (cfg_threshold == 8'h80 && cfg_conv1_en && cfg_enc_key == 8'hA5)
                  ? "PASS" : "FAIL");
        if (cfg_threshold !== 8'h80 || !cfg_conv1_en || cfg_enc_key !== 8'hA5)
            errors = errors + 1;

        // ── Summary ───────────────────────────────────────────
        $display("\n==============================================");
        $display(" config_reg_block: Errors=%0d  %s",
                  errors, errors == 0 ? "ALL PASS ✓" : "FAIL ✗");
        $display("==============================================");
        $finish;
    end

endmodule
