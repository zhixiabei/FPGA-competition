// Associate detector results with the actual DDR allocation, then freeze the
// selected slot before display. Only metadata crosses these clock domains.
module target_frame_bridge #(
    parameter integer FRAME_WORDS = 172800,
    parameter [11:0] DEFAULT_EFFECT_CONFIG = 12'd0,
    // Production target_detect_switch uses first-valid color bounds and
    // clears motion multi-boxes. Other users retain independent fields.
    parameter integer COMPACT_MODE_PAYLOAD = 0,
    parameter integer USE_EXTERNAL_WRITE_PROGRESS = 0
) (
    input wire I_csi_clk,
    input wire I_ddr_clk,
    input wire I_hdmi_clk,
    input wire I_rst_n,
    input wire I_frame_start,
    input wire [9:0] I_frame_id,
    input wire [11:0] I_effect_config,
    input wire I_motion_mode,
    input wire [1:0] I_color_mode,
    input wire I_result_ready,
    input wire [9:0] I_result_frame_id,
    input wire I_result_found,
    input wire I_result_motion_mode,
    input wire [1:0] I_result_color_mode,
    input wire [11:0] I_result_xmin,
    input wire [11:0] I_result_xmax,
    input wire [11:0] I_result_ymin,
    input wire [11:0] I_result_ymax,
    input wire [11:0] I_result_center_x,
    input wire [11:0] I_result_center_y,
    input wire [3:0] I_multi_valid,
    input wire [3:0] I_multi_hold,
    input wire [191:0] I_multi_boxes,
    input wire [7:0] I_multi_shapes,
    input wire I_multi_overflow,
    input wire I_write_start,
    input wire [1:0] I_write_slot,
    input wire I_write_word,
    input wire I_read_start,
    input wire [1:0] I_read_slot,
    output reg O_ready,
    output reg [11:0] O_effect_config,
    output reg O_motion_mode,
    output reg [1:0] O_color_mode,
    output reg O_found,
    output reg [11:0] O_xmin,
    output reg [11:0] O_xmax,
    output reg [11:0] O_ymin,
    output reg [11:0] O_ymax,
    output reg [11:0] O_center_x,
    output reg [11:0] O_center_y,
    output reg [3:0] O_multi_valid,
    output reg [3:0] O_multi_hold,
    output reg [191:0] O_multi_boxes,
    output reg [7:0] O_multi_shapes,
    output reg O_multi_overflow,
    // Same-edge combinational completion from video_ddr_write_progress.
    input wire I_write_complete
);
    // Clipped 720p coordinates need 11 x bits and 10 y bits. Keep the
    // external 12-bit ports while storing only significant payload bits.
    localparam integer BOX_WIDTH = 42;
    localparam integer BODY_WIDTH = COMPACT_MODE_PAYLOAD ? 210 : 252;
    localparam integer EXPANDED_BODY_WIDTH = 285;
    localparam integer RESULT_WIDTH = 16+10+BODY_WIDTH;
    localparam integer READ_WIDTH = BODY_WIDTH+13;
    localparam integer COUNT_WIDTH = (FRAME_WORDS < 2) ? 1 : $clog2(FRAME_WORDS+1);

    function [1:0] F_offset;
        input [11:0] effect_config;
        begin
            case (effect_config[11:8])
                4'd2, 4'd6, 4'd7: F_offset = 2'd3;
                4'd4, 4'd8, 4'd10, 4'd11: F_offset = 2'd1;
                // Majority, dilation and erosion add three centered windows.
                4'd12: F_offset = 2'd3;
                default: F_offset = 2'd0;
            endcase
        end
    endfunction
    function [11:0] F_clip_x;
        input [11:0] value;
        input [1:0] offset;
        reg [10:0] shifted;
        reg [1:0] remaining_low;
        reg exceeds_limit;
        begin
            // 1279 = 4*319+3. Compare before the offset add so the
            // saturating decision needs no carry chain from that add.
            remaining_low = ~offset;
            exceeds_limit = value[11:2] > 10'd319 ||
                (value[11:2] == 10'd319 && value[1:0] > remaining_low);
            shifted = value[10:0]+{9'd0,offset};
            F_clip_x = exceeds_limit ? 12'd1279 : {1'b0,shifted};
        end
    endfunction
    function [11:0] F_clip_y;
        input [11:0] value;
        input [1:0] offset;
        reg [9:0] shifted;
        reg [1:0] remaining_low;
        reg exceeds_limit;
        begin
            // Keep all upper input bits in the range comparison.
            remaining_low = ~offset;
            exceeds_limit = value[11:2] > 10'd179 ||
                (value[11:2] == 10'd179 && value[1:0] > remaining_low);
            shifted = value[9:0]+{8'd0,offset};
            F_clip_y = exceeds_limit ? 12'd719 : {2'b0,shifted};
        end
    endfunction

    function [BOX_WIDTH-1:0] F_pack_box;
        input [47:0] box_value;
        begin
            F_pack_box = {box_value[45:36],box_value[33:24],
                          box_value[22:12],box_value[10:0]};
        end
    endfunction
    function [47:0] F_expand_box;
        input [BOX_WIDTH-1:0] box_value;
        begin
            F_expand_box = {2'b0,box_value[41:32],2'b0,box_value[31:22],
                            1'b0,box_value[21:11],1'b0,box_value[10:0]};
        end
    endfunction
    function [62:0] F_pack_single;
        input [71:0] coordinates;
        begin
            F_pack_single = {coordinates[70:60],coordinates[58:48],
                             coordinates[45:36],coordinates[33:24],
                             coordinates[22:12],coordinates[9:0]};
        end
    endfunction
    function [71:0] F_expand_single;
        input [62:0] coordinates;
        begin
            F_expand_single = {1'b0,coordinates[62:52],1'b0,coordinates[51:41],
                               2'b0,coordinates[40:31],2'b0,coordinates[30:21],
                               1'b0,coordinates[20:10],2'b0,coordinates[9:0]};
        end
    endfunction
    function [EXPANDED_BODY_WIDTH-1:0] F_expand_body;
        input [BODY_WIDTH-1:0] body;
        input [11:0] effect_config;
        input read_valid;
        integer index;
        reg [BOX_WIDTH-1:0] single_box;
        reg [11:0] motion_zero;
        begin
            if (COMPACT_MODE_PAYLOAD) begin
                // Both formats keep flags and the shared box area at the
                // same low offsets. Only the single bounds are omitted.
                if (body[BODY_WIDTH-1] || body[4*BOX_WIDTH+13])
                    single_box = body[1 +: BOX_WIDTH];
                else if (body[4*BOX_WIDTH+14])
                    single_box = body[1+BOX_WIDTH +: BOX_WIDTH];
                else if (body[4*BOX_WIDTH+15])
                    single_box = body[1+2*BOX_WIDTH +: BOX_WIDTH];
                else
                    single_box = body[1+3*BOX_WIDTH +: BOX_WIDTH];
                F_expand_body = {body[BODY_WIDTH-1 -: 4],
                    F_expand_single({
                        single_box[10:0],single_box[21:11],
                        single_box[31:22],single_box[41:32],
                        body[BODY_WIDTH-5 -: 21]}),
                    body[4*BOX_WIDTH+16:4*BOX_WIDTH+1],192'b0,body[0]};
                // Invalid read snapshots already store zero geometry and
                // bypass result clipping. Only reconstructed motion boxes
                // need this guard; found/valid flags cannot substitute for
                // read_valid because no-target results may still be shifted.
                motion_zero = read_valid ? {10'b0,F_offset(effect_config)} : 12'b0;
                for (index=0; index<4; index=index+1)
                    F_expand_body[1+48*index +: 48] = body[BODY_WIDTH-1] ?
                        {motion_zero,motion_zero,motion_zero,motion_zero} :
                        F_expand_box(body[1+BOX_WIDTH*index +: BOX_WIDTH]);
            end else begin
                F_expand_body = {body[BODY_WIDTH-1 -: 4],
                                 F_expand_single(body[BODY_WIDTH-5 -: 63]),
                                 body[4*BOX_WIDTH+16:4*BOX_WIDTH+1],192'b0,body[0]};
                for (index=0; index<4; index=index+1)
                    F_expand_body[1+48*index +: 48] =
                        F_expand_box(body[1+BOX_WIDTH*index +: BOX_WIDTH]);
            end
        end
    endfunction

    reg [15:0] S_nonce_counter;
    // Held from ISP SOF until the next ISP SOF. video_in crosses that same
    // SOF through two DDR stages before I_write_start samples these registers.
    reg [15:0] S_start_nonce;
    reg [9:0] S_start_frame_id;
    reg [11:0] S_start_effect_config;
    reg S_start_motion_mode, S_start_valid;
    reg [1:0] S_start_color_mode;
    reg [3:0] S_context_valid;
    reg [9:0] S_context_id [0:3];
    reg [15:0] S_context_nonce [0:3];
    reg [11:0] S_context_config [0:3];
    reg S_context_motion [0:3];
    reg [1:0] S_context_color [0:3];

    wire [1:0] S_context_index = I_result_frame_id[1:0];
    // A replaced context is unusable on the replacement edge too.
    wire S_context_match = S_context_valid[S_context_index] &&
        S_context_id[S_context_index] == I_result_frame_id &&
        S_context_motion[S_context_index] == I_result_motion_mode &&
        S_context_color[S_context_index] == I_result_color_mode &&
        !(I_frame_start && I_frame_id[1:0] == S_context_index);
    wire [1:0] S_result_offset = F_offset(S_context_config[S_context_index]);
    wire [4*BOX_WIDTH-1:0] S_adjusted_boxes;
    genvar box_index;
    generate
        for (box_index=0; box_index<4; box_index=box_index+1) begin : g_adjust_boxes
            // Every box is {ymax,ymin,xmax,xmin}; box zero occupies [47:0].
            assign S_adjusted_boxes[BOX_WIDTH*box_index +: BOX_WIDTH] = F_pack_box({
                F_clip_y(I_multi_boxes[48*box_index+36 +: 12], S_result_offset),
                F_clip_y(I_multi_boxes[48*box_index+24 +: 12], S_result_offset),
                F_clip_x(I_multi_boxes[48*box_index+12 +: 12], S_result_offset),
                F_clip_x(I_multi_boxes[48*box_index +: 12], S_result_offset)});
        end
    endgenerate
    wire [62:0] S_adjusted_single = F_pack_single({
        F_clip_x(I_result_xmin,S_result_offset),
        F_clip_x(I_result_xmax,S_result_offset),
        F_clip_y(I_result_ymin,S_result_offset),
        F_clip_y(I_result_ymax,S_result_offset),
        F_clip_x(I_result_center_x,S_result_offset),
        F_clip_y(I_result_center_y,S_result_offset)});
    wire [RESULT_WIDTH-1:0] S_new_result;
    generate
        if (COMPACT_MODE_PAYLOAD) begin : g_compact_payload
            // Keep centers independently: averaging clipped bounds changes
            // their rounding/saturation. Motion uses box zero for its bounds;
            // its original zero multi-boxes are reconstructed after CDC.
            wire [4*BOX_WIDTH-1:0] S_shared_boxes = I_result_motion_mode ?
                {{(3*BOX_WIDTH){1'b0}},
                 S_adjusted_single[30:21],S_adjusted_single[40:31],
                 S_adjusted_single[51:41],S_adjusted_single[62:52]} :
                S_adjusted_boxes;
            assign S_new_result = {
                S_context_nonce[S_context_index],I_result_frame_id,
                I_result_motion_mode,I_result_color_mode,I_result_found,
                S_adjusted_single[20:0],
                I_multi_valid,I_multi_hold,I_multi_shapes,S_shared_boxes,I_multi_overflow};
        end else begin : g_full_payload
            assign S_new_result = {
                S_context_nonce[S_context_index],I_result_frame_id,
                I_result_motion_mode,I_result_color_mode,I_result_found,
                S_adjusted_single,
                I_multi_valid,I_multi_hold,I_multi_shapes,S_adjusted_boxes,I_multi_overflow};
        end
    endgenerate
    wire S_new_result_valid = I_result_ready && S_context_match;

    reg [RESULT_WIDTH-1:0] S_result_payload, S_result_pending_payload;
    reg S_result_request, S_result_ack, S_result_pending_valid;
    reg S_result_dropped;
    (* async_reg = "true" *) reg S_result_ack_meta, S_result_ack_sync;
    integer context_index;
    always @(posedge I_csi_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            S_nonce_counter <= 0; S_start_nonce <= 0; S_start_frame_id <= 0;
            S_start_effect_config <= DEFAULT_EFFECT_CONFIG;
            S_start_motion_mode <= 0; S_start_valid <= 0; S_context_valid <= 0;
            S_start_color_mode <= 0;
            S_result_payload <= 0; S_result_pending_payload <= 0;
            S_result_request <= 0; S_result_pending_valid <= 0;
            S_result_ack_meta <= 0; S_result_ack_sync <= 0; S_result_dropped <= 0;
            for (context_index=0; context_index<4; context_index=context_index+1) begin
                S_context_id[context_index] <= 0;
                S_context_nonce[context_index] <= 0;
                S_context_config[context_index] <= DEFAULT_EFFECT_CONFIG;
                S_context_motion[context_index] <= 0;
                S_context_color[context_index] <= 0;
            end
        end else begin
            S_result_ack_meta <= S_result_ack;
            S_result_ack_sync <= S_result_ack_meta;
            S_result_dropped <= I_result_ready && !S_context_match;
            if (I_frame_start) begin
                S_nonce_counter <= S_nonce_counter+16'd1;
                S_start_nonce <= S_nonce_counter+16'd1;
                S_start_frame_id <= I_frame_id;
                S_start_effect_config <= I_effect_config;
                S_start_motion_mode <= I_motion_mode;
                S_start_color_mode <= I_color_mode;
                S_start_valid <= 1'b1;
                S_context_valid[I_frame_id[1:0]] <= 1'b1;
                S_context_id[I_frame_id[1:0]] <= I_frame_id;
                S_context_nonce[I_frame_id[1:0]] <= S_nonce_counter+16'd1;
                S_context_config[I_frame_id[1:0]] <= I_effect_config;
                S_context_motion[I_frame_id[1:0]] <= I_motion_mode;
                S_context_color[I_frame_id[1:0]] <= I_color_mode;
            end
            if (S_result_request == S_result_ack_sync) begin
                if (S_result_pending_valid) begin
                    S_result_payload <= S_result_pending_payload;
                    S_result_request <= !S_result_request;
                    S_result_pending_valid <= S_new_result_valid;
                    if (S_new_result_valid)
                        S_result_pending_payload <= S_new_result;
                end else if (S_new_result_valid) begin
                    S_result_payload <= S_new_result;
                    S_result_request <= !S_result_request;
                end
            end else if (S_new_result_valid) begin
                if (!S_result_pending_valid) begin
                    S_result_pending_payload <= S_new_result;
                    S_result_pending_valid <= 1'b1;
                end else begin
                    // Keep the two older complete records; drop this entire
                    // result rather than overwrite a bus awaiting its ACK.
                    S_result_dropped <= 1'b1;
                end
            end
        end
    end

    (* async_reg = "true" *) reg S_result_req_meta, S_result_req_sync;
    reg [15:0] S_slot_nonce [0:3];
    reg [9:0] S_slot_frame_id [0:3];
    reg [11:0] S_slot_effect_config [0:3];
    reg [3:0] S_slot_motion_mode, S_slot_started, S_slot_complete, S_slot_result_valid;
    reg [1:0] S_slot_color_mode [0:3];
    reg [BODY_WIDTH-1:0] S_slot_result [0:3];
    reg [1:0] S_active_write_slot;
    reg [COUNT_WIDTH-1:0] S_write_count;
    reg S_write_active;
    reg [RESULT_WIDTH-1:0] S_last_result_payload;
    reg S_last_result_valid;

    wire S_result_message = S_result_req_sync != S_result_ack;
    wire [15:0] S_message_nonce = S_result_payload[BODY_WIDTH+10 +: 16];
    wire [9:0] S_message_id = S_result_payload[BODY_WIDTH +: 10];
    wire S_message_motion = S_result_payload[BODY_WIDTH-1];
    wire [1:0] S_message_color = S_result_payload[BODY_WIDTH-2 -: 2];
    wire S_message_matches_start = S_result_message && S_start_valid &&
        S_message_nonce == S_start_nonce && S_message_id == S_start_frame_id &&
        S_message_motion == S_start_motion_mode &&
        S_message_color == S_start_color_mode;
    wire S_last_matches_start = S_last_result_valid && S_start_valid &&
        S_last_result_payload[BODY_WIDTH+10 +: 16] == S_start_nonce &&
        S_last_result_payload[BODY_WIDTH +: 10] == S_start_frame_id &&
        S_last_result_payload[BODY_WIDTH-1] == S_start_motion_mode &&
        S_last_result_payload[BODY_WIDTH-2 -: 2] == S_start_color_mode;

    wire S_read_valid = S_slot_started[I_read_slot] &&
        S_slot_complete[I_read_slot] && S_slot_result_valid[I_read_slot] &&
        !(I_write_start && I_write_slot == I_read_slot);
    wire [READ_WIDTH-1:0] S_read_snapshot = S_read_valid ?
        {1'b1,S_slot_effect_config[I_read_slot],
         S_slot_result[I_read_slot][BODY_WIDTH-1 -: 3],
         S_slot_result[I_read_slot][BODY_WIDTH-4:0]} :
        {1'b0,S_slot_effect_config[I_read_slot],S_slot_motion_mode[I_read_slot],
         S_slot_color_mode[I_read_slot],{(BODY_WIDTH-3){1'b0}}};
    reg [READ_WIDTH-1:0] S_read_payload, S_read_pending_payload;
    reg S_read_request, S_read_ack, S_read_pending_valid;
    (* async_reg = "true" *) reg S_read_ack_meta, S_read_ack_sync;
    genvar slot_bank;
    generate
        for (slot_bank=0; slot_bank<4; slot_bank=slot_bank+1) begin : g_slot_result
            wire S_start_selected = I_write_start && I_write_slot == slot_bank;
            wire S_message_matches_slot = S_slot_started[slot_bank] &&
                S_slot_nonce[slot_bank] == S_message_nonce &&
                S_slot_frame_id[slot_bank] == S_message_id &&
                S_slot_motion_mode[slot_bank] == S_message_motion &&
                S_slot_color_mode[slot_bank] == S_message_color;
            wire S_take_message = S_start_selected ? S_message_matches_start :
                S_result_message && S_message_matches_slot;
            wire S_take_last = S_start_selected && !S_message_matches_start &&
                S_last_matches_start;

            // The two sources are exclusive, with write-start taking priority.
            // One static write port per bank avoids a second dynamic array write.
            always @(posedge I_ddr_clk or negedge I_rst_n) begin
                if (!I_rst_n) begin
                    S_slot_result[slot_bank] <= 0;
                    S_slot_result_valid[slot_bank] <= 1'b0;
                end else begin
                    if (S_take_message || S_take_last)
                        S_slot_result[slot_bank] <=
                            ({BODY_WIDTH{S_take_message}} &
                             S_result_payload[BODY_WIDTH-1:0]) |
                            ({BODY_WIDTH{S_take_last}} &
                             S_last_result_payload[BODY_WIDTH-1:0]);
                    if (S_start_selected)
                        S_slot_result_valid[slot_bank] <= S_take_message || S_take_last;
                    else if (S_take_message)
                        S_slot_result_valid[slot_bank] <= 1'b1;
                end
            end
        end
    endgenerate
    integer slot_index;
    always @(posedge I_ddr_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            S_result_req_meta <= 0; S_result_req_sync <= 0; S_result_ack <= 0;
            S_slot_motion_mode <= 0; S_slot_started <= 0;
            S_slot_complete <= 0;
            S_active_write_slot <= 0; S_write_count <= 0; S_write_active <= 0;
            S_last_result_payload <= 0; S_last_result_valid <= 0;
            S_read_payload <= 0; S_read_pending_payload <= 0;
            S_read_request <= 0; S_read_pending_valid <= 0;
            S_read_ack_meta <= 0; S_read_ack_sync <= 0;
            for (slot_index=0; slot_index<4; slot_index=slot_index+1) begin
                S_slot_nonce[slot_index] <= 0; S_slot_frame_id[slot_index] <= 0;
                S_slot_effect_config[slot_index] <= DEFAULT_EFFECT_CONFIG;
                S_slot_color_mode[slot_index] <= 0;
            end
        end else begin
            S_result_req_meta <= S_result_request;
            S_result_req_sync <= S_result_req_meta;
            S_read_ack_meta <= S_read_ack;
            S_read_ack_sync <= S_read_ack_meta;
            if (S_result_message) begin
                S_result_ack <= S_result_req_sync;
                S_last_result_payload <= S_result_payload;
                S_last_result_valid <= 1'b1;
            end
            if (I_write_start) begin
                S_active_write_slot <= I_write_slot;
                if (!USE_EXTERNAL_WRITE_PROGRESS) begin
                    S_write_count <= I_write_word ? 1 : 0;
                    S_write_active <= !(FRAME_WORDS == 1 && I_write_word);
                end
                S_slot_nonce[I_write_slot] <= S_start_nonce;
                S_slot_frame_id[I_write_slot] <= S_start_frame_id;
                S_slot_effect_config[I_write_slot] <= S_start_effect_config;
                S_slot_motion_mode[I_write_slot] <= S_start_motion_mode;
                S_slot_color_mode[I_write_slot] <= S_start_color_mode;
                S_slot_started[I_write_slot] <= S_start_valid;
                S_slot_complete[I_write_slot] <= FRAME_WORDS == 1 && I_write_word;
            end else if (USE_EXTERNAL_WRITE_PROGRESS ? I_write_complete :
                         I_write_word && S_write_active) begin
                if (USE_EXTERNAL_WRITE_PROGRESS || S_write_count == FRAME_WORDS-1) begin
                    S_slot_complete[S_active_write_slot] <= 1'b1;
                    if (!USE_EXTERNAL_WRITE_PROGRESS)
                        S_write_active <= 1'b0;
                end else begin
                    S_write_count <= S_write_count+1'b1;
                end
            end
            if (S_read_request == S_read_ack_sync) begin
                if (I_read_start) begin
                    S_read_payload <= S_read_snapshot;
                    S_read_request <= !S_read_request;
                    S_read_pending_valid <= 1'b0;
                end else if (S_read_pending_valid) begin
                    S_read_payload <= S_read_pending_payload;
                    S_read_request <= !S_read_request;
                    S_read_pending_valid <= 1'b0;
                end
            end else if (I_read_start) begin
                // Only the newest not-yet-sent read selection can be useful.
                S_read_pending_payload <= S_read_snapshot;
                S_read_pending_valid <= 1'b1;
            end
        end
    end

    (* async_reg = "true" *) reg S_read_req_meta, S_read_req_sync;
    always @(posedge I_hdmi_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            S_read_req_meta <= 0; S_read_req_sync <= 0; S_read_ack <= 0;
            O_ready <= 0; O_effect_config <= DEFAULT_EFFECT_CONFIG;
            O_motion_mode <= 0; O_color_mode <= 0; O_found <= 0;
            O_xmin <= 0; O_xmax <= 0; O_ymin <= 0; O_ymax <= 0;
            O_center_x <= 0; O_center_y <= 0;
            O_multi_valid <= 0; O_multi_hold <= 0;
            O_multi_boxes <= 0; O_multi_shapes <= 0; O_multi_overflow <= 0;
        end else begin
            S_read_req_meta <= S_read_request;
            S_read_req_sync <= S_read_req_meta;
            if (S_read_req_sync != S_read_ack) begin
                {O_ready,O_effect_config,O_motion_mode,O_color_mode,O_found,
                 O_xmin,O_xmax,O_ymin,O_ymax,O_center_x,O_center_y,
                 O_multi_valid,O_multi_hold,O_multi_shapes,O_multi_boxes,O_multi_overflow} <=
                    {S_read_payload[READ_WIDTH-1 -: 13],
                     F_expand_body(S_read_payload[BODY_WIDTH-1:0],
                         S_read_payload[READ_WIDTH-2 -: 12],S_read_payload[READ_WIDTH-1])};
                S_read_ack <= S_read_req_sync;
            end
        end
    end
endmodule

// Shared DDR progress for bridge and latency metadata. Latency excludes a
// start-coincident word; bridge includes it. Both completion outputs use the
// pre-edge count, so their consumers retain the original completion edge.
module video_ddr_write_progress #(
    parameter integer FRAME_WORDS = 172800
) (
    input wire I_clk,
    input wire I_rst_n,
    input wire I_write_start,
    input wire I_write_word,
    output wire O_bridge_complete,
    output wire O_latency_complete
);
    localparam integer COUNT_WIDTH = (FRAME_WORDS < 2) ? 1 : $clog2(FRAME_WORDS+1);
    reg [COUNT_WIDTH-1:0] S_write_count;
    reg S_write_active, S_start_word;
    wire S_bridge_terminal, S_latency_terminal;
    generate
        if (FRAME_WORDS > 1 && FRAME_WORDS%2 == 0) begin : g_even_words
            // For the production 172800 words the two terminal values
            // 172799 and 172798 differ only in their lowest bit.
            localparam [COUNT_WIDTH-2:0] LAST_HIGH = (FRAME_WORDS-1)/2;
            wire S_terminal_high = S_write_count[COUNT_WIDTH-1:1] == LAST_HIGH;
            assign S_latency_terminal = S_terminal_high && S_write_count[0];
            assign S_bridge_terminal = S_terminal_high &&
                (S_write_count[0] != S_start_word);
        end else if (FRAME_WORDS == 1) begin : g_one_word
            // start+word completes bridge inside its start branch. The
            // common counter remains active for latency's subsequent word.
            assign S_latency_terminal = 1'b1;
            assign S_bridge_terminal = !S_start_word;
        end else begin : g_odd_words
            assign S_latency_terminal = S_write_count == FRAME_WORDS-1;
            assign S_bridge_terminal = S_start_word ?
                S_write_count == FRAME_WORDS-2 : S_latency_terminal;
        end
    endgenerate
    wire S_accept_word = !I_write_start && I_write_word && S_write_active;
    assign O_bridge_complete = S_accept_word && S_bridge_terminal;
    assign O_latency_complete = S_accept_word && S_latency_terminal;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            S_write_count <= 0;
            S_write_active <= 0;
            S_start_word <= 0;
        end else if (I_write_start) begin
            S_write_count <= 0;
            S_write_active <= 1'b1;
            S_start_word <= I_write_word;
        end else if (S_accept_word) begin
            if (S_latency_terminal)
                S_write_active <= 1'b0;
            else
                S_write_count <= S_write_count+1'b1;
        end
    end
endmodule
