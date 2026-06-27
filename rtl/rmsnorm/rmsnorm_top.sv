module rmsnorm_top(
    input  logic clk,
    input  logic rst_n,
    input  logic valid_in,
    input  logic clr,
    input  logic [15:0] x_in [0:15],
    input  logic [31:0] gamma [0:15],
    input  logic gamma_valid,
    output logic [15:0] x_out [0:15],
    output logic valid_out,
    output logic ready_out
);

    // sum of squares 
    logic [31:0] sum_sq;
    logic sum_sq_valid;

    rmsnorm_sum_sq u_sum_sq (
        .d_in(x_in),
        .valid_in(valid_in),
        .clr(clr),
        .clk(clk),
        .rst_n(rst_n),
        .sum_sq(sum_sq),
        .valid_out(sum_sq_valid)
    );

    //  reciprocal square root
    logic [31:0] rsqrt;
    logic rsqrt_valid;

    rmsnorm_rsqrt u_rsqrt (
        .clk(clk),
        .valid_in(sum_sq_valid),
        .sum_sq(sum_sq),
        .rsqrt(rsqrt),
        .valid_out(rsqrt_valid)
    );

    // latch rsqrt scalar — holds until all 256 groups are scaled
    logic [31:0] rsqrt_reg;
    logic rsqrt_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rsqrt_reg   <= 32'b0;
            rsqrt_ready <= 1'b0;
            ready_out   <= 1'b0;
        end else if (clr) begin
            rsqrt_reg   <= 32'b0;
            rsqrt_ready <= 1'b0;
            ready_out   <= 1'b0;
        end else if (rsqrt_valid) begin
            rsqrt_reg   <= rsqrt;
            rsqrt_ready <= 1'b1;
            ready_out   <= 1'b1;   // tell FSM rsqrt is ready, start streaming gamma + x
        end else begin
            ready_out   <= 1'b0;   // pulse for one cycle only
        end
    end

    // stage 1: x[i] × gamma[i] 
    // x_in is BF16, convert to FP32 first
    // gamma is already FP32
    // gated by gamma_valid

    logic [31:0] x_fp32    [0:15];
    logic [31:0] xg_result [0:15];
    logic xg_valid  [0:15];

    generate
        for (genvar i = 0; i < 16; i++) begin : gen_x_fp32
            bf16_to_fp32 u_bf16_to_fp32 (
                .bf16_in(x_in[i]),
                .fp32_out(x_fp32[i])
            );
        end
    endgenerate

    generate
        for (genvar i = 0; i < 16; i++) begin : gen_xgamma_mul
            floating_point_0 u_xgamma_mul (
                .aclk(clk),
                .aclken(1'b1),
                .s_axis_a_tvalid(gamma_valid),
                .s_axis_a_tready(),
                .s_axis_a_tdata(x_fp32[i]),
                .s_axis_b_tvalid(gamma_valid),
                .s_axis_b_tready(),
                .s_axis_b_tdata(gamma[i]),
                .m_axis_result_tvalid(xg_valid[i]),
                .m_axis_result_tready(1'b1),
                .m_axis_result_tdata(xg_result[i])
            );
        end
    endgenerate

    // stage 2: xg_result[i] × rsqrt
    // rsqrt_reg is broadcast to all 16 multipliers

    logic [31:0] scaled [0:15];
    logic scaled_valid [0:15];

    generate
        for (genvar i = 0; i < 16; i++) begin : gen_scale_mul
            floating_point_0 u_scale_mul (
                .aclk(clk),
                .aclken(1'b1),
                .s_axis_a_tvalid(xg_valid[i]),
                .s_axis_a_tready(),
                .s_axis_a_tdata(xg_result[i]),
                .s_axis_b_tvalid(xg_valid[i]),
                .s_axis_b_tready(),
                .s_axis_b_tdata(rsqrt_reg),
                .m_axis_result_tvalid(scaled_valid[i]),
                .m_axis_result_tready(1'b1),
                .m_axis_result_tdata(scaled[i])
            );
        end
    endgenerate

    // convert FP32 back to BF16 
    generate
        for (genvar i = 0; i < 16; i++) begin : gen_fp32_to_bf16
            fp32_to_bf16 u_fp32_to_bf16 (
                .fp32_in(scaled[i]),
                .bf16_out(x_out[i])
            );
        end
    endgenerate

    // valid_out — all 16 channels share the same valid since they're identical pipelines
    // use channel 0 as representative
    assign valid_out = scaled_valid[0];

endmodule