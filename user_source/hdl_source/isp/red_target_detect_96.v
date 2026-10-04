// Four-pixel-per-clock red target detector, before the RGB/edge selector.
// The centered 3x3 majority filter matches color_target_detect: centers on
// the one-pixel outer border are excluded. Results include the final beat.
module red_target_detect_96 #(
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
    input wire I_tuser,
    input wire I_tvalid,
    input wire [95:0] I_tdata,
    output reg O_result_ready,
    output reg O_found,
    output reg [11:0] O_xmin,
    output reg [11:0] O_xmax,
    output reg [11:0] O_ymin,
    output reg [11:0] O_ymax,
    output reg [11:0] O_center_x,
    output reg [11:0] O_center_y,
    output reg [23:0] O_pixels,
    output reg O_frame_toggle
);
    function integer bit_width;
        input integer size;
        integer value;
        begin
            value = size-1;
            bit_width = 0;
            while (value > 0) begin
                bit_width = bit_width+1;
                value = value >> 1;
            end
            if (bit_width < 1) bit_width = 1;
        end
    endfunction
    localparam integer IMG_WIDTH_GRP = IMG_WIDTH / 4;
    localparam integer GROUP_BITS = bit_width(IMG_WIDTH_GRP);
    localparam integer X_BITS = bit_width(IMG_WIDTH);
    localparam integer Y_BITS = bit_width(IMG_HEIGHT);
    localparam integer COUNT_BITS = bit_width((IMG_WIDTH-2)*(IMG_HEIGHT-2)+1);
    localparam [8:0] RED_MIN_9 = RED_MIN;
    localparam [8:0] RED_DELTA_9 = RED_DELTA;

    // data128_96 puts the earliest pixel in bits 95:72, and AWB preserves
    // that order. video_out displays the most-significant bytes first.
    wire [3:0] red_mask;
    genvar p;
    generate
        for (p = 0; p < 4; p = p + 1) begin : gen_red
            wire [8:0] red;
            wire [8:0] green_limit;
            wire [8:0] blue_limit;
            assign red = {1'b0,I_tdata[95-p*24-:8]};
            assign green_limit = {1'b0,I_tdata[87-p*24-:8]} + RED_DELTA_9;
            assign blue_limit = {1'b0,I_tdata[79-p*24-:8]} + RED_DELTA_9;
            assign red_mask[p] = (red >= RED_MIN_9) &&
                                (red >= green_limit) && (red >= blue_limit);
        end
    endgenerate

    reg [GROUP_BITS-1:0] x_grp;
    reg [Y_BITS-1:0] y_pos;
    reg frame_pending;
    reg frame_open;
    wire start_frame = frame_pending || I_tuser;
    wire accept_beat = I_tvalid && (frame_open || start_frame);
    wire [GROUP_BITS-1:0] beat_group = start_frame ? {GROUP_BITS{1'b0}} : x_grp;
    wire [Y_BITS-1:0] beat_row = start_frame ? {Y_BITS{1'b0}} : y_pos;
    wire final_beat = (beat_group == IMG_WIDTH_GRP-1) &&
                     (beat_row == IMG_HEIGHT-1);

    // AWB's O_tuser is the early input marker. Remember it during blanking
    // and reset coordinates on the next valid output beat. A new marker also
    // abandons any incomplete frame, so lost beats cannot offset later frames.
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            x_grp <= {GROUP_BITS{1'b0}};
            y_pos <= {Y_BITS{1'b0}};
            frame_pending <= 1'b0;
            frame_open <= 1'b0;
        end else begin
            if (I_tuser)
                frame_pending <= 1'b1;
            if (accept_beat) begin
                frame_pending <= 1'b0;
                frame_open <= 1'b1;
                if (final_beat) begin
                    x_grp <= {GROUP_BITS{1'b0}};
                    y_pos <= {Y_BITS{1'b0}};
                end else if (beat_group == IMG_WIDTH_GRP-1) begin
                    x_grp <= {GROUP_BITS{1'b0}};
                    y_pos <= beat_row + 1'b1;
                end else begin
                    x_grp <= beat_group + 1'b1;
                    y_pos <= beat_row;
                end
            end
        end
    end

    // Four mask bits per RAM address. Synchronous old-data reads and no
    // reset loop allow block-RAM inference; rows 0 and 1 refill the buffers
    // before any old data can contribute to the majority filter.
    reg [3:0] line1 [0:IMG_WIDTH_GRP-1];
    reg [3:0] line2 [0:IMG_WIDTH_GRP-1];
    reg [3:0] top_now, mid_now, bot_now;
    always @(posedge I_clk) begin
        if (accept_beat) begin
            top_now <= line2[beat_group];
            mid_now <= line1[beat_group];
            bot_now <= red_mask;
            line2[beat_group] <= line1[beat_group];
            line1[beat_group] <= red_mask;
        end
    end

    reg valid_d, start_d, final_d;
    reg [GROUP_BITS-1:0] group_d;
    reg [Y_BITS-1:0] row_d;
    reg top_prev2, top_prev1, mid_prev2, mid_prev1, bot_prev2, bot_prev1;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            valid_d <= 1'b0;
            start_d <= 1'b0;
            final_d <= 1'b0;
            group_d <= {GROUP_BITS{1'b0}};
            row_d <= {Y_BITS{1'b0}};
            {top_prev2,top_prev1,mid_prev2,mid_prev1,
             bot_prev2,bot_prev1} <= 6'd0;
        end else begin
            valid_d <= accept_beat;
            start_d <= accept_beat && start_frame;
            final_d <= accept_beat && final_beat;
            group_d <= beat_group;
            row_d <= beat_row;
            if (valid_d) begin
                top_prev2 <= top_now[2];
                top_prev1 <= top_now[3];
                mid_prev2 <= mid_now[2];
                mid_prev1 <= mid_now[3];
                bot_prev2 <= bot_now[2];
                bot_prev1 <= bot_now[3];
            end
        end
    end

    // Stage 1: majority decisions are independent for the four lanes.
    // Sum each row first, then sum the three row totals; avoid a serial
    // nine-input addition chain. Lane 0/1 need a previous group in the row.
    wire [3:0] filtered_hits;
    genvar lane;
    generate
        for (lane = 0; lane < 4; lane = lane+1) begin : gen_majority
            wire [2:0] top_window, mid_window, bot_window;
            wire [1:0] top_votes, mid_votes, bot_votes;
            wire [3:0] votes;
            if (lane == 0) begin
                assign top_window = {top_prev2,top_prev1,top_now[0]};
                assign mid_window = {mid_prev2,mid_prev1,mid_now[0]};
                assign bot_window = {bot_prev2,bot_prev1,bot_now[0]};
            end else if (lane == 1) begin
                assign top_window = {top_prev1,top_now[0],top_now[1]};
                assign mid_window = {mid_prev1,mid_now[0],mid_now[1]};
                assign bot_window = {bot_prev1,bot_now[0],bot_now[1]};
            end else if (lane == 2) begin
                assign top_window = top_now[2:0];
                assign mid_window = mid_now[2:0];
                assign bot_window = bot_now[2:0];
            end else begin
                assign top_window = top_now[3:1];
                assign mid_window = mid_now[3:1];
                assign bot_window = bot_now[3:1];
            end
            assign top_votes = {1'b0,top_window[0]} + {1'b0,top_window[1]} + {1'b0,top_window[2]};
            assign mid_votes = {1'b0,mid_window[0]} + {1'b0,mid_window[1]} + {1'b0,mid_window[2]};
            assign bot_votes = {1'b0,bot_window[0]} + {1'b0,bot_window[1]} + {1'b0,bot_window[2]};
            assign votes = {2'd0,top_votes} + {2'd0,mid_votes} + {2'd0,bot_votes};
            assign filtered_hits[lane] = (row_d >= 2) &&
                                         ((lane >= 2) || group_d != 0) && (votes >= 5);
        end
    endgenerate

    reg valid_h, start_h, final_h;
    reg [3:0] hits_h;
    reg [GROUP_BITS-1:0] group_h;
    reg [Y_BITS-1:0] row_h;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            valid_h <= 1'b0;
            start_h <= 1'b0;
            final_h <= 1'b0;
            hits_h <= 4'd0;
            group_h <= {GROUP_BITS{1'b0}};
            row_h <= {Y_BITS{1'b0}};
        end else begin
            valid_h <= valid_d;
            start_h <= start_d;
            final_h <= final_d;
            if (valid_d) begin
                hits_h <= filtered_hits;
                group_h <= group_d;
                row_h <= row_d;
            end
        end
    end

    // Stage 2: one priority encoder for each extremum and a balanced
    // popcount. Center x=4*group+lane-1 is formed with concatenation; only
    // lane 0 needs the previous group. No chain of four 12-bit additions.
    wire [GROUP_BITS-1:0] previous_group = group_h-1'b1;
    wire [X_BITS-1:0] lane_x0 = {previous_group,2'b11};
    wire [X_BITS-1:0] lane_x1 = {group_h,2'b00};
    wire [X_BITS-1:0] lane_x2 = {group_h,2'b01};
    wire [X_BITS-1:0] lane_x3 = {group_h,2'b10};
    wire [1:0] hits_low = {1'b0,hits_h[0]} + {1'b0,hits_h[1]};
    wire [1:0] hits_high = {1'b0,hits_h[2]} + {1'b0,hits_h[3]};
    wire [2:0] beat_popcount = {1'b0,hits_low} + {1'b0,hits_high};
    wire [X_BITS-1:0] first_x = hits_h[0] ? lane_x0 :
                              hits_h[1] ? lane_x1 :
                              hits_h[2] ? lane_x2 : lane_x3;
    wire [X_BITS-1:0] last_x = hits_h[3] ? lane_x3 :
                             hits_h[2] ? lane_x2 :
                             hits_h[1] ? lane_x1 : lane_x0;
    reg valid_b, start_b, final_b, hit_b;
    reg [2:0] popcount_b;
    reg [X_BITS-1:0] xmin_b, xmax_b;
    reg [Y_BITS-1:0] y_b;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            valid_b <= 1'b0;
            start_b <= 1'b0;
            final_b <= 1'b0;
            hit_b <= 1'b0;
            popcount_b <= 3'd0;
            xmin_b <= {X_BITS{1'b0}};
            xmax_b <= {X_BITS{1'b0}};
            y_b <= {Y_BITS{1'b0}};
        end else begin
            valid_b <= valid_h;
            start_b <= start_h;
            final_b <= final_h;
            if (valid_h) begin
                hit_b <= |hits_h;
                popcount_b <= beat_popcount;
                xmin_b <= first_x;
                xmax_b <= last_x;
                y_b <= row_h-1'b1;
            end
        end
    end

    // Stage 3: one count update and one comparator/mux per box extremum.
    // Snapshot the next values on the final beat, including that beat's hits.
    reg [COUNT_BITS-1:0] count;
    reg [X_BITS-1:0] xmin, xmax;
    reg [Y_BITS-1:0] ymin, ymax;
    wire [COUNT_BITS-1:0] count_next = start_b ? popcount_b : count+popcount_b;
    wire [X_BITS-1:0] xmin_next = start_b ? (hit_b ? xmin_b : IMG_WIDTH-1) :
                                         (hit_b && xmin_b < xmin ? xmin_b : xmin);
    wire [X_BITS-1:0] xmax_next = start_b ? (hit_b ? xmax_b : {X_BITS{1'b0}}) :
                                         (hit_b && xmax_b > xmax ? xmax_b : xmax);
    wire [Y_BITS-1:0] ymin_next = start_b ? (hit_b ? y_b : IMG_HEIGHT-1) :
                                         (hit_b && y_b < ymin ? y_b : ymin);
    wire [Y_BITS-1:0] ymax_next = start_b ? (hit_b ? y_b : {Y_BITS{1'b0}}) :
                                         (hit_b && y_b > ymax ? y_b : ymax);
    reg snapshot_valid;
    reg [COUNT_BITS-1:0] snapshot_count;
    reg [X_BITS-1:0] snapshot_xmin, snapshot_xmax;
    reg [Y_BITS-1:0] snapshot_ymin, snapshot_ymax;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            count <= {COUNT_BITS{1'b0}};
            xmin <= IMG_WIDTH-1;
            xmax <= {X_BITS{1'b0}};
            ymin <= IMG_HEIGHT-1;
            ymax <= {Y_BITS{1'b0}};
            snapshot_valid <= 1'b0;
            snapshot_count <= {COUNT_BITS{1'b0}};
            snapshot_xmin <= {X_BITS{1'b0}};
            snapshot_xmax <= {X_BITS{1'b0}};
            snapshot_ymin <= {Y_BITS{1'b0}};
            snapshot_ymax <= {Y_BITS{1'b0}};
        end else begin
            snapshot_valid <= valid_b && final_b;
            if (valid_b) begin
                count <= count_next;
                xmin <= xmin_next;
                xmax <= xmax_next;
                ymin <= ymin_next;
                ymax <= ymax_next;
                if (final_b) begin
                    snapshot_count <= count_next;
                    snapshot_xmin <= xmin_next;
                    snapshot_xmax <= xmax_next;
                    snapshot_ymin <= ymin_next;
                    snapshot_ymax <= ymax_next;
                    // Geometry fallback also supports consecutive frames
                    // without another marker or an intervening blank cycle.
                    count <= {COUNT_BITS{1'b0}};
                    xmin <= IMG_WIDTH-1;
                    xmax <= {X_BITS{1'b0}};
                    ymin <= IMG_HEIGHT-1;
                    ymax <= {Y_BITS{1'b0}};
                end
            end
        end
    end

    // Stage 4: register frame width/height and center before qualification.
    reg metrics_valid, metrics_box_valid, metrics_count_ok;
    reg [COUNT_BITS-1:0] metrics_count;
    reg [X_BITS-1:0] metrics_xmin, metrics_xmax, metrics_center_x;
    reg [Y_BITS-1:0] metrics_ymin, metrics_ymax, metrics_center_y;
    reg [X_BITS:0] metrics_width;
    reg [Y_BITS:0] metrics_height;
    wire [X_BITS:0] center_x_sum = {1'b0,snapshot_xmin}+{1'b0,snapshot_xmax};
    wire [Y_BITS:0] center_y_sum = {1'b0,snapshot_ymin}+{1'b0,snapshot_ymax};
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            metrics_valid <= 1'b0;
            metrics_box_valid <= 1'b0;
            metrics_count_ok <= 1'b0;
            metrics_count <= {COUNT_BITS{1'b0}};
            metrics_xmin <= {X_BITS{1'b0}};
            metrics_xmax <= {X_BITS{1'b0}};
            metrics_ymin <= {Y_BITS{1'b0}};
            metrics_ymax <= {Y_BITS{1'b0}};
            metrics_center_x <= {X_BITS{1'b0}};
            metrics_center_y <= {Y_BITS{1'b0}};
            metrics_width <= {(X_BITS+1){1'b0}};
            metrics_height <= {(Y_BITS+1){1'b0}};
        end else begin
            metrics_valid <= snapshot_valid;
            if (snapshot_valid) begin
                metrics_box_valid <= (snapshot_xmin <= snapshot_xmax) &&
                                     (snapshot_ymin <= snapshot_ymax);
                metrics_count_ok <= snapshot_count >= MIN_PIXELS;
                metrics_count <= snapshot_count;
                metrics_xmin <= snapshot_xmin;
                metrics_xmax <= snapshot_xmax;
                metrics_ymin <= snapshot_ymin;
                metrics_ymax <= snapshot_ymax;
                metrics_center_x <= center_x_sum[X_BITS:1];
                metrics_center_y <= center_y_sum[Y_BITS:1];
                metrics_width <= {1'b0,snapshot_xmax}-{1'b0,snapshot_xmin}+1'b1;
                metrics_height <= {1'b0,snapshot_ymax}-{1'b0,snapshot_ymin}+1'b1;
            end
        end
    end

    // Stage 5: publication is five clocks after acceptance of the last input
    // beat. Metadata follows every pipeline stage even when valid has gaps.
    wire result_found = metrics_count_ok && metrics_box_valid &&
                        (metrics_width >= MIN_WIDTH) && (metrics_height >= MIN_HEIGHT);
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_result_ready <= 1'b0;
            O_found <= 1'b0;
            O_xmin <= 12'd0;
            O_xmax <= 12'd0;
            O_ymin <= 12'd0;
            O_ymax <= 12'd0;
            O_center_x <= 12'd0;
            O_center_y <= 12'd0;
            O_pixels <= 24'd0;
            O_frame_toggle <= 1'b0;
        end else begin
            O_result_ready <= metrics_valid;
            if (metrics_valid) begin
                O_frame_toggle <= ~O_frame_toggle;
                O_pixels <= metrics_count;
                O_found <= result_found;
                O_xmin <= result_found ? metrics_xmin : 12'd0;
                O_xmax <= result_found ? metrics_xmax : 12'd0;
                O_ymin <= result_found ? metrics_ymin : 12'd0;
                O_ymax <= result_found ? metrics_ymax : 12'd0;
                O_center_x <= result_found ? metrics_center_x : 12'd0;
                O_center_y <= result_found ? metrics_center_y : 12'd0;
            end
        end
    end
endmodule
