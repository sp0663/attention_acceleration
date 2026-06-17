module bf16_mac (
    input logic clk,
    input logic rst_n,
    input logic clr_acc,
    input logic valid_in,
    input logic [15:0] a,
    input logic [15:0] b,
    output logic [31:0] result,
    output logic valid_out
);
    logic [31:0] a_fp32, b_fp32;
    logic [31:0] product;
    logic product_valid;
    logic sum_valid;
    logic [31:0] accumulator;
    logic [31:0] sum_out;

    bf16_to_fp32 u_a (.bf16_in(a), .fp32_out(a_fp32));
    bf16_to_fp32 u_b (.bf16_in(b), .fp32_out(b_fp32));

    floating_point_0 fp32_multiplier (
        .aclk(clk),
        .aclken(valid_in),
        .s_axis_a_tvalid(valid_in),
        .s_axis_a_tready(),
        .s_axis_a_tdata(a_fp32),
        .s_axis_b_tvalid(valid_in),
        .s_axis_b_tready(),
        .s_axis_b_tdata(b_fp32),
        .m_axis_result_tvalid(product_valid),
        .m_axis_result_tready(1'b1),
        .m_axis_result_tdata(product)
    );

    floating_point_1 fp32_adder (
        .aclk(clk),
        .aclken(product_valid),
        .s_axis_a_tvalid(product_valid),
        .s_axis_a_tready(),
        .s_axis_a_tdata(product),
        .s_axis_b_tvalid(product_valid),
        .s_axis_b_tready(),
        .s_axis_b_tdata(accumulator),
        .m_axis_result_tvalid(sum_valid),
        .m_axis_result_tready(1'b1),
        .m_axis_result_tdata(sum_out)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            accumulator <= 32'b0;
            result      <= 32'b0;
            valid_out   <= 1'b0;
        end else if (clr_acc) begin
            accumulator <= 32'b0;
        end else if (sum_valid) begin
            accumulator <= sum_out;
            result      <= sum_out;
            valid_out   <= 1'b1;
        end else begin
            valid_out   <= 1'b0;
        end
    end

endmodule