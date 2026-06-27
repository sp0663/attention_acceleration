module systolic_pe (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        valid_in,   // indicates valid activation and partial sum from top/left
    input  logic [15:0] x_in,       // activation from left
    input  logic [15:0] weight_in,  // weight from top
    input  logic        weight_en,  // weight load enable
    input  logic [31:0] s_in,       // partial sum from top
    output logic [15:0] x_out,      // activation to right
    output logic [15:0] weight_out, // weight to bottom
    output logic [31:0] s_out,      // partial sum to bottom
    output logic        valid_out   // indicates valid partial sum to bottom
);

    logic [15:0] w;

    // Weight stationary register and shift logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w          <= 16'b0;
            weight_out <= 16'b0;
        end else if (weight_en) begin
            w          <= weight_in;
            weight_out <= weight_in;
        end
    end

    // Activation propagation pipeline register
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_out <= 16'b0;
        end else begin
            x_out <= x_in;
        end
    end

    // Multiply-Accumulate unit
    bf16_mac u_mac (
        .clk(clk),
        .valid_in(valid_in),
        .a(x_in),
        .b(w),
        .c(s_in),
        .result(s_out),
        .valid_out(valid_out)
    );

endmodule
