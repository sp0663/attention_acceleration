module rope_lut #(
    // Dimensions based on your Python generation script
    parameter int SEQ_LEN    = 128,
    parameter int NUM_PAIRS  = 64,
    parameter int DATA_WIDTH = 64,
    
    // Automatically calculate bit widths
    localparam int POS_W  = $clog2(SEQ_LEN),
    localparam int PAIR_W = $clog2(NUM_PAIRS),
    localparam int ADDR_W = POS_W + PAIR_W
) (
    input  logic                  clk,
    input  logic [POS_W-1:0]      position,
    input  logic [PAIR_W-1:0]     pair_idx,
    
    // 64-bit output: [31:0] cos_fp32, [63:32] sin_fp32
    output logic [DATA_WIDTH-1:0] lut_data
);

    // ============================================================
    // Memory Array Definition
    // ============================================================
    // The attribute below instructs Vivado's synthesis tool to 
    // strictly infer Block RAM (BRAM) for this array.
    (* rom_style = "block" *)
    logic [DATA_WIDTH-1:0] lut_mem [0:(1<<ADDR_W)-1];

    // ============================================================
    // Initialization
    // ============================================================
    // During synthesis, Vivado will read this .mem file and bake 
    // the hex values directly into the FPGA's bitstream.
    initial begin
        $readmemh("rope_lut.mem", lut_mem);
    end

    // ============================================================
    // 2-Cycle Read Pipeline
    // ============================================================
    logic [ADDR_W-1:0] addr_r;

    always_ff @(posedge clk) begin
        // Cycle 1: Concatenate position and pair index to form 
        // the flattened 1D memory address, and register it.
        addr_r   <= {position, pair_idx};
        
        // Cycle 2: Read from the memory array using the registered 
        // address and latch it to the output.
        lut_data <= lut_mem[addr_r];
    end

endmodule