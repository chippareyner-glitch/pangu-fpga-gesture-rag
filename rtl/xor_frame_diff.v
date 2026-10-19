// =============================================================================
// Module Name: xor_frame_diff
// Description: Multi-frame XOR difference generator for 32x32 binary ROI.
//              Provides Channel 2 (Dynamic Motion Hotspots) for micro-gestures.
//              Memory cost: 4096 bits (Single BRAM/DRM block).
// =============================================================================

`timescale 1ns / 1ps

module xor_frame_diff #(
    parameter ROI_SIZE = 32,
    parameter FRAME_DELAY = 4
)(
    input  wire        clk,
    input  wire        rst_n,
    
    // 32x32 stream sync
    input  wire        i_roi_valid,
    input  wire [9:0]  i_pixel_addr, // 0 to 1023
    input  wire        i_binary_pix, // Current frame pixel
    input  wire        i_frame_end,  // Pulsed at end of 32x32 ROI scan
    
    // Dual-channel output stream
    output reg         o_dual_valid,
    output reg         o_ch1_static, // Channel 1: Static contour
    output reg         o_ch2_motion  // Channel 2: Dynamic XOR motion hotspot
);

    // Ring buffer pointer for 4 frame delays: frame_slot 0, 1, 2, 3
    reg [1:0] wr_frame_idx;
    wire [1:0] rd_frame_idx = wr_frame_idx - 2'd1; // delayed by 4 frames (modulo 4 ring)

    // Combined address: {frame_idx[1:0], pixel_addr[9:0]} -> 12-bit address (4096 bits)
    wire [11:0] wr_addr = {wr_frame_idx, i_pixel_addr};
    wire [11:0] rd_addr = {rd_frame_idx, i_pixel_addr};

    // 4096 x 1-bit Ring Memory (Inferred BRAM)
    reg mem [0:4095];
    reg delayed_pix;

    always @(posedge clk) begin
        if (i_roi_valid) begin
            delayed_pix <= mem[rd_addr];
            mem[wr_addr] <= i_binary_pix;
        end
    end

    // Frame index advancement
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            wr_frame_idx <= 2'd0;
        else if (i_frame_end)
            wr_frame_idx <= wr_frame_idx + 1'b1;
    end

    // Pipelined Output (1 cycle latency for RAM read)
    reg static_d1;
    reg valid_d1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            static_d1    <= 1'b0;
            valid_d1     <= 1'b0;
            o_dual_valid <= 1'b0;
            o_ch1_static <= 1'b0;
            o_ch2_motion <= 1'b0;
        end else begin
            valid_d1     <= i_roi_valid;
            static_d1    <= i_binary_pix;

            o_dual_valid <= valid_d1;
            o_ch1_static <= static_d1;
            // Channel 2 is XOR of current static pixel with 4-frame delayed pixel
            o_ch2_motion <= static_d1 ^ delayed_pix;
        end
    end

endmodule
