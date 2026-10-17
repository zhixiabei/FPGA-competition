`timescale 1ns/1ps
module tb_red_multi_switch;
    localparam integer W=256, H=128, GROUPS=W/4;
    reg clk=0, rst_n=0, request_motion=0, user=0, last=0, valid=0;
    reg [95:0] data=0;
    reg [9:0] frame_id=0;
    wire ready, found, toggle, result_motion, active_motion, overflow;
    wire [9:0] result_id;
    wire [11:0] xmin,xmax,ymin,ymax,cx,cy;
    wire [23:0] pixels;
    wire [3:0] multi_valid,multi_hold;
    wire [191:0] boxes;
    always #5 clk=~clk;
    target_detect_switch_96 #(
        .IMG_WIDTH(W), .IMG_HEIGHT(H), .RED_MIN_PIXELS(32),
        .MIN_BLOCKS(8), .DIFF_THRESHOLD(6), .MOTION_STABLE_ENABLE(1), .RED_MULTI_ENABLE(1)
    ) dut (
        .I_clk(clk), .I_rst_n(rst_n), .I_motion_mode_async(request_motion),
        .I_tuser(user), .I_tlast(last), .I_tvalid(valid), .I_tdata(data), .I_frame_id(frame_id),
        .O_result_ready(ready), .O_found(found), .O_xmin(xmin), .O_xmax(xmax),
        .O_ymin(ymin), .O_ymax(ymax), .O_center_x(cx), .O_center_y(cy), .O_pixels(pixels),
        .O_frame_toggle(toggle), .O_target_motion_mode(result_motion),
        .O_motion_mode_active(active_motion), .O_result_frame_id(result_id),
        .O_multi_valid(multi_valid), .O_multi_hold(multi_hold), .O_multi_boxes(boxes),
        .O_multi_overflow(overflow)
    );
    reg seen [0:127], seen_mode [0:127], seen_found [0:127];
    reg [3:0] seen_multi [0:127], seen_hold [0:127];
    reg [191:0] seen_boxes [0:127];
    reg [23:0] seen_pixels [0:127];
    reg [11:0] seen_xmin [0:127];
    integer result_cycle [0:127], sof_cycle [0:127], raw_cycle [0:127];
    integer raw_observed_id [0:127], queued_raw=0;
    integer cycle=0, results=0, checks=0, cross_sof=0, n;
    reg previous_toggle=0, forcing=0;
    reg inject_red=0, inject_motion=0;
    reg [9:0] inject_red_id=0, inject_motion_id=0;
    reg [3:0] inject_valid=0;
    reg [191:0] inject_boxes=0;
    reg [23:0] inject_pixels=0;

    always @(posedge clk) begin
        cycle=cycle+1;
        if (rst_n && user) sof_cycle[frame_id]=cycle;
        if (rst_n && dut.raw_motion_ready && !forcing) begin
            raw_cycle[queued_raw]=cycle;
            raw_observed_id[queued_raw]=dut.gen_multi_result.completion_id;
            queued_raw=queued_raw+1;
        end
        #1;
        if (!rst_n) previous_toggle=0;
        else if (ready) begin
            if (result_id >= 128 || seen[result_id])
                $fatal(1,"Duplicate/unexpected switch result %0d",result_id);
            if (toggle !== !previous_toggle)
                $fatal(1,"Output toggle did not follow each completion");
            if (overflow) $fatal(1,"Ordinary switch case overflowed %0d",result_id);
            previous_toggle=toggle;
            seen[result_id]=1; seen_mode[result_id]=result_motion;
            seen_found[result_id]=found; seen_multi[result_id]=multi_valid;
            seen_hold[result_id]=multi_hold; seen_boxes[result_id]=boxes;
            seen_pixels[result_id]=pixels; seen_xmin[result_id]=xmin;
            result_cycle[result_id]=cycle;
            results=results+1;
        end
    end
    function integer pop4;
        input [3:0] mask;
        begin pop4=mask[0]+mask[1]+mask[2]+mask[3]; end
    endfunction
    function [23:0] rgb;
        input integer scene,x,y;
        reg red;
        begin
            red=(x>=16 && x<=39 && y>=16 && y<=35) ||
                (x>=96 && x<=119 && y>=16 && y<=35) ||
                (x>=16 && x<=39 && y>=80 && y<=99) ||
                (x>=176 && x<=199 && y>=80 && y<=99);
            if (scene==0) rgb=red ? 24'hd00806 : 24'h181818;
            else if (scene==2 && x>=48 && x<96 && y>=32 && y<72) rgb=24'h606060;
            else rgb=24'h181818;
        end
    endfunction
    task blank;
        input integer cycles;
        integer c;
        begin
            for(c=0;c<cycles;c=c+1) begin
                @(negedge clk); user=0; valid=0; last=0; data=0;
            end
        end
    endtask
    task reset_dut;
        begin
            @(negedge clk); rst_n=0; user=0; valid=0; last=0; request_motion=0;
            blank(4);
            @(negedge clk); rst_n=1;
            blank(6);
        end
    endtask
    task marker;
        input integer id, mode;
        begin
            @(negedge clk); request_motion=mode;
            blank(5);
            @(negedge clk); user=1; frame_id=id;
            @(negedge clk); user=0;
        end
    endtask
    task send_frame;
        input integer id,scene,expected_mode,mid_mode;
        integer y,g,l;
        begin
            @(negedge clk); user=1; valid=0; last=0; frame_id=id;
            @(negedge clk); user=0; frame_id=10'd999;
            for(y=0;y<H;y=y+1) begin
                for(g=0;g<GROUPS;g=g+1) begin
                    @(negedge clk); valid=1; last=g==GROUPS-1;
                    for(l=0;l<4;l=l+1) data[95-l*24-:24]=rgb(scene,g*4+l,y);
                    if (active_motion !== expected_mode[0])
                        $fatal(1,"Mode changed within frame %0d",id);
                    if (y==H/2 && g==0) request_motion=mid_mode;
                end
            end
            @(negedge clk); valid=0; last=0; data=0;
        end
    endtask
    task expect_result;
        input integer id, mode, count;
        integer c;
        begin
            c=0;
            while(!seen[id] && c<2000) begin @(negedge clk); c=c+1; end
            if(!seen[id] || seen_mode[id] !== mode[0] || pop4(seen_multi[id]) != count)
                $fatal(1,"Missing/mistagged switch result %0d seen=%b mode=%b multi=%b expected=%0d/%0d",
                    id,seen[id],seen_mode[id],seen_multi[id],mode,count);
            if(mode && (seen_multi[id]!=0 || seen_hold[id]!=0 || seen_boxes[id]!=0))
                $fatal(1,"Motion result retained red metadata %0d",id);
            checks=checks+1;
        end
    endtask
    task begin_forcing;
        begin
            forcing=1;
            force dut.multi_ready=inject_red;
            force dut.multi_frame_id=inject_red_id;
            force dut.multi_valid=inject_valid;
            force dut.multi_hold=4'b0;
            force dut.multi_boxes=inject_boxes;
            force dut.multi_overflow=1'b0;
            force dut.motion_ready=inject_motion;
            force dut.gen_multi_result.motion_id_2d=inject_motion_id;
            force dut.motion_found=1'b1;
            force dut.motion_xmin=12'd24;
            force dut.motion_xmax=12'd63;
            force dut.motion_ymin=12'd32;
            force dut.motion_ymax=12'd63;
            force dut.motion_cx=12'd43;
            force dut.motion_cy=12'd47;
            force dut.motion_pixels=inject_pixels;
        end
    endtask
    task end_forcing;
        begin
            release dut.multi_ready; release dut.multi_frame_id;
            release dut.multi_valid; release dut.multi_hold;
            release dut.multi_boxes; release dut.multi_overflow;
            release dut.motion_ready; release dut.gen_multi_result.motion_id_2d;
            release dut.motion_found; release dut.motion_xmin; release dut.motion_xmax;
            release dut.motion_ymin; release dut.motion_ymax;
            release dut.motion_cx; release dut.motion_cy; release dut.motion_pixels;
            forcing=0;
        end
    endtask

    initial begin
        for(n=0;n<128;n=n+1) begin
            seen[n]=0; seen_mode[n]=0; seen_multi[n]=0; seen_found[n]=0; seen_hold[n]=0;
            seen_boxes[n]=0; seen_pixels[n]=0; seen_xmin[n]=0;
            result_cycle[n]=0; sof_cycle[n]=0; raw_cycle[n]=0; raw_observed_id[n]=0;
        end
        reset_dut();
        send_frame(1,0,0,0);
        send_frame(2,0,0,0);
        send_frame(3,0,0,0);
        expect_result(1,0,0); expect_result(2,0,4); expect_result(3,0,4);
        if(result_cycle[1] <= sof_cycle[2] || result_cycle[2] <= sof_cycle[3])
            $fatal(1,"Red pipeline did not cross the following SOF");
        cross_sof=cross_sof+2;
        if(seen_boxes[2] !== seen_boxes[3])
            $fatal(1,"Stable red objects changed slots");

        request_motion=1; blank(6);
        send_frame(10,0,1,0);
        send_frame(11,0,0,0);
        expect_result(10,1,0); expect_result(11,0,0);
        send_frame(12,0,0,0); expect_result(12,0,4);
        if(result_cycle[10] <= sof_cycle[11])
            $fatal(1,"Motion pipeline did not cross next SOF");
        cross_sof=cross_sof+1;

        // Real motion and stabilization: three repeated local frame changes
        // confirm the object; the next SOF precedes the preceding result.
        request_motion=1; blank(6);
        send_frame(20,1,1,1);
        send_frame(21,2,1,1);
        send_frame(22,1,1,1);
        send_frame(23,2,1,1);
        send_frame(24,1,1,1);
        expect_result(20,1,0); expect_result(21,1,0); expect_result(22,1,0);
        expect_result(23,1,0); expect_result(24,1,0);
        if(!seen_found[23] || !seen_found[24])
            $fatal(1,"Real stable motion did not confirm");
        for(n=0;n<queued_raw;n=n+1) begin
            if(raw_observed_id[n]>=20 && raw_observed_id[n]<=24 &&
               result_cycle[raw_observed_id[n]] != raw_cycle[n]+2)
                $fatal(1,"Stable motion ID/data latency mismatch id=%0d raw=%0d result=%0d",
                    raw_observed_id[n],raw_cycle[n],result_cycle[raw_observed_id[n]]);
        end
        checks=checks+5;

        // Force only completed-source interfaces to exercise extreme ordering.
        reset_dut(); begin_forcing();
        marker(40,0); marker(41,1);
        @(negedge clk);
        inject_red_id=40; inject_valid=4'b0001;
        inject_boxes=192'b0;
        inject_boxes[47:0]={12'd49,12'd20,12'd39,12'd10};
        inject_motion_id=41; inject_pixels=24'd1216;
        inject_red=1; inject_motion=1;
        @(negedge clk); inject_red=0; inject_motion=0;
        expect_result(40,0,1); expect_result(41,1,0);
        if(result_cycle[41] != result_cycle[40]+1 || seen_pixels[41]!=1216 ||
           seen_xmin[40]!=10)
            $fatal(1,"Simultaneous completions were lost or data packing changed");
        if(active_motion != 1 || seen_mode[40] != 0)
            $fatal(1,"Old red result inherited the current K2 mode");
        checks=checks+2;

        marker(42,0); marker(43,1);
        @(negedge clk);
        inject_red_id=42; inject_motion_id=43; inject_pixels=24'd2240;
        inject_red=1; inject_motion=1;
        @(negedge clk); inject_red=0; inject_motion=0;
        expect_result(42,0,1); expect_result(43,1,0);
        if(seen_pixels[43] != 2240) $fatal(1,"Second collision changed motion payload");
        end_forcing();

        // Exercise the real stabilizer with raw completions in adjacent
        // clocks, each carrying a different frame's metadata and count.
        reset_dut();
        marker(80,1); marker(81,1); marker(82,1);
        forcing=1;
        force dut.raw_motion_ready=inject_motion;
        force dut.raw_motion_found=1'b1;
        force dut.motion_scene_change=1'b0;
        force dut.motion_supported_blocks=24'd32;
        force dut.raw_motion_xmin=12'd24;
        force dut.raw_motion_xmax=12'd63;
        force dut.raw_motion_ymin=12'd32;
        force dut.raw_motion_ymax=12'd63;
        force dut.raw_motion_pixels=inject_pixels;
        force dut.gen_multi_result.completion_id=inject_motion_id;
        @(negedge clk); inject_motion=1; inject_motion_id=80; inject_pixels=24'd100;
        @(negedge clk); inject_motion_id=81; inject_pixels=24'd200;
        @(negedge clk); inject_motion_id=82; inject_pixels=24'd300;
        @(negedge clk); inject_motion=0;
        expect_result(80,1,0); expect_result(81,1,0); expect_result(82,1,0);
        if(seen_found[80] || seen_found[81] || !seen_found[82] || seen_pixels[82]!=300 ||
           result_cycle[81]!=result_cycle[80]+1 || result_cycle[82]!=result_cycle[81]+1)
            $fatal(1,"Back-to-back raw completions lost stable frame tags");
        checks=checks+3;
        release dut.raw_motion_ready; release dut.raw_motion_found;
        release dut.motion_scene_change; release dut.motion_supported_blocks;
        release dut.raw_motion_xmin; release dut.raw_motion_xmax;
        release dut.raw_motion_ymin; release dut.raw_motion_ymax;
        release dut.raw_motion_pixels; release dut.gen_multi_result.completion_id;
        forcing=0;
        blank(30);
        $display("RED_MULTI_SWITCH_PASS results=%0d checks=%0d cross_sof=%0d real_raw=%0d",
            results,checks,cross_sof,queued_raw);
        $finish;
    end
    initial begin #10000000; $fatal(1,"Multi switch watchdog"); end
endmodule
