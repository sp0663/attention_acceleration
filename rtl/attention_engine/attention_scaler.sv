
module attention_scaler #(
    parameter SEQ_LEN = 4
)(
    input  logic        clk,
    input  logic        aresetn,
    input  logic        start_scale,
    input  logic [31:0] raw_score_matrix [SEQ_LEN-1:0][SEQ_LEN-1:0],
    
    output logic [31:0] scaled_score_matrix [SEQ_LEN-1:0][SEQ_LEN-1:0],
    output logic        scale_valid_out
);

    // Constant for 1/sqrt(4) = 0.5 in IEEE-754 FP32 Hex
    localparam [31:0] SCALE_FACTOR = 32'h3F000000; 

    logic streaming;
    int   row_cnt, col_cnt;
    int   out_row_cnt, out_col_cnt;

    logic        s_axis_a_tvalid;
    logic [31:0] s_axis_a_tdata;
    logic        s_axis_b_tvalid;
    logic [31:0] s_axis_b_tdata;
    logic        m_axis_result_tvalid;
    logic [31:0] m_axis_result_tdata;

    logic        in_valid_r;
    logic [31:0] in_data_r;

    always_ff @(posedge clk or negedge aresetn) begin
        if (!aresetn) begin
            in_valid_r <= 1'b0;
            in_data_r  <= 32'h0;
        end else begin
            in_valid_r <= streaming;
            in_data_r  <= raw_score_matrix[row_cnt][col_cnt];
        end
    end

    assign s_axis_a_tvalid = in_valid_r;
    assign s_axis_a_tdata  = in_data_r;
    
    assign s_axis_b_tvalid = in_valid_r;
    assign s_axis_b_tdata  = SCALE_FACTOR;

    floating_point_1 scale_mult_ip (
        .aclk(clk),
        .s_axis_a_tvalid(s_axis_a_tvalid),
        .s_axis_a_tdata(s_axis_a_tdata),
        .s_axis_b_tvalid(s_axis_b_tvalid),
        .s_axis_b_tdata(s_axis_b_tdata),
        .m_axis_result_tvalid(m_axis_result_tvalid),
        .m_axis_result_tdata(m_axis_result_tdata)
    );

    always_ff @(posedge clk or negedge aresetn) begin
        if (!aresetn) begin
            streaming <= 1'b0;
            row_cnt   <= 0;
            col_cnt   <= 0;
        end else begin
            if (start_scale) begin
                streaming <= 1'b1;
                row_cnt   <= 0;
                col_cnt   <= 0;
            end else if (streaming) begin
                if (col_cnt == SEQ_LEN - 1) begin
                    col_cnt <= 0;
                    if (row_cnt == SEQ_LEN - 1) begin
                        streaming <= 1'b0;
                    end else begin
                        row_cnt <= row_cnt + 1;
                    end
                end else begin
                    col_cnt <= col_cnt + 1;
                end
            end
        end
    end

    always_ff @(posedge clk or negedge aresetn) begin
        if (!aresetn) begin
            out_row_cnt     <= 0;
            out_col_cnt     <= 0;
            scale_valid_out <= 1'b0;
        end else begin
            scale_valid_out <= 1'b0;
            if (m_axis_result_tvalid) begin
                scaled_score_matrix[out_row_cnt][out_col_cnt] <= m_axis_result_tdata;
                
                if (out_col_cnt == SEQ_LEN - 1) begin
                    out_col_cnt <= 0;
                    if (out_row_cnt == SEQ_LEN - 1) begin
                        out_row_cnt     <= 0;
                        scale_valid_out <= 1'b1; 
                    end else begin
                        out_row_cnt <= out_row_cnt + 1;
                    end
                end else begin
                    out_col_cnt <= out_col_cnt + 1;
                end
            end
        end
    end

endmodule
