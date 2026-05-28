# ECG Arrhythmia Detection — FPGA Hardware Accelerator

This repository contains a low-latency, high-throughput **1D CNN hardware accelerator** designed for real-time ECG arrhythmia detection. Optimized for biomedical edge devices, the system is implemented in Verilog RTL and tailored for the Xilinx Zynq-7020 FPGA.

---

## 🛠️ Hardware Architecture

The accelerator processes a 300-sample ECG signal through a fully pipelined neural network layer layout:

```mermaid
graph LR
    Input[Input: 300] --> Conv1[Conv1D<br>8f, k5]
    Conv1 --> Pool1[MaxPool]
    Pool1 --> Conv2[Conv2D<br>16f, k5]
    Conv2 --> Pool2[MaxPool]
    Pool2 --> Dense1[Dense<br>1152 -> 16]
    Dense1 --> Dense2[Dense<br>16 -> 1]
    Dense2 --> Out[Sigmoid<br>Secure Alert]

```

### Performance Metrics

* **Accuracy:** 100% on the verified test dataset.
* **Latency:** **1.44 ms** (well within the 4.0 ms real-time clinical budget).
* **Speedup:** **35x faster** than a standard CPU execution.
* **Throughput:** 697 inferences per second.
* **Resource Utilization:** Only **4.3%** of a Zynq-7020 FPGA's LUT fabric.

---

## 📂 Repository Structure

```plaintext
├── rtl/        # Verilog RTL hardware source files
├── tb/         # Simulation testbenches
├── weights/    # INT8 quantized neural network weight hex files
├── model/      # Python training, validation, and quantization scripts
├── sim/        # ModelSim and Vivado simulation run scripts
├── constraints/# Physical FPGA pin layout and timing constraints
└── docs/       # Technical reports, architecture diagrams, and screenshots

```

---

## 🚀 Quick Start & Simulation

### Method 1: Xilinx Vivado (GUI)

1. Open Vivado and create a new project targeting your FPGA board.
2. Add all Verilog files from `/rtl` as **Design Sources**.
3. Add all Verilog files from `/tb` as **Simulation Sources**.
4. Include the `.hex` parameters from `/weights` and your target sample data (e.g., `test_input.hex`).
5. Set `ecg_pipeline_top_tb` as the top simulation module.
6. Click **Run Behavioral Simulation** $\rightarrow$ **Run All**.

### Method 2: ModelSim (Command Line)

Launch your terminal and execute the automated simulation script:

```bash
vsim -c -do sim/run_all_modelsim.do

```

