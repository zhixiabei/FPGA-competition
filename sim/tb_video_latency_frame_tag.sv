`timescale 1ns/1ps

// Real RAW -> LSC -> demosaic -> AWB -> mode switch -> packer path.
// Frame IDs change on every input beat after SOF to check that the sideband
// is captured with the frame marker, rather than sampled from a newer RAW.
module tb_video_latency_frame_tag;
    localparam integer W = 1280, H = 720, GROUPS = W/4;
    localparam integer FRAME_GROUPS = GROUPS*H;
    localparam integer FRAME_WORDS = W*H*3/16;
    reg clk = 0;
    always #4.830 clk = ~clk;
    reg rst_n = 0;
    reg raw_user = 0, raw_valid = 0, raw_last = 0;
    reg [39:0] raw_data = 0;
    reg [9:0] raw_id = 0;
    reg edge_request = 0, motion_request = 0;
    wire packed_user, packed_valid, active_edge, active_motion;
    wire [9:0] packed_id;
    wire [127:0] packed_data;

    isp_top #(.ENABLE_EDGE(0)) dut (
        .I_awb_hold_async(1'b0),
        .axi4s_video_aclk(clk), .I_rst_n(rst_n),
        .I_effect_config({edge_request ? 4'd2 : 4'd0,8'd0}),
        .I_motion_mode_async(motion_request),
        .I_color_mode_async(motion_request ? 2'd3 : 2'd0),
        .I_tlast(raw_last), .I_tuser(raw_user), .I_tdata(raw_data),
        .I_tvalid(raw_valid), .I_tdest(raw_id), .O_tready(1'b1),
        .O_tdata(packed_data), .O_tlast(), .O_tuser(packed_user),
        .O_tvalid(packed_valid), .I_tready(),
        .O_target_result_ready(), .O_target_found(),
        .O_target_xmin(), .O_target_xmax(), .O_target_ymin(), .O_target_ymax(),
        .O_target_center_x(), .O_target_center_y(), .O_target_pixels(),
        .O_target_frame_toggle(), .O_target_motion_mode(),
        .O_motion_mode_active(active_motion), .O_edge_mode_active(active_edge),
        .O_ae_stats_valid(), .O_ae_sum_y(), .O_ae_sample_count(),
        .O_ae_bright_count(), .O_latency_frame_id(packed_id)
    );

    integer expected_id [0:2];
    integer matrix_count [0:2], demosaic_count [0:2], packed_count [0:2];
    integer matrix_frame = -1, demosaic_frame = -1, packed_frame = -1;
    integer matrix_starts = 0, demosaic_starts = 0, packed_starts = 0;
    integer overlap_checks = 0, mode_checks = 0, raw_starts = 0;
    integer tag_checks = 0;
    reg [9:0] previous_output_id = 0;
    reg previous_output_sof = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            if (raw_user) begin
                raw_starts = raw_starts+1;
                if (raw_id == 1023) begin
                    if (packed_frame != 0 || packed_count[0] == 0 ||
                        packed_count[0] >= FRAME_WORDS)
                        $fatal(1, "The new RAW did not overlap the previous ISP tail");
                    if (packed_id != expected_id[0])
                        $fatal(1, "A new RAW changed the previous frame's output tag");
                    overlap_checks = overlap_checks+1;
                end
            end
            if (dut.u_demosaic.raw_matrix_3x3_buffer_d.O_tuser) begin
                matrix_frame = matrix_frame+1;
                matrix_starts = matrix_starts+1;
                if (matrix_frame > 2 ||
                    dut.u_demosaic.raw_matrix_3x3_buffer_d.O_frame_id !==
                        expected_id[matrix_frame][9:0])
                    $fatal(1, "Matrix SOF belongs to a short or incorrect RAW frame");
            end
            if (dut.u_demosaic.raw_matrix_3x3_buffer_d.O_tvalid) begin
                if (matrix_frame < 0 || matrix_frame > 2)
                    $fatal(1, "Matrix pixel appeared without its tagged SOF");
                matrix_count[matrix_frame] = matrix_count[matrix_frame]+1;
            end
            if (dut.m_aixs_tuser) begin
                demosaic_frame = demosaic_frame+1;
                demosaic_starts = demosaic_starts+1;
                if (demosaic_frame > 2 ||
                    dut.demosaic_frame_id !== expected_id[demosaic_frame][9:0])
                    $fatal(1, "Demosaic SOF and frame ID are not aligned");
            end
            if (dut.m_aixs_tvalid) begin
                if (demosaic_frame < 0 || demosaic_frame > 2)
                    $fatal(1, "Demosaic pixel appeared without its tagged SOF");
                demosaic_count[demosaic_frame] = demosaic_count[demosaic_frame]+1;
            end
            if (packed_user) begin
                packed_frame = packed_frame+1;
                packed_starts = packed_starts+1;
                if (packed_frame > 2 ||
                    packed_id !== expected_id[packed_frame][9:0])
                    $fatal(1, "Packed SOF tag mismatch: index=%0d tag=%0d",
                           packed_frame, packed_id);
                if (active_edge !== (packed_frame == 1) ||
                    active_motion !== (packed_frame == 1))
                    $fatal(1, "Mode switch changed the expected tagged frame");
                mode_checks = mode_checks+1;
            end
            if (packed_valid) begin
                if (packed_frame < 0 || packed_frame > 2 ||
                    packed_id !== expected_id[packed_frame][9:0])
                    $fatal(1, "Packed pixel is associated with a newer/older frame");
                if ((^packed_data) === 1'bx)
                    $fatal(1, "Unknown pixel on the real packed ISP output");
                packed_count[packed_frame] = packed_count[packed_frame]+1;
                tag_checks = tag_checks+1;
            end
            if (packed_id !== previous_output_id && !packed_user &&
                !previous_output_sof)
                $fatal(1, "Output frame ID changed outside the output SOF");
            previous_output_id = packed_id;
            previous_output_sof = packed_user;
        end else begin
            previous_output_id = 0;
            previous_output_sof = 0;
        end
    end

    task automatic blank_cycles(input integer count);
        begin
            raw_valid = 0; raw_user = 0; raw_last = 0; raw_id = 10'h155;
            repeat (count) @(negedge clk);
        end
    endtask

    task automatic send_short_frame(input integer id, input integer beats);
        begin
            for (integer beat = 0; beat < beats; beat = beat+1) begin
                raw_valid = 1;
                raw_user = beat == 0;
                raw_last = 0;
                raw_id = beat == 0 ? id[9:0] : (beat+17);
                raw_data = {4{10'd320}};
                @(negedge clk);
            end
            blank_cycles(80);
        end
    endtask

    task automatic send_complete_frame(input integer id,
                                       input bit next_mode,
                                       input integer final_blank);
        begin
            for (integer row = 0; row < H; row = row+1) begin
                for (integer group_index = 0; group_index < GROUPS;
                     group_index = group_index+1) begin
                    raw_valid = 1;
                    raw_user = row == 0 && group_index == 0;
                    raw_last = group_index == GROUPS-1;
                    raw_id = raw_user ? id[9:0] : (row+group_index+29);
                    raw_data = {4{10'd320}};
                    if (row == 200 && group_index == 100) begin
                        edge_request = next_mode;
                        motion_request = next_mode;
                    end
                    @(negedge clk);
                end
                if (row != H-1)
                    blank_cycles(32);
            end
            blank_cycles(final_blank);
        end
    endtask

    initial begin
        expected_id[0] = 1022;
        expected_id[1] = 1023;
        expected_id[2] = 1;
        for (integer index = 0; index < 3; index = index+1) begin
            matrix_count[index] = 0;
            demosaic_count[index] = 0;
            packed_count[index] = 0;
        end
        repeat (16) @(negedge clk);
        rst_n = 1;
        blank_cycles(32);
        send_short_frame(1021, 100);
        if (matrix_starts != 0 || demosaic_starts != 0 || packed_starts != 0)
            $fatal(1, "The first incomplete RAW unexpectedly produced a frame");
        send_complete_frame(1022, 1, 660);
        send_complete_frame(1023, 0, 1000);
        send_short_frame(0, 37);
        if (matrix_starts != 2 || demosaic_starts != 2 || packed_starts != 2)
            $fatal(1, "The wrapped incomplete RAW unexpectedly produced a frame");
        send_complete_frame(1, 0, 1200);
        for (integer index = 0; index < 3; index = index+1) begin
            if (matrix_count[index] != FRAME_GROUPS ||
                demosaic_count[index] != FRAME_GROUPS ||
                packed_count[index] != FRAME_WORDS)
                $fatal(1, "Incomplete tagged output frame=%0d matrix=%0d demosaic=%0d packed=%0d",
                       expected_id[index], matrix_count[index],
                       demosaic_count[index], packed_count[index]);
        end
        if (matrix_starts != 3 || demosaic_starts != 3 || packed_starts != 3 ||
            overlap_checks != 1 || mode_checks != 3 || raw_starts != 5)
            $fatal(1, "Frame-tag scenario coverage is incomplete");
        $display("VIDEO_LATENCY_FRAME_TAG_PASS raw_frames=%0d complete=3 short_without_output=2 wrap=1 overlap=%0d mode_checks=%0d tagged_words=%0d",
                 raw_starts, overlap_checks, mode_checks, tag_checks);
        $finish;
    end

    initial begin
        #20000000;
        $fatal(1, "Frame-tag integration timeout");
    end
endmodule
