"""
quantize_and_export.py  —  INT8 Quantisation + HEX Export
==========================================================
Converts trained Keras model weights to INT8 hex files for RTL.

RETRAIN-PROOF DESIGN:
  - Validates line counts BEFORE writing any file
  - Errors immediately if architecture accidentally changed
  - Saves scale factors for documentation

WEIGHT VALUES vs LINE COUNTS:
  VALUES   : change every retrain (stochastic GD) — this is EXPECTED
  COUNTS   : NEVER change — fixed by architecture:
    conv1_w.hex : 40   (8 × 1 × 5)
    conv1_b.hex : 8
    conv2_w.hex : 640  (16 × 8 × 5)
    conv2_b.hex : 16
    dense_w.hex : 18432 (1152 × 16)
    dense_b.hex : 16
    out_w.hex   : 16
    out_b.hex   : 1

RTL MEMORY LAYOUT (must match $readmemh array shapes in ecg_pipeline_top.sv):
  conv1_w : [filter][channel][kernel]  = (8, 1, 5)   → transpose(2,1,0)
  conv2_w : [filter][channel][kernel]  = (16, 8, 5)  → transpose(2,1,0)
  dense_w : [flat_idx][out_neuron]     = (1152, 16)  → no transpose
  out_w   : [in_neuron][out]           = (16, 1)     → no transpose
"""

import numpy as np
import tensorflow as tf
import os
import sys
import json

MODEL_PATH = "../weights/ecg_model.h5"
OUTPUT_DIR = "../weights/"

EXPECTED = {
    "conv1_w.hex":  40,
    "conv1_b.hex":  8,
    "conv2_w.hex":  640,
    "conv2_b.hex":  16,
    "dense_w.hex":  18432,
    "dense_b.hex":  16,
    "out_w.hex":    16,
    "out_b.hex":    1,
}


def quantize_and_save(array, filename, verbose=True):
    scale = float(np.max(np.abs(array)))
    if scale < 1e-8:
        scale = 1.0
    w_q  = np.clip(np.round(array / scale * 127.0), -128, 127).astype(np.int8)
    flat = w_q.flatten()
    n    = len(flat)

    if filename in EXPECTED and n != EXPECTED[filename]:
        print(f"\nERROR: {filename} has {n} values — RTL expects {EXPECTED[filename]}")
        print("Architecture mismatch. Check train_model.py parameters.")
        sys.exit(1)

    os.makedirs(OUTPUT_DIR, exist_ok=True)
    with open(os.path.join(OUTPUT_DIR, filename), "w") as f:
        for val in flat:
            f.write(f"{int(val) & 0xFF:02X}\n")

    if verbose:
        nz  = np.sum(w_q != 0) / n * 100
        sat = np.sum(np.abs(w_q) == 127) / n * 100
        print(f"  {filename:15s}  {n:6d} lines  scale={scale:.4f}  "
              f"non-zero={nz:.1f}%  saturated={sat:.1f}%")
    return n, scale


def main():
    print(f"Loading: {MODEL_PATH}")
    model = tf.keras.models.load_model(MODEL_PATH)

    print("\nExporting weights:")
    print("-" * 65)

    scales   = {}
    exported = set()

    for layer in model.layers:
        ws = layer.get_weights()
        if len(ws) != 2:
            continue
        w, b = ws
        name = layer.name.lower()

        if "conv1d" in name and w.shape[-1] == 8:
            assert w.shape == (5, 1, 8), f"Conv1 shape: {w.shape}"
            w_rtl = w.transpose(2, 1, 0)   # (5,1,8) → (8,1,5)
            _, s = quantize_and_save(w_rtl, "conv1_w.hex")
            scales["conv1_w"] = s
            quantize_and_save(b, "conv1_b.hex")
            print(f"    Conv1: Keras{w.shape} → RTL{w_rtl.shape} [f,ch,k]")
            exported.add("conv1")

        elif "conv1d" in name and w.shape[-1] == 16:
            assert w.shape == (5, 8, 16), f"Conv2 shape: {w.shape}"
            w_rtl = w.transpose(2, 1, 0)   # (5,8,16) → (16,8,5)
            _, s = quantize_and_save(w_rtl, "conv2_w.hex")
            scales["conv2_w"] = s
            quantize_and_save(b, "conv2_b.hex")
            print(f"    Conv2: Keras{w.shape} → RTL{w_rtl.shape} [f,ch,k]")
            exported.add("conv2")

        elif "dense" in name and w.shape == (1152, 16):
            # dense_engine.sv: acc[o] += din * w[in_idx][o]
            # → w[flat_idx][out_neuron] — same as Keras (in, out), no transpose
            _, s = quantize_and_save(w, "dense_w.hex")
            scales["dense_w"] = s
            quantize_and_save(b, "dense_b.hex")
            print(f"    Dense1: Keras{w.shape} → RTL same [flat,out]")
            exported.add("dense1")

        elif "dense" in name and w.shape == (16, 1):
            _, s = quantize_and_save(w, "out_w.hex")
            scales["out_w"] = s
            quantize_and_save(b, "out_b.hex")
            print(f"    Dense2: Keras{w.shape} → RTL same [in,out]")
            exported.add("dense2")

    missing = {"conv1", "conv2", "dense1", "dense2"} - exported
    if missing:
        print(f"\nERROR: Layers not exported: {missing}")
        sys.exit(1)

    # Final verification
    print("\n" + "=" * 65)
    print("VERIFICATION:")
    all_ok = True
    for fname, exp in EXPECTED.items():
        fpath = os.path.join(OUTPUT_DIR, fname)
        if not os.path.exists(fpath):
            print(f"  MISSING : {fname}"); all_ok = False; continue
        with open(fpath) as f:
            actual = sum(1 for _ in f)
        ok = actual == exp
        print(f"  {'OK    ' if ok else 'ERROR '}: {fname:15s}  {actual:6d} lines (exp {exp})")
        if not ok:
            all_ok = False

    print("\nQuantisation scales (>0.01 = good precision):")
    for name, scale in scales.items():
        warn = "  ← LOW" if scale < 0.01 else ""
        print(f"  {name}: {scale:.4f}{warn}")

    with open(os.path.join(OUTPUT_DIR, "quant_scales.json"), "w") as f:
        json.dump(scales, f, indent=2)

    print("\n" + "=" * 65)
    if all_ok:
        print("ALL HEX FILES VERIFIED — copy weights/*.hex to Vivado sim folder.")
        print("")
        print("Note: weight VALUES changed from previous run — that is expected.")
        print("Note: LUT count may vary ±2% due to Vivado constant optimisation.")
    else:
        print("ERRORS — do NOT proceed to synthesis.")
        sys.exit(1)


if __name__ == "__main__":
    main()
