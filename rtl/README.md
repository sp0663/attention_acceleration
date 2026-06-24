# RTL — Attention Accelerator

SystemVerilog implementation of the LLaMA 3 8B attention sublayer for FPGA.  
All arithmetic is FP32 internally. BF16 conversion happens at the top-level I/O boundary only.  
Target sequence length: 128 tokens, processed **one token at a time** — full sequence lives in off-chip DRAM.

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
Converts FP32 back to BF16 by truncating the lower 16 mantissa bits with round-to-nearest (ties-to-even). Used at the output boundary.

### `bf16_mac.sv`
Fused Multiply-Add (FMA) unit implemented using the Xilinx Floating Point IP core configured as multiply-accumulate. Takes two BF16 inputs (a, b) and one FP32 input (c), converts a and b to FP32 internally, and computes (a×b)+c in a single pipelined operation with 17 cycle latency. No internal accumulator — the caller (systolic PE) is responsible for chaining the c input. Used inside the systolic array processing elements.

---

## rmsnorm/

### `rmsnorm_sum_sq.sv`
Takes 16 BF16 values per cycle over 256 cycles (4096 total elements of one token vector) and computes the sum of squares. Implemented as 16 parallel FP32 squarers feeding a 4-stage adder tree (16→1 partial sum per cycle), followed by 16 parallel accumulators in a round-robin scheme to avoid the adder feedback latency problem. A second 4-stage combine tree reduces the 16 partial accumulators to one final FP32 scalar. Outputs one sum_sq value per token vector.

### `rmsnorm_rsqrt.sv`
Computes the reciprocal square root (1/√x) using the Xilinx Floating Point IP core configured as Reciprocal Square Root, single precision FP32. Latency is 33 cycles. Input is sum_sq/4096 (division by 4096 is a free exponent subtraction of 12 in hardware). Outputs one FP32 scalar per token vector.

### `rmsnorm_top.sv`
Connects rmsnorm_sum_sq and rmsnorm_rsqrt, then applies the learned gamma scaling. The FSM times gamma streaming to arrive exactly when rsqrt is ready (Option iii — overlapped), eliminating the need to buffer gamma on-chip. Scaling is two stages of 16 parallel FP32 multipliers: first x[i]×gamma[i], then result×rsqrt. Outputs 16 normalised BF16 values per cycle.

---

## projection/

### `systolic_pe.sv`
A single processing element (PE) for the systolic array. Takes BF16 activation a_in, BF16 weight b_in, and FP32 partial sum c_in, computes (a×b)+c using one instantiation of bf16_mac (Xilinx FMA core), and outputs the FP32 result. Also passes a_in and b_in to neighbouring PEs as registered outputs (a_out, b_out) so data flows through the array. No internal accumulator — partial sums flow through the c input chain.

### `systolic_array.sv`
An N×N array of systolic PEs (N=16, parameterised). Activations flow left-to-right, weights flow top-to-bottom, partial sums accumulate along each row via the c input chain. Input skewing registers ensure a[i] and b[j] arrive at PE[i,j] at the correct cycle. The rightmost PE in each row outputs the dot product result for that row. Tiling over the full 4096-dimension is handled externally by projection_top.sv.

### `projection_top.sv`
Drives the systolic array to compute all four projections in sequence: W_Q, W_K, W_V, and W_O. Manages weight DMA requests to stream 16×16 weight tiles from DRAM into the array, handles tiling over the full 4096×4096 matrix, and routes outputs to the appropriate downstream buffer. One token vector is processed at a time.

---

## rope/

### `rope_lut.sv`
Stores precomputed sin and cos values for all (position, frequency) pairs needed across the full sequence length and head dimension. Addressed by token position and dimension pair index. Read-only after initialisation. Note: if BRAM is insufficient, replace with on-the-fly CORDIC computation in a future revision.

### `rope_rotate.sv`
Applies a 2D rotation to one pair of dimensions [x1, x2] given sin and cos values. Computes [x1·cos − x2·sin, x1·sin + x2·cos] using four FP32 multipliers and two FP32 adders, fully pipelined. Processes one dimension pair per cycle.

