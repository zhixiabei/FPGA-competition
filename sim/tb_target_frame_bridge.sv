`timescale 1ns/1ps

module tb_target_frame_bridge;
    reg csi_clk = 0, ddr_clk = 0, hdmi_clk = 0;
    reg ddr_running = 1, hdmi_running = 1;
    always #7 csi_clk = ~csi_clk;
    always #3 if (ddr_running) ddr_clk = ~ddr_clk;
    always #5.5 if (hdmi_running) hdmi_clk = ~hdmi_clk;
    reg rst_n = 0, frame_start = 0, motion_mode = 0;
    reg [1:0] color_mode = 0, result_color = 0;
    reg [9:0] frame_id = 0;
    reg [11:0] effect_config = 0;
    reg result_ready = 0, result_found = 0, result_motion = 0;
    reg [9:0] result_id = 0;
    reg [11:0] xmin = 0, xmax = 0, ymin = 0, ymax = 0, cx = 0, cy = 0;
    reg [3:0] multi_valid = 0, multi_hold = 0;
    reg [191:0] boxes = 0;
    reg [7:0] shapes = 0;
    reg overflow = 0, write_start = 0, write_word = 0, read_start = 0;
    reg production_word = 0;
    reg [1:0] write_slot = 0, read_slot = 0;
    wire ready, found, out_motion, out_overflow, production_ready;
    wire [1:0] out_color;
    wire [11:0] out_config, out_xmin, out_xmax, out_ymin, out_ymax, out_cx, out_cy;
    wire [3:0] out_valid, out_hold;
    wire [191:0] out_boxes;
    wire [7:0] out_shapes;
    integer checks = 0, wraps = 0, busy_checks = 0, freeze_checks = 0;
    integer shift_checks = 0, collision_checks = 0, production_checks = 0;
    integer i;

    target_frame_bridge #(.FRAME_WORDS(4), .DEFAULT_EFFECT_CONFIG(12'h123)) dut (
        .I_csi_clk(csi_clk), .I_ddr_clk(ddr_clk), .I_hdmi_clk(hdmi_clk), .I_rst_n(rst_n),
        .I_frame_start(frame_start), .I_frame_id(frame_id),
        .I_effect_config(effect_config), .I_motion_mode(motion_mode), .I_color_mode(color_mode),
        .I_result_ready(result_ready), .I_result_frame_id(result_id),
        .I_result_found(result_found), .I_result_motion_mode(result_motion),
        .I_result_color_mode(result_color),
        .I_result_xmin(xmin), .I_result_xmax(xmax),
        .I_result_ymin(ymin), .I_result_ymax(ymax),
        .I_result_center_x(cx), .I_result_center_y(cy),
        .I_multi_valid(multi_valid), .I_multi_hold(multi_hold),
        .I_multi_boxes(boxes), .I_multi_overflow(overflow),
        .I_multi_shapes(shapes),
        .I_write_start(write_start), .I_write_slot(write_slot), .I_write_word(write_word),
        .I_read_start(read_start), .I_read_slot(read_slot),
        .O_ready(ready), .O_effect_config(out_config), .O_motion_mode(out_motion),
        .O_color_mode(out_color),
        .O_found(found), .O_xmin(out_xmin), .O_xmax(out_xmax),
        .O_ymin(out_ymin), .O_ymax(out_ymax), .O_center_x(out_cx), .O_center_y(out_cy),
        .O_multi_valid(out_valid), .O_multi_hold(out_hold),
        .O_multi_boxes(out_boxes), .O_multi_overflow(out_overflow),
        .O_multi_shapes(out_shapes)
    );

    // Keep the actual 172800-word production counter in this regression too.
    target_frame_bridge production_dut (
        .I_csi_clk(csi_clk), .I_ddr_clk(ddr_clk), .I_hdmi_clk(hdmi_clk), .I_rst_n(rst_n),
        .I_frame_start(frame_start), .I_frame_id(frame_id),
        .I_effect_config(effect_config), .I_motion_mode(motion_mode), .I_color_mode(color_mode),
        .I_result_ready(result_ready), .I_result_frame_id(result_id),
        .I_result_found(result_found), .I_result_motion_mode(result_motion),
        .I_result_color_mode(result_color),
        .I_result_xmin(xmin), .I_result_xmax(xmax),
        .I_result_ymin(ymin), .I_result_ymax(ymax),
        .I_result_center_x(cx), .I_result_center_y(cy),
        .I_multi_valid(multi_valid), .I_multi_hold(multi_hold),
        .I_multi_boxes(boxes), .I_multi_overflow(overflow),
        .I_multi_shapes(shapes),
        .I_write_start(write_start), .I_write_slot(write_slot), .I_write_word(production_word),
        .I_read_start(read_start), .I_read_slot(read_slot),
        .O_ready(production_ready)
    );

    function automatic integer offset_of(input [11:0] config_value);
        case (config_value[11:8])
            2, 6, 7: offset_of = 3;
            4, 8, 10, 11: offset_of = 1;
            12: offset_of = 3;
            default: offset_of = 0;
        endcase
    endfunction
    function automatic [7:0] source_shapes(input integer seed);
        integer slot;
        begin
            for (slot=0; slot<4; slot=slot+1)
                source_shapes[2*slot +: 2] = 2'((seed/10+slot)%4);
        end
    endfunction
    function automatic [11:0] clipped(input integer value, input integer shift,
                                      input integer maximum);
        integer adjusted;
        begin
            adjusted = value+shift;
            clipped = adjusted > maximum ? maximum : adjusted;
        end
    endfunction
    function automatic [191:0] source_boxes(input integer seed);
        reg [191:0] value;
        integer b;
        begin
            value = 0;
            for (b=0; b<4; b=b+1)
                value[48*b +: 48] = {12'(seed+20*b+16),12'(seed+20*b),
                                    12'(seed+40*b+30),12'(seed+40*b)};
            source_boxes = value;
        end
    endfunction
    function automatic [191:0] expected_boxes(input integer seed, input [11:0] config_value);
        reg [191:0] value;
        integer b, shift;
        begin
            value = 0; shift = offset_of(config_value);
            for (b=0; b<4; b=b+1)
                value[48*b +: 48] = {
                    clipped(seed+20*b+16,shift,719),clipped(seed+20*b,shift,719),
                    clipped(seed+40*b+30,shift,1279),clipped(seed+40*b,shift,1279)};
            expected_boxes = value;
        end
    endfunction

    task automatic source_frame(input integer id, input [11:0] config_value, input bit motion);
        begin
            @(negedge csi_clk);
            frame_start = 1; frame_id = id; effect_config = config_value; motion_mode = motion;
            @(negedge csi_clk);
            frame_start = 0;
        end
    endtask
    task automatic start_write(input integer slot);
        begin
            repeat (5) @(negedge ddr_clk);
            write_start = 1; write_slot = slot;
            @(negedge ddr_clk);
            write_start = 0;
        end
    endtask
    task automatic words(input integer count);
        begin
            @(negedge ddr_clk);
            write_word = 1;
            repeat (count) @(negedge ddr_clk);
            write_word = 0;
        end
    endtask
    task automatic send_result(input integer id, input bit motion, input integer seed,
                               input bit has_target, input [3:0] valids,
                               input [3:0] holds, input bit over);
        begin
            @(negedge csi_clk);
            result_ready = 1; result_id = id; result_motion = motion;
            result_found = has_target;
            xmin = seed; xmax = seed+30; ymin = seed; ymax = seed+16;
            cx = seed+15; cy = seed+8;
            multi_valid = valids; multi_hold = holds;
            boxes = source_boxes(seed); overflow = over;
            shapes = motion ? 8'd0 : source_shapes(seed);
            @(negedge csi_clk);
            result_ready = 0;
        end
    endtask
    task automatic drain;
        begin
            repeat (22) @(negedge csi_clk);
        end
    endtask
    task automatic select_read(input integer slot);
        begin
            @(negedge ddr_clk);
            read_slot = slot; read_start = 1;
            @(negedge ddr_clk);
            read_start = 0;
            repeat (18) @(negedge hdmi_clk);
        end
    endtask
    task automatic check_output(input bit expected_ready, input [11:0] config_value,
                                input bit motion, input integer seed,
                                input bit has_target, input [3:0] valids,
                                input [3:0] holds, input bit over, input string scenario);
        integer shift;
        begin
            shift = offset_of(config_value);
            if (ready !== expected_ready || out_config !== config_value || out_motion !== motion)
                $fatal(1, "%s metadata ready=%b/%b config=%h/%h mode=%b/%b",
                       scenario,ready,expected_ready,out_config,config_value,out_motion,motion);
            if (expected_ready) begin
                if (found !== has_target || out_valid !== valids ||
                    out_hold !== holds || out_overflow !== over ||
                    out_shapes !== (motion ? 8'd0 : source_shapes(seed)) ||
                    out_xmin !== clipped(seed,shift,1279) ||
                    out_xmax !== clipped(seed+30,shift,1279) ||
                    out_ymin !== clipped(seed,shift,719) ||
                    out_ymax !== clipped(seed+16,shift,719) ||
                    out_cx !== clipped(seed+15,shift,1279) ||
                    out_cy !== clipped(seed+8,shift,719) ||
                    out_boxes !== expected_boxes(seed,config_value))
                    $fatal(1, "%s mismatched single/multi result seed=%0d",scenario,seed);
            end else if (found !== 0 || out_valid !== 0 || out_hold !== 0 ||
                         out_overflow !== 0 || out_boxes !== 0 || out_shapes !== 0) begin
                $fatal(1, "%s invalid frame retained target flags",scenario);
            end
            checks = checks+1;
        end
    endtask

    initial begin
        repeat (8) @(negedge csi_clk);
        if (ready !== 0 || out_config !== 12'h123)
            $fatal(1,"Reset output/default configuration mismatch");
        rst_n = 1;
        source_frame(10,12'h2a5,0);
        start_write(1);  // Slot 1 is deliberately unrelated to ID modulo four.
        words(3);
        send_result(10,0,40,1,4'b1111,4'b0100,1);
        drain();
        select_read(1);
        check_output(0,12'h2a5,0,0,0,0,0,0,"result retained before complete frame");
        words(1);
        select_read(1);
        check_output(1,12'h2a5,0,40,1,4'b1111,4'b0100,1,"four boxes complete with Scharr shift");
        shift_checks = shift_checks+1;
        words(17);
        select_read(1);
        check_output(1,12'h2a5,0,40,1,4'b1111,4'b0100,1,"extra words do not relabel slot");

        source_frame(11,12'h8e1,1);
        start_write(3);
        words(4);
        source_frame(12,12'h6d2,0);
        start_write(0);
        words(4);
        repeat (2000) @(negedge csi_clk);
        send_result(11,1,80,1,4'b0001,0,0);
        drain();
        select_read(3);
        check_output(1,12'h8e1,1,80,1,1,0,0,"late prior frame keeps source config/mode/actual slot");
        shift_checks = shift_checks+1;
        select_read(0);
        check_output(0,12'h6d2,0,0,0,0,0,0,"next frame is not given earlier result");
        send_result(12,1,190,1,15,0,0); // Wrong detector mode must be rejected.
        drain();
        select_read(0);
        check_output(0,12'h6d2,0,0,0,0,0,0,"wrong source detector mode rejected");
        send_result(12,0,110,0,0,0,0);
        drain();
        repeat (12) @(negedge hdmi_clk);
        check_output(0,12'h6d2,0,0,0,0,0,0,"late metadata cannot change frozen display");
        freeze_checks = freeze_checks+1;
        select_read(0);
        check_output(1,12'h6d2,0,110,0,0,0,0,"valid no-target result remains distinct from missing result");

        source_frame(20,12'h700,0); start_write(2); words(4);
        repeat (1) @(negedge csi_clk);
        send_result(20,0,1278,1,15,10,0); drain(); select_read(2);
        check_output(1,12'h700,0,1278,1,15,10,0,"Scharr inverse clips all four boxes and centers");
        shift_checks = shift_checks+1;
        source_frame(21,12'h400,0); start_write(2); words(4);
        repeat (32) @(negedge csi_clk);
        send_result(21,0,1279,1,3,2,0); drain(); select_read(2);
        check_output(1,12'h400,0,1279,1,3,2,0,"emboss delay and clipping");
        shift_checks = shift_checks+1;
        source_frame(22,12'h000,0); start_write(2);
        send_result(21,0,240,1,15,0,0); drain(); select_read(2);
        check_output(0,12'h000,0,0,0,0,0,0,"rollback reused slot rejects old generation");
        send_result(22,0,260,1,5,4,0); drain(); words(4); select_read(2);
        check_output(1,12'h000,0,260,1,5,4,0,"reused slot accepts only new generation");

        // Store contexts without DDR work, then stall the result receiver.
        source_frame(100,12'h100,0); start_write(0); words(4);
        source_frame(101,12'h400,0); start_write(1); words(4);
        source_frame(102,12'h800,0); start_write(3); words(4);
        @(negedge ddr_clk); ddr_running = 0;
        send_result(100,0,100,1,1,0,0);
        send_result(101,0,200,1,3,2,0);
        send_result(102,0,300,1,7,4,1);
        repeat (4) @(negedge csi_clk);
        ddr_running = 1;
        drain();
        select_read(0); check_output(1,12'h100,0,100,1,1,0,0,"busy mailbox first record held");
        select_read(1); check_output(1,12'h400,0,200,1,3,2,0,"busy mailbox pending record preserved");
        select_read(3); check_output(0,12'h800,0,0,0,0,0,0,"full mailbox drops complete third record");
        busy_checks = busy_checks+1;

        // An in-flight old result survives a whole 10-bit ID wrap, while its
        // actual write slot is reused for the same ID with a different nonce.
        source_frame(7,12'h000,0); start_write(2); words(4);
        @(negedge ddr_clk); ddr_running = 0;
        send_result(7,0,70,1,1,0,0);
        for (i=8; i<=1031; i=i+1)
            source_frame(i%1024,12'h800,0);
        ddr_running = 1;
        start_write(2); words(4); drain(); select_read(2);
        check_output(0,12'h800,0,0,0,0,0,0,"same frame ID after wrap rejects old nonce");
        send_result(7,0,370,1,9,8,0); drain(); select_read(2);
        check_output(1,12'h800,0,370,1,9,8,0,"wrapped ID accepts current generation");
        wraps = wraps+1;

        // Arrange the receiver's result-accept edge to equal write-start.
        drain();
        source_frame(500,12'h200,0);
        fork
            send_result(500,0,500,1,15,8,0);
            begin
                wait (dut.S_result_req_sync != dut.S_result_ack);
                @(negedge ddr_clk);
                write_slot = 1; write_start = 1;
                @(negedge ddr_clk);
                write_start = 0;
            end
        join
        words(4); drain(); select_read(1);
        check_output(1,12'h200,0,500,1,15,8,0,"matching result and write-start same edge accepted");
        collision_checks = collision_checks+1;
        source_frame(501,12'h600,0);
        fork
            send_result(500,0,550,1,15,0,1);
            begin
                wait (dut.S_result_req_sync != dut.S_result_ack);
                @(negedge ddr_clk);
                write_slot = 1; write_start = 1;
                @(negedge ddr_clk);
                write_start = 0;
            end
        join
        words(4); drain(); select_read(1);
        check_output(0,12'h600,0,0,0,0,0,0,"old result at write-start cannot repopulate reused slot");
        collision_checks = collision_checks+1;
        send_result(501,0,600,1,12,4,0); drain();
        select_read(1);
        check_output(1,12'h600,0,600,1,12,4,0,"new frame result fills reused slot");
        shift_checks = shift_checks+1;

        // A read snapshot remains a complete tuple while HDMI is stalled.
        @(negedge hdmi_clk); hdmi_running = 0;
        @(negedge ddr_clk); read_slot = 0; read_start = 1;
        @(negedge ddr_clk); read_start = 0;
        repeat (4) @(negedge ddr_clk);
        @(negedge ddr_clk); read_slot = 2; read_start = 1;
        @(negedge ddr_clk); read_start = 0;
        repeat (4) @(negedge ddr_clk);
        @(negedge ddr_clk); read_slot = 1; read_start = 1;
        @(negedge ddr_clk); read_start = 0;
        hdmi_running = 1;
        repeat (35) @(negedge hdmi_clk);
        check_output(1,12'h600,0,600,1,12,4,0,"busy read mailbox eventually publishes newest frozen tuple");
        busy_checks = busy_checks+1;
        source_frame(502,12'h300,0); start_write(1); words(4);
        send_result(502,0,680,1,2,0,0); drain();
        check_output(1,12'h600,0,600,1,12,4,0,"slot reuse cannot mutate an already selected display frame");
        freeze_checks = freeze_checks+1;
        select_read(1);
        check_output(1,12'h300,0,680,1,2,0,0,"next read selects new tuple");

        // An overwritten source context must not borrow the replacement nonce.
        source_frame(600,12'h000,0); start_write(0); words(4);
        source_frame(604,12'h400,0);
        send_result(600,0,700,1,1,0,0); drain(); select_read(0);
        check_output(0,12'h000,0,0,0,0,0,0,"overwritten source context drops stale result");

        // Color selection is part of the same frame identity as detector mode.
        color_mode=2'd1; result_color=2'd2;
        source_frame(605,12'h000,0); start_write(2); words(4);
        send_result(605,0,720,1,1,0,0); drain(); select_read(2);
        check_output(0,12'h000,0,0,0,0,0,0,"wrong source color mode rejected");
        result_color=2'd1;
        send_result(605,0,720,1,1,0,0); drain(); select_read(2);
        check_output(1,12'h000,0,720,1,1,0,0,"selected color mode follows buffered frame");
        if (out_color!==2'd1)
            $fatal(1,"Buffered color mode expected green, got %0d",out_color);
        color_mode=2'd0; result_color=2'd0;

        // The four color-mask previews retain the same frame identity and
        // shape tuple, with independent raw/one-window/three-window offsets.
        for(i=9;i<=12;i=i+1) begin
            source_frame(606+i-9,{4'(i),8'h5a},0); start_write(2); words(4);
            send_result(606+i-9,0,1278,1,15,4,0); drain(); select_read(2);
            check_output(1,{4'(i),8'h5a},0,1278,1,15,4,0,
                "color-mask preview preserves shape tuple and spatial clipping");
            shift_checks=shift_checks+1;
        end

        source_frame(610,12'h800,0); start_write(3);
        send_result(610,0,200,1,3,0,0); drain();
        @(negedge ddr_clk); production_word = 1;
        repeat (172799) @(negedge ddr_clk);
        production_word = 0;
        select_read(3);
        if (production_ready !== 0)
            $fatal(1,"Production count marked 172799 words complete");
        production_checks = production_checks+1;
        @(negedge ddr_clk); production_word = 1;
        @(negedge ddr_clk); production_word = 0;
        select_read(3);
        if (production_ready !== 1)
            $fatal(1,"Production count did not mark word 172800 complete");
        production_checks = production_checks+1;
        @(negedge ddr_clk); production_word = 1;
        repeat (15) @(negedge ddr_clk);
        production_word = 0;
        select_read(3);
        if (production_ready !== 1)
            $fatal(1,"Production count overflow invalidated completed frame");
        production_checks = production_checks+1;
        rst_n = 0;
        repeat (6) @(negedge csi_clk);
        rst_n = 1;
        @(negedge ddr_clk); production_word = 1;
        repeat (172800) @(negedge ddr_clk);
        production_word = 0;
        select_read(3);
        if (production_ready !== 0 || ready !== 0)
            $fatal(1,"Trailing words after reset manufactured a complete frame");
        production_checks = production_checks+1;
        if (wraps != 1 || busy_checks != 2 || freeze_checks != 2 ||
            collision_checks != 2 || production_checks != 4 || shift_checks != 9)
            $fatal(1,"Frame bridge coverage incomplete");
        $display("TARGET_FRAME_BRIDGE_PASS checks=%0d wrap=%0d busy=%0d freeze=%0d collision=%0d production=%0d shifts=%0d late=2000",
                 checks,wraps,busy_checks,freeze_checks,collision_checks,production_checks,shift_checks);
        $finish;
    end
    initial begin
        #5000000;
        $fatal(1,"Frame bridge regression timed out");
    end
endmodule
