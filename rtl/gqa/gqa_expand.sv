module gqa_expand (
    input  logic [4:0]  q_head_idx,    // 0 to 31
    output logic [2:0]  kv_head_idx    // 0 to 7
);

    assign kv_head_idx = q_head_idx[4:2];  // divide by 4

endmodule