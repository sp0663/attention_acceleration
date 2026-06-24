module bf16_mac (
    input  logic clk,
    input  logic valid_in,
    input  logic [15:0] a,
    input  logic [15:0] b,
    input  logic [31:0] c,
    output logic [31:0] result,
    output logic valid_out
);
    logic [31:0] a_fp32, b_fp32;

    bf16_to_fp32 u_a (.bf16_in(a), .fp32_out(a_fp32));
    bf16_to_fp32 u_b (.bf16_in(b), .fp32_out(b_fp32));

    floating_point_2 fp32_fma (
        .aclk(clk),
        .s_axis_a_tvalid(valid_in),
        .s_axis_a_tready(),
        .s_axis_a_tdata(a_fp32),
        .s_axis_b_tvalid(valid_in),
        .s_axis_b_tready(),
        .s_axis_b_tdata(b_fp32),
        .s_axis_c_tvalid(valid_in),
        .s_axis_c_tready(),
        .s_axis_c_tdata(c),
        .m_axis_result_tvalid(valid_out),
        .m_axis_result_tready(1'b1),
        .m_axis_result_tdata(result)
    );

endmodule