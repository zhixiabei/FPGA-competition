`timescale 1ns/1ps
// Exercise actual RGB through both detectors and the SOF mode selector.
// Detector results, metadata, clears, and mode signals are never forced.
module tb_single_target_switch;
    localparam integer W=256,H=128,GROUPS=W/4;
    reg clk=0,rst_n=0,user=0,last=0,valid=0;
    reg [1:0] request_mode=0;
    reg [11:0] effect_config=0;
    reg [9:0] frame_id=0;
    reg [95:0] data=0;
    wire ready,found,toggle,result_motion,active_motion,overflow;
    wire [1:0] result_color,active_color;
    wire [9:0] result_id;
    wire [11:0] xmin,xmax,ymin,ymax,cx,cy;
    wire [23:0] pixels;
    wire [3:0] target_valid,hold;
    wire [191:0] boxes;
    wire [7:0] shapes;
    reg seen[0:127],seen_found[0:127],seen_held[0:127];
    reg [1:0] expected_mode[0:127],seen_shape[0:127];
    reg [47:0] seen_box[0:127];
    integer results=0,checks=0,motion_found_count=0,n;
    reg previous_toggle=0;
    always #5 clk=~clk;
    target_detect_switch_96 #(
        .IMG_WIDTH(W),.IMG_HEIGHT(H),.RED_MIN_PIXELS(32),
        .DIFF_THRESHOLD(6),.MIN_BLOCKS(8),.MOTION_STABLE_ENABLE(1),
        .RED_MULTI_ENABLE(0),.SINGLE_SHAPE_ENABLE(1)
    ) dut (
        .I_clk(clk),.I_rst_n(rst_n),.I_motion_mode_async(request_mode==3),
        .I_color_mode_async(request_mode),.I_effect_config(effect_config),
        .I_tuser(user),.I_tlast(last),.I_tvalid(valid),.I_tdata(data),
        .I_frame_id(frame_id),.O_result_ready(ready),.O_found(found),
        .O_xmin(xmin),.O_xmax(xmax),.O_ymin(ymin),.O_ymax(ymax),
        .O_center_x(cx),.O_center_y(cy),.O_pixels(pixels),.O_frame_toggle(toggle),
        .O_target_motion_mode(result_motion),.O_target_color_mode(result_color),
        .O_motion_mode_active(active_motion),.O_color_mode_active(active_color),
        .O_result_frame_id(result_id),.O_multi_valid(target_valid),
        .O_multi_hold(hold),.O_multi_boxes(boxes),.O_multi_shapes(shapes),
        .O_mask_pixels(),.O_multi_overflow(overflow)
    );
    always @(posedge clk) begin
        #1;
        if(rst_n && ready) begin
            if(result_id>=128 || seen[result_id])
                $fatal(1,"Duplicate/unexpected real switch result id=%0d",result_id);
            if(toggle!==!previous_toggle)
                $fatal(1,"Completion toggle did not change id=%0d",result_id);
            if(result_motion!==(expected_mode[result_id]==3) ||
               (!result_motion && result_color!==expected_mode[result_id]))
                $fatal(1,"Result mode mismatch id=%0d actual=%0d/%0d expected=%0d",
                    result_id,result_motion,result_color,expected_mode[result_id]);
            if(overflow || target_valid[3:1]!==0 || hold[3:1]!==0 ||
               boxes[191:48]!==0 || shapes[7:2]!==0)
                $fatal(1,"Single switch leaked overflow/upper metadata id=%0d",result_id);
            if(result_motion && (target_valid!==0 || hold!==0 || boxes!==0 || shapes!==0))
                $fatal(1,"Motion result retained color shape metadata id=%0d",result_id);
            if(!result_motion && (found!==target_valid[0] || (!found && shapes[1:0]!==0)))
                $fatal(1,"Single color result fields disagree id=%0d",result_id);
            previous_toggle=toggle;
            seen[result_id]=1;seen_found[result_id]=found;
            seen_held[result_id]=hold[0];seen_shape[result_id]=shapes[1:0];
            seen_box[result_id]=boxes[47:0];results=results+1;
            if(result_motion && found) motion_found_count=motion_found_count+1;
            $display("SINGLE_SWITCH_RESULT id=%0d mode=%0d found=%0d hold=%0d shape=%0d",
                result_id,expected_mode[result_id],found,hold[0],shapes[1:0]);
        end
    end
    function [23:0] rgb(input integer scene,input integer color_mode,
                        input integer px,input integer py,input integer offset);
        reg [23:0] foreground;
        begin
            case(color_mode)
                1:foreground=24'h20f020;
                2:foreground=24'h2020f0;
                default:foreground=24'hf02020;
            endcase
            rgb=24'h101010;
            if(scene==1 && px>=72 && px<120 && py>=40 && py<88) rgb=foreground;
            if(scene==2 && px>=offset && px<offset+48 && py>=32 && py<80)
                rgb=24'hb0b0b0;
        end
    endfunction
    task blank(input integer cycles);
        integer c;
        begin
            for(c=0;c<cycles;c=c+1) begin
                @(negedge clk);user=0;valid=0;last=0;data=0;
            end
        end
    endtask
    task select_mode(input integer mode);
        begin
            @(negedge clk);request_mode=mode;
            blank(6);
        end
    endtask
    task send_rows(input integer id,input integer mode,input integer scene,
                   input integer offset,input integer row_count,input integer mid_mode);
        integer py,g,l;
        begin
            expected_mode[id]=mode;
            @(negedge clk);user=1;valid=0;last=0;frame_id=id;
            @(negedge clk);user=0;
            for(py=0;py<row_count;py=py+1)
                for(g=0;g<GROUPS;g=g+1) begin
                    @(negedge clk);valid=1;last=g==GROUPS-1;
                    for(l=0;l<4;l=l+1)
                        data[95-l*24-:24]=rgb(scene,mode,g*4+l,py,offset);
                    if(active_motion!==(mode==3) || active_color!==(mode==3 ? 2'd0 : mode[1:0]))
                        $fatal(1,"SOF mode changed inside RGB frame id=%0d mode=%0d active=%0d/%0d",
                            id,mode,active_motion,active_color);
                    if(py==H/2 && g==0 && mid_mode>=0) request_mode=mid_mode;
                end
            @(negedge clk);valid=0;last=0;data=0;
        end
    endtask
    task frame(input integer id,input integer mode,input integer scene,
               input integer offset,input integer mid_mode);
        begin send_rows(id,mode,scene,offset,H,mid_mode);end
    endtask
    task expect_result(input integer id,input integer expect_found,
                       input integer expect_hold,input integer expect_shape);
        integer c;
        begin
            c=0;
            while(!seen[id] && c<12000) begin @(negedge clk);c=c+1;end
            if(!seen[id] || (expect_found>=0 && seen_found[id]!==expect_found[0]) ||
               (expect_hold>=0 && seen_held[id]!==expect_hold[0]) ||
               (expect_shape>=0 && seen_shape[id]!==expect_shape[1:0]))
                $fatal(1,"Real switch result mismatch id=%0d seen=%0d found=%0d hold=%0d shape=%0d expected=%0d/%0d/%0d",
                    id,seen[id],seen_found[id],seen_held[id],seen_shape[id],
                    expect_found,expect_hold,expect_shape);
            if(expect_found==1 && expected_mode[id]!=3 &&
               seen_box[id]!=={12'd87,12'd40,12'd119,12'd72})
                $fatal(1,"Color box changed id=%0d box=%h",id,seen_box[id]);
            checks=checks+1;
        end
    endtask
    initial begin
        for(n=0;n<128;n=n+1) begin
            seen[n]=0;seen_found[n]=0;seen_held[n]=0;
            expected_mode[n]=0;seen_shape[n]=0;seen_box[n]=0;
        end
        blank(4);@(negedge clk);rst_n=1;blank(6);
        frame(1,0,1,0,-1);expect_result(1,0,0,0);
        frame(2,0,1,0,-1);expect_result(2,1,0,1);
        frame(3,0,1,0,1);expect_result(3,1,0,1);
        frame(4,1,1,0,-1);expect_result(4,0,0,0);
        frame(5,1,1,0,-1);expect_result(5,1,0,1);
        select_mode(2);
        frame(6,2,1,0,-1);expect_result(6,0,0,0);
        frame(7,2,1,0,-1);expect_result(7,1,0,1);
        select_mode(3);
        frame(8,3,0,0,-1);expect_result(8,-1,0,0);
        for(n=9;n<=13;n=n+1) begin
            frame(n,3,2,64+16*((n-9)%3),-1);expect_result(n,-1,0,0);
        end
        if(motion_found_count==0) $fatal(1,"Real motion detector never confirmed moving input");
        select_mode(0);
        frame(14,0,1,0,-1);expect_result(14,0,0,0);
        frame(15,0,1,0,-1);expect_result(15,1,0,1);
        // Next SOF arrives before the prior EOF has left the morphology pipe.
        frame(16,0,1,0,2);
        frame(17,2,1,0,-1);expect_result(17,0,0,0);
        frame(18,2,1,0,-1);expect_result(18,1,0,1);
        if(seen[16]) $fatal(1,"Mode clear published prior pipeline EOF id=16");
        // Change color after a truncated source, then require confirmation anew.
        send_rows(19,2,1,0,12,-1);
        select_mode(1);
        frame(20,1,1,0,-1);expect_result(20,0,0,0);
        frame(21,1,1,0,-1);expect_result(21,1,0,1);
        frame(22,1,0,0,-1);expect_result(22,1,1,1);
        frame(23,1,0,0,-1);expect_result(23,1,1,1);
        frame(24,1,0,0,-1);expect_result(24,0,0,0);
        // Signature overrides blue/motion only at SOF, and clears old tracks.
        select_mode(2);effect_config=12'hd00;
        frame(25,0,1,0,3);expect_result(25,0,0,0);
        frame(26,0,1,0,-1);expect_result(26,1,0,1);
        effect_config=12'hd01;
        frame(27,0,1,0,-1);expect_result(27,1,0,1);
        effect_config=12'h000;
        frame(28,3,0,0,-1);expect_result(28,-1,0,0);
        select_mode(0);
        frame(29,0,1,0,-1);expect_result(29,0,0,0);
        frame(30,0,1,0,-1);expect_result(30,1,0,1);
        effect_config=12'hd00;
        frame(31,0,1,0,-1);expect_result(31,0,0,0);
        frame(32,0,1,0,-1);expect_result(32,1,0,1);
        effect_config=12'h900;
        frame(33,0,1,0,-1);expect_result(33,0,0,0);
        frame(34,0,1,0,-1);expect_result(34,1,0,1);
        $display("SINGLE_TARGET_SWITCH_PASS results=%0d checks=%0d rgb_modes=3 motion_found=%0d sof_commit=1 tail_clear=1 partial_clear=1 hold=2 signature_red_override_restore=PASS",
            results,checks,motion_found_count);
        $finish;
    end
    initial begin
        #100000000;
        $fatal(1,"Real switch watchdog");
    end
endmodule
