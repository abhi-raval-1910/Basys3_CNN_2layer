"""
Exports the first N MNIST test images as plain hex .mem files that the
Verilog testbench tb_top_known.v can load directly into the FPGA's
image RAM via $readmemh.

Each .mem file has exactly 784 lines (one 2-digit hex byte per pixel),
in raster order (row 0 left-to-right, then row 1, ... row 27).
Pixel values are 0-255 (white digit on black background, MNIST format).

Run:  python export_test_image_mem.py
Output: ../sim/test_image_0.mem ... ../sim/test_image_9.mem
        (plus a ../sim/test_image_labels.txt listing the labels)
"""
import os
from torchvision import datasets

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SIM_DIR    = os.path.normpath(os.path.join(SCRIPT_DIR, "..", "sim"))

NUM_IMAGES = 10  # export the first 10 MNIST test images


def main():
    os.makedirs(SIM_DIR, exist_ok=True)
    ds = datasets.MNIST(root="./data", train=False, download=True)

    labels = []
    for i in range(NUM_IMAGES):
        img, label = ds[i]                       # img is a PIL Image, 28x28 grayscale
        pixels = list(img.getdata())             # 784 values, 0-255
        assert len(pixels) == 784, f"image {i}: expected 784 pixels, got {len(pixels)}"

        fname = os.path.join(SIM_DIR, f"test_image_{i}.mem")
        with open(fname, "w") as f:
            for p in pixels:
                f.write(f"{p & 0xFF:02X}\n")
        labels.append(label)
        print(f"  Image {i}: label={label}  -> {fname}  (784 bytes)")

    # Also write a labels file for reference
    labels_path = os.path.join(SIM_DIR, "test_image_labels.txt")
    with open(labels_path, "w") as f:
        f.write("# index  label  (first 10 MNIST test images)\n")
        for i, label in enumerate(labels):
            f.write(f"{i} {label}\n")
    print(f"\nWrote labels to {labels_path}")
    print("\nThe first 10 MNIST test image labels are:")
    print(f"  index 0..9 -> labels {labels}")
    print("\nTo verify the FPGA in simulation:")
    print("  1. Use sim/tb_top_known.v as the simulation top")
    print("  2. Edit the EXPECTED_LABEL and IMAGE_FILE localparams in that file")
    print("     to match the image you want to test (e.g. image 0 has label 7)")
    print("  3. Run Behavioral Simulation -> should print PASS")


if __name__ == "__main__":
    main()
