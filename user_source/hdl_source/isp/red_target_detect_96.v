// Four-pixel-per-clock selected-color detector, before the display selector.
// Majority denoising followed by 3x3 closing repairs small color-mask holes.
// The first window shares its taps with the K1 mask previews. No RGB rows
// or complete image are stored. Results include the final input beat.
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
    input wire [1:0] I_color_mode,
    input wire [3:0] I_mask_view_mode,
    output wire [3:0] O_mask_pixels,
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
    output wire [7:0] O_multi_shapes,
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
    // Red and blue use normalized chroma/hue bounds instead of a large
    // absolute channel difference. For a selected primary as the largest
    // channel these integer comparisons require:
    //   max(G,B) <= 2R/3 and |G-B| <= (R-min(G,B))/3.
    // Green objects from the camera are commonly shifted toward yellow-green
    // or cyan-green by the illuminant and AWB. Green therefore keeps the same
    // floor/delta checks but uses max(R,B) <= 4G/5 without requiring R and B
    // to be balanced around pure green. No divider or DSP is needed.
    // RED_MIN and RED_DELTA remain as a floor against dark channel noise.
    // Low-saturation pink/white and orange/purple are outside these bounds;
    // genuinely clipped pixels cannot recover their original color here.
    wire [3:0] red_mask;
    genvar p;
    generate
        for (p = 0; p < 4; p = p + 1) begin : gen_red
            wire [7:0] red_in = I_tdata[95-p*24-:8];
            wire [7:0] green_in = I_tdata[87-p*24-:8];
            wire [7:0] blue_in = I_tdata[79-p*24-:8];
            reg [7:0] dominant, secondary_a, secondary_b;
            wire [8:0] red = {1'b0,dominant};
            wire secondary_a_larger = secondary_a >= secondary_b;
            wire [7:0] secondary_max = secondary_a_larger ? secondary_a : secondary_b;
            wire [7:0] secondary_min = secondary_a_larger ? secondary_b : secondary_a;
            wire [8:0] secondary_limit;
            wire [9:0] twice_red;
            wire [9:0] triple_secondary;
            wire [9:0] hue_limit;
            wire [10:0] four_dominant;
            wire [10:0] five_secondary;
            wire delta_ok;
            wire strict_primary_mask;
            wire relaxed_green_mask;
            always @(*) begin
                case (I_color_mode)
                    2'd1: begin dominant=green_in; secondary_a=red_in; secondary_b=blue_in; end
                    2'd2: begin dominant=blue_in; secondary_a=red_in; secondary_b=green_in; end
                    default: begin dominant=red_in; secondary_a=green_in; secondary_b=blue_in; end
                endcase
            end
            // The larger secondary channel gives the stronger bounds.
            // Reuse these sums/comparisons for both secondary channels.
            assign secondary_limit = {1'b0,secondary_max} + RED_DELTA_9;
            if (RED_DELTA_9 <= 9'd256) begin : gen_monotone_delta
                assign delta_ok = red >= secondary_limit;
            end else begin : gen_legacy_wrapped_delta
                // Preserve the original nine-bit wrap for unusual parameters.
                wire [8:0] limit_a = {1'b0,secondary_a} + RED_DELTA_9;
                wire [8:0] limit_b = {1'b0,secondary_b} + RED_DELTA_9;
                assign delta_ok = red >= limit_a && red >= limit_b;
            end
            assign twice_red = {1'b0,red[7:0],1'b0};
            assign triple_secondary = {2'b0,secondary_max} + {1'b0,secondary_max,1'b0};
            assign hue_limit = {1'b0,red} + {1'b0,secondary_min,1'b0};
            assign four_dominant = {red,2'b0};
            assign five_secondary = {1'b0,secondary_max,2'b0} + {3'b0,secondary_max};
            assign strict_primary_mask =
                (red >= RED_MIN_9) &&
                delta_ok &&
                (twice_red >= triple_secondary) &&
                (triple_secondary <= hue_limit);
            assign relaxed_green_mask =
                (red >= RED_MIN_9) &&
                delta_ok &&
                (four_dominant >= five_secondary);
            assign red_mask[p] = I_color_mode == 2'd1 ?
                                 relaxed_green_mask : strict_primary_mask;
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

    // Each two-row binary history occupies one packed eight-bit ERAM.
    // Rows 0/1 refill it before any old data can contribute to the filter.
    wire [3:0] top_now, mid_now, bot_now;
    red_mask_rows_4 #(.GROUPS(IMG_WIDTH_GRP),.ADDR_BITS(GROUP_BITS)) u_mask_rows (
        .I_clk(I_clk),.I_rst_n(I_rst_n),.I_valid(accept_beat),
        .I_group(beat_group),.I_mask(red_mask),
        .O_top(top_now),.O_mid(mid_now),.O_bot(bot_now)
    );

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

    // Stage 1: binary dilation and erosion are just nine-bit OR and AND.
    // Lane 0/1 need the previous group. Bit zero is the earliest pixel.
    wire [3:0] dilated_hits, eroded_hits, majority_hits;
    genvar lane;
    generate
        for (lane = 0; lane < 4; lane = lane+1) begin : gen_mask_extrema
            wire [2:0] top_window, mid_window, bot_window;
            wire window_valid = row_d >= 2 && ((lane >= 2) || group_d != 0);
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
            assign dilated_hits[lane] = window_valid &&
                (|{top_window,mid_window,bot_window});
            assign eroded_hits[lane] = window_valid &&
                (&{top_window,mid_window,bot_window});
            assign top_votes = {1'b0,top_window[0]} + {1'b0,top_window[1]} + {1'b0,top_window[2]};
            assign mid_votes = {1'b0,mid_window[0]} + {1'b0,mid_window[1]} + {1'b0,mid_window[2]};
            assign bot_votes = {1'b0,bot_window[0]} + {1'b0,bot_window[1]} + {1'b0,bot_window[2]};
            assign votes = {2'd0,top_votes} + {2'd0,mid_votes} + {2'd0,bot_votes};
            assign majority_hits[lane] = window_valid && votes >= 5;
        end
    endgenerate

    reg [3:0] view_d, view_h, view_cd;
    reg [3:0] preview_h, preview_hd;
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
            view_d <= 0; view_h <= 0; preview_h <= 0;
        end else begin
            view_d <= I_mask_view_mode;
            view_h <= view_d;
            valid_h <= valid_d;
            start_h <= start_d;
            final_h <= final_d;
            case (view_d)
                4'd10: preview_h <= valid_d ? eroded_hits : 4'd0;
                4'd11: preview_h <= valid_d ? dilated_hits : 4'd0;
                default: preview_h <= valid_d ? bot_now : 4'd0;
            endcase
            if (valid_d) begin
                hits_h <= majority_hits;
                group_h <= group_d;
                row_h <= row_d;
            end
        end
    end

    // The next two one-bit rows dilate the denoised mask. Geometry and frame
    // markers advance with valid beats; the display delay advances on bubbles.
    wire [3:0] close_top, close_mid, close_bot;
    red_mask_rows_4 #(.GROUPS(IMG_WIDTH_GRP),.ADDR_BITS(GROUP_BITS)) u_close_rows (
        .I_clk(I_clk),.I_rst_n(I_rst_n),.I_valid(valid_h),
        .I_group(group_h),.I_mask(hits_h),
        .O_top(close_top),.O_mid(close_mid),.O_bot(close_bot)
    );
    reg valid_cd, start_cd, final_cd, valid_c, start_c, final_c;
    reg [GROUP_BITS-1:0] group_cd, group_c;
    reg [Y_BITS-1:0] row_cd, row_c;
    reg close_top_prev2, close_top_prev1, close_mid_prev2, close_mid_prev1;
    reg close_bot_prev2, close_bot_prev1;
    wire [3:0] close_dilated_hits;
    reg [3:0] hits_c;
    generate
        for (lane = 0; lane < 4; lane = lane+1) begin : gen_close
            wire [2:0] top_window, mid_window, bot_window;
            if (lane == 0) begin
                assign top_window = {close_top_prev2,close_top_prev1,close_top[0]};
                assign mid_window = {close_mid_prev2,close_mid_prev1,close_mid[0]};
                assign bot_window = {close_bot_prev2,close_bot_prev1,close_bot[0]};
            end else if (lane == 1) begin
                assign top_window = {close_top_prev1,close_top[0],close_top[1]};
                assign mid_window = {close_mid_prev1,close_mid[0],close_mid[1]};
                assign bot_window = {close_bot_prev1,close_bot[0],close_bot[1]};
            end else if (lane == 2) begin
                assign top_window = close_top[2:0];
                assign mid_window = close_mid[2:0];
                assign bot_window = close_bot[2:0];
            end else begin
                assign top_window = close_top[3:1];
                assign mid_window = close_mid[3:1];
                assign bot_window = close_bot[3:1];
            end
            assign close_dilated_hits[lane] = row_cd >= 4 && group_cd != 0 &&
                (|{top_window,mid_window,bot_window});
        end
    endgenerate
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            valid_cd<=0; start_cd<=0; final_cd<=0;
            valid_c<=0; start_c<=0; final_c<=0;
            group_cd<=0; row_cd<=0; group_c<=0; row_c<=0; hits_c<=0;
            {close_top_prev2,close_top_prev1,close_mid_prev2,close_mid_prev1,
             close_bot_prev2,close_bot_prev1}<=0;
            view_cd<=0; preview_hd<=0;
        end else begin
            valid_cd<=valid_h; start_cd<=start_h; final_cd<=final_h;
            valid_c<=valid_cd; start_c<=start_cd; final_c<=final_cd;
            view_cd<=view_h; preview_hd<=preview_h;
            if (valid_h) begin group_cd<=group_h; row_cd<=row_h; end
            if (valid_cd) begin
                hits_c<=close_dilated_hits; group_c<=group_cd; row_c<=row_cd;
                close_top_prev2<=close_top[2]; close_top_prev1<=close_top[3];
                close_mid_prev2<=close_mid[2]; close_mid_prev1<=close_mid[3];
                close_bot_prev2<=close_bot[2]; close_bot_prev1<=close_bot[3];
            end
        end
    end
    // One final AND window completes the closing. The original majority
    // stage remains necessary: it removes isolated diagonal tips and specks
    // that are not reliable scanline contours, before filling small holes.
    wire [3:0] erode_top, erode_mid, erode_bot;
    red_mask_rows_4 #(.GROUPS(IMG_WIDTH_GRP),.ADDR_BITS(GROUP_BITS)) u_erode_rows (
        .I_clk(I_clk),.I_rst_n(I_rst_n),.I_valid(valid_c),
        .I_group(group_c),.I_mask(hits_c),
        .O_top(erode_top),.O_mid(erode_mid),.O_bot(erode_bot)
    );
    reg valid_fd, start_fd, final_fd, valid_f, start_f, final_f;
    reg [GROUP_BITS-1:0] group_fd, group_f;
    reg [Y_BITS-1:0] row_fd, row_f;
    reg erode_top_prev2, erode_top_prev1, erode_mid_prev2, erode_mid_prev1;
    reg erode_bot_prev2, erode_bot_prev1;
    wire [3:0] closed_hits;
    reg [3:0] hits_f, view_c, view_fd, preview_hc, preview_hf;
    generate
        for (lane=0;lane<4;lane=lane+1) begin : gen_close_erode
            wire [2:0] top_window, mid_window, bot_window;
            if (lane == 0) begin
                assign top_window={erode_top_prev2,erode_top_prev1,erode_top[0]};
                assign mid_window={erode_mid_prev2,erode_mid_prev1,erode_mid[0]};
                assign bot_window={erode_bot_prev2,erode_bot_prev1,erode_bot[0]};
            end else if (lane == 1) begin
                assign top_window={erode_top_prev1,erode_top[0],erode_top[1]};
                assign mid_window={erode_mid_prev1,erode_mid[0],erode_mid[1]};
                assign bot_window={erode_bot_prev1,erode_bot[0],erode_bot[1]};
            end else if (lane == 2) begin
                assign top_window=erode_top[2:0];
                assign mid_window=erode_mid[2:0];
                assign bot_window=erode_bot[2:0];
            end else begin
                assign top_window=erode_top[3:1];
                assign mid_window=erode_mid[3:1];
                assign bot_window=erode_bot[3:1];
            end
            assign closed_hits[lane]=row_fd >= 6 && group_fd != 0 &&
                ((lane >= 2) || group_fd != 1) &&
                (&{top_window,mid_window,bot_window});
        end
    endgenerate
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            valid_fd<=0; start_fd<=0; final_fd<=0;
            valid_f<=0; start_f<=0; final_f<=0;
            group_fd<=0; row_fd<=0; group_f<=0; row_f<=0; hits_f<=0;
            {erode_top_prev2,erode_top_prev1,erode_mid_prev2,erode_mid_prev1,
             erode_bot_prev2,erode_bot_prev1}<=0;
            view_c<=0; view_fd<=0; preview_hc<=0; preview_hf<=0;
        end else begin
            valid_fd<=valid_c; start_fd<=start_c; final_fd<=final_c;
            valid_f<=valid_fd; start_f<=start_fd; final_f<=final_fd;
            view_c<=view_cd; view_fd<=view_c;
            preview_hc<=preview_hd; preview_hf<=preview_hc;
            if (valid_c) begin group_fd<=group_c; row_fd<=row_c; end
            if (valid_fd) begin
                hits_f<=closed_hits; group_f<=group_fd; row_f<=row_fd;
                erode_top_prev2<=erode_top[2]; erode_top_prev1<=erode_top[3];
                erode_mid_prev2<=erode_mid[2]; erode_mid_prev1<=erode_mid[3];
                erode_bot_prev2<=erode_bot[2]; erode_bot_prev1<=erode_bot[3];
            end
        end
    end
    // Expand to RGB only in the existing final display selector. Keeping
    // these delays four bits wide avoids eleven copies of 96-bit pixels.
    reg [3:0] mask_preview_pipe [0:5];
    integer preview_stage;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            for (preview_stage=0;preview_stage<6;preview_stage=preview_stage+1)
                mask_preview_pipe[preview_stage]<=0;
        end else begin
            mask_preview_pipe[0]<=view_fd == 4'd12 ?
                (valid_fd ? closed_hits : 4'd0) : preview_hf;
            for (preview_stage=1;preview_stage<6;preview_stage=preview_stage+1)
                mask_preview_pipe[preview_stage]<=mask_preview_pipe[preview_stage-1];
        end
    end
    assign O_mask_pixels=mask_preview_pipe[5];

    // One priority encoder per extremum and a balanced popcount. The three
    // centered windows refer to source x=4*group+lane-3, y=row-3.
    wire [GROUP_BITS-1:0] previous_group = group_f-1'b1;
    wire [X_BITS-1:0] lane_x0 = {previous_group,2'b01};
    wire [X_BITS-1:0] lane_x1 = {previous_group,2'b10};
    wire [X_BITS-1:0] lane_x2 = {previous_group,2'b11};
    wire [X_BITS-1:0] lane_x3 = {group_f,2'b00};
    wire [1:0] hits_low = {1'b0,hits_f[0]} + {1'b0,hits_f[1]};
    wire [1:0] hits_high = {1'b0,hits_f[2]} + {1'b0,hits_f[3]};
    wire [2:0] beat_popcount = {1'b0,hits_low} + {1'b0,hits_high};
    wire [X_BITS-1:0] first_x = hits_f[0] ? lane_x0 :
                              hits_f[1] ? lane_x1 :
                              hits_f[2] ? lane_x2 : lane_x3;
    wire [X_BITS-1:0] last_x = hits_f[3] ? lane_x3 :
                             hits_f[2] ? lane_x2 :
                             hits_f[1] ? lane_x1 : lane_x0;
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
            valid_b <= valid_f;
            start_b <= start_f;
            final_b <= final_f;
            if (valid_f) begin
                hit_b <= |hits_f;
                popcount_b <= beat_popcount;
                xmin_b <= first_x;
                xmax_b <= last_x;
                y_b <= row_f-2'd3;
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

    // Publication is nine clocks after acceptance of the last input
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
            reg [9:0] pending_id, active_id, id_d, id_h, id_cd, id_c, id_fd, id_f, id_b;
            wire [9:0] accepted_id = start_frame ?
                (I_tuser ? I_frame_id : pending_id) : active_id;
            always @(posedge I_clk or negedge I_rst_n) begin
                if (!I_rst_n) begin
                    pending_id <= 0; active_id <= 0;
                    id_d <= 0; id_h <= 0; id_cd <= 0; id_c <= 0;
                    id_fd <= 0; id_f <= 0; id_b <= 0;
                end else begin
                    if (I_tuser) pending_id <= I_frame_id;
                    if (accept_beat) begin
                        id_d <= accepted_id;
                        if (start_frame) active_id <= accepted_id;
                    end
                    if (valid_d) id_h <= id_d;
                    if (valid_h) id_cd <= id_h;
                    if (valid_cd) id_c <= id_cd;
                    if (valid_c) id_fd <= id_c;
                    if (valid_fd) id_f <= id_fd;
                    if (valid_f) id_b <= id_f;
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
                .O_boxes(O_multi_boxes), .O_shapes(O_multi_shapes), .O_frame_id(O_multi_frame_id),
                .O_overflow(O_multi_overflow)
            );
        end else begin : gen_single_only
            assign O_multi_ready = 1'b0;
            assign O_multi_valid = 4'b0;
            assign O_multi_hold = 4'b0;
            assign O_multi_boxes = 192'b0;
            assign O_multi_shapes = 8'b0;
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
    output reg [7:0] O_shapes,
    output reg [9:0] O_frame_id,
    output reg O_overflow
);
    localparam [1:0] TOK_RUN = 0, TOK_END = 1, TOK_OVERFLOW = 2, TOK_ABORT = 3;
    localparam integer TOKEN_BITS = 2+10+3*X_BITS+Y_BITS+1;
    localparam integer COORD_BITS = (X_BITS > Y_BITS ? X_BITS : Y_BITS)+1;
    localparam integer MOM_BITS = COUNT_BITS+COORD_BITS;
    localparam integer FEATURE_BITS = 17+2*MOM_BITS+4*COORD_BITS;
    localparam integer CAND_BITS = 6*X_BITS+2*Y_BITS+COUNT_BITS+1+FEATURE_BITS;
    localparam integer MATCH_X = IMG_WIDTH/8 > 8 ? IMG_WIDTH/8 : 8;
    localparam integer MATCH_Y = IMG_HEIGHT/8 > 8 ? IMG_HEIGHT/8 : 8;
    localparam [4:0] S_FETCH=0, S_TOKEN=1, S_DISPATCH=2,
        S_SCAN_REQ=3, S_SCAN=4, S_COMMIT=5, S_EOF_REQ=6, S_EOF=7,
        S_TOP_SCAN=8, S_TOP_WRITE=9, S_TRACK_INIT=10, S_TRACK_SCAN=11,
        S_TRACK_APPLY=12, S_MISS=13, S_NEW=14, S_PUBLISH=15,
        S_SCAN_LOAD=16, S_EOF_LOAD=17, S_CLASS_START=18, S_CLASS_WAIT=19,
        S_CLASS_REQ=20;

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
    wire [X_BITS:0] token_span = {1'b0,token_xmax}-{1'b0,token_xmin}+1'b1;
    wire [COORD_BITS-1:0] token_xsum = {1'b0,token_xmin}+{1'b0,token_xmax};
    wire [COORD_BITS-1:0] token_y2 = {token_y,1'b0};
    wire [MOM_BITS-1:0] token_mx2 = token_pixels*token_xsum;
    wire [MOM_BITS-1:0] token_my2 = token_pixels*token_y2;
    wire [COORD_BITS-1:0] token_umin = {1'b0,token_xmin}+token_y;
    wire [COORD_BITS-1:0] token_umax = {1'b0,token_xmax}+token_y;
    wire [COORD_BITS-1:0] token_vmin = {1'b0,token_xmin}+IMG_HEIGHT-token_y;
    wire [COORD_BITS-1:0] token_vmax = {1'b0,token_xmax}+IMG_HEIGHT-token_y;
    assign {token_kind,token_id,token_xmin,token_xmax,token_y,token_pixels}=token;
    assign fifo_pop=(state == S_FETCH) && fifo_count != 0 && I_rst_n && !I_clear;

    reg [15:0] candidate_valid;
    reg [3:0] scan_index, match_slot, free_slot;
    reg match_slot_valid, free_slot_valid;
    reg [X_BITS-1:0] work_xmin, work_xmax, work_prev_min, work_prev_max;
    reg [X_BITS-1:0] work_row_min, work_row_max;
    reg [Y_BITS-1:0] work_ymin, work_ymax;
    reg [COUNT_BITS-1:0] work_pixels;
    reg [15:0] work_perimeter;
    reg work_shape_bad;
    reg [MOM_BITS-1:0] work_mx2, work_my2;
    reg [COORD_BITS-1:0] work_umin, work_umax, work_vmin, work_vmax;
    reg work_prev_valid;
    wire [CAND_BITS-1:0] candidate_data;
    reg candidate_expired, same_row, link_valid, candidate_qualified;
    reg [X_BITS-1:0] link_min, link_max;
    wire [X_BITS-1:0] read_xmin, read_xmax, read_prev_min, read_prev_max;
    wire [X_BITS-1:0] read_row_min, read_row_max;
    wire [Y_BITS-1:0] read_ymin, read_ymax;
    wire [COUNT_BITS-1:0] read_pixels;
    wire read_prev_valid;
    wire [15:0] read_perimeter;
    wire read_shape_bad;
    wire [MOM_BITS-1:0] read_mx2, read_my2;
    wire [COORD_BITS-1:0] read_umin, read_umax, read_vmin, read_vmax;
    assign {read_xmin,read_xmax,read_ymin,read_ymax,read_pixels,
            read_prev_valid,read_prev_min,read_prev_max,read_row_min,read_row_max,
            read_perimeter,read_shape_bad,read_mx2,read_my2,
            read_umin,read_umax,read_vmin,read_vmax}
        =candidate_data;
    wire read_same_row=(token_y == read_ymax);
    wire read_adjacent_row=({1'b0,token_y} == {1'b0,read_ymax}+1'b1);
    wire [X_BITS-1:0] cand_xmin, cand_xmax, cand_prev_min, cand_prev_max;
    wire [X_BITS-1:0] cand_row_min, cand_row_max;
    wire [Y_BITS-1:0] cand_ymin, cand_ymax;
    wire [COUNT_BITS-1:0] cand_pixels;
    wire cand_prev_valid;
    wire [15:0] cand_perimeter;
    wire cand_shape_bad;
    wire [MOM_BITS-1:0] cand_mx2, cand_my2;
    wire [COORD_BITS-1:0] cand_umin, cand_umax, cand_vmin, cand_vmax;
    assign {cand_xmin,cand_xmax,cand_ymin,cand_ymax,cand_pixels,
            cand_prev_valid,cand_prev_min,cand_prev_max,cand_row_min,cand_row_max,
            cand_perimeter,cand_shape_bad,cand_mx2,cand_my2,
            cand_umin,cand_umax,cand_vmin,cand_vmax}
        =candidate_data;
    wire [X_BITS-1:0] overlap_min = token_xmin > read_row_min ? token_xmin : read_row_min;
    wire [X_BITS-1:0] overlap_max = token_xmax < read_row_max ? token_xmax : read_row_max;
    wire [X_BITS:0] overlap_width = overlap_min <= overlap_max ?
        {1'b0,overlap_max}-{1'b0,overlap_min}+1'b1 : 0;
    wire [1:0] diagonal_steps = {1'b0,(token_xmin != read_row_min)}+
        {1'b0,(token_xmax != read_row_max)};
    reg [15:0] shared_boundary;
    reg boundary_bad;
    wire [16:0] merged_perimeter =
        {1'b0,work_perimeter}+{1'b0,cand_perimeter}-{1'b0,shared_boundary};
    wire candidate_matches=link_valid &&
        ({1'b0,token_xmin} <= {1'b0,link_max}+1'b1) &&
        ({1'b0,link_min} <= {1'b0,token_xmax}+1'b1);
    reg [1:0] class_index,top_index,minimum_slot;
    reg [COUNT_BITS-1:0] minimum_pixels;
    reg minimum_empty;
    wire commit_ok=match_slot_valid || free_slot_valid;
    wire [3:0] commit_slot=match_slot_valid ? match_slot : free_slot;
    wire top_write=state == S_TOP_WRITE &&
        (minimum_empty || cand_pixels > minimum_pixels);
    wire candidate_write=((state == S_COMMIT && commit_ok) || top_write) &&
        I_rst_n && !I_clear;
    wire [4:0] candidate_waddr=top_write ? {3'b100,minimum_slot} : {1'b0,commit_slot};
    wire retire_to_top=candidate_valid[scan_index] && candidate_qualified &&
        (state == S_EOF || (state == S_SCAN && candidate_expired));
    wire top_resume_scan=state == S_TOP_WRITE &&
        (return_state == S_SCAN_LOAD || return_state == S_EOF_LOAD);
    // Hold the retiring row on the synchronous RAM output while selecting
    // Top4. Otherwise prefetch the next live row in the normal scan cycle.
    wire candidate_read=(state == S_SCAN_REQ || state == S_EOF_REQ ||
        state == S_CLASS_REQ || top_resume_scan ||
        ((state == S_SCAN || state == S_EOF) && scan_index != 15 &&
            !retire_to_top)) && I_rst_n && !I_clear;
    wire [4:0] candidate_raddr=state == S_CLASS_REQ ? {3'b100,class_index} :
        (state == S_SCAN_REQ || state == S_EOF_REQ) ? 5'd0 :
        top_resume_scan ? {1'b0,scan_index} : {1'b0,scan_index}+1'b1;
    // Addresses 0..15 hold live components; 16..19 hold Top4 shape features.
    // The extra shallow rows fit in the same ERAM banks and replace a wide
    // resettable feature table plus its four-way read mux.
    wire [CAND_BITS-1:0] candidate_wdata=top_write ?
        {{(CAND_BITS-FEATURE_BITS){1'b0}},cand_perimeter,cand_shape_bad,cand_mx2,cand_my2,
            cand_umin,cand_umax,cand_vmin,cand_vmax} :
        {work_xmin,work_xmax,work_ymin,work_ymax,work_pixels,
            work_prev_valid,work_prev_min,work_prev_max,work_row_min,work_row_max,
            work_perimeter,work_shape_bad,work_mx2,work_my2,
            work_umin,work_umax,work_vmin,work_vmax};
    red_multi_small_ram #(.WIDTH(CAND_BITS), .DEPTH(32), .ADDR_BITS(5)) u_candidates (
        .I_clk(I_clk), .I_write(candidate_write), .I_waddr(candidate_waddr),
        .I_data(candidate_wdata),
        .I_read(candidate_read), .I_raddr(candidate_raddr), .O_data(candidate_data)
    );

    reg [3:0] top_valid;
    reg [X_BITS-1:0] top_xmin [0:3], top_xmax [0:3];
    reg [Y_BITS-1:0] top_ymin [0:3], top_ymax [0:3];
    reg [COUNT_BITS-1:0] top_pixels [0:3];
    reg [1:0] top_shape [0:3], track_shape [0:3];
    reg [3:0] top_circle_support;
    wire shape_ready;
    wire [1:0] shape_result;
    wire shape_circle_support;
    wire [15:0] class_perimeter;
    wire class_bad;
    wire [MOM_BITS-1:0] class_mx2, class_my2;
    wire [COORD_BITS-1:0] class_umin,class_umax,class_vmin,class_vmax;
    assign {class_perimeter,class_bad,class_mx2,class_my2,
            class_umin,class_umax,class_vmin,class_vmax}=candidate_data[FEATURE_BITS-1:0];
    color_shape_descriptor #(
        .IMG_WIDTH(IMG_WIDTH),.IMG_HEIGHT(IMG_HEIGHT),.X_BITS(X_BITS),
        .Y_BITS(Y_BITS),.COUNT_BITS(COUNT_BITS),.COORD_BITS(COORD_BITS),
        .MOM_BITS(MOM_BITS),.STABLE_INPUTS(1)
    ) u_shape (
        .I_clk(I_clk),.I_rst_n(I_rst_n),.I_clear(I_clear),
        .I_start(state == S_CLASS_START && top_valid[class_index]),
        .I_bad(class_bad),.I_area(top_pixels[class_index]),.I_perimeter(class_perimeter),
        .I_xmin(top_xmin[class_index]),.I_xmax(top_xmax[class_index]),
        .I_ymin(top_ymin[class_index]),.I_ymax(top_ymax[class_index]),
        .I_mx2(class_mx2),.I_my2(class_my2),
        .I_umin(class_umin),.I_umax(class_umax),
        .I_vmin(class_vmin),.I_vmax(class_vmax),
        .O_ready(shape_ready),.O_shape(shape_result),
        .O_circle_support(shape_circle_support)
    );
    reg [3:0] track_occupied, track_confirmed, matched_tracks, used_detections;
    reg [X_BITS-1:0] track_xmin [0:3], track_xmax [0:3];
    reg [Y_BITS-1:0] track_ymin [0:3], track_ymax [0:3];
    reg [1:0] track_misses [0:3];
    // Confirm a shape twice independently of the geometry confirmation.
    // Count every frame without support for the stable class, so alternating
    // wrong/unknown classes cannot keep an obsolete label indefinitely.
    reg [1:0] track_pending_shape [0:3], track_shape_hits [0:3];
    reg [1:0] track_shape_age [0:3];
    reg [3:0] pair_index;
    reg [1:0] best_track, best_detection, track_index;
    reg best_valid;
    reg [13:0] best_distance;
    // A confirmed circle may use the weaker, current-frame circle evidence.
    // This is feature hysteresis, not an unconditional extension of label age.
    wire [1:0] matched_shape=(track_shape[best_track] == 3 &&
        top_circle_support[best_detection]) ? 2'd3 : top_shape[best_detection];
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
            work_perimeter<=0; work_shape_bad<=0; work_mx2<=0; work_my2<=0;
            work_umin<=0; work_umax<=0; work_vmin<=0; work_vmax<=0;
            shared_boundary<=0; boundary_bad<=0; class_index<=0;
            candidate_expired<=0; same_row<=0;
            link_valid<=0; link_min<=0; link_max<=0; candidate_qualified<=0;
            top_valid<=0; top_circle_support<=0;
            minimum_pixels<=0; minimum_slot<=0; minimum_empty<=0; top_index<=0;
            track_occupied<=0; track_confirmed<=0; matched_tracks<=0; used_detections<=0;
            pair_index<=0; best_track<=0; best_detection<=0; track_index<=0;
            best_valid<=0; best_distance<=0;
            O_ready<=0; O_valid<=0; O_hold<=0; O_boxes<=0; O_shapes<=0; O_frame_id<=0; O_overflow<=0;
            for (slot=0; slot<4; slot=slot+1) begin
                top_xmin[slot]<=0; top_xmax[slot]<=0; top_ymin[slot]<=0;
                top_ymax[slot]<=0; top_pixels[slot]<=0;
                top_shape[slot]<=0; track_shape[slot]<=0;
                track_pending_shape[slot]<=0; track_shape_hits[slot]<=0;
                track_shape_age[slot]<=0;
                track_xmin[slot]<=0; track_xmax[slot]<=0;
                track_ymin[slot]<=0; track_ymax[slot]<=0; track_misses[slot]<=0;
            end
        end else if (I_clear) begin
            state<=S_FETCH; context_open<=0; context_bad<=0; candidate_valid<=0;
            top_valid<=0; top_circle_support<=0; track_occupied<=0; track_confirmed<=0;
            matched_tracks<=0; used_detections<=0;
            O_ready<=0; O_valid<=0; O_hold<=0; O_boxes<=0; O_shapes<=0; O_overflow<=0;
            for (slot=0; slot<4; slot=slot+1) begin
                track_shape[slot]<=0; track_pending_shape[slot]<=0;
                track_shape_hits[slot]<=0; track_shape_age[slot]<=0;
            end
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
                            O_valid<=0; O_hold<=0; O_boxes<=0; O_shapes<=0;
                            track_occupied<=0; track_confirmed<=0;
                            for (slot=0; slot<4; slot=slot+1) begin
                                track_shape[slot]<=0; track_pending_shape[slot]<=0;
                                track_shape_hits[slot]<=0; track_shape_age[slot]<=0;
                            end
                            context_open<=0; candidate_valid<=0; state<=S_FETCH;
                        end
                    end else if (token_kind == TOK_RUN) begin
                        if (context_bad) state<=S_FETCH;
                        else begin
                            work_xmin<=token_xmin; work_xmax<=token_xmax;
                            work_ymin<=token_y; work_ymax<=token_y;
                            work_pixels<=token_pixels; work_prev_valid<=0;
                            // Q3 octile contour: axial=8, diagonal=11.
                            // Each row starts with its closed one-row outline;
                            // merging removes shared edges and staircase bias.
                            work_perimeter<=(token_span+17'd1)<<4;
                            work_shape_bad<=token_pixels != token_span;
                            work_mx2<=token_mx2; work_my2<=token_my2;
                            work_umin<=token_umin; work_umax<=token_umax;
                            work_vmin<=token_vmin; work_vmax<=token_vmax;
                            work_prev_min<=0; work_prev_max<=0;
                            work_row_min<=token_xmin; work_row_max<=token_xmax;
                            match_slot_valid<=0; free_slot_valid<=0;
                            scan_index<=0; state<=S_SCAN_REQ;
                        end
                    end else if (token_kind != TOK_END || context_bad) begin
                        O_ready<=1; O_frame_id<=context_id;
                        O_overflow<=context_bad || token_kind == TOK_OVERFLOW;
                        O_valid<=0; O_hold<=0; O_boxes<=0; O_shapes<=0;
                        track_occupied<=0; track_confirmed<=0;
                        for (slot=0; slot<4; slot=slot+1) begin
                            track_shape[slot]<=0; track_pending_shape[slot]<=0;
                            track_shape_hits[slot]<=0; track_shape_age[slot]<=0;
                        end
                        context_open<=0; candidate_valid<=0; state<=S_FETCH;
                    end else begin
                        scan_index<=0; state<=S_EOF_REQ;
                    end
                end
                S_SCAN_REQ: state<=S_SCAN_LOAD;
                S_SCAN_LOAD, S_EOF_LOAD: begin
                    // Separate the RAM row selection from overlap and merge.
                    candidate_expired<=({1'b0,token_y} > {1'b0,read_ymax}+1'b1);
                    same_row<=read_same_row;
                    link_valid<=read_same_row ? read_prev_valid : read_adjacent_row;
                    link_min<=read_same_row ? read_prev_min : read_row_min;
                    link_max<=read_same_row ? read_prev_max : read_row_max;
                    shared_boundary<=read_adjacent_row ?
                        (overlap_width<<4)+diagonal_steps*16'd5 : 16'd0;
                    boundary_bad<=!read_adjacent_row || overlap_width == 0;
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
                            top_index<=0;
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
                        work_perimeter<=merged_perimeter[15:0];
                        work_shape_bad<=work_shape_bad || cand_shape_bad || boundary_bad ||
                            match_slot_valid || merged_perimeter[16];
                        work_mx2<=work_mx2+cand_mx2; work_my2<=work_my2+cand_my2;
                        if (cand_umin < work_umin) work_umin<=cand_umin;
                        if (cand_umax > work_umax) work_umax<=cand_umax;
                        if (cand_vmin < work_vmin) work_vmin<=cand_vmin;
                        if (cand_vmax > work_vmax) work_vmax<=cand_vmax;
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
                    state<=scan_index == 15 ? S_CLASS_REQ : S_EOF_LOAD;
                    class_index<=0;
                    if (candidate_valid[scan_index] && candidate_qualified) begin
                        top_index<=0;
                        minimum_empty<=0; minimum_pixels<={COUNT_BITS{1'b1}};
                        return_state<=scan_index == 15 ? S_CLASS_REQ : S_EOF_LOAD;
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
                    // The RAM output is held throughout Top4 selection.
                    if (top_write) begin
                        top_valid[minimum_slot]<=1; top_pixels[minimum_slot]<=cand_pixels;
                        top_xmin[minimum_slot]<=cand_xmin; top_xmax[minimum_slot]<=cand_xmax;
                        top_ymin[minimum_slot]<=cand_ymin; top_ymax[minimum_slot]<=cand_ymax;
                    end
                    state<=return_state;
                end
                S_CLASS_REQ: state<=S_CLASS_START;
                S_CLASS_START: begin
                    if (top_valid[class_index]) state<=S_CLASS_WAIT;
                    else begin
                        top_shape[class_index]<=0;
                        top_circle_support[class_index]<=0;
                        if (class_index == 3) state<=S_TRACK_INIT;
                        else begin class_index<=class_index+1'b1; state<=S_CLASS_REQ; end
                    end
                end
                S_CLASS_WAIT: if (shape_ready) begin
                    top_shape[class_index]<=shape_result;
                    top_circle_support[class_index]<=shape_circle_support;
                    if (class_index == 3) state<=S_TRACK_INIT;
                    else begin class_index<=class_index+1'b1; state<=S_CLASS_REQ; end
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
                        if (matched_shape != 0 &&
                            matched_shape == track_shape[best_track]) begin
                            track_pending_shape[best_track]<=0;
                            track_shape_hits[best_track]<=0;
                            track_shape_age[best_track]<=0;
                        end else if (matched_shape != 0 &&
                            matched_shape == track_pending_shape[best_track] &&
                            track_shape_hits[best_track] != 0) begin
                            track_shape[best_track]<=matched_shape;
                            track_pending_shape[best_track]<=0;
                            track_shape_hits[best_track]<=0;
                            track_shape_age[best_track]<=0;
                        end else begin
                            track_pending_shape[best_track]<=matched_shape;
                            track_shape_hits[best_track]<=matched_shape != 0 ? 1 : 0;
                            if (track_shape_age[best_track] < 2)
                                track_shape_age[best_track]<=track_shape_age[best_track]+1'b1;
                            else begin
                                track_shape[best_track]<=0;
                                track_shape_age[best_track]<=2;
                            end
                        end
                        best_valid<=0; best_distance<=14'h3fff; pair_index<=0;
                        state<=S_TRACK_SCAN;
                    end else begin track_index<=0; state<=S_MISS; end
                end
                S_MISS: begin
                    if (track_occupied[track_index] && !matched_tracks[track_index]) begin
                        if (!track_confirmed[track_index] || track_misses[track_index] == 2) begin
                            track_occupied[track_index]<=0; track_confirmed[track_index]<=0;
                            track_shape[track_index]<=0; track_pending_shape[track_index]<=0;
                            track_shape_hits[track_index]<=0; track_shape_age[track_index]<=0;
                        end else begin
                            track_misses[track_index]<=track_misses[track_index]+1'b1;
                            track_pending_shape[track_index]<=0;
                            track_shape_hits[track_index]<=0;
                            if (track_shape_age[track_index] < 2)
                                track_shape_age[track_index]<=track_shape_age[track_index]+1'b1;
                            else begin
                                track_shape[track_index]<=0;
                                track_shape_age[track_index]<=2;
                            end
                        end
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
                        track_shape[empty_track]<=0;
                        track_pending_shape[empty_track]<=top_shape[track_index];
                        track_shape_hits[empty_track]<=top_shape[track_index] != 0 ? 1 : 0;
                        track_shape_age[empty_track]<=0;
                    end
                    if (track_index == 3) state<=S_PUBLISH;
                    else track_index<=track_index+1'b1;
                end
                S_PUBLISH: begin
                    O_ready<=1; O_frame_id<=context_id; O_overflow<=0;
                    O_valid<=track_occupied & track_confirmed;
                    for (slot=0; slot<4; slot=slot+1) begin
                        O_hold[slot]<=track_occupied[slot] && track_confirmed[slot] && track_misses[slot] != 0;
                        O_shapes[slot*2+:2]<=track_occupied[slot] && track_confirmed[slot] ?
                            track_shape[slot] : 2'd0;
                        O_boxes[slot*48+:48]<={{(12-Y_BITS){1'b0}},track_ymax[slot],
                            {(12-Y_BITS){1'b0}},track_ymin[slot],
                            {(12-X_BITS){1'b0}},track_xmax[slot],
                            {(12-X_BITS){1'b0}},track_xmin[slot]};
                    end
                    context_open<=0; state<=S_FETCH;
                end
                default: begin
                    state<=S_FETCH; context_open<=0; track_occupied<=0; track_confirmed<=0;
                    for (slot=0; slot<4; slot=slot+1) begin
                        track_shape[slot]<=0; track_pending_shape[slot]<=0;
                        track_shape_hits[slot]<=0; track_shape_age[slot]<=0;
                    end
                end
            endcase
        end
    end
endmodule

// Shared once per Top4 result, outside the pixel-rate path. Q3 contour length
// and four projected first moments avoid an edge image or perspective warp.
// Codes: 0 unknown, 1 square, 2 triangle, 3 circle.
module color_shape_descriptor #(
    parameter integer IMG_WIDTH=1280, IMG_HEIGHT=720,
    parameter integer X_BITS=11, Y_BITS=10, COUNT_BITS=20,
    parameter integer COORD_BITS=12, MOM_BITS=32,
    parameter integer STABLE_INPUTS=0
) (
    input wire I_clk,I_rst_n,I_clear,I_start,I_bad,
    input wire [COUNT_BITS-1:0] I_area,
    input wire [15:0] I_perimeter,
    input wire [X_BITS-1:0] I_xmin,I_xmax,
    input wire [Y_BITS-1:0] I_ymin,I_ymax,
    input wire [MOM_BITS-1:0] I_mx2,I_my2,
    input wire [COORD_BITS-1:0] I_umin,I_umax,I_vmin,I_vmax,
    output reg O_ready,
    output reg [1:0] O_shape,
    output reg O_circle_support
);
    localparam [3:0] IDLE=0,MULTIPLY=1,METRIC=2,CENTER_START=3,
        CENTER_DONE=4,SPAN_START=5,SPAN_DONE=6,FINISH=7,
        CIRCLE_X_START=8,CIRCLE_X_DONE=9,CIRCLE_U_DONE=10;
    // P8 squared needs 32 bits; the area metric needs COUNT_BITS+12.
    // Bound the signed projected-moment difference, then reserve four bits
    // for the largest centroid scale (16*D). Keep the 32 multiply cycles.
    localparam integer DEV_BITS =
        (MOM_BITS+2 > COUNT_BITS+COORD_BITS+2) ?
        MOM_BITS+2 : COUNT_BITS+COORD_BITS+2;
    localparam integer AREA_SCALE_BITS = COUNT_BITS+12;
    localparam integer PRODUCT_BITS =
        AREA_SCALE_BITS > 32 ? AREA_SCALE_BITS : 32;
    localparam integer MATH_BITS =
        DEV_BITS+4 > PRODUCT_BITS ? DEV_BITS+4 : PRODUCT_BITS;
    reg [3:0] state,multiply_return;
    reg [5:0] multiply_count;
    reg [MATH_BITS-1:0] multiplicand,product,deviation;
    reg [31:0] multiplier;
    reg [COUNT_BITS-1:0] saved_area;
    reg [X_BITS-1:0] saved_xmin,saved_xmax;
    reg [Y_BITS-1:0] saved_ymin,saved_ymax;
    reg [MOM_BITS-1:0] saved_mx2,saved_my2;
    reg [COORD_BITS-1:0] saved_umin,saved_umax,saved_vmin,saved_vmax;
    // The engine holds its Top4 RAM output and geometry during CLASS_WAIT.
    // Other callers retain the default snapshot-on-start interface.
    wire [COUNT_BITS-1:0] area=STABLE_INPUTS ? I_area : saved_area;
    wire [X_BITS-1:0] xmin=STABLE_INPUTS ? I_xmin : saved_xmin;
    wire [X_BITS-1:0] xmax=STABLE_INPUTS ? I_xmax : saved_xmax;
    wire [Y_BITS-1:0] ymin=STABLE_INPUTS ? I_ymin : saved_ymin;
    wire [Y_BITS-1:0] ymax=STABLE_INPUTS ? I_ymax : saved_ymax;
    wire [MOM_BITS-1:0] mx2=STABLE_INPUTS ? I_mx2 : saved_mx2;
    wire [MOM_BITS-1:0] my2=STABLE_INPUTS ? I_my2 : saved_my2;
    wire [COORD_BITS-1:0] umin=STABLE_INPUTS ? I_umin : saved_umin;
    wire [COORD_BITS-1:0] umax=STABLE_INPUTS ? I_umax : saved_umax;
    wire [COORD_BITS-1:0] vmin=STABLE_INPUTS ? I_vmin : saved_vmin;
    wire [COORD_BITS-1:0] vmax=STABLE_INPUTS ? I_vmax : saved_vmax;
    reg [1:0] projection;
    reg isotropic,centered,skew,circle_metric,square_metric,triangle_metric;
    reg circle_fill;
    reg circle_support,square_fill,square_spans_ok;
    reg center_negative;
    reg signed [MATH_BITS-1:0] moment;
    reg [COORD_BITS:0] saved_span;
    wire [MATH_BITS-1:0] area_wide={{(MATH_BITS-COUNT_BITS){1'b0}},area};
    // A circle has substantially more support than a square in both the
    // axis-aligned and diagonal bounding boxes.  The diagonal box covers two
    // pixels per (u,v) lattice cell, hence the 50A >= 18*Buv scale below.
    wire [MATH_BITS-1:0] area25=(area_wide<<4)+(area_wide<<3)+area_wide;
    wire [MATH_BITS-1:0] area50=(area_wide<<5)+(area_wide<<4)+(area_wide<<1);
    wire [MATH_BITS-1:0] box18=(product<<4)+(product<<1);
    wire [MATH_BITS-1:0] box17=(product<<4)+product;
    wire [COORD_BITS:0] width={1'b0,xmax}-{1'b0,xmin}+1'b1;
    wire [COORD_BITS:0] height={1'b0,ymax}-{1'b0,ymin}+1'b1;
    wire [COORD_BITS:0] u_span={1'b0,umax}-{1'b0,umin}+1'b1;
    wire [COORD_BITS:0] v_span={1'b0,vmax}-{1'b0,vmin}+1'b1;
    // Keep 9:8 for circles. Squares may additionally absorb two raster
    // pixels, but only when a directional coverage gives square evidence.
    wire [COORD_BITS+4:0] w8={width,3'b0},h8={height,3'b0};
    wire [COORD_BITS+4:0] u8={u_span,3'b0},v8={v_span,3'b0};
    reg signed [COORD_BITS+1:0] projection_center;
    reg [COORD_BITS-1:0] projection_min,projection_max;
    reg signed [MATH_BITS-1:0] projection_moment;
    reg [COORD_BITS:0] projection_span;
    // Add or subtract the center product in one full-width carry chain.
    // Keeping the carry-in explicit preserves the original modulo arithmetic.
    wire [MATH_BITS-1:0] center_product_operand=
        product ^ {MATH_BITS{!center_negative}};
    wire signed [MATH_BITS-1:0] signed_difference=
        moment+center_product_operand+
        {{(MATH_BITS-1){1'b0}},!center_negative};
    // U and V projections use the same sum, with a controlled second operand.
    wire projection_subtract=projection == 3;
    wire [MATH_BITS-1:0] projection_my_operand=
        {{(MATH_BITS-MOM_BITS){1'b0}},my2} ^
        {MATH_BITS{projection_subtract}};
    wire signed [MATH_BITS-1:0] projection_uv_moment=
        {{(MATH_BITS-MOM_BITS){1'b0}},mx2}+projection_my_operand+
        {{(MATH_BITS-1){1'b0}},projection_subtract};
    always @* begin
        case (projection)
            0: begin
                projection_min=xmin; projection_max=xmax;
                projection_moment=$signed({1'b0,mx2});
                projection_span=width;
            end
            1: begin
                projection_min=ymin; projection_max=ymax;
                projection_moment=$signed({1'b0,my2});
                projection_span=height;
            end
            2: begin
                projection_min=umin; projection_max=umax;
                projection_moment=projection_uv_moment;
                projection_span=u_span;
            end
            default: begin
                projection_min=vmin; projection_max=vmax;
                projection_moment=projection_uv_moment;
                projection_span=v_span;
            end
        endcase
        projection_center=$signed({1'b0,projection_min})+
            $signed({1'b0,projection_max})-(projection==3 ? 2*IMG_HEIGHT : 0);
    end
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            state<=IDLE; multiply_return<=IDLE; multiply_count<=0;
            multiplicand<=0; multiplier<=0; product<=0; deviation<=0;
            saved_area<=0; saved_xmin<=0; saved_xmax<=0; saved_ymin<=0; saved_ymax<=0;
            saved_mx2<=0; saved_my2<=0; saved_umin<=0; saved_umax<=0; saved_vmin<=0; saved_vmax<=0;
            projection<=0; isotropic<=0; centered<=0; skew<=0;
            circle_metric<=0; square_metric<=0; triangle_metric<=0;
            circle_fill<=0;
            circle_support<=0; square_fill<=0; square_spans_ok<=0;
            moment<=0; center_negative<=0; saved_span<=0;
            O_ready<=0; O_shape<=0; O_circle_support<=0;
        end else if (I_clear) begin
            state<=IDLE; O_ready<=0; O_shape<=0; O_circle_support<=0;
        end else begin
            O_ready<=0;
            case (state)
                IDLE: if (I_start) begin
                    O_shape<=0; O_circle_support<=0;
                    if (I_bad || I_area == 0 || I_xmin <= 3 || I_ymin <= 3 ||
                        I_xmax >= IMG_WIDTH-4 || I_ymax >= IMG_HEIGHT-4 ||
                        I_xmax-I_xmin < 11 || I_ymax-I_ymin < 11) O_ready<=1;
                    else begin
                        if (!STABLE_INPUTS) begin
                            saved_area<=I_area; saved_xmin<=I_xmin; saved_xmax<=I_xmax;
                            saved_ymin<=I_ymin; saved_ymax<=I_ymax;
                            saved_mx2<=I_mx2; saved_my2<=I_my2;
                            saved_umin<=I_umin; saved_umax<=I_umax;
                            saved_vmin<=I_vmin; saved_vmax<=I_vmax;
                        end
                        multiplicand<={{(MATH_BITS-16){1'b0}},I_perimeter}; multiplier<=I_perimeter;
                        product<=0; multiply_count<=0; multiply_return<=METRIC;
                        state<=MULTIPLY;
                    end
                end
                MULTIPLY: begin
                    if (multiplier[0]) product<=product+multiplicand;
                    multiplicand<=multiplicand<<1; multiplier<=multiplier>>1;
                    multiply_count<=multiply_count+1'b1;
                    if (multiply_count == 31) state<=multiply_return;
                end
                METRIC: begin
                    // P8^2/(64A): square 13.5..19; triangle 19..64.
                    // Circle tolerates perimeter noise up to 19 only when
                    // both bounding-box coverages reach 18/25. This also
                    // separates small rasterized squares with Q below 14.5.
                    circle_metric<=product <= (area_wide<<10)+(area_wide<<7)+(area_wide<<6);
                    square_metric<=product >= (area_wide<<10)-(area_wide<<7)-(area_wide<<5) &&
                        product <= (area_wide<<10)+(area_wide<<7)+(area_wide<<6);
                    triangle_metric<=product > (area_wide<<10)+(area_wide<<7)+(area_wide<<6) &&
                        product <= (area_wide<<12);
                    isotropic<=w8 <= h8+height && h8 <= w8+width &&
                        u8 <= v8+v_span && v8 <= u8+u_span;
                    // The old +16 was an absolute two-pixel allowance: enough
                    // for a 17x15 mask, but only 1.4% of a 141-pixel target.
                    // Scale the allowance with the target so camera vertical
                    // compression is not mistaken for a rectangle.
                    square_spans_ok<=w8 <= h8+height+(height>>2) &&
                        h8 <= w8+width+(width>>2) &&
                        u8 <= v8+v_span+16 && v8 <= u8+u_span+16;
                    centered<=1; skew<=0; projection<=0; state<=CIRCLE_X_START;
                end
                CIRCLE_X_START: begin
                    multiplicand<=width; multiplier<=height;
                    product<=0; multiply_count<=0; multiply_return<=CIRCLE_X_DONE;
                    state<=MULTIPLY;
                end
                CIRCLE_X_DONE: begin
                    circle_fill<=area25 >= box18;
                    circle_support<=area25 >= box17;
                    square_fill<=area25 <= (product<<4);
                    multiplicand<=u_span; multiplier<=v_span;
                    product<=0; multiply_count<=0; multiply_return<=CIRCLE_U_DONE;
                    state<=MULTIPLY;
                end
                CIRCLE_U_DONE: begin
                    circle_fill<=circle_fill && area50 >= box18;
                    circle_support<=circle_support && area50 >= box17;
                    square_fill<=square_fill || area50 <= (product<<4);
                    state<=CENTER_START;
                end
                CENTER_START: begin
                    multiplicand<=area_wide;
                    multiplier<=projection_center < 0 ? -projection_center : projection_center;
                    product<=0; multiply_count<=0; multiply_return<=CENTER_DONE;
                    center_negative<=projection_center < 0;
                    moment<=projection_moment; saved_span<=projection_span;
                    state<=MULTIPLY;
                end
                CENTER_DONE: begin
                    deviation<=signed_difference < 0 ? -signed_difference : signed_difference;
                    state<=SPAN_START;
                end
                SPAN_START: begin
                    multiplicand<=area_wide; multiplier<=saved_span;
                    product<=0; multiply_count<=0; multiply_return<=SPAN_DONE;
                    state<=MULTIPLY;
                end
                SPAN_DONE: begin
                    // deviation is twice the physical centroid offset:
                    // 8D <= A*S allows a displacement of S/16.
                    centered<=centered && (deviation<<3) <= product;
                    skew<=skew || ((deviation<<3)+(deviation<<2)) >= product;
                    if (projection == 3) state<=FINISH;
                    else begin projection<=projection+1'b1; state<=CENTER_START; end
                end
                FINISH: begin
                    O_circle_support<=isotropic && centered && circle_metric && circle_support;
                    if (isotropic && centered && circle_metric && circle_fill) O_shape<=3;
                    else if ((isotropic || (square_spans_ok && square_fill)) &&
                        centered && square_metric && !circle_fill) O_shape<=1;
                    else if (skew && triangle_metric) O_shape<=2;
                    else O_shape<=0;
                    O_ready<=1; state<=IDLE;
                end
                default: state<=IDLE;
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
    localparam integer BANK_WIDTH = 40;
    localparam integer BANKS = (WIDTH+BANK_WIDTH-1)/BANK_WIDTH;
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
            // A only writes and B only reads. Pseudo dual-port mode uses
            // all 40 bits of each ERAM while retaining a one-clock read.
            wire [BANKS*BANK_WIDTH-1:0] padded_input=
                {{(BANKS*BANK_WIDTH-WIDTH){1'b0}},I_data};
            wire [BANKS*BANK_WIDTH-1:0] padded_output;
            genvar bank;
            for (bank=0; bank<BANKS; bank=bank+1) begin : gen_bank
                PH1P_LOGIC_ERAM #(
                    .DATA_WIDTH_A(BANK_WIDTH), .DATA_WIDTH_B(BANK_WIDTH),
                    .ADDR_WIDTH_A(ADDR_BITS), .ADDR_WIDTH_B(ADDR_BITS),
                    .DATA_DEPTH_A(DEPTH), .DATA_DEPTH_B(DEPTH), .MODE("PDPW"),
                    .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
                    .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
                    .IMPLEMENT("20K(FAST)"), .CLKMODE("SYNC"),
                    .ECC_ENCODE("DISABLE"), .ECC_DECODE("DISABLE"),
                    .INIT_FILE("NONE"), .FILL_ALL("NONE")
                ) u_ram (
                    .clka(I_clk), .clkb(I_clk), .cea(I_write), .ceb(I_read),
                    .ocea(1'b0), .oceb(1'b0), .wea(I_write), .web(1'b0),
                    .rsta(1'b0), .rstb(1'b0), .bea(1'b0), .beb(1'b0),
                    .addra(I_waddr), .addrb(I_raddr),
                    .dia(padded_input[bank*BANK_WIDTH+:BANK_WIDTH]),
                    .dib({BANK_WIDTH{1'b0}}), .doa(),
                    .dob(padded_output[bank*BANK_WIDTH+:BANK_WIDTH]),
                    .ecc_sbiterr(), .ecc_dbiterr(),
                    .ecc_sbiterrinj(1'b0), .ecc_dbiterrinj(1'b0)
                );
            end
            assign O_data=padded_output[WIDTH-1:0];
        end
    endgenerate
endmodule

// One packed ERAM stores the two binary rows needed by a four-lane window.
// A synchronous read returns {row y-2,row y-1} alongside the current mask.
// The following clock writes {row y-1,current row} to the previous address.
// Consecutive accepted groups use different addresses; a row has at least
// two groups, so each update completes before that address is read again.
module red_mask_rows_4 #(
    parameter integer GROUPS = 320,
    parameter integer ADDR_BITS = GROUPS > 1 ? $clog2(GROUPS) : 1
) (
    input wire I_clk, I_rst_n, I_valid,
    input wire [ADDR_BITS-1:0] I_group,
    input wire [3:0] I_mask,
    output wire [3:0] O_top, O_mid, O_bot
);
    localparam integer DEPTH = 1 << ADDR_BITS;
`ifdef RED_MULTI_PORTABLE_RAM
    localparam integer PORTABLE = 1;
`elsif SCHARR_PORTABLE_RAM
    localparam integer PORTABLE = 1;
`else
    localparam integer PORTABLE = 0;
`endif
    reg write_pending;
    reg [ADDR_BITS-1:0] write_group;
    reg [3:0] current_mask;
    wire read_enable = I_rst_n && I_valid;
    wire write_enable = I_rst_n && write_pending;
    wire [7:0] previous_rows;
    wire [7:0] next_rows = {previous_rows[3:0],current_mask};
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n)
            write_pending <= 1'b0;
        else
            write_pending <= I_valid;
    end
    // Pixel/address registers need no reset. The caller qualifies their
    // outputs and suppresses the first two rows while the ERAM refills.
    always @(posedge I_clk) begin
        if (read_enable) begin
            write_group <= I_group;
            current_mask <= I_mask;
        end
    end
    assign O_top = previous_rows[7:4];
    assign O_mid = previous_rows[3:0];
    assign O_bot = current_mask;
    generate
        if (PORTABLE) begin : gen_portable
            reg [7:0] memory [0:DEPTH-1];
            reg [7:0] read_data;
            always @(posedge I_clk) begin
                if (write_enable) memory[write_group] <= next_rows;
                if (read_enable) read_data <= memory[I_group];
            end
            assign previous_rows = read_data;
        end else begin : gen_eram
            PH1P_LOGIC_ERAM #(
                .DATA_WIDTH_A(8), .DATA_WIDTH_B(8),
                .ADDR_WIDTH_A(ADDR_BITS), .ADDR_WIDTH_B(ADDR_BITS),
                .DATA_DEPTH_A(DEPTH), .DATA_DEPTH_B(DEPTH), .MODE("PDPW"),
                .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
                .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
                .IMPLEMENT("20K(FAST)"), .CLKMODE("SYNC"),
                .ECC_ENCODE("DISABLE"), .ECC_DECODE("DISABLE"),
                .INIT_FILE("NONE"), .FILL_ALL("NONE")
            ) u_rows (
                .clka(I_clk), .clkb(I_clk), .cea(write_enable), .ceb(read_enable),
                .ocea(1'b0), .oceb(1'b0), .wea(write_enable), .web(1'b0),
                .rsta(1'b0), .rstb(1'b0), .bea(1'b0), .beb(1'b0),
                .addra(write_group), .addrb(I_group), .dia(next_rows), .dib(8'd0),
                .doa(), .dob(previous_rows), .ecc_sbiterr(), .ecc_dbiterr(),
                .ecc_sbiterrinj(1'b0), .ecc_dbiterrinj(1'b0)
            );
        end
    endgenerate
endmodule
