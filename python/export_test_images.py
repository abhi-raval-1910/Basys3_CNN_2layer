"""
Exports a handful of real MNIST test images as PNG files you can feed
into stream_to_fpga.py. Saves them as digit_<label>_<index>.png.

Run: python export_test_images.py
"""
from torchvision import datasets
import os

OUT_DIR = "test_images"
NUM_PER_DIGIT = 2  # how many examples of each digit 0-9 to export

def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    test_dataset = datasets.MNIST(root="./data", train=False, download=True)

    counts = {d: 0 for d in range(10)}
    saved = 0
    for img, label in test_dataset:
        if counts[label] < NUM_PER_DIGIT:
            filename = f"{OUT_DIR}/digit_{label}_{counts[label]}.png"
            img.save(filename)  # img is already a PIL Image, 28x28 grayscale
            counts[label] += 1
            saved += 1
        if saved >= NUM_PER_DIGIT * 10:
            break

    print(f"Saved {saved} images to {OUT_DIR}/")
    print("Example: python stream_to_fpga.py --port COM3 --image test_images/digit_7_0.png")

if __name__ == "__main__":
    main()
