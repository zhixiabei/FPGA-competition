// Passive first-pixel latency monitor. Frame tags follow the ISP and actual
// DDR slot allocation; none of these signals control the video datapath.
module video_latency_monitor #(
    parameter integer TIME_WIDTH = 24,
    parameter integer TIME_NUM = 1,
    parameter integer TIME_DEN = 50,
    parameter integer FRAME_WORDS = 172800,
    parameter integer MAX_AGE_US = 1000000
) (
    input wire I_time_clk,
    input wire I_csi_clk,
    input wire I_ddr_clk,
    input wire I_hdmi_clk,
    input wire I_rst_n,
    input wire I_raw_sof,
    input wire I_raw_valid,
    output wire [9:0] O_raw_frame_id,
    input wire I_isp_sof,
    input wire I_isp_valid,
    input wire [9:0] I_isp_frame_id,
    input wire I_write_start,
    input wire [1:0] I_write_slot,
    input wire I_write_word,
    input wire I_read_start,
    input wire [1:0] I_read_slot,
    input wire I_display_frame_start,
    output reg O_sample_strobe,
    output reg O_sample_valid,
    output reg [9:0] O_frame_id,
    output reg [19:0] O_total_us,
    output reg [19:0] O_isp_us,
    output reg [19:0] O_buffer_us
);
    localparam integer COUNT_WIDTH = $clog2(FRAME_WORDS+1);
    localparam integer AGE_BIT = $clog2(MAX_AGE_US)-1;
    localparam integer PAYLOAD_WIDTH = 11+2*TIME_WIDTH;

    // The default 24-bit microsecond counter wraps after 16.78 seconds.
    // Slot aging clears records within 1.58 seconds and stays expired until
    // the next write, so a stopped stream cannot revive on counter wrap.
    wire [TIME_WIDTH-1:0] S_time_us, S_time_gray;
    video_latency_timebase #(
        .TIME_WIDTH(TIME_WIDTH), .TIME_NUM(TIME_NUM), .TIME_DEN(TIME_DEN)
    ) u_timebase (
        .I_clk(I_time_clk), .I_rst_n(I_rst_n),
        .O_time_us(S_time_us), .O_time_gray(S_time_gray)
    );

    (* async_reg = "true" *) reg [TIME_WIDTH-1:0] S_csi_gray_meta, S_csi_gray_sync;
    (* async_reg = "true" *) reg [TIME_WIDTH-1:0] S_hdmi_gray_meta, S_hdmi_gray_sync;
    reg [TIME_WIDTH-1:0] S_csi_us, S_hdmi_us;
    function [TIME_WIDTH-1:0] F_gray_decode;
        input [TIME_WIDTH-1:0] gray;
        integer bit_index;
        begin
            F_gray_decode[TIME_WIDTH-1] = gray[TIME_WIDTH-1];
            for (bit_index=TIME_WIDTH-2; bit_index>=0; bit_index=bit_index-1)
                F_gray_decode[bit_index] =
                    F_gray_decode[bit_index+1] ^ gray[bit_index];
        end
    endfunction
    always @(posedge I_csi_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            S_csi_gray_meta <= 0; S_csi_gray_sync <= 0; S_csi_us <= 0;
        end else begin
            S_csi_gray_meta <= S_time_gray;
            S_csi_gray_sync <= S_csi_gray_meta;
            S_csi_us <= F_gray_decode(S_csi_gray_sync);
        end
    end
    always @(posedge I_hdmi_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            S_hdmi_gray_meta <= 0; S_hdmi_gray_sync <= 0; S_hdmi_us <= 0;
        end else begin
            S_hdmi_gray_meta <= S_time_gray;
            S_hdmi_gray_sync <= S_hdmi_gray_meta;
            S_hdmi_us <= F_gray_decode(S_hdmi_gray_sync);
        end
    end

    reg [9:0] S_raw_id;
    reg S_raw_first_pending;
    reg [3:0] S_raw_valid;
    reg [9:0] S_raw_ids [0:3];
    reg [TIME_WIDTH-1:0] S_raw_times [0:3];
    assign O_raw_frame_id = I_raw_sof ? S_raw_id+10'd1 : S_raw_id;

    // This start payload is held for the entire ISP frame. video_in's
    // synchronized SOF precedes its DDR capture by two clock stages.
    reg [9:0] S_start_id;
    reg S_start_valid, S_isp_first_pending;
    reg [TIME_WIDTH-1:0] S_start_raw_us;
    reg [PAYLOAD_WIDTH-1:0] S_isp_payload;
    reg S_isp_request, S_isp_ack;
    (* async_reg = "true" *) reg S_isp_ack_meta, S_isp_ack_sync;
    wire S_raw_match = S_raw_valid[I_isp_frame_id[1:0]] &&
        (S_raw_ids[I_isp_frame_id[1:0]] == I_isp_frame_id);
    integer raw_index;
    always @(posedge I_csi_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            S_raw_id <= 0; S_raw_first_pending <= 0; S_raw_valid <= 0;
            S_start_id <= 0; S_start_valid <= 0; S_start_raw_us <= 0;
            S_isp_first_pending <= 0; S_isp_payload <= 0; S_isp_request <= 0;
            S_isp_ack_meta <= 0; S_isp_ack_sync <= 0;
            for (raw_index=0; raw_index<4; raw_index=raw_index+1) begin
                S_raw_ids[raw_index] <= 0;
                S_raw_times[raw_index] <= 0;
            end
        end else begin
            S_isp_ack_meta <= S_isp_ack;
            S_isp_ack_sync <= S_isp_ack_meta;
            if (I_raw_sof) begin
                S_raw_id <= O_raw_frame_id;
                S_raw_ids[O_raw_frame_id[1:0]] <= O_raw_frame_id;
                S_raw_times[O_raw_frame_id[1:0]] <= S_csi_us;
                S_raw_valid[O_raw_frame_id[1:0]] <= I_raw_valid;
                S_raw_first_pending <= !I_raw_valid;
            end else if (S_raw_first_pending && I_raw_valid) begin
                S_raw_times[S_raw_id[1:0]] <= S_csi_us;
                S_raw_valid[S_raw_id[1:0]] <= 1'b1;
                S_raw_first_pending <= 1'b0;
            end
            if (I_isp_sof) begin
                S_start_id <= I_isp_frame_id;
                S_start_valid <= S_raw_match;
                S_start_raw_us <= S_raw_times[I_isp_frame_id[1:0]];
                S_isp_first_pending <= !I_isp_valid;
                if (I_isp_valid && S_isp_request == S_isp_ack_sync) begin
                    S_isp_payload <= {S_raw_match,I_isp_frame_id,
                        S_raw_times[I_isp_frame_id[1:0]],S_csi_us};
                    S_isp_request <= !S_isp_request;
                end
            end else if (S_isp_first_pending && I_isp_valid) begin
                S_isp_first_pending <= 1'b0;
                if (S_isp_request == S_isp_ack_sync) begin
                    S_isp_payload <= {S_start_valid,S_start_id,S_start_raw_us,S_csi_us};
                    S_isp_request <= !S_isp_request;
                end
            end
        end
    end

    (* async_reg = "true" *) reg S_isp_req_meta, S_isp_req_sync;
    (* async_reg = "true" *) reg S_age_meta, S_age_sync;
    reg S_age_seen;
    wire S_age_step = S_age_sync != S_age_seen;
    reg [9:0] S_slot_ids [0:3];
    reg [TIME_WIDTH-1:0] S_slot_raw [0:3], S_slot_isp [0:3];
    reg [3:0] S_slot_started, S_slot_metadata, S_slot_complete;
    reg [1:0] S_slot_age [0:3];
    reg [1:0] S_active_write_slot;
    reg [COUNT_WIDTH-1:0] S_write_count;
    reg S_write_active;
    reg [PAYLOAD_WIDTH-1:0] S_last_isp_payload;
    reg S_last_isp_valid;
    wire [9:0] S_message_id = S_isp_payload[2*TIME_WIDTH +: 10];
    wire S_message_valid = S_isp_payload[PAYLOAD_WIDTH-1];
    wire [TIME_WIDTH-1:0] S_message_raw = S_isp_payload[TIME_WIDTH +: TIME_WIDTH];
    wire [TIME_WIDTH-1:0] S_message_isp = S_isp_payload[0 +: TIME_WIDTH];

    // Snapshot once when the DDR read base is selected, before active video.
    reg [PAYLOAD_WIDTH-1:0] S_read_payload;
    reg S_read_request, S_read_ack;
    (* async_reg = "true" *) reg S_read_ack_meta, S_read_ack_sync;
    integer slot_index;
    always @(posedge I_ddr_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            S_isp_req_meta <= 0; S_isp_req_sync <= 0; S_isp_ack <= 0;
            S_age_meta <= 0; S_age_sync <= 0; S_age_seen <= 0;
            S_slot_started <= 0; S_slot_metadata <= 0; S_slot_complete <= 0;
            S_active_write_slot <= 0; S_write_count <= 0; S_write_active <= 0;
            S_last_isp_payload <= 0; S_last_isp_valid <= 0;
            S_read_payload <= 0; S_read_request <= 0;
            S_read_ack_meta <= 0; S_read_ack_sync <= 0;
            for (slot_index=0; slot_index<4; slot_index=slot_index+1) begin
                S_slot_ids[slot_index] <= 0;
                S_slot_raw[slot_index] <= 0; S_slot_isp[slot_index] <= 0;
                S_slot_age[slot_index] <= 0;
            end
        end else begin
            S_isp_req_meta <= S_isp_request;
            S_isp_req_sync <= S_isp_req_meta;
            S_read_ack_meta <= S_read_ack;
            S_read_ack_sync <= S_read_ack_meta;
            S_age_meta <= S_time_us[AGE_BIT];
            S_age_sync <= S_age_meta;
            S_age_seen <= S_age_sync;

            for (slot_index=0; slot_index<4; slot_index=slot_index+1) begin
                if (S_age_step) begin
                    if (S_slot_age[slot_index] != 3)
                        S_slot_age[slot_index] <= S_slot_age[slot_index]+1'b1;
                    if (S_slot_age[slot_index] >= 2) begin
                        S_slot_started[slot_index] <= 1'b0;
                        S_slot_metadata[slot_index] <= 1'b0;
                        S_slot_complete[slot_index] <= 1'b0;
                    end
                end
                if (S_isp_req_sync != S_isp_ack &&
                    S_slot_started[slot_index] &&
                    S_slot_ids[slot_index] == S_message_id &&
                    S_slot_raw[slot_index] == S_message_raw) begin
                    S_slot_raw[slot_index] <= S_message_raw;
                    S_slot_isp[slot_index] <= S_message_isp;
                    S_slot_metadata[slot_index] <= S_message_valid;
                end
            end
            if (S_isp_req_sync != S_isp_ack) begin
                S_isp_ack <= S_isp_req_sync;
                S_last_isp_payload <= S_isp_payload;
                S_last_isp_valid <= 1'b1;
            end

            if (I_write_start) begin
                S_active_write_slot <= I_write_slot;
                S_write_count <= 0;
                S_write_active <= 1'b1;
                S_slot_ids[I_write_slot] <= S_start_id;
                S_slot_raw[I_write_slot] <= S_start_raw_us;
                S_slot_started[I_write_slot] <= S_start_valid;
                if (S_isp_req_sync != S_isp_ack &&
                    S_message_id == S_start_id && S_message_raw == S_start_raw_us) begin
                    S_slot_isp[I_write_slot] <= S_message_isp;
                    S_slot_metadata[I_write_slot] <= S_message_valid;
                end else if (S_last_isp_valid &&
                    S_last_isp_payload[2*TIME_WIDTH +: 10] == S_start_id &&
                    S_last_isp_payload[TIME_WIDTH +: TIME_WIDTH] == S_start_raw_us) begin
                    S_slot_isp[I_write_slot] <= S_last_isp_payload[0 +: TIME_WIDTH];
                    S_slot_metadata[I_write_slot] <= S_last_isp_payload[PAYLOAD_WIDTH-1];
                end else
                    S_slot_metadata[I_write_slot] <= 1'b0;
                S_slot_complete[I_write_slot] <= 1'b0;
                S_slot_age[I_write_slot] <= 0;
            end else if (I_write_word && S_write_active) begin
                if (S_write_count == FRAME_WORDS-1) begin
                    S_slot_complete[S_active_write_slot] <= 1'b1;
                    S_write_active <= 1'b0;
                end else
                    S_write_count <= S_write_count+1'b1;
            end

            if (I_read_start && S_read_request == S_read_ack_sync) begin
                S_read_payload <= {
                    S_slot_started[I_read_slot] && S_slot_metadata[I_read_slot] &&
                    S_slot_complete[I_read_slot] &&
                    !(I_write_start && I_write_slot == I_read_slot) &&
                    !(S_age_step && S_slot_age[I_read_slot] >= 2),
                    S_slot_ids[I_read_slot],S_slot_raw[I_read_slot],S_slot_isp[I_read_slot]};
                S_read_request <= !S_read_request;
            end
        end
    end

    (* async_reg = "true" *) reg S_read_req_meta, S_read_req_sync;
    reg [PAYLOAD_WIDTH-1:0] S_pending_payload;
    reg S_pending_valid, S_pending_fresh;
    reg [TIME_WIDTH-1:0] S_sample_time;
    reg [PAYLOAD_WIDTH-1:0] S_sample_payload;
    reg S_sample_record_valid;
    reg [1:0] S_sample_stage;
    reg [TIME_WIDTH-1:0] S_total_delta, S_isp_delta, S_buffer_delta;
    wire [TIME_WIDTH-1:0] S_pending_age =
        S_hdmi_us-S_pending_payload[TIME_WIDTH +: TIME_WIDTH];
    wire [TIME_WIDTH-1:0] S_sample_raw =
        S_sample_payload[TIME_WIDTH +: TIME_WIDTH];
    wire [TIME_WIDTH-1:0] S_sample_isp = S_sample_payload[0 +: TIME_WIDTH];
    always @(posedge I_hdmi_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            S_read_req_meta <= 0; S_read_req_sync <= 0; S_read_ack <= 0;
            S_pending_payload <= 0; S_pending_valid <= 0; S_pending_fresh <= 0;
            S_sample_time <= 0; S_sample_payload <= 0; S_sample_record_valid <= 0;
            S_sample_stage <= 0; S_total_delta <= 0; S_isp_delta <= 0; S_buffer_delta <= 0;
            O_sample_strobe <= 0; O_sample_valid <= 0; O_frame_id <= 0;
            O_total_us <= 0; O_isp_us <= 0; O_buffer_us <= 0;
        end else begin
            S_read_req_meta <= S_read_request;
            S_read_req_sync <= S_read_req_meta;
            O_sample_strobe <= 1'b0;
            if (S_pending_age >= MAX_AGE_US)
                S_pending_valid <= 1'b0;
            if (S_read_req_sync != S_read_ack) begin
                S_pending_payload <= S_read_payload;
                S_pending_valid <= S_read_payload[PAYLOAD_WIDTH-1];
                S_pending_fresh <= 1'b1;
                S_read_ack <= S_read_req_sync;
            end
            if (I_display_frame_start) begin
                S_sample_time <= S_hdmi_us;
                S_sample_payload <= S_pending_payload;
                S_sample_record_valid <= S_pending_fresh && S_pending_valid;
                S_pending_fresh <= 1'b0;
                S_sample_stage <= 1;
            end else if (S_sample_stage == 1) begin
                S_total_delta <= S_sample_time-S_sample_raw;
                S_isp_delta <= S_sample_isp-S_sample_raw;
                S_buffer_delta <= S_sample_time-S_sample_isp;
                S_sample_stage <= 2;
            end else if (S_sample_stage == 2) begin
                O_sample_strobe <= 1'b1;
                O_sample_valid <= S_sample_record_valid &&
                    S_total_delta < MAX_AGE_US && S_isp_delta <= S_total_delta &&
                    S_total_delta <= 999999;
                O_frame_id <= S_sample_payload[2*TIME_WIDTH +: 10];
                O_total_us <= S_total_delta;
                O_isp_us <= S_isp_delta;
                O_buffer_us <= S_buffer_delta;
                S_sample_stage <= 0;
            end
        end
    end
endmodule
