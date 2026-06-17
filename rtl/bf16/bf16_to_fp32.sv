module bf16_to_fp32 (
    input  logic [15:0] bf16_in,
    output logic [31:0] fp32_out
);
    // Convert BF16 to FP32
    assign fp32_out = {bf16_in, 16'b0};

endmodule