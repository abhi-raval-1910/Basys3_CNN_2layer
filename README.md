# CNN_FPGA — Basys 3 Two-Layer CNN Digit Classifier (Parallel 9-MAC)

## What this is

A **2-conv-layer + 2-maxpool + FC** MNIST digit classifier running as real
Verilog hardware on a Basys 3 (Artix-7 XC7A35T-1CPG236C). Each conv layer
uses a **streaming line-buffer + 9-MAC parallel array** (9 DSP48E1s per
conv instance, 18 total — well within the 90-DSP budget).

```
28x28 image
  -> Conv1(1->8,  3x3) -> ReLU -> MaxPool(2x2)   # 26x26x8 -> 13x13x8
  -> Conv2(8->16, 3x3) -> ReLU -> MaxPool(2x2)   # 11x11x16 -> 5x5x16 = 400
  -> FC(400 -> 10)
  -> Argmax -> 7-seg digit + LEDs
```

**Two upgrades over the single-conv / single-MAC starter project:**

1. **Second conv layer.** The model is now Conv1(1→8) → Pool → Conv2(8→16) →
   Pool → FC(400→10). All engines (`conv_engine.v`, `pool_engine.v`,
   `fc_engine.v`) are fully parameterized over `INPUT_CH`, `OUTPUT_CH`,
   `INPUT_H`, `INPUT_W`, `OUTPUT_H`, `OUTPUT_W`, weight depth, and address
   widths.

2. **Parallel 9-MAC streaming conv.** Each `conv_engine` instance replaces
   the old sequential single-MAC loop with:
   - A **3-row line buffer** held in flip-flops (per channel), fed by a
     single raster-order stream from input RAM. The 3×3 window is read
     combinationally — no RAM reads during compute.
   - A **9-MAC array** (9 parallel signed 8×8 multipliers + adder tree)
     that fires in a single cycle for one (filter, input_channel) pair.
     Vivado infers 9 DSP48E1s per instance.

   Compute flow per output pixel:
   ```
   for each filter f in 0..OUTPUT_CH-1:
       acc = 0
       for each input channel c in 0..INPUT_CH-1:
           load 9 weights for (f, c) from weight ROM   # ~10 cycles
           partial = sum(window[c][k] * weight[k])     # 9 DSPs, 1 cycle
           acc += partial
       write ReLU(saturate(acc >> SHIFT)) to conv_out RAM
   ```

## File map

```
CNN_FPGA/
├── rtl/
│   ├── dp_ram.v           - generic dual-port RAM (Vivado infers BRAM)
│   ├── weight_rom.v       - generic weight ROM, loaded from a .mem hex file
│   ├── uart_rx.v          - 115200 baud UART receiver
│   ├── conv_engine.v      - PARAMETERIZED + streaming line-buffer + 9-MAC
│   ├── pool_engine.v      - PARAMETERIZED 2x2 max pool
│   ├── fc_engine.v        - PARAMETERIZED fully connected layer
│   ├── argmax10.v         - picks the highest-scoring digit
│   ├── display_7seg.v     - drives the 7-segment display
│   ├── top.v              - wires everything together + 12-state master FSM
│   ├── conv1_weights.mem  - 72 lines   (8 filters x 1 ch x 9)
│   ├── conv2_weights.mem  - 1152 lines (16 filters x 8 ch x 9)
│   └── fc_weights.mem     - 4000 lines (10 outputs x 400 inputs)
├── constraints/
│   └── basys3.xdc         - pin mapping (unchanged)
├── python/
│   ├── train_model.py     - trains the matching 2-conv PyTorch model (12 epochs, StepLR)
│   ├── quantize_export.py - quantizes to INT8, writes .mem files DIRECTLY into ../rtl/
│   ├── stream_to_fpga.py  - sends a 28x28 image over UART to the board
│   ├── export_test_images.py - saves sample MNIST images as PNGs
│   └── benchmark_cpu.py   - CPU baseline timing for the same model
├── sim/
│   ├── tb_top.v           - basic testbench (run BEFORE hardware)
│   └── tb_timing.v        - per-stage timing testbench
└── README.md              - this file
```

## Step-by-step

### 1. (Optional but recommended) Re-train the model
```bash
cd python
pip install torch torchvision
python train_model.py
```
Trains for 12 epochs with Adam(lr=0.001) and StepLR(step_size=4, gamma=0.5).
Test accuracy lands ~98%. Saves `fpga_cnn_weights.pth`.

