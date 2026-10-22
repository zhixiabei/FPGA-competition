`timescale 1ns/1ps
// Production post-demosaic path. Only the demosaic output boundary is driven;
// AWB, target selection, four-target detection, display delay and packing run.
module tb_isp_red_multi;
    localparam integer W=1280, H=720, GROUPS=W/4;
    localparam integer FRAME_GROUPS=W*H/4, FRAME_WORDS=W*H*3/16;
    reg clk=0, rst_n=0;
    always #5 clk=~clk;
    reg source_valid=0, source_user=0, source_last=0;
    reg [9:0] injected_id=0;
    reg [127:0] injected_rgb=0;
    wire [127:0] output_data;
    wire output_valid, output_user;
    wire target_ready, target_found, target_toggle, target_motion, active_motion;
    wire [9:0] target_id, latency_id;
    wire [3:0] target_valid, target_hold;
    wire [191:0] target_boxes;
    wire [7:0] target_shapes;
    wire [1:0] target_color, active_color;
    wire target_overflow;
    wire [11:0] effect_config;
    isp_top #(.ENABLE_EDGE(0), .RED_MULTI_ENABLE(1)) dut (
        .I_awb_hold_async(1'b0),
        .axi4s_video_aclk(clk), .I_rst_n(rst_n),
        .I_effect_config(12'd0), .I_motion_mode_async(1'b0), .I_color_mode_async(2'd0),
        .I_tlast(source_last), .I_tuser(source_user),
        .I_tdata(source_valid ? {4{10'd512}} : 40'd0),
        .I_tvalid(source_valid), .I_tdest(injected_id), .O_tready(1'b1),
        .O_tdata(output_data), .O_tlast(), .O_tuser(output_user),
        .O_tvalid(output_valid), .I_tready(),
        .O_target_result_ready(target_ready), .O_target_found(target_found),
        .O_target_xmin(), .O_target_xmax(), .O_target_ymin(), .O_target_ymax(),
        .O_target_center_x(), .O_target_center_y(), .O_target_pixels(),
        .O_target_frame_toggle(target_toggle),
        .O_target_motion_mode(target_motion), .O_motion_mode_active(active_motion),
        .O_target_color_mode(target_color), .O_color_mode_active(active_color),
        .O_target_result_frame_id(target_id), .O_target_multi_valid(target_valid),
        .O_target_multi_hold(target_hold), .O_target_multi_boxes(target_boxes),
        .O_target_multi_shapes(target_shapes),
        .O_target_multi_overflow(target_overflow),
        .O_edge_mode_active(), .O_effect_config(effect_config),
        .O_ae_stats_valid(), .O_ae_sum_y(), .O_ae_sample_count(),
        .O_ae_bright_count(), .O_latency_frame_id(latency_id)
    );

    integer awb_frame=-1, edge_frame=-1, packed_frame=-1;
    integer awb_count[0:2], edge_count[0:2], packed_count[0:2];
    integer target_results=0, boxes_checked=0, stable_slots=0;
    integer shapes_checked=0;
    integer packed_labels=0, pixel_labels=0, slot_for_object[0:3];
    reg previous_toggle=0;
    reg sampled_edge_user, sampled_edge_valid;
    reg [11:0] sampled_effect;
    integer frame_index, object_index, slot_index, located_slot, matching_slots;
    reg [47:0] checked_box;

    function automatic [9:0] expected_id(input integer frame_number);
        case(frame_number)
            0: expected_id=10'd1023;
            1: expected_id=10'd0;
            2: expected_id=10'd1;
            default: expected_id=10'd777;
        endcase
    endfunction
    function automatic integer object_x0(
        input integer frame_number, input integer object_number
    );
        integer base_x, shift_x;
        begin
            case(object_number)
                0,2: base_x=80;
                1: base_x=400;
                default: base_x=1040;
            endcase
            case(object_number)
                0: shift_x=4;
                1: shift_x=-4;
                2: shift_x=2;
                default: shift_x=-2;
            endcase
            object_x0=base_x+(frame_number==2 ? shift_x : 0);
        end
    endfunction
    function automatic integer object_y0(
        input integer frame_number, input integer object_number
    );
        object_y0=(object_number<2 ? 80 : 500)+
            (frame_number==2 ? (object_number<2 ? 2 : -2) : 0);
    endfunction
    function automatic [23:0] scene(
        input integer frame_number, input integer x, input integer y
    );
        integer object_number, x0, y0;
        begin
            // Neutral background keeps the real AWB at unity. Saturated
            // red objects are excluded from its neutral sample population.
            scene=24'h808080;
            for(object_number=0;object_number<4;object_number=object_number+1) begin
                x0=object_x0(frame_number,object_number);
                y0=object_y0(frame_number,object_number);
                if(x>=x0 && x<x0+64 && y>=y0 && y<y0+64)
                    scene=24'hd00806;
            end
        end
    endfunction
    function automatic [127:0] scene_group(
        input integer frame_number, input integer group_number, input integer row
    );
        integer lane;
        begin
            // This is the demosaic's real little-lane 32-bit RGB packing.
            // The production data128_96 module performs its own conversion.
            for(lane=0;lane<4;lane=lane+1)
                scene_group[lane*32+:32]=
                    {8'd0,scene(frame_number,group_number*4+lane,row)};
        end
    endfunction

    always @(posedge clk) begin
        sampled_edge_user=dut.edge_O_tuser;
        sampled_edge_valid=dut.edge_O_tvalid;
        sampled_effect=effect_config;
        if(rst_n) begin
            if(source_user) begin
                if(awb_frame>=0 && awb_count[awb_frame]!=FRAME_GROUPS)
                    $fatal(1,"AWB preceding frame lost groups");
                awb_frame=awb_frame+1;
                if(awb_frame>2 || injected_id!==expected_id(awb_frame))
                    $fatal(1,"Source SOF ID changed unexpectedly");
            end
            if(sampled_edge_user) begin
                if(edge_frame>=0 && edge_count[edge_frame]!=FRAME_GROUPS)
                    $fatal(1,"Display preceding frame lost groups");
                edge_frame=edge_frame+1;
                if(edge_frame>2) $fatal(1,"Unexpected display SOF");
            end
            if(sampled_edge_valid) begin
                if(edge_frame<0 || edge_frame>2 || sampled_effect!==12'd0)
                    $fatal(1,"Display RGB/config frame mismatch");
                edge_count[edge_frame]=edge_count[edge_frame]+1;
            end
        end
        #1;
        if(rst_n) begin
            if(dut.awb_O_tuser!==source_user || active_motion!==1'b0 ||
               active_color!==2'd0)
                $fatal(1,"AWB marker or fixed red mode changed");
            if(dut.awb_O_tvalid) begin
                if(awb_frame<0 || awb_frame>2)
                    $fatal(1,"AWB valid pixel lacks a frame");
                awb_count[awb_frame]=awb_count[awb_frame]+1;
            end
            if(target_ready) begin
                if(target_results>=3 ||
                    target_id!==expected_id(target_results) ||
                    target_motion!==1'b0 || target_color!==2'd0 ||
                    target_toggle===previous_toggle ||
                    target_overflow!==1'b0 ||
                    (^{target_valid,target_hold,target_found,target_boxes,target_shapes})===1'bx)
                    $fatal(1,"Production multi result token mismatch result=%0d id=%0d expected=%0d",
                        target_results,target_id,expected_id(target_results));
                if(target_results==0) begin
                    if(target_valid!==4'b0 || target_hold!==4'b0 ||
                       target_found!==1'b0 || target_shapes!==8'd0)
                        $fatal(1,"First frame bypassed two-frame confirmation");
                end else begin
                    if(target_valid!==4'b1111 || target_hold!==4'b0 || target_found!==1'b1)
                        $fatal(1,"Confirmed frame lacks four active boxes result=%0d valid=%b hold=%b",
                            target_results,target_valid,target_hold);
                    // Expected geometry comes solely from the input scene.
                    // It does not inspect any detector state or intermediate ROI.
                    for(object_index=0;object_index<4;object_index=object_index+1) begin
                        located_slot=-1;
                        matching_slots=0;
                        for(slot_index=0;slot_index<4;slot_index=slot_index+1) begin
                            checked_box=target_boxes[slot_index*48+:48];
                            if(checked_box[11:0]==object_x0(target_results,object_index) &&
                               checked_box[23:12]==object_x0(target_results,object_index)+63 &&
                               checked_box[35:24]==object_y0(target_results,object_index) &&
                               checked_box[47:36]==object_y0(target_results,object_index)+63) begin
                                located_slot=slot_index;
                                matching_slots=matching_slots+1;
                            end
                        end
                        if(matching_slots!=1)
                            $fatal(1,"Missing/duplicate independent box result=%0d object=%0d expected=%0d,%0d,%0d,%0d actual=%h",
                                target_results,object_index,
                                object_x0(target_results,object_index),
                                object_x0(target_results,object_index)+63,
                                object_y0(target_results,object_index),
                                object_y0(target_results,object_index)+63,target_boxes);
                        if(target_shapes[located_slot*2+:2]!==2'd1)
                            $fatal(1,"AWB square shape or spatial slot mismatch result=%0d object=%0d slot=%0d shape=%0d",
                                target_results,object_index,located_slot,
                                target_shapes[located_slot*2+:2]);
                        shapes_checked=shapes_checked+1;
                        if(target_results==1) slot_for_object[object_index]=located_slot;
                        else begin
                            if(slot_for_object[object_index]!=located_slot)
                                $fatal(1,"Small movement changed the object's slot");
                            stable_slots=stable_slots+1;
                        end
                        boxes_checked=boxes_checked+1;
                    end
                end
                previous_toggle=target_toggle;
                target_results=target_results+1;
            end
            if(output_user) begin
                if(!sampled_edge_user)
                    $fatal(1,"Packed SOF no longer follows display SOF by one clock");
                if(packed_frame>=0 && packed_count[packed_frame]!=FRAME_WORDS)
                    $fatal(1,"Packed preceding frame lost words");
                packed_frame=packed_frame+1;
                if(packed_frame>2 || latency_id!==expected_id(packed_frame))
                    $fatal(1,"Packed SOF ID mismatch frame=%0d id=%0d expected=%0d",
                        packed_frame,latency_id,expected_id(packed_frame));
                packed_labels=packed_labels+1;
            end
            if(output_valid) begin
                if(packed_frame<0 || packed_frame>2 ||
                    latency_id!==expected_id(packed_frame) || (^output_data)===1'bx)
                    $fatal(1,"Packed pixels crossed their frame ID");
                packed_count[packed_frame]=packed_count[packed_frame]+1;
                pixel_labels=pixel_labels+1;
            end
        end
    end

    task automatic tick(
        input bit valid, input bit user, input bit last,
        input [127:0] rgb, input [9:0] id
    );
        @(negedge clk);
        source_valid=valid; source_user=user; source_last=last;
        injected_rgb=rgb; injected_id=id;
        @(posedge clk); #2;
    endtask
    integer f,y,g,timeout_cycles;
    initial begin
        force dut.m_aixs_tdata=injected_rgb;
        force dut.m_aixs_tvalid=source_valid;
        force dut.m_aixs_tuser=source_user;
        force dut.m_aixs_tlast=source_last;
        force dut.demosaic_frame_id=injected_id;
        for(f=0;f<3;f=f+1) begin
            awb_count[f]=0; edge_count[f]=0; packed_count[f]=0;
        end
        for(f=0;f<4;f=f+1) slot_for_object[f]=-1;
        repeat(5) tick(0,0,0,0,10'd777);
        @(negedge clk); rst_n=1;
        repeat(5) tick(0,0,0,0,10'd777);
        for(f=0;f<3;f=f+1) begin
            // At each SOF the new ID appears on the same edge as the marker.
            // Frame 1 has an early SOF; frames 0 and 2 pair it with pixel 0.
            // Afterwards ID=777 deliberately invalidates any uncaptured use.
            if(f==1) begin
                tick(0,1,0,0,expected_id(f));
                repeat(2) tick(0,0,0,0,10'd777);
            end
            for(y=0;y<H;y=y+1) begin
                for(g=0;g<GROUPS;g=g+1)
                    tick(1,f!=1 && y==0 && g==0,g==GROUPS-1,
                        scene_group(f,g,y),
                        f!=1 && y==0 && g==0 ? expected_id(f) : 10'd777);
                repeat(4) tick(0,0,0,0,10'd777);
            end
            timeout_cycles=0;
            while(target_results!=f+1 && timeout_cycles<20000) begin
                tick(0,0,0,0,10'd777);
                timeout_cycles=timeout_cycles+1;
            end
            if(target_results!=f+1)
                $fatal(1,"No production multi-target result for frame%0d",f);
            repeat(128) tick(0,0,0,0,10'd777);
        end
        repeat(128) tick(0,0,0,0,10'd777);
        for(f=0;f<3;f=f+1)
            if(awb_count[f]!=FRAME_GROUPS || edge_count[f]!=FRAME_GROUPS ||
               packed_count[f]!=FRAME_WORDS)
                $fatal(1,"Frame%0d production count mismatch AWB=%0d display=%0d packed=%0d",
                    f,awb_count[f],edge_count[f],packed_count[f]);
        if(target_results!=3 || boxes_checked!=8 || shapes_checked!=8 || stable_slots!=4 ||
           packed_labels!=3 || pixel_labels!=3*FRAME_WORDS ||
           awb_frame!=2 || edge_frame!=2 || packed_frame!=2)
            $fatal(1,"Production multi-target integration coverage incomplete");
        $display("ISP_RED_MULTI_PASS frames=3 ids=1023,0,1 source_sof_same=2 source_sof_early=1 awb_groups=%0d display_groups=%0d packed_words=%0d result_tokens=%0d boxes=%0d stable_slots=%0d packed_labels=%0d shapes=%0d shape=SQR color=RED",
            3*FRAME_GROUPS,3*FRAME_GROUPS,3*FRAME_WORDS,
            target_results,boxes_checked,stable_slots,packed_labels,shapes_checked);
        $finish;
    end
    initial begin
        #15000000;
        $fatal(1,"Production ISP multi-target integration timeout");
    end
endmodule
