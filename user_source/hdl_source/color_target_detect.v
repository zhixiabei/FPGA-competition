// Single red target detector, one displayed RGB888 pixel per clock.
// Tap the DDR display stream BEFORE any Logo, text or box overlay.
// A centered 3x3 majority filter rejects isolated pixels. Its supported
// centers are x=1..IMG_WIDTH-2, y=1..IMG_HEIGHT-2 (one-pixel border excluded).
// Results are published after the last input pixel, including its filtered
// center. The display latches that result at the NEXT frame's first pixel.
module color_target_detect #(
    parameter integer IMG_WIDTH = 1280,
    parameter integer IMG_HEIGHT = 720,
    parameter integer RED_MIN = 80,
    parameter integer RED_DELTA = 30,
    parameter integer MIN_PIXELS = 128,
    parameter integer MIN_WIDTH = 8,
    parameter integer MIN_HEIGHT = 8
) (
    input wire I_clk,
    input wire I_rst_n,
    input wire I_valid,
    input wire [11:0] I_x,
    input wire [11:0] I_y,
    input wire [23:0] I_rgb,
    output wire O_pixel_red,
    output reg O_result_ready,
    output reg O_found,
    output reg [11:0] O_xmin,
    output reg [11:0] O_xmax,
    output reg [11:0] O_ymin,
    output reg [11:0] O_ymax,
    output reg [11:0] O_center_x,
    output reg [11:0] O_center_y,
    output reg [23:0] O_pixels,
    output wire O_mask_valid,
    output wire O_mask_hit,
    output wire [11:0] O_mask_x,
    output wire [11:0] O_mask_y
);
    // Explicit 9-bit arithmetic: e.g. G=250 plus 30 must NOT wrap to 24.
    wire [8:0] red = {1'b0, I_rgb[23:16]};
    wire [8:0] green = {1'b0, I_rgb[15:8]};
    wire [8:0] blue = {1'b0, I_rgb[7:0]};
    wire [8:0] green_limit = green + RED_DELTA;
    wire [8:0] blue_limit = blue + RED_DELTA;
    assign O_pixel_red = I_valid && (red >= RED_MIN) &&
                        (red >= green_limit) && (red >= blue_limit);

    // Synchronous old-data reads; no reset loops on line RAMs. The first
    // two rows refill RAM before it can participate in the majority filter.
    reg line1 [0:IMG_WIDTH-1];
    reg line2 [0:IMG_WIDTH-1];
    reg top_now, mid_now, bot_now;
    reg top_prev2, top_prev1, mid_prev2, mid_prev1, bot_prev2, bot_prev1;
    reg valid_d;
    reg [11:0] x_d, y_d;

    always @(posedge I_clk) begin
        if (I_valid && I_x < IMG_WIDTH && I_y < IMG_HEIGHT) begin
            top_now <= line2[I_x];
            mid_now <= line1[I_x];
            bot_now <= O_pixel_red;
            line2[I_x] <= line1[I_x];
            line1[I_x] <= O_pixel_red;
        end
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            valid_d <= 1'b0;
            x_d <= 12'd0;
            y_d <= 12'd0;
            {top_prev2, top_prev1, mid_prev2, mid_prev1,
             bot_prev2, bot_prev1} <= 6'd0;
        end else begin
            valid_d <= I_valid && I_x < IMG_WIDTH && I_y < IMG_HEIGHT;
            x_d <= I_x;
            y_d <= I_y;
            if (valid_d) begin
                top_prev2 <= (x_d == 0) ? 1'b0 : top_prev1;
                mid_prev2 <= (x_d == 0) ? 1'b0 : mid_prev1;
                bot_prev2 <= (x_d == 0) ? 1'b0 : bot_prev1;
                top_prev1 <= top_now;
                mid_prev1 <= mid_now;
                bot_prev1 <= bot_now;
            end
        end
    end

    wire [3:0] votes =
        {3'd0,top_prev2} + {3'd0,top_prev1} + {3'd0,top_now} +
        {3'd0,mid_prev2} + {3'd0,mid_prev1} + {3'd0,mid_now} +
        {3'd0,bot_prev2} + {3'd0,bot_prev1} + {3'd0,bot_now};
    assign O_mask_valid = valid_d && (x_d >= 2) && (y_d >= 2);
    assign O_mask_hit = O_mask_valid && (votes >= 5);
    assign O_mask_x = x_d - 12'd1;
    assign O_mask_y = y_d - 12'd1;

    reg frame_open;
    reg [23:0] count, seen;
    reg [11:0] xmin, xmax, ymin, ymax;
    wire frame_start = valid_d && (x_d == 0) && (y_d == 0);
    wire frame_end = valid_d && (x_d == IMG_WIDTH-1) &&
                                (y_d == IMG_HEIGHT-1);
    wire hit = frame_open && O_mask_hit;
    wire [23:0] count_next = count + (hit ? 24'd1 : 24'd0);
    wire [11:0] xmin_next = hit && O_mask_x < xmin ? O_mask_x : xmin;
    wire [11:0] xmax_next = hit && O_mask_x > xmax ? O_mask_x : xmax;
    wire [11:0] ymin_next = hit && O_mask_y < ymin ? O_mask_y : ymin;
    wire [11:0] ymax_next = hit && O_mask_y > ymax ? O_mask_y : ymax;
    wire [12:0] box_width = {1'b0,xmax_next} - {1'b0,xmin_next} + 13'd1;
    wire [12:0] box_height = {1'b0,ymax_next} - {1'b0,ymin_next} + 13'd1;
    wire [12:0] center_x_sum = {1'b0,xmin_next} + {1'b0,xmax_next};
    wire [12:0] center_y_sum = {1'b0,ymin_next} + {1'b0,ymax_next};
    wire result_found = (count_next >= MIN_PIXELS) &&
                        (xmin_next <= xmax_next) && (ymin_next <= ymax_next) &&
                        (box_width >= MIN_WIDTH) && (box_height >= MIN_HEIGHT);
    wire frame_complete = (seen == IMG_WIDTH*IMG_HEIGHT-1);
    wire accept_result = result_found && frame_complete;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            frame_open <= 1'b0;
            seen <= 24'd0;
            count <= 24'd0;
            xmin <= IMG_WIDTH-1;
            xmax <= 12'd0;
            ymin <= IMG_HEIGHT-1;
            ymax <= 12'd0;
            O_result_ready <= 1'b0;
            O_found <= 1'b0;
            O_xmin <= 12'd0;
            O_xmax <= 12'd0;
            O_ymin <= 12'd0;
            O_ymax <= 12'd0;
            O_center_x <= 12'd0;
            O_center_y <= 12'd0;
            O_pixels <= 24'd0;
        end else if (frame_start) begin
            frame_open <= 1'b1;
            seen <= 24'd1;
            count <= 24'd0;
            xmin <= IMG_WIDTH-1;
            xmax <= 12'd0;
            ymin <= IMG_HEIGHT-1;
            ymax <= 12'd0;
            O_result_ready <= 1'b0;
        end else if (valid_d && frame_open) begin
            seen <= seen + 24'd1;
            count <= count_next;
            xmin <= xmin_next;
            xmax <= xmax_next;
            ymin <= ymin_next;
            ymax <= ymax_next;
            if (frame_end) begin
                frame_open <= 1'b0;
                O_result_ready <= frame_complete;
                O_found <= accept_result;
                O_pixels <= count_next;
                O_xmin <= accept_result ? xmin_next : 12'd0;
                O_xmax <= accept_result ? xmax_next : 12'd0;
                O_ymin <= accept_result ? ymin_next : 12'd0;
                O_ymax <= accept_result ? ymax_next : 12'd0;
                O_center_x <= accept_result ? center_x_sum[12:1] : 12'd0;
                O_center_y <= accept_result ? center_y_sum[12:1] : 12'd0;
            end
        end
    end
endmodule
