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
    logic accum_delay_valid [0:15];
    logic [31:0] sq_sum_1 [0:7];
    logic [31:0] accum_sum_1 [0:7];
    logic sq_sum_1_valid [0:7];
    logic accum_sum_1_valid [0:7];
    logic [31:0] sq_sum_2 [0:3];
    logic [31:0] accum_sum_2 [0:3];
    logic sq_sum_2_valid [0:3];
    logic accum_sum_2_valid [0:3];
    logic [31:0] sq_sum_3 [0:1];
    logic [31:0] accum_sum_3 [0:1];
    logic sq_sum_3_valid [0:1];
    logic accum_sum_3_valid [0:1];
    logic [31:0] final_sum;
    logic [31:0] final_accum_sum;
    logic final_sum_valid;
    logic final_accum_sum_valid;
    logic [31:0] accum_out [0:15];
    logic accum_valid [0:15];
    logic [31:0] accumulator [0:15];
    logic [15:0] current_accum;
    logic [8:0] group_count;      
    logic all_accum_done;
    logic [3:0] drain_count;
    logic drain_active;

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

    generate
        for (genvar n = 0; n < 16; n++) begin: gen_accum_adder
            floating_point_1 u_fp32_accum_adder (
                .aclk(clk),
                .aclken(1'b1),
                .s_axis_a_tvalid(final_sum_valid && current_accum[n]),
                .s_axis_a_tready(),
                .s_axis_a_tdata(final_sum),
                .s_axis_b_tvalid(final_sum_valid && current_accum[n]),
                .s_axis_b_tready(),
                .s_axis_b_tdata(accumulator[n]),
                .m_axis_result_tvalid(accum_valid[n]),
                .m_axis_result_tready(1'b1),
                .m_axis_result_tdata(accum_out[n])
            );
        end
    endgenerate

    // Stage 1: 16 to 8
    generate
        for (genvar j = 0; j < 8; j++) begin : gen_accum_adder_1
            floating_point_1 u_fp32_accum_adder_1 (
                .aclk(clk),
                .aclken(1'b1),
                .s_axis_a_tvalid(accum_delay_valid[2*j]),
                .s_axis_a_tready(),
                .s_axis_a_tdata(accumulator[2*j]),
                .s_axis_b_tvalid(accum_delay_valid[2*j+1]),
                .s_axis_b_tready(),
                .s_axis_b_tdata(accumulator[2*j+1]),
                .m_axis_result_tvalid(accum_sum_1_valid[j]),
                .m_axis_result_tready(1'b1),
                .m_axis_result_tdata(accum_sum_1[j])
            );
        end
    endgenerate

    // Stage 2: 8 to 4
    generate
        for (genvar k = 0; k < 4; k++) begin : gen_accum_adder_2
            floating_point_1 u_fp32_accum_adder_2 (
                .aclk(clk),
                .aclken(1'b1),
                .s_axis_a_tvalid(accum_sum_1_valid[2*k]),
                .s_axis_a_tready(),
                .s_axis_a_tdata(accum_sum_1[2*k]),
                .s_axis_b_tvalid(accum_sum_1_valid[2*k+1]),
                .s_axis_b_tready(),
                .s_axis_b_tdata(accum_sum_1[2*k+1]),
                .m_axis_result_tvalid(accum_sum_2_valid[k]),
                .m_axis_result_tready(1'b1),
                .m_axis_result_tdata(accum_sum_2[k])
            );
        end
    endgenerate

    // Stage 3: 4 to 2
    generate
        for (genvar m = 0; m < 2; m++) begin : gen_accum_adder_3
            floating_point_1 u_fp32_accum_adder_3 (
                .aclk(clk),
                .aclken(1'b1),
                .s_axis_a_tvalid(accum_sum_2_valid[2*m]),
                .s_axis_a_tready(),
                .s_axis_a_tdata(accum_sum_2[2*m]),
                .s_axis_b_tvalid(accum_sum_2_valid[2*m+1]),
                .s_axis_b_tready(),
                .s_axis_b_tdata(accum_sum_2[2*m+1]),
                .m_axis_result_tvalid(accum_sum_3_valid[m]),
                .m_axis_result_tready(1'b1),
                .m_axis_result_tdata(accum_sum_3[m])
            );
        end
    endgenerate

    // Stage 4: 2 to 1
    floating_point_1 u_fp32_final_accum_adder (
        .aclk(clk),
        .aclken(1'b1),
        .s_axis_a_tvalid(accum_sum_3_valid[0]),
        .s_axis_a_tready(),
        .s_axis_a_tdata(accum_sum_3[0]),
        .s_axis_b_tvalid(accum_sum_3_valid[1]),
        .s_axis_b_tready(),
        .s_axis_b_tdata(accum_sum_3[1]),
        .m_axis_result_tvalid(final_accum_sum_valid),
        .m_axis_result_tready(1'b1),
        .m_axis_result_tdata(final_accum_sum)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_accum <= 16'b1;
        end else if (clr) begin
            current_accum <= 16'b1;
        end else if (final_sum_valid) begin
            current_accum <= (current_accum == 16'h8000) ? 16'b1 : (current_accum << 1);
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        for (int i = 0; i < 16; i++) begin
            if (!rst_n) begin
                accumulator[i] <= 32'b0;
            end
            else if (clr) begin
                accumulator[i] <= 32'b0;
            end
            else if (accum_valid[i]) begin
                accumulator[i] <= accum_out[i];
            end
            else begin
                accumulator[i] <= accumulator[i];
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_sq      <= 32'b0;
            valid_out   <= 1'b0;
        end else if (final_accum_sum_valid) begin
            sum_sq      <= final_accum_sum;
            valid_out   <= 1'b1;
        end else begin
            valid_out   <= 1'b0;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            group_count <= 9'b0;
        end else if (clr) begin
            group_count <= 9'b0;
        end else if (final_sum_valid) begin
            group_count <= group_count + 1'b1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            drain_active <= 1'b0;
            drain_count  <= 4'b0;
            accum_delay_valid <= 1'b0;
        end else if (clr) begin
            drain_active <= 1'b0;
            drain_count  <= 4'b0;
            accum_delay_valid <= 1'b0;
        end else if (group_count == 9'd256 && !drain_active) begin
            drain_active <= 1'b1;
            drain_count  <= 4'b0;
        end else if (drain_active) begin
            if (drain_count == 4'd11) begin   // wait one adder latency (12 cycles) for last accum to settle
                for (int i = 0; i < 16; i++) accum_delay_valid[i] <= 1'b1;
                drain_active <= 1'b0;
            end else begin
                drain_count <= drain_count + 1'b1;
            end
        end else begin
            accum_delay_valid <= 1'b0;
        end
    end

endmodule