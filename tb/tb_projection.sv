`timescale 1ns / 1ps

module tb_projection_top;

    // ----------------------------------------------------
    // Parameters (Scaled down for rapid single-tile tests)
    // ----------------------------------------------------
    parameter PE_SIZE = 4;
    parameter SEQ_LEN = 4;
    parameter D_MODEL = 4; 
    parameter D_KV    = 4; 
    parameter CLK_PERIOD = 10; 

    // Testbench Signals
    logic        clk;
    logic        rst_n;
    logic        valid_in;
    logic        ready_in;
    logic        valid_out;
    logic        ready_out;
    logic [1:0]  proj_sel;
    
    logic [15:0] weight_dma_row_tile;
    logic [15:0] weight_dma_col_tile;
    logic        weight_dma_req;
    logic        weight_dma_ready;
    
    logic [$clog2(PE_SIZE)-1:0] weight_rd_addr;
    logic [15:0]                weight_rd_data [0:PE_SIZE-1];
    
    logic [$clog2(SEQ_LEN)-1:0]      act_rd_addr;
    logic [($clog2(D_MODEL/PE_SIZE)>0 ? $clog2(D_MODEL/PE_SIZE)-1 : 0):0] act_rd_col_grp;
    logic                               act_rd_en;
    logic [31:0]                        act_rd_data [0:PE_SIZE-1];
    
    logic                               out_wr_en;
    logic [$clog2(SEQ_LEN)-1:0]        out_wr_addr;
    logic [($clog2(D_MODEL/PE_SIZE)>0 ? $clog2(D_MODEL/PE_SIZE)-1 : 0):0] out_wr_col_grp;
    logic [1:0]                        out_dest;
    logic [31:0]                        out_wr_data [0:PE_SIZE-1];

    // Instantiate UUT
    projection_top #(
        .PE_SIZE(PE_SIZE),
        .SEQ_LEN(SEQ_LEN),
        .D_MODEL(D_MODEL),
        .D_KV(D_KV)
    ) uut (.*);

    // Clock Generation
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    // FIX: Generate valid BF16 floating-point values (Base 16'h3F80 = 1.0)
    always_comb begin
        for (int i = 0; i < PE_SIZE; i++) begin
            weight_rd_data[i] = 16'h3F80 + ((weight_rd_addr + i) * 16'h0040);
        end
    end

    // FIX: Generate valid FP32 floating-point values (Base 32'h3F800000 = 1.0)
    // Mock Activation Memory Response (Fixed Address Alignment)
    always_comb begin
        for (int i = 0; i < PE_SIZE; i++) begin
            // If act_rd_en is low, hold the baseline vector at 0
            if (!act_rd_en && act_rd_addr == 0) begin
                act_rd_data[i] = 32'h3F800000 + (i * 32'h00200000);
            end else begin
                act_rd_data[i] = 32'h3F800000 + ((act_rd_addr + i) * 32'h00200000);
            end
        end
    end

    // Automate Weight DMA Handshake
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            weight_dma_ready <= 1'b0;
        end else begin
            if (weight_dma_req && !weight_dma_ready) begin
                weight_dma_ready <= 1'b1;
            end else begin
                weight_dma_ready <= 1'b0;
            end
        end
    end

    // Test Vector Sequence
    initial begin
        rst_n     = 1'b0;
        valid_in  = 1'b0;
        ready_out = 1'b0;
        proj_sel  = 2'b00; 

        #(CLK_PERIOD * 5);
        rst_n = 1'b1;
        #(CLK_PERIOD * 2);

        $display("[TB INFO] Starting Execution for W_Q Projection Layer...");
        
        @(posedge clk);
        while (!ready_in) @(posedge clk); 
        
        valid_in  = 1'b1;
        proj_sel  = 2'b00; 
        ready_out = 1'b1;  
        
        @(posedge clk);
        valid_in = 1'b0; 

        // Dynamic Watchdog Framework
        fork
            begin
                @(posedge valid_out);
                @(posedge clk); 
                $display("[TB SUCCESS] Layer Processing Finished successfully!");
            end
            begin
                repeat(2000) @(posedge clk);
                $display("[TB ERROR] Simulation timed out! Check state tracks.");
            end
        join_any
        
        #(CLK_PERIOD * 10);
        $finish;
    end

    // Verification Monitor
    integer write_count = 0;
    always @(posedge clk) begin
        if (out_wr_en) begin
            write_count = write_count + 1;
            $display("[MONITOR @ %0t ns] Output Write #%0d | Addr: %0d | Col Group: %0d | Sample Data[0]: %h", 
                     $time, write_count, out_wr_addr, out_wr_col_grp, out_wr_data[0]);
        end
    end

endmodule