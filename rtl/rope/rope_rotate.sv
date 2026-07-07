module rope_rotate #(
    parameter int HEAD_DIM  = 128,
    parameter int NUM_PAIRS = HEAD_DIM / 2,
    localparam int PAIR_W   = $clog2(NUM_PAIRS)
) (
    input  logic clk,
    input  logic rst_n,

    input  logic valid_in,
    input  logic [6:0] position,

    input  logic [15:0] x_in  [0:HEAD_DIM-1],

    output logic [15:0] x_out [0:HEAD_DIM-1],

    output logic valid_out,
    output logic ready_in
);

    typedef enum logic [1:0] {
        ST_IDLE  = 2'd0,
        ST_ISSUE = 2'd1,
        ST_DRAIN = 2'd2
    } state_t;

    state_t state;

    logic [PAIR_W-1:0] pair_cnt;
    logic issue_valid;

    assign issue_valid = (state == ST_ISSUE);

    // ============================================================
    // FSM and pair request counter
    // ============================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= ST_IDLE;
            pair_cnt  <= '0;
            ready_in  <= 1'b1;
        end
        else begin
            case (state)
                // Wait for new head
                ST_IDLE: begin
                    if (valid_in && ready_in) begin
                        pair_cnt <= '0;
                        ready_in <= 1'b0;
                        state    <= ST_ISSUE;
                    end
                end

                // Issue exactly: 0, 1, 2, ..., NUM_PAIRS-1
                ST_ISSUE: begin
                    if (pair_cnt == NUM_PAIRS - 1) begin
                        state <= ST_DRAIN;
                    end
                    else begin
                        pair_cnt <= pair_cnt + 1'b1;
                    end
                end

                // Wait for complete output head
                ST_DRAIN: begin
                    if (valid_out) begin
                        ready_in <= 1'b1;
                        state    <= ST_IDLE;
                    end
                end

                default: begin
                    state     <= ST_IDLE;
                    pair_cnt  <= '0;
                    ready_in  <= 1'b1;
                end
            endcase
        end
    end

    // ============================================================
    // Current BF16 input pair
    // ============================================================

    logic [15:0] current_x0_bf16;
    logic [15:0] current_x1_bf16;

    assign current_x0_bf16 = x_in[2 * pair_cnt];
    assign current_x1_bf16 = x_in[2 * pair_cnt + 1];

    // ============================================================
    // BF16 -> FP32
    // ============================================================

    logic [31:0] current_x0_fp32;
    logic [31:0] current_x1_fp32;

    bf16_to_fp32 u_bf16_to_fp32_0 (
        .bf16_in  (current_x0_bf16),
        .fp32_out (current_x0_fp32)
    );

    bf16_to_fp32 u_bf16_to_fp32_1 (
        .bf16_in  (current_x1_bf16),
        .fp32_out (current_x1_fp32)
    );

    // ============================================================
    // RoPE LUT (2-Cycle Latency)
    // ============================================================

    logic [63:0] lut_word;
    logic [31:0] sin_fp32;
    logic [31:0] cos_fp32;

    rope_lut u_lut_single (
        .clk      (clk),
        .position (position),
        .pair_idx (pair_cnt),
        .lut_data (lut_word)
    );

    assign sin_fp32 = lut_word[63:32];
    assign cos_fp32 = lut_word[31:0];

    // ============================================================
    // Input alignment registers (2 Stages)
    //
    // Matches the 2-cycle latency of the Vivado BRAM LUT so that
    // the x inputs arrive at the multipliers at the exact same
    // time as the trig outputs.
    // ============================================================

    // Stage 1
    logic [31:0] x0_reg_1;
    logic [31:0] x1_reg_1;
    logic math_valid_1;

    // Stage 2
    logic [31:0] x0_reg_2;
    logic [31:0] x1_reg_2;
    logic math_valid_2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x0_reg_1     <= '0;
            x1_reg_1     <= '0;
            math_valid_1 <= 1'b0;
            
            x0_reg_2     <= '0;
            x1_reg_2     <= '0;
            math_valid_2 <= 1'b0;
        end
        else begin
            // Stage 1: Latch data from conversion
            math_valid_1 <= issue_valid;
            if (issue_valid) begin
                x0_reg_1 <= current_x0_fp32;
                x1_reg_1 <= current_x1_fp32;
            end

            // Stage 2: Delay one more cycle to align with BRAM
            math_valid_2 <= math_valid_1;
            x0_reg_2     <= x0_reg_1;
            x1_reg_2     <= x1_reg_1;
        end
    end

    // ============================================================
    // FP multiplier signals
    // ============================================================

    logic [31:0] x0_cos_fp32;
    logic [31:0] x1_sin_fp32;
    logic [31:0] x0_sin_fp32;
    logic [31:0] x1_cos_fp32;

    logic x0_cos_valid;
    logic x1_sin_valid;
    logic x0_sin_valid;
    logic x1_cos_valid;

    // ============================================================
    // The 4 Multipliers (Using Stage 2 inputs)
    // ============================================================

    floating_point_0 u_mul_x0_cos (
        .aclk                 (clk),
        .s_axis_a_tvalid      (math_valid_2),
        .s_axis_a_tdata       (x0_reg_2),
        .s_axis_b_tvalid      (math_valid_2),
        .s_axis_b_tdata       (cos_fp32),
        .m_axis_result_tvalid (x0_cos_valid),
        .m_axis_result_tdata  (x0_cos_fp32)
    );

    floating_point_0 u_mul_x1_sin (
        .aclk                 (clk),
        .s_axis_a_tvalid      (math_valid_2),
        .s_axis_a_tdata       (x1_reg_2),
        .s_axis_b_tvalid      (math_valid_2),
        .s_axis_b_tdata       (sin_fp32),
        .m_axis_result_tvalid (x1_sin_valid),
        .m_axis_result_tdata  (x1_sin_fp32)
    );

    floating_point_0 u_mul_x0_sin (
        .aclk                 (clk),
        .s_axis_a_tvalid      (math_valid_2),
        .s_axis_a_tdata       (x0_reg_2),
        .s_axis_b_tvalid      (math_valid_2),
        .s_axis_b_tdata       (sin_fp32),
        .m_axis_result_tvalid (x0_sin_valid),
        .m_axis_result_tdata  (x0_sin_fp32)
    );

    floating_point_0 u_mul_x1_cos (
        .aclk                 (clk),
        .s_axis_a_tvalid      (math_valid_2),
        .s_axis_a_tdata       (x1_reg_2),
        .s_axis_b_tvalid      (math_valid_2),
        .s_axis_b_tdata       (cos_fp32),
        .m_axis_result_tvalid (x1_cos_valid),
        .m_axis_result_tdata  (x1_cos_fp32)
    );

    // ============================================================
    // Floating-point negation
    // ============================================================

    logic [31:0] x1_sin_neg_fp32;

    assign x1_sin_neg_fp32 = {
        ~x1_sin_fp32[31],
         x1_sin_fp32[30:0]
    };

    // ============================================================
    // FP adder outputs
    // ============================================================

    logic [31:0] rot0_fp32;
    logic [31:0] rot1_fp32;

    logic rot0_valid;
    logic rot1_valid;

    // ============================================================
    // rot0 = x0*cos - x1*sin
    // ============================================================

    floating_point_1 u_add_rot0 (
        .aclk                 (clk),
        .s_axis_a_tvalid      (x0_cos_valid),
        .s_axis_a_tdata       (x0_cos_fp32),
        .s_axis_b_tvalid      (x1_sin_valid),
        .s_axis_b_tdata       (x1_sin_neg_fp32),
        .m_axis_result_tvalid (rot0_valid),
        .m_axis_result_tdata  (rot0_fp32)
    );

    // ============================================================
    // rot1 = x0*sin + x1*cos
    // ============================================================

    floating_point_1 u_add_rot1 (
        .aclk                 (clk),
        .s_axis_a_tvalid      (x0_sin_valid),
        .s_axis_a_tdata       (x0_sin_fp32),
        .s_axis_b_tvalid      (x1_cos_valid),
        .s_axis_b_tdata       (x1_cos_fp32),
        .m_axis_result_tvalid (rot1_valid),
        .m_axis_result_tdata  (rot1_fp32)
    );

    // ============================================================
    // FP32 -> BF16
    // ============================================================

    logic [15:0] rot0_bf16;
    logic [15:0] rot1_bf16;

    fp32_to_bf16 u_out_0 (
        .fp32_in  (rot0_fp32),
        .bf16_out (rot0_bf16)
    );

    fp32_to_bf16 u_out_1 (
        .fp32_in  (rot1_fp32),
        .bf16_out (rot1_bf16)
    );

    // ============================================================
    // Ordered result write counter
    // ============================================================

    logic [PAIR_W-1:0] write_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_cnt <= '0;
            valid_out <= 1'b0;
        end
        else begin
            valid_out <= 1'b0;

            if (valid_in && ready_in) begin
                write_cnt <= '0;
            end

            if (rot0_valid && rot1_valid) begin
                x_out[2 * write_cnt]     <= rot0_bf16;
                x_out[2 * write_cnt + 1] <= rot1_bf16;

                if (write_cnt == NUM_PAIRS - 1) begin
                    write_cnt <= '0;
                    valid_out <= 1'b1;
                end
                else begin
                    write_cnt <= write_cnt + 1'b1;
                end
            end
        end
    end

endmodule