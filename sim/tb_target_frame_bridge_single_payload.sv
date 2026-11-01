`timescale 1ns/1ps

module tb_target_frame_bridge_single_payload;
    reg csi_clk=0, ddr_clk=0, hdmi_clk=0;
    always #7 csi_clk=~csi_clk;
    always #3 ddr_clk=~ddr_clk;
    always #5.5 hdmi_clk=~hdmi_clk;

    reg rst_n=0, frame_start=0, motion_mode=0;
    reg [9:0] frame_id=0, result_frame_id=0;
    reg [11:0] effect_config=0;
    reg [1:0] color_mode=0, result_color_mode=0;
    reg result_ready=0, result_found=0, result_motion_mode=0;
    reg [11:0] xmin=0, xmax=0, ymin=0, ymax=0, center_x=0, center_y=0;
    reg [3:0] multi_valid=0, multi_hold=0;
    reg [191:0] multi_boxes=0;
    reg [7:0] multi_shapes=0;
    reg multi_overflow=0, write_start=0, write_word=0, read_start=0;
    reg [1:0] write_slot=0, read_slot=0;

    wire [297:0] full_tuple, single_tuple;
    wire full_mirror,single_mirror;
    wire write_complete;
    video_ddr_write_progress #(.FRAME_WORDS(4)) write_progress (
        .I_clk(ddr_clk), .I_rst_n(rst_n), .I_write_start(write_start),
        .I_write_word(write_word), .O_bridge_complete(write_complete),
        .O_latency_complete()
    );

`define BRIDGE_INPUTS \
        .I_csi_clk(csi_clk), .I_ddr_clk(ddr_clk), .I_hdmi_clk(hdmi_clk), \
        .I_rst_n(rst_n), .I_frame_start(frame_start), .I_frame_id(frame_id), \
        .I_effect_config(effect_config), .I_motion_mode(motion_mode), \
        .I_color_mode(color_mode), .I_result_ready(result_ready), \
        .I_result_frame_id(result_frame_id), .I_result_found(result_found), \
        .I_result_motion_mode(result_motion_mode), \
        .I_result_color_mode(result_color_mode), .I_result_xmin(xmin), \
        .I_result_xmax(xmax), .I_result_ymin(ymin), .I_result_ymax(ymax), \
        .I_result_center_x(center_x), .I_result_center_y(center_y), \
        .I_multi_valid(multi_valid), .I_multi_hold(multi_hold), \
        .I_multi_boxes(multi_boxes), .I_multi_shapes(multi_shapes), \
        .I_multi_overflow(multi_overflow), .I_write_start(write_start), \
        .I_write_slot(write_slot), .I_write_word(write_word), \
        .I_read_start(read_start), .I_read_slot(read_slot), .I_write_complete(write_complete)

`define BRIDGE_OUTPUTS(T) \
        .O_ready(T[297]), .O_effect_config(T[296:285]), \
        .O_motion_mode(T[284]), .O_color_mode(T[283:282]), .O_found(T[281]), \
        .O_xmin(T[280:269]), .O_xmax(T[268:257]), \
        .O_ymin(T[256:245]), .O_ymax(T[244:233]), \
        .O_center_x(T[232:221]), .O_center_y(T[220:209]), \
        .O_multi_valid(T[208:205]), .O_multi_hold(T[204:201]), \
        .O_multi_shapes(T[200:193]), .O_multi_boxes(T[192:1]), \
        .O_multi_overflow(T[0])

    target_frame_bridge #(.FRAME_WORDS(4)) full (
        `BRIDGE_INPUTS, `BRIDGE_OUTPUTS(full_tuple),.O_read_mirror(full_mirror)
    );
    target_frame_bridge #(
        .FRAME_WORDS(4), .COMPACT_MODE_PAYLOAD(1), .SINGLE_TARGET_ONLY(1),
        .USE_EXTERNAL_WRITE_PROGRESS(1),
        .RESULT_PENDING_ENABLE(0), .READ_PENDING_ENABLE(0)
    ) single (
        `BRIDGE_INPUTS, `BRIDGE_OUTPUTS(single_tuple),.O_read_mirror(single_mirror)
    );

`ifdef BRIDGE_ROUTING_REFERENCE
    wire [297:0] reference_tuple;
    wire reference_mirror;
    integer cycle_checks=0, stress_frame;
    target_frame_bridge_reference #(
        .FRAME_WORDS(4), .COMPACT_MODE_PAYLOAD(1), .SINGLE_TARGET_ONLY(1),
        .USE_EXTERNAL_WRITE_PROGRESS(1),
        .RESULT_PENDING_ENABLE(0), .READ_PENDING_ENABLE(0)
    ) reference (
        `BRIDGE_INPUTS, `BRIDGE_OUTPUTS(reference_tuple),.O_read_mirror(reference_mirror)
    );
    always @(posedge ddr_clk) begin
        #1;
        if (rst_n) begin
            if (single_mirror !== reference_mirror ||
                single.S_read_payload !== reference.S_read_payload ||
                single.S_result_ack !== reference.S_result_ack ||
                single.S_slot_result_valid !== reference.S_slot_result_valid)
                $fatal(1,"Bridge routing changed DDR data/control at %t",$time);
            cycle_checks=cycle_checks+1;
        end
    end
    always @(posedge hdmi_clk) begin
        #1;
        if (rst_n && single_tuple !== reference_tuple)
            $fatal(1,"Bridge routing changed HDMI data/latency at %t",$time);
    end
