`timescale 1ns / 1ps

module attention_step5_top #(
    parameter SEQ_LEN     = 4,
    parameter HEAD_DIM    = 4,
    parameter SEQ_LEN_2   = 2,
    parameter HEAD_DIM_2  = 2
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    
    input  logic [15:0] Q[SEQ_LEN-1:0][HEAD_DIM-1:0],
    input  logic [15:0] K[SEQ_LEN-1:0][HEAD_DIM-1:0],
    
    output logic [31:0] masked_scores[SEQ_LEN-1:0][SEQ_LEN-1:0],
    output logic        valid_out
);

    logic [31:0] raw_score[SEQ_LEN-1:0][SEQ_LEN-1:0];
    logic        systolic_valid;

    logic [31:0] scaled_score[SEQ_LEN-1:0][SEQ_LEN-1:0];
    logic        scaler_valid;

    tiled_systolic #(
        .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM),
        .SEQ_LEN_2(SEQ_LEN_2),
        .HEAD_DIM_2(HEAD_DIM_2)
    ) u_tiled_systolic (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .Q(Q),
        .K(K),
        .score(raw_score),
        .valid_out(systolic_valid)
    );

    attention_scaler #(
        .SEQ_LEN(SEQ_LEN)
    ) u_attention_scaler (
        .aclk(clk),
        .aresetn(rst_n),
        .start_scale(systolic_valid),
        .raw_score_matrix(raw_score),
        .scaled_score_matrix(scaled_score),
        .scale_valid_out(scaler_valid)
    );

    causal_mask #(
        .N(SEQ_LEN)  
    ) u_causal_mask (
        .clk(clk),
        .rst_n(rst_n),
        .start(scaler_valid),
        .raw_matrix(scaled_score),
        .masked_matrix(masked_scores),
        .valid_out(valid_out)
    );

endmodule
