module projection_top #(
    parameter PE_SIZE = 16,
    parameter SEQ_LEN = 128,
    parameter D_MODEL = 4096
) (
    input  logic        clk,
    input  logic        rst_n,
    
    // Control interface (from top-level FSM)
    input  logic        valid_in,
    output logic        ready_in,
    output logic        valid_out,
    input  logic        ready_out,
    input  logic [1:0]  proj_sel,      // 0: W_Q, 1: W_K, 2: W_V, 3: W_O
    
    // Weight DMA Interface (to AXI master / weight buffer controller)
    output logic [15:0] weight_dma_row_tile,
    output logic [15:0] weight_dma_col_tile,
    output logic        weight_dma_req,
    input  logic        weight_dma_ready,
    
    // Weight Buffer Read Interface
    output logic [$clog2(PE_SIZE)-1:0] weight_rd_addr,
    input  logic [15:0]                weight_rd_data [0:PE_SIZE-1],
    
    // Activation Buffer Read Interface (reads normalized hidden states)
    output logic [$clog2(SEQ_LEN)-1:0]     act_rd_addr,
    output logic [$clog2(D_MODEL/PE_SIZE)-1:0] act_rd_col_grp,
    output logic                           act_rd_en,
    input  logic [31:0]                    act_rd_data [0:PE_SIZE-1], // FP32 activations
    
    // Downstream Projection Write Interface (to Q/K/V/O buffers)
    output logic                           out_wr_en,
    output logic [$clog2(SEQ_LEN)-1:0]     out_wr_addr,
    output logic [$clog2(D_MODEL/PE_SIZE)-1:0] out_wr_col_grp,
    output logic [1:0]                     out_dest,
    output logic [31:0]                    out_wr_data [0:PE_SIZE-1] // FP32 outputs
);

    // States
    typedef enum logic [2:0] {
        ST_IDLE,
        ST_REQ_WEIGHT,
        ST_LOAD_WEIGHT,
        ST_COMPUTE,
        ST_DONE
    } state_t;

    state_t state, next_state;

    // Registers
    logic [1:0]  proj_sel_reg;
    logic [15:0] row_tile;
    logic [15:0] col_tile;
    logic [15:0] num_col_tiles;
    logic [15:0] num_row_tiles;
    
    logic [$clog2(PE_SIZE):0] weight_load_cnt; // up to PE_SIZE
    logic [$clog2(SEQ_LEN):0]  stream_cnt;      // up to SEQ_LEN
    logic [$clog2(SEQ_LEN):0]  wr_cnt;          // up to SEQ_LEN

    // Internal Systolic Array Signals
    logic [15:0] systolic_weight_in [0:PE_SIZE-1];
    logic        systolic_weight_en;
    logic [15:0] systolic_x_in [0:PE_SIZE-1];
    logic        systolic_val_in [0:PE_SIZE-1];
    logic [31:0] systolic_s_in [0:PE_SIZE-1];
    logic [15:0] systolic_x_out [0:PE_SIZE-1];
    logic [31:0] systolic_s_out [0:PE_SIZE-1];
    logic        systolic_val_out [0:PE_SIZE-1];

    // Skew/Deskew Signals
    logic [15:0] act_bf16 [0:PE_SIZE-1];
    logic [15:0] act_to_skew [0:PE_SIZE-1];
    logic [31:0] sum_to_skew [0:PE_SIZE-1];
    logic        val_to_skew [0:PE_SIZE-1];
    
    logic [31:0] deskewed_s_out [0:PE_SIZE-1];
    logic        deskewed_val_out [0:PE_SIZE-1];

    // 1-cycle BRAM delay registers
    logic        val_read_valid;
    logic [15:0] act_bf16_reg [0:PE_SIZE-1];
    logic [31:0] accum_ram_rd_data_reg [0:PE_SIZE-1];

    // Accumulation BRAM
    logic [31:0] accum_ram [0:SEQ_LEN-1][0:PE_SIZE-1];
    logic        accum_ram_wr_en;
    logic [$clog2(SEQ_LEN)-1:0] accum_ram_wr_addr;
    logic [31:0] accum_ram_wr_data [0:PE_SIZE-1];
    
    logic        accum_ram_rd_en;
    logic [$clog2(SEQ_LEN)-1:0] accum_ram_rd_addr;
    logic [31:0] accum_ram_rd_data [0:PE_SIZE-1];

    // Dynamic tile configurations based on projection type
    always_comb begin
        num_row_tiles = 4096 / PE_SIZE;
        if (proj_sel_reg == 2'd0 || proj_sel_reg == 2'd3) begin
            num_col_tiles = 4096 / PE_SIZE; // W_Q (0), W_O (3)
        end else begin
            num_col_tiles = 1024 / PE_SIZE; // W_K (1), W_V (2)
        end
    end

    // FSM State transitions
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
        end else begin
            state <= next_state;
        end
    end

    always_comb begin
        next_state = state;
        case (state)
            ST_IDLE: begin
                if (valid_in && ready_in) begin
                    next_state = ST_REQ_WEIGHT;
                end
            end
            ST_REQ_WEIGHT: begin
                if (weight_dma_ready) begin
                    next_state = ST_LOAD_WEIGHT;
                end
            end
            ST_LOAD_WEIGHT: begin
                if (weight_load_cnt == PE_SIZE) begin
                    next_state = ST_COMPUTE;
                end
            end
            ST_COMPUTE: begin
                // Transition when the last element (SEQ_LEN-1) has finished writing back
                if (wr_cnt == SEQ_LEN - 1 && deskewed_val_out[0]) begin
                    if (row_tile == num_row_tiles - 1 && col_tile == num_col_tiles - 1) begin
                        next_state = ST_DONE;
                    end else begin
                        next_state = ST_REQ_WEIGHT;
                    end
                end
            end
            ST_DONE: begin
                if (ready_out) begin
                    next_state = ST_IDLE;
                end
            end
            default: next_state = ST_IDLE;
        endcase
    end

    // Control registers and loop variables
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            proj_sel_reg <= 2'b0;
            row_tile     <= '0;
            col_tile     <= '0;
        end else begin
            if (state == ST_IDLE && valid_in && ready_in) begin
                proj_sel_reg <= proj_sel;
                row_tile     <= '0;
                col_tile     <= '0;
            end else if (state == ST_COMPUTE && wr_cnt == SEQ_LEN - 1 && deskewed_val_out[0]) begin
                if (row_tile == num_row_tiles - 1) begin
                    row_tile <= '0;
                    if (col_tile != num_col_tiles - 1) begin
                        col_tile <= col_tile + 1;
                    end
                end else begin
                    row_tile <= row_tile + 1;
                end
            end
        end
    end

    // Ready in/out handshakes
    assign ready_in  = (state == ST_IDLE);
    assign valid_out = (state == ST_DONE);

    // Weight DMA outputs
    assign weight_dma_row_tile = row_tile;
    assign weight_dma_col_tile = col_tile;
    assign weight_dma_req      = (state == ST_REQ_WEIGHT);

    // Weight loader counters
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            weight_load_cnt    <= 0;
            systolic_weight_en <= 1'b0;
        end else if (state == ST_LOAD_WEIGHT) begin
            if (weight_load_cnt < PE_SIZE) begin
                weight_load_cnt    <= weight_load_cnt + 1;
                systolic_weight_en <= 1'b1;
            end else begin
                systolic_weight_en <= 1'b0;
            end
        end else begin
            weight_load_cnt    <= 0;
            systolic_weight_en <= 1'b0;
        end
    end

    // Weight buffer address output (read in reverse order so bottom row loads first)
    assign weight_rd_addr = (state == ST_LOAD_WEIGHT && weight_load_cnt < PE_SIZE) ? 
                            (PE_SIZE - 1 - weight_load_cnt) : '0;

    // Connect weights directly to systolic array weight ports
    assign systolic_weight_in = weight_rd_data;

    // Stream and Write counters
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stream_cnt <= '0;
        end else if (state == ST_COMPUTE) begin
            if (stream_cnt < SEQ_LEN) begin
                stream_cnt <= stream_cnt + 1;
            end
        end else begin
            stream_cnt <= '0;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_cnt <= '0;
        end else if (state == ST_COMPUTE) begin
            if (deskewed_val_out[0]) begin
                if (wr_cnt == SEQ_LEN - 1) begin
                    wr_cnt <= '0;
                end else begin
                    wr_cnt <= wr_cnt + 1;
                end
            end
        end else begin
            wr_cnt <= '0;
        end
    end

    // BRAM Read control for activations and accumulation RAM
    assign act_rd_en       = (state == ST_COMPUTE && stream_cnt < SEQ_LEN);
    assign act_rd_addr     = stream_cnt[$clog2(SEQ_LEN)-1:0];
    assign act_rd_col_grp  = row_tile[$clog2(D_MODEL/PE_SIZE)-1:0];

    assign accum_ram_rd_en   = (state == ST_COMPUTE && stream_cnt < SEQ_LEN);
    assign accum_ram_rd_addr = stream_cnt[$clog2(SEQ_LEN)-1:0];

    // Pipeline read-valid and register read outputs to align with BRAM's 1-cycle latency
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            val_read_valid <= 1'b0;
            for (int i = 0; i < PE_SIZE; i++) begin
                act_bf16_reg[i]            <= 16'b0;
                accum_ram_rd_data_reg[i]   <= 32'b0;
            end
        end else begin
            val_read_valid <= (state == ST_COMPUTE && stream_cnt < SEQ_LEN);
            act_bf16_reg   <= act_bf16;
            accum_ram_rd_data_reg <= accum_ram_rd_data;
        end
    end

    // BF16 Converter instantiations (for inputs from token buffer)
    generate
        for (genvar i = 0; i < PE_SIZE; i++) begin : gen_conv
            fp32_to_bf16 u_conv (
                .fp32_in(act_rd_data[i]),
                .bf16_out(act_bf16[i])
            );
        end
    endgenerate

    // Connect registers to skewing block
    generate
        for (genvar i = 0; i < PE_SIZE; i++) begin : gen_skew_in
            assign act_to_skew[i] = act_bf16_reg[i];
            assign sum_to_skew[i] = (row_tile == 0) ? 32'b0 : accum_ram_rd_data_reg[i];
            assign val_to_skew[i] = val_read_valid;
        end
    endgenerate

    // ----------------------------------------------------
    // Skewing Delay Lines (Align inputs to the 2D array)
    // ----------------------------------------------------
    generate
        for (genvar i = 0; i < PE_SIZE; i++) begin : gen_act_skew
            delay_line #(
                .WIDTH(16),
                .DELAY(17 * i)
            ) u_act_delay (
                .clk(clk),
                .rst_n(rst_n),
                .din(act_to_skew[i]),
                .dout(systolic_x_in[i])
            );
        end
        
        for (genvar j = 0; j < PE_SIZE; j++) begin : gen_sum_skew
            delay_line #(
                .WIDTH(32),
                .DELAY(j)
            ) u_sum_delay (
                .clk(clk),
                .rst_n(rst_n),
                .din(sum_to_skew[j]),
                .dout(systolic_s_in[j])
            );
            
            delay_line #(
                .WIDTH(1),
                .DELAY(j)
            ) u_val_delay (
                .clk(clk),
                .rst_n(rst_n),
                .din(val_to_skew[j]),
                .dout(systolic_val_in[j])
            );
        end
    endgenerate

    // Instantiate Systolic Array
    systolic_array #(
        .PE_SIZE(PE_SIZE)
    ) u_systolic_array (
        .clk(clk),
        .rst_n(rst_n),
        .weight_in(systolic_weight_in),
        .weight_en(systolic_weight_en),
        .x_in(systolic_x_in),
        .valid_in(systolic_val_in),
        .s_in(systolic_s_in),
        .x_out(systolic_x_out),
        .s_out(systolic_s_out),
        .valid_out(systolic_val_out)
    );

    // ----------------------------------------------------
    // Deskewing Delay Lines (Align outputs from the 2D array)
    // ----------------------------------------------------
    generate
        for (genvar j = 0; j < PE_SIZE; j++) begin : gen_out_deskew
            delay_line #(
                .WIDTH(32),
                .DELAY(PE_SIZE - 1 - j)
            ) u_out_delay (
                .clk(clk),
                .rst_n(rst_n),
                .din(systolic_s_out[j]),
                .dout(deskewed_s_out[j])
            );
            
            delay_line #(
                .WIDTH(1),
                .DELAY(PE_SIZE - 1 - j)
            ) u_val_delay (
                .clk(clk),
                .rst_n(rst_n),
                .din(systolic_val_out[j]),
                .dout(deskewed_val_out[j])
            );
        end
    endgenerate

    // Write back outputs to accumulation RAM or downstream buffer
    assign out_wr_en      = (state == ST_COMPUTE && deskewed_val_out[0] && row_tile == num_row_tiles - 1);
    assign out_wr_addr    = wr_cnt[$clog2(SEQ_LEN)-1:0];
    assign out_wr_col_grp = col_tile[$clog2(D_MODEL/PE_SIZE)-1:0];
    assign out_dest       = proj_sel_reg;
    assign out_wr_data    = deskewed_s_out;

    assign accum_ram_wr_en   = (state == ST_COMPUTE && deskewed_val_out[0] && row_tile != num_row_tiles - 1);
    assign accum_ram_wr_addr = wr_cnt[$clog2(SEQ_LEN)-1:0];
    assign accum_ram_wr_data = deskewed_s_out;

    // Accumulation RAM
    always_ff @(posedge clk) begin
        if (accum_ram_wr_en) begin
            accum_ram[accum_ram_wr_addr] <= accum_ram_wr_data;
        end
    end
    
    always_ff @(posedge clk) begin
        if (accum_ram_rd_en) begin
            accum_ram_rd_data <= accum_ram[accum_ram_rd_addr];
        end
    end

endmodule


// Helper module: delay line for pipeline registers
module delay_line #(
    parameter WIDTH = 16,
    parameter DELAY = 0
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic [WIDTH-1:0] din,
    output logic [WIDTH-1:0] dout
);
    if (DELAY == 0) begin : gen_no_delay
        assign dout = din;
    end else begin : gen_delay
        logic [WIDTH-1:0] shift_reg [0:DELAY-1];
        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                for (int i = 0; i < DELAY; i++) begin
                    shift_reg[i] <= {WIDTH{1'b0}};
                end
            end else begin
                shift_reg[0] <= din;
                for (int i = 1; i < DELAY; i++) begin
                    shift_reg[i] <= shift_reg[i-1];
                end
            end
        end
        assign dout = shift_reg[DELAY-1];
    end
endmodule
