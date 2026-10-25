`timescale 1ns/1ps
// Confirmation regression through the production result source and display.
// The historical >100 ms expiry regression remains in the baseline test logs. Exercise the production result source, 68-bit mailbox and
// HDMI frame commit; force only the inference completion/decoder interfaces.
module tb_handfixed_refresh;
    reg clk=0;always #7.5 clk=~clk;
    reg pixel_clk=0;always #6.667 pixel_clk=~pixel_clk;
    reg rst_n=0,memory_error=0,done=0,found=1,key4_n=1;
    reg [2:0] decoded_class=3;
    reg signed [15:0] rx=100,ry=120;
    reg [15:0] side=240;
    wire valid,box_valid;
    wire [2:0] label;
    wire [11:0] x1,y1,x2,y2;
    wire [15:0] result_frame;
    integer completed=0,source_updates=0,hold_cycles=1000;
    handfixed_system #(.KEY4_CONTROL(1),.KEY_DEBOUNCE_CYCLES(4)) dut(.key4_n(key4_n),.clk(clk),.rst_n(rst_n),.calibrated(1'b1),.uart_rx(1'b1),.uart_tx(),
        .memory_error(memory_error),.frame_start(1'b0),.frame_slot(2'd0),.video_write(1'b0),
        .video_addr(25'd0),.video_data(128'd0),.mem_valid(),.mem_write(),.mem_addr(),.mem_data(),
        .mem_ready(1'b0),.mem_rsp_valid(1'b0),.mem_rsp_data(128'd0),
        .result_valid(valid),.result_class(label),.model_ready(),.operation(),.runtime_status(),
        .box_valid(box_valid),.box_x1(x1),.box_y1(y1),.box_x2(x2),.box_y2(y2),.result_frame(result_frame));

    // Same payload, event capture and acknowledged CDC as design_top_wrapper.
    reg [67:0] payload=0,seen=0;
    wire [67:0] hdmi_result;
    always @(posedge clk or negedge rst_n)
        if(!rst_n) payload<=0;
        else if(valid) payload<={result_frame,label,box_valid,y2,y1,x2,x1};
    camera_diag_cdc #(.WIDTH(68)) cdc(.I_src_clk(clk),.I_dst_clk(pixel_clk),.I_rst_n(rst_n),
        .I_src_data(payload),.O_dst_data(hdmi_result));
    always @(posedge pixel_clk or negedge rst_n)
        if(!rst_n) seen<=0;else seen<=hdmi_result;
    reg user=0;
    integer pixels=0;
    // Accelerated frame boundaries also cover arbitrarily many display frames
    // between completed inferences. The production timeout parameter is zero.
    always @(negedge pixel_clk) begin
        pixels=pixels+1;user=rst_n && pixels%1000==0;
    end
    hdmi_mixer #(.HANDCNN_DYNAMIC_ROI(1),.CNN_RESULT_TIMEOUT_FRAMES(0)) display(
        .I_clk(pixel_clk),.I_rst_n(rst_n),.I_video_vsync(1'b0),.I_video_hsync(1'b0),
        .I_video_de(1'b0),.I_video_user(user),.I_video_last(1'b0),.I_effect_mode(4'd1),.I_effect_param(8'd0),
        .I_debug_status(4'd0),.I_cam_fail_index(8'd0),.I_raw_stats_valid(1'b0),.I_raw_stats_data(45'd0),
        .I_ae_readout_valid(1'b0),.I_ae_readout_data(28'd0),.I_latency_sample_strobe(1'b0),.I_latency_show(1'b0),
        .I_latency_sample_valid(1'b0),.I_latency_total_us(20'd0),.I_latency_isp_us(20'd0),.I_latency_buffer_us(20'd0),
        .I_cnn_result_valid(hdmi_result!=seen),.I_cnn_class(hdmi_result[51:49]),
        .I_hand_box_valid(hdmi_result[48]),.I_hand_box(hdmi_result[47:0]),
        .I_resnet_probe_status(32'd0),.I_video_rd_data(24'd0),
        .I_target_result_ready(1'b0),.I_target_found(1'b0),.I_target_motion_mode(1'b0),.I_target_color_mode(2'd0),
        .I_target_xmin(12'd0),.I_target_xmax(12'd0),.I_target_ymin(12'd0),.I_target_ymax(12'd0),
        .I_target_center_x(12'd0),.I_target_center_y(12'd0),.I_target_multi_valid(4'd0),.I_target_multi_hold(4'd0),
        .I_target_multi_boxes(192'd0),.I_target_multi_overflow(1'b0),
        .O_video_rd_en(),.O_display_frame_start(),.O_hdmi_vsync(),.O_hdmi_hsync(),.O_hdmi_de(),.O_hdmi_data());
    always @(posedge clk) if(rst_n && valid) source_updates=source_updates+1;
    task classifier_result(input integer frame_id,input integer cls,input integer expected_class);
        begin
            @(negedge clk);dut.state=6;dut.read_frame=frame_id;decoded_class=cls;done=1;
            @(negedge clk);done=0;completed=completed+1;
            if(!valid || label!=expected_class || !box_valid || result_frame!=frame_id || dut.result_count!=completed)
                $fatal(1,"confirmed publication failed raw=%0d got=%0d want=%0d frame=%0d",cls,label,expected_class,frame_id);
            display_result(expected_class,1,{12'd600,12'd120,12'd880,12'd400});
        end
    endtask
    task display_result(input integer cls,input integer has_box,input [47:0] coords);
        begin
            repeat(2200) @(negedge pixel_clk);
            if(display.S_cnn_class!==cls || display.S_hand_box[48]!==has_box[0] ||
               (has_box && display.S_hand_box[47:0]!==coords))
                $fatal(1,"HDMI result mismatch label=%0d box=%h expected=%0d/%h",display.S_cnn_class,display.S_hand_box,cls,coords);
        end
    endtask
    task key_press;
        begin
            @(negedge clk);key4_n=0;repeat(12) @(negedge clk);
            key4_n=1;repeat(12) @(negedge clk);
        end
    endtask
    task discarded_result(input integer id,input integer cls);
        integer count_before;
        begin
            count_before=dut.result_count;
            @(negedge clk);dut.state=6;dut.read_frame=id;decoded_class=cls;done=1;
            @(negedge clk);done=0;
            if(valid || label!=1 || dut.result_count!=count_before) $fatal(1,"paused/stale result published");
        end
    endtask
    initial begin
        force dut.loader.model_ready=1'b0;
        force dut.dec_done=done;force dut.dec_class=decoded_class;
        force dut.pp_done=1'b0;force dut.core_done=1'b0;force dut.core_fault=1'b0;
        repeat(10) @(negedge clk);rst_n=1;
        display_result(1,1,{12'd600,12'd120,12'd880,12'd400});
        if(dut.run_enabled || dut.capture_phase!=0 || dut.pp_start || dut.core_start) $fatal(1,"boot not stopped");
        key_press();if(!dut.run_enabled) $fatal(1,"start failed");
        classifier_result(1,3,1);classifier_result(2,3,3);
        // Stop while a decoder result is in flight. It must never relabel.
        @(negedge clk);dut.state=6;
        key_press();if(dut.run_enabled || label!=1 || !box_valid) $fatal(1,"stop failed");
        display_result(1,1,{12'd600,12'd120,12'd880,12'd400});
        // Restart before the old work completes. It is still invalid.
        key_press();if(!dut.run_enabled) $fatal(1,"restart failed");
        discarded_result(3,4);
        // A new scheduling event is required to clear discard_compute.
        @(negedge clk);dut.pending=1;dut.pending_frame=4;
        @(negedge clk);if(!dut.pp_start || dut.discard_compute) $fatal(1,"fresh scheduling failed");
        classifier_result(4,4,1);classifier_result(5,4,4);
        // Old capture completion after stop/restart must not become pending.
        @(negedge clk);dut.state=0;dut.capture_phase=2;
        force dut.snap_busy=1'b1;force dut.snap_done=1'b0;
        key_press();key_press();
        @(negedge clk);force dut.snap_done=1'b1;
        @(negedge clk);force dut.snap_done=1'b0;
        if(dut.pending || dut.capture_phase!=0) $fatal(1,"old capture reused after restart");
        release dut.snap_busy;release dut.snap_done;
        @(negedge clk);dut.pending=1;dut.pending_frame=6;
        @(negedge clk);
        classifier_result(6,2,1);classifier_result(7,2,2);
        key_press();display_result(1,1,{12'd600,12'd120,12'd880,12'd400});
        repeat(100) @(negedge clk);
        if(dut.capture_phase || dut.pending || label!=1) $fatal(1,"paused work started");
        // model_ready stays high and weights are not reset by KEY4.
        force dut.loader.model_ready=1'b1;
        repeat(100) @(negedge clk);
        if(!dut.model_ready || dut.capture_phase || dut.result_count!=6) $fatal(1,"paused loader/counter failed");
        if(source_updates!=10) $fatal(1,"missing/spurious events %0d",source_updates);
        rst_n=0;repeat(10) @(negedge clk);
        if(label!=1 || box_valid || dut.run_enabled) $fatal(1,"reset failed");
        $display("HANDFIXED_REFRESH_PASS KEY4 stopped_boot toggle stop_during_decode rapid_restart stale_capture fixed480 atomic_cdc weights_preserved");$finish;
    end
    initial begin #400000000;$fatal(1,"fixed refresh timeout");end
endmodule