### `rope_top.sv`
Iterates over all heads and all dimension pairs, dispatching Q and K values to rope_rotate.sv with the correct sin/cos values from rope_lut.sv. V vectors are passed through unchanged. Outputs rotated Q and K with the same shape as input.

---

## gqa/

### `gqa_expand.sv`
Broadcasts the 8 KV heads to 32 heads by index remapping — no data is physically copied. Read address into the KV buffer is computed as head_index/4, so all four Q heads in a group read from the same KV head. Zero additional memory or compute cost.

---

## attention_engine/

### `dot_product.sv`
Computes the scaled dot product between one query vector and one key vector: Q·Kᵀ/√128. Takes two FP32 vectors of length 128 (one head dimension) and returns a single FP32 scalar. Implemented as 16 parallel bf16_mac FMA units feeding a 4-stage adder tree, followed by multiplication by 1/√128 as a fixed scale factor.

### `causal_mask.sv`
Applies the causal mask to attention scores. For each score at position (i, j), if j > i the score is replaced with a large negative FP32 value (−∞ approximation). Implemented as a comparator and mux — no arithmetic, zero latency.

### `softmax.sv`
Row-wise softmax over the attention score matrix. Finds the row maximum for numerical stability, subtracts it from all scores, exponentiates using the Xilinx FP exp() IP core, accumulates the sum using an adder tree, then divides each exp value by the sum. Outputs FP32 attention weights that sum to 1 per row.

### `score_buffer.sv`
On-chip buffer storing attention scores for one head, one row at a time. Scores are computed one head at a time and passed immediately to softmax — the full [32 × S × S] matrix is never materialised on-chip. Acts as a small FIFO between the dot product engine and softmax.

### `attention_engine_top.sv`
Orchestrates steps 5, 6, and 7. Drives dot_product.sv across all head and position pairs, passes scores through causal_mask.sv and softmax.sv, then multiplies attention weights by V to produce the attended output. Processes one head at a time to stay within BRAM budget.

---

## memory/

### `axi_master.sv`
AXI4 bus master that fetches weight matrices and token vectors from off-chip DRAM on demand. Accepts a base address and burst length from the FSM, performs the AXI read transaction, and streams data into the appropriate on-chip buffer. Handles AXI handshaking, burst splitting, and error responses.

### `weight_buffer.sv`
Ping-pong on-chip buffer (two banks of BRAM) holding incoming 16×16 weight tiles streamed from DRAM. While one bank is consumed by the systolic array, the other is filled by the AXI master. Prevents stalls due to DRAM latency. Sized for one 16×16 BF16 tile per bank = 8KB total.

### `token_buffer.sv`
On-chip BRAM holding **one token vector [4096] in BF16** — 8KB, fits in one BRAM18. Written by the AXI master at the start of each token's computation and read by RMSNorm and the residual add. The full sequence of 128 tokens lives in off-chip DRAM and is streamed one token at a time.

### `output_buffer.sv`
On-chip BRAM holding one output token vector [4096] in BF16 after the residual add and BF16 conversion. Written by the attention datapath and read by the AXI master which writes it back to off-chip DRAM immediately. Sized at 8KB — one token at a time.

---

## Parameters (defined in `attention_top.sv`)

| Parameter | Value | Description |
|---|---|---|
| `SEQ_LEN` | 128 | Sequence length (processed one token at a time from DRAM) |
| `D_MODEL` | 4096 | Hidden dimension |
| `N_HEADS` | 32 | Query heads |
| `N_KV_HEADS` | 8 | Key/Value heads (GQA) |
| `HEAD_DIM` | 128 | Per-head dimension (D_MODEL / N_HEADS) |
| `N_PARALLEL` | 16 | Number of parallel lanes (squarers, multipliers, PE rows) |
| `PE_SIZE` | 16 | Systolic array dimension |

---

## Interfaces

Every module follows the same valid/ready handshake:

```systemverilog
input  logic  clk, rst_n
input  logic  valid_in
output logic  ready_in
output logic  valid_out
input  logic  ready_out
```

A transfer occurs on any cycle where both `valid` and `ready` are high. This allows any module to stall its upstream by deasserting `ready_in`.

---

