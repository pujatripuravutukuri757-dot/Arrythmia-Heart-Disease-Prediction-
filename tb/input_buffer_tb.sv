// ============================================================
// Testbench: input_buffer_tb.sv
// DUT: input_buffer.sv
//
// Tests:
//   T1: Write DEPTH=300 samples → full + buffer_ready
//   T2: Write when full → overflow_flag, no crash
//   T3: Random-access read vs shadow array
//   T4: Sequential read (seq_rd_en) drains buffer
//   T5: Clear → empty + re-fill
//
// Interface matches input_buffer.sv exactly.
// ============================================================
`timescale 1ns/1ps

module input_buffer_tb;

    localparam DEPTH  = 300;
    localparam DATA_W = 8;
    localparam CLK_P  = 10;

    // ── DUT ports ─────────────────────────────────────────────
    reg  clk, rst_n, clear;
    reg  wr_en;
    reg  signed [DATA_W-1:0] wr_data;
    wire full, overflow_flag, empty, buffer_ready;

    reg  rd_en;
    reg  [$clog2(DEPTH)-1:0] rd_addr;
    wire signed [DATA_W-1:0] rd_data;

    reg  seq_rd_en;
    wire signed [DATA_W-1:0] seq_rd_data;
    wire [$clog2(DEPTH):0]   sample_count;

    // ── DUT ───────────────────────────────────────────────────
    input_buffer #(.DEPTH(DEPTH), .DATA_W(DATA_W)) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .clear        (clear),
        .wr_en        (wr_en),
        .wr_data      (wr_data),
        .full         (full),
        .overflow_flag(overflow_flag),
        .rd_en        (rd_en),
        .rd_addr      (rd_addr),
        .rd_data      (rd_data),
        .seq_rd_en    (seq_rd_en),
        .seq_rd_data  (seq_rd_data),
        .empty        (empty),
        .sample_count (sample_count),
        .buffer_ready (buffer_ready)
    );

    // ── Clock ─────────────────────────────────────────────────
    initial clk = 0;
    always #(CLK_P/2) clk = ~clk;

    initial begin
        $dumpfile("input_buffer.vcd");
        $dumpvars(0, input_buffer_tb);
    end

    // ── Helpers ───────────────────────────────────────────────
    integer i, errors;
    reg signed [DATA_W-1:0] shadow [0:DEPTH-1]; // mirrors what we write

    task ck;
        begin @(posedge clk); #1; end
    endtask

    task reset_dut;
        begin
            rst_n = 0; clear = 0; wr_en = 0; rd_en = 0;
            seq_rd_en = 0; wr_data = 0; rd_addr = 0;
            repeat(4) ck();
            rst_n = 1;
            repeat(2) ck();
        end
    endtask

    // ── Main ──────────────────────────────────────────────────
    initial begin
        errors = 0;
        $display("==============================================");
        $display(" TB: input_buffer  DEPTH=%0d  DATA_W=%0d", DEPTH, DATA_W);
        $display("==============================================");

        reset_dut();

        // ── T1: Write DEPTH samples, check full + buffer_ready ──
        $display("\n[T1] Write %0d samples → full + buffer_ready", DEPTH);
        for (i = 0; i < DEPTH; i = i + 1) begin
            wr_data  = $signed(i - 128);    // pattern: -128 → +127
            shadow[i] = wr_data;
            wr_en = 1; ck(); wr_en = 0;
        end
        ck();
        if (!full)          begin $display("  FAIL: full not asserted");         errors = errors + 1; end
        if (!buffer_ready)  begin $display("  FAIL: buffer_ready not asserted"); errors = errors + 1; end
        if (sample_count != DEPTH) begin
            $display("  FAIL: sample_count=%0d (exp %0d)", sample_count, DEPTH);
            errors = errors + 1;
        end
        $display("  full=%0d ready=%0d count=%0d  %s",
                  full, buffer_ready, sample_count,
                  (full && buffer_ready && sample_count==DEPTH) ? "PASS" : "FAIL");

        // ── T2: Write when full → overflow, no crash ───────────
        $display("\n[T2] Write when full → overflow_flag");
        wr_data = 8'h55; wr_en = 1; ck(); wr_en = 0; ck();
        if (!overflow_flag) begin
            $display("  FAIL: overflow_flag not set"); errors = errors + 1;
        end
        $display("  overflow_flag=%0d  %s", overflow_flag, overflow_flag ? "PASS" : "FAIL");

        // ── T3: Random-access read vs shadow ───────────────────
        $display("\n[T3] Random-access read (every 30th sample)");
        begin : t3_block
            integer fail_t3;
            fail_t3 = 0;
            for (i = 0; i < 10; i = i + 1) begin
                rd_addr = i * 30;
                rd_en   = 1; ck(); rd_en = 0;
                // rd_data is combinational — valid same cycle
                if (rd_data !== shadow[i*30]) begin
                    $display("  FAIL addr=%0d: got %0d exp %0d",
                              rd_addr, $signed(rd_data), $signed(shadow[i*30]));
                    fail_t3 = fail_t3 + 1;
                    errors  = errors + 1;
                end
            end
            if (fail_t3 == 0)
                $display("  10 spot-checks PASS");
        end

        // ── T4: Sequential read drains buffer ──────────────────
        $display("\n[T4] Sequential read: drain 10 samples");
        begin : t4_block
            integer count_before;
            count_before = sample_count;
            for (i = 0; i < 10; i = i + 1) begin
                seq_rd_en = 1; ck(); seq_rd_en = 0;
                // seq_rd_data valid 1 cycle after seq_rd_en
                ck();
                $display("  seq[%0d] = %0d", i, $signed(seq_rd_data));
            end
            if (sample_count == count_before - 10)
                $display("  sample_count reduced to %0d  PASS", sample_count);
            else begin
                $display("  FAIL: sample_count=%0d (exp %0d)",
                          sample_count, count_before - 10);
                errors = errors + 1;
            end
        end

        // ── T5: Clear → empty, then re-fill ───────────────────
        $display("\n[T5] Clear + re-fill");
        clear = 1; ck(); clear = 0; ck();
        if (!empty) begin $display("  FAIL: not empty after clear"); errors = errors + 1; end
        if (full)   begin $display("  FAIL: full after clear");      errors = errors + 1; end

        // Write 5 fresh samples
        for (i = 0; i < 5; i = i + 1) begin
            wr_data = i + 1; wr_en = 1; ck(); wr_en = 0;
        end
        ck();
        if (sample_count !== 5) begin
            $display("  FAIL: count after refill=%0d (exp 5)", sample_count);
            errors = errors + 1;
        end
        $display("  empty after clear=%0d, count after refill=%0d  %s",
                  empty, sample_count, (sample_count==5) ? "PASS" : "FAIL");

        // ── Summary ───────────────────────────────────────────
        $display("\n==============================================");
        $display(" input_buffer: Errors=%0d  %s",
                  errors, errors==0 ? "ALL PASS ✓" : "FAIL ✗");
        $display("==============================================");
        $finish;
    end

endmodule
