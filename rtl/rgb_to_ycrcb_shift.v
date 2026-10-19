// =============================================================================
// Module Name: rgb_to_ycrcb_shift
// Description: Multiplier-free RGB888 to YCrCb Color Space Converter for FPGA.
//              Target Platform: PanGo Logos-2 PG2L200H / Pure Logic FPGA.
//              Optimized with Shift-and-Add (0 DSP / APM blocks consumed).
//              Pipeline Latency: 3 clock cycles.
// =============================================================================

`timescale 1ns / 1ps

module rgb_to_ycrcb_shift #(
    parameter DW = 8
)(
    input  wire                 clk,
    input  wire                 rst_n,
    
    // Video Stream In (RGB888)
    input  wire                 i_de,
    input  wire                 i_vsync,
    input  wire                 i_hsync,
    input  wire [DW-1:0]        i_r,
    input  wire [DW-1:0]        i_g,
    input  wire [DW-1:0]        i_b,
    
    // Video Stream Out (YCrCb)
    output reg                  o_de,
    output reg                  o_vsync,
    output reg                  o_hsync,
    output reg  [DW-1:0]        o_y,
    output reg  [DW-1:0]        o_cb,
    output reg  [DW-1:0]        o_cr
);

    // -------------------------------------------------------------------------
    // Shift-and-Add Coefficients Approximation:
    // Y  =  0.2990*R + 0.5870*G + 0.1140*B ~= ( 77*R + 150*G +  29*B) >> 8
    // Cb = -0.1687*R - 0.3313*G + 0.5000*B + 128 ~= (-43*R -  85*G + 128*B + 32768) >> 8
    // Cr =  0.5000*R - 0.4187*G - 0.0813*B + 128 ~= (128*R - 107*G -  21*B + 32768) >> 8
    //
    // Decomposition:
    //  77 = 64 + 8 + 4 + 1
    // 150 = 128 + 16 + 4 + 2
    //  29 = 16 + 8 + 4 + 1
    //  43 = 32 + 8 + 2 + 1
    //  85 = 64 + 16 + 4 + 1
    // 128 = 128
    // 107 = 64 + 32 + 8 + 2 + 1
    //  21 = 16 + 4 + 1
    // -------------------------------------------------------------------------

    // Pipeline Stage 1: Partial Products (Shift & Add)
    reg [15:0] prod_77_r, prod_150_g, prod_29_b;
    reg [15:0] prod_43_r, prod_85_g,  prod_128_b;
    reg [15:0] prod_128_r, prod_107_g, prod_21_b;
    
    reg de_d1, vsync_d1, hsync_d1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prod_77_r   <= 16'd0; prod_150_g  <= 16'd0; prod_29_b   <= 16'd0;
            prod_43_r   <= 16'd0; prod_85_g   <= 16'd0; prod_128_b  <= 16'd0;
            prod_128_r  <= 16'd0; prod_107_g  <= 16'd0; prod_21_b   <= 16'd0;
            de_d1       <= 1'b0;  vsync_d1    <= 1'b0;  hsync_d1    <= 1'b0;
        end else begin
            de_d1    <= i_de;
            vsync_d1 <= i_vsync;
            hsync_d1 <= i_hsync;

            // Y partials
            prod_77_r  <= (i_r << 6) + (i_r << 3) + (i_r << 2) + i_r;
            prod_150_g <= (i_g << 7) + (i_g << 4) + (i_g << 2) + (i_g << 1);
            prod_29_b  <= (i_b << 4) + (i_b << 3) + (i_b << 2) + i_b;

            // Cb partials
            prod_43_r  <= (i_r << 5) + (i_r << 3) + (i_r << 1) + i_r;
            prod_85_g  <= (i_g << 6) + (i_g << 4) + (i_g << 2) + i_g;
            prod_128_b <= (i_b << 7);

            // Cr partials
            prod_128_r <= (i_r << 7);
            prod_107_g <= (i_g << 6) + (i_g << 5) + (i_g << 3) + (i_g << 1) + i_g;
            prod_21_b  <= (i_b << 4) + (i_b << 2) + i_b;
        end
    end

    // Pipeline Stage 2: Summation with Offset
    reg [16:0] sum_y;
    reg signed [17:0] sum_cb;
    reg signed [17:0] sum_cr;
    reg de_d2, vsync_d2, hsync_d2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_y    <= 17'd0;
            sum_cb   <= 18'sd0;
            sum_cr   <= 18'sd0;
            de_d2    <= 1'b0;
            vsync_d2 <= 1'b0;
            hsync_d2 <= 1'b0;
        end else begin
            de_d2    <= de_d1;
            vsync_d2 <= vsync_d1;
            hsync_d2 <= hsync_d1;

            sum_y  <= prod_77_r + prod_150_g + prod_29_b;
            sum_cb <= $signed({2'b00, prod_128_b}) - $signed({2'b00, prod_43_r}) - $signed({2'b00, prod_85_g}) + 18'sd32768;
            sum_cr <= $signed({2'b00, prod_128_r}) - $signed({2'b00, prod_107_g}) - $signed({2'b00, prod_21_b}) + 18'sd32768;
        end
    end

    // Pipeline Stage 3: Shift >> 8 & Saturation Clamping
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_de    <= 1'b0;
            o_vsync <= 1'b0;
            o_hsync <= 1'b0;
            o_y     <= 8'd0;
            o_cb    <= 8'd0;
            o_cr    <= 8'd0;
        end else begin
            o_de    <= de_d2;
            o_vsync <= vsync_d2;
            o_hsync <= hsync_d2;

            // Y Clamping [0, 255]
            o_y  <= (sum_y[16:8] > 8'd255) ? 8'd255 : sum_y[15:8];

            // Cb Clamping [0, 255]
            if (sum_cb < 18'sd0)
                o_cb <= 8'd0;
            else if (sum_cb[16:8] > 8'd255)
                o_cb <= 8'd255;
            else
                o_cb <= sum_cb[15:8];

            // Cr Clamping [0, 255]
            if (sum_cr < 18'sd0)
                o_cr <= 8'd0;
            else if (sum_cr[16:8] > 8'd255)
                o_cr <= 8'd255;
            else
                o_cr <= sum_cr[15:8];
        end
    end

endmodule
