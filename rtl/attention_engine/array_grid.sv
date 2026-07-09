module array_grid #(
    parameter SEQ_LEN = 2,
    parameter HEAD_DIM = 2
)(
    input logic clk,rst_n,start,
    input logic  [15:0] Q[SEQ_LEN-1:0][HEAD_DIM-1:0],
    input logic [15:0] K[SEQ_LEN-1:0][HEAD_DIM-1:0],
    output logic [31:0] score[SEQ_LEN-1:0][SEQ_LEN-1:0] ,
    output logic valid_out
);
    genvar j, k;
    int l,m,n;
    logic PE_valid_out[SEQ_LEN-1:0][SEQ_LEN-1:0],PE_valid_in[SEQ_LEN-1:0][SEQ_LEN-1:0];
    logic [31:0] score_next[SEQ_LEN-1:0][SEQ_LEN-1:0];
    logic [15:0] Q_reg [SEQ_LEN-1:0][SEQ_LEN:0],
                K_reg [SEQ_LEN:0][SEQ_LEN-1:0],
                Q_sequence[SEQ_LEN-1:0][(HEAD_DIM<<1)-2:0],
                K_sequence[(HEAD_DIM<<1)-2:0][SEQ_LEN-1:0];


    always@(posedge clk)begin
        if(!rst_n)begin
            for(l=0;l<SEQ_LEN;l=l+1)begin
                for(m=0;m<=SEQ_LEN;m=m+1)begin
                    Q_reg[l][m]<=0;
                    K_reg[m][l]<=0;
                    if(m!=SEQ_LEN && l!=SEQ_LEN)begin
                        score[l][m]<=0;
                        PE_valid_in[l][m]<=0;
                    end
                end
            end
            for(m=0;m<HEAD_DIM-1;m=m+1)begin
                K_sequence[m][l]<=0;
                K_sequence[m+HEAD_DIM][l]<=0;
                Q_sequence[l][m]<=0;
                Q_sequence[l][m+HEAD_DIM]<=0;
            end
        end
        else if(start) begin
            for(l=0;l<SEQ_LEN;l=l+1)begin
                for(m=0;m<SEQ_LEN;m=m+1)begin
                    PE_valid_in[l][m]<=1'b1;
                end
          end
            Q_reg[0][0]<=Q[0][HEAD_DIM-1];
            K_reg[0][0]<=K[0][SEQ_LEN-1];
            for(l=0;l<SEQ_LEN;l=l+1)begin
                for(m=0;m<HEAD_DIM;m=m+1)begin
                    Q_sequence[l][HEAD_DIM+m-l]<=Q[l][m];
                end
                for(m=0;m<SEQ_LEN;m=m+1)begin
                    K_sequence[m+SEQ_LEN-l][l]<=K[l][m];
                    score[l][m]<=0;
                end
            end
        end
        else begin
            if(PE_valid_out[0][0])begin
                for(l=0;l<SEQ_LEN;l=l+1)begin
                    for(m=1;m<(HEAD_DIM<<1)-1;m=m+1)begin
                        Q_sequence[l][m]<=Q_sequence[l][m-1];
                    end
                end
                for(l=1;l<(SEQ_LEN<<1)-1;l=l+1)begin
                    for(m=0;m<SEQ_LEN;m=m+1)begin
                       K_sequence[l][m]<=K_sequence[l-1][m];
                    end
                end
            end
            for(l=0;l<SEQ_LEN;l=l+1)begin
                for(m=0;m<SEQ_LEN;m=m+1)begin
                    if(PE_valid_out[l][m])begin
                        PE_valid_in[l][m]<=1'b1;
                        score[l][m]<=score_next[l][m];
                        Q_reg[l][0]<=Q_sequence[l][(HEAD_DIM<<1)-2];
                        K_reg[0][l]<=K_sequence[(HEAD_DIM<<1)-2][l];
                    end
                    else begin
                        PE_valid_in[l][m]<=0;
                    end
                end
            end
        end
    end

    generate
        for (j = 0; j < SEQ_LEN; j = j + 1) begin
            for (k = 0; k < SEQ_LEN; k = k + 1) begin
                    PE pejk (
                        .clk(clk),
                        .rst_n(rst_n),
                        .valid_in(PE_valid_in[j][k]),
                        .Q_reg(Q_reg[j][k]),
                        .K_reg(K_reg[j][k]),
                        .acc_present(score[j][k]),
                        .acc(score_next[j][k]),
                        .Q_reg_out(Q_reg[j][k+1]),
                        .K_reg_out(K_reg[j+1][k]),
                        .valid_out(PE_valid_out[j][k])
                    );
            end
        end
    endgenerate
endmodule