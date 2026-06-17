module fp32_to_bf16 (
    input logic [31:0] fp32_in,
    output logic [15:0] bf16_out
);
    logic guard_bit;
    logic sticky_bit;
    logic kept_bit;

    assign guard_bit = fp32_in[15];
    assign sticky_bit = |fp32_in[14:0];
    assign kept_bit = fp32_in[16];
    
    // Convert FP32 to BF16
    always_comb begin
        if (&fp32_in[30:23]) begin
            bf16_out = {fp32_in[31], 8'hFF, fp32_in[22:16]};
        end
        else begin
            if (guard_bit == 0) begin
                bf16_out = {fp32_in[31:16]};
            end
            else if (guard_bit == 1 && sticky_bit == 1) begin
                bf16_out = {fp32_in[31], (fp32_in[30:16] + 1'b1)};
            end
            else if (guard_bit == 1 && sticky_bit == 0) begin
                if (kept_bit == 1) begin
                    bf16_out = {fp32_in[31], (fp32_in[30:16] + 1'b1)};
                end else begin
                    bf16_out = {fp32_in[31:16]};
                end else begin
                    bf16_out = fp32_in[31:16];
                end
            end
        end
    end

endmodule