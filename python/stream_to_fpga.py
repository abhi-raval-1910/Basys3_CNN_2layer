"""
Streams one 28x28 grayscale image over UART to the Basys 3 at 115200 baud.
Requires: pip install pyserial opencv-python numpy

Usage:
    python stream_to_fpga.py --port COM3 --image digit.png
"""
import argparse
import time
import numpy as np
import serial
import cv2


def load_image(path):
    img = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
    if img is None:
        raise FileNotFoundError(f"Could not read image: {path}")
    img = cv2.resize(img, (28, 28))
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True, help="e.g. COM3 or /dev/ttyUSB1")
    ap.add_argument("--image", required=True, help="path to a 28x28-ish grayscale digit image")
    ap.add_argument("--baud", type=int, default=115200)
    args = ap.parse_args()

    img = load_image(args.image)
    pixels = img.flatten().astype(np.uint8)
    assert pixels.size == 784, "Image must flatten to exactly 784 pixels"

    print(f"Opening {args.port} @ {args.baud} baud...")
    with serial.Serial(args.port, args.baud, timeout=1) as ser:
        time.sleep(2)  # let the board settle after DTR toggling
        n = ser.write(bytearray(pixels))
        print(f"Sent {n} bytes. Watch the Basys 3 7-segment display for the predicted digit.")


if __name__ == "__main__":
    main()
