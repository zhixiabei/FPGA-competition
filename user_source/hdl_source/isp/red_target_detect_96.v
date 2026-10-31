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
    parameter integer MULTI_ENABLE = 0,
    parameter integer CANDIDATE_SLOTS = 8,
    parameter integer MAX_TARGETS = 3,
    parameter integer SINGLE_SHAPE_ENABLE = 0
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
    // Separate SOF color selection/max-min from the threshold arithmetic.
    // Four lanes still accept a beat every clock; all beat metadata follows
    // this register, and the preview tail below gives back the same clock.
    reg green_m;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) green_m <= 1'b0;
        else green_m <= I_color_mode == 2'd1;
    end
    wire [3:0] red_mask;
    genvar p;
    generate
        for (p = 0; p < 4; p = p + 1) begin : gen_red
            wire [7:0] red_in = I_tdata[95-p*24-:8];
            wire [7:0] green_in = I_tdata[87-p*24-:8];
            wire [7:0] blue_in = I_tdata[79-p*24-:8];
            reg [7:0] dominant_in, secondary_a_in, secondary_b_in;
            reg [7:0] dominant, secondary_max, secondary_min;
            wire [8:0] red = {1'b0,dominant};
            wire secondary_a_larger = secondary_a_in >= secondary_b_in;
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
                    2'd1: begin dominant_in=green_in; secondary_a_in=red_in; secondary_b_in=blue_in; end
                    2'd2: begin dominant_in=blue_in; secondary_a_in=red_in; secondary_b_in=green_in; end
                    default: begin dominant_in=red_in; secondary_a_in=green_in; secondary_b_in=blue_in; end
                endcase
            end
            always @(posedge I_clk or negedge I_rst_n) begin
                if (!I_rst_n) begin
                    dominant <= 0; secondary_max <= 0; secondary_min <= 0;
                end else begin
                    dominant <= dominant_in;
                    secondary_max <= secondary_a_larger ? secondary_a_in : secondary_b_in;
                    secondary_min <= secondary_a_larger ? secondary_b_in : secondary_a_in;
                end
            end
            // The larger secondary channel gives the stronger bounds.
            // Reuse these sums/comparisons for both secondary channels.
            assign secondary_limit = {1'b0,secondary_max} + RED_DELTA_9;
            if (RED_DELTA_9 <= 9'd256) begin : gen_monotone_delta
                assign delta_ok = red >= secondary_limit;
            end else begin : gen_legacy_wrapped_delta
                // Preserve the original nine-bit wrap for unusual parameters.
                wire [8:0] limit_a = {1'b0,secondary_max} + RED_DELTA_9;
                wire [8:0] limit_b = {1'b0,secondary_min} + RED_DELTA_9;
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
            assign red_mask[p] = green_m ?
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

    reg valid_m, start_m, final_m;
    reg [GROUP_BITS-1:0] group_m;
    reg [Y_BITS-1:0] row_m;
    reg [3:0] view_m;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            valid_m <= 0; start_m <= 0; final_m <= 0;
            group_m <= 0; row_m <= 0; view_m <= 0;
        end else begin
            valid_m <= accept_beat;
            start_m <= accept_beat && start_frame;
            final_m <= accept_beat && final_beat;
            group_m <= beat_group;
            row_m <= beat_row;
            view_m <= I_mask_view_mode;
        end
    end

    // Each two-row binary history occupies one packed eight-bit ERAM.
    // Rows 0/1 refill it before any old data can contribute to the filter.
    wire [3:0] top_now, mid_now, bot_now;
    red_mask_rows_4 #(.GROUPS(IMG_WIDTH_GRP),.ADDR_BITS(GROUP_BITS)) u_mask_rows (
        .I_clk(I_clk),.I_rst_n(I_rst_n),.I_valid(valid_m),
        .I_group(group_m),.I_mask(red_mask),
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
            valid_d <= valid_m;
            start_d <= start_m;
            final_d <= final_m;
            group_d <= group_m;
            row_d <= row_m;
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
            view_d <= view_m;
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
    reg [3:0] mask_preview_pipe [0:4];
    integer preview_stage;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            for (preview_stage=0;preview_stage<5;preview_stage=preview_stage+1)
                mask_preview_pipe[preview_stage]<=0;
        end else begin
            mask_preview_pipe[0]<=view_fd == 4'd12 ?
                (valid_fd ? closed_hits : 4'd0) : preview_hf;
            for (preview_stage=1;preview_stage<5;preview_stage=preview_stage+1)
                mask_preview_pipe[preview_stage]<=mask_preview_pipe[preview_stage-1];
        end
    end
    assign O_mask_pixels=mask_preview_pipe[4];

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
    reg valid_b, start_b, final_b, hit_b, row_end_b;
    reg [2:0] popcount_b;
    reg [X_BITS-1:0] xmin_b, xmax_b;
    reg [Y_BITS-1:0] y_b;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            valid_b <= 1'b0;
            start_b <= 1'b0;
            final_b <= 1'b0;
            hit_b <= 1'b0;
            row_end_b <= 1'b0;
            popcount_b <= 3'd0;
            xmin_b <= {X_BITS{1'b0}};
            xmax_b <= {X_BITS{1'b0}};
            y_b <= {Y_BITS{1'b0}};
        end else begin
            valid_b <= valid_f;
            start_b <= start_f;
            final_b <= final_f;
            row_end_b <= valid_f && group_f == IMG_WIDTH_GRP-1;
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

    // Publication is ten clocks after acceptance of the last input
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

    reg [9:0] pending_id, active_id, id_m, id_d, id_h, id_cd, id_c, id_fd, id_f, id_b;
    reg clear_m;
    wire [9:0] accepted_id = start_frame ?
        (I_tuser ? I_frame_id : pending_id) : active_id;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            pending_id <= 0; active_id <= 0;
            id_m <= 0; id_d <= 0; id_h <= 0; id_cd <= 0; id_c <= 0;
            id_fd <= 0; id_f <= 0; id_b <= 0;
            clear_m <= 0;
        end else begin
            clear_m <= I_multi_clear;
            if (I_tuser) pending_id <= I_frame_id;
            if (accept_beat) begin
                id_m <= accepted_id;
                if (start_frame) active_id <= accepted_id;
            end
            if (valid_m) id_d <= id_m;
            if (valid_d) id_h <= id_d;
            if (valid_h) id_cd <= id_h;
            if (valid_cd) id_c <= id_cd;
            if (valid_c) id_fd <= id_c;
            if (valid_fd) id_f <= id_fd;
            if (valid_f) id_b <= id_f;
        end
    end

    generate
        if (MULTI_ENABLE) begin : gen_multi
            red_multi_run_engine #(
                .IMG_WIDTH(IMG_WIDTH), .IMG_HEIGHT(IMG_HEIGHT),
                .X_BITS(X_BITS), .Y_BITS(Y_BITS), .COUNT_BITS(COUNT_BITS),
                .MIN_PIXELS(MIN_PIXELS), .MIN_WIDTH(MIN_WIDTH), .MIN_HEIGHT(MIN_HEIGHT),
                .CANDIDATE_SLOTS(CANDIDATE_SLOTS), .MAX_TARGETS(MAX_TARGETS)
            ) u_engine (
                .I_clk(I_clk), .I_rst_n(I_rst_n), .I_clear(clear_m),
                .I_valid(valid_b), .I_start(start_b), .I_final(final_b),
                .I_hit(hit_b), .I_pixels(popcount_b),
                .I_xmin(xmin_b), .I_xmax(xmax_b), .I_y(y_b), .I_id(id_b),
                .O_ready(O_multi_ready), .O_valid(O_multi_valid), .O_hold(O_multi_hold),
                .O_boxes(O_multi_boxes), .O_shapes(O_multi_shapes), .O_frame_id(O_multi_frame_id),
                .O_overflow(O_multi_overflow)
            );
        end else if (SINGLE_SHAPE_ENABLE) begin : gen_single_shape
            red_single_shape_engine #(
                .IMG_WIDTH(IMG_WIDTH), .IMG_HEIGHT(IMG_HEIGHT),
                .X_BITS(X_BITS), .Y_BITS(Y_BITS), .COUNT_BITS(COUNT_BITS),
                .MIN_PIXELS(MIN_PIXELS), .MIN_WIDTH(MIN_WIDTH), .MIN_HEIGHT(MIN_HEIGHT)
            ) u_engine (
                .I_clk(I_clk), .I_rst_n(I_rst_n), .I_clear(clear_m),
                .I_valid(valid_b), .I_start(start_b), .I_final(final_b),
                .I_row_end(row_end_b), .I_hit(hit_b), .I_pixels(popcount_b),
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

// One selected-color silhouette per frame. This path deliberately has no
// component table, TopN selection, run FIFO, or inter-target pairing. Separate
// silhouettes share the union box; a split row or a disconnected row marks
// only the shape descriptor bad, so color detection still remains available.
module red_single_shape_engine #(
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
    input wire I_valid, I_start, I_final, I_row_end, I_hit,
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
    localparam integer COORD_BITS = (X_BITS > Y_BITS ? X_BITS : Y_BITS)+1;
    localparam integer MOM_BITS = COUNT_BITS+COORD_BITS;
    localparam integer MATCH_X = IMG_WIDTH/8 > 8 ? IMG_WIDTH/8 : 8;
    localparam integer MATCH_Y = IMG_HEIGHT/8 > 8 ? IMG_HEIGHT/8 : 8;
    localparam [1:0] CLASS_IDLE=0, CLASS_START=1, CLASS_WAIT=2;
    localparam integer RESULT_BITS = 10+1+1+1+2+48;

    // Reduce every physical row, including its last beat, before multiplying
    // its first moments. Four input pixels per clock never require a stall.
    reg source_open, source_continue, source_first_row, row_open, row_hit;
    reg [9:0] source_id;
    reg [X_BITS:0] row_pixels;
    reg [X_BITS-1:0] row_xmin, row_xmax;
    // After clear/reset, old beats can still be travelling through the mask
    // pipeline. Only a new SOF may reopen it. Geometry-only consecutive frames
    // remain accepted after a successfully observed final beat.
    wire begin_frame = I_start || (!source_open && source_continue);
    wire source_accept = I_valid && (source_open || begin_frame);
    wire fresh_row = begin_frame || !row_open;
    wire next_row_hit = (!fresh_row && row_hit) || I_hit;
    wire [X_BITS:0] next_row_pixels =
        (fresh_row ? {(X_BITS+1){1'b0}} : row_pixels) +
        (I_hit ? I_pixels : 3'd0);
    wire [X_BITS-1:0] next_row_xmin =
        fresh_row || !row_hit ? I_xmin :
        I_hit && I_xmin < row_xmin ? I_xmin : row_xmin;
    wire [X_BITS-1:0] next_row_xmax =
        fresh_row || !row_hit ? I_xmax :
        I_hit && I_xmax > row_xmax ? I_xmax : row_xmax;
    reg r0_valid, r0_first, r0_last, r0_hit;
    reg [9:0] r0_id;
    reg [X_BITS:0] r0_pixels;
    reg [X_BITS-1:0] r0_xmin, r0_xmax;
    reg [Y_BITS-1:0] r0_y;
    reg abort_0, abort_1, abort_done;
    reg [9:0] abort_id_0, abort_id_1, abort_id;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            source_open<=0; source_continue<=0; source_first_row<=1; source_id<=0;
            row_open<=0; row_hit<=0; row_pixels<=0; row_xmin<=0; row_xmax<=0;
            r0_valid<=0; r0_first<=0; r0_last<=0; r0_hit<=0;
            r0_id<=0; r0_pixels<=0; r0_xmin<=0; r0_xmax<=0; r0_y<=0;
            abort_0<=0; abort_1<=0; abort_done<=0;
            abort_id_0<=0; abort_id_1<=0; abort_id<=0;
        end else if (I_clear) begin
            source_open<=0; source_continue<=0; source_first_row<=1;
            row_open<=0; row_hit<=0; row_pixels<=0;
            r0_valid<=0; abort_0<=0; abort_1<=0; abort_done<=0;
        end else begin
            r0_valid<=0;
            abort_0<=0; abort_1<=abort_0; abort_done<=abort_1;
            abort_id_1<=abort_id_0; abort_id<=abort_id_1;
            if (source_accept) begin
                if (I_start && source_open) begin
                    abort_0<=1; abort_id_0<=source_id;
                end
                if (begin_frame) begin
                    source_open<=1; source_continue<=0;
                    source_id<=I_id; source_first_row<=1;
                end
                row_open<=1; row_hit<=next_row_hit;
                row_pixels<=next_row_pixels;
                row_xmin<=next_row_xmin; row_xmax<=next_row_xmax;
                if (I_row_end || I_final) begin
                    r0_valid<=1; r0_first<=begin_frame || source_first_row;
                    r0_last<=I_final; r0_hit<=next_row_hit;
                    r0_id<=begin_frame ? I_id : source_id;
                    r0_pixels<=next_row_pixels;
                    r0_xmin<=next_row_xmin; r0_xmax<=next_row_xmax; r0_y<=I_y;
                    source_first_row<=0; row_open<=0; row_hit<=0; row_pixels<=0;
                end
                if (I_final) begin source_open<=0; source_continue<=1; end
            end
        end
    end

    wire [X_BITS:0] r0_span =
        {1'b0,r0_xmax}-{1'b0,r0_xmin}+1'b1;
    wire [COORD_BITS-1:0] r0_xsum =
        {1'b0,r0_xmin}+{1'b0,r0_xmax};
    wire [COORD_BITS-1:0] r0_y2 = {r0_y,1'b0};
    reg r1_valid, r1_first, r1_last, r1_hit, r1_bad;
    reg [9:0] r1_id;
    reg [X_BITS:0] r1_pixels, r1_span;
    reg [X_BITS-1:0] r1_xmin, r1_xmax;
    reg [Y_BITS-1:0] r1_y;
    reg [MOM_BITS-1:0] r1_mx2, r1_my2;
    reg [COORD_BITS-1:0] r1_umin, r1_umax, r1_vmin, r1_vmax;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r1_valid<=0; r1_first<=0; r1_last<=0; r1_hit<=0; r1_bad<=0;
            r1_id<=0; r1_pixels<=0; r1_span<=0;
            r1_xmin<=0; r1_xmax<=0; r1_y<=0; r1_mx2<=0; r1_my2<=0;
            r1_umin<=0; r1_umax<=0; r1_vmin<=0; r1_vmax<=0;
        end else if (I_clear) begin
            r1_valid<=0;
        end else begin
            r1_valid<=r0_valid;
            if (r0_valid) begin
                r1_first<=r0_first; r1_last<=r0_last; r1_hit<=r0_hit;
                r1_id<=r0_id; r1_pixels<=r0_pixels; r1_span<=r0_span;
                r1_xmin<=r0_xmin; r1_xmax<=r0_xmax; r1_y<=r0_y;
                r1_bad<=r0_hit && (r0_pixels != r0_span ||
                    r0_xmin > r0_xmax || r0_xmax >= IMG_WIDTH || r0_y >= IMG_HEIGHT);
                r1_mx2<=r0_pixels*r0_xsum; r1_my2<=r0_pixels*r0_y2;
                r1_umin<={1'b0,r0_xmin}+r0_y;
                r1_umax<={1'b0,r0_xmax}+r0_y;
                r1_vmin<={1'b0,r0_xmin}+IMG_HEIGHT-r0_y;
                r1_vmax<={1'b0,r0_xmax}+IMG_HEIGHT-r0_y;
            end
        end
    end

    // The contour is identical to the component engine for one contiguous
    // interval on each occupied row: axial steps cost 8 and diagonals 11.
    reg work_seen, work_bad;
    reg [COUNT_BITS-1:0] work_area;
    reg [15:0] work_perimeter;
    reg [X_BITS-1:0] work_xmin, work_xmax, prev_xmin, prev_xmax;
    reg [Y_BITS-1:0] work_ymin, work_ymax, prev_y;
    reg [MOM_BITS-1:0] work_mx2, work_my2;
    reg [COORD_BITS-1:0] work_umin, work_umax, work_vmin, work_vmax;
    reg next_seen, next_bad;
    reg [COUNT_BITS-1:0] next_area;
    reg [15:0] next_perimeter;
    reg [X_BITS-1:0] next_xmin, next_xmax, next_prev_xmin, next_prev_xmax;
    reg [Y_BITS-1:0] next_ymin, next_ymax, next_prev_y;
    reg [MOM_BITS-1:0] next_mx2, next_my2;
    reg [COORD_BITS-1:0] next_umin, next_umax, next_vmin, next_vmax;
    wire [X_BITS-1:0] overlap_min = r1_xmin > prev_xmin ? r1_xmin : prev_xmin;
    wire [X_BITS-1:0] overlap_max = r1_xmax < prev_xmax ? r1_xmax : prev_xmax;
    wire [X_BITS:0] overlap_width = overlap_min <= overlap_max ?
        {1'b0,overlap_max}-{1'b0,overlap_min}+1'b1 : 0;
    wire [1:0] diagonal_steps =
        {1'b0,(r1_xmin != prev_xmin)}+{1'b0,(r1_xmax != prev_xmax)};
    wire linked_row = !r1_first && work_seen &&
        {1'b0,r1_y} == {1'b0,prev_y}+1'b1 && overlap_width != 0;
    wire [16:0] row_outline = ({{(16-X_BITS){1'b0}},r1_span}+17'd1)<<4;
    wire [16:0] shared_boundary = linked_row ?
        ({{(16-X_BITS){1'b0}},overlap_width}<<4)+diagonal_steps*17'd5 : 17'd0;
    wire [16:0] perimeter_sum =
        {1'b0,(r1_first ? 16'd0 : work_perimeter)}+row_outline-shared_boundary;
    wire [COUNT_BITS:0] area_sum =
        {1'b0,(r1_first ? {COUNT_BITS{1'b0}} : work_area)}+r1_pixels;
    always @* begin
        next_seen=r1_first ? 1'b0 : work_seen;
        next_bad=r1_first ? 1'b0 : work_bad;
        next_area=r1_first ? {COUNT_BITS{1'b0}} : work_area;
        next_perimeter=r1_first ? 16'd0 : work_perimeter;
        next_xmin=r1_first ? {X_BITS{1'b1}} : work_xmin;
        next_xmax=r1_first ? {X_BITS{1'b0}} : work_xmax;
        next_ymin=r1_first ? {Y_BITS{1'b1}} : work_ymin;
        next_ymax=r1_first ? {Y_BITS{1'b0}} : work_ymax;
        next_prev_xmin=prev_xmin; next_prev_xmax=prev_xmax; next_prev_y=prev_y;
        next_mx2=r1_first ? {MOM_BITS{1'b0}} : work_mx2;
        next_my2=r1_first ? {MOM_BITS{1'b0}} : work_my2;
        next_umin=r1_first ? {COORD_BITS{1'b1}} : work_umin;
        next_umax=r1_first ? {COORD_BITS{1'b0}} : work_umax;
        next_vmin=r1_first ? {COORD_BITS{1'b1}} : work_vmin;
        next_vmax=r1_first ? {COORD_BITS{1'b0}} : work_vmax;
        if (r1_hit) begin
            next_bad=next_bad || r1_bad || area_sum[COUNT_BITS] ||
                perimeter_sum[16] || (next_seen && !linked_row);
            next_area=area_sum[COUNT_BITS-1:0];
            next_perimeter=perimeter_sum[15:0];
            if (!next_seen || r1_xmin < next_xmin) next_xmin=r1_xmin;
            if (!next_seen || r1_xmax > next_xmax) next_xmax=r1_xmax;
            if (!next_seen || r1_y < next_ymin) next_ymin=r1_y;
            if (!next_seen || r1_y > next_ymax) next_ymax=r1_y;
            next_mx2=next_mx2+r1_mx2; next_my2=next_my2+r1_my2;
            if (!next_seen || r1_umin < next_umin) next_umin=r1_umin;
            if (!next_seen || r1_umax > next_umax) next_umax=r1_umax;
            if (!next_seen || r1_vmin < next_vmin) next_vmin=r1_vmin;
            if (!next_seen || r1_vmax > next_vmax) next_vmax=r1_vmax;
            next_prev_xmin=r1_xmin; next_prev_xmax=r1_xmax; next_prev_y=r1_y;
            next_seen=1;
        end
    end

    reg frame_done, snap_bad, snap_found;
    reg [9:0] snap_id;
    reg [COUNT_BITS-1:0] snap_area;
    reg [15:0] snap_perimeter;
    reg [X_BITS-1:0] snap_xmin, snap_xmax;
    reg [Y_BITS-1:0] snap_ymin, snap_ymax;
    reg [MOM_BITS-1:0] snap_mx2, snap_my2;
    reg [COORD_BITS-1:0] snap_umin, snap_umax, snap_vmin, snap_vmax;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            work_seen<=0; work_bad<=0; work_area<=0; work_perimeter<=0;
            work_xmin<=0; work_xmax<=0; work_ymin<=0; work_ymax<=0;
            prev_xmin<=0; prev_xmax<=0; prev_y<=0; work_mx2<=0; work_my2<=0;
            work_umin<=0; work_umax<=0; work_vmin<=0; work_vmax<=0;
            frame_done<=0; snap_bad<=0; snap_found<=0; snap_id<=0;
            snap_area<=0; snap_perimeter<=0; snap_xmin<=0; snap_xmax<=0;
            snap_ymin<=0; snap_ymax<=0; snap_mx2<=0; snap_my2<=0;
            snap_umin<=0; snap_umax<=0; snap_vmin<=0; snap_vmax<=0;
        end else if (I_clear) begin
            work_seen<=0; work_bad<=0; work_area<=0; work_perimeter<=0; frame_done<=0;
        end else begin
            frame_done<=0;
            if (r1_valid) begin
                work_seen<=next_seen; work_bad<=next_bad;
                work_area<=next_area; work_perimeter<=next_perimeter;
                work_xmin<=next_xmin; work_xmax<=next_xmax;
                work_ymin<=next_ymin; work_ymax<=next_ymax;
                prev_xmin<=next_prev_xmin; prev_xmax<=next_prev_xmax; prev_y<=next_prev_y;
                work_mx2<=next_mx2; work_my2<=next_my2;
                work_umin<=next_umin; work_umax<=next_umax;
                work_vmin<=next_vmin; work_vmax<=next_vmax;
                if (r1_last) begin
                    frame_done<=1; snap_id<=r1_id; snap_bad<=next_bad;
                    snap_found<=next_seen && next_area >= MIN_PIXELS &&
                        ({1'b0,next_xmax}-{1'b0,next_xmin}+1'b1 >= MIN_WIDTH) &&
                        ({1'b0,next_ymax}-{1'b0,next_ymin}+1'b1 >= MIN_HEIGHT);
                    snap_area<=next_area; snap_perimeter<=next_perimeter;
                    snap_xmin<=next_xmin; snap_xmax<=next_xmax;
                    snap_ymin<=next_ymin; snap_ymax<=next_ymax;
                    snap_mx2<=next_mx2; snap_my2<=next_my2;
                    snap_umin<=next_umin; snap_umax<=next_umax;
                    snap_vmin<=next_vmin; snap_vmax<=next_vmax;
                end
            end
        end
    end

    // EOF freezes one descriptor input bank. It changes only when frame_done
    // is raised, which cancels an older classifier before its result can be
    // published. Keep only the dispatched ID separately for that cancellation;
    // duplicating the entire snapshot as a second job bank is unnecessary.
    reg [1:0] class_state;
    reg [9:0] job_id;
    wire job_bad=snap_bad, job_found=snap_found;
    wire [COUNT_BITS-1:0] job_area=snap_area;
    wire [15:0] job_perimeter=snap_perimeter;
    wire [X_BITS-1:0] job_xmin=snap_xmin, job_xmax=snap_xmax;
    wire [Y_BITS-1:0] job_ymin=snap_ymin, job_ymax=snap_ymax;
    wire [MOM_BITS-1:0] job_mx2=snap_mx2, job_my2=snap_my2;
    wire [COORD_BITS-1:0] job_umin=snap_umin, job_umax=snap_umax,
        job_vmin=snap_vmin, job_vmax=snap_vmax;
    wire shape_ready, shape_circle_support;
    wire [1:0] shape_result;
    wire cancel_job = (abort_done || frame_done) && class_state != CLASS_IDLE;
    color_shape_descriptor #(
        .IMG_WIDTH(IMG_WIDTH),.IMG_HEIGHT(IMG_HEIGHT),.X_BITS(X_BITS),
        .Y_BITS(Y_BITS),.COUNT_BITS(COUNT_BITS),.COORD_BITS(COORD_BITS),
        .MOM_BITS(MOM_BITS),.STABLE_INPUTS(1)
    ) u_shape (
        .I_clk(I_clk),.I_rst_n(I_rst_n),.I_clear(I_clear || cancel_job),
        .I_start(class_state == CLASS_START),.I_bad(job_bad || !job_found),
        .I_area(job_area),.I_perimeter(job_perimeter),
        .I_xmin(job_xmin),.I_xmax(job_xmax),.I_ymin(job_ymin),.I_ymax(job_ymax),
        .I_mx2(job_mx2),.I_my2(job_my2),.I_umin(job_umin),.I_umax(job_umax),
        .I_vmin(job_vmin),.I_vmax(job_vmax),.O_ready(shape_ready),
        .O_shape(shape_result),.O_circle_support(shape_circle_support)
    );

    // One scalar track retains the existing two-frame confirmation, two-frame
    // miss hold, and independent shape confirmation/expiry. There is no array
    // search or assignment between multiple targets.
    reg track_occupied, track_confirmed;
    reg [X_BITS-1:0] track_xmin, track_xmax;
    reg [Y_BITS-1:0] track_ymin, track_ymax;
    reg [1:0] track_misses, track_shape, track_pending_shape;
    reg [1:0] track_shape_hits, track_shape_age;
    reg track_occupied_n, track_confirmed_n;
    reg [X_BITS-1:0] track_xmin_n, track_xmax_n;
    reg [Y_BITS-1:0] track_ymin_n, track_ymax_n;
    reg [1:0] track_misses_n, track_shape_n, track_pending_shape_n;
    reg [1:0] track_shape_hits_n, track_shape_age_n;
    wire [X_BITS:0] track_xsum={1'b0,track_xmin}+{1'b0,track_xmax};
    wire [X_BITS:0] job_xsum={1'b0,job_xmin}+{1'b0,job_xmax};
    wire [Y_BITS:0] track_ysum={1'b0,track_ymin}+{1'b0,track_ymax};
    wire [Y_BITS:0] job_ysum={1'b0,job_ymin}+{1'b0,job_ymax};
    wire [X_BITS:0] delta_x=track_xsum >= job_xsum ?
        track_xsum-job_xsum : job_xsum-track_xsum;
    wire [Y_BITS:0] delta_y=track_ysum >= job_ysum ?
        track_ysum-job_ysum : job_ysum-track_ysum;
    wire target_matches=track_occupied && job_found &&
        delta_x <= 2*MATCH_X && delta_y <= 2*MATCH_Y;
    wire [1:0] matched_shape=track_shape == 3 && shape_circle_support ?
        2'd3 : shape_result;
    always @* begin
        track_occupied_n=track_occupied; track_confirmed_n=track_confirmed;
        track_xmin_n=track_xmin; track_xmax_n=track_xmax;
        track_ymin_n=track_ymin; track_ymax_n=track_ymax;
        track_misses_n=track_misses; track_shape_n=track_shape;
        track_pending_shape_n=track_pending_shape;
        track_shape_hits_n=track_shape_hits; track_shape_age_n=track_shape_age;
        if (target_matches) begin
            track_confirmed_n=1; track_misses_n=0;
            track_xmin_n=job_xmin; track_xmax_n=job_xmax;
            track_ymin_n=job_ymin; track_ymax_n=job_ymax;
            if (matched_shape != 0 && matched_shape == track_shape) begin
                track_pending_shape_n=0; track_shape_hits_n=0; track_shape_age_n=0;
            end else if (matched_shape != 0 && matched_shape == track_pending_shape &&
                track_shape_hits != 0) begin
                track_shape_n=matched_shape; track_pending_shape_n=0;
                track_shape_hits_n=0; track_shape_age_n=0;
            end else begin
                track_pending_shape_n=matched_shape;
                track_shape_hits_n=matched_shape != 0 ? 1 : 0;
                if (track_shape_age < 2) track_shape_age_n=track_shape_age+1'b1;
                else begin track_shape_n=0; track_shape_age_n=2; end
            end
        end else begin
            if (track_occupied) begin
                if (!track_confirmed || track_misses == 2) begin
                    track_occupied_n=0; track_confirmed_n=0; track_misses_n=0;
                    track_shape_n=0; track_pending_shape_n=0;
                    track_shape_hits_n=0; track_shape_age_n=0;
                end else begin
                    track_misses_n=track_misses+1'b1;
                    track_pending_shape_n=0; track_shape_hits_n=0;
                    if (track_shape_age < 2) track_shape_age_n=track_shape_age+1'b1;
                    else begin track_shape_n=0; track_shape_age_n=2; end
                end
            end
            if (job_found && !track_occupied_n) begin
                track_occupied_n=1; track_confirmed_n=0; track_misses_n=0;
                track_xmin_n=job_xmin; track_xmax_n=job_xmax;
                track_ymin_n=job_ymin; track_ymax_n=job_ymax;
                track_shape_n=0; track_pending_shape_n=shape_result;
                track_shape_hits_n=shape_result != 0 ? 1 : 0; track_shape_age_n=0;
            end
        end
    end

    wire publish_valid=track_occupied_n && track_confirmed_n;
    wire [47:0] publish_box=publish_valid ?
        {{(12-Y_BITS){1'b0}},track_ymax_n,{(12-Y_BITS){1'b0}},track_ymin_n,
         {(12-X_BITS){1'b0}},track_xmax_n,{(12-X_BITS){1'b0}},track_xmin_n} : 48'd0;
    reg event_a_valid, event_b_valid;
    reg [RESULT_BITS-1:0] event_a, event_b;
    always @* begin
        event_a_valid=0; event_b_valid=0; event_a=0; event_b=0;
        if (abort_done) begin
            event_a_valid=1;
            if (class_state != CLASS_IDLE) begin
                // A new truncated source must not let an older, unfinished
                // classification revive a stale track. Preserve both IDs.
                event_a={job_id,1'b1,1'b0,1'b0,2'd0,48'd0};
                event_b_valid=1; event_b={abort_id,1'b0,1'b0,1'b0,2'd0,48'd0};
            end else event_a={abort_id,1'b0,1'b0,1'b0,2'd0,48'd0};
        end else if (frame_done && class_state != CLASS_IDLE) begin
            // Only malformed/sub-minimum-rate frames can overtake this
            // classifier. Report the old frame as invalid instead of mixing.
            event_a_valid=1; event_a={job_id,1'b1,1'b0,1'b0,2'd0,48'd0};
        end else if (class_state == CLASS_WAIT && shape_ready) begin
            event_a_valid=1;
            event_a={job_id,1'b0,publish_valid,
                (publish_valid && track_misses_n != 0),
                (publish_valid ? track_shape_n : 2'd0),publish_box};
        end
    end

    // Two result registers absorb the only possible two-result burst: an
    // interrupted classifier followed by the truncated source's invalid ID.
    // They are frame metadata, not a pixel/run FIFO or component storage.
    reg [RESULT_BITS-1:0] result_0, result_1, result_0_n, result_1_n;
    reg [1:0] result_count, result_count_n;
    always @* begin
        result_0_n=result_0; result_1_n=result_1;
        result_count_n=result_count;
        if (result_count != 0) begin
            result_0_n=result_1; result_count_n=result_count-1'b1;
        end
        if (event_a_valid) begin
            if (result_count_n == 0) result_0_n=event_a;
            else result_1_n=event_a;
            result_count_n=result_count_n+1'b1;
        end
        if (event_b_valid) begin
            if (result_count_n == 0) result_0_n=event_b;
            else result_1_n=event_b;
            result_count_n=result_count_n+1'b1;
        end
    end
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            class_state<=CLASS_IDLE; job_id<=0;
            track_occupied<=0; track_confirmed<=0; track_misses<=0;
            track_xmin<=0; track_xmax<=0; track_ymin<=0; track_ymax<=0;
            track_shape<=0; track_pending_shape<=0; track_shape_hits<=0; track_shape_age<=0;
            result_count<=0; result_0<=0; result_1<=0;
            O_ready<=0; O_valid<=0; O_hold<=0; O_boxes<=0;
            O_shapes<=0; O_frame_id<=0; O_overflow<=0;
        end else if (I_clear) begin
            class_state<=CLASS_IDLE; track_occupied<=0; track_confirmed<=0;
            track_misses<=0; track_shape<=0; track_pending_shape<=0;
            track_shape_hits<=0; track_shape_age<=0; result_count<=0;
            O_ready<=0; O_valid<=0; O_hold<=0; O_boxes<=0; O_shapes<=0; O_overflow<=0;
        end else begin
            result_0<=result_0_n; result_1<=result_1_n; result_count<=result_count_n;
            O_ready<=result_count != 0;
            if (result_count != 0) begin
                O_valid<=0; O_hold<=0; O_boxes<=0; O_shapes<=0;
                {O_frame_id,O_overflow,O_valid[0],O_hold[0],O_shapes[1:0],O_boxes[47:0]}
                    <=result_0;
            end
            if (abort_done) begin
                class_state<=CLASS_IDLE; track_occupied<=0; track_confirmed<=0;
                track_misses<=0; track_shape<=0; track_pending_shape<=0;
                track_shape_hits<=0; track_shape_age<=0;
            end else if (frame_done) begin
                class_state<=CLASS_START;
                job_id<=snap_id;
                if (class_state != CLASS_IDLE) begin
                    track_occupied<=0; track_confirmed<=0; track_misses<=0;
                    track_shape<=0; track_pending_shape<=0;
                    track_shape_hits<=0; track_shape_age<=0;
                end
            end else if (class_state == CLASS_START) begin
                class_state<=CLASS_WAIT;
            end else if (class_state == CLASS_WAIT && shape_ready) begin
                class_state<=CLASS_IDLE;
                track_occupied<=track_occupied_n; track_confirmed<=track_confirmed_n;
                track_xmin<=track_xmin_n; track_xmax<=track_xmax_n;
                track_ymin<=track_ymin_n; track_ymax<=track_ymax_n;
                track_misses<=track_misses_n; track_shape<=track_shape_n;
                track_pending_shape<=track_pending_shape_n;
                track_shape_hits<=track_shape_hits_n; track_shape_age<=track_shape_age_n;
            end
        end
    end
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
    parameter integer MIN_HEIGHT = 8,
    parameter integer CANDIDATE_SLOTS = 8,
    parameter integer MAX_TARGETS = 3
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
    // Supported capacities: 8/16 live components, 3/4 output tracks.
    // The upper RAM half holds the selected targets' shape features.
    localparam integer CAND_INDEX_BITS = $clog2(CANDIDATE_SLOTS);
    localparam integer CAND_ADDR_BITS = CAND_INDEX_BITS+1;
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

    reg [CANDIDATE_SLOTS-1:0] candidate_valid;
    reg [CAND_INDEX_BITS-1:0] scan_index, match_slot, free_slot;
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
    wire [CAND_INDEX_BITS-1:0] commit_slot=match_slot_valid ? match_slot : free_slot;
    wire top_write=state == S_TOP_WRITE &&
        (minimum_empty || cand_pixels > minimum_pixels);
    wire candidate_write=((state == S_COMMIT && commit_ok) || top_write) &&
        I_rst_n && !I_clear;
    wire [CAND_ADDR_BITS-1:0] candidate_waddr=top_write ?
        {1'b1,{(CAND_INDEX_BITS-2){1'b0}},minimum_slot} : {1'b0,commit_slot};
    wire retire_to_top=candidate_valid[scan_index] && candidate_qualified &&
        (state == S_EOF || (state == S_SCAN && candidate_expired));
    wire top_resume_scan=state == S_TOP_WRITE &&
        (return_state == S_SCAN_LOAD || return_state == S_EOF_LOAD);
    // Hold the retiring row on the synchronous RAM output while selecting
    // TopN. Otherwise prefetch the next live row in the normal scan cycle.
    wire candidate_read=(state == S_SCAN_REQ || state == S_EOF_REQ ||
        state == S_CLASS_REQ || top_resume_scan ||
        ((state == S_SCAN || state == S_EOF) && scan_index != CANDIDATE_SLOTS-1 &&
            !retire_to_top)) && I_rst_n && !I_clear;
    wire [CAND_ADDR_BITS-1:0] candidate_raddr=state == S_CLASS_REQ ?
        {1'b1,{(CAND_INDEX_BITS-2){1'b0}},class_index} :
        (state == S_SCAN_REQ || state == S_EOF_REQ) ? {CAND_ADDR_BITS{1'b0}} :
        top_resume_scan ? {1'b0,scan_index} : {1'b0,scan_index}+1'b1;
    // Live components occupy the lower half; TopN features the upper half.
    // The extra shallow rows fit in the same ERAM banks and replace a wide
    // resettable feature table plus its four-way read mux.
    wire [CAND_BITS-1:0] candidate_wdata=top_write ?
        {{(CAND_BITS-FEATURE_BITS){1'b0}},cand_perimeter,cand_shape_bad,cand_mx2,cand_my2,
            cand_umin,cand_umax,cand_vmin,cand_vmax} :
        {work_xmin,work_xmax,work_ymin,work_ymax,work_pixels,
            work_prev_valid,work_prev_min,work_prev_max,work_row_min,work_row_max,
            work_perimeter,work_shape_bad,work_mx2,work_my2,
            work_umin,work_umax,work_vmin,work_vmax};
    red_multi_small_ram #(.WIDTH(CAND_BITS), .DEPTH(2*CANDIDATE_SLOTS),
        .ADDR_BITS(CAND_ADDR_BITS)) u_candidates (
        .I_clk(I_clk), .I_write(candidate_write), .I_waddr(candidate_waddr),
        .I_data(candidate_wdata),
        .I_read(candidate_read), .I_raddr(candidate_raddr), .O_data(candidate_data)
    );

    reg [MAX_TARGETS-1:0] top_valid;
    reg [X_BITS-1:0] top_xmin [0:MAX_TARGETS-1], top_xmax [0:MAX_TARGETS-1];
    reg [Y_BITS-1:0] top_ymin [0:MAX_TARGETS-1], top_ymax [0:MAX_TARGETS-1];
    reg [COUNT_BITS-1:0] top_pixels [0:MAX_TARGETS-1];
    reg [1:0] top_shape [0:MAX_TARGETS-1], track_shape [0:MAX_TARGETS-1];
    reg [MAX_TARGETS-1:0] top_circle_support;
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
    reg [MAX_TARGETS-1:0] track_occupied, track_confirmed, matched_tracks, used_detections;
    reg [X_BITS-1:0] track_xmin [0:MAX_TARGETS-1], track_xmax [0:MAX_TARGETS-1];
    reg [Y_BITS-1:0] track_ymin [0:MAX_TARGETS-1], track_ymax [0:MAX_TARGETS-1];
    reg [1:0] track_misses [0:MAX_TARGETS-1];
    // Confirm a shape twice independently of the geometry confirmation.
    // Count every frame without support for the stable class, so alternating
    // wrong/unknown classes cannot keep an obsolete label indefinitely.
    reg [1:0] track_pending_shape [0:MAX_TARGETS-1], track_shape_hits [0:MAX_TARGETS-1];
    reg [1:0] track_shape_age [0:MAX_TARGETS-1];
    reg [1:0] pair_track, pair_detection;
    reg [1:0] best_track, best_detection, track_index;
    reg best_valid;
    reg [13:0] best_distance;
    // A confirmed circle may use the weaker, current-frame circle evidence.
    // This is feature hysteresis, not an unconditional extension of label age.
    wire [1:0] matched_shape=(track_shape[best_track] == 3 &&
        top_circle_support[best_detection]) ? 2'd3 : top_shape[best_detection];
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
    wire [3:0] occupied_slots={{(4-MAX_TARGETS){1'b1}},track_occupied};
    wire [1:0] empty_track=!occupied_slots[0] ? 0 :
        !occupied_slots[1] ? 1 : !occupied_slots[2] ? 2 : 3;
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
            pair_track<=0; pair_detection<=0;
            best_track<=0; best_detection<=0; track_index<=0;
            best_valid<=0; best_distance<=0;
            O_ready<=0; O_valid<=0; O_hold<=0; O_boxes<=0; O_shapes<=0; O_frame_id<=0; O_overflow<=0;
            for (slot=0; slot<MAX_TARGETS; slot=slot+1) begin
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
            for (slot=0; slot<MAX_TARGETS; slot=slot+1) begin
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
                            for (slot=0; slot<MAX_TARGETS; slot=slot+1) begin
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
                        for (slot=0; slot<MAX_TARGETS; slot=slot+1) begin
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
                    state<=scan_index == CANDIDATE_SLOTS-1 ? S_COMMIT : S_SCAN_LOAD;
                    if (!candidate_valid[scan_index]) begin
                        if (!free_slot_valid) begin free_slot_valid<=1; free_slot<=scan_index; end
                    end else if (candidate_expired) begin
                        candidate_valid[scan_index]<=0;
                        if (!free_slot_valid) begin free_slot_valid<=1; free_slot<=scan_index; end
                        if (candidate_qualified) begin
                            top_index<=0;
                            minimum_empty<=0; minimum_pixels<={COUNT_BITS{1'b1}};
                            return_state<=scan_index == CANDIDATE_SLOTS-1 ? S_COMMIT : S_SCAN_LOAD;
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
                    state<=scan_index == CANDIDATE_SLOTS-1 ? S_CLASS_REQ : S_EOF_LOAD;
                    class_index<=0;
                    if (candidate_valid[scan_index] && candidate_qualified) begin
                        top_index<=0;
                        minimum_empty<=0; minimum_pixels<={COUNT_BITS{1'b1}};
                        return_state<=scan_index == CANDIDATE_SLOTS-1 ? S_CLASS_REQ : S_EOF_LOAD;
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
                    if (top_index == MAX_TARGETS-1) state<=S_TOP_WRITE;
                    else top_index<=top_index+1'b1;
                end
                S_TOP_WRITE: begin
                    // The RAM output is held throughout TopN selection.
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
                        if (class_index == MAX_TARGETS-1) state<=S_TRACK_INIT;
                        else begin class_index<=class_index+1'b1; state<=S_CLASS_REQ; end
                    end
                end
                S_CLASS_WAIT: if (shape_ready) begin
                    top_shape[class_index]<=shape_result;
                    top_circle_support[class_index]<=shape_circle_support;
                    if (class_index == MAX_TARGETS-1) state<=S_TRACK_INIT;
                    else begin class_index<=class_index+1'b1; state<=S_CLASS_REQ; end
                end
                S_TRACK_INIT: begin
                    matched_tracks<=0; used_detections<=0; pair_track<=0; pair_detection<=0;
                    best_valid<=0; best_distance<=14'h3fff;
                    state<=S_TRACK_SCAN;
                end
                S_TRACK_SCAN: begin
                    if (pair_eligible && (!best_valid || pair_distance < best_distance)) begin
                        best_valid<=1; best_distance<=pair_distance;
                        best_track<=pair_track; best_detection<=pair_detection;
                    end
                    if (pair_detection == MAX_TARGETS-1) begin
                        pair_detection<=0;
                        if (pair_track == MAX_TARGETS-1) state<=S_TRACK_APPLY;
                        else pair_track<=pair_track+1'b1;
                    end else pair_detection<=pair_detection+1'b1;
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
                        best_valid<=0; best_distance<=14'h3fff; pair_track<=0; pair_detection<=0;
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
                    if (track_index == MAX_TARGETS-1) begin track_index<=0; state<=S_NEW; end
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
                    if (track_index == MAX_TARGETS-1) state<=S_PUBLISH;
                    else track_index<=track_index+1'b1;
                end
                S_PUBLISH: begin
                    O_ready<=1; O_frame_id<=context_id; O_overflow<=0;
                    O_valid<=track_occupied & track_confirmed;
                    O_hold<=0; O_boxes<=0; O_shapes<=0;
                    for (slot=0; slot<MAX_TARGETS; slot=slot+1) begin
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
                    for (slot=0; slot<MAX_TARGETS; slot=slot+1) begin
                        track_shape[slot]<=0; track_pending_shape[slot]<=0;
                        track_shape_hits[slot]<=0; track_shape_age[slot]<=0;
                    end
                end
            endcase
        end
    end
endmodule

// Shared once per selected result, outside the pixel-rate path. Q3 contour length
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
    localparam [4:0] IDLE=0,MULTIPLY=1,UPPER_DONE=2,LOWER_DONE=3,
        AREA25_DONE=4,CHECK_METRICS=5,CIRCLE_X_DONE=6,
        CIRCLE_X_CHECK=7,CIRCLE_U_DONE=8,CIRCLE_U_CHECK=9,
        CENTER_START=10,CENTER_DONE=11,SPAN_START=12,SPAN_DONE=13,
        SKEW_CHECK=14,FINISH=15;
    localparam integer DEV_BITS =
        (MOM_BITS+2 > COUNT_BITS+COORD_BITS+2) ?
        MOM_BITS+2 : COUNT_BITS+COORD_BITS+2;
    localparam integer AREA_SCALE_BITS = COUNT_BITS+12;
    localparam integer PRODUCT_BITS =
        AREA_SCALE_BITS > 32 ? AREA_SCALE_BITS : 32;
    localparam integer MATH_BITS =
        DEV_BITS+4 > PRODUCT_BITS ? DEV_BITS+4 : PRODUCT_BITS;
    // Keep the original modulo-MATH_BITS arithmetic, but carry only one
    // thirteen-bit limb through the shared arithmetic/compare units per clock.
    localparam integer LIMB_BITS = 13;
    localparam integer LIMBS = (MATH_BITS+LIMB_BITS-1)/LIMB_BITS;
    localparam integer LIMB_INDEX_BITS = LIMBS > 1 ? $clog2(LIMBS) : 1;
    localparam integer PAD_BITS = LIMBS*LIMB_BITS;
    // All multiplier sources are at most 16 bits or an absolute projected
    // centre (COORD_BITS+2 bits). Preserve the old 32-bit input truncation.
    localparam integer MULTIPLIER_BITS =
        COORD_BITS+2 > 32 ? 32 : (COORD_BITS+2 > 16 ? COORD_BITS+2 : 16);
    localparam integer MULTIPLY_GROUPS = (MULTIPLIER_BITS+2)/2;

    reg [4:0] state,multiply_return;
    reg [5:0] multiply_count;
    reg [MATH_BITS-1:0] multiplicand,product,deviation;
    reg [MULTIPLIER_BITS+2:0] multiplier;
    reg [LIMB_INDEX_BITS-1:0] limb_index;
    reg arithmetic_carry,compare_right_carry,compare_carry,compare_equal;
    // Exact unsigned bounds: P*P fits 32 bits; A*1216, A*864 and
    // A*25 need COUNT_BITS+11, +10 and +5 bits respectively.
    reg [31:0] perimeter_squared;
    reg [COUNT_BITS+10:0] metric_upper;
    reg [COUNT_BITS+9:0] metric_lower;
    reg [COUNT_BITS+4:0] area25;
    reg [3:0] check_index;
    reg [COUNT_BITS-1:0] saved_area;
    reg [X_BITS-1:0] saved_xmin,saved_xmax;
    reg [Y_BITS-1:0] saved_ymin,saved_ymax;
    reg [MOM_BITS-1:0] saved_mx2,saved_my2;
    reg [COORD_BITS-1:0] saved_umin,saved_umax,saved_vmin,saved_vmax;

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
    reg circle_fill,circle_support,square_fill,square_spans_ok;
    reg center_negative;
    reg signed [MATH_BITS-1:0] moment;
    reg [COORD_BITS:0] saved_span;
    wire [MATH_BITS-1:0] area_wide={{(MATH_BITS-COUNT_BITS){1'b0}},area};
    // Candidate RAM no longer feeds a difference and a wide comparison in
    // the same clock. Capture the exact original spans on the start edge.
    reg [COORD_BITS:0] width,height,u_span,v_span;
    wire [COORD_BITS+4:0] w8={width,3'b0},h8={height,3'b0};
    wire [COORD_BITS+4:0] u8={u_span,3'b0},v8={v_span,3'b0};
    wire [COORD_BITS+1:0] width_quarter=width+(width>>2);
    wire [COORD_BITS+1:0] height_quarter=height+(height>>2);
    localparam integer OFFSET_BITS=COORD_BITS+2 > 5 ? COORD_BITS+2 : 5;
    wire [OFFSET_BITS-1:0] u_plus16={1'b0,u_span}+16;
    wire [OFFSET_BITS-1:0] v_plus16={1'b0,v_span}+16;

    reg signed [COORD_BITS+1:0] projection_center;
    reg [COORD_BITS-1:0] projection_min,projection_max;
    reg [COORD_BITS:0] projection_span;
    wire [31:0] center_magnitude=projection_center<0 ?
        -projection_center : projection_center;
    wire projection_subtract=projection==3;
    wire booth_zero=multiplier[2:0]==3'b000 || multiplier[2:0]==3'b111;
    wire booth_double=multiplier[2:0]==3'b011 || multiplier[2:0]==3'b100;
    wire booth_negative=multiplier[2];
    wire [MATH_BITS-1:0] booth_operand=booth_double ?
        multiplicand<<1 : multiplicand;

    reg [MATH_BITS-1:0] compare_left_base,compare_left_extra;
    reg [MATH_BITS-1:0] compare_right_base,compare_right_extra;
    reg [MATH_BITS-1:0] arithmetic_left,arithmetic_right;
    reg arithmetic_initial_carry;
    // Constant slices avoid a barrel shifter for index*13. An out-of-range
    // index still selects zero, matching the original unsigned right shift.
    function [LIMB_BITS-1:0] select_limb;
        input [MATH_BITS-1:0] value;
        input [LIMB_INDEX_BITS-1:0] index;
        integer part;
        begin
            select_limb=0;
            for(part=0;part<LIMBS;part=part+1)
                select_limb=select_limb |
                    ((value>>(part*LIMB_BITS)) & {LIMB_BITS{index==part}});
        end
    endfunction
    wire [LIMB_BITS-1:0] arithmetic_left_limb=
        select_limb(arithmetic_left,limb_index);
    wire [LIMB_BITS-1:0] arithmetic_right_limb=
        select_limb(arithmetic_right,limb_index);
    wire [LIMB_BITS:0] arithmetic_sum=
        {1'b0,arithmetic_left_limb}+{1'b0,arithmetic_right_limb}+
        (limb_index==0 ? arithmetic_initial_carry : arithmetic_carry);
    wire [LIMB_BITS-1:0] compare_right_base_limb=
        select_limb(compare_right_base,limb_index);
    wire [LIMB_BITS-1:0] compare_right_extra_limb=
        select_limb(compare_right_extra,limb_index);
    wire [LIMB_BITS:0] compare_right_sum=
        {1'b0,compare_right_base_limb}+{1'b0,compare_right_extra_limb}+
        (limb_index==0 ? 1'b0 : compare_right_carry);
    // The last limb is padded with zeroes after each side's addition, so
    // overflow is discarded at exactly MATH_BITS, including malformed inputs.
    wire [LIMB_BITS-1:0] limb_mask=limb_index==LIMBS-1 ?
        {LIMB_BITS{1'b1}}>>(PAD_BITS-MATH_BITS) : {LIMB_BITS{1'b1}};
    wire [LIMB_BITS-1:0] compare_left_limb=
        arithmetic_sum[LIMB_BITS-1:0]&limb_mask;
    wire [LIMB_BITS-1:0] compare_right_limb=
        compare_right_sum[LIMB_BITS-1:0]&limb_mask;
    wire [LIMB_BITS:0] compare_difference=
        {1'b0,compare_right_limb}+{1'b0,~compare_left_limb}+
        (limb_index==0 ? 1'b1 : compare_carry);
    wire comparison_equal=(limb_index==0 || compare_equal) &&
        compare_left_limb==compare_right_limb;
    wire comparison_le=compare_difference[LIMB_BITS];
    wire comparison_lt=comparison_le && !comparison_equal;

    // The same limb adder handles Booth accumulation, projected first moments,
    // signed deviation, absolute value, and the left side of every comparison.
    always @* begin
        arithmetic_left=compare_left_base;
        arithmetic_right=compare_left_extra;
        arithmetic_initial_carry=0;
        case(state)
            MULTIPLY:begin
                arithmetic_left=product;
                arithmetic_right=booth_operand ^ {MATH_BITS{booth_negative}};
                arithmetic_initial_carry=booth_negative;
            end
            CENTER_START:begin
                arithmetic_left={{(MATH_BITS-MOM_BITS){1'b0}},mx2};
                arithmetic_right=0;
                if(projection==1)
                    arithmetic_left={{(MATH_BITS-MOM_BITS){1'b0}},my2};
                else if(projection>=2) begin
                    arithmetic_right={{(MATH_BITS-MOM_BITS){1'b0}},my2} ^
                        {MATH_BITS{projection_subtract}};
                    arithmetic_initial_carry=projection_subtract;
                end
            end
            CENTER_DONE:begin
                arithmetic_left=moment;
                arithmetic_right=product ^ {MATH_BITS{!center_negative}};
                arithmetic_initial_carry=!center_negative;
            end
            SPAN_START:begin
                arithmetic_left=0;
                arithmetic_right=deviation ^ {MATH_BITS{deviation[MATH_BITS-1]}};
                arithmetic_initial_carry=deviation[MATH_BITS-1];
            end
        endcase
    end
    always @* begin
        compare_left_base=0;compare_left_extra=0;
        compare_right_base=0;compare_right_extra=0;
        case(state)
            CHECK_METRICS:case(check_index)
                0:begin compare_left_base=perimeter_squared;compare_right_base=metric_upper;end
                1:begin compare_left_base=metric_lower;compare_right_base=perimeter_squared;end
                2:begin compare_left_base=perimeter_squared;compare_right_base=metric_upper;end
                3:begin compare_left_base=metric_upper;compare_right_base=perimeter_squared;end
                4:begin compare_left_base=perimeter_squared;compare_right_base=area_wide<<12;end
                5:begin compare_left_base=w8;compare_right_base=h8;compare_right_extra=height;end
                6:begin compare_left_base=h8;compare_right_base=w8;compare_right_extra=width;end
                7:begin compare_left_base=u8;compare_right_base=v8;compare_right_extra=v_span;end
                8:begin compare_left_base=v8;compare_right_base=u8;compare_right_extra=u_span;end
                9:begin compare_left_base=w8;compare_right_base=h8;
                        compare_right_extra=height_quarter;end
                10:begin compare_left_base=h8;compare_right_base=w8;
                         compare_right_extra=width_quarter;end
                11:begin compare_left_base=u8;compare_right_base=v8;
                         compare_right_extra=v_plus16;end
                default:begin compare_left_base=v8;compare_right_base=u8;
                              compare_right_extra=u_plus16;end
            endcase
            CIRCLE_X_CHECK,CIRCLE_U_CHECK:case(check_index)
                0:begin compare_left_base=product<<4;compare_left_extra=product<<1;
                        compare_right_base=state==CIRCLE_X_CHECK ? area25 : area25<<1;end
                1:begin compare_left_base=product<<4;compare_left_extra=product;
                        compare_right_base=state==CIRCLE_X_CHECK ? area25 : area25<<1;end
                default:begin compare_left_base=state==CIRCLE_X_CHECK ? area25 : area25<<1;
                              compare_right_base=product<<4;end
            endcase
            SPAN_DONE:begin compare_left_base=deviation<<3;compare_right_base=product;end
            SKEW_CHECK:begin compare_left_base=product;compare_right_base=deviation<<3;
                             compare_right_extra=deviation<<2;end
        endcase
    end

    always @* begin
        case (projection)
            0: begin
                projection_min=xmin; projection_max=xmax;
                projection_span=width;
            end
            1: begin
                projection_min=ymin; projection_max=ymax;
                projection_span=height;
            end
            2: begin
                projection_min=umin; projection_max=umax;
                projection_span=u_span;
            end
            default: begin
                projection_min=vmin; projection_max=vmax;
                projection_span=v_span;
            end
        endcase
        projection_center=$signed({1'b0,projection_min})+
            $signed({1'b0,projection_max})-(projection==3 ? 2*IMG_HEIGHT : 0);
    end

    integer arithmetic_bit;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            state<=IDLE;multiply_return<=IDLE;multiply_count<=0;
            limb_index<=0;arithmetic_carry<=0;
            compare_right_carry<=0;compare_carry<=0;compare_equal<=0;
            multiplicand<=0;multiplier<=0;product<=0;deviation<=0;
            perimeter_squared<=0;metric_upper<=0;metric_lower<=0;area25<=0;
            check_index<=0;
            saved_area<=0;saved_xmin<=0;saved_xmax<=0;saved_ymin<=0;saved_ymax<=0;
            saved_mx2<=0;saved_my2<=0;saved_umin<=0;saved_umax<=0;
            saved_vmin<=0;saved_vmax<=0;
            projection<=0;isotropic<=0;centered<=0;skew<=0;
            circle_metric<=0;square_metric<=0;triangle_metric<=0;
            circle_fill<=0;circle_support<=0;square_fill<=0;square_spans_ok<=0;
            moment<=0;center_negative<=0;saved_span<=0;
            width<=0;height<=0;u_span<=0;v_span<=0;
            O_ready<=0;O_shape<=0;O_circle_support<=0;
        end else if (I_clear) begin
            state<=IDLE;limb_index<=0;O_ready<=0;O_shape<=0;O_circle_support<=0;
        end else begin
            O_ready<=0;
            case(state)
                IDLE:if(I_start) begin
                    O_shape<=0;O_circle_support<=0;
                    if(I_bad || I_area==0 || I_xmin<=3 || I_ymin<=3 ||
                       I_xmax>=IMG_WIDTH-4 || I_ymax>=IMG_HEIGHT-4 ||
                       I_xmax-I_xmin<11 || I_ymax-I_ymin<11) O_ready<=1;
                    else begin
                        if(!STABLE_INPUTS) begin
                            saved_area<=I_area;saved_xmin<=I_xmin;saved_xmax<=I_xmax;
                            saved_ymin<=I_ymin;saved_ymax<=I_ymax;
                            saved_mx2<=I_mx2;saved_my2<=I_my2;
                            saved_umin<=I_umin;saved_umax<=I_umax;
                            saved_vmin<=I_vmin;saved_vmax<=I_vmax;
                        end
                        width<={1'b0,I_xmax}-{1'b0,I_xmin}+1'b1;
                        height<={1'b0,I_ymax}-{1'b0,I_ymin}+1'b1;
                        u_span<={1'b0,I_umax}-{1'b0,I_umin}+1'b1;
                        v_span<={1'b0,I_vmax}-{1'b0,I_vmin}+1'b1;
                        multiplicand<={{(MATH_BITS-16){1'b0}},I_perimeter};
                        multiplier<={I_perimeter,1'b0};product<=0;multiply_count<=0;
                        limb_index<=0;
                        multiply_return<=UPPER_DONE;state<=MULTIPLY;
                    end
                end
                MULTIPLY:begin
                    if(!booth_zero) begin
                        for(arithmetic_bit=0;arithmetic_bit<MATH_BITS;arithmetic_bit=arithmetic_bit+1)
                            if(arithmetic_bit/LIMB_BITS==limb_index)
                                product[arithmetic_bit]<=arithmetic_sum[arithmetic_bit%LIMB_BITS];
                        arithmetic_carry<=arithmetic_sum[LIMB_BITS];
                    end
                    if(booth_zero || limb_index==LIMBS-1) begin
                        multiplicand<=multiplicand<<2;multiplier<=multiplier>>2;
                        multiply_count<=multiply_count+1'b1;limb_index<=0;
                        if(multiply_count==MULTIPLY_GROUPS-1) state<=multiply_return;
                    end else limb_index<=limb_index+1'b1;
                end
                UPPER_DONE:begin
                    perimeter_squared<=product;
                    multiplicand<=area_wide;multiplier<={32'd1216,1'b0};
                    product<=0;multiply_count<=0;multiply_return<=LOWER_DONE;
                    state<=MULTIPLY;
                end
                LOWER_DONE:begin
                    metric_upper<=product;
                    multiplicand<=area_wide;multiplier<={32'd864,1'b0};
                    product<=0;multiply_count<=0;multiply_return<=AREA25_DONE;
                    state<=MULTIPLY;
                end
                AREA25_DONE:begin
                    metric_lower<=product;
                    multiplicand<=area_wide;multiplier<={32'd25,1'b0};
                    product<=0;multiply_count<=0;multiply_return<=CHECK_METRICS;
                    state<=MULTIPLY;
                    check_index<=0;circle_metric<=0;square_metric<=1;
                    triangle_metric<=1;isotropic<=1;square_spans_ok<=1;
                    centered<=1;skew<=0;projection<=0;
                end
                CHECK_METRICS:begin
                    if(check_index==0) area25<=product;
                    arithmetic_carry<=arithmetic_sum[LIMB_BITS];
                    compare_right_carry<=compare_right_sum[LIMB_BITS];
                    compare_carry<=compare_difference[LIMB_BITS];compare_equal<=comparison_equal;
                    if(limb_index==LIMBS-1) begin
                        limb_index<=0;
                        case(check_index)
                            0:circle_metric<=comparison_le;
                            1:square_metric<=square_metric && comparison_le;
                            2:square_metric<=square_metric && comparison_le;
                            3:triangle_metric<=triangle_metric && comparison_lt;
                            4:triangle_metric<=triangle_metric && comparison_le;
                            5,6,7,8:isotropic<=isotropic && comparison_le;
                            default:square_spans_ok<=square_spans_ok && comparison_le;
                        endcase
                        if(check_index==12) begin
                            multiplicand<=width;multiplier<={height,1'b0};
                            product<=0;multiply_count<=0;multiply_return<=CIRCLE_X_DONE;
                            state<=MULTIPLY;
                        end else check_index<=check_index+1'b1;
                    end else limb_index<=limb_index+1'b1;
                end
                CIRCLE_X_DONE:begin check_index<=0;state<=CIRCLE_X_CHECK;end
                CIRCLE_X_CHECK:begin
                    arithmetic_carry<=arithmetic_sum[LIMB_BITS];
                    compare_right_carry<=compare_right_sum[LIMB_BITS];
                    compare_carry<=compare_difference[LIMB_BITS];compare_equal<=comparison_equal;
                    if(limb_index==LIMBS-1) begin
                        limb_index<=0;
                        case(check_index)
                            0:circle_fill<=comparison_le;
                            1:circle_support<=comparison_le;
                            default:square_fill<=comparison_le;
                        endcase
                        if(check_index==2) begin
                            multiplicand<=u_span;multiplier<={v_span,1'b0};
                            product<=0;multiply_count<=0;multiply_return<=CIRCLE_U_DONE;
                            state<=MULTIPLY;
                        end else check_index<=check_index+1'b1;
                    end else limb_index<=limb_index+1'b1;
                end
                CIRCLE_U_DONE:begin check_index<=0;state<=CIRCLE_U_CHECK;end
                CIRCLE_U_CHECK:begin
                    arithmetic_carry<=arithmetic_sum[LIMB_BITS];
                    compare_right_carry<=compare_right_sum[LIMB_BITS];
                    compare_carry<=compare_difference[LIMB_BITS];compare_equal<=comparison_equal;
                    if(limb_index==LIMBS-1) begin
                        limb_index<=0;
                        case(check_index)
                            0:circle_fill<=circle_fill && comparison_le;
                            1:circle_support<=circle_support && comparison_le;
                            default:square_fill<=square_fill || comparison_le;
                        endcase
                        if(check_index==2) state<=CENTER_START;
                        else check_index<=check_index+1'b1;
                    end else limb_index<=limb_index+1'b1;
                end
                CENTER_START:begin
                    for(arithmetic_bit=0;arithmetic_bit<MATH_BITS;arithmetic_bit=arithmetic_bit+1)
                        if(arithmetic_bit/LIMB_BITS==limb_index)
                            moment[arithmetic_bit]<=arithmetic_sum[arithmetic_bit%LIMB_BITS];
                    arithmetic_carry<=arithmetic_sum[LIMB_BITS];
                    if(limb_index==LIMBS-1) begin
                        limb_index<=0;multiplicand<=area_wide;
                        multiplier<={center_magnitude,1'b0};
                        product<=0;multiply_count<=0;multiply_return<=CENTER_DONE;
                        center_negative<=projection_center<0;saved_span<=projection_span;
                        state<=MULTIPLY;
                    end else limb_index<=limb_index+1'b1;
                end
                CENTER_DONE:begin
                    for(arithmetic_bit=0;arithmetic_bit<MATH_BITS;arithmetic_bit=arithmetic_bit+1)
                        if(arithmetic_bit/LIMB_BITS==limb_index)
                            deviation[arithmetic_bit]<=arithmetic_sum[arithmetic_bit%LIMB_BITS];
                    arithmetic_carry<=arithmetic_sum[LIMB_BITS];
                    if(limb_index==LIMBS-1) begin limb_index<=0;state<=SPAN_START;end
                    else limb_index<=limb_index+1'b1;
                end
                SPAN_START:begin
                    for(arithmetic_bit=0;arithmetic_bit<MATH_BITS;arithmetic_bit=arithmetic_bit+1)
                        if(arithmetic_bit/LIMB_BITS==limb_index)
                            deviation[arithmetic_bit]<=arithmetic_sum[arithmetic_bit%LIMB_BITS];
                    arithmetic_carry<=arithmetic_sum[LIMB_BITS];
                    if(limb_index==LIMBS-1) begin
                        limb_index<=0;multiplicand<=area_wide;multiplier<={saved_span,1'b0};
                        product<=0;multiply_count<=0;multiply_return<=SPAN_DONE;
                        state<=MULTIPLY;
                    end else limb_index<=limb_index+1'b1;
                end
                SPAN_DONE:begin
                    arithmetic_carry<=arithmetic_sum[LIMB_BITS];
                    compare_right_carry<=compare_right_sum[LIMB_BITS];
                    compare_carry<=compare_difference[LIMB_BITS];compare_equal<=comparison_equal;
                    if(limb_index==LIMBS-1) begin
                        limb_index<=0;centered<=centered && comparison_le;state<=SKEW_CHECK;
                    end else limb_index<=limb_index+1'b1;
                end
                SKEW_CHECK:begin
                    arithmetic_carry<=arithmetic_sum[LIMB_BITS];
                    compare_right_carry<=compare_right_sum[LIMB_BITS];
                    compare_carry<=compare_difference[LIMB_BITS];compare_equal<=comparison_equal;
                    if(limb_index==LIMBS-1) begin
                        limb_index<=0;skew<=skew || comparison_le;
                        if(projection==3) state<=FINISH;
                        else begin projection<=projection+1'b1;state<=CENTER_START;end
                    end else limb_index<=limb_index+1'b1;
                end
                FINISH:begin
                    O_circle_support<=isotropic && centered && circle_metric && circle_support;
                    if(isotropic && centered && circle_metric && circle_fill) O_shape<=3;
                    else if((isotropic || (square_spans_ok && square_fill)) &&
                        centered && square_metric && !circle_fill) O_shape<=1;
                    else if(skew && triangle_metric) O_shape<=2;
                    else O_shape<=0;
                    O_ready<=1;state<=IDLE;
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
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
