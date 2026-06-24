module rmsnorm_rsqrt (
    input logic clk,
    input logic valid_in,
    input logic [31:0] sum_sq,
    output logic [31:0] result,
    output logic valid_out
);

    floating_point_3 fp32_rec_sqroot (
        .aclk(clk),                               
        .s_axis_a_tvalid(valid_in),            
        .s_axis_a_tready(),           
        .s_axis_a_tdata(sum_sq),              
        .m_axis_result_tvalid(valid_out), 
        .m_axis_result_tready(1'b1), 
        .m_axis_result_tdata(result)    
    );

endmodule