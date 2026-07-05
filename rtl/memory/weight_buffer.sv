module weight_buffer (
    input  logic        clk,
    input  logic        rst_n,

    // BRAM port A — connected to AXI BRAM Controller (write from DMA)
    input  logic        bram_en,
    input  logic [3:0]  bram_we,       // byte write enable
    input  logic [9:0]  bram_addr,     // word address (512 bytes / 4 bytes per word = 128 words)
    input  logic [31:0] bram_din,
    output logic [31:0] bram_dout,

    // port B — read by systolic array, 16 BF16 values per cycle
    input  logic        rd_en,
    output logic [15:0] rd_data [0:15]
);

    // 16 rows × 16 values × 16 bits = 4096 bits = 512 bytes
    // viewed from BRAM controller as 128 × 32-bit words
    // viewed from systolic array as 16 × (16 × 16-bit) rows
    logic [31:0] mem [0:127];   // 128 words of 32 bits = 512 bytes

    logic [3:0] rd_count;

    // BRAM port A — AXI BRAM Controller writes here
    always_ff @(posedge clk) begin
        if (bram_en) begin
            if (bram_we[0]) mem[bram_addr][7:0]   <= bram_din[7:0];
            if (bram_we[1]) mem[bram_addr][15:8]  <= bram_din[15:8];
            if (bram_we[2]) mem[bram_addr][23:16] <= bram_din[23:16];
            if (bram_we[3]) mem[bram_addr][31:24] <= bram_din[31:24];
            bram_dout <= mem[bram_addr];
        end
    end

    // read counter — increments each cycle rd_en is high
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_count <= 4'b0;
        end else if (rd_en) begin
            rd_count <= rd_count + 1;
        end else begin
            rd_count <= 4'b0;
        end
    end

    // port B — systolic array reads 16 BF16 values per cycle
    // each row of 16 BF16 values = 256 bits = 8 words of 32 bits
    // row n occupies mem[n*8] to mem[n*8+7]
    always_ff @(posedge clk) begin
        if (rd_en) begin
            for (int i = 0; i < 8; i++) begin
                rd_data[i*2]   <= mem[rd_count*8 + i][15:0];
                rd_data[i*2+1] <= mem[rd_count*8 + i][31:16];
            end
        end
    end

endmodule