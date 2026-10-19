// =============================================================================
// Module Name: pangu_gesture_top
// Description: Complete Top-Level Architecture for Real-Time Gesture Tracking &
//              Micro-Gesture Recognition on PanGo Logos-2 PG2L200H FPGA.
//              Integrates:
//              1. Multiplierless YCrCb + Skin Filter
//              2. 3x3 Morphology Line Buffer
//              3. Bounding Box & Fingertip Tracker
//              4. Dual-Channel XOR Frame Difference
//              5. Click-Hold Anti-Jitter FSM
//              6. Real-time HDMI OSD (Green Bounding Box + Red Reticle Crosshair)
// =============================================================================

`timescale 1ns / 1ps

module pangu_gesture_top #(
    parameter IMG_WIDTH  = 1280,
    parameter IMG_HEIGHT = 720
)(
    input  wire        clk_pixel,       // 74.25 MHz (720p@60Hz)
    input  wire        clk_sys,         // 50 MHz
    input  wire        rst_n,
    
    // Camera Video In (RGB888)
    input  wire        cam_de,
    input  wire        cam_vsync,
    input  wire        cam_hsync,
    input  wire [7:0]  cam_r,
    input  wire [7:0]  cam_g,
    input  wire [7:0]  cam_b,
    
    // Display Video Out with On-Screen Display (OSD)
    output wire        osd_de,
    output wire        osd_vsync,
    output wire        osd_hsync,
    output reg  [7:0]  osd_r,
    output reg  [7:0]  osd_g,
    output reg  [7:0]  osd_b,
    
    // Virtual Mouse Controls (To UART / CH9329 / USB HID)
    output wire [11:0] mouse_x,
    output wire [11:0] mouse_y,
    output wire        mouse_click_left,
    output wire        mouse_click_right,
    output wire [2:0]  system_state
);

    // 1. Color Space Conversion
    wire de_yuv, vsync_yuv, hsync_yuv;
    wire [7:0] pix_y, pix_cb, pix_cr;

    rgb_to_ycrcb_shift #(
        .DW(8)
    ) u_yuv (
        .clk     (clk_pixel),
        .rst_n   (rst_n),
        .i_de    (cam_de),
        .i_vsync (cam_vsync),
        .i_hsync (cam_hsync),
        .i_r     (cam_r),
        .i_g     (cam_g),
        .i_b     (cam_b),
        .o_de    (de_yuv),
        .o_vsync (vsync_yuv),
        .o_hsync (hsync_yuv),
        .o_y     (pix_y),
        .o_cb    (pix_cb),
        .o_cr    (pix_cr)
    );

    // 2. Skin Filter & 3x3 Morphology Dilation
    wire de_morph, vsync_morph, hsync_morph, pix_bin;

    skin_detect_morphology #(
        .IMG_WIDTH (IMG_WIDTH),
        .IMG_HEIGHT(IMG_HEIGHT)
    ) u_morph (
        .clk          (clk_pixel),
        .rst_n        (rst_n),
        .i_de         (de_yuv),
        .i_vsync      (vsync_yuv),
        .i_hsync      (hsync_yuv),
        .i_y          (pix_y),
        .i_cb         (pix_cb),
        .i_cr         (pix_cr),
        .i_morph_mode (1'b1), // Dilation to close finger gaps
        .o_de         (de_morph),
        .o_vsync      (vsync_morph),
        .o_hsync      (hsync_morph),
        .o_binary     (pix_bin)
    );

    // 3. Bounding Box & Fingertip Coordinate Tracker
    wire [11:0] bbox_xmin, bbox_xmax, bbox_ymin, bbox_ymax;
    wire [11:0] raw_tip_x, raw_tip_y;
    wire        target_valid;

    bbox_fingertip_tracker #(
        .IMG_WIDTH (IMG_WIDTH),
        .IMG_HEIGHT(IMG_HEIGHT)
    ) u_tracker (
        .clk           (clk_pixel),
        .rst_n         (rst_n),
        .i_de          (de_morph),
        .i_vsync       (vsync_morph),
        .i_hsync       (hsync_morph),
        .i_binary      (pix_bin),
        .o_bbox_xmin   (bbox_xmin),
        .o_bbox_xmax   (bbox_xmax),
        .o_bbox_ymin   (bbox_ymin),
        .o_bbox_ymax   (bbox_ymax),
        .o_tip_x       (raw_tip_x),
        .o_tip_y       (raw_tip_y),
        .o_valid_frame (target_valid)
    );

    // 4. Click-Hold Anti-Jitter State Machine
    // (Here i_gesture_class connects to neural network inference / click trigger)
    wire [1:0] gesture_class = (bbox_xmax - bbox_xmin < 12'd100) ? 2'b01 : 2'b00; // Sample trigger
    
    click_hold_fsm #(
        .CLK_FREQ_HZ (74_250_000),
        .LOCK_MS     (120),
        .COOLDOWN_MS (80)
    ) u_fsm (
        .clk               (clk_pixel),
        .rst_n             (rst_n),
        .i_frame_tick      (vsync_morph),
        .i_raw_x           (raw_tip_x),
        .i_raw_y           (raw_tip_y),
        .i_target_valid    (target_valid),
        .i_gesture_class   (gesture_class),
        .o_cursor_x        (mouse_x),
        .o_cursor_y        (mouse_y),
        .o_mouse_left_btn  (mouse_click_left),
        .o_mouse_right_btn (mouse_click_right),
        .o_fsm_state       (system_state)
    );

    // 5. On-Screen Display (OSD): Green Box + Red Crosshair
    reg [11:0] cur_x, cur_y;
    always @(posedge clk_pixel or negedge rst_n) begin
        if (!rst_n) begin
            cur_x <= 12'd0;
            cur_y <= 12'd0;
        end else if (!cam_vsync) begin
            cur_x <= 12'd0;
            cur_y <= 12'd0;
        end else if (cam_de) begin
            if (cur_x == IMG_WIDTH - 1) begin
                cur_x <= 12'd0;
                cur_y <= cur_y + 1'b1;
            end else begin
                cur_x <= cur_x + 1'b1;
            end
        end
    end

    // OSD Border logic (2-pixel thick border)
    wire is_bbox_edge = target_valid && (
        ((cur_x >= bbox_xmin && cur_x <= bbox_xmax) && (cur_y == bbox_ymin || cur_y == bbox_ymin+1 || cur_y == bbox_ymax || cur_y == bbox_ymax-1)) ||
        ((cur_y >= bbox_ymin && cur_y <= bbox_ymax) && (cur_x == bbox_xmin || cur_x == bbox_xmin+1 || cur_x == bbox_xmax || cur_x == bbox_xmax-1))
    );

    // OSD Crosshair logic (10-pixel arm)
    wire is_crosshair = target_valid && (
        ((cur_y == mouse_y) && (cur_x >= mouse_x - 12'd10 && cur_x <= mouse_x + 12'd10)) ||
        ((cur_x == mouse_x) && (cur_y >= mouse_y - 12'd10 && cur_y <= mouse_y + 12'd10))
    );

    assign osd_de    = cam_de;
    assign osd_vsync = cam_vsync;
    assign osd_hsync = cam_hsync;

    always @(posedge clk_pixel) begin
        if (is_crosshair) begin
            // Red Reticle Crosshair
            osd_r <= 8'hFF; osd_g <= 8'h00; osd_b <= 8'h00;
        end else if (is_bbox_edge) begin
            // Green Bounding Box
            osd_r <= 8'h00; osd_g <= 8'hFF; osd_b <= 8'h00;
        end else begin
            // Original Video
            osd_r <= cam_r; osd_g <= cam_g; osd_b <= cam_b;
        end
    end

endmodule
