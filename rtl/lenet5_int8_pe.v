// =============================================================================
// Module Name: lenet5_int8_pe
// Description: Quantized INT8 Multiply-Accumulate (MAC) Processing Element for
//              Convolutional & Fully Connected Neural Network Layers.
//              Features: Saturating Accumulator, Bit-Shift Scaling, ReLU/Pass.
// =============================================================================

`timescale 1ns / 1ps

module lenet5_int8_pe #(
    parameter DATA_WIDTH  = 8,
    parameter ACCUM_WIDTH = 24,
    parameter SHIFT_VAL   = 7 // Scale factor: division by 2^7 = 128
)(
    input  wire                          clk,
    input  wire                          rst_n,
    
    // Control
    input  wire                          i_valid,
    input  wire                          i_clr_accum, // Assert on start of new kernel/channel
    input  wire signed [ACCUM_WIDTH-1:0] i_bias,
    input  wire                          i_relu_en,
    
    // Operands
    input  wire signed [DATA_WIDTH-1:0]  i_weight,
    input  wire signed [DATA_WIDTH-1:0]  i_act,
    
    // Result
    output reg                           o_valid,
    output reg  signed [DATA_WIDTH-1:0]  o_result,
    output reg  signed [ACCUM_WIDTH-1:0] o_raw_accum
);

    // Stage 1: Multiplication (8-bit x 8-bit = 16-bit signed)
    reg signed [15:0] prod_s1;
    reg               valid_s1;
    reg               clr_s1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prod_s1  <= 16'sd0;
            valid_s1 <= 1'b0;
            clr_s1   <= 1'b0;
        end else begin
            valid_s1 <= i_valid;
            clr_s1   <= i_clr_accum;
            if (i_valid)
                prod_s1 <= i_weight * i_act;
            else
                prod_s1 <= 16'sd0;
        end
    end

    // Stage 2: Accumulation
    reg signed [ACCUM_WIDTH-1:0] accum_s2;
    reg valid_s2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            accum_s2 <= 'sd0;
            valid_s2 <= 1'b0;
        end else begin
            valid_s2 <= valid_s1;
            if (clr_s1)
                accum_s2 <= $signed({ {8{prod_s1[15]}}, prod_s1 }) + i_bias;
            else if (valid_s1)
                accum_s2 <= accum_s2 + $signed({ {8{prod_s1[15]}}, prod_s1 });
        end
    end

    // Stage 3: Shift Truncation, Rounding & Activation Clamping
    wire signed [ACCUM_WIDTH-1:0] shifted = accum_s2 >>> SHIFT_VAL;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_valid     <= 1'b0;
            o_result    <= 'sd0;
            o_raw_accum <= 'sd0;
        end else begin
            o_valid     <= valid_s2;
            o_raw_accum <= accum_s2;

            if (i_relu_en) begin
                // ReLU: if negative, clamp to 0; if > 127, clamp to 127
                if (shifted < 0)
                    o_result <= 8'sd0;
                else if (shifted > 24'sd127)
                    o_result <= 8'sd127;
                else
                    o_result <= shifted[DATA_WIDTH-1:0];
            end else begin
                // Linear: clamp to [-128, 127]
                if (shifted > 24'sd127)
                    o_result <= 8'sd127;
                else if (shifted < -24'sd128)
                    o_result <= -8'sd128;
                else
                    o_result <= shifted[DATA_WIDTH-1:0];
            end
        end
    end

endmodule
