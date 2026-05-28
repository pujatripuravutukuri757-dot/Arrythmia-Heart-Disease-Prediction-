ECG Arrhythmia Detection — FPGA Hardware Accelerator
FPGA Hackathon 2026 | Biomedical Systems | Team Name

Project Summary
Configurable low-latency 1D CNN accelerator for real-time ECG arrhythmia detection implemented in Verilog RTL on Zynq-7020 FPGA.

Architecture
Input(300) → Conv1D(8f,k5) → MaxPool → Conv1D(16f,k5) → MaxPool → Dense(1152→16) → Dense(16→1) → Sigmoid → Secure Alert

Key Results
Accuracy : 100% on test dataset
Latency : 1.44 ms (real-time budget: 4 ms)
Speedup : 35x over CPU
LUT usage : 4.3% of Zynq-7020
Throughput : 697 inferences/second
How to Run Simulation (Vivado)
Open Vivado → Create Project
Add rtl/*.v as Design Sources
Add tb/*.v as Simulation Sources
Add weights/*.hex and test_data/test_input.hex
Set ecg_pipeline_top_tb as simulation top
Run Behavioral Simulation → Run All
How to Run Simulation (ModelSim)
vsim -c -do sim/run_all_modelsim.do

File Structure
rtl/ → Verilog RTL source files tb/ → Testbenches weights/ → INT8 quantized weight hex files model/ → Python training & quantization sim/ → Simulation scripts docs/ → Report, diagrams, screenshots


---

