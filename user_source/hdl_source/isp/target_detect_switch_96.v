// Both detectors run continuously, so entering motion mode has a reference
// immediately. A synchronized request commits at SOF. Completion carries the
// mode captured at the last pixel, even if the next SOF precedes publication.
module target_detect_switch_96 #(
    parameter integer IMG_WIDTH = 1280,
    parameter integer IMG_HEIGHT = 720,
    parameter integer RED_MIN_PIXELS = 128,
    parameter integer DIFF_THRESHOLD = 10,
    parameter integer MIN_BLOCKS = 12,
    parameter integer GLOBAL_CHANGE_PERCENT = 40,
    parameter integer MOTION_STABLE_ENABLE = 1,
    parameter integer RED_MULTI_ENABLE = 0,
    parameter integer SINGLE_SHAPE_ENABLE = 0
) (
    input wire I_clk,
    input wire I_rst_n,
    input wire I_motion_mode_async,
    input wire [1:0] I_color_mode_async,
    input wire [11:0] I_effect_config,
    input wire I_tuser,
    input wire I_tlast,
    input wire I_tvalid,
    input wire [95:0] I_tdata,
    input wire [9:0] I_frame_id,
    output wire O_result_ready,
    output wire O_found,
    output wire [11:0] O_xmin,
    output wire [11:0] O_xmax,
    output wire [11:0] O_ymin,
    output wire [11:0] O_ymax,
    output wire [11:0] O_center_x,
    output wire [11:0] O_center_y,
    output wire [23:0] O_pixels,
    output wire O_frame_toggle,
    output wire O_target_motion_mode,
    output wire [1:0] O_target_color_mode,
    output wire O_motion_mode_active,
    output wire [1:0] O_color_mode_active,
    output wire [9:0] O_result_frame_id,
    output wire [3:0] O_multi_valid,
    output wire [3:0] O_multi_hold,
    output wire [191:0] O_multi_boxes,
    output wire [7:0] O_multi_shapes,
    output wire [3:0] O_mask_pixels,
    output wire O_multi_overflow
);
    localparam integer FRAME_BEATS = IMG_WIDTH * IMG_HEIGHT / 4;
    localparam integer COUNT_BITS = $clog2(FRAME_BEATS);
    (* keep="true" *) reg [1:0] color_meta, color_sync;
    reg [1:0] color_sync_d;
    reg active_motion, completion_motion;
    reg [1:0] active_color, completion_color;
    reg [3:0] active_mask_view_mode;
    reg user_d, frame_pending, frame_open;
    reg [COUNT_BITS-1:0] beat_count;
    wire frame_marker = I_tuser && !user_d;
    wire [1:0] active_mode = active_motion ? 2'b11 : active_color;
    wire [1:0] frame_mode = color_sync == color_sync_d ? color_sync : active_mode;
    wire first_beat = frame_marker || frame_pending;
    wire accept_beat = I_tvalid && (frame_open || first_beat);
    wire final_beat = !first_beat && beat_count == FRAME_BEATS-1;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            color_meta <= 0; color_sync <= 0; color_sync_d <= 0;
            active_motion <= 0; completion_motion <= 0;
            active_color <= 0; completion_color <= 0;
            active_mask_view_mode <= 0;
            user_d <= 0; frame_pending <= 0; frame_open <= 0; beat_count <= 0;
        end else begin
            color_meta <= I_color_mode_async;
            color_sync <= color_meta;
            color_sync_d <= color_sync;
            user_d <= I_tuser;
            // Match the display selector's AWB-SOF configuration commit,
            // including an early marker before the first valid RGB beat.
            if (I_tuser)
                active_mask_view_mode <= I_effect_config[11:8];
            if (frame_marker) begin
                active_motion <= frame_mode == 2'b11;
                active_color <= frame_mode == 2'b11 ? 2'b00 : frame_mode;
                frame_pending <= 1;
                frame_open <= 0;
            end
            if (accept_beat) begin
                frame_pending <= 0;
                frame_open <= !final_beat;
                beat_count <= first_beat ? 1 : beat_count + 1'b1;
                if (final_beat)
                    begin completion_motion <= active_motion; completion_color <= active_color; end
            end
        end
    end

    wire red_ready, red_found, red_toggle;
    wire [11:0] red_xmin, red_xmax, red_ymin, red_ymax, red_cx, red_cy;
    wire [23:0] red_pixels;
    wire multi_ready, multi_overflow;
    wire [3:0] multi_valid, multi_hold;
    wire [191:0] multi_boxes;
    wire [7:0] multi_shapes;
    wire [9:0] multi_frame_id;
    red_target_detect_96 #(
        .IMG_WIDTH(IMG_WIDTH), .IMG_HEIGHT(IMG_HEIGHT),
        .RED_MIN(24), .RED_DELTA(6), .MIN_PIXELS(RED_MIN_PIXELS),
        .MULTI_ENABLE(RED_MULTI_ENABLE),
        .SINGLE_SHAPE_ENABLE(SINGLE_SHAPE_ENABLE)
    ) u_red (
        .I_clk(I_clk), .I_rst_n(I_rst_n),
        .I_tuser(I_tuser), .I_tvalid(I_tvalid), .I_tdata(I_tdata),
        .I_color_mode(frame_marker ?
            (frame_mode == 2'b11 ? 2'b00 : frame_mode) : active_color),
        .I_mask_view_mode(I_tuser ? I_effect_config[11:8] : active_mask_view_mode),
        .O_mask_pixels(O_mask_pixels),
        .O_result_ready(red_ready), .O_found(red_found),
        .O_xmin(red_xmin), .O_xmax(red_xmax), .O_ymin(red_ymin), .O_ymax(red_ymax),
        .O_center_x(red_cx), .O_center_y(red_cy), .O_pixels(red_pixels),
        .O_frame_toggle(red_toggle),
        .I_frame_id(I_frame_id),
        .I_multi_clear(frame_marker &&
            (((frame_mode == 2'b11) != active_motion) ||
             ((frame_mode == 2'b11 ? 2'b00 : frame_mode) != active_color))),
        .O_multi_ready(multi_ready), .O_multi_valid(multi_valid),
        .O_multi_hold(multi_hold), .O_multi_boxes(multi_boxes),
        .O_multi_shapes(multi_shapes),
        .O_multi_frame_id(multi_frame_id), .O_multi_overflow(multi_overflow)
    );
    wire raw_motion_ready, raw_motion_found, raw_motion_toggle, motion_scene_change;
    wire [11:0] raw_motion_xmin, raw_motion_xmax, raw_motion_ymin, raw_motion_ymax;
    wire [11:0] raw_motion_cx, raw_motion_cy;
    wire [23:0] raw_motion_pixels, motion_supported_blocks;
    wire motion_ready, motion_found, motion_toggle;
    wire [11:0] motion_xmin, motion_xmax, motion_ymin, motion_ymax, motion_cx, motion_cy;
    wire [23:0] motion_pixels;
    motion_target_detect_96 #(
        .IMG_WIDTH(IMG_WIDTH), .IMG_HEIGHT(IMG_HEIGHT),
        .DIFF_THRESHOLD(DIFF_THRESHOLD), .MIN_BLOCKS(MIN_BLOCKS),
        .GLOBAL_CHANGE_PERCENT(GLOBAL_CHANGE_PERCENT)
    ) u_motion (
        .I_clk(I_clk), .I_rst_n(I_rst_n),
        .I_tuser(I_tuser), .I_tlast(I_tlast), .I_tvalid(I_tvalid), .I_tdata(I_tdata),
        .O_result_ready(raw_motion_ready), .O_found(raw_motion_found),
        .O_xmin(raw_motion_xmin), .O_xmax(raw_motion_xmax),
        .O_ymin(raw_motion_ymin), .O_ymax(raw_motion_ymax),
        .O_center_x(raw_motion_cx), .O_center_y(raw_motion_cy),
        .O_pixels(raw_motion_pixels), .O_frame_toggle(raw_motion_toggle),
        .O_supported_blocks(motion_supported_blocks), .O_scene_change(motion_scene_change)
    );
    generate
        if (MOTION_STABLE_ENABLE) begin : gen_stable_motion
            motion_result_stabilizer #(
                .IMG_WIDTH(IMG_WIDTH), .IMG_HEIGHT(IMG_HEIGHT),
                .INPUT_BLOCK_ALIGNED(1)
            ) u_stabilizer (
                .I_clk(I_clk), .I_rst_n(I_rst_n),
                .I_result_ready(raw_motion_ready), .I_found(raw_motion_found),
                .I_scene_change(motion_scene_change),
                .I_supported_blocks(motion_supported_blocks), .I_pixels(raw_motion_pixels),
                .I_xmin(raw_motion_xmin), .I_xmax(raw_motion_xmax),
                .I_ymin(raw_motion_ymin), .I_ymax(raw_motion_ymax),
                .O_result_ready(motion_ready), .O_found(motion_found),
                .O_xmin(motion_xmin), .O_xmax(motion_xmax),
                .O_ymin(motion_ymin), .O_ymax(motion_ymax),
                .O_center_x(motion_cx), .O_center_y(motion_cy),
                .O_pixels(motion_pixels), .O_frame_toggle(motion_toggle)
            );
        end else begin : gen_raw_motion
            assign motion_ready = raw_motion_ready;
            assign motion_found = raw_motion_found;
            assign motion_toggle = raw_motion_toggle;
            assign motion_xmin = raw_motion_xmin;
            assign motion_xmax = raw_motion_xmax;
            assign motion_ymin = raw_motion_ymin;
            assign motion_ymax = raw_motion_ymax;
            assign motion_cx = raw_motion_cx;
            assign motion_cy = raw_motion_cy;
            assign motion_pixels = raw_motion_pixels;
        end
    endgenerate

    assign O_motion_mode_active = active_motion;
    assign O_color_mode_active = active_color;
    generate
        if (!RED_MULTI_ENABLE && !SINGLE_SHAPE_ENABLE) begin : gen_legacy_result
            assign O_target_motion_mode = completion_motion;
            assign O_target_color_mode = completion_color;
            assign O_result_ready = completion_motion ? motion_ready : red_ready;
            assign O_found = completion_motion ? motion_found : red_found;
            assign O_xmin = completion_motion ? motion_xmin : red_xmin;
            assign O_xmax = completion_motion ? motion_xmax : red_xmax;
            assign O_ymin = completion_motion ? motion_ymin : red_ymin;
            assign O_ymax = completion_motion ? motion_ymax : red_ymax;
            assign O_center_x = completion_motion ? motion_cx : red_cx;
            assign O_center_y = completion_motion ? motion_cy : red_cy;
            assign O_pixels = completion_motion ? motion_pixels : red_pixels;
            assign O_frame_toggle = completion_motion ? motion_toggle : red_toggle;
            assign O_result_frame_id = 10'd0;
            assign O_multi_valid = 4'd0;
            assign O_multi_hold = 4'd0;
            assign O_multi_boxes = 192'd0;
            assign O_multi_shapes = 8'd0;
            assign O_multi_overflow = 1'b0;
        end else begin : gen_multi_result
            reg [9:0] active_id, completion_id, motion_id_1d, motion_id_2d;
            reg [9:0] context_id [0:3];
            reg [3:0] context_valid, context_motion;
            reg [1:0] context_color [0:3];
            integer ci;
            // Motion's stabilizer publishes two clocks after its raw result.
            // Color shape results carry their own ID through classification,
            // whether using the single-frame accumulator or the run queue.
            always @(posedge I_clk or negedge I_rst_n) begin
                if (!I_rst_n) begin
                    active_id<=0; completion_id<=0;
                    motion_id_1d<=0; motion_id_2d<=0;
                    context_valid<=0; context_motion<=0;
                    for (ci=0; ci<4; ci=ci+1) begin context_id[ci]<=0; context_color[ci]<=0; end
                end else begin
                    if (frame_marker) begin
                        active_id<=I_frame_id;
                        context_id[I_frame_id[1:0]]<=I_frame_id;
                        context_valid[I_frame_id[1:0]]<=1'b1;
                        context_motion[I_frame_id[1:0]]<=frame_mode == 2'b11;
                        context_color[I_frame_id[1:0]]<=
                            frame_mode == 2'b11 ? 2'b00 : frame_mode;
                    end
                    if (accept_beat && final_beat) completion_id<=active_id;
                    if (raw_motion_ready) motion_id_1d<=completion_id;
                    motion_id_2d<=motion_id_1d;
                end
            end
            wire [9:0] motion_id = MOTION_STABLE_ENABLE ?
                motion_id_2d : completion_id;
            wire red_selected = multi_ready &&
                context_valid[multi_frame_id[1:0]] &&
                context_id[multi_frame_id[1:0]] == multi_frame_id &&
                !context_motion[multi_frame_id[1:0]] &&
                !(frame_marker && I_frame_id[1:0] == multi_frame_id[1:0]);
            wire motion_selected = motion_ready &&
                context_valid[motion_id[1:0]] &&
                context_id[motion_id[1:0]] == motion_id &&
                context_motion[motion_id[1:0]] &&
                !(frame_marker && I_frame_id[1:0] == motion_id[1:0]);
            wire [47:0] first_box = multi_valid[0] ? multi_boxes[0 +: 48] :
                multi_valid[1] ? multi_boxes[48 +: 48] :
                multi_valid[2] ? multi_boxes[96 +: 48] : multi_boxes[144 +: 48];
            wire [12:0] red_center_x = {1'b0,first_box[11:0]}+
                {1'b0,first_box[23:12]};
            wire [12:0] red_center_y = {1'b0,first_box[35:24]}+
                {1'b0,first_box[47:36]};
            wire [106:0] new_motion = {motion_id,motion_found,motion_xmin,
                motion_xmax,motion_ymin,motion_ymax,motion_cx,motion_cy,motion_pixels};
            reg [106:0] pending_motion;
            reg pending_valid;
            reg ready, found, result_motion, result_toggle, overflow;
            reg [1:0] result_color;
            reg [9:0] result_id;
            reg [11:0] xmin,xmax,ymin,ymax,cx,cy;
            reg [23:0] pixels;
            reg [3:0] valid, hold;
            reg [191:0] boxes;
            reg [7:0] shapes;
            always @(posedge I_clk or negedge I_rst_n) begin
                if (!I_rst_n) begin
                    pending_motion<=0; pending_valid<=0;
                    ready<=0; found<=0; result_motion<=0; result_color<=0; result_toggle<=0;
                    result_id<=0; xmin<=0; xmax<=0; ymin<=0; ymax<=0;
                    cx<=0; cy<=0; pixels<=0; valid<=0; hold<=0; boxes<=0; shapes<=0; overflow<=0;
                end else begin
                    ready<=0;
                    if (red_selected) begin
                        ready<=1; result_motion<=0; result_color<=context_color[multi_frame_id[1:0]]; result_id<=multi_frame_id;
                        found<=|multi_valid; valid<=multi_valid; hold<=multi_hold;
                        boxes<=multi_boxes; shapes<=multi_shapes; overflow<=multi_overflow; pixels<=0;
                        xmin<=first_box[11:0]; xmax<=first_box[23:12];
                        ymin<=first_box[35:24]; ymax<=first_box[47:36];
                        cx<=red_center_x[12:1]; cy<=red_center_y[12:1];
                        result_toggle<=!result_toggle;
                        if (motion_selected) begin
                            pending_motion<=new_motion; pending_valid<=1;
                        end
                    end else if (pending_valid || motion_selected) begin
                        ready<=1; result_motion<=1; result_color<=0;
                        {result_id,found,xmin,xmax,ymin,ymax,cx,cy,pixels}<=
                            pending_valid ? pending_motion : new_motion;
                        valid<=0; hold<=0; boxes<=0; shapes<=0; overflow<=0;
                        result_toggle<=!result_toggle;
                        pending_valid<=pending_valid && motion_selected;
                        if (pending_valid && motion_selected) pending_motion<=new_motion;
                    end
                end
            end
            assign O_result_ready=ready;
            assign O_found=found;
            assign O_target_motion_mode=result_motion;
            assign O_target_color_mode=result_color;
            assign O_frame_toggle=result_toggle;
            assign O_result_frame_id=result_id;
            assign O_xmin=xmin; assign O_xmax=xmax;
            assign O_ymin=ymin; assign O_ymax=ymax;
            assign O_center_x=cx; assign O_center_y=cy; assign O_pixels=pixels;
            assign O_multi_valid=valid; assign O_multi_hold=hold;
            assign O_multi_boxes=boxes; assign O_multi_shapes=shapes;
            assign O_multi_overflow=overflow;
        end
    endgenerate
endmodule

// Advance only on completed camera frames. Every result still publishes a
// token, including unconfirmed/held boxes, so DDR slot metadata stays aligned.
module motion_result_stabilizer #(
    parameter integer IMG_WIDTH = 1280,
    parameter integer IMG_HEIGHT = 720,
    parameter integer MIN_SUPPORTED_BLOCKS = 8,
    parameter integer CONFIRM_FRAMES = 3,
    parameter integer RELEASE_FRAMES = 3,
    parameter integer MAX_CENTER_STEP = 64,
    parameter integer SIZE_MARGIN = 32,
    parameter integer DEADBAND = 8,
    parameter integer INPUT_BLOCK_ALIGNED = 0
) (
    input wire I_clk,
    input wire I_rst_n,
    input wire I_result_ready,
    input wire I_found,
    input wire I_scene_change,
    input wire [23:0] I_supported_blocks,
    input wire [23:0] I_pixels,
    input wire [11:0] I_xmin, I_xmax, I_ymin, I_ymax,
    output reg O_result_ready,
    output reg O_found,
    output reg [11:0] O_xmin, O_xmax, O_ymin, O_ymax,
    output reg [11:0] O_center_x, O_center_y,
    output reg [23:0] O_pixels,
    output reg O_frame_toggle
);
    // The original unsigned comparison promotes 2*MAX_CENTER_STEP to 32
    // bits. Preserve that parameter arithmetic, including large values.
    localparam [31:0] CENTER_LIMIT = 2*MAX_CENTER_STEP;
    function centers_match;
        input [12:0] current_center, previous_center;
        reg signed [13:0] difference;
        begin
            difference = $signed({1'b0,current_center}) -
                         $signed({1'b0,previous_center});
            // One signed subtraction replaces two unsigned differences and
            // their ordering mux. A 13-bit center difference never exceeds
            // 8191, so larger original unsigned limits always accept it.
            if (CENTER_LIMIT >= 32'd8191)
                centers_match = 1'b1;
            else
                centers_match = difference >= -$signed({1'b0,CENTER_LIMIT}) &&
                                difference <=  $signed({1'b0,CENTER_LIMIT});
        end
    endfunction
    function boxes_match;
        input [11:0] ax0, ax1, ay0, ay1, bx0, bx1, by0, by1;
        input [12:0] bw, bh, bcx, bcy;
        reg [12:0] aw, ah, acx, acy;
        begin
            aw = {1'b0,ax1} - {1'b0,ax0} + 13'd1;
            ah = {1'b0,ay1} - {1'b0,ay0} + 13'd1;
            acx = {1'b0,ax0} + {1'b0,ax1};
            acy = {1'b0,ay0} + {1'b0,ay1};
            boxes_match = centers_match(acx,bcx) && centers_match(acy,bcy) &&
                {1'b0,aw} <= {bw,1'b0} + SIZE_MARGIN &&
                {1'b0,bw} <= {aw,1'b0} + SIZE_MARGIN &&
                {1'b0,ah} <= {bh,1'b0} + SIZE_MARGIN &&
                {1'b0,bh} <= {ah,1'b0} + SIZE_MARGIN &&
                {1'b0,ax0} <= {1'b0,bx1} + SIZE_MARGIN &&
                {1'b0,bx0} <= {1'b0,ax1} + SIZE_MARGIN &&
                {1'b0,ay0} <= {1'b0,by1} + SIZE_MARGIN &&
                {1'b0,by0} <= {1'b0,ay1} + SIZE_MARGIN;
        end
    endfunction

    function [11:0] smooth_coordinate;
        input [11:0] previous, current;
        reg signed [12:0] difference;
        reg [13:0] previous_weight, biased_current, weighted_sum;
        begin
            difference = $signed({1'b0,current}) - $signed({1'b0,previous});
            // Preserve the original away-from-zero quarter-step rounding.
            // Compute 3*previous and current+bias in parallel; unlike
            // previous+((current-previous+bias)>>>2), neither sum waits
            // for the signed difference. The maximum is 16383, so all
            // weighted arithmetic is explicitly unsigned and 14 bits.
            previous_weight = {1'b0,previous,1'b0} + {2'b00,previous};
            biased_current = {2'b00,current} +
                (current >= previous ? 14'd3 : 14'd0);
            weighted_sum = previous_weight + biased_current;
            smooth_coordinate =
                difference >= -DEADBAND && difference <= DEADBAND ?
                previous : weighted_sum[13:2];
        end
    endfunction

    localparam integer CONFIRM_BITS = $clog2(CONFIRM_FRAMES+1);
    localparam integer RELEASE_BITS = $clog2(RELEASE_FRAMES+1);
    reg active;
    reg [CONFIRM_BITS-1:0] confirmations;
    reg [RELEASE_BITS-1:0] misses;
    reg [11:0] anchor_x0, anchor_x1, anchor_y0, anchor_y1;
    // Cache exact anchor features at the same edge as their coordinates.
    // Association no longer recomputes the stored center/width before the
    // subtraction and comparisons. Publication latency is unchanged.
    reg [12:0] anchor_width, anchor_height, anchor_center_x, anchor_center_y;
    reg [11:0] track_x0, track_x1, track_y0, track_y1;
    reg [23:0] track_pixels;
    wire [12:0] candidate_width = {1'b0,I_xmax} - {1'b0,I_xmin} + 13'd1;
    wire [12:0] candidate_height = {1'b0,I_ymax} - {1'b0,I_ymin} + 13'd1;
    wire [12:0] candidate_center_x = {1'b0,I_xmin} + {1'b0,I_xmax};
    wire [12:0] candidate_center_y = {1'b0,I_ymin} + {1'b0,I_ymax};
    wire [13:0] span_blocks =
        (({1'b0,candidate_width}+14'd7) >> 3) +
        (({1'b0,candidate_height}+14'd7) >> 3);
    wire [25:0] support_weight =
        {1'b0,I_supported_blocks,1'b0} + {2'b00,I_supported_blocks};
    // Sparse clusters must not turn their large union into a target.
    // Keep enough margin for the two thin edges of a moving solid object.
    wire candidate = I_found && I_xmin <= I_xmax && I_ymin <= I_ymax &&
        I_xmax < IMG_WIDTH && I_ymax < IMG_HEIGHT &&
        I_supported_blocks >= MIN_SUPPORTED_BLOCKS &&
        support_weight >= {span_blocks,1'b0};
    wire associated = boxes_match(I_xmin,I_xmax,I_ymin,I_ymax,
                               anchor_x0,anchor_x1,anchor_y0,anchor_y1,
                               anchor_width,anchor_height,anchor_center_x,anchor_center_y);
    // The raw motion detector publishes inclusive eight-pixel block bounds.
    // For a valid candidate its maximum coordinate always ends in 3'b111.
    // Use that value before smoothing, whose result is consumed only when
    // candidate is true. This removes the raw found flag from the arithmetic
    // data path; invalid frames still follow the unchanged miss/release path.
    // Historical track coordinates retain their full sub-block precision.
    wire [11:0] smooth_current_xmax = INPUT_BLOCK_ALIGNED ?
        {I_xmax[11:3],3'b111} : I_xmax;
    wire [11:0] smooth_current_ymax = INPUT_BLOCK_ALIGNED ?
        {I_ymax[11:3],3'b111} : I_ymax;
    wire [11:0] smooth_x0 = smooth_coordinate(track_x0,I_xmin);
    wire [11:0] smooth_x1 = smooth_coordinate(track_x1,smooth_current_xmax);
    wire [11:0] smooth_y0 = smooth_coordinate(track_y0,I_ymin);
    wire [11:0] smooth_y1 = smooth_coordinate(track_y1,smooth_current_ymax);
    wire [11:0] smoothed_x0 = smooth_x0 <= smooth_x1 ? smooth_x0 : I_xmin;
    wire [11:0] smoothed_x1 = smooth_x0 <= smooth_x1 ? smooth_x1 : smooth_current_xmax;
    wire [11:0] smoothed_y0 = smooth_y0 <= smooth_y1 ? smooth_y0 : I_ymin;
    wire [11:0] smoothed_y1 = smooth_y0 <= smooth_y1 ? smooth_y1 : smooth_current_ymax;

    reg publish_valid, publish_found;
    reg [11:0] publish_x0, publish_x1, publish_y0, publish_y1;
    reg [23:0] publish_pixels;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            active <= 0; confirmations <= 0; misses <= 0;
            anchor_x0 <= 0; anchor_x1 <= 0; anchor_y0 <= 0; anchor_y1 <= 0;
            anchor_width <= 13'd1; anchor_height <= 13'd1;
            anchor_center_x <= 0; anchor_center_y <= 0;
            track_x0 <= 0; track_x1 <= 0; track_y0 <= 0; track_y1 <= 0;
            track_pixels <= 0;
            publish_valid <= 0; publish_found <= 0;
            publish_x0 <= 0; publish_x1 <= 0; publish_y0 <= 0; publish_y1 <= 0;
            publish_pixels <= 0;
        end else begin
            publish_valid <= I_result_ready;
            if (I_result_ready) begin
                publish_found <= 0;
                publish_x0 <= 0; publish_x1 <= 0;
                publish_y0 <= 0; publish_y1 <= 0; publish_pixels <= 0;
                if (I_scene_change) begin
                    // A bad reference or broad illumination event must not
                    // display a stale box through the ordinary miss hold.
                    active <= 0; confirmations <= 0; misses <= 0;
                end else if (active) begin
                    if (candidate && associated) begin
                        misses <= 0;
                        anchor_x0 <= I_xmin; anchor_x1 <= I_xmax;
                        anchor_y0 <= I_ymin; anchor_y1 <= I_ymax;
                        anchor_width <= candidate_width; anchor_height <= candidate_height;
                        anchor_center_x <= candidate_center_x; anchor_center_y <= candidate_center_y;
                        track_x0 <= smoothed_x0; track_x1 <= smoothed_x1;
                        track_y0 <= smoothed_y0; track_y1 <= smoothed_y1;
                        track_pixels <= I_pixels;
                        publish_found <= 1;
                        publish_x0 <= smoothed_x0; publish_x1 <= smoothed_x1;
                        publish_y0 <= smoothed_y0; publish_y1 <= smoothed_y1;
                        publish_pixels <= I_pixels;
                    end else if (misses < RELEASE_FRAMES-1) begin
                        misses <= misses + 1'b1;
                        publish_found <= 1;
                        publish_x0 <= track_x0; publish_x1 <= track_x1;
                        publish_y0 <= track_y0; publish_y1 <= track_y1;
                        publish_pixels <= track_pixels;
                    end else begin
                        active <= 0; misses <= 0;
                        confirmations <= candidate ? 1 : 0;
                        anchor_x0 <= I_xmin; anchor_x1 <= I_xmax;
                        anchor_y0 <= I_ymin; anchor_y1 <= I_ymax;
                        anchor_width <= candidate_width; anchor_height <= candidate_height;
                        anchor_center_x <= candidate_center_x; anchor_center_y <= candidate_center_y;
                    end
                end else if (candidate) begin
                    anchor_x0 <= I_xmin; anchor_x1 <= I_xmax;
                    anchor_y0 <= I_ymin; anchor_y1 <= I_ymax;
                    anchor_width <= candidate_width; anchor_height <= candidate_height;
                    anchor_center_x <= candidate_center_x; anchor_center_y <= candidate_center_y;
                    if (CONFIRM_FRAMES == 1 ||
                        (confirmations != 0 && associated &&
                         confirmations >= CONFIRM_FRAMES-1)) begin
                        active <= 1; confirmations <= 0; misses <= 0;
                        track_x0 <= I_xmin; track_x1 <= I_xmax;
                        track_y0 <= I_ymin; track_y1 <= I_ymax;
                        track_pixels <= I_pixels;
                        publish_found <= 1;
                        publish_x0 <= I_xmin; publish_x1 <= I_xmax;
                        publish_y0 <= I_ymin; publish_y1 <= I_ymax;
                        publish_pixels <= I_pixels;
                    end else
                        confirmations <= confirmations != 0 && associated ?
                            confirmations + 1'b1 : 1;
                end else
                    confirmations <= 0;
            end
        end
    end

    wire [12:0] center_x_sum = {1'b0,publish_x0} + {1'b0,publish_x1};
    wire [12:0] center_y_sum = {1'b0,publish_y0} + {1'b0,publish_y1};
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_result_ready <= 0; O_found <= 0; O_frame_toggle <= 0;
            O_xmin <= 0; O_xmax <= 0; O_ymin <= 0; O_ymax <= 0;
            O_center_x <= 0; O_center_y <= 0; O_pixels <= 0;
        end else begin
            O_result_ready <= publish_valid;
            if (publish_valid) begin
                O_frame_toggle <= ~O_frame_toggle;
                O_found <= publish_found;
                O_xmin <= publish_x0; O_xmax <= publish_x1;
                O_ymin <= publish_y0; O_ymax <= publish_y1;
                O_center_x <= center_x_sum[12:1];
                O_center_y <= center_y_sum[12:1];
                O_pixels <= publish_pixels;
            end
        end
    end

    // synthesis translate_off
    initial begin
        if (CONFIRM_FRAMES < 1 || RELEASE_FRAMES < 1 ||
            MIN_SUPPORTED_BLOCKS < 1 || MAX_CENTER_STEP < 1 ||
            SIZE_MARGIN < 0 || DEADBAND < 0)
            $fatal(1, "Motion stability parameters are outside the supported range");
    end
    // synthesis translate_on
endmodule
