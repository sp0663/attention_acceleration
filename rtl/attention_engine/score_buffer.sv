module score_buffer #(
    parameter SEQ_LEN = 128,
    parameter SEQ_BITS = 7 // log2(128)
)(
    input  logic clk,
    // --- Write Interface (From Causal Mask) ---
    input  logic                valid_in,
    output logic                ready_in,
    input  logic [SEQ_BITS-1:0] write_addr,
    input  logic [31:0]         score_in,

    // --- Read Interface (To Softmax) ---
    // Softmax does not use a valid/ready FIFO pop because it needs 
    // random access to scan the memory multiple times.
    input  logic [SEQ_BITS-1:0] read_addr,
    output logic [31:0]         score_out
);

    // Memory array: 128 elements, each 32 bits wide (FP32)
    // Synthesis tools will map this to Distributed RAM or BRAM automatically.
    logic [31:0] ram [0:SEQ_LEN-1];

    // --- Write Datapath ---
    // In a perfectly pipelined system, this buffer is always ready to accept 
    // the next dot product, assuming Softmax finishes reading before the next row begins.
    assign ready_in = 1'b1;

    always_ff @(posedge clk) begin
        if (valid_in) begin
            ram[write_addr] <= score_in;
        end
    end

    // --- Read Datapath ---
    // Synchronous read (1 cycle latency). This is the standard pattern for 
    // inferring highly efficient BRAM in Xilinx/Intel FPGAs.
    always_ff @(posedge clk) begin
        score_out <= ram[read_addr];
    end

endmodule