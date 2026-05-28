# =============================================================================
# create_project.tcl
# Usage: In Vivado Tcl Console → source scripts/create_project.tcl
# Target: xc7z020clg400-1  (Zybo Z7-20)
# =============================================================================

set proj  "ecg_cnn_accelerator"
set dir   "./vivado_project"
set part  "xc7z020clg400-1"

create_project $proj $dir -part $part

# ── RTL sources ───────────────────────────────────────────────────────────────
foreach sv_file {
    rtl/input_buffer.sv
    rtl/conv1d_engine.sv
    rtl/maxpool1d_unit.sv
    rtl/dense_engine.sv
    rtl/sigmoid_classifier.sv
    rtl/secure_alert.sv
    rtl/config_reg_block.sv
    rtl/ecg_pipeline_top.sv
} {
    add_files -norecurse $sv_file
    set_property file_type SystemVerilog [get_files [file tail $sv_file]]
}

set_property top ecg_pipeline_top [get_filesets sources_1]

# ── Simulation sources ────────────────────────────────────────────────────────
foreach tb_file {
    tb/input_buffer_tb.sv
    tb/conv1d_engine_tb.sv
    tb/maxpool1d_unit_tb.sv
    tb/dense_engine_tb.sv
    tb/sigmoid_classifier_tb.sv
    tb/secure_alert_tb.sv
    tb/config_reg_block_tb.sv
    tb/ecg_pipeline_top_tb.sv
} {
    add_files -fileset sim_1 -norecurse $tb_file
    set_property file_type SystemVerilog [get_files [file tail $tb_file]]
}

set_property top ecg_pipeline_top_tb [get_filesets sim_1]

# ── Hex files: add weights/ folder to XSim search path ───────────────────────
# XSim looks for $readmemh files relative to the simulation working directory.
# Either copy weights/*.hex into the sim launch dir, OR set this path:
set_property include_dirs [list [file normalize weights/]] [get_filesets sim_1]
set_property include_dirs [list [file normalize weights/]] [get_filesets sources_1]

# ── Constraints ───────────────────────────────────────────────────────────────
add_files -fileset constrs_1 -norecurse constraints/ecg_constr.xdc

# ── Synthesis settings (preserve original ~3.45% LUT result) ─────────────────
set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY rebuilt [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.ARGS.RETIMING          true    [get_runs synth_1]
set_property STEPS.OPT_DESIGN.IS_ENABLED               true    [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED          true    [get_runs impl_1]

puts ""
puts "Project created for: xc7z020clg400-1 (Zybo Z7-20)"
puts ""
puts "SIMULATION STEPS:"
puts "  1. Copy weights/*.hex to Vivado project sim working dir"
puts "     (or Vivado will look in the weights/ folder set above)"
puts "  2. Flow → Run Simulation → Run Behavioral Simulation"
puts "  3. Select top = ecg_pipeline_top_tb"
puts "  4. Verify all 6 tests PASS in Tcl console"
puts ""
puts "SYNTHESIS STEPS:"
puts "  5. Flow → Run Synthesis"
puts "  6. Flow → Run Implementation"
puts "  7. Reports → Resource Utilization (target: LUT≈3.45% BRAM=0 DSP=0)"
puts "  8. Reports → Timing Summary     (target: WNS≥+0.435ns)"
puts "  9. Flow → Generate Bitstream    (Round 2 ready)"
puts ""
puts "EXPECTED RESULTS:"
puts "  LUTs ≈ 1,834 (3.45%)  |  note: may vary ±2% with weight values"
puts "  FFs  ≈ 946   (0.89%)  |  BRAM=0  DSP=0  BUFG=1"
puts "  WNS  ≥ +0.435 ns      |  Fmax ≥ 104.5 MHz"
puts "  DRC violations: 0"

start_gui
