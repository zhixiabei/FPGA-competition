`timescale 1ns/1ps
// Single-target persistent handwriting overlay, one pixel clock domain.
// Reuse the system detector, frame metadata bridge and video coordinates.
// Default: 1280x720, 320x180 one-bit canvas, light half-weight smoothing.
module pen_minimal #(
    parameter integer IMG_WIDTH = 1280,
    parameter integer IMG_HEIGHT = 720,
    parameter integer CANVAS_SHIFT = 2,
    parameter integer MAX_JUMP_CELLS = 96 >> CANVAS_SHIFT,
    parameter integer SMOOTH_ENABLE = 1
)(
    input wire I_clk,
    input wire I_rst_n,
    input wire I_frame_start,
    input wire I_enable,
    input wire I_pause,
    input wire I_clear, // Synchronous pulse; held high keeps the canvas clearing.
    input wire I_pen_valid,
    input wire I_pen_hold, // Held/stale detector results never produce ink.
    input wire [10:0] I_pen_x,
    input wire [9:0] I_pen_y,
    input wire I_de,
    input wire [10:0] I_x,
    input wire [9:0] I_y,
    output wire O_ink, // One registered read clock; align RGB/DE/HS/VS equally.
    output wire O_busy,
    output reg O_clearing
);
    localparam integer CW = (IMG_WIDTH + (1<<CANVAS_SHIFT)-1)>>CANVAS_SHIFT;
    localparam integer CH = (IMG_HEIGHT + (1<<CANVAS_SHIFT)-1)>>CANVAS_SHIFT;
    localparam integer XW = CW>1 ? $clog2(CW) : 1;
    localparam integer YW = CH>1 ? $clog2(CH) : 1;
    localparam integer MW = XW>YW ? XW : YW;
    localparam integer DEPTH = CW*CH;
    localparam integer AW = DEPTH>1 ? $clog2(DEPTH) : 1;
    localparam [1:0] IDLE=0, PREPARE=1, DRAW=2, FILTER=3;

    reg canvas [0:DEPTH-1];
    reg [1:0] state;
    reg active, anchor_valid;
    reg [AW-1:0] clear_address;
    reg [XW-1:0] anchor_x, target_x, line_x;
    reg [YW-1:0] anchor_y, target_y, line_y;
    reg [MW-1:0] major_delta, minor_delta, error_acc;
    reg major_y, negative_x, negative_y;
    reg ink_read, read_gate;
    // Half-pixel precision avoids the one-cell dead zone of cell averaging.
    // Reuse the line engine's distance check before filtering a new sample.
    reg [CANVAS_SHIFT-1:0] target_low_x, target_low_y;
    reg [11:0] smooth_x;
    reg [10:0] smooth_y;
    reg [XW-1:0] raw_anchor_x;
    reg [YW-1:0] raw_anchor_y;
    wire [10:0] raw_x = {target_x,target_low_x};
    wire [9:0] raw_y = {target_y,target_low_y};
    wire [12:0] smooth_sum_x = {1'b0,smooth_x}+{1'b0,raw_x,1'b0}+13'd1;
    wire [11:0] smooth_sum_y = {1'b0,smooth_y}+{1'b0,raw_y,1'b0}+12'd1;

    // Share the distance hardware between raw jump rejection and line setup.
    // Filtering must not halve a large jump or misclassify fast valid motion.
    wire [XW-1:0] distance_anchor_x = SMOOTH_ENABLE && state==FILTER ? raw_anchor_x : anchor_x;
    wire [YW-1:0] distance_anchor_y = SMOOTH_ENABLE && state==FILTER ? raw_anchor_y : anchor_y;
    wire [MW-1:0] distance_x = target_x>=distance_anchor_x ?
        target_x-distance_anchor_x : distance_anchor_x-target_x;
    wire [MW-1:0] distance_y = target_y>=distance_anchor_y ?
        target_y-distance_anchor_y : distance_anchor_y-target_y;
    wire join_line = anchor_valid && distance_x<=MAX_JUMP_CELLS &&
        distance_y<=MAX_JUMP_CELLS;
    wire [MW:0] error_sum = {1'b0,error_acc}+{1'b0,minor_delta};
    wire minor_step = error_sum >= {1'b0,major_delta};
    wire [MW:0] error_next = minor_step ? error_sum-major_delta : error_sum;
    wire clear_request = I_clear || (I_frame_start && active && !I_enable);
    wire write_enable = O_clearing || (state==DRAW && !I_frame_start);

    // Constant row stride is implemented with shifts/adds, never a DSP.
    function [AW-1:0] address;
        input [XW-1:0] x;
        input [YW-1:0] y;
        reg [AW-1:0] widened_y;
        integer bit_index;
        begin
            widened_y=y;
            address=x;
            for(bit_index=0;bit_index<AW;bit_index=bit_index+1)
                if ((CW & (1<<bit_index))!=0)
                    address=address+(widened_y<<bit_index);
        end
    endfunction
    wire [XW-1:0] read_x = I_x>>CANVAS_SHIFT;
    wire [YW-1:0] read_y = I_y>>CANVAS_SHIFT;
    wire [AW-1:0] read_address = address(read_x,read_y);
    wire [AW-1:0] write_address = O_clearing ? clear_address : address(line_x,line_y);
    wire read_valid = I_de && I_x<IMG_WIDTH && I_y<IMG_HEIGHT;

    // No memory reset: a sweep after reset/clear permits ERAM inference.
    // Read-during-write is read-first; a just-written cell is visible next read.
    always @(posedge I_clk) begin
        if (write_enable && !clear_request)
            canvas[write_address] <= !O_clearing;
        if (read_valid)
            ink_read <= canvas[read_address];
    end
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) read_gate<=0;
        else read_gate<=read_valid && active && !O_clearing && !clear_request;
    end
    assign O_ink = ink_read && read_gate && !O_clearing && !clear_request;
    assign O_busy = O_clearing || state!=IDLE;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            state<=IDLE; active<=0; anchor_valid<=0;
            O_clearing<=1; clear_address<=0;
            anchor_x<=0; anchor_y<=0; target_x<=0; target_y<=0;
            line_x<=0; line_y<=0;
            major_delta<=0; minor_delta<=0; error_acc<=0;
            major_y<=0; negative_x<=0; negative_y<=0;
            target_low_x<=0; target_low_y<=0; smooth_x<=0; smooth_y<=0;
            raw_anchor_x<=0; raw_anchor_y<=0;
        end else if (clear_request) begin
            O_clearing<=1; clear_address<=0;
            state<=IDLE; anchor_valid<=0;
            if (I_frame_start) active<=I_enable;
        end else begin
            if (I_frame_start) active<=I_enable;
            if (O_clearing) begin
                state<=IDLE; anchor_valid<=0;
                if (clear_address==DEPTH-1) begin
                    O_clearing<=0; clear_address<=0;
                end else clear_address<=clear_address+1'b1;
            end else if (I_frame_start) begin
                // Even if a frame unexpectedly interrupts drawing, never join
                // from a segment whose endpoint was not actually written.
                if (!I_enable || I_pause || !I_pen_valid || I_pen_hold ||
                    I_pen_x>=IMG_WIDTH || I_pen_y>=IMG_HEIGHT || state!=IDLE) begin
                    state<=IDLE; anchor_valid<=0;
                end else begin
                    target_x<=I_pen_x>>CANVAS_SHIFT;
                    target_y<=I_pen_y>>CANVAS_SHIFT;
                    target_low_x<=I_pen_x[CANVAS_SHIFT-1:0];
                    target_low_y<=I_pen_y[CANVAS_SHIFT-1:0];
                    state<=SMOOTH_ENABLE ? FILTER : PREPARE;
                end
            end else case(state)
                FILTER: begin
                    raw_anchor_x<=target_x; raw_anchor_y<=target_y;
                    if (join_line) begin
                        // new = (old + measurement)/2; no DSP or frame buffer.
                        smooth_x<=smooth_sum_x>>1;
                        smooth_y<=smooth_sum_y>>1;
                        target_x<=smooth_sum_x>>(CANVAS_SHIFT+2);
                        target_y<=smooth_sum_y>>(CANVAS_SHIFT+2);
                    end else begin
                        // A new stroke starts exactly at the measured position.
                        // Gate BEFORE smoothing so a jump cannot turn into a line.
                        smooth_x<={raw_x,1'b0};
                        smooth_y<={raw_y,1'b0};
                        anchor_valid<=0;
                    end
                    state<=PREPARE;
                end
                PREPARE: begin
                    line_x<=join_line ? anchor_x : target_x;
                    line_y<=join_line ? anchor_y : target_y;
                    negative_x<=target_x<anchor_x;
                    negative_y<=target_y<anchor_y;
                    major_y<=distance_y>distance_x;
                    major_delta<=!join_line ? 0 :
                        (distance_y>distance_x ? distance_y : distance_x);
                    minor_delta<=!join_line ? 0 :
                        (distance_y>distance_x ? distance_x : distance_y);
                    error_acc<=!join_line ? 0 :
                        ((distance_y>distance_x ? distance_y : distance_x)>>1);
                    anchor_x<=target_x; anchor_y<=target_y; anchor_valid<=1;
                    state<=DRAW;
                end
                DRAW: begin
                    if (line_x==target_x && line_y==target_y) state<=IDLE;
                    else begin
                        if (!major_y || minor_step)
                            line_x<=negative_x ? line_x-1'b1 : line_x+1'b1;
                        if (major_y || minor_step)
                            line_y<=negative_y ? line_y-1'b1 : line_y+1'b1;
                        error_acc<=error_next[MW-1:0];
                    end
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
