

module tiled_systolic #(
    parameter SEQ_LEN     = 4,  
    parameter HEAD_DIM    = 4,  
    parameter SEQ_LEN_2   = 2,    // Sub-tile size along SEQ_LEN
    parameter HEAD_DIM_2  = 2     // Sub-tile size along HEAD_DIM
)(
    input  logic        clk, rst_n, start,
    input  logic [15:0] Q[SEQ_LEN-1:0][HEAD_DIM-1:0],
    input  logic [15:0] K[SEQ_LEN-1:0][HEAD_DIM-1:0],
    output logic [31:0] score[SEQ_LEN-1:0][SEQ_LEN-1:0],
    output logic        valid_out
);

    localparam NUM_I_TILES = SEQ_LEN / SEQ_LEN_2;
    localparam NUM_J_TILES = SEQ_LEN / SEQ_LEN_2;
    localparam NUM_K_TILES = HEAD_DIM / HEAD_DIM_2;
    
    localparam IP_LATENCY = 11;

    typedef enum logic [2:0] {
        IDLE,
        START_TILE,
        WAIT_TILE,
        SEND_ADD_PULSE,
        WAIT_ADD_LATENCY,
        NEXT_SUB_CELL,
        NEXT_TILE,
        DONE
    } state_t;

    state_t state;

    int i_tile, j_tile, k_tile;
    int acc_r, acc_c;
    int latency_cnt;

    int global_r, global_c;

    logic [15:0] sub_Q[SEQ_LEN_2-1:0][HEAD_DIM_2-1:0];
    logic [15:0] sub_K[SEQ_LEN_2-1:0][HEAD_DIM_2-1:0];
    logic [31:0] sub_score[SEQ_LEN_2-1:0][SEQ_LEN_2-1:0];
    logic        grid_start;
    logic        grid_valid_out;

    logic [31:0] accum_mem[SEQ_LEN-1:0][SEQ_LEN-1:0];

    array_grid #(
        .SEQ_LEN(SEQ_LEN_2),
        .HEAD_DIM(HEAD_DIM_2)
    ) grid_inst (
        .clk(clk),
        .rst_n(rst_n),
        .start(grid_start),
        .Q(sub_Q),
        .K(sub_K),
        .score(sub_score),
        .valid_out(grid_valid_out)
    );

    logic        adder_a_valid, adder_b_valid, adder_out_valid;
    logic [31:0] adder_a_data, adder_b_data, adder_out_data;

   floating_point_0 fp_add_inst (
        .aclk(clk),
        .s_axis_a_tvalid(adder_a_valid),
        .s_axis_a_tdata(adder_a_data),
        .s_axis_b_tvalid(adder_b_valid),
        .s_axis_b_tdata(adder_b_data),
        .m_axis_result_tvalid(adder_out_valid),
        .m_axis_result_tdata(adder_out_data)
    );

    always_comb begin
        for (int r = 0; r < SEQ_LEN_2; r++) begin
            for (int c = 0; c < HEAD_DIM_2; c++) begin
                sub_Q[r][c] = Q[i_tile * SEQ_LEN_2 + r][k_tile * HEAD_DIM_2 + c];
                sub_K[r][c] = K[j_tile * SEQ_LEN_2 + r][k_tile * HEAD_DIM_2 + c];
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= IDLE;
            i_tile        <= 0;
            j_tile        <= 0;
            k_tile        <= 0;
            acc_r         <= 0;
            acc_c         <= 0;
            global_r      <= 0;
            global_c      <= 0;
            latency_cnt   <= 0;
            grid_start    <= 1'b0;
            valid_out     <= 1'b0;
            adder_a_valid <= 1'b0;
            adder_b_valid <= 1'b0;

            for (int r = 0; r < SEQ_LEN; r++) begin
                for (int c = 0; c < SEQ_LEN; c++) begin
                    accum_mem[r][c] <= 32'h00000000;
                    score[r][c]     <= 32'h00000000;
                end
            end
        end else begin
            case (state)
                IDLE: begin
                    valid_out     <= 1'b0;
                    grid_start    <= 1'b0;
                    adder_a_valid <= 1'b0;
                    adder_b_valid <= 1'b0;

                    if (start) begin
                        i_tile     <= 0;
                        j_tile     <= 0;
                        k_tile     <= 0;
                        state      <= START_TILE;

                        for (int r = 0; r < SEQ_LEN; r++) begin
                            for (int c = 0; c < SEQ_LEN; c++) begin
                                accum_mem[r][c] <= 32'h00000000;
                            end
                        end
                    end
                end

                START_TILE: begin
                    grid_start <= 1'b1;
                    state      <= WAIT_TILE;
                end

                WAIT_TILE: begin
                    grid_start <= 1'b0; 
                    if (grid_valid_out) begin
                        acc_r <= 0;
                        acc_c <= 0;
                        state <= SEND_ADD_PULSE;
                    end
                end

                SEND_ADD_PULSE: begin
                    global_r <= i_tile * SEQ_LEN_2 + acc_r;
                    global_c <= j_tile * SEQ_LEN_2 + acc_c;

                    adder_a_data  <= accum_mem[i_tile * SEQ_LEN_2 + acc_r][j_tile * SEQ_LEN_2 + acc_c];
                    adder_b_data  <= sub_score[acc_r][acc_c];
                    
                    adder_a_valid <= 1'b1;
                    adder_b_valid <= 1'b1;
                    
                    latency_cnt   <= 0;
                    state         <= WAIT_ADD_LATENCY;
                end

                WAIT_ADD_LATENCY: begin
                    adder_a_valid <= 1'b0;
                    adder_b_valid <= 1'b0;

                    if (adder_out_valid || (latency_cnt == IP_LATENCY)) begin
                        accum_mem[global_r][global_c] <= adder_out_data;
                        latency_cnt <=1'b0;
                        state                         <= NEXT_SUB_CELL;
                    end else begin
                        latency_cnt <= latency_cnt + 1;
                    end
                end

                NEXT_SUB_CELL: begin
                    if (acc_c + 1 < SEQ_LEN_2) begin
                        acc_c <= acc_c + 1;
                        state <= SEND_ADD_PULSE;
                    end else begin
                        acc_c <= 0;
                        if (acc_r + 1 < SEQ_LEN_2) begin
                            acc_r <= acc_r + 1;
                            state <= SEND_ADD_PULSE;
                        end else begin
                            state <= NEXT_TILE;
                        end
                    end
                end

                NEXT_TILE: begin
                    if (k_tile + 1 < NUM_K_TILES) begin
                        k_tile <= k_tile + 1;
                        state  <= START_TILE;
                    end else begin
                        k_tile <= 0;
                        if (j_tile + 1 < NUM_J_TILES) begin
                            j_tile <= j_tile + 1;
                            state  <= START_TILE;
                        end else begin
                            j_tile <= 0;
                            if (i_tile + 1 < NUM_I_TILES) begin
                                i_tile <= i_tile + 1;
                                state  <= START_TILE;
                            end else begin
                                state <= DONE;
                            end
                        end
                    end
                end

                DONE: begin
                    for (int r = 0; r < SEQ_LEN; r++) begin
                        for (int c = 0; c < SEQ_LEN; c++) begin
                            score[r][c] <= accum_mem[r][c];
                        end
                    end
                    valid_out <= 1'b1;
                    state     <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
