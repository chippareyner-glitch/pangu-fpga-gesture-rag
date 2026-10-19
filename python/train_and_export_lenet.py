#!/usr/bin/env python3
"""
train_and_export_lenet.py
-------------------------
Lightweight 2-Channel CNN for FPGA Gesture Recognition & Automated INT8 Hardware Exporter.
- Input: 32x32 x 2 Channels (Ch0: Static Hand Mask, Ch1: XOR Temporal Difference)
- Output: 4 Classes (0: Hover/Point, 1: Thumb-Click, 2: Fist/Grab, 3: Open Palm)
- Exports: Verilog ROM module (.v), PanGo .hex, and Xilinx .coe memory files.
"""

import os
import math
import numpy as np
import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import TensorDataset, DataLoader

# =====================================================================
# 1. Ultra-Lightweight CNN Architecture (Tailored for Pure Logic FPGA)
# =====================================================================
class MicroGestureCNN(nn.Module):
    def __init__(self, num_classes=4):
        super(MicroGestureCNN, self).__init__()
        # Conv1: 2 in-channels -> 4 filters, 3x3 kernel, stride 1, padding 1
        self.conv1 = nn.Conv2d(2, 4, kernel_size=3, stride=1, padding=1, bias=True)
        self.relu1 = nn.ReLU()
        self.pool1 = nn.MaxPool2d(kernel_size=2, stride=2) # 32x32 -> 16x16
        
        # Conv2: 4 in-channels -> 8 filters, 3x3 kernel, stride 1, padding 1
        self.conv2 = nn.Conv2d(4, 8, kernel_size=3, stride=1, padding=1, bias=True)
        self.relu2 = nn.ReLU()
        self.pool2 = nn.MaxPool2d(kernel_size=2, stride=2) # 16x16 -> 8x8
        
        # FC Layers
        # 8 channels * 8 * 8 = 512 inputs
        self.fc1 = nn.Linear(8 * 8 * 8, 16, bias=True)
        self.relu3 = nn.ReLU()
        self.fc2 = nn.Linear(16, num_classes, bias=True)

    def forward(self, x):
        x = self.pool1(self.relu1(self.conv1(x)))
        x = self.pool2(self.relu2(self.conv2(x)))
        x = x.view(x.size(0), -1)
        x = self.relu3(self.fc1(x))
        x = self.fc2(x)
        return x

# =====================================================================
# 2. Synthetic Dataset Generator (For zero-dependency instant testing)
# =====================================================================
def generate_synthetic_gestures(samples_per_class=200):
    """
    Synthesizes binary geometric representations:
    Class 0 (Hover): Single vertical index finger bar. XOR diff is empty.
    Class 1 (Thumb-Click): Index finger bar + lateral thumb hotspot in XOR diff.
    Class 2 (Grab): Solid filled compact square / circle.
    Class 3 (Open Palm): Broad 5-ray palm structure.
    """
    total = samples_per_class * 4
    x_data = np.zeros((total, 2, 32, 32), dtype=np.float32)
    y_data = np.zeros((total,), dtype=np.int64)

    idx = 0
    for cls in range(4):
        for s in range(samples_per_class):
            noise = np.random.binomial(1, 0.02, (32, 32)).astype(np.float32)
            if cls == 0: # Hover: Index finger
                x_data[idx, 0, 8:28, 14:18] = 1.0 # finger
                # Ch1 has near zero diff
                x_data[idx, 1] = noise
            elif cls == 1: # Thumb-Click: Finger + Thumb hotspot on diff
                x_data[idx, 0, 8:28, 14:18] = 1.0
                x_data[idx, 0, 18:24, 8:14] = 1.0  # thumb
                x_data[idx, 1, 18:24, 8:14] = 1.0  # dynamic hotspot
            elif cls == 2: # Grab / Fist
                x_data[idx, 0, 10:26, 10:24] = 1.0
                x_data[idx, 1, 10:26, 10:24] = np.random.binomial(1, 0.1, (16, 14))
            elif cls == 3: # Open Palm
                x_data[idx, 0, 14:28, 8:26] = 1.0
                for f in [8, 12, 16, 20, 24]:
                    x_data[idx, 0, 6:14, f:f+2] = 1.0
            
            # Apply slight jitter & noise
            x_data[idx, 0] = np.clip(x_data[idx, 0] + noise, 0.0, 1.0)
            y_data[idx] = cls
            idx += 1

    return torch.tensor(x_data), torch.tensor(y_data)

# =====================================================================
# 3. Training & INT8 Quantization Routine
# =====================================================================
def quantize_to_int8(tensor, scale=128.0):
    """Clamps and converts FP32 weights to signed INT8 [-128, 127]."""
    quant = np.round(tensor.detach().cpu().numpy() * scale)
    return np.clip(quant, -128, 127).astype(np.int8)

