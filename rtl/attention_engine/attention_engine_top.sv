`timescale 1ns / 1ps

module attention_mha_top #(
    parameter NUM_HEADS  = 32,
    parameter SEQ_LEN    = 128,
    parameter HEAD_DIM   = 128,
    parameter SEQ_LEN_2  = 16,
    parameter HEAD_DIM_2 = 16
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    
    input  logic [15:0] Q [NUM_HEADS-1:0][SEQ_LEN-1:0][HEAD_DIM-1:0],
    input  logic [15:0] K [NUM_HEADS-1:0][SEQ_LEN-1:0][HEAD_DIM-1:0],
    
    output logic [31:0] masked_scores [NUM_HEADS-1:0][SEQ_LEN-1:0][SEQ_LEN-1:0],
    output logic        valid_out
);

    logic [NUM_HEADS-1:0] head_valid;

    genvar h;
    generate
        for (h = 0; h < NUM_HEADS; h++) begin : gen_attention_heads
            attention_step5_top #(
                .SEQ_LEN(SEQ_LEN),
                .HEAD_DIM(HEAD_DIM),
                .SEQ_LEN_2(SEQ_LEN_2),
                .HEAD_DIM_2(HEAD_DIM_2)
            ) u_head_pipeline (
                .clk(clk),
                .rst_n(rst_n),
                .start(start),
                .Q(Q[h]),
                .K(K[h]),
                .masked_scores(masked_scores[h]),
                .valid_out(head_valid[h])
            );
        end
    endgenerate

    assign valid_out = &head_valid;

endmodule
