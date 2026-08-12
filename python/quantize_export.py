"""
Loads fpga_cnn_weights.pth, quantizes every layer to signed INT8
(symmetric, per-tensor), reports the accuracy after quantization, and
writes the three weight .mem files DIRECTLY into ../rtl/ so they land
next to the Verilog files automatically.

Address layout matches the RTL exactly:
  conv1_weights.mem : 72   lines -> addr = f*INPUT_CH1*9 + c*9 + ky*3 + kx
                                       (f=0..7, c=0,     ky/kx=0..2)
  conv2_weights.mem : 1152 lines -> addr = f*INPUT_CH2*9 + c*9 + ky*3 + kx
                                       (f=0..15, c=0..7,  ky/kx=0..2)
  fc_weights.mem    : 4000 lines -> addr = out*400 + in
                                       (out=0..9, in=0..399)

These match PyTorch's default out_channels-major flatten order, so no
reordering is needed beyond a straight .flatten().

Run: python quantize_export.py
"""
import os
import torch
from train_model import FPGACNN
from torchvision import datasets, transforms
from torch.utils.data import DataLoader


# Where to drop the .mem files. Resolving ../rtl relative to this script
# means it works no matter what your current directory is.
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
RTL_DIR    = os.path.normpath(os.path.join(SCRIPT_DIR, "..", "rtl"))


def quantize_symmetric(tensor):
    max_val = torch.max(torch.abs(tensor))
    scale = 127.0 / (max_val + 1e-7)
    q = torch.round(tensor * scale)
    q = torch.clamp(q, -128, 127)
    return q.to(torch.int8), scale.item()


def write_mem_file(int8_tensor, filepath):
    vals = int8_tensor.flatten().tolist()
    with open(filepath, "w") as f:
        for v in vals:
            f.write(f"{(v & 0xFF):02X}\n")
    print(f"  Wrote {len(vals):>5d} values -> {filepath}")


def evaluate(model, loader):
    model.eval()
    correct, total = 0, 0
    with torch.no_grad():
        for images, labels in loader:
            outputs = model(images)
            _, predicted = torch.max(outputs.data, 1)
            total   += labels.size(0)
            correct += (predicted == labels).sum().item()
    return 100 * correct / total


def main():
    print(f"Output directory for .mem files: {RTL_DIR}")
    os.makedirs(RTL_DIR, exist_ok=True)

    model = FPGACNN()
    model.load_state_dict(torch.load("fpga_cnn_weights.pth", map_location="cpu"))
    model.eval()

    conv1_q, conv1_scale = quantize_symmetric(model.conv1.weight.data)
    conv2_q, conv2_scale = quantize_symmetric(model.conv2.weight.data)
    fc_q,    fc_scale    = quantize_symmetric(model.fc.weight.data)

    print(f"conv1 scale: {conv1_scale:.4f}  shape: {tuple(conv1_q.shape)}  numel: {conv1_q.numel()}")
    print(f"conv2 scale: {conv2_scale:.4f}  shape: {tuple(conv2_q.shape)}  numel: {conv2_q.numel()}")
    print(f"fc    scale: {fc_scale:.4f}  shape: {tuple(fc_q.shape)}  numel: {fc_q.numel()}")

    write_mem_file(conv1_q, os.path.join(RTL_DIR, "conv1_weights.mem"))
    write_mem_file(conv2_q, os.path.join(RTL_DIR, "conv2_weights.mem"))
    write_mem_file(fc_q,    os.path.join(RTL_DIR, "fc_weights.mem"))

    # Sanity-check accuracy drop from quantization (weights only, fake-quant forward pass)
    transform = transforms.Compose([transforms.ToTensor()])
    test_dataset = datasets.MNIST(root="./data", train=False, download=True, transform=transform)
    test_loader  = DataLoader(test_dataset, batch_size=256, shuffle=False)

    print(f"\nFloat32 baseline accuracy:    {evaluate(model, test_loader):.2f}%")

    with torch.no_grad():
        model.conv1.weight.data = conv1_q.float() / conv1_scale
        model.conv2.weight.data = conv2_q.float() / conv2_scale
        model.fc.weight.data    = fc_q.float()    / fc_scale
    print(f"Simulated INT8-weight accuracy: {evaluate(model, test_loader):.2f}%")

    print("\nDone. The .mem files are now in:")
    print(f"  {RTL_DIR}")
    print("Vivado will pick them up automatically via $readmemh when you add the")
    print("rtl/ folder as a design source.")


if __name__ == "__main__":
    main()
