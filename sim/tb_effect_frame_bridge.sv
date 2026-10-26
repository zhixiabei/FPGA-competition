`timescale 1ns/1ps
module tb_effect_frame_bridge;
    reg csi_clk=0, ddr_clk=0, hdmi_clk=0, hdmi_running=1;
    always #7 csi_clk=~csi_clk;
    always #3 ddr_clk=~ddr_clk;
    always #5.5 if(hdmi_running) hdmi_clk=~hdmi_clk;
    reg rst_n=0, frame_start=0, write_start=0, read_start=0;
    reg [11:0] effect_request=12'h123;
    reg [9:0] frame_id=0;
    reg [1:0] write_slot=0, read_slot=0;
    wire [11:0] out_config, legacy_config;
    integer checks=0, comparisons=0;
    effect_frame_bridge #(.DEFAULT_EFFECT_CONFIG(12'h123)) dut (
        .I_csi_clk(csi_clk),.I_ddr_clk(ddr_clk),.I_hdmi_clk(hdmi_clk),
        .I_rst_n(rst_n),.I_frame_start(frame_start),.I_effect_config(effect_request),
        .I_write_start(write_start),.I_write_slot(write_slot),
        .I_read_start(read_start),.I_read_slot(read_slot),.O_effect_config(out_config)
    );
    // Compare the retained frame-config semantics with the original bridge,
    // including simultaneous events, busy mailboxes and superseded requests.
    target_frame_bridge #(.DEFAULT_EFFECT_CONFIG(12'h123)) reference_dut (
        .I_csi_clk(csi_clk),.I_ddr_clk(ddr_clk),.I_hdmi_clk(hdmi_clk),
        .I_rst_n(rst_n),.I_frame_start(frame_start),.I_frame_id(frame_id),
        .I_effect_config(effect_request),.I_motion_mode(1'b0),.I_color_mode(2'd0),
        .I_result_ready(1'b0),.I_result_frame_id(10'd0),
        .I_result_found(1'b0),.I_result_motion_mode(1'b0),.I_result_color_mode(2'd0),
        .I_result_xmin(12'd0),.I_result_xmax(12'd0),
        .I_result_ymin(12'd0),.I_result_ymax(12'd0),
        .I_result_center_x(12'd0),.I_result_center_y(12'd0),
        .I_multi_valid(4'd0),.I_multi_hold(4'd0),.I_multi_boxes(192'd0),
        .I_multi_overflow(1'b0),.I_write_start(write_start),.I_write_slot(write_slot),
        .I_write_word(1'b0),.I_read_start(read_start),.I_read_slot(read_slot),
        .O_effect_config(legacy_config)
    );
    always @(posedge hdmi_clk) begin
        #1;
        if(rst_n) begin
            if(out_config !== legacy_config)
                $fatal(1,"Frame-config mismatch new=%h original=%h",out_config,legacy_config);
            comparisons=comparisons+1;
        end
    end
    task automatic allocate(input [1:0] slot,input [11:0] value);
        @(negedge csi_clk);effect_request=value;frame_start=1;frame_id=frame_id+1;
        @(negedge csi_clk);frame_start=0;
        repeat(4) @(negedge ddr_clk);
        write_slot=slot;write_start=1;
        @(negedge ddr_clk);write_start=0;
    endtask
    task automatic select_slot(input [1:0] slot);
        @(negedge ddr_clk);read_slot=slot;read_start=1;
        @(negedge ddr_clk);read_start=0;
    endtask
    task automatic expect_config(input [11:0] value);
        repeat(20) @(negedge hdmi_clk);
        if(out_config !== value) $fatal(1,"Expected %h, got %h",value,out_config);
        checks=checks+1;
    endtask
    initial begin
        repeat(4) @(negedge csi_clk);rst_n=1;
        expect_config(12'h123);
        for(integer i=0;i<4;i=i+1) begin
            select_slot(i);expect_config(12'h123);
            allocate(i,12'h200+i);
        end
        for(integer i=0;i<4;i=i+1) begin
            select_slot(i);expect_config(12'h200+i);
        end
        // A new camera configuration must not alter an already buffered slot.
        allocate(2,12'h8ab);select_slot(0);expect_config(12'h200);

        // Freeze the in-flight selection while HDMI is stopped, then reuse
        // that slot. Also replace a pending selection with the newest one.
        @(negedge hdmi_clk);hdmi_running=0;
        select_slot(1);allocate(1,12'h777);
        select_slot(1);select_slot(2);allocate(2,12'h888);
        hdmi_running=1;
        expect_config(12'h8ab);
        select_slot(1);expect_config(12'h777);
        select_slot(2);expect_config(12'h888);

        // Deterministic stress across unrelated clock phases and slot reuse.
        for(integer i=0;i<200;i=i+1) begin
            allocate(i%4,(i*37+19)%4096);
            select_slot((i+1)%4);
            if(i%5==0) select_slot(i%4);
        end
        expect_config((196*37+19)%4096);
        // Reset must clear stale and pending frame configurations.
        @(negedge ddr_clk);rst_n=0;
        repeat(4) @(negedge csi_clk);rst_n=1;
        select_slot(3);expect_config(12'h123);
        $display("EFFECT_FRAME_BRIDGE_PASS checks=%0d comparisons=%0d slots=4 frozen_payload=1 pending_latest=1 reset=1",checks,comparisons);
        $finish;
    end
    initial begin
        #1000000;$fatal(1,"Effect frame bridge timeout");
    end
endmodule
