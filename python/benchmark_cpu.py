"""
Runs the exact same FPGACNN model (2 conv layers + pool + FC) on the CPU
using PyTorch, and measures how long inference takes — both single-image
and batched — so you can compare it against the FPGA's measured hardware
time.

Two modes:
  1. If test_images/ (from export_test_images.py) exists, benchmarks on
     those real PNGs, printing the predicted digit for each.
  2. Otherwise, benchmarks on N random MNIST test images.

Run: python benchmark_cpu.py
"""
import os
import time
import glob
import torch
from PIL import Image
import numpy as np

from train_model import FPGACNN

WEIGHTS_FILE    = "fpga_cnn_weights.pth"
TEST_IMAGE_DIR   = "test_images"
NUM_WARMUP      = 5          # untimed runs first, to avoid cold-start noise
NUM_TIMED_RUNS  = 200        # single-image timing repeats, for a stable average
BATCH_SIZE      = 64         # for the batched-throughput measurement


def load_model():
    model = FPGACNN()
    if not os.path.exists(WEIGHTS_FILE):
        raise FileNotFoundError(
            f"{WEIGHTS_FILE} not found. Run train_model.py first."
        )
    model.load_state_dict(torch.load(WEIGHTS_FILE, map_location="cpu"))
    model.eval()
    torch.set_num_threads(1)  # fair single-core comparison against the FPGA
    return model


def load_test_images_from_dir(path):
    files = sorted(glob.glob(os.path.join(path, "*.png")))
    tensors, names = [], []
    for f in files:
        img = Image.open(f).convert("L").resize((28, 28))
        arr = np.array(img, dtype=np.float32) / 255.0
        tensors.append(torch.from_numpy(arr).unsqueeze(0))  # [1,28,28]
        names.append(os.path.basename(f))
    return tensors, names


def load_mnist_fallback(n=20):
    from torchvision import datasets, transforms
    transform = transforms.Compose([transforms.ToTensor()])
    ds = datasets.MNIST(root="./data", train=False, download=True, transform=transform)
    tensors, names = [], []
    for i in range(n):
        img, label = ds[i]
        tensors.append(img)  # already [1,28,28], 0-1 range
        names.append(f"mnist_test_{i}_label{label}")
    return tensors, names


@torch.no_grad()
def time_single_image(model, x):
    """x: [1,28,28] tensor. Returns (predicted_digit, elapsed_seconds)."""
    x = x.unsqueeze(0)  # add batch dim -> [1,1,28,28]
    start = time.perf_counter()
    out = model(x)
    elapsed = time.perf_counter() - start
    pred = int(torch.argmax(out, dim=1).item())
    return pred, elapsed


@torch.no_grad()
def time_batch(model, x_batch):
    start = time.perf_counter()
    out = model(x_batch)
    elapsed = time.perf_counter() - start
    preds = torch.argmax(out, dim=1).tolist()
    return preds, elapsed


def main():
    print("Loading model...")
    model = load_model()

    if os.path.isdir(TEST_IMAGE_DIR) and glob.glob(os.path.join(TEST_IMAGE_DIR, "*.png")):
        print(f"Using real test images from {TEST_IMAGE_DIR}/")
        tensors, names = load_test_images_from_dir(TEST_IMAGE_DIR)
    else:
        print(f"{TEST_IMAGE_DIR}/ not found -- falling back to MNIST test set.")
        tensors, names = load_mnist_fallback(n=20)

    print(f"Loaded {len(tensors)} test images.\n")

    # ---- Warm-up (not timed) ----
    for x in tensors[:min(NUM_WARMUP, len(tensors))]:
        time_single_image(model, x)

    # ---- Per-image predictions + individual timings ----
    print(f"{'Image':30s} {'Predicted':>10s} {'Time (ms)':>12s}")
    print("-" * 55)
    per_image_times = []
    for x, name in zip(tensors, names):
        pred, elapsed = time_single_image(model, x)
        per_image_times.append(elapsed)
        print(f"{name:30s} {pred:>10d} {elapsed*1000:>12.4f}")

    # ---- Stable average over many repeated single-image runs ----
    x0 = tensors[0]
    repeat_times = []
    for _ in range(NUM_TIMED_RUNS):
        _, elapsed = time_single_image(model, x0)
        repeat_times.append(elapsed)
    avg_ms = (sum(repeat_times) / len(repeat_times)) * 1000
    min_ms = min(repeat_times) * 1000
    max_ms = max(repeat_times) * 1000

    # ---- Batched throughput ----
    batch = torch.stack(tensors[:min(BATCH_SIZE, len(tensors))])
    if batch.dim() == 3:
        batch = batch.unsqueeze(1)
    _, batch_elapsed = time_batch(model, batch)
    per_image_in_batch_ms = (batch_elapsed / batch.shape[0]) * 1000

    print("\n" + "=" * 55)
    print("SUMMARY (CPU, PyTorch, single-threaded)")
    print("=" * 55)
    print(f"Single-image inference, avg of {NUM_TIMED_RUNS} runs: {avg_ms:.4f} ms")
    print(f"  min: {min_ms:.4f} ms   max: {max_ms:.4f} ms")
    print(f"Batched inference ({batch.shape[0]} images at once): "
          f"{per_image_in_batch_ms:.4f} ms/image ({batch_elapsed*1000:.2f} ms total)")

    print("\nFor comparison: the FPGA's parallel 9-MAC pipeline (2 conv layers)")
    print("measured in Vivado simulation is the number to compare against the")
    print("single-image number above. UART transfer time (~68 ms @ 115200 baud)")
    print("is a link-speed limitation, not a compute limitation.")


if __name__ == "__main__":
    main()
