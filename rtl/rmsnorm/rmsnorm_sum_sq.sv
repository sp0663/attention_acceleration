module rmsnorm_sum_sq (
    input logic [15:0] d_in [0:15],
    input logic valid_in,
    input logic clr,
    input logic clk,
    input logic rst_n,
    output logic [31:0] sum_sq,
    output logic valid_out
);

    logic [31:0] d_fp32 [0:15];
    logic [31:0] square [0:15];
    logic sq_valid [0:15];
    logic [31:0] sq_sum_1 [0:7];
    logic sq_sum_1_valid [0:7];
    logic [31:0] sq_sum_2 [0:3];
    logic sq_sum_2_valid [0:3];
    logic [31:0] sq_sum_3 [0:1];
    logic sq_sum_3_valid [0:1];
    logic [31:0] final_sum;
    logic final_sum_valid;
    logic [31:0] accum_out;
    logic accum_valid;
    logic [31:0] accumulator;
    logic [31:0] final_sum_delay [0:11];

    // BF16 to FP32 conversion
    generate
        for (genvar i = 0; i < 16; i++) begin : gen_bf16_to_fp32
            bf16_to_fp32 u_bf16_to_fp32 (
                .bf16_in(d_in[i]),
                .fp32_out(d_fp32[i])
            );
        end
    endgenerate

    // 16 squarers
    generate
        for (genvar i = 0; i < 16; i++) begin : gen_fp32_multiplier
            floating_point_0 u_fp32_multiplier (
                .aclk(clk),
                .aclken(1'b1),
                .s_axis_a_tvalid(valid_in),
                .s_axis_a_tready(),
                .s_axis_a_tdata(d_fp32[i]),
                .s_axis_b_tvalid(valid_in),
                .s_axis_b_tready(),
                .s_axis_b_tdata(d_fp32[i]),
                .m_axis_result_tvalid(sq_valid[i]),
                .m_axis_result_tready(1'b1),
                .m_axis_result_tdata(square[i])
            );
        end
    endgenerate

    // Stage 1: 16 to 8
    generate
        for (genvar j = 0; j < 8; j++) begin : gen_adder_1
            floating_point_1 u_fp32_adder_1 (
                .aclk(clk),
                .aclken(1'b1),
                .s_axis_a_tvalid(sq_valid[2*j]),
                .s_axis_a_tready(),
                .s_axis_a_tdata(square[2*j]),
                .s_axis_b_tvalid(sq_valid[2*j+1]),
                .s_axis_b_tready(),
                .s_axis_b_tdata(square[2*j+1]),
                .m_axis_result_tvalid(sq_sum_1_valid[j]),
                .m_axis_result_tready(1'b1),
                .m_axis_result_tdata(sq_sum_1[j])
            );
        end
    endgenerate

    // Stage 2: 8 to 4
    generate
        for (genvar k = 0; k < 4; k++) begin : gen_adder_2
            floating_point_1 u_fp32_adder_2 (
                .aclk(clk),
                .aclken(1'b1),
                .s_axis_a_tvalid(sq_sum_1_valid[2*k]),
                .s_axis_a_tready(),
                .s_axis_a_tdata(sq_sum_1[2*k]),
                .s_axis_b_tvalid(sq_sum_1_valid[2*k+1]),
                .s_axis_b_tready(),
                .s_axis_b_tdata(sq_sum_1[2*k+1]),
                .m_axis_result_tvalid(sq_sum_2_valid[k]),
                .m_axis_result_tready(1'b1),
                .m_axis_result_tdata(sq_sum_2[k])
            );
        end
    endgenerate

    // Stage 3: 4 to 2
    generate
        for (genvar m = 0; m < 2; m++) begin : gen_adder_3
            floating_point_1 u_fp32_adder_3 (
                .aclk(clk),
                .aclken(1'b1),
                .s_axis_a_tvalid(sq_sum_2_valid[2*m]),
                .s_axis_a_tready(),
                .s_axis_a_tdata(sq_sum_2[2*m]),
                .s_axis_b_tvalid(sq_sum_2_valid[2*m+1]),
                .s_axis_b_tready(),
                .s_axis_b_tdata(sq_sum_2[2*m+1]),
                .m_axis_result_tvalid(sq_sum_3_valid[m]),
                .m_axis_result_tready(1'b1),
                .m_axis_result_tdata(sq_sum_3[m])
            );
        end
    endgenerate

    // Stage 4: 2 to 1
    floating_point_1 u_fp32_final_adder (
        .aclk(clk),
        .aclken(1'b1),
        .s_axis_a_tvalid(sq_sum_3_valid[0]),
        .s_axis_a_tready(),
        .s_axis_a_tdata(sq_sum_3[0]),
        .s_axis_b_tvalid(sq_sum_3_valid[1]),
        .s_axis_b_tready(),
        .s_axis_b_tdata(sq_sum_3[1]),
        .m_axis_result_tvalid(final_sum_valid),
        .m_axis_result_tready(1'b1),
        .m_axis_result_tdata(final_sum)
    );

    // 12-stage delay on final_sum to align with accumulator adder latency
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 12; i++) final_sum_delay[i] <= 32'b0;
        end else if (clr) begin
            for (int i = 0; i < 12; i++) final_sum_delay[i] <= 32'b0;
        end else if (final_sum_valid) begin
            final_sum_delay[0] <= final_sum;
            for (int i = 1; i < 12; i++) final_sum_delay[i] <= final_sum_delay[i-1];
        end
    end

    // Accumulator adder: accumulator + delayed final_sum
    floating_point_1 u_fp32_accum_adder (
        .aclk(clk),
        .aclken(1'b1),
        .s_axis_a_tvalid(final_sum_valid),
        .s_axis_a_tready(),
        .s_axis_a_tdata(accumulator),
        .s_axis_b_tvalid(final_sum_valid),
        .s_axis_b_tready(),
        .s_axis_b_tdata(final_sum_delay[11]),
        .m_axis_result_tvalid(accum_valid),
        .m_axis_result_tready(1'b1),
        .m_axis_result_tdata(accum_out)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            accumulator <= 32'b0;
            sum_sq      <= 32'b0;
            valid_out   <= 1'b0;
        end else if (clr) begin
            accumulator <= 32'b0;
            sum_sq      <= 32'b0;
            valid_out   <= 1'b0;
        end else if (accum_valid) begin
            accumulator <= accum_out;
            sum_sq      <= accum_out;
            valid_out   <= 1'b1;
        end else begin
            valid_out   <= 1'b0;
        end
    end

endmodule