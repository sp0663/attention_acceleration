module token_buffer (
    input  logic        clk,
    input  logic        rst_n,

    // AXI Stream slave — receives data from AXI DMA (128-bit = 8 BF16 per beat)
    input  logic         s_axis_tvalid,
    output logic         s_axis_tready,
    input  logic [127:0] s_axis_tdata,
    input  logic         s_axis_tlast,

    // read port — 16 BF16 values per cycle, consumed by datapath
    input  logic        rd_en,
    input  logic [7:0]  rd_addr,       // 0 to 255 (4096/16 groups)
    output logic [15:0] rd_data [0:15]
);

    logic [15:0] mem [0:15][0:255];

    // write logic — AXI Stream
    // 128 bits = 8 BF16 values per beat
    // need 2 beats to fill one group of 16 values
    logic        beat_phase;     // 0 = first beat, 1 = second beat
    logic [7:0]  wr_addr;
    logic [15:0] beat0_data [0:7]; // store first beat while waiting for second

    assign s_axis_tready = 1'b1;  // always ready to accept data

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            beat_phase <= 1'b0;
            wr_addr    <= 8'b0;
        end else if (s_axis_tvalid) begin
            if (beat_phase == 1'b0) begin
                // store first 8 values
                for (int i = 0; i < 8; i++)
                    beat0_data[i] <= s_axis_tdata[i*16 +: 16];
                beat_phase <= 1'b1;
            end else begin
                // write all 16 values to memory
                for (int i = 0; i < 8; i++)
                    mem[i][wr_addr]   <= beat0_data[i];
                for (int i = 0; i < 8; i++)
                    mem[i+8][wr_addr] <= s_axis_tdata[i*16 +: 16];
                beat_phase <= 1'b0;
                if (s_axis_tlast)
                    wr_addr <= 8'b0;   // reset for next token
                else
                    wr_addr <= wr_addr + 1;
            end
        end
    end

    // read port — 1 cycle latency
    always_ff @(posedge clk) begin
        if (rd_en) begin
            for (int i = 0; i < 16; i++)
                rd_data[i] <= mem[i][rd_addr];
        end
    end

endmodule