### 2. (Optional) Re-export weights
```bash
python quantize_export.py
```
This quantizes every layer to signed INT8 (symmetric, per-tensor), reports
the INT8-simulated accuracy, and writes the three `.mem` files **directly
into `../rtl/`** — no manual copying needed:
- `conv1_weights.mem` (72 lines)
- `conv2_weights.mem` (1152 lines)
- `fc_weights.mem` (4000 lines)

The repo already ships with a pre-trained set of `.mem` files in `rtl/`, so
you can skip steps 1–2 if you just want to run the project.

### 3. Create the Vivado project
- Vivado → Create Project → RTL Project.
- Part: search `xc7a35tcpg236-1` (the Basys 3's exact part).
- Add Sources → Add or create design sources → add **every file in `rtl/`**
  (including the three `.mem` files — add them as Design Sources too;
  Vivado needs them on the synthesis search path for `$readmemh`).
- Add Sources → Add or create constraints → add `constraints/basys3.xdc`.
- Add Sources → Add or create simulation sources → add `sim/tb_top.v` and
  `sim/tb_timing.v` (mark them simulation-only).
- Set `top.v` as top module if Vivado doesn't do it automatically
  (right-click → Set as Top).

### 4. Make the weight files visible to `$readmemh`
The `.mem` files already live in `rtl/` next to the Verilog files. As long
as you added the whole `rtl/` folder (including the `.mem` files) to the
project as Design Sources, `$readmemh("conv1_weights.mem", mem)` etc. will
find them with no path needed for both simulation and synthesis. If Vivado
complains, the simplest fallback is to also copy the three `.mem` files
into the folder that contains the `.xpr` project file.

### 5. Simulate BEFORE flashing hardware
Run behavioral simulation on `tb_top.v` (Flow Navigator → Run Simulation →
Run Behavioral Simulation). It sends a synthetic ramp image and prints
`PASS: predicted digit = N` when the pipeline finishes.

For per-stage timing, set `tb_timing.v` as the simulation top instead and
`run all` — it will print a stage-by-stage timing report (UART load,
Conv1, Pool1, Conv2, Pool2, FC, total).

If it times out or errors, fix it here — much faster to debug in simulation
(you can see every signal) than by staring at LEDs on the board.

### 6. Synthesize, implement, generate bitstream
- Run Synthesis → check the Utilization report:
  - **DSP48E1**: expect ~18 (9 per conv engine × 2 instances).
  - **BRAM**: ~6-8 tiles (image RAM, conv1 out, pool1 out, conv2 out,
    pool2 out, 3 weight ROMs).
  - **LUTs**: well under the 33K budget (line buffers cost some LUTs/FFs;
    the largest is Conv2's 8-channel × 3-row × 13-col line buffer =
    312 bytes of FFs).
- Run Implementation → check timing (no negative slack).
- Generate Bitstream.

### 7. Program the board
Hardware Manager → Auto Connect → Program Device → select the generated
`.bit` file.

### 8. Send an image and read the result
```bash
cd python
pip install pyserial opencv-python
python stream_to_fpga.py --port COM3 --image your_digit.png
```
(Windows: find your COM port in Device Manager. Linux/Mac: `/dev/ttyUSB*`
or `/dev/ttyACM*`.)

While loading, LEDs 15:6 will count up as pixels arrive. Once LED 5 turns
on, loading is done. Once LED 4 turns on, the result is ready — read the
predicted digit on the rightmost 7-segment digit (and also on LEDs 3:0).

Press the center button (`btnC`) to reset and classify another image.
Actually, you don't even need to: when the next image starts streaming in,
the FSM auto-restarts from `M_LOAD`.

## LED assignments

| LED       | Meaning                                                    |
|-----------|------------------------------------------------------------|
| `led[3:0]`| Predicted digit (0–9)                                      |
| `led[4]`  | `result_ready` — pipeline finished, digit is valid         |
| `led[5]`  | `loading_done` — all 784 pixels received                   |
| `led[15:6]`| `img_wr_addr[9:0]` — debug: watch pixels stream in        |

## Tuning notes

- **Requantization shift (IMPORTANT)**: each `conv_engine` instance has a
  `SHIFT` parameter that right-shifts the 32-bit accumulator down to 8 bits
  after the conv layer. The correct value depends on the trained weight
  scales — too small and outputs saturate at 255 (losing information), too
  large and outputs are all near zero (also losing information).

  This project ships with empirically-tuned values:
  - `u_conv1.SHIFT = 9`
  - `u_conv2.SHIFT = 8`

  These were found by sweeping SHIFT1 × SHIFT2 against 100 MNIST test
  images in a Python RTL-faithful reference model and picking the
  combination that matched the PyTorch float baseline (100% on those 100
  images). If you retrain the model with different weights, re-tune the
  SHIFT values: a good starting point is `SHIFT ≈ round(log2(weight_scale))`
  (printed by `quantize_export.py`), then sweep ±2 to find the best
  combination.

- **Ties in argmax**: `argmax10.v` breaks ties by picking the lowest index.
  Not usually an issue after training converges.

- **Image format**: `stream_to_fpga.py` resizes whatever you feed it to
  28×28 grayscale but does not invert or normalize like MNIST (white digit
  on black background, roughly centered). Use an actual MNIST test image
  for your first end-to-end test rather than a photo of handwriting.

## Resource budget (estimated)

| Resource      | Used by this design              | Basys3 budget |
|---------------|----------------------------------|---------------|
| DSP48E1       | ~18 (9 × 2 conv engines)         | 90            |
| BRAM36        | ~6–8 (5 feature-map RAMs + 3 ROMs)| 50            |
| LUTs          | <5K (control + line buffer logic)| 33K           |
| Flip-flops    | ~3K (line buffers + pipeline)    | 65K           |

## Architecture details (parallel 9-MAC conv)

Each `conv_engine` instance implements:

```
                  +-----------------+
input RAM ------->| stream pixels  |---> line buffer (3 rows × INPUT_W
stream_ptr (raster| in raster order |     per channel, in flip-flops)
order, channel as +-----------------+
inner loop)                |
                           v
                  +-----------------+
                  | window read    |----> 3x3 window for each channel
                  | (combinational |      (9 pixels per channel, all
                  |  from lb regs)  |       channels available in parallel)
                  +-----------------+
                           |
                           v
        weight ROM ---> +-----------------+
        (9 weights      | 9 parallel     |----> partial sum
         for (f,c))     | signed 8x8 MAC |      (signed 21-bit)
                        | + adder tree   |
                        +-----------------+
                                 |
                                 v
                          acc += partial   (loop over input channels)
                                 |
                                 v
                          ReLU(acc >> SHIFT, saturate [0,255])
                                 |
                                 v
                          conv_out RAM
```

Line-buffer row mapping (circular buffer, 3 rows):
```
cur_wr_row = in_y % 3
r_bot      = cur_wr_row              # row in_y    (= oy+2)
r_mid      = (cur_wr_row + 1) % 3    # row in_y-1  (= oy+1)
r_top      = (cur_wr_row + 2) % 3    # row in_y-2  (= oy)
```

Weight address layout (matches PyTorch's out_channels-major flatten order):
```
conv1_weights.mem:  addr = f*1*9 + 0*9 + ky*3 + kx      (f=0..7,   ky/kx=0..2)
conv2_weights.mem:  addr = f*8*9 + c*9 + ky*3 + kx      (f=0..15,  c=0..7, ky/kx=0..2)
fc_weights.mem:     addr = out*400 + in                  (out=0..9, in=0..399)
```

Image RAM address layout (channel-major, raster within a channel):
```
conv1 input (image_ram):     addr = in_y*28 + in_x
conv2 input (pool1_out_ram): addr = in_c*169 + in_y*13 + in_x
fc input    (pool2_out_ram): addr = in                (0..399, flat)
```

Output RAM address layout:
```
conv1_out_ram: addr = f*676 + oy*26 + ox
pool1_out_ram: addr = f*169 + py*13 + px
conv2_out_ram: addr = f*121 + oy*11 + ox
pool2_out_ram: addr = f*25  + py*5  + px
```

## What was preserved (unchanged from the starter project)

- `uart_rx.v` — 115200 baud UART receiver
- `stream_to_fpga.py` — sends 784 raw bytes
- `display_7seg.v` — 7-segment driver
- `argmax10.v` — 10-way argmax
- `dp_ram.v` — generic dual-port RAM
- `weight_rom.v` — generic weight ROM
- `basys3.xdc` — pin mapping
- Image RAM (784×8) — same byte format
- btnC reset + auto-restart logic — same behavior
- LED assignments — `led[4]` = result_ready, `led[5]` = loading_done,
  `led[3:0]` = digit, `led[15:6]` = pixel counter
