module PE (
    input logic clk,rst_n,
    input logic [15:0] Q_reg,
    input logic [15:0] K_reg,
    input logic [31:0] acc_present,
    input logic valid_in,
    output logic [31:0] acc,
    output logic [15:0] Q_reg_out,
    output logic [15:0] K_reg_out,
    output logic valid_out
);
    logic [31:0] acc_next;
    logic acc_valid;
    //score calculation
    always_ff@(posedge clk) begin
        if(!rst_n)begin
            Q_reg_out <= 16'b0;
            K_reg_out <= 16'b0;
            acc <= 32'b0;
            valid_out<=0;
        end
        else if(acc_valid)begin
            acc <= acc_next;           //Like dot product, the accumulator is updated with the new value.
            Q_reg_out <= Q_reg;
            K_reg_out <= K_reg;
            valid_out<=1'b1;
        end
        else begin
            valid_out<=0;
        end
    end

    bf16_mac u_mac (
        .clk(clk),
        .valid_in(valid_in),
        .a(Q_reg),
        .b(K_reg),
        .c(acc_present),
        .result(acc_next),
        .valid_out(acc_valid)
    );
endmodule