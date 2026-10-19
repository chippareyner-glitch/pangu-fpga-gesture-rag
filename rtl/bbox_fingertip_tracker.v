// =============================================================================
// Module Name: bbox_fingertip_tracker
// Description: Real-time Bounding Box & Fingertip Coordinate Extraction with
//              Hardware Moving Average Filtering on pure FPGA logic.
//              Latches stable coordinates at VSYNC falling edge.
// =============================================================================

`timescale 1ns / 1ps

module bbox_fingertip_tracker #(
    parameter IMG_WIDTH  = 1280,
    parameter IMG_HEIGHT = 720
)(
    input  wire        clk,
    input  wire        rst_n,
    
    // Binary video stream
    input  wire        i_de,
    input  wire        i_vsync,
    input  wire        i_hsync,
    input  wire        i_binary,
    
    // Stable Output Coordinates (Updated per frame)
    output reg  [11:0] o_bbox_xmin,
    output reg  [11:0] o_bbox_xmax,
    output reg  [11:0] o_bbox_ymin,
    output reg  [11:0] o_bbox_ymax,
    output reg  [11:0] o_tip_x,
    output reg  [11:0] o_tip_y,
    output reg         o_valid_frame
);

    // Raster scan counters
    reg [11:0] x_cnt;
    reg [11:0] y_cnt;
    reg vsync_prev;
    wire vsync_negedge = vsync_prev & ~i_vsync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_cnt      <= 12'd0;
            y_cnt      <= 12'd0;
            vsync_prev <= 1'b0;
        end else begin
            vsync_prev <= i_vsync;
            if (!i_vsync) begin
                x_cnt <= 12'd0;
                y_cnt <= 12'd0;
            end else if (i_de) begin
                if (x_cnt == IMG_WIDTH - 1) begin
                    x_cnt <= 12'd0;
                    y_cnt <= y_cnt + 1'b1;
                end else begin
                    x_cnt <= x_cnt + 1'b1;
                end
            end
        end
    end

    // Noise rejection: 3 consecutive white pixels to validate fingertip
    reg [2:0] consecutive_white;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            consecutive_white <= 3'd0;
        else if (i_de) begin
            if (i_binary)
                consecutive_white <= (consecutive_white == 3'd7) ? 3'd7 : consecutive_white + 1'b1;
            else
                consecutive_white <= 3'd0;
        end
    end

    // Per-frame temporary bounding box & fingertip
    reg [11:0] frame_xmin, frame_xmax;
    reg [11:0] frame_ymin, frame_ymax;
    reg [11:0] frame_tip_x, frame_tip_y;
    reg        tip_found;
    reg [23:0] skin_pixel_count;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_xmin       <= IMG_WIDTH;
            frame_xmax       <= 12'd0;
            frame_ymin       <= IMG_HEIGHT;
            frame_ymax       <= 12'd0;
            frame_tip_x      <= 12'd0;
            frame_tip_y      <= 12'd0;
            tip_found        <= 1'b0;
            skin_pixel_count <= 24'd0;
        end else if (!i_vsync) begin
            // Reset during vertical blanking
            frame_xmin       <= IMG_WIDTH;
            frame_xmax       <= 12'd0;
            frame_ymin       <= IMG_HEIGHT;
            frame_ymax       <= 12'd0;
            frame_tip_x      <= 12'd0;
            frame_tip_y      <= 12'd0;
            tip_found        <= 1'b0;
            skin_pixel_count <= 24'd0;
        end else if (i_de && i_binary) begin
            skin_pixel_count <= skin_pixel_count + 1'b1;

            // Bounding box update
            if (x_cnt < frame_xmin) frame_xmin <= x_cnt;
            if (x_cnt > frame_xmax) frame_xmax <= x_cnt;
            if (y_cnt < frame_ymin) frame_ymin <= y_cnt;
            if (y_cnt > frame_ymax) frame_ymax <= y_cnt;

            // Fingertip is the topmost valid point (minimum y with filter)
            if (!tip_found && consecutive_white >= 3'd3) begin
                frame_tip_x <= x_cnt - 12'd1; // center of cluster
                frame_tip_y <= y_cnt;
                tip_found   <= 1'b1;
            end
        end
    end

    // 4-Point Moving Average Filter for Fingertip Coordinates
    reg [11:0] tip_x_history [0:3];
    reg [11:0] tip_y_history [0:3];
    wire [13:0] avg_x_sum = tip_x_history[0] + tip_x_history[1] + tip_x_history[2] + tip_x_history[3];
    wire [13:0] avg_y_sum = tip_y_history[0] + tip_y_history[1] + tip_y_history[2] + tip_y_history[3];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_bbox_xmin   <= 12'd0;
            o_bbox_xmax   <= 12'd0;
            o_bbox_ymin   <= 12'd0;
            o_bbox_ymax   <= 12'd0;
            o_tip_x       <= 12'd0;
            o_tip_y       <= 12'd0;
            o_valid_frame <= 1'b0;
            tip_x_history[0] <= 12'd0; tip_x_history[1] <= 12'd0;
            tip_x_history[2] <= 12'd0; tip_x_history[3] <= 12'd0;
            tip_y_history[0] <= 12'd0; tip_y_history[1] <= 12'd0;
            tip_y_history[2] <= 12'd0; tip_y_history[3] <= 12'd0;
        end else if (vsync_negedge) begin
            // Frame completed: validate if sufficient skin pixels detected (> 500 pixels)
            if (skin_pixel_count > 24'd500 && tip_found) begin
                o_bbox_xmin   <= frame_xmin;
                o_bbox_xmax   <= frame_xmax;
                o_bbox_ymin   <= frame_ymin;
                o_bbox_ymax   <= frame_ymax;
                
                // Shift history buffer
                tip_x_history[3] <= tip_x_history[2];
                tip_x_history[2] <= tip_x_history[1];
                tip_x_history[1] <= tip_x_history[0];
                tip_x_history[0] <= frame_tip_x;

                tip_y_history[3] <= tip_y_history[2];
                tip_y_history[2] <= tip_y_history[1];
                tip_y_history[1] <= tip_y_history[0];
                tip_y_history[0] <= frame_tip_y;

                // 4-point average
                o_tip_x       <= avg_x_sum[13:2];
                o_tip_y       <= avg_y_sum[13:2];
                o_valid_frame <= 1'b1;
            end else begin
                o_valid_frame <= 1'b0;
            end
        end
    end

endmodule
