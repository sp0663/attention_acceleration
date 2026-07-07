`timescale 1ns / 1ps
module tb_rope_top;

    // Parameters
    localparam int HEAD_DIM  = 128;
    localparam int NUM_PAIRS =   HEAD_DIM / 2;
    localparam logic [15:0] BF16_ONE = 16'h3F80;

    // DUT signals

    logic clk;
    logic rst_n;
    logic [6:0] position;
    logic [15:0] s_axis_tdata;
    logic s_axis_tvalid;
    logic s_axis_tready;
    logic s_axis_tlast;
    logic [15:0] m_axis_tdata;
    logic m_axis_tvalid;
    logic m_axis_tready;
    logic m_axis_tlast;

    integer output_count;

    integer error_count;
   
    // DUT

    rope_top #(

        .HEAD_DIM  (HEAD_DIM),

        .NUM_PAIRS (NUM_PAIRS)

    ) uut (

        .clk (
            clk
        ),
        .rst_n (
            rst_n
        ),
        .position (
            position
        ),
        .s_axis_tdata (
            s_axis_tdata
        ),
        .s_axis_tvalid (
            s_axis_tvalid
        ),
        .s_axis_tready (
            s_axis_tready
        ),
        .s_axis_tlast (
            s_axis_tlast
        ),
        .m_axis_tdata (
            m_axis_tdata
        ),
        .m_axis_tvalid (
            m_axis_tvalid
        ),
        .m_axis_tready (
            m_axis_tready
        ),
        .m_axis_tlast (
            m_axis_tlast
        )
    );

    // Clock generation
    // 100 MHz
   
    initial begin

        clk = 1'b0;

        forever #5 clk = ~clk;

    end

    // FP32 bits -> BF16
    // Round-to-nearest-even

    function automatic [15:0] fp32_bits_to_bf16 (

        input logic [31:0] bits

    );

        logic guard_bit;

        logic sticky_bit;

        logic kept_bit;

        logic [15:0] upper;


        begin

            upper = bits[31:16];


            guard_bit = bits[15];


            sticky_bit = |bits[14:0];


            kept_bit =  bits[16];



            // Inf / NaN

            if (&bits[30:23]) begin

                fp32_bits_to_bf16 = { bits[31], 8'hFF, bits[22:16] };
            end


            // Round upward

            else if ( guard_bit && (sticky_bit || kept_bit)) begin

                fp32_bits_to_bf16 = upper + 16'd1;

            end

            // Truncate

            else begin

                fp32_bits_to_bf16 = upper;

            end

        end

    endfunction
   
    // Real -> BF16

    function automatic [15:0] real_to_bf16 (

        input real value

    );

        shortreal value_short;

        logic [31:0] fp32_bits;


        begin

            value_short = value;


            fp32_bits = $shortrealtobits( value_short );


            real_to_bf16 = fp32_bits_to_bf16( fp32_bits );

        end

    endfunction


    function automatic [15:0] expected_output (

        input integer output_index,

        input integer pos

    );

        integer pair_index;

        real exponent;

        real frequency;

        real theta;

        real expected_real;


        begin

            pair_index = output_index / 2;


            exponent = (2.0 * pair_index) / HEAD_DIM;


            frequency =1.0 / (500000.0 ** exponent);


            theta = pos * frequency;



            if ((output_index % 2) == 0) begin

                expected_real =  $cos(theta)  - $sin(theta);

            end
            else begin

                expected_real = $sin(theta) + $cos(theta);

            end


            expected_output =

                real_to_bf16(
                    expected_real
                );

        end

    endfunction

    function automatic logic bf16_close (

        input logic [15:0] dut,

        input logic [15:0] expected

    );

        integer difference;


        begin

            difference = $signed({1'b0, dut}) - $signed({1'b0, expected});

            if (difference < 0)
                difference = -difference;
            bf16_close =(difference <= 1);

        end

    endfunction

    initial begin

        rst_n = 1'b0;
        position = 7'd56;
        s_axis_tdata =  16'h0000;
        s_axis_tvalid = 1'b0;
        s_axis_tlast = 1'b0;
        m_axis_tready = 1'b1;
        output_count = 0;
        error_count = 0;
        repeat (5)

            @(posedge clk);


        @(negedge clk);

        rst_n = 1'b1;

        repeat (3)

            @(posedge clk);



        $display("");

        $display(
            "========================================"
        );

        $display(
            "RoPE TEST START"
        );

        $display(
            "Position = %0d",
            position
        );

        $display(
            "Input = BF16 1.0"
        );

        $display(
            "========================================"
        );

        $display("");

        // Send 128 BF16 values
       
        for (
            int i = 0;
            i < HEAD_DIM;
            i++
        ) begin


            // Wait until DUT ready

            while (!s_axis_tready)

                @(posedge clk);

            // Drive before sampling edge

            @(negedge clk);

            s_axis_tvalid = 1'b1;


            s_axis_tdata = BF16_ONE;



            if (i == HEAD_DIM - 1)

                s_axis_tlast = 1'b1;

            else

                s_axis_tlast = 1'b0;



            // Transfer occurs here

            @(posedge clk);

        end


        @(negedge clk);

        s_axis_tvalid = 1'b0;
        s_axis_tlast = 1'b0;
        s_axis_tdata = 16'h0000;

        $display("");

        $display(
            "Input transfer complete."
        );

        $display(
            "Waiting for output..."
        );

        $display("");



        // --------------------------------------------------------
        // Wait for 128 outputs
        // --------------------------------------------------------

        wait(
            output_count == HEAD_DIM 
            );



        repeat (5)

            @(posedge clk);

        // --------------------------------------------------------
        // Final report
        // --------------------------------------------------------

        $display("");

        $display(
            "========================================"
        );

        $display(
            "TEST COMPLETE"
        );

        $display(
            "Outputs = %0d",
            output_count
        );

        $display(
            "Errors  = %0d",
            error_count
        );

        $display(
            "========================================"
        );


        if (error_count == 0)

            $display(
                "TEST PASSED"
            );

        else

            $display(
                "TEST FAILED"
            );

        $finish;
    end

    // ============================================================
    // Output checker
    // ============================================================

    always @(posedge clk) begin

        logic [15:0] expected;

        if (

            rst_n &&

            m_axis_tvalid &&

            m_axis_tready

        ) begin

            expected =

                expected_output(

                    output_count,

                    position

                );

            $display(

                "OUTPUT[%0d] DUT=%h EXPECTED=%h",

                output_count,

                m_axis_tdata,

                expected

            );


            // ----------------------------------------------------
            // Data comparison
            // ----------------------------------------------------

            if (

                !bf16_close(

                    m_axis_tdata,

                    expected

                )

            ) begin


                $display(

                    "ERROR at output %0d",

                    output_count

                );


                error_count = error_count + 1;

            end

            // ----------------------------------------------------
            // TLAST check
            // ----------------------------------------------------

            if (

                output_count == HEAD_DIM - 1

            ) begin


                if (!m_axis_tlast) begin

                    $display(

                        "ERROR: TLAST missing on final output"

                    );

                    error_count = error_count + 1;

                end
            end
            else begin


                if (m_axis_tlast) begin


                    $display(

                        "ERROR: early TLAST at output %0d",

                        output_count

                    );

                    error_count = error_count + 1;

                end

            end
            output_count = output_count + 1;

        end

    end


    // ============================================================
    // Useful internal debug
    //
    // These signals exist in the rope_rotate code above.
    // ============================================================

    always @(posedge clk) begin

        if ( rst_n && uut.u_rope_rotate.math_valid_2) begin

            $display(

                "FP INPUT: pair=%0d x0=%h x1=%h sin=%h cos=%h",

                uut.u_rope_rotate.pair_cnt,

                uut.u_rope_rotate.x0_reg_2,

                uut.u_rope_rotate.x1_reg_2,

                uut.u_rope_rotate.sin_fp32,

                uut.u_rope_rotate.cos_fp32

            );

        end

    end



    // ============================================================
    // Timeout
    // ============================================================

    initial begin

        #100000;


        $display("");

        $display(
            "========================================"
        );

        $display(
            "TEST TIMEOUT"
        );

        $display(
            "Outputs received = %0d",
            output_count
        );

        $display(
            "========================================"
        );


        $finish;
    end
endmodule