def export_verilog_rom(model, out_dir="."):
    """Exports model parameters to synthesizable Verilog ROM and memory init files."""
    os.makedirs(out_dir, exist_ok=True)
    
    scale = 128.0 # Scale factor = 2^7
    weights = {}
    for name, param in model.named_parameters():
        q = quantize_to_int8(param, scale=scale)
        weights[name] = q
        print(f"[*] Quantized {name:15s} Shape: {str(q.shape):15s} Range: [{q.min()}, {q.max()}]")

    # Flatten all weights into a continuous memory stream
    flat_bytes = []
    metadata = []
    cur_offset = 0
    for name, arr in weights.items():
        flat = arr.flatten().tolist()
        length = len(flat)
        metadata.append((name, cur_offset, length))
        cur_offset += length
        flat_bytes.extend(flat)

    # 1. Export PanGo .hex file
    hex_path = os.path.join(out_dir, "weights.hex")
    with open(hex_path, "w") as f:
        for b in flat_bytes:
            # 8-bit two's complement hex
            val = b & 0xFF
            f.write(f"{val:02X}\n")
    print(f"[+] Wrote PanGo PDS hex file: {hex_path} (Total weights: {len(flat_bytes)} bytes)")

    # 2. Export Xilinx .coe file
    coe_path = os.path.join(out_dir, "weights.coe")
    with open(coe_path, "w") as f:
        f.write("memory_initialization_radix=16;\n")
        f.write("memory_initialization_vector=\n")
        hex_strs = [f"{b & 0xFF:02X}" for b in flat_bytes]
        f.write(",\n".join(hex_strs) + ";\n")
    print(f"[+] Wrote Xilinx COE file: {coe_path}")

    # 3. Export synthesizable Verilog ROM module
    verilog_path = os.path.join(out_dir, "weights_rom.v")
    with open(verilog_path, "w") as f:
        f.write("// =============================================================================\n")
        f.write("// Auto-generated Quantized Weights ROM for MicroGestureCNN\n")
        f.write(f"// Total weights: {len(flat_bytes)} bytes | Quantization: Signed INT8 (Scale=128)\n")
        f.write("// =============================================================================\n\n")
        f.write("`timescale 1ns / 1ps\n\n")
        f.write(f"module weights_rom #(\n")
        f.write(f"    parameter ADDR_WIDTH = {math.ceil(math.log2(len(flat_bytes)))},\n")
        f.write(f"    parameter DATA_WIDTH = 8\n")
        f.write(f")(\n")
        f.write(f"    input  wire                  clk,\n")
        f.write(f"    input  wire [ADDR_WIDTH-1:0] addr,\n")
        f.write(f"    output reg  signed [7:0]     q\n")
        f.write(f");\n\n")
        f.write(f"    // Memory table\n")
        f.write(f"    reg signed [7:0] mem [0:{len(flat_bytes)-1}];\n\n")
        f.write(f"    initial begin\n")
        f.write(f'        $readmemh("weights.hex", mem);\n')
        f.write(f"    end\n\n")
        f.write(f"    always @(posedge clk) begin\n")
        f.write(f"        q <= mem[addr];\n")
        f.write(f"    end\n\n")
        f.write(f"endmodule\n\n")
        f.write("/* Memory Map:\n")
        for name, off, length in metadata:
            f.write(f"   - {name:20s}: offset {off:6d} to {off+length-1:6d} (len: {length})\n")
        f.write("*/\n")
    print(f"[+] Wrote Verilog ROM module: {verilog_path}")

def main():
    print("=== Training Lightweight 2-Channel CNN for FPGA Gesture Recognition ===")
    x_train, y_train = generate_synthetic_gestures(samples_per_class=300)
    dataset = TensorDataset(x_train, y_train)
    loader = DataLoader(dataset, batch_size=32, shuffle=True)

    model = MicroGestureCNN(num_classes=4)
    criterion = nn.CrossEntropyLoss()
    optimizer = optim.Adam(model.parameters(), lr=0.003)

    model.train()
    for epoch in range(15):
        total_loss = 0.0
        correct = 0
        total = 0
        for batch_x, batch_y in loader:
            optimizer.zero_grad()
            out = model(batch_x)
            loss = criterion(out, batch_y)
            loss.backward()
            optimizer.step()
            total_loss += loss.item()
            preds = out.argmax(dim=1)
            correct += (preds == batch_y).sum().item()
            total += batch_y.size(0)
        acc = correct / total * 100.0
        if (epoch + 1) % 5 == 0 or epoch == 0:
            print(f"Epoch [{epoch+1:2d}/15] Loss: {total_loss/len(loader):.4f} Acc: {acc:.2f}%")

    print("\n=== Model Training Complete! Exporting Hardware Quantized Weights ===")
    export_dir = os.path.dirname(os.path.abspath(__file__))
    export_verilog_rom(model, out_dir=export_dir)
    print("\n[SUCCESS] Hardware assets successfully generated!")

if __name__ == "__main__":
    main()
