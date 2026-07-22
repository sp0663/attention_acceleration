module causal_mask #(
    parameter N = 4,                       
    parameter DATA_WIDTH = 32,             
    // IEEE-754 FP32 representation of -Infinity (0xFF800000)
    parameter [DATA_WIDTH-1:0] MASK_VAL = 32'hFF800000 
)(
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    start,
    input  logic [DATA_WIDTH-1:0]   raw_matrix [N-1:0][N-1:0],
    
    output logic [DATA_WIDTH-1:0]   masked_matrix [N-1:0][N-1:0],
    output logic                    valid_out
);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out <= 1'b0;
            for (int r = 0; r < N; r++) begin
                for (int c = 0; c < N; c++) begin
                    masked_matrix[r][c] <= '0;
                end
            end
        end else begin
            if (start) begin
                for (int row = 0; row < N; row++) begin
                    for (int col = 0; col < N; col++) begin
                        if (row >= col) begin
                            masked_matrix[row][col] <= raw_matrix[row][col];
                        end else begin
                            masked_matrix[row][col] <= MASK_VAL;
                        end
                    end
                end
                valid_out <= 1'b1;
            end else begin
                valid_out <= 1'b0;
            end
        end
    end

endmodule
