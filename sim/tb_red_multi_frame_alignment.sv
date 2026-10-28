`timescale 1ns/1ps
// Production metadata integration: real top/video_in/video_out/bridge/mixer.
// Camera algorithms, pixel FIFO storage, PLL and physical DDR are boundaries.
// Accepted DDR write words are injected; addresses, allocation, completion,
// metadata CDC, read selection and mixer frame latches remain real logic.
module tb_red_multi_frame_alignment #(
    parameter integer COMPACT_MODE = 0,
    parameter integer SINGLE_TARGET = 0
);
    localparam integer FRAME_WORDS = 172800;
    localparam integer TARGETS = SINGLE_TARGET ? 1 : 4;
    reg csi_clk = 0, hdmi_clk = 0, ddr_clk = 0;
    always #7 csi_clk = ~csi_clk;
    always #5.5 hdmi_clk = ~hdmi_clk;
    always #3 ddr_clk = ~ddr_clk;
    reg rst_n = 0, camera_user = 0, camera_error = 0, injected_word = 0;
    reg [9:0] camera_id = 0, result_id = 0;
    reg [11:0] effect_config = 0;
    reg motion_mode = 0, detection_request = 0;
    reg [1:0] color_mode = 0, result_color = 0;
    reg result_ready = 0, result_found = 0, result_motion = 0;
    reg [11:0] result_xmin = 0, result_xmax = 0, result_ymin = 0, result_ymax = 0;
    reg [11:0] result_cx = 0, result_cy = 0;
    reg [3:0] result_valid = 0, result_hold = 0;
    reg [191:0] result_boxes = 0;
    reg [7:0] result_shapes = 0;
    reg result_overflow = 0;
    reg hdmi_vs = 1, hdmi_de = 0, hdmi_user = 0, hdmi_last = 0;

    integer source_frame_id = -1, current_write_slot = -1, current_read_slot = -1;
    integer write_events = 0, read_events = 0, display_checks = 0;
    integer red_four_checks = 0, motion_checks = 0, buffered_mode_checks = 0;
    integer missing_checks = 0, partial_checks = 0, late_checks = 0;
    integer rollback_checks = 0, freeze_checks = 0, geometry_checks = 0;
    integer green_checks = 0, blue_checks = 0, shape_checks = 0;
    integer mask_checks [9:12];
    reg [11:0] source_config [0:1023];
    bit source_motion [0:1023];
    reg [1:0] source_color [0:1023];
    integer ref_id [0:3], ref_words [0:3];
    reg [11:0] ref_config [0:3];
    bit ref_motion [0:3], ref_result [0:3], ref_found [0:3];
    reg [1:0] ref_color [0:3];
    reg [7:0] ref_shapes [0:3];
    reg [3:0] ref_valid [0:3], ref_hold [0:3];
    bit ref_overflow [0:3];
    integer snapshot_id = -1, snapshot_words = 0;
    reg [11:0] snapshot_config = 0;
    bit snapshot_ready = 0, snapshot_motion = 0, snapshot_found = 0;
    reg [3:0] snapshot_valid = 0, snapshot_hold = 0;
    bit snapshot_overflow = 0;
    reg [1:0] snapshot_color = 0;
    reg [7:0] snapshot_shapes = 0;

    // CNN is outside this forced-metadata boundary; retain the video-only stride.
    design_top_wrapper #(.SHOW_RAW_STATS(0),
        .RED_MULTI_ENABLE(SINGLE_TARGET ? 0 : 1),
        .SINGLE_SHAPE_ENABLE(SINGLE_TARGET),
        .ENABLE_HANDCNN(0), .FRUIT_SWITCH_CONTROL(0)) dut (
        .I_sys_clk(ddr_clk), .I_rst_n(rst_n),
        .I_mode_key_n(1'b1), .I_detect_key_n(1'b1),
        .I_effect_key_n(1'b1), .I_latency_switch(1'b0), .I_param_key_n(1'b1)
    );
    // The default keeps the original arbitrary independent-field regression.
    // Compact mode uses the production detector contract below.
    defparam dut.u_target_frame_bridge.COMPACT_MODE_PAYLOAD = COMPACT_MODE;

    function automatic integer slot_of_base(input [24:0] address);
        case (address)
            0: slot_of_base = 0;
            7000000: slot_of_base = 1;
            14000000: slot_of_base = 2;
            21000000: slot_of_base = 3;
            default: slot_of_base = -1;
        endcase
    endfunction
    function automatic integer offset_of(input [11:0] config_value);
        case (config_value[11:8])
            2, 6, 7: offset_of = 3;
            4, 8, 10, 11: offset_of = 1;
            12: offset_of = 3;
            default: offset_of = 0;
        endcase
    endfunction
    function automatic [11:0] clip_x(input integer value, input integer shift);
        clip_x = value+shift > 1279 ? 1279 : value+shift;
    endfunction
    function automatic [11:0] clip_y(input integer value, input integer shift);
        clip_y = value+shift > 719 ? 719 : value+shift;
    endfunction
    function automatic integer box_x(input integer id, input integer index);
        box_x = id == 4 ? 1268+index*4 : 220+id*7+index*180;
    endfunction
    function automatic integer box_y(input integer id, input integer index);
        box_y = id == 4 ? 710+index*3 : 240+(id%4)*35+index*70;
    endfunction
    function automatic [191:0] packed_boxes(input integer id, input integer shift);
        integer b;
        reg [191:0] value;
        begin
            value = 0;
            for (b=0; b<4; b=b+1)
                value[b*48 +: 48] = {
                    clip_y(box_y(id,b)+48,shift),clip_y(box_y(id,b),shift),
                    clip_x(box_x(id,b)+96,shift),clip_x(box_x(id,b),shift)};
            packed_boxes = value;
        end
    endfunction

    function automatic [7:0] packed_shapes(input integer id);
        integer b;
        begin
            for (b=0; b<4; b=b+1)
                packed_shapes[2*b +: 2] = 2'((id+b)%4);
        end
    endfunction

    // Decode actual base addresses after the production address registers
    // update. Never derive the reference from bridge/slot metadata registers.
    always @(posedge ddr_clk) begin
        if (rst_n && dut.u_video_in.S_frame_start) begin
            #0.2;
            current_write_slot = slot_of_base(dut.S_vi_ddr_wr_addr);
            if (current_write_slot < 0 ||
                dut.S_write_frame_slot !== current_write_slot[1:0])
                $fatal(1,"Actual write address/slot mismatch address=%0d",dut.S_vi_ddr_wr_addr);
            ref_id[current_write_slot] = source_frame_id;
            ref_words[current_write_slot] = 0;
            ref_config[current_write_slot] = source_config[source_frame_id];
            ref_motion[current_write_slot] = source_motion[source_frame_id];
            ref_color[current_write_slot] = source_color[source_frame_id];
            ref_shapes[current_write_slot] = 0;
            ref_result[current_write_slot] = 0;
            ref_found[current_write_slot] = 0;
            ref_valid[current_write_slot] = 0;
            ref_hold[current_write_slot] = 0;
            ref_overflow[current_write_slot] = 0;
            write_events = write_events+1;
        end else if (rst_n && dut.S_vi_ddr_wr_en && current_write_slot >= 0) begin
            if (ref_words[current_write_slot] < FRAME_WORDS)
                ref_words[current_write_slot] = ref_words[current_write_slot]+1;
        end
    end
    always @(posedge ddr_clk) begin
        if (rst_n && dut.u_video_out.S_video_frame_start) begin
            #0.2;
            current_read_slot = slot_of_base(dut.S_vo_ddr_rd_addr);
            if (current_read_slot < 0 ||
                dut.S_read_frame_slot !== current_read_slot[1:0])
                $fatal(1,"Actual read address/slot mismatch address=%0d",dut.S_vo_ddr_rd_addr);
            snapshot_id = ref_id[current_read_slot];
            snapshot_words = ref_words[current_read_slot];
            snapshot_config = ref_config[current_read_slot];
            snapshot_motion = ref_motion[current_read_slot];
            snapshot_color = ref_color[current_read_slot];
            snapshot_ready = snapshot_words == FRAME_WORDS && ref_result[current_read_slot];
            snapshot_found = snapshot_ready && ref_found[current_read_slot];
            snapshot_valid = snapshot_ready ? ref_valid[current_read_slot] : 0;
            snapshot_hold = snapshot_ready ? ref_hold[current_read_slot] : 0;
            snapshot_shapes = snapshot_ready ? ref_shapes[current_read_slot] : 0;
            snapshot_overflow = snapshot_ready && ref_overflow[current_read_slot];
            read_events = read_events+1;
        end
    end

    task automatic start_camera(input integer id, input [11:0] config_value,
                                input bit motion, input bit rx_error);
        integer before_count;
        begin
            @(negedge csi_clk);
            source_frame_id = id; camera_id = id;
            source_config[id] = config_value; source_motion[id] = motion;
            color_mode = motion ? 2'd0 : 2'(id%3);
            source_color[id] = color_mode;
            effect_config = config_value; motion_mode = motion;
            detection_request = motion; camera_error = rx_error;
            before_count = write_events;
            camera_user = 1;
            @(negedge csi_clk);
            camera_user = 0;
            repeat (10) @(negedge csi_clk);
            if (write_events != before_count+1 || ref_id[current_write_slot] != id)
                $fatal(1,"Camera SOF did not allocate exactly one actual write frame id=%0d",id);
            // A newer user request must not modify this frame's saved config.
            effect_config = config_value ^ 12'h100;
            detection_request = !motion;
            camera_error = 0;
        end
    endtask
    task automatic write_words(input integer count);
        begin
            @(negedge ddr_clk);
            injected_word = 1;
            repeat (count) @(negedge ddr_clk);
            injected_word = 0;
        end
    endtask
    task automatic publish(input integer id, input bit motion, input bit found_value,
                           input [3:0] valid_value, input [3:0] held_value,
                           input bit overflow_value);
        integer s;
        reg [47:0] first_box;
        reg [12:0] center_sum_x, center_sum_y;
        begin
            @(negedge csi_clk);
            result_ready = 1; result_id = id; result_motion = motion; result_found = found_value;
            result_color = source_color[id];
            result_xmin = box_x(id,0); result_xmax = box_x(id,0)+96;
            result_ymin = box_y(id,0); result_ymax = box_y(id,0)+48;
            result_cx = box_x(id,0)+48; result_cy = box_y(id,0)+24;
            result_boxes = packed_boxes(id,0);
            result_shapes = motion ? 8'd0 : packed_shapes(id);
            result_valid = valid_value; result_hold = held_value; result_overflow = overflow_value;
            if (SINGLE_TARGET) begin
                result_valid = motion ? 4'd0 : {3'b0,found_value};
                result_hold = motion ? 4'd0 : {3'b0,held_value[0]};
                result_shapes[7:2] = 6'd0;
                if (!found_value) result_shapes = 8'd0;
                result_boxes[191:48] = 144'd0;
                if (motion) result_boxes = 192'd0;
                result_overflow = 1'b0;
            end else if (COMPACT_MODE) begin
                if (motion) begin
                    result_valid = 0; result_hold = 0; result_shapes = 0;
                    result_boxes = 0; result_overflow = 0;
                end else begin
                    first_box = valid_value[0] ? result_boxes[0 +: 48] :
                        valid_value[1] ? result_boxes[48 +: 48] :
                        valid_value[2] ? result_boxes[96 +: 48] : result_boxes[144 +: 48];
                    result_xmin = first_box[11:0]; result_xmax = first_box[23:12];
                    result_ymin = first_box[35:24]; result_ymax = first_box[47:36];
                    center_sum_x = {1'b0,result_xmin}+{1'b0,result_xmax};
                    center_sum_y = {1'b0,result_ymin}+{1'b0,result_ymax};
                    result_cx = center_sum_x[12:1]; result_cy = center_sum_y[12:1];
                    if (found_value !== (|valid_value))
                        $fatal(1,"Compact integration source violated production found invariant");
                end
            end
            @(negedge csi_clk);
            result_ready = 0;
            for (s=0; s<4; s=s+1)
                if (ref_id[s] == id && ref_motion[s] == motion &&
                    ref_color[s] == result_color) begin
                    ref_result[s] = 1; ref_found[s] = found_value;
                    ref_valid[s] = result_valid; ref_hold[s] = result_hold;
                    ref_overflow[s] = result_overflow;
                    ref_shapes[s] = result_shapes;
                end
            repeat (18) @(negedge csi_clk);
        end
    endtask
    task automatic check_bridge_snapshot(input string scenario);
        integer shift;
        reg [191:0] expected_multi;
        reg [47:0] first_box;
        reg [11:0] expected_xmin,expected_xmax,expected_ymin,expected_ymax;
        reg [11:0] expected_cx,expected_cy,zero_shift;
        reg [12:0] center_sum_x,center_sum_y;
        begin
            shift = offset_of(snapshot_config);
            expected_multi = packed_boxes(snapshot_id,shift);
            expected_xmin = clip_x(box_x(snapshot_id,0),shift);
            expected_xmax = clip_x(box_x(snapshot_id,0)+96,shift);
            expected_ymin = clip_y(box_y(snapshot_id,0),shift);
            expected_ymax = clip_y(box_y(snapshot_id,0)+48,shift);
            expected_cx = clip_x(box_x(snapshot_id,0)+48,shift);
            expected_cy = clip_y(box_y(snapshot_id,0)+24,shift);
            if (SINGLE_TARGET) begin
                expected_multi[191:48] = 144'd0;
                if (snapshot_motion) expected_multi = 192'd0;
            end else if (COMPACT_MODE) begin
                if (snapshot_motion) begin
                    zero_shift = 12'(shift);
                    expected_multi = {16{zero_shift}};
                end else begin
                    // Recreate detector coordinates before the bridge adds
                    // offset; centers are averaged before its clipping.
                    expected_multi = packed_boxes(snapshot_id,0);
                    first_box = snapshot_valid[0] ? expected_multi[0 +: 48] :
                        snapshot_valid[1] ? expected_multi[48 +: 48] :
                        snapshot_valid[2] ? expected_multi[96 +: 48] :
                            expected_multi[144 +: 48];
                    center_sum_x = {1'b0,first_box[11:0]}+{1'b0,first_box[23:12]};
                    center_sum_y = {1'b0,first_box[35:24]}+{1'b0,first_box[47:36]};
                    expected_xmin = clip_x(first_box[11:0],shift);
                    expected_xmax = clip_x(first_box[23:12],shift);
                    expected_ymin = clip_y(first_box[35:24],shift);
                    expected_ymax = clip_y(first_box[47:36],shift);
                    expected_cx = clip_x(center_sum_x[12:1],shift);
                    expected_cy = clip_y(center_sum_y[12:1],shift);
                    expected_multi = packed_boxes(snapshot_id,shift);
                end
            end
            if (dut.u_hdmi_mixer.I_target_result_ready !== snapshot_ready ||
                {dut.u_hdmi_mixer.I_effect_mode,dut.u_hdmi_mixer.I_effect_param} !== snapshot_config ||
                dut.u_hdmi_mixer.I_target_motion_mode !== snapshot_motion ||
                dut.u_hdmi_mixer.I_target_color_mode !== snapshot_color ||
                dut.u_hdmi_mixer.I_target_found !== snapshot_found ||
                dut.u_hdmi_mixer.I_target_multi_valid !== snapshot_valid ||
                dut.u_hdmi_mixer.I_target_multi_hold !== snapshot_hold ||
                dut.u_hdmi_mixer.I_target_multi_shapes !== snapshot_shapes ||
                dut.u_hdmi_mixer.I_target_multi_overflow !== snapshot_overflow)
                $fatal(1,"%s selected metadata mismatch slot=%0d frame=%0d ready=%b/%b config=%h/%h mode=%b/%b",
                    scenario,current_read_slot,snapshot_id,
                    dut.u_hdmi_mixer.I_target_result_ready,snapshot_ready,
                    {dut.u_hdmi_mixer.I_effect_mode,dut.u_hdmi_mixer.I_effect_param},snapshot_config,
                    dut.u_hdmi_mixer.I_target_motion_mode,snapshot_motion);
            if (snapshot_ready &&
                (dut.u_hdmi_mixer.I_target_multi_boxes !== expected_multi ||
                 dut.u_hdmi_mixer.I_target_xmin !== expected_xmin ||
                 dut.u_hdmi_mixer.I_target_xmax !== expected_xmax ||
                 dut.u_hdmi_mixer.I_target_ymin !== expected_ymin ||
                 dut.u_hdmi_mixer.I_target_ymax !== expected_ymax ||
                 dut.u_hdmi_mixer.I_target_center_x !== expected_cx ||
                 dut.u_hdmi_mixer.I_target_center_y !== expected_cy))
                $fatal(1,"%s selected geometry mismatch source_frame=%0d config=%h",
                       scenario,snapshot_id,snapshot_config);
        end
    endtask
    task automatic active_pixels;
        reg [3:0] expected_valid, expected_hold;
        reg [191:0] expected_boxes;
        integer b, shift;
        begin
            check_bridge_snapshot("before active video");
            shift = offset_of(snapshot_config);
            expected_valid = snapshot_motion ? {3'b000,snapshot_found} : snapshot_valid;
            expected_hold = snapshot_motion ? 4'd0 : snapshot_hold;
            expected_boxes = packed_boxes(snapshot_id,shift);
            @(negedge hdmi_clk);
            hdmi_de = 1; hdmi_user = 1;
            @(negedge hdmi_clk);
            hdmi_user = 0;
            repeat (150) @(negedge hdmi_clk);
            if (dut.u_hdmi_mixer.multi_target.valid !== expected_valid ||
                dut.u_hdmi_mixer.multi_target.held !== expected_hold ||
                dut.u_hdmi_mixer.multi_target.shapes !== snapshot_shapes ||
                dut.u_hdmi_mixer.multi_target.overflow !==
                    (snapshot_overflow && !snapshot_motion) ||
                dut.u_hdmi_mixer.S_target_motion_mode !== snapshot_motion ||
                dut.u_hdmi_mixer.S_target_color_mode !== snapshot_color ||
                dut.u_hdmi_mixer.S_target_found !== snapshot_found ||
                dut.u_hdmi_mixer.S_effect_mode !== snapshot_config[11:8])
                $fatal(1,"Mixer frame latch mismatch frame=%0d valid=%b/%b held=%b/%b",
                    snapshot_id,dut.u_hdmi_mixer.multi_target.valid,expected_valid,
                    dut.u_hdmi_mixer.multi_target.held,expected_hold);
            for (b=0; b<TARGETS; b=b+1)
                if (expected_valid[b]) begin
                    if (dut.u_hdmi_mixer.multi_target.xmin[b] !== expected_boxes[b*48 +: 12] ||
                        dut.u_hdmi_mixer.multi_target.xmax[b] !== expected_boxes[b*48+12 +: 12] ||
                        dut.u_hdmi_mixer.multi_target.ymin[b] !== expected_boxes[b*48+24 +: 12] ||
                        dut.u_hdmi_mixer.multi_target.ymax[b] !== expected_boxes[b*48+36 +: 12])
                        $fatal(1,"Mixer box belongs to another source frame=%0d box=%0d",snapshot_id,b);
                    geometry_checks = geometry_checks+1;
                    shape_checks = shape_checks+1;
                end
            hdmi_last = 1;
            @(negedge hdmi_clk);
            hdmi_last = 0; hdmi_de = 0;
            repeat (5) @(negedge hdmi_clk);
            display_checks = display_checks+1;
            if (!snapshot_motion && expected_valid == (SINGLE_TARGET ? 1 : 15))
                red_four_checks = red_four_checks+1;
            if (!snapshot_motion && snapshot_ready && snapshot_color == 1)
                green_checks = green_checks+1;
            if (!snapshot_motion && snapshot_ready && snapshot_color == 2)
                blue_checks = blue_checks+1;
            if (snapshot_motion && snapshot_ready) motion_checks = motion_checks+1;
            if (snapshot_motion != motion_mode) buffered_mode_checks = buffered_mode_checks+1;
            if(snapshot_ready && snapshot_config[11:8]>=9 && snapshot_config[11:8]<=12)
                mask_checks[snapshot_config[11:8]]=mask_checks[snapshot_config[11:8]]+1;
            if (!snapshot_ready) missing_checks = missing_checks+1;
            if (snapshot_words > 0 && snapshot_words < FRAME_WORDS) partial_checks = partial_checks+1;
        end
    endtask
    task automatic display_frame;
        integer before_count;
        begin
            before_count = read_events;
            @(negedge hdmi_clk);
            hdmi_vs = 0;
            repeat (9) @(negedge hdmi_clk);
            hdmi_vs = 1;
            repeat (18) @(negedge hdmi_clk);
            if (read_events != before_count+1)
                $fatal(1,"Vsync did not select exactly one actual DDR read base");
            active_pixels();
        end
    endtask

    initial begin
        force dut.S_csi_rx_clk = csi_clk;
        force dut.S_hdmi_pixel_clk = hdmi_clk;
        force dut.S_hdmi_serial_clk = hdmi_clk;
        force dut.S_ddr_clk = ddr_clk;
        force dut.S_24m_clk = csi_clk;
        force dut.S_100m_clk = ddr_clk;
        force dut.S_pll_lock = rst_n;
        force dut.S_init_calib_complete = rst_n;
        force dut.S_cam_status = 4'hf;
        force dut.S_cam_fail_index = 8'd0;
        force dut.S_ISP_O_tuser = camera_user;
        force dut.S_ISP_O_tvalid = 1'b0;
        force dut.S_ISP_O_tdata = 128'd0;
        force dut.S_isp_frame_id = camera_id;
        force dut.S_ISP_effect_config = effect_config;
        force dut.S_ISP_motion_mode_active = motion_mode;
        force dut.S_ISP_color_mode_active = color_mode;
        force dut.S_motion_mode_requested = detection_request;
        force dut.S_ISP_target_result_ready = result_ready;
        force dut.S_ISP_target_result_frame_id = result_id;
        force dut.S_ISP_target_found = result_found;
        force dut.S_ISP_target_motion_mode = result_motion;
        force dut.S_ISP_target_color_mode = result_color;
        force dut.S_ISP_target_xmin = result_xmin;
        force dut.S_ISP_target_xmax = result_xmax;
        force dut.S_ISP_target_ymin = result_ymin;
        force dut.S_ISP_target_ymax = result_ymax;
        force dut.S_ISP_target_center_x = result_cx;
        force dut.S_ISP_target_center_y = result_cy;
        force dut.S_ISP_target_multi_valid = result_valid;
        force dut.S_ISP_target_multi_hold = result_hold;
        force dut.S_ISP_target_multi_boxes = result_boxes;
        force dut.S_ISP_target_multi_shapes = result_shapes;
        force dut.S_ISP_target_multi_overflow = result_overflow;
        force dut.S_hdmi_vsync = hdmi_vs;
        force dut.S_hdmi_hsync = 1'b0;
        force dut.S_hdmi_de = hdmi_de;
        force dut.S_hdmi_user = hdmi_user;
        force dut.S_hdmi_last = hdmi_last;
        force dut.S_video_rd_data = 24'h202020;
        force dut.S_ddr_user_ready = 1'b1;
        force dut.S_ddr_user_rd_valid = 1'b0;
        force dut.u_video_in.S_fifo_rd_num = 9'd0;
        force dut.u_video_out.S_fifo_wr_num = 9'd511;
        force dut.u_video_in.I_mipi_rx_error = camera_error;
        force dut.u_video_in.I_display_pause = 1'b0;
        force dut.u_video_in.O_ddr_user_wr_en = injected_word;
        for (integer s=0; s<4; s=s+1) begin
            ref_id[s] = -1; ref_words[s] = 0; ref_config[s] = 0;
            ref_motion[s] = 0; ref_result[s] = 0; ref_found[s] = 0;
            ref_valid[s] = 0; ref_hold[s] = 0; ref_overflow[s] = 0;
            ref_color[s] = 0; ref_shapes[s] = 0;
        end
        repeat (12) @(negedge csi_clk);
        rst_n = 1;
        repeat (10) @(negedge csi_clk);
        for(integer mask_mode=9;mask_mode<=12;mask_mode=mask_mode+1)
            mask_checks[mask_mode]=0;

        start_camera(0,12'h2a5,0,0); write_words(FRAME_WORDS); publish(0,0,1,15,4,0);
        start_camera(1,12'h4b6,0,0); write_words(FRAME_WORDS); publish(1,0,1,15,2,1);
        start_camera(2,12'h8c7,1,0); write_words(FRAME_WORDS);
        display_frame(); // Actual reader selects source frame 0, despite K2 motion mode now active.
        publish(2,1,1,0,0,0);
        start_camera(3,12'h6d8,0,0); write_words(FRAME_WORDS);
        display_frame(); // Frame 1 remains red with four independent statuses.
        start_camera(4,12'h7e9,0,0); write_words(FRAME_WORDS);
        repeat (2000) @(negedge csi_clk);
        publish(3,0,1,15,8,0); late_checks = late_checks+1;
        display_frame(); // Frame 2 retains its motion mode and one box.
        publish(4,0,1,15,1,0);
        start_camera(5,12'h001,0,0); write_words(FRAME_WORDS);
        display_frame(); // Late frame-3 result kept frame-3's +3 pixel configuration.
        if (snapshot_id != 3 || !snapshot_ready)
            $fatal(1,"Late result not displayed on its actual source frame");
        start_camera(6,12'h812,0,0); write_words(FRAME_WORDS); publish(6,0,1,15,4,0);
        display_frame(); // Frame 4 clips all four boxes at the image boundary.
        start_camera(7,12'h323,0,0); write_words(FRAME_WORDS-1); publish(7,0,1,15,2,0);
        start_camera(8,12'h434,0,0); write_words(FRAME_WORDS); publish(8,0,1,15,1,0);
        display_frame(); // Frame 6 is complete.
        start_camera(9,12'h245,0,0); write_words(FRAME_WORDS); publish(9,0,1,15,8,0);
        display_frame(); // Frame 7 has a result but only 172799 accepted write words.
        if (snapshot_id != 7 || snapshot_ready)
            $fatal(1,"Truncated frame retained visible boxes");
        start_camera(10,12'h656,0,1); // Error rollback overwrites frame 9's actual slot.
        if (ref_id[current_write_slot] != 10 || current_write_slot != 1)
            $fatal(1,"Error case did not exercise actual DDR rollback allocation");
        write_words(FRAME_WORDS);
        publish(9,0,1,15,0,1); // Late obsolete result cannot restore frame 9 in reused slot.
        rollback_checks = rollback_checks+1;
        display_frame();
        start_camera(11,12'h867,1,0); write_words(FRAME_WORDS); publish(11,1,1,0,0,0);
        start_camera(12,12'h078,0,0); write_words(FRAME_WORDS); publish(12,0,0,0,0,0);
        display_frame(); // Reused frame-10 slot still has no result.
        if (snapshot_id != 10 || snapshot_ready)
            $fatal(1,"Old frame-9 result contaminated rollback replacement");
        publish(10,0,1,15,4,0);
        check_bridge_snapshot("late result cannot mutate already frozen read");
        if (dut.u_hdmi_mixer.multi_target.valid !== 0)
            $fatal(1,"Late result changed an active mixer frame");
        freeze_checks = freeze_checks+1;
        display_frame(); // Only a new read selection admits frame-10's late result.
        if (snapshot_id != 10 || !snapshot_ready)
            $fatal(1,"Current source result did not fill rollback slot");
        start_camera(13,12'h789,0,0); write_words(FRAME_WORDS); publish(13,0,1,15,8,0);
        display_frame(); // Frame 11's motion mode survives return to red mode.
        start_camera(14,12'h49a,0,0); write_words(FRAME_WORDS); publish(14,0,1,15,2,0);
        publish(10,0,1,15,0,1); // The source context and physical slot are both replaced.
        display_frame(); // Frame 12 is a valid no-target result.
        start_camera(15,12'h2ab,0,0); write_words(FRAME_WORDS); publish(15,0,1,15,1,0);
        display_frame();
        start_camera(16,12'h8bc,0,0); write_words(FRAME_WORDS); publish(16,0,1,15,4,0);
        display_frame(); // Reused frame-14 slot must keep frame-14 geometry.
        if (snapshot_id != 14 || !snapshot_ready)
            $fatal(1,"Reused slot source frame mismatch");
        check_bridge_snapshot("old replaced frame never restores its four boxes");
        start_camera(17,12'h95a,0,0); write_words(FRAME_WORDS); publish(17,0,1,15,4,0);
        start_camera(18,12'ha6b,0,0); write_words(FRAME_WORDS); publish(18,0,1,15,2,0);
        display_frame();
        start_camera(19,12'hb7c,0,0); write_words(FRAME_WORDS); publish(19,0,1,15,1,0);
        display_frame();
        start_camera(20,12'hc8d,0,0); write_words(FRAME_WORDS); publish(20,0,1,15,8,0);
        display_frame();
        start_camera(21,12'h000,0,0); write_words(FRAME_WORDS); publish(21,0,1,15,4,0);
        display_frame();
        start_camera(22,12'h000,0,0); write_words(FRAME_WORDS); publish(22,0,1,15,2,0);
        display_frame();
        for(integer mask_mode=9;mask_mode<=12;mask_mode=mask_mode+1)
            if(mask_checks[mask_mode]==0)
                $fatal(1,"Missing production mask-mode frame/shape alignment mode=%0d",mask_mode);
        if (write_events != 23 || red_four_checks < 8 || motion_checks < 2 ||
            buffered_mode_checks < 2 || partial_checks != 1 || late_checks != 1 ||
            rollback_checks != 1 || freeze_checks != 1 ||
            geometry_checks < (SINGLE_TARGET ? 14 : 30) ||
            green_checks == 0 || blue_checks == 0 ||
            shape_checks < (SINGLE_TARGET ? 14 : 30))
            $fatal(1,"Production multi-frame integration coverage incomplete");
        $display("RED_MULTI_FRAME_ALIGNMENT_PASS write=%0d read=%0d display=%0d red_four=%0d motion=%0d buffered_mode=%0d partial=%0d late=%0d rollback=%0d freeze=%0d geometry=%0d green=%0d blue=%0d shapes=%0d words=%0d mask_modes=9..12 compact=%0d single=%0d",
            write_events,read_events,display_checks,red_four_checks,motion_checks,
            buffered_mode_checks,partial_checks,late_checks,rollback_checks,
            freeze_checks,geometry_checks,green_checks,blue_checks,shape_checks,FRAME_WORDS,
            COMPACT_MODE,SINGLE_TARGET);
        $finish;
    end
    initial begin
        #30000000;
        $fatal(1,"Production multi-frame integration timed out");
    end
endmodule
