// =============================================================================
// Module Name: click_hold_fsm
// Description: Click-Hold Coordinate Locking State Machine.
//              Freezes cursor coordinates at the exact instant a click gesture
//              initiates, eliminating muscle-recoil-induced cursor jitter.
// =============================================================================

`timescale 1ns / 1ps

module click_hold_fsm #(
    parameter CLK_FREQ_HZ = 50_000_000,
    parameter LOCK_MS     = 100, // Lock cursor for 100ms on click trigger
    parameter COOLDOWN_MS = 60   // Release debounce cooldown
)(
    input  wire        clk,
    input  wire        rst_n,
    
    // Raw inputs from tracker & neural network
    input  wire        i_frame_tick,     // Frame pulse (60Hz)
    input  wire [11:0] i_raw_x,
    input  wire [11:0] i_raw_y,
    input  wire        i_target_valid,
    input  wire [1:0]  i_gesture_class,  // 00: Hover, 01: Click, 10: Grab, 11: None
    
    // Stabilized Virtual Mouse Output
    output reg  [11:0] o_cursor_x,
    output reg  [11:0] o_cursor_y,
    output reg         o_mouse_left_btn,
    output reg         o_mouse_right_btn,
    output reg  [2:0]  o_fsm_state
);

    localparam S_IDLE       = 3'd0;
    localparam S_HOVER      = 3'd1;
    localparam S_CLICK_LOCK = 3'd2;
    localparam S_CLICK_HOLD = 3'd3;
    localparam S_COOLDOWN   = 3'd4;

    reg [2:0] state, next_state;
    reg [23:0] timer_cnt;
    localparam CNT_LOCK     = (CLK_FREQ_HZ / 1000) * LOCK_MS;
    localparam CNT_COOLDOWN = (CLK_FREQ_HZ / 1000) * COOLDOWN_MS;

    reg [11:0] locked_x, locked_y;

    // FSM State Transition
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= S_IDLE;
        else
            state <= next_state;
    end

    // Next State Logic
    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE: begin
                if (i_target_valid)
                    next_state = S_HOVER;
            end

            S_HOVER: begin
                if (!i_target_valid)
                    next_state = S_IDLE;
                else if (i_gesture_class == 2'b01) // Click detected
                    next_state = S_CLICK_LOCK;
            end

            S_CLICK_LOCK: begin
                // Freeze coordinates immediately for lock duration
                if (timer_cnt >= CNT_LOCK)
                    next_state = S_CLICK_HOLD;
            end

            S_CLICK_HOLD: begin
                if (i_gesture_class != 2'b01) // Released
                    next_state = S_COOLDOWN;
            end

            S_COOLDOWN: begin
                if (timer_cnt >= CNT_COOLDOWN)
                    next_state = i_target_valid ? S_HOVER : S_IDLE;
            end

            default: next_state = S_IDLE;
        endcase
    end

    // Datapath & Timer
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            timer_cnt         <= 24'd0;
            locked_x          <= 12'd0;
            locked_y          <= 12'd0;
            o_cursor_x        <= 12'd0;
            o_cursor_y        <= 12'd0;
            o_mouse_left_btn  <= 1'b0;
            o_mouse_right_btn <= 1'b0;
            o_fsm_state       <= S_IDLE;
        end else begin
            o_fsm_state <= state;

            case (state)
                S_IDLE: begin
                    timer_cnt        <= 24'd0;
                    o_mouse_left_btn <= 1'b0;
                end

                S_HOVER: begin
                    timer_cnt        <= 24'd0;
                    o_cursor_x       <= i_raw_x;
                    o_cursor_y       <= i_raw_y;
                    o_mouse_left_btn <= 1'b0;
                    // Latch potential lock coordinates continuously
                    locked_x         <= i_raw_x;
                    locked_y         <= i_raw_y;
                end

                S_CLICK_LOCK: begin
                    // HOLD PREVIOUS COORDINATES RIGIDLY
                    o_cursor_x       <= locked_x;
                    o_cursor_y       <= locked_y;
                    o_mouse_left_btn <= 1'b1; // Assert mouse button
                    timer_cnt        <= timer_cnt + 1'b1;
                end

                S_CLICK_HOLD: begin
                    timer_cnt        <= 24'd0;
                    o_cursor_x       <= locked_x;
                    o_cursor_y       <= locked_y;
                    o_mouse_left_btn <= 1'b1;
                end

                S_COOLDOWN: begin
                    // Still maintain locked coordinate until muscle recoil settles
                    o_cursor_x       <= locked_x;
                    o_cursor_y       <= locked_y;
                    o_mouse_left_btn <= 1'b0;
                    timer_cnt        <= timer_cnt + 1'b1;
                end
            endcase
        end
    end

endmodule