`endif

`undef BRIDGE_INPUTS
`undef BRIDGE_OUTPUTS

    task automatic start_frame(input [9:0] id, input [11:0] config_value,
                               input bit motion, input [1:0] color);
        begin
            @(negedge csi_clk);
            frame_start=1;
            frame_id=id;
            effect_config=config_value;
            motion_mode=motion;
            color_mode=color;
            @(negedge csi_clk);
            frame_start=0;
        end
    endtask

    task automatic start_write_slot(input [1:0] slot);
        begin
            repeat (3) @(negedge ddr_clk);
            write_start=1;
            write_slot=slot;
            @(negedge ddr_clk);
            write_start=0;
        end
    endtask

    task automatic complete_frame_write;
        begin
            @(negedge ddr_clk);
            write_word=1;
            repeat (4) @(negedge ddr_clk);
            write_word=0;
        end
    endtask

    task automatic publish_color_result(input [9:0] id,input [1:0] color=2);
        begin
            @(negedge csi_clk);
            result_ready=1;
            result_frame_id=id;
            result_found=1;
            result_motion_mode=0;
            result_color_mode=color;
            xmin=12'd1277; xmax=12'd4090;
            ymin=12'd718; ymax=12'd4090;
            center_x=12'd1278; center_y=12'd718;
            multi_valid=4'b1011;
            multi_hold=4'b1101;
            multi_shapes=8'b10_01_11_10;
            multi_overflow=1;
            multi_boxes[0 +: 48]={12'd4090,12'd718,12'd4090,12'd1277};
            multi_boxes[48 +: 48]={12'd100,12'd20,12'd200,12'd10};
            multi_boxes[96 +: 48]={12'd300,12'd220,12'd240,12'd30};
            multi_boxes[144 +: 48]={12'd500,12'd400,12'd350,12'd50};
            @(negedge csi_clk);
            result_ready=0;
        end
    endtask

    task automatic publish_motion_result(input [9:0] id);
        begin
            @(negedge csi_clk);
            result_ready=1;
            result_frame_id=id;
            result_found=1;
            result_motion_mode=1;
            result_color_mode=0;
            xmin=12'd10; xmax=12'd200;
            ymin=12'd20; ymax=12'd100;
            center_x=12'd105; center_y=12'd60;
            multi_valid=4'b1111;
            multi_hold=4'b1111;
            multi_shapes=8'hff;
            multi_overflow=1;
            multi_boxes={4{48'hffffffffffff}};
            @(negedge csi_clk);
            result_ready=0;
        end
    endtask

    task automatic select_frame_slot(input [1:0] slot);
        begin
            @(negedge ddr_clk);
            read_slot=slot;
            read_start=1;
            @(negedge ddr_clk);
            read_start=0;
            repeat (24) @(negedge hdmi_clk);
        end
    endtask

    task automatic check_single_payload(input [8:0] check_id, input bit motion);
        begin
            if (single_tuple[297:209] !== full_tuple[297:209])
                $fatal(1,"single geometry/metadata mismatch check=%0d full=%h single=%h",
                    check_id,full_tuple[297:209],single_tuple[297:209]);
            if (single_tuple[0] !== 1'b0)
                $fatal(1,"single-target overflow was not cleared check=%0d",check_id);
            if (motion) begin
                if (single_tuple[208:193] !== 16'b0 ||
                    single_tuple[192:1] !== 192'b0)
                    $fatal(1,"motion-mode multi-target fields were not cleared");
            end else if (single_tuple[208:206] !== 3'b000 ||
                         single_tuple[204:202] !== 3'b000 ||
                         single_tuple[200:195] !== 6'b0)
                $fatal(1,"unused single-target fields were not zero check=%0d",check_id);
            else begin
                if (single_tuple[205] !== full_tuple[205] ||
                    single_tuple[201] !== full_tuple[201] ||
                    single_tuple[194:193] !== full_tuple[194:193] ||
                    single_tuple[48:1] !== full_tuple[48:1])
                    $fatal(1,"slot-zero metadata/box mismatch check=%0d",check_id);
                if (single_tuple[192:49] !== 144'b0)
                    $fatal(1,"unused single-target boxes were not zero check=%0d",check_id);
            end
        end
    endtask

    reg [297:0] frozen_color_tuple;
    initial begin
        repeat (8) @(negedge csi_clk);
        if ($bits(single.S_result_payload)!=93 ||
            $bits(single.S_read_payload)!=84 ||
            $bits(single.S_slot_result_ram)!=71)
            $fatal(1,"single-target payload widths are not 93/84/71 bits");
        rst_n=1;

        start_frame(10,12'hc5a,0,2);
        start_write_slot(1);
        complete_frame_write();
        publish_color_result(10);
        repeat (24) @(negedge csi_clk);
        select_frame_slot(1);
        check_single_payload(0,0);
        if (single_tuple[297:282] !== {1'b1,12'hc5a,1'b0,2'd2} ||
            single_tuple[281] !== 1'b1 ||
            single_tuple[280:269] !== 12'd1279 ||
            single_tuple[268:257] !== 12'd1279 ||
            single_tuple[256:245] !== 12'd719 ||
            single_tuple[244:233] !== 12'd719 ||
            single_tuple[194:193] !== 2'd2)
            $fatal(1,"color, shape, or mode-12 clipped coordinates were not preserved");
        frozen_color_tuple=single_tuple;

        start_frame(11,12'h4e1,1,0);
        start_write_slot(2);
        complete_frame_write();
        publish_motion_result(11);
        repeat (24) @(negedge csi_clk);
        select_frame_slot(2);
        check_single_payload(1,1);
        if (single_tuple[297:282] !== {1'b1,12'h4e1,1'b1,2'd0} ||
            single_tuple[280:269] !== 12'd11 ||
            single_tuple[268:257] !== 12'd201 ||
            single_tuple[256:245] !== 12'd21 ||
            single_tuple[244:233] !== 12'd101 ||
            single_tuple[201:193] !== 9'b0)
            $fatal(1,"motion result, mode-4 offset, or cleared multi fields failed");

        select_frame_slot(1);
        check_single_payload(2,0);
        if (single_tuple !== frozen_color_tuple)
            $fatal(1,"re-reading a completed DDR slot did not restore its frozen target");

        start_frame(12,12'hd01,0,0); start_write_slot(3); complete_frame_write();
        repeat (24) @(negedge csi_clk); select_frame_slot(3);
        if(single_tuple[297:282]!=={1'b0,12'hd01,1'b0,2'd0} ||
           single_mirror!==1 || full_mirror!==1)
            $fatal(1,"Missing target disabled signature mirror/pause in compact payload");
        publish_color_result(12,0);
        repeat (24) @(negedge csi_clk); select_frame_slot(3);
        check_single_payload(3,0);
        if(single_tuple[232:209]!=={12'd1278,12'd718})
            $fatal(1,"Signature center acquired a spatial offset");
        start_frame(13,12'h900,0,0); start_write_slot(0); complete_frame_write();
        select_frame_slot(3);
        if(single_mirror!==1 || single_tuple[296:285]!==12'hd01)
            $fatal(1,"New request changed an older signature frame");
        select_frame_slot(0);
        if(single_mirror!==0 || full_mirror!==0 || single_tuple[296:285]!==12'h900)
            $fatal(1,"Binary display must restore forward read order");

`ifdef BRIDGE_ROUTING_REFERENCE
        // Reused/duplicate slots, ID wrap, all effects and reads while a
        // result is crossing exercise the physical storage substitution.
        for (stress_frame=0; stress_frame<64; stress_frame=stress_frame+1) begin
            start_frame(10'(1000+stress_frame),12'(stress_frame<<8),0,2);
            if (stress_frame%3==0) begin
                publish_color_result(10'(1000+stress_frame));
                repeat (24) @(negedge csi_clk);
            end
            start_write_slot(2'(stress_frame));
            if (stress_frame%4==0)
                start_write_slot(2'(stress_frame+1));
            select_frame_slot(2'(stress_frame));
            complete_frame_write();
            fork
                publish_color_result(10'(1000+stress_frame));
                begin
                    repeat (3) @(negedge ddr_clk);
                    select_frame_slot(2'(stress_frame));
                end
            join
            select_frame_slot(2'(stress_frame+1));
            if (stress_frame==31) begin
                @(negedge csi_clk); rst_n=0;
                repeat (8) @(negedge csi_clk);
                rst_n=1;
            end
        end
        $display("TARGET_FRAME_BRIDGE_ROUTING_EQUIVALENCE_PASS cycles=%0d frames=64 reset=1 external_progress=1 latency_delta=0",cycle_checks);
`endif
        $display("TARGET_FRAME_BRIDGE_SINGLE_PAYLOAD_PASS body_bits=%0d result_bits=%0d read_bits=%0d slots=4 geometry=color+motion freeze=1 signature=1 queues=0",
            $bits(single.S_slot_result_ram),$bits(single.S_result_payload),
            $bits(single.S_read_payload));
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1,"Single-target bridge payload test timed out");
    end
endmodule
