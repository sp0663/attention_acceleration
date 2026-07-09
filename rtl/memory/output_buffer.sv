module output_buffer (
    input  logic        clk,
    input  logic        rst_n,

    // write port — from datapath after residual add, 16 BF16 values per cycle
    input  logic        wr_en,
    input  logic [7:0]  wr_addr,
    input  logic [15:0] wr_data [0:15],

    // AXI Stream master — sends data to AXI DMA for writeback to DDR
    output logic         m_axis_tvalid,
    input  logic         m_axis_tready,
    output logic [127:0] m_axis_tdata,
    output logic         m_axis_tlast,

    // read trigger — FSM asserts this to start streaming output to DMA
    input  logic        rd_start
);

    logic [15:0] mem [0:15][0:255];

    // write port
    always_ff @(posedge clk) begin
        if (wr_en) begin
            for (int i = 0; i < 16; i++)
                mem[i][wr_addr] <= wr_data[i];
        end
    end

    // AXI Stream master — reads memory and streams to DMA
    // 2 beats per group of 16 values (8 values per 128-bit beat)
    logic [7:0]  rd_addr;
    logic        beat_phase;
    logic        active;
    logic [15:0] rd_buf [0:15];  // buffer one group while sending 2 beats

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_addr       <= 8'b0;
            beat_phase    <= 1'b0;
            active        <= 1'b0;
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;
        end else begin
            if (rd_start && !active) begin
                active     <= 1'b1;
                rd_addr    <= 8'b0;
                beat_phase <= 1'b0;
            end

            if (active) begin
                m_axis_tvalid <= 1'b1;

                if (m_axis_tready) begin
                    if (beat_phase == 1'b0) begin
                        // latch current group and send first beat
                        for (int i = 0; i < 16; i++)
                            rd_buf[i] <= mem[i][rd_addr];
                        for (int i = 0; i < 8; i++)
                            m_axis_tdata[i*16 +: 16] <= mem[i][rd_addr];
                        beat_phase <= 1'b1;
                    end else begin
                        // send second beat
                        for (int i = 0; i < 8; i++)
                            m_axis_tdata[i*16 +: 16] <= rd_buf[i+8];
                        beat_phase <= 1'b0;

                        if (rd_addr == 8'd255) begin
                            m_axis_tlast  <= 1'b1;
                            active        <= 1'b0;
                            m_axis_tvalid <= 1'b0;
                            rd_addr       <= 8'b0;
                        end else begin
                            m_axis_tlast <= 1'b0;
                            rd_addr      <= rd_addr + 1;
                        end
                    end
                end
            end else begin
                m_axis_tvalid <= 1'b0;
                m_axis_tlast  <= 1'b0;
            end
        end
    end

endmodule