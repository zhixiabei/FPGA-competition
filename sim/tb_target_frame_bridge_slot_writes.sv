`timescale 1ns/1ps

module tb_target_frame_bridge_slot_writes;
    reg csi_clk = 0, ddr_clk = 0, hdmi_clk = 0;
    always #7 csi_clk = ~csi_clk;
    always #3 ddr_clk = ~ddr_clk;
    always #5.5 hdmi_clk = ~hdmi_clk;
    reg rst_n = 0, frame_start = 0, motion_mode = 0;
    reg [1:0] color_mode = 0, result_color = 0;
    reg [9:0] frame_id = 0, result_id = 0;
    reg [11:0] effect_config = 0;
    reg result_ready = 0, result_motion = 0, result_found = 0;
    reg [11:0] xmin = 0, xmax = 0, ymin = 0, ymax = 0, cx = 0, cy = 0;
    reg [3:0] multi_valid = 0, multi_hold = 0;
    reg [191:0] boxes = 0;
    reg [7:0] shapes = 0;
    reg overflow = 0, write_start = 0, write_word = 0, read_start = 0;
    reg [1:0] write_slot = 0, read_slot = 0;
    wire ready, found, out_motion, out_overflow;
    wire [1:0] out_color;
    wire [11:0] out_config, out_xmin, out_xmax, out_ymin, out_ymax, out_cx, out_cy;
    wire [3:0] out_valid, out_hold;
    wire [191:0] out_boxes;
    wire [7:0] out_shapes;
    wire [297:0] output_tuple = {
        ready,out_config,out_motion,out_color,found,
        out_xmin,out_xmax,out_ymin,out_ymax,out_cx,out_cy,
        out_valid,out_hold,out_shapes,out_boxes,out_overflow};
    reg [251:0] held_slot_result;
    integer checks = 0, slot;

    target_frame_bridge #(
        .FRAME_WORDS(1), .RESULT_PENDING_ENABLE(0),
        .READ_PENDING_ENABLE(0)
    ) dut (
        .I_csi_clk(csi_clk), .I_ddr_clk(ddr_clk), .I_hdmi_clk(hdmi_clk), .I_rst_n(rst_n),
        .I_frame_start(frame_start), .I_frame_id(frame_id),
        .I_effect_config(effect_config), .I_motion_mode(motion_mode), .I_color_mode(color_mode),
        .I_result_ready(result_ready), .I_result_frame_id(result_id),
        .I_result_found(result_found), .I_result_motion_mode(result_motion),
        .I_result_color_mode(result_color),
        .I_result_xmin(xmin), .I_result_xmax(xmax), .I_result_ymin(ymin), .I_result_ymax(ymax),
        .I_result_center_x(cx), .I_result_center_y(cy),
        .I_multi_valid(multi_valid), .I_multi_hold(multi_hold),
        .I_multi_boxes(boxes), .I_multi_shapes(shapes), .I_multi_overflow(overflow),
        .I_write_start(write_start), .I_write_slot(write_slot), .I_write_word(write_word),
        .I_read_start(read_start), .I_read_slot(read_slot),
        .O_ready(ready), .O_effect_config(out_config), .O_motion_mode(out_motion),
        .O_color_mode(out_color), .O_found(found),
        .O_xmin(out_xmin), .O_xmax(out_xmax), .O_ymin(out_ymin), .O_ymax(out_ymax),
        .O_center_x(out_cx), .O_center_y(out_cy),
        .O_multi_valid(out_valid), .O_multi_hold(out_hold),
        .O_multi_boxes(out_boxes), .O_multi_shapes(out_shapes), .O_multi_overflow(out_overflow)
    );

    function automatic [191:0] boxes_of(input integer seed);
        integer index;
        begin
            for (index=0; index<4; index=index+1)
                boxes_of[48*index +: 48] = {
                    12'(seed+20*index+16),12'(seed+20*index),
                    12'(seed+30*index+24),12'(seed+30*index)};
        end
    endfunction
    function automatic [297:0] expected_tuple(
        input bit is_ready, input [11:0] config_value,
        input bit motion, input [1:0] color_value, input integer seed);
        begin
            if (is_ready)
                expected_tuple = {
                    1'b1,config_value,motion,color_value,1'b1,
                    12'(seed),12'(seed+30),12'(seed+2),12'(seed+22),
                    12'(seed+15),12'(seed+12),
                    4'(seed),4'(~seed),8'(seed),boxes_of(seed),1'(seed)};
            else
                expected_tuple = {1'b0,config_value,motion,color_value,282'b0};
        end
    endfunction

    task automatic source_frame(input integer id, input [11:0] config_value,
                                input bit motion, input [1:0] color_value);
        begin
            @(negedge csi_clk);
            frame_start = 1; frame_id = id; effect_config = config_value;
            motion_mode = motion; color_mode = color_value;
            @(negedge csi_clk);
            frame_start = 0;
        end
    endtask
    task automatic start_write(input integer selected_slot);
        begin
            repeat (5) @(negedge ddr_clk);
            write_start = 1; write_word = 1; write_slot = selected_slot;
            @(negedge ddr_clk);
            write_start = 0; write_word = 0;
        end
    endtask
    task automatic send_result(input integer id, input bit motion,
                               input [1:0] color_value, input integer seed);
        begin
            @(negedge csi_clk);
            result_ready = 1; result_id = id; result_motion = motion;
            result_color = color_value; result_found = 1;
            xmin = seed; xmax = seed+30; ymin = seed+2; ymax = seed+22;
            cx = seed+15; cy = seed+12;
            multi_valid = 4'(seed); multi_hold = 4'(~seed);
            boxes = boxes_of(seed); shapes = 8'(seed); overflow = 1'(seed);
            @(negedge csi_clk);
            result_ready = 0;
        end
    endtask
    task automatic collide_write(input integer selected_slot);
        begin
            wait (dut.S_result_req_sync != dut.S_result_ack);
            @(negedge ddr_clk);
            write_start = 1; write_word = 1; write_slot = selected_slot;
            @(negedge ddr_clk);
            write_start = 0; write_word = 0;
        end
    endtask
    task automatic drain;
        repeat (22) @(negedge csi_clk);
    endtask
    task automatic check_slot(input integer selected_slot, input bit expected_ready,
                              input [11:0] config_value, input bit motion,
                              input [1:0] color_value, input integer seed,
                              input string scenario);
        begin
            @(negedge ddr_clk);
            read_start = 1; read_slot = selected_slot;
            @(negedge ddr_clk);
            read_start = 0;
            repeat (18) @(negedge hdmi_clk);
            if (output_tuple !== expected_tuple(
                    expected_ready,config_value,motion,color_value,seed))
                $fatal(1,"%s slot=%0d tuple=%h expected=%h",scenario,selected_slot,
                    output_tuple,expected_tuple(
                        expected_ready,config_value,motion,color_value,seed));
            checks = checks+1;
        end
    endtask

    initial begin
        repeat (8) @(negedge csi_clk);
        rst_n = 1;
        source_frame(10,12'h02a,0,0); start_write(0);
        source_frame(11,12'h03b,1,2);
        send_result(11,1,2,200); drain();
        fork
            send_result(10,0,0,100);
            collide_write(1);
        join
        drain();
        check_slot(0,1,12'h02a,0,0,100,"current result updates prior slot");
        check_slot(1,1,12'h03b,1,2,200,"cached result fills different new slot");

        source_frame(12,12'h04c,0,1);
        start_write(2); start_write(3);
        send_result(12,0,1,300); drain();
        check_slot(2,1,12'h04c,0,1,300,"first physical slot accepts same frame");
        check_slot(3,1,12'h04c,0,1,300,"second physical slot accepts same frame");
        fork
            send_result(12,0,1,350);
            collide_write(2);
        join
        drain();
        check_slot(2,1,12'h04c,0,1,350,"current result wins over cached result");
        check_slot(3,1,12'h04c,0,1,350,"current result also updates other matching slot");

        held_slot_result = dut.S_slot_result[2];
        source_frame(13,12'h05d,1,3);
        fork
            send_result(12,0,1,380);
            collide_write(2);
        join
        drain();
        if (dut.S_slot_result[2] !== held_slot_result ||
            dut.S_slot_result_valid[2] !== 1'b0)
            $fatal(1,"Unmatched write-start did not preserve data and clear validity");
        checks = checks+1;
        check_slot(2,0,12'h05d,1,3,0,"reused slot rejects old result on write-start");
        check_slot(3,1,12'h04c,0,1,380,"unreused slot still accepts old frame result");
        send_result(13,1,3,400); drain();
        check_slot(2,1,12'h05d,1,3,400,"new result fills reused slot");

        rst_n = 0;
        repeat (3) @(negedge ddr_clk);
        for (slot=0; slot<4; slot=slot+1)
            if (dut.S_slot_result[slot] !== 252'b0 ||
                dut.S_slot_result_valid[slot] !== 1'b0)
                $fatal(1,"Reset did not clear result bank %0d",slot);
        checks = checks+1;
        $display("TARGET_FRAME_BRIDGE_SLOT_WRITES_PASS checks=%0d simultaneous_sources=1 duplicate_slots=1 write_priority=2 reset=1",
                 checks);
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1,"Frame bridge slot-write regression timed out");
    end
endmodule
