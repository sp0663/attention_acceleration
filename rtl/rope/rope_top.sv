module rope_top #(
    parameter int HEAD_DIM  = 128,
    parameter int NUM_PAIRS = HEAD_DIM / 2,
    localparam int ELEM_W = $clog2(HEAD_DIM)

) (
    input  logic clk,
    input  logic rst_n,

    // Token position

    input  logic [6:0] position,



    // ============================================================

    // AXI4-Stream Input

    // ============================================================



    input  logic [15:0] s_axis_tdata,

    input  logic        s_axis_tvalid,

    output logic        s_axis_tready,

    input  logic        s_axis_tlast,





    // ============================================================

    // AXI4-Stream Output

    // ============================================================



    output logic [15:0] m_axis_tdata,

    output logic        m_axis_tvalid,

    input  logic        m_axis_tready,

    output logic        m_axis_tlast

);





    // ============================================================

    // State machine

    // ============================================================



    typedef enum logic [1:0] {



        ST_RECEIVE  = 2'd0,

        ST_PROCESS  = 2'd1,

        ST_TRANSMIT = 2'd2



    } state_t;





    state_t state;







    // ============================================================

    // Input/output buffers

    // ============================================================



    logic [15:0] head_buffer_in

        [0:HEAD_DIM-1];





    logic [15:0] head_buffer_out

        [0:HEAD_DIM-1];







    // ============================================================

    // Counters

    // ============================================================



    logic [ELEM_W-1:0] rx_cnt;



    logic [ELEM_W-1:0] tx_cnt;







    // ============================================================

    // Store position associated with current head

    // ============================================================



    logic [6:0] position_reg;







    // ============================================================

    // RoPE core control

    // ============================================================



    logic core_valid_in;



    logic core_valid_out;



    logic core_ready_in;



    logic core_started;







    // ============================================================

    // RoPE core

    // ============================================================



    rope_rotate #(



        .HEAD_DIM  (HEAD_DIM),



        .NUM_PAIRS (NUM_PAIRS)



    ) u_rope_rotate (



        .clk (

            clk

        ),



        .rst_n (

            rst_n

        ),



        .valid_in (

            core_valid_in

        ),



        .position (

            position_reg

        ),



        .x_in (

            head_buffer_in

        ),



        .x_out (

            head_buffer_out

        ),



        .valid_out (

            core_valid_out

        ),



        .ready_in (

            core_ready_in

        )



    );







    // ============================================================

    // AXI input interface

    // ============================================================



    assign s_axis_tready =

        (state == ST_RECEIVE);







    // ============================================================

    // AXI output interface

    // ============================================================



    assign m_axis_tdata =

        head_buffer_out[tx_cnt];





    assign m_axis_tvalid =

        (state == ST_TRANSMIT);





    assign m_axis_tlast =

        (state == ST_TRANSMIT) &&

        (tx_cnt == HEAD_DIM - 1);







    // ============================================================

    // Main FSM

    // ============================================================



    always_ff @(posedge clk or negedge rst_n) begin



        if (!rst_n) begin



            state <= ST_RECEIVE;



            rx_cnt <= '0;



            tx_cnt <= '0;



            position_reg <= '0;



            core_valid_in <= 1'b0;



            core_started <= 1'b0;



        end



        else begin





            // ====================================================

            // Default: core valid is a one-cycle pulse

            // ====================================================



            core_valid_in <= 1'b0;







            case (state)





                // =================================================

                // RECEIVE

                //

                // Receive HEAD_DIM BF16 values.

                // =================================================



                ST_RECEIVE: begin



                    tx_cnt <= '0;



                    core_started <= 1'b0;





                    if (

                        s_axis_tvalid &&

                        s_axis_tready

                    ) begin





                        // Store incoming BF16 value



                        head_buffer_in[rx_cnt]

                            <= s_axis_tdata;







                        // Capture position at start of head



                        if (rx_cnt == 0) begin



                            position_reg <= position;



                        end







                        // Last expected element



                        if (rx_cnt == HEAD_DIM - 1) begin



                            rx_cnt <= '0;



                            state <= ST_PROCESS;



                        end



                        else begin



                            rx_cnt <= rx_cnt + 1'b1;



                        end



                    end



                end







                // =================================================

                // PROCESS

                //

                // Send exactly one start pulse to rope_rotate.

                // =================================================



                ST_PROCESS: begin





                    // ---------------------------------------------

                    // Start core exactly once

                    // ---------------------------------------------



                    if (

                        core_ready_in &&

                        !core_started

                    ) begin



                        core_valid_in <= 1'b1;



                        core_started <= 1'b1;



                    end







                    // ---------------------------------------------

                    // Complete rotated head ready

                    // ---------------------------------------------



                    if (core_valid_out) begin



                        tx_cnt <= '0;



                        state <= ST_TRANSMIT;



                    end



                end







                // =================================================

                // TRANSMIT

                //

                // Send one BF16 value per AXI handshake.

                // =================================================



                ST_TRANSMIT: begin





                    if (

                        m_axis_tvalid &&

                        m_axis_tready

                    ) begin





                        if (tx_cnt == HEAD_DIM - 1) begin



                            tx_cnt <= '0;



                            state <= ST_RECEIVE;



                        end



                        else begin



                            tx_cnt <= tx_cnt + 1'b1;



                        end



                    end



                end







                // =================================================

                // Safety recovery

                // =================================================



                default: begin



                    state <= ST_RECEIVE;



                    rx_cnt <= '0;



                    tx_cnt <= '0;



                    core_started <= 1'b0;



                end





            endcase



        end



    end





endmodule