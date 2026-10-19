// =============================================================================
// Module Name: skin_detect_morphology
// Description: Skin-color segmentation in YCrCb space + 3x3 morphology filter
//              (Erosion & Dilation) using Dual Line-Buffers.
//              Eliminates salt-and-pepper noise and fills internal holes.
// =============================================================================

`timescale 1ns / 1ps

module skin_detect_morphology #(
    parameter IMG_WIDTH  = 1280,
    parameter IMG_HEIGHT = 720
)(
    input  wire        clk,
    input  wire        rst_n,
    
    // YCrCb Input Stream
    input  wire        i_de,
    input  wire        i_vsync,
    input  wire        i_hsync,
    input  wire [7:0]  i_y,
    input  wire [7:0]  i_cb,
    input  wire [7:0]  i_cr,
    
    // Morphology Configuration: 0: Erosion, 1: Dilation
    input  wire        i_morph_mode,
    
    // Clean Binary Output Stream
    output reg         o_de,
    output reg         o_vsync,
    output reg         o_hsync,
    output reg         o_binary
);

    // -------------------------------------------------------------------------
    // Step 1: Skin Color Thresholding in YCrCb
    // Typical human skin range: Cb in [77, 127], Cr in [133, 173]
    // -------------------------------------------------------------------------
    reg raw_bin;
    reg de_s1, vsync_s1, hsync_s1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            raw_bin  <= 1'b0;
            de_s1    <= 1'b0;
            vsync_s1 <= 1'b0;
            hsync_s1 <= 1'b0;
        end else begin
            de_s1    <= i_de;
            vsync_s1 <= i_vsync;
            hsync_s1 <= i_hsync;
            if (i_de) begin
                if ((i_cb >= 8'd77 && i_cb <= 8'd127) && 
                    (i_cr >= 8'd133 && i_cr <= 8'd173))
                    raw_bin <= 1'b1;
                else
                    raw_bin <= 1'b0;
            end else begin
                raw_bin <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Step 2: Line Buffers for 3x3 Window Matrix Generation
    // Line buffer 1 delays by 1 line; Line buffer 2 delays by 2 lines.
    // -------------------------------------------------------------------------
    reg [IMG_WIDTH-1:0] shift_line0;
    reg [IMG_WIDTH-1:0] shift_line1;
    
    wire tap0_in = raw_bin;
    reg  tap1_in;
    reg  tap2_in;

    always @(posedge clk) begin
        if (de_s1) begin
            shift_line0 <= {shift_line0[IMG_WIDTH-2:0], tap0_in};
            shift_line1 <= {shift_line1[IMG_WIDTH-2:0], shift_line0[IMG_WIDTH-1]};
        end
    end

    always @(posedge clk) begin
        tap1_in <= shift_line0[IMG_WIDTH-1];
        tap2_in <= shift_line1[IMG_WIDTH-1];
    end

    // 3x3 Window Registers
    reg [2:0] row0, row1, row2;
    reg de_s2, vsync_s2, hsync_s2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row0 <= 3'b0; row1 <= 3'b0; row2 <= 3'b0;
            de_s2 <= 1'b0; vsync_s2 <= 1'b0; hsync_s2 <= 1'b0;
        end else begin
            de_s2    <= de_s1;
            vsync_s2 <= vsync_s1;
            hsync_s2 <= hsync_s1;
            if (de_s1) begin
                row0 <= {row0[1:0], tap0_in};
                row1 <= {row1[1:0], tap1_in};
                row2 <= {row2[1:0], tap2_in};
            end
        end
    end

    // -------------------------------------------------------------------------
    // Step 3: Morphological Operation
    // Erosion:  o = (row0 == 3'b111) && (row1 == 3'b111) && (row2 == 3'b111)
    // Dilation: o = (|row0) || (|row1) || (|row2)
    // -------------------------------------------------------------------------
    wire is_all_ones  = (row0 == 3'b111) && (row1 == 3'b111) && (row2 == 3'b111);
    wire is_any_one   = (|row0) || (|row1) || (|row2);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_de     <= 1'b0;
            o_vsync  <= 1'b0;
            o_hsync  <= 1'b0;
            o_binary <= 1'b0;
        end else begin
            o_de    <= de_s2;
            o_vsync <= vsync_s2;
            o_hsync <= hsync_s2;
            
            if (i_morph_mode == 1'b0)
                o_binary <= is_all_ones; // Erosion
            else
                o_binary <= is_any_one;  // Dilation
        end
    end

endmodule
