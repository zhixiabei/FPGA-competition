// Associate detector results with the actual DDR allocation, then freeze the
// selected slot before display. Only metadata crosses these clock domains.
module target_frame_bridge #(
    parameter integer FRAME_WORDS = 172800,
    parameter [11:0] DEFAULT_EFFECT_CONFIG = 12'd0
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
    output reg O_multi_overflow
);
    // Clipped 720p coordinates need 11 x bits and 10 y bits. Keep the
    // external 12-bit ports while storing only significant payload bits.
    localparam integer BOX_WIDTH = 42;
    localparam integer BODY_WIDTH = 244;
    localparam integer RESULT_WIDTH = 16+10+BODY_WIDTH;
    localparam integer READ_WIDTH = BODY_WIDTH+13;
    localparam integer COUNT_WIDTH = (FRAME_WORDS < 2) ? 1 : $clog2(FRAME_WORDS+1);

    function [1:0] F_offset;
        input [11:0] effect_config;
        begin
            case (effect_config[11:8])
                4'd2, 4'd6, 4'd7: F_offset = 2'd3;
                4'd4, 4'd8: F_offset = 2'd1;
                default: F_offset = 2'd0;
            endcase
        end
    endfunction
    function [11:0] F_clip_x;
        input [11:0] value;
        input [1:0] offset;
        reg [12:0] shifted;
        begin
            shifted = {1'b0,value}+offset;
            F_clip_x = (shifted > 13'd1279) ? 12'd1279 : shifted[11:0];
        end
    endfunction
    function [11:0] F_clip_y;
        input [11:0] value;
        input [1:0] offset;
        reg [12:0] shifted;
        begin
            shifted = {1'b0,value}+offset;
            F_clip_y = (shifted > 13'd719) ? 12'd719 : shifted[11:0];
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
    function [276:0] F_expand_body;
        input [BODY_WIDTH-1:0] body;
        integer index;
        begin
            F_expand_body = {body[243:240],F_expand_single(body[239:177]),
                             body[176:169],192'b0,body[0]};
            for (index=0; index<4; index=index+1)
                F_expand_body[1+48*index +: 48] =
                    F_expand_box(body[1+BOX_WIDTH*index +: BOX_WIDTH]);
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
    wire [RESULT_WIDTH-1:0] S_new_result = {
        S_context_nonce[S_context_index],I_result_frame_id,
        I_result_motion_mode,I_result_color_mode,I_result_found,
        F_pack_single({
        F_clip_x(I_result_xmin,S_result_offset),
        F_clip_x(I_result_xmax,S_result_offset),
        F_clip_y(I_result_ymin,S_result_offset),
        F_clip_y(I_result_ymax,S_result_offset),
        F_clip_x(I_result_center_x,S_result_offset),
        F_clip_y(I_result_center_y,S_result_offset)}),
        I_multi_valid,I_multi_hold,S_adjusted_boxes,I_multi_overflow};
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
    integer slot_index;
    always @(posedge I_ddr_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            S_result_req_meta <= 0; S_result_req_sync <= 0; S_result_ack <= 0;
            S_slot_motion_mode <= 0; S_slot_started <= 0;
            S_slot_complete <= 0; S_slot_result_valid <= 0;
            S_active_write_slot <= 0; S_write_count <= 0; S_write_active <= 0;
            S_last_result_payload <= 0; S_last_result_valid <= 0;
            S_read_payload <= 0; S_read_pending_payload <= 0;
            S_read_request <= 0; S_read_pending_valid <= 0;
            S_read_ack_meta <= 0; S_read_ack_sync <= 0;
            for (slot_index=0; slot_index<4; slot_index=slot_index+1) begin
                S_slot_nonce[slot_index] <= 0; S_slot_frame_id[slot_index] <= 0;
                S_slot_effect_config[slot_index] <= DEFAULT_EFFECT_CONFIG;
                S_slot_color_mode[slot_index] <= 0;
                S_slot_result[slot_index] <= 0;
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
                for (slot_index=0; slot_index<4; slot_index=slot_index+1) begin
                    if (S_slot_started[slot_index] &&
                        S_slot_nonce[slot_index] == S_message_nonce &&
                        S_slot_frame_id[slot_index] == S_message_id &&
                        S_slot_motion_mode[slot_index] == S_message_motion &&
                        S_slot_color_mode[slot_index] == S_message_color &&
                        !(I_write_start && I_write_slot == slot_index)) begin
                        S_slot_result[slot_index] <= S_result_payload[BODY_WIDTH-1:0];
                        S_slot_result_valid[slot_index] <= 1'b1;
                    end
                end
            end
            if (I_write_start) begin
                S_active_write_slot <= I_write_slot;
                S_write_count <= I_write_word ? 1 : 0;
                S_write_active <= !(FRAME_WORDS == 1 && I_write_word);
                S_slot_nonce[I_write_slot] <= S_start_nonce;
                S_slot_frame_id[I_write_slot] <= S_start_frame_id;
                S_slot_effect_config[I_write_slot] <= S_start_effect_config;
                S_slot_motion_mode[I_write_slot] <= S_start_motion_mode;
                S_slot_color_mode[I_write_slot] <= S_start_color_mode;
                S_slot_started[I_write_slot] <= S_start_valid;
                S_slot_complete[I_write_slot] <= FRAME_WORDS == 1 && I_write_word;
                if (S_message_matches_start) begin
                    S_slot_result[I_write_slot] <= S_result_payload[BODY_WIDTH-1:0];
                    S_slot_result_valid[I_write_slot] <= 1'b1;
                end else if (S_last_matches_start) begin
                    S_slot_result[I_write_slot] <= S_last_result_payload[BODY_WIDTH-1:0];
                    S_slot_result_valid[I_write_slot] <= 1'b1;
                end else begin
                    S_slot_result_valid[I_write_slot] <= 1'b0;
                end
            end else if (I_write_word && S_write_active) begin
                if (S_write_count == FRAME_WORDS-1) begin
                    S_slot_complete[S_active_write_slot] <= 1'b1;
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
            O_multi_boxes <= 0; O_multi_overflow <= 0;
        end else begin
            S_read_req_meta <= S_read_request;
            S_read_req_sync <= S_read_req_meta;
            if (S_read_req_sync != S_read_ack) begin
                {O_ready,O_effect_config,O_motion_mode,O_color_mode,O_found,
                 O_xmin,O_xmax,O_ymin,O_ymax,O_center_x,O_center_y,
                 O_multi_valid,O_multi_hold,O_multi_boxes,O_multi_overflow} <=
                    {S_read_payload[READ_WIDTH-1 -: 13],
                     F_expand_body(S_read_payload[BODY_WIDTH-1:0])};
                S_read_ack <= S_read_req_sync;
            end
        end
    end
endmodule
