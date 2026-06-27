module systolic_array #(
    parameter PE_SIZE = 16
) (
    input  logic        clk,
    input  logic        rst_n,
    
    // Weight loading interface
    input  logic [15:0] weight_in [0:PE_SIZE-1],
    input  logic        weight_en,
    
    // Activation inputs (left boundary)
    input  logic [15:0] x_in [0:PE_SIZE-1],
    
    // Valid inputs (top boundary, controls MAC)
    input  logic        valid_in [0:PE_SIZE-1],
    
    // Partial sum inputs (top boundary)
    input  logic [31:0] s_in [0:PE_SIZE-1],
    
    // Outputs (right boundary activations, bottom boundary partial sums & valids)
    output logic [15:0] x_out [0:PE_SIZE-1],
    output logic [31:0] s_out [0:PE_SIZE-1],
    output logic        valid_out [0:PE_SIZE-1]
);

    // Grid connections:
    // x_conn[i][j] is the activation input to PE(i,j), and x_conn[i][PE_SIZE] is the output of row i.
    logic [15:0] x_conn [0:PE_SIZE-1][0:PE_SIZE];
    
    // s_conn[i][j] is the partial sum input to PE(i,j) from above.
    logic [31:0] s_conn [0:PE_SIZE][0:PE_SIZE-1];
    
    // v_conn[i][j] is the valid input to PE(i,j) from above.
    logic        v_conn [0:PE_SIZE][0:PE_SIZE-1];
    
    // w_conn[i][j] is the weight input to PE(i,j) from above.
    logic [15:0] w_conn [0:PE_SIZE][0:PE_SIZE-1];

    // Connect boundaries
    generate
        for (genvar i = 0; i < PE_SIZE; i++) begin : gen_row_boundary
            assign x_conn[i][0] = x_in[i];
            assign x_out[i]     = x_conn[i][PE_SIZE];
        end
        for (genvar j = 0; j < PE_SIZE; j++) begin : gen_col_boundary
            assign s_conn[0][j] = s_in[j];
            assign v_conn[0][j] = valid_in[j];
            assign w_conn[0][j] = weight_in[j];
            
            assign s_out[j]     = s_conn[PE_SIZE][j];
            assign valid_out[j] = v_conn[PE_SIZE][j];
        end
    endgenerate

    // Instantiate PE array
    generate
        for (genvar i = 0; i < PE_SIZE; i++) begin : gen_pe_rows
            for (genvar j = 0; j < PE_SIZE; j++) begin : gen_pe_cols
                systolic_pe u_pe (
                    .clk(clk),
                    .rst_n(rst_n),
                    .valid_in(v_conn[i][j]),
                    .x_in(x_conn[i][j]),
                    .weight_in(w_conn[i][j]),
                    .weight_en(weight_en),
                    .s_in(s_conn[i][j]),
                    .x_out(x_conn[i][j+1]),
                    .weight_out(w_conn[i+1][j]),
                    .s_out(s_conn[i+1][j]),
                    .valid_out(v_conn[i+1][j])
                );
            end
        end
    endgenerate

endmodule
