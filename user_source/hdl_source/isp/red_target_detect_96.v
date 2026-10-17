// Four-pixel-per-clock red target detector, before the RGB/edge selector.
// The centered 3x3 majority filter matches color_target_detect: centers on
// the one-pixel outer border are excluded. Results include the final beat.
module red_target_detect_96 #(
    parameter integer IMG_WIDTH = 1280,
    parameter integer IMG_HEIGHT = 720,
    parameter integer RED_MIN = 24,
    parameter integer RED_DELTA = 6,
    parameter integer MIN_PIXELS = 128,
    parameter integer MIN_WIDTH = 8,
    parameter integer MIN_HEIGHT = 8,
    parameter integer MULTI_ENABLE = 0
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
    output reg O_frame_toggle,
    input wire [9:0] I_frame_id,
    input wire I_multi_clear,
    output wire O_multi_ready,
    output wire [3:0] O_multi_valid,
    output wire [3:0] O_multi_hold,
    output wire [191:0] O_multi_boxes,
    output wire [9:0] O_multi_frame_id,
    output wire O_multi_overflow
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
    //
    // Use normalized chroma/hue bounds instead of a large absolute channel
    // difference, so dim red retains the same color decision as bright red.
    // For red as the largest channel these integer comparisons require:
    //   max(G,B) <= 2R/3 and |G-B| <= (R-min(G,B))/3.
    // The latter is the +/-20 degree red HSV hue interval. No divider, DSP,
    // hue conversion or maximum/minimum datapath is needed. RED_MIN and the
    // small RED_DELTA remain as a floor against dark channel noise.
    // Low-saturation pink/white and orange/purple are outside these bounds;
    // genuinely clipped pixels cannot recover their original color here.
    wire [3:0] red_mask;
    genvar p;
    generate
        for (p = 0; p < 4; p = p + 1) begin : gen_red
            wire [8:0] red;
            wire [7:0] green;
            wire [7:0] blue;
            wire [8:0] green_limit;
            wire [8:0] blue_limit;
            wire [9:0] twice_red;
            wire [9:0] triple_green;
            wire [9:0] triple_blue;
            wire [9:0] hue_green_limit;
            wire [9:0] hue_blue_limit;
            assign red = {1'b0,I_tdata[95-p*24-:8]};
            assign green = I_tdata[87-p*24-:8];
            assign blue = I_tdata[79-p*24-:8];
            assign green_limit = {1'b0,green} + RED_DELTA_9;
            assign blue_limit = {1'b0,blue} + RED_DELTA_9;
            assign twice_red = {1'b0,red[7:0],1'b0};
            assign triple_green = {2'b0,green} + {1'b0,green,1'b0};
            assign triple_blue = {2'b0,blue} + {1'b0,blue,1'b0};
            assign hue_green_limit = {1'b0,red} + {1'b0,blue,1'b0};
            assign hue_blue_limit = {1'b0,red} + {1'b0,green,1'b0};
            assign red_mask[p] = (red >= RED_MIN_9) &&
                                (red >= green_limit) && (red >= blue_limit) &&
                                (twice_red >= triple_green) &&
                                (twice_red >= triple_blue) &&
                                (triple_green <= hue_green_limit) &&
                                (triple_blue <= hue_blue_limit);
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

    generate
        if (MULTI_ENABLE) begin : gen_multi
            reg [9:0] pending_id, active_id, id_d, id_h, id_b;
            wire [9:0] accepted_id = start_frame ?
                (I_tuser ? I_frame_id : pending_id) : active_id;
            always @(posedge I_clk or negedge I_rst_n) begin
                if (!I_rst_n) begin
                    pending_id <= 0; active_id <= 0;
                    id_d <= 0; id_h <= 0; id_b <= 0;
                end else begin
                    if (I_tuser) pending_id <= I_frame_id;
                    if (accept_beat) begin
                        id_d <= accepted_id;
                        if (start_frame) active_id <= accepted_id;
                    end
                    if (valid_d) id_h <= id_d;
                    if (valid_h) id_b <= id_h;
                end
            end
            red_multi_run_engine #(
                .IMG_WIDTH(IMG_WIDTH), .IMG_HEIGHT(IMG_HEIGHT),
                .X_BITS(X_BITS), .Y_BITS(Y_BITS), .COUNT_BITS(COUNT_BITS),
                .MIN_PIXELS(MIN_PIXELS), .MIN_WIDTH(MIN_WIDTH), .MIN_HEIGHT(MIN_HEIGHT)
            ) u_engine (
                .I_clk(I_clk), .I_rst_n(I_rst_n), .I_clear(I_multi_clear),
                .I_valid(valid_b), .I_start(start_b), .I_final(final_b),
                .I_hit(hit_b), .I_pixels(popcount_b),
                .I_xmin(xmin_b), .I_xmax(xmax_b), .I_y(y_b), .I_id(id_b),
                .O_ready(O_multi_ready), .O_valid(O_multi_valid), .O_hold(O_multi_hold),
                .O_boxes(O_multi_boxes), .O_frame_id(O_multi_frame_id),
                .O_overflow(O_multi_overflow)
            );
        end else begin : gen_single_only
            assign O_multi_ready = 1'b0;
            assign O_multi_valid = 4'b0;
            assign O_multi_hold = 4'b0;
            assign O_multi_boxes = 192'b0;
            assign O_multi_frame_id = 10'b0;
            assign O_multi_overflow = 1'b0;
        end
    endgenerate
endmodule

// Bounded scanline connectivity. A descriptor carries its frame identity all
// the way through the FIFO; a following SOF never resets an older context.
module red_multi_run_engine #(
    parameter integer IMG_WIDTH = 1280,
    parameter integer IMG_HEIGHT = 720,
    parameter integer X_BITS = 11,
    parameter integer Y_BITS = 10,
    parameter integer COUNT_BITS = 20,
    parameter integer MIN_PIXELS = 128,
    parameter integer MIN_WIDTH = 8,
    parameter integer MIN_HEIGHT = 8
) (
    input wire I_clk, I_rst_n, I_clear,
    input wire I_valid, I_start, I_final, I_hit,
    input wire [2:0] I_pixels,
    input wire [X_BITS-1:0] I_xmin, I_xmax,
    input wire [Y_BITS-1:0] I_y,
    input wire [9:0] I_id,
    output reg O_ready,
    output reg [3:0] O_valid, O_hold,
    output reg [191:0] O_boxes,
    output reg [9:0] O_frame_id,
    output reg O_overflow
);
    localparam [1:0] TOK_RUN = 0, TOK_END = 1, TOK_OVERFLOW = 2, TOK_ABORT = 3;
    localparam integer TOKEN_BITS = 2+10+3*X_BITS+Y_BITS+1;
    localparam integer CAND_BITS = 6*X_BITS+2*Y_BITS+COUNT_BITS+1;
    localparam integer MATCH_X = IMG_WIDTH/8 > 8 ? IMG_WIDTH/8 : 8;
    localparam integer MATCH_Y = IMG_HEIGHT/8 > 8 ? IMG_HEIGHT/8 : 8;
    localparam [4:0] S_FETCH=0, S_TOKEN=1, S_DISPATCH=2,
        S_SCAN_REQ=3, S_SCAN=4, S_COMMIT=5, S_EOF_REQ=6, S_EOF=7,
        S_TOP_SCAN=8, S_TOP_WRITE=9, S_TRACK_INIT=10, S_TRACK_SCAN=11,
        S_TRACK_APPLY=12, S_MISS=13, S_NEW=14, S_PUBLISH=15,
        S_SCAN_LOAD=16, S_EOF_LOAD=17;

    reg source_open, source_drop, run_open, pending_end;
    reg [9:0] source_id, pending_end_id;
    reg [1:0] pending_end_kind;
    reg [X_BITS-1:0] run_xmin, run_xmax;
    reg [Y_BITS-1:0] run_y;
    reg [X_BITS:0] run_pixels;
    reg source_open_n, source_drop_n, run_open_n, pending_end_n;
    reg [9:0] source_id_n, pending_end_id_n;
    reg [1:0] pending_end_kind_n;
    reg [X_BITS-1:0] run_xmin_n, run_xmax_n;
    reg [Y_BITS-1:0] run_y_n;
    reg [X_BITS:0] run_pixels_n;
    reg fifo_push;
    reg [TOKEN_BITS-1:0] fifo_wdata;
    reg [5:0] fifo_wp, fifo_rp;
    reg [6:0] fifo_count;
    wire fifo_pop;
    wire [TOKEN_BITS-1:0] fifo_rdata;

    // Leave two FIFO entries for termination/error tokens. After a rejected
    // run the entire frame is invalid; no partial/global fallback is drawn.
    always @* begin
        source_open_n=source_open; source_drop_n=source_drop; source_id_n=source_id;
        run_open_n=run_open; run_xmin_n=run_xmin; run_xmax_n=run_xmax;
        run_y_n=run_y; run_pixels_n=run_pixels;
        pending_end_n=pending_end; pending_end_id_n=pending_end_id;
        pending_end_kind_n=pending_end_kind;
        fifo_push=0; fifo_wdata=0;
        if (pending_end && fifo_count < 64) begin
            fifo_push=1;
            fifo_wdata={pending_end_kind,pending_end_id,
                        {(3*X_BITS+Y_BITS+1){1'b0}}};
            pending_end_n=0;
        end
        if (I_valid) begin
            if (I_start) begin
                if (source_open && !source_drop) begin
                    if (!fifo_push && fifo_count < 64) begin
                        fifo_push=1;
                        fifo_wdata={TOK_ABORT,source_id,{(3*X_BITS+Y_BITS+1){1'b0}}};
                    end else begin
                        pending_end_n=1; pending_end_id_n=source_id;
                        pending_end_kind_n=TOK_ABORT;
                    end
                end
                source_open_n=1; source_drop_n=0; source_id_n=I_id;
                run_open_n=0;
            end
            if (source_open_n && !source_drop_n) begin
                if (run_open_n && (!I_hit || I_y != run_y_n)) begin
                    if (!fifo_push && fifo_count < 62) begin
                        fifo_push=1;
                        fifo_wdata={TOK_RUN,source_id_n,run_xmin_n,run_xmax_n,
                                    run_y_n,run_pixels_n};
                    end else begin
                        source_drop_n=1;
                        pending_end_n=1; pending_end_id_n=source_id_n;
                        pending_end_kind_n=TOK_OVERFLOW;
                    end
                    run_open_n=0;
                end
                if (I_hit && !source_drop_n) begin
                    if (run_open_n) begin
                        run_xmax_n=I_xmax;
                        run_pixels_n=run_pixels_n+I_pixels;
                    end else begin
                        run_open_n=1; run_xmin_n=I_xmin; run_xmax_n=I_xmax;
                        run_y_n=I_y; run_pixels_n=I_pixels;
                    end
                end
                if (I_final && !source_drop_n) begin
                    if (run_open_n) begin
                        if (!fifo_push && fifo_count < 62) begin
                            fifo_push=1;
                            fifo_wdata={TOK_RUN,source_id_n,run_xmin_n,run_xmax_n,
                                        run_y_n,run_pixels_n};
                            pending_end_n=1; pending_end_id_n=source_id_n;
                            pending_end_kind_n=TOK_END;
                        end else begin
                            pending_end_n=1; pending_end_id_n=source_id_n;
                            pending_end_kind_n=TOK_OVERFLOW;
                        end
                    end else if (!fifo_push && fifo_count < 64) begin
                        fifo_push=1;
                        fifo_wdata={TOK_END,source_id_n,{(3*X_BITS+Y_BITS+1){1'b0}}};
                    end else begin
                        pending_end_n=1; pending_end_id_n=source_id_n;
                        pending_end_kind_n=TOK_END;
                    end
                    run_open_n=0;
                end
            end
            if (I_final) begin
                source_open_n=0; run_open_n=0;
            end
        end
    end
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            source_open<=0; source_drop<=0; source_id<=0; run_open<=0;
            run_xmin<=0; run_xmax<=0; run_y<=0; run_pixels<=0;
            pending_end<=0; pending_end_id<=0; pending_end_kind<=TOK_END;
            fifo_wp<=0; fifo_rp<=0; fifo_count<=0;
        end else if (I_clear) begin
            source_open<=0; source_drop<=0; run_open<=0; pending_end<=0;
            fifo_wp<=0; fifo_rp<=0; fifo_count<=0;
        end else begin
            source_open<=source_open_n; source_drop<=source_drop_n; source_id<=source_id_n;
            run_open<=run_open_n; run_xmin<=run_xmin_n; run_xmax<=run_xmax_n;
            run_y<=run_y_n; run_pixels<=run_pixels_n;
            pending_end<=pending_end_n; pending_end_id<=pending_end_id_n;
            pending_end_kind<=pending_end_kind_n;
            if (fifo_push) fifo_wp<=fifo_wp+1'b1;
            if (fifo_pop) fifo_rp<=fifo_rp+1'b1;
            case ({fifo_push,fifo_pop})
                2'b10: fifo_count<=fifo_count+1'b1;
                2'b01: fifo_count<=fifo_count-1'b1;
                default: fifo_count<=fifo_count;
            endcase
        end
    end
    red_multi_small_ram #(.WIDTH(TOKEN_BITS), .DEPTH(64), .ADDR_BITS(6)) u_fifo (
        .I_clk(I_clk), .I_write(fifo_push && I_rst_n && !I_clear),
        .I_waddr(fifo_wp), .I_data(fifo_wdata),
        .I_read(fifo_pop), .I_raddr(fifo_rp), .O_data(fifo_rdata)
    );

    reg [4:0] state, return_state;
    reg context_open, context_bad;
    reg [9:0] context_id;
    reg [TOKEN_BITS-1:0] token;
    wire [1:0] token_kind;
    wire [9:0] token_id;
    wire [X_BITS-1:0] token_xmin, token_xmax;
    wire [Y_BITS-1:0] token_y;
    wire [X_BITS:0] token_pixels;
    assign {token_kind,token_id,token_xmin,token_xmax,token_y,token_pixels}=token;
    assign fifo_pop=(state == S_FETCH) && fifo_count != 0 && I_rst_n && !I_clear;

    reg [15:0] candidate_valid;
    reg [3:0] scan_index, match_slot, free_slot;
    reg match_slot_valid, free_slot_valid;
    reg [X_BITS-1:0] work_xmin, work_xmax, work_prev_min, work_prev_max;
    reg [X_BITS-1:0] work_row_min, work_row_max;
    reg [Y_BITS-1:0] work_ymin, work_ymax;
    reg [COUNT_BITS-1:0] work_pixels;
    reg work_prev_valid;
    wire [CAND_BITS-1:0] candidate_data;
    reg [CAND_BITS-1:0] candidate_stage;
    reg candidate_expired, same_row, link_valid, candidate_qualified;
    reg [X_BITS-1:0] link_min, link_max;
    wire [X_BITS-1:0] read_xmin, read_xmax, read_prev_min, read_prev_max;
    wire [X_BITS-1:0] read_row_min, read_row_max;
    wire [Y_BITS-1:0] read_ymin, read_ymax;
    wire [COUNT_BITS-1:0] read_pixels;
    wire read_prev_valid;
    assign {read_xmin,read_xmax,read_ymin,read_ymax,read_pixels,
            read_prev_valid,read_prev_min,read_prev_max,read_row_min,read_row_max}
        =candidate_data;
    wire read_same_row=(token_y == read_ymax);
    wire read_adjacent_row=({1'b0,token_y} == {1'b0,read_ymax}+1'b1);
    wire [X_BITS-1:0] cand_xmin, cand_xmax, cand_prev_min, cand_prev_max;
    wire [X_BITS-1:0] cand_row_min, cand_row_max;
    wire [Y_BITS-1:0] cand_ymin, cand_ymax;
    wire [COUNT_BITS-1:0] cand_pixels;
    wire cand_prev_valid;
    assign {cand_xmin,cand_xmax,cand_ymin,cand_ymax,cand_pixels,
            cand_prev_valid,cand_prev_min,cand_prev_max,cand_row_min,cand_row_max}
        =candidate_stage;
    wire candidate_matches=link_valid &&
        ({1'b0,token_xmin} <= {1'b0,link_max}+1'b1) &&
        ({1'b0,link_min} <= {1'b0,token_xmax}+1'b1);
    wire commit_ok=match_slot_valid || free_slot_valid;
    wire [3:0] commit_slot=match_slot_valid ? match_slot : free_slot;
    wire candidate_write=state == S_COMMIT && commit_ok && I_rst_n && !I_clear;
    wire candidate_read=(state == S_SCAN_REQ || state == S_EOF_REQ ||
        ((state == S_SCAN || state == S_EOF) && scan_index != 15)) && I_rst_n && !I_clear;
    wire [3:0] candidate_raddr=(state == S_SCAN_REQ || state == S_EOF_REQ) ?
        4'd0 : scan_index+1'b1;
    red_multi_small_ram #(.WIDTH(CAND_BITS), .DEPTH(16), .ADDR_BITS(4)) u_candidates (
        .I_clk(I_clk), .I_write(candidate_write), .I_waddr(commit_slot),
        .I_data({work_xmin,work_xmax,work_ymin,work_ymax,work_pixels,
                 work_prev_valid,work_prev_min,work_prev_max,work_row_min,work_row_max}),
        .I_read(candidate_read), .I_raddr(candidate_raddr), .O_data(candidate_data)
    );

    reg [3:0] top_valid;
    reg [X_BITS-1:0] top_xmin [0:3], top_xmax [0:3];
    reg [Y_BITS-1:0] top_ymin [0:3], top_ymax [0:3];
    reg [COUNT_BITS-1:0] top_pixels [0:3];
    reg [X_BITS-1:0] retired_xmin, retired_xmax;
    reg [Y_BITS-1:0] retired_ymin, retired_ymax;
    reg [COUNT_BITS-1:0] retired_pixels, minimum_pixels;
    reg [1:0] top_index, minimum_slot;
    reg minimum_empty;

    reg [3:0] track_occupied, track_confirmed, matched_tracks, used_detections;
    reg [X_BITS-1:0] track_xmin [0:3], track_xmax [0:3];
    reg [Y_BITS-1:0] track_ymin [0:3], track_ymax [0:3];
    reg [1:0] track_misses [0:3];
    reg [3:0] pair_index;
    reg [1:0] best_track, best_detection, track_index;
    reg best_valid;
    reg [13:0] best_distance;
    wire [1:0] pair_track=pair_index[3:2];
    wire [1:0] pair_detection=pair_index[1:0];
    wire [X_BITS:0] track_xsum={1'b0,track_xmin[pair_track]}+{1'b0,track_xmax[pair_track]};
    wire [X_BITS:0] top_xsum={1'b0,top_xmin[pair_detection]}+{1'b0,top_xmax[pair_detection]};
    wire [Y_BITS:0] track_ysum={1'b0,track_ymin[pair_track]}+{1'b0,track_ymax[pair_track]};
    wire [Y_BITS:0] top_ysum={1'b0,top_ymin[pair_detection]}+{1'b0,top_ymax[pair_detection]};
    wire [X_BITS:0] delta_x=track_xsum >= top_xsum ? track_xsum-top_xsum : top_xsum-track_xsum;
    wire [Y_BITS:0] delta_y=track_ysum >= top_ysum ? track_ysum-top_ysum : top_ysum-track_ysum;
    wire [13:0] pair_distance=delta_x+delta_y;
    wire pair_eligible=track_occupied[pair_track] && !matched_tracks[pair_track] &&
        top_valid[pair_detection] && !used_detections[pair_detection] &&
        delta_x <= 2*MATCH_X && delta_y <= 2*MATCH_Y;
    wire empty_track_exists=!(&track_occupied);
    wire [1:0] empty_track=!track_occupied[0] ? 0 :
        !track_occupied[1] ? 1 : !track_occupied[2] ? 2 : 3;
    integer slot;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            state<=S_FETCH; return_state<=S_FETCH; context_open<=0; context_bad<=0;
            context_id<=0; token<=0; candidate_valid<=0; scan_index<=0;
            match_slot<=0; free_slot<=0; match_slot_valid<=0; free_slot_valid<=0;
            work_xmin<=0; work_xmax<=0; work_ymin<=0; work_ymax<=0;
            work_pixels<=0; work_prev_valid<=0; work_prev_min<=0; work_prev_max<=0;
            work_row_min<=0; work_row_max<=0;
            candidate_stage<=0; candidate_expired<=0; same_row<=0;
            link_valid<=0; link_min<=0; link_max<=0; candidate_qualified<=0;
            top_valid<=0; retired_xmin<=0; retired_xmax<=0;
            retired_ymin<=0; retired_ymax<=0; retired_pixels<=0;
            minimum_pixels<=0; minimum_slot<=0; minimum_empty<=0; top_index<=0;
            track_occupied<=0; track_confirmed<=0; matched_tracks<=0; used_detections<=0;
            pair_index<=0; best_track<=0; best_detection<=0; track_index<=0;
            best_valid<=0; best_distance<=0;
            O_ready<=0; O_valid<=0; O_hold<=0; O_boxes<=0; O_frame_id<=0; O_overflow<=0;
            for (slot=0; slot<4; slot=slot+1) begin
                top_xmin[slot]<=0; top_xmax[slot]<=0; top_ymin[slot]<=0;
                top_ymax[slot]<=0; top_pixels[slot]<=0;
                track_xmin[slot]<=0; track_xmax[slot]<=0;
                track_ymin[slot]<=0; track_ymax[slot]<=0; track_misses[slot]<=0;
            end
        end else if (I_clear) begin
            state<=S_FETCH; context_open<=0; context_bad<=0; candidate_valid<=0;
            top_valid<=0; track_occupied<=0; track_confirmed<=0;
            matched_tracks<=0; used_detections<=0;
            O_ready<=0; O_valid<=0; O_hold<=0; O_boxes<=0; O_overflow<=0;
        end else begin
            O_ready<=0;
            case (state)
                S_FETCH: if (fifo_pop) state<=S_TOKEN;
                S_TOKEN: begin
                    token<=fifo_rdata;
                    if (!context_open) begin
                        context_open<=1; context_id<=fifo_rdata[TOKEN_BITS-3-:10];
                        context_bad<=0; candidate_valid<=0; top_valid<=0;
                    end
                    state<=S_DISPATCH;
                end
                S_DISPATCH: begin
                    if (token_id != context_id) begin
                        // A malformed sequence is never allowed to combine frames.
                        context_bad<=1;
                        if (token_kind == TOK_RUN) state<=S_FETCH;
                        else begin
                            O_ready<=1; O_frame_id<=token_id; O_overflow<=1;
                            O_valid<=0; O_hold<=0; O_boxes<=0;
                            track_occupied<=0; track_confirmed<=0;
                            context_open<=0; candidate_valid<=0; state<=S_FETCH;
                        end
                    end else if (token_kind == TOK_RUN) begin
                        if (context_bad) state<=S_FETCH;
                        else begin
                            work_xmin<=token_xmin; work_xmax<=token_xmax;
                            work_ymin<=token_y; work_ymax<=token_y;
                            work_pixels<=token_pixels; work_prev_valid<=0;
                            work_prev_min<=0; work_prev_max<=0;
                            work_row_min<=token_xmin; work_row_max<=token_xmax;
                            match_slot_valid<=0; free_slot_valid<=0;
                            scan_index<=0; state<=S_SCAN_REQ;
                        end
                    end else if (token_kind != TOK_END || context_bad) begin
                        O_ready<=1; O_frame_id<=context_id;
                        O_overflow<=context_bad || token_kind == TOK_OVERFLOW;
                        O_valid<=0; O_hold<=0; O_boxes<=0;
                        track_occupied<=0; track_confirmed<=0;
                        context_open<=0; candidate_valid<=0; state<=S_FETCH;
                    end else begin
                        scan_index<=0; state<=S_EOF_REQ;
                    end
                end
                S_SCAN_REQ: state<=S_SCAN_LOAD;
                S_SCAN_LOAD, S_EOF_LOAD: begin
                    // Separate the RAM row selection from overlap and merge.
                    candidate_stage<=candidate_data;
                    candidate_expired<=({1'b0,token_y} > {1'b0,read_ymax}+1'b1);
                    same_row<=read_same_row;
                    link_valid<=read_same_row ? read_prev_valid : read_adjacent_row;
                    link_min<=read_same_row ? read_prev_min : read_row_min;
                    link_max<=read_same_row ? read_prev_max : read_row_max;
                    candidate_qualified<=read_pixels >= MIN_PIXELS &&
                        ({1'b0,read_xmax}-{1'b0,read_xmin}+1'b1 >= MIN_WIDTH) &&
                        ({1'b0,read_ymax}-{1'b0,read_ymin}+1'b1 >= MIN_HEIGHT);
                    state<=state == S_SCAN_LOAD ? S_SCAN : S_EOF;
                end
                S_SCAN: begin
                    scan_index<=scan_index+1'b1;
                    state<=scan_index == 15 ? S_COMMIT : S_SCAN_LOAD;
                    if (!candidate_valid[scan_index]) begin
                        if (!free_slot_valid) begin free_slot_valid<=1; free_slot<=scan_index; end
                    end else if (candidate_expired) begin
                        candidate_valid[scan_index]<=0;
                        if (!free_slot_valid) begin free_slot_valid<=1; free_slot<=scan_index; end
                        if (candidate_qualified) begin
                            retired_xmin<=cand_xmin; retired_xmax<=cand_xmax;
                            retired_ymin<=cand_ymin; retired_ymax<=cand_ymax;
                            retired_pixels<=cand_pixels; top_index<=0;
                            minimum_empty<=0; minimum_pixels<={COUNT_BITS{1'b1}};
                            return_state<=scan_index == 15 ? S_COMMIT : S_SCAN_LOAD;
                            state<=S_TOP_SCAN;
                        end
                    end else if (candidate_matches) begin
                        candidate_valid[scan_index]<=0;
                        if (!match_slot_valid) begin match_slot_valid<=1; match_slot<=scan_index; end
                        if (cand_xmin < work_xmin) work_xmin<=cand_xmin;
                        if (cand_xmax > work_xmax) work_xmax<=cand_xmax;
                        if (cand_ymin < work_ymin) work_ymin<=cand_ymin;
                        work_pixels<=work_pixels+cand_pixels;
                        if (!work_prev_valid || link_min < work_prev_min) work_prev_min<=link_min;
                        if (!work_prev_valid || link_max > work_prev_max) work_prev_max<=link_max;
                        work_prev_valid<=1;
                        if (same_row) begin
                            if (cand_row_min < work_row_min) work_row_min<=cand_row_min;
                            if (cand_row_max > work_row_max) work_row_max<=cand_row_max;
                        end
                    end
                end
                S_COMMIT: begin
                    if (commit_ok) candidate_valid[commit_slot]<=1;
                    else context_bad<=1;
                    state<=S_FETCH;
                end
                S_EOF_REQ: state<=S_EOF_LOAD;
                S_EOF: begin
                    candidate_valid[scan_index]<=0; scan_index<=scan_index+1'b1;
                    state<=scan_index == 15 ? S_TRACK_INIT : S_EOF_LOAD;
                    if (candidate_valid[scan_index] && candidate_qualified) begin
                        retired_xmin<=cand_xmin; retired_xmax<=cand_xmax;
                        retired_ymin<=cand_ymin; retired_ymax<=cand_ymax;
                        retired_pixels<=cand_pixels; top_index<=0;
                        minimum_empty<=0; minimum_pixels<={COUNT_BITS{1'b1}};
                        return_state<=scan_index == 15 ? S_TRACK_INIT : S_EOF_LOAD;
                        state<=S_TOP_SCAN;
                    end
                end
                S_TOP_SCAN: begin
                    if (!top_valid[top_index]) begin
                        if (!minimum_empty) minimum_slot<=top_index;
                        minimum_empty<=1;
                    end else if (!minimum_empty && top_pixels[top_index] <= minimum_pixels) begin
                        minimum_pixels<=top_pixels[top_index]; minimum_slot<=top_index;
                    end
                    if (top_index == 3) state<=S_TOP_WRITE;
                    else top_index<=top_index+1'b1;
                end
                S_TOP_WRITE: begin
                    if (minimum_empty || retired_pixels > minimum_pixels) begin
                        top_valid[minimum_slot]<=1; top_pixels[minimum_slot]<=retired_pixels;
                        top_xmin[minimum_slot]<=retired_xmin; top_xmax[minimum_slot]<=retired_xmax;
                        top_ymin[minimum_slot]<=retired_ymin; top_ymax[minimum_slot]<=retired_ymax;
                    end
                    state<=return_state;
                end
                S_TRACK_INIT: begin
                    matched_tracks<=0; used_detections<=0; pair_index<=0;
                    best_valid<=0; best_distance<=14'h3fff;
                    state<=S_TRACK_SCAN;
                end
                S_TRACK_SCAN: begin
                    if (pair_eligible && (!best_valid || pair_distance < best_distance)) begin
                        best_valid<=1; best_distance<=pair_distance;
                        best_track<=pair_track; best_detection<=pair_detection;
                    end
                    if (pair_index == 15) state<=S_TRACK_APPLY;
                    else pair_index<=pair_index+1'b1;
                end
                S_TRACK_APPLY: begin
                    if (best_valid) begin
                        matched_tracks[best_track]<=1; used_detections[best_detection]<=1;
                        track_confirmed[best_track]<=1; track_misses[best_track]<=0;
                        track_xmin[best_track]<=top_xmin[best_detection];
                        track_xmax[best_track]<=top_xmax[best_detection];
                        track_ymin[best_track]<=top_ymin[best_detection];
                        track_ymax[best_track]<=top_ymax[best_detection];
                        best_valid<=0; best_distance<=14'h3fff; pair_index<=0;
                        state<=S_TRACK_SCAN;
                    end else begin track_index<=0; state<=S_MISS; end
                end
                S_MISS: begin
                    if (track_occupied[track_index] && !matched_tracks[track_index]) begin
                        if (!track_confirmed[track_index] || track_misses[track_index] == 2) begin
                            track_occupied[track_index]<=0; track_confirmed[track_index]<=0;
                        end else track_misses[track_index]<=track_misses[track_index]+1'b1;
                    end
                    if (track_index == 3) begin track_index<=0; state<=S_NEW; end
                    else track_index<=track_index+1'b1;
                end
                S_NEW: begin
                    if (top_valid[track_index] && !used_detections[track_index] && empty_track_exists) begin
                        track_occupied[empty_track]<=1; track_confirmed[empty_track]<=0;
                        track_misses[empty_track]<=0;
                        track_xmin[empty_track]<=top_xmin[track_index];
                        track_xmax[empty_track]<=top_xmax[track_index];
                        track_ymin[empty_track]<=top_ymin[track_index];
                        track_ymax[empty_track]<=top_ymax[track_index];
                    end
                    if (track_index == 3) state<=S_PUBLISH;
                    else track_index<=track_index+1'b1;
                end
                S_PUBLISH: begin
                    O_ready<=1; O_frame_id<=context_id; O_overflow<=0;
                    O_valid<=track_occupied & track_confirmed;
                    for (slot=0; slot<4; slot=slot+1) begin
                        O_hold[slot]<=track_occupied[slot] && track_confirmed[slot] && track_misses[slot] != 0;
                        O_boxes[slot*48+:48]<={{(12-Y_BITS){1'b0}},track_ymax[slot],
                            {(12-Y_BITS){1'b0}},track_ymin[slot],
                            {(12-X_BITS){1'b0}},track_xmax[slot],
                            {(12-X_BITS){1'b0}},track_xmin[slot]};
                    end
                    context_open<=0; state<=S_FETCH;
                end
                default: begin state<=S_FETCH; context_open<=0; track_occupied<=0; end
            endcase
        end
    end
endmodule

// Wide, shallow tables use ERAM rather than thousands of resettable flip-flops.
// The portable branch has exactly the same one-clock synchronous read latency.
module red_multi_small_ram #(
    parameter integer WIDTH = 32,
    parameter integer DEPTH = 64,
    parameter integer ADDR_BITS = 6
) (
    input wire I_clk, I_write, I_read,
    input wire [ADDR_BITS-1:0] I_waddr, I_raddr,
    input wire [WIDTH-1:0] I_data,
    output wire [WIDTH-1:0] O_data
);
`ifdef RED_MULTI_PORTABLE_RAM
    localparam integer PORTABLE = 1;
`elsif SCHARR_PORTABLE_RAM
    localparam integer PORTABLE = 1;
`else
    localparam integer PORTABLE = 0;
`endif
    localparam integer BANKS = (WIDTH+31)/32;
    generate
        if (PORTABLE) begin : gen_portable
            reg [WIDTH-1:0] memory [0:DEPTH-1];
            reg [WIDTH-1:0] read_data;
            always @(posedge I_clk) begin
                if (I_write) memory[I_waddr]<=I_data;
                if (I_read) read_data<=memory[I_raddr];
            end
            assign O_data=read_data;
        end else begin : gen_eram
            wire [BANKS*32-1:0] padded_input={{(BANKS*32-WIDTH){1'b0}},I_data};
            wire [BANKS*32-1:0] padded_output;
            genvar bank;
            for (bank=0; bank<BANKS; bank=bank+1) begin : gen_bank
                PH1P_LOGIC_ERAM #(
                    .DATA_WIDTH_A(32), .DATA_WIDTH_B(32),
                    .ADDR_WIDTH_A(ADDR_BITS), .ADDR_WIDTH_B(ADDR_BITS),
                    .DATA_DEPTH_A(DEPTH), .DATA_DEPTH_B(DEPTH), .MODE("DP"),
                    .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
                    .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
                    .IMPLEMENT("20K(FAST)"), .CLKMODE("SYNC"),
                    .ECC_ENCODE("DISABLE"), .ECC_DECODE("DISABLE"),
                    .INIT_FILE("NONE"), .FILL_ALL("NONE")
                ) u_ram (
                    .clka(I_clk), .clkb(I_clk), .cea(I_write), .ceb(I_read),
                    .ocea(1'b0), .oceb(1'b0), .wea(I_write), .web(1'b0),
                    .rsta(1'b0), .rstb(1'b0), .bea(1'b0), .beb(1'b0),
                    .addra(I_waddr), .addrb(I_raddr), .dia(padded_input[bank*32+:32]),
                    .dib(32'd0), .doa(), .dob(padded_output[bank*32+:32]),
                    .ecc_sbiterr(), .ecc_dbiterr(),
                    .ecc_sbiterrinj(1'b0), .ecc_dbiterrinj(1'b0)
                );
            end
            assign O_data=padded_output[WIDTH-1:0];
        end
    endgenerate
endmodule
