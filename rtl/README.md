# RTL — Attention Accelerator

SystemVerilog implementation of the LLaMA 3 8B attention sublayer for FPGA.  
All arithmetic is FP32 internally. BF16 conversion happens at the top-level I/O boundary only.  
Target sequence length: 128 tokens (scalable to 512).

---

## Directory Structure

```
rtl/
├── top/
├── bf16/
├── rmsnorm/
├── projection/
├── rope/
├── gqa/
├── attention_engine/
└── memory/
```

---

## top/

### `attention_top.sv`
Top-level wrapper that instantiates and connects every submodule. Handles BF16→FP32 conversion on input and FP32→BF16 on output. This is the only file the synthesis tool sees at the top level.

### `attention_fsm.sv`
Central finite state machine that sequences the entire datapath. Controls start/done handshakes between blocks, triggers DMA transfers for weight loading, and stalls upstream blocks when downstream buffers are full. All inter-block timing runs through here.

---

## bf16/

### `bf16_to_fp32.sv`
Converts a 16-bit BF16 value to 32-bit FP32 by zero-extending the mantissa. Since BF16 is just FP32 with the bottom 16 mantissa bits dropped, this is a simple bit-extension with no arithmetic. Used at the input boundary.

### `fp32_to_bf16.sv`
Converts FP32 back to BF16 by truncating the lower 16 mantissa bits with round-to-nearest. Used at the output boundary.

### `bf16_mac.sv`
Multiply-accumulate unit operating on BF16 inputs. Converts operands to FP32, performs the MAC in FP32, and returns an FP32 accumulator. Used inside the systolic array processing elements.

---

## rmsnorm/

### `rmsnorm_sum_sq.sv`
Takes a vector of FP32 values of length 4096 and computes the sum of squares across all elements. Implemented as a pipelined adder tree for throughput.

### `rmsnorm_rsqrt.sv`
Computes the reciprocal square root (1/√x) of the sum-of-squares output. Uses a LUT-based approximation followed by one Newton-Raphson refinement step for accuracy.

### `rmsnorm_top.sv`
Combines the above two modules. Takes the raw input vector, computes RMS, divides each element by it, then multiplies element-wise by the learned gamma vector loaded from weight buffer. Outputs a normalised FP32 vector of the same shape.

---

## projection/

### `systolic_pe.sv`
A single processing element (PE) for the systolic array. On each clock cycle it multiplies its local weight value by the incoming activation, accumulates into a local register, and passes the activation to the next PE. The fundamental compute unit.

### `systolic_array.sv`
An N×N array of systolic PEs for matrix multiplication. Weights are preloaded into the array, activations flow left-to-right, and partial sums accumulate vertically. Parameterised by array size — set N based on available DSP count.

### `projection_top.sv`
Drives the systolic array to compute all four projections in sequence: W_Q, W_K, W_V (during the forward pass), and W_O (after the attention engine). Manages weight DMA requests to load each matrix from DRAM into the array, and routes outputs to the appropriate downstream buffer.

---

## rope/

### `rope_lut.sv`
Stores precomputed sin and cos values for all (position, frequency) pairs needed across the full sequence length and head dimension. Addressed by token position and dimension index. Read-only after initialisation.

### `rope_rotate.sv`
Applies a 2D rotation to one pair of dimensions [x1, x2] given sin and cos values from the LUT. Computes [x1·cos − x2·sin, x1·sin + x2·cos]. Fully pipelined, processes one pair per cycle.

### `rope_top.sv`
Iterates over all heads and all positions, dispatching pairs of Q and K dimensions to `rope_rotate.sv` with the correct sin/cos from the LUT. V vectors are passed through unchanged. Outputs rotated Q and K tensors of the same shape.

---

## gqa/

### `gqa_expand.sv`
Broadcasts the 8 KV heads to 32 heads by repeating each head 4 times. Implemented as an index remapping — no data is physically copied. A read address into the 8-head KV buffer is computed as `head_index / 4`, so all four Q heads in a group read from the same KV head. Zero additional memory cost.

---

## attention_engine/

### `dot_product.sv`
Computes the scaled dot product between one query vector and one key vector: Q·K^T / √128. Takes two FP32 vectors of length 128 (one head dimension) and returns a single FP32 scalar. Implemented as a pipelined multiply-accumulate chain followed by a fixed scale factor.

### `causal_mask.sv`
Applies the causal mask to the attention score matrix. For each score at position (i, j), if j > i the score is replaced with −∞ (represented as a large negative FP32 value). Implemented as a comparator and mux — no arithmetic.

### `softmax.sv`
Row-wise softmax over the attention score matrix. First finds the row maximum for numerical stability, subtracts it from all scores, then exponentiates via a LUT, accumulates the sum using an adder tree, and divides each exp value by the sum. Outputs FP32 attention weights that sum to 1 per row.

### `score_buffer.sv`
On-chip BRAM tile that stores the attention score matrix [32 heads × S × S] between the dot product stage and the softmax stage. Sized for S ≤ 128. Acts as a ping-pong buffer so the dot product engine and softmax engine can overlap.

### `attention_engine_top.sv`
Orchestrates steps 5, 6, and 7. Drives `dot_product.sv` across all head/position pairs to fill `score_buffer.sv`, then passes scores through `causal_mask.sv` and `softmax.sv` to get attention weights, then multiplies weights by V to produce the attended output. Controls all internal sequencing.

---

## memory/

### `axi_master.sv`
AXI4 bus master that fetches weight matrices from off-chip DRAM on demand. Accepts a base address and burst length from the FSM, performs the AXI read transaction, and streams data into the weight buffer. Handles AXI handshaking, burst splitting, and error responses.

### `weight_buffer.sv`
Ping-pong on-chip buffer (two banks of URAM/BRAM) that holds incoming weight tiles streamed from DRAM. While one bank is being consumed by the systolic array, the other is being filled by the AXI master. Prevents stalls due to DRAM latency.

### `token_buffer.sv`
On-chip BRAM holding the input hidden state tensor [S × 4096] in FP32. Written once at the start of each attention call and read by RMSNorm. Also stores the original pre-norm input for the residual addition in step 9.

### `output_buffer.sv`
On-chip BRAM holding the final attention output [S × 4096] in FP32 after the residual add. The top-level module reads from here, converts to BF16, and sends the result off-chip via the AXI master.

---

## Parameters (defined in `attention_top.sv`)

| Parameter | Value | Description |
|---|---|---|
| `SEQ_LEN` | 128 | Sequence length (scalable to 512) |
| `D_MODEL` | 4096 | Hidden dimension |
| `N_HEADS` | 32 | Query heads |
| `N_KV_HEADS` | 8 | Key/Value heads (GQA) |
| `HEAD_DIM` | 128 | Per-head dimension (D_MODEL / N_HEADS) |
| `PE_SIZE` | TBD | Systolic array dimension (set per DSP budget) |

---

## Interfaces

Every module follows the same valid/ready handshake:

```
input  logic        clk, rst_n
input  logic        valid_in
output logic        ready_in
output logic        valid_out
input  logic        ready_out
```

A transfer occurs on any cycle where both `valid` and `ready` are high. This allows any module to stall its upstream by deasserting `ready_in`.
