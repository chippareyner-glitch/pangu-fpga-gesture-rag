// =============================================================================
// Module Name: bnn_xnor_popcount
// Description: Zero-DSP Binarized Neural Network (BNN) Vector Processing Unit.
//              Replaces multipliers with XNOR and accumulators with Popcount.
//              Vector Length: 32 elements per cycle. Target: Pure Logic FPGA.
// =============================================================================

`timescale 1ns / 1ps

module bnn_xnor_popcount #(
    parameter VEC_LEN = 32
)(
    input  wire                 clk,
    input  wire                 rst_n,
    
    input  wire                 i_valid,
    input  wire [VEC_LEN-1:0]   i_act_vec,    // 1-bit activations: 1=+1, 0=-1
    input  wire [VEC_LEN-1:0]   i_weight_vec, // 1-bit weights: 1=+1, 0=-1
    input  wire [5:0]           i_threshold,  // Binarization activation threshold
    
    output reg                  o_valid,
    output reg  [5:0]           o_popcount,   // 0 to 32
    output reg                  o_bnn_bit     // 1 if popcount >= threshold, else 0
);

    // Step 1: Bitwise XNOR (Multiplication in {-1, +1} domain)
    wire [VEC_LEN-1:0] xnor_res = ~(i_act_vec ^ i_weight_vec);

    // Step 2: Pipelined Tree-based Popcount
    // Level 1: 16 x 2-bit adders
    reg [1:0] lvl1 [0:15];
    reg       v1;
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v1 <= 1'b0;
            for (i=0; i<16; i=i+1) lvl1[i] <= 2'd0;
        end else begin
            v1 <= i_valid;
            for (i=0; i<16; i=i+1)
                lvl1[i] <= xnor_res[2*i] + xnor_res[2*i + 1];
        end
    end

    // Level 2: 8 x 3-bit adders
    reg [2:0] lvl2 [0:7];
    reg       v2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v2 <= 1'b0;
            for (i=0; i<8; i=i+1) lvl2[i] <= 3'd0;
        end else begin
            v2 <= v1;
            for (i=0; i<8; i=i+1)
                lvl2[i] <= lvl1[2*i] + lvl1[2*i + 1];
        end
    end

    // Level 3: 4 x 4-bit adders
    reg [3:0] lvl3 [0:3];
    reg       v3;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v3 <= 1'b0;
            for (i=0; i<4; i=i+1) lvl3[i] <= 4'd0;
        end else begin
            v3 <= v2;
            for (i=0; i<4; i=i+1)
                lvl3[i] <= lvl2[2*i] + lvl2[2*i + 1];
        end
    end

    // Level 4: 2 x 5-bit adders
    reg [4:0] lvl4 [0:1];
    reg       v4;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v4 <= 1'b0;
            lvl4[0] <= 5'd0; lvl4[1] <= 5'd0;
        end else begin
            v4 <= v3;
            lvl4[0] <= lvl3[0] + lvl3[1];
            lvl4[1] <= lvl3[2] + lvl3[3];
        end
    end

    // Final Stage: 6-bit Sum & Threshold Binarization
    wire [5:0] total_sum = lvl4[0] + lvl4[1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_valid     <= 1'b0;
            o_popcount  <= 6'd0;
            o_bnn_bit   <= 1'b0;
        end else begin
            o_valid     <= v4;
            o_popcount  <= total_sum;
            o_bnn_bit   <= (total_sum >= i_threshold);
        end
    end

endmodule
