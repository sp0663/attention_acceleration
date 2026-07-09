`timescale 1ns / 1ps

module array_grid_tb;

    parameter SEQ_LEN  = 2;
    parameter HEAD_DIM = 2;

    logic clk;
    logic rst_n;
    logic start;

    logic [15:0] Q [SEQ_LEN-1:0][HEAD_DIM-1:0];
    logic [15:0] K [SEQ_LEN-1:0][HEAD_DIM-1:0];

    logic [31:0] score [SEQ_LEN-1:0][SEQ_LEN-1:0];
    logic valid_out;

    integer i, j;

    // Instantiate Design Under Test
    array_grid #(
        .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .Q(Q),
        .K(K),
        .score(score),
        .valid_out(valid_out)
    );

    //---------------- Clock Generator ----------------//
    initial clk = 0;
    always #5 clk = ~clk; // 10ns Clock Period

    //---------------- Stimulus Block ----------------//
    initial begin
        rst_n = 0;
        start = 0;

        // ==========================================
        // Q Matrix (BF16)
        // [1.0  2.0]
        // [3.0  4.0]
        // ==========================================
        Q[0][0] = 16'h3F80;   // 1.0
        Q[0][1] = 16'h4000;   // 2.0
        Q[1][0] = 16'h4040;   // 3.0
        Q[1][1] = 16'h4080;   // 4.0

        // ==========================================
        // K Matrix (BF16)
        // [5.0  6.0]
        // [7.0  8.0]
        // ==========================================
        K[0][0] = 16'h40A0;   // 5.0
        K[0][1] = 16'h40C0;   // 6.0
        K[1][0] = 16'h40E0;   // 7.0
        K[1][1] = 16'h4100;   // 8.0

        // Release Reset
        #20;
        rst_n = 1;

        // Issue Start Pulse
        @(negedge clk);
        start = 1;
        @(negedge clk);
        start = 0;

        $display("[TB] Array started. Waiting for valid_out...");

        // Dynamic Watchdog Framework
        fork
            begin
                // Wait for hardware to assert valid_out
                @(posedge valid_out);
                // Allow one extra cycle for final outputs to cleanly stabilize
                @(posedge clk); 

                $display("---------------------------------------");
                $display("SUCCESS! Calculation Finished at Time = %0t ns", $time);
                $display("---------------------------------------");
                for(i=0; i<SEQ_LEN; i=i+1) begin
                    for(j=0; j<SEQ_LEN; j=j+1)
                        $write("%h ", score[i][j]);
                    $display();
                end
            end
            begin
                // Safety Watchdog: Timeout after 500 clock cycles if something breaks
                repeat(500) @(posedge clk);
                $display("---------------------------------------");
                $display("ERROR: Simulation timed out! valid_out never went high.");
                $display("Check if your Vivado Floating Point IP core matches the ports.");
                $display("---------------------------------------");
            end
        join_any

        $display("");
        $display("Expected FP32 Result Matrix:");
        $display("41880000 41B80000");
        $display("421C0000 42540000");

        $finish;
    end

endmodule