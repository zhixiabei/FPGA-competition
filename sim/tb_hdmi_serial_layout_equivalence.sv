`timescale 1ns/1ps
// Compare placement and complete pixel/control output with a frozen mixer.
// The video source scans real lines without blanking, giving placement the
// shortest possible time before the first permitted label scan line.
module tb_hdmi_serial_layout_equivalence #(
    parameter integer W=1280, H=720, CASES=192, SWEEP=0, PIXEL_PROBES=0
);
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, user=0, last=0, de=0;
    reg ready=0, found=0, motion=0, overflow=0, show=0;
    reg [3:0] mode=0, valid=0, held=0;
    reg [1:0] color=0;
    reg [191:0] boxes=0;
    reg [7:0] shapes=0;
    reg [11:0] xmin=0,xmax=0,ymin=0,ymax=0,cx=0,cy=0;
    reg [23:0] rgb=0;
    wire [23:0] got, want;
    wire gde,wde,grd,wrd,gsof,wsof,ghs,whs,gvs,wvs;
`define MIXER_PORTS(DATA,DE,RD,SOF,HS,VS) \
        .I_clk(clk),.I_rst_n(rst_n),.I_video_vsync(1'b0), \
        .I_video_hsync(last),.I_video_de(de),.I_video_user(user), \
        .I_video_last(last),.I_effect_mode(mode),.I_effect_param(8'd0), \
        .I_debug_status(4'hf),.I_cam_fail_index(8'd0), \
        .I_raw_stats_valid(1'b0),.I_raw_stats_data(45'd0), \
        .I_ae_readout_valid(1'b0),.I_ae_readout_data(28'd0), \
        .I_latency_sample_strobe(1'b0),.I_latency_show(show), \
        .I_latency_sample_valid(1'b0),.I_latency_total_us(20'd0), \
        .I_latency_isp_us(20'd0),.I_latency_buffer_us(20'd0), \
        .I_cnn_enable(1'b0),.I_cnn_result_valid(1'b0),.I_cnn_class(3'd1), \
        .I_hand_box_valid(1'b0),.I_hand_box(48'd0),.I_resnet_probe_status(32'd0), \
        .I_video_rd_data(rgb),.I_target_result_ready(ready), \
        .I_target_found(found),.I_target_motion_mode(motion), \
        .I_target_color_mode(color),.I_target_xmin(xmin),.I_target_xmax(xmax), \
        .I_target_ymin(ymin),.I_target_ymax(ymax), \
        .I_target_center_x(cx),.I_target_center_y(cy), \
        .I_target_multi_valid(valid),.I_target_multi_hold(held), \
        .I_target_multi_boxes(boxes),.I_target_multi_shapes(shapes), \
        .I_target_multi_overflow(overflow),.O_hdmi_data(DATA),.O_hdmi_de(DE), \
        .O_video_rd_en(RD),.O_display_frame_start(SOF), \
        .O_hdmi_hsync(HS),.O_hdmi_vsync(VS)
    hdmi_mixer #(.IMG_WIDTH(W),.IMG_HEIGHT(H),.MULTI_TARGET_ENABLE(1),
        .SHOW_COLOR_TARGET(1),.SHOW_CAMERA_STATUS(1),.SHOW_EFFECT_LABEL(1),
        .SHOW_RAW_STATS(1),.SHOW_LATENCY(1),.LATENCY_SWITCH_ENABLE(1)) dut(
        `MIXER_PORTS(got,gde,grd,gsof,ghs,gvs)
    );
    hdmi_mixer_reference #(.IMG_WIDTH(W),.IMG_HEIGHT(H),.MULTI_TARGET_ENABLE(1),
        .SHOW_COLOR_TARGET(1),.SHOW_CAMERA_STATUS(1),.SHOW_EFFECT_LABEL(1),
        .SHOW_RAW_STATS(1),.SHOW_LATENCY(1),.LATENCY_SWITCH_ENABLE(1)) reference(
        `MIXER_PORTS(want,wde,wrd,wsof,whs,wvs)
    );
`undef MIXER_PORTS
    reg [31:0] noise=32'h7bc129f5+W;
    integer f,n,s,checks=0,max_cycles=0,layout_cycles;
    integer scan_x=0,scan_y=0,restarts=0,complete=0;
    reg [1:0] sweep_slot=0;
    reg [4:0] sweep_attempt=0;
    reg [11:0] sweep_xmin=0,sweep_xmax=0,sweep_ymin=0,sweep_ymax=0;
    reg [12:0] expected_right=0,expected_bottom=0;
    integer candidate_checks=0;
    reg [11:0] probe_x=0,probe_y=0;
    integer label_pixel_checks=0;
    function [31:0] next_random(input [31:0] x);
        next_random=x*32'd1664525+32'd1013904223;
    endfunction
    task tick(input reg sof);
        begin
            @(negedge clk);
            if(sof) begin scan_x=0;scan_y=0;end
            user=sof;de=1;last=scan_x==W-1;
            noise=next_random(noise);rgb=noise[23:0];
            @(posedge clk);#1;
            if ({got,gde,grd,gsof,ghs,gvs} !==
                {want,wde,wrd,wsof,whs,wvs})
                $fatal(1,"Pixel/control mismatch W=%0d f=%0d at %0d,%0d",
                    W,f,scan_x,scan_y);
            if ({dut.multi_target.layout_busy,dut.multi_target.layout_slot,
                 dut.multi_target.layout_attempt,dut.multi_target.candidate_valid,
                 dut.multi_target.candidate_x,dut.multi_target.candidate_y,
                 dut.multi_target.candidate_width,dut.multi_target.label_valid,
                 dut.multi_target.label_compact} !==
                {reference.multi_target.layout_busy,reference.multi_target.layout_slot,
                 reference.multi_target.layout_attempt,reference.multi_target.candidate_valid,
                 reference.multi_target.candidate_x,reference.multi_target.candidate_y,
                 reference.multi_target.candidate_width,reference.multi_target.label_valid,
                 reference.multi_target.label_compact})
                $fatal(1,"Placement lost cycle equivalence W=%0d f=%0d slot=%0d attempt=%0d",
                    W,f,dut.multi_target.layout_slot,dut.multi_target.layout_attempt);
            for(integer k=0;k<4;k=k+1)
                if ({dut.multi_target.label_x[k],dut.multi_target.label_y[k]} !==
                    {reference.multi_target.label_x[k],reference.multi_target.label_y[k]})
                    $fatal(1,"Placement register changed edge W=%0d f=%0d slot=%0d",W,f,k);
            if({dut.multi_target.layout_xmin,dut.multi_target.layout_xmax,
                dut.multi_target.layout_ymin,dut.multi_target.layout_ymax} !==
               {reference.multi_target.xmin[reference.multi_target.layout_slot],
                reference.multi_target.xmax[reference.multi_target.layout_slot],
                reference.multi_target.ymin[reference.multi_target.layout_slot],
                reference.multi_target.ymax[reference.multi_target.layout_slot]})
                $fatal(1,"Slot geometry cache mismatch W=%0d f=%0d slot=%0d",
                    W,f,dut.multi_target.layout_slot);
            if(dut.multi_target.layout_busy && scan_y>=16)
                $fatal(1,"Label placement missed row-16 deadline W=%0d f=%0d",W,f);
            checks=checks+1;
            if(last) begin scan_x=0;scan_y=scan_y+1;end
            else scan_x=scan_x+1;
        end
    endtask
    task compare_layout;
        begin
            if ({dut.multi_target.label_valid,dut.multi_target.label_compact} !==
                {reference.multi_target.label_valid,reference.multi_target.label_compact})
                $fatal(1,"Layout valid mismatch W=%0d f=%0d",W,f);
            for(s=0;s<4;s=s+1)
                if ({dut.multi_target.label_x[s],dut.multi_target.label_y[s]} !==
                    {reference.multi_target.label_x[s],reference.multi_target.label_y[s]})
                    $fatal(1,"Layout position mismatch W=%0d f=%0d slot=%0d",W,f,s);
            complete=complete+1;
        end
    endtask
    task finish_layout;
        begin
            layout_cycles=0;
            while(dut.multi_target.layout_busy || reference.multi_target.layout_busy) begin
                tick(0);
                layout_cycles=layout_cycles+1;
                if(layout_cycles>1088)
                    $fatal(1,"Placement exceeded serial upper bound W=%0d f=%0d",W,f);
            end
            if(layout_cycles>=16*W)
                $fatal(1,"Placement exceeded available scan clocks W=%0d f=%0d",W,f);
            if(layout_cycles>max_cycles) max_cycles=layout_cycles;
            compare_layout;
        end
    endtask
    task sweep_candidates;
        begin
            force dut.multi_target.layout_busy=1'b0;
            force reference.multi_target.layout_busy=1'b0;
            force dut.multi_target.layout_slot=sweep_slot;
            force reference.multi_target.layout_slot=sweep_slot;
            force dut.multi_target.layout_attempt=sweep_attempt;
            force reference.multi_target.layout_attempt=sweep_attempt;
            force dut.multi_target.layout_xmin=sweep_xmin;
            force dut.multi_target.layout_xmax=sweep_xmax;
            force dut.multi_target.layout_ymin=sweep_ymin;
            force dut.multi_target.layout_ymax=sweep_ymax;
            for(integer slot_index=0;slot_index<4;slot_index=slot_index+1) begin
                sweep_slot=2'(slot_index);
                sweep_xmin=reference.multi_target.xmin[slot_index];
                sweep_xmax=reference.multi_target.xmax[slot_index];
                sweep_ymin=reference.multi_target.ymin[slot_index];
                sweep_ymax=reference.multi_target.ymax[slot_index];
                for(integer attempt_index=0;attempt_index<32;attempt_index=attempt_index+1) begin
                    sweep_attempt=5'(attempt_index);
                    #1;
                    expected_right=reference.multi_target.candidate_x+
                                   reference.multi_target.candidate_width;
                    expected_bottom=reference.multi_target.candidate_y+13'd16;
                    if({dut.multi_target.candidate_x,dut.multi_target.candidate_y,
                        dut.multi_target.candidate_width,dut.multi_target.candidate_valid,
                        dut.multi_target.candidate_right,dut.multi_target.candidate_bottom} !==
                       {reference.multi_target.candidate_x,reference.multi_target.candidate_y,
                        reference.multi_target.candidate_width,reference.multi_target.candidate_valid,
                        expected_right,expected_bottom})
                        $fatal(1,"Candidate/endpoint mismatch W=%0d f=%0d slot=%0d attempt=%0d",
                            W,f,slot_index,attempt_index);
                    candidate_checks=candidate_checks+1;
                end
            end
            release dut.multi_target.layout_busy;
            release reference.multi_target.layout_busy;
            release dut.multi_target.layout_slot;
            release reference.multi_target.layout_slot;
            release dut.multi_target.layout_attempt;
            release reference.multi_target.layout_attempt;
            release dut.multi_target.layout_xmin;
            release dut.multi_target.layout_xmax;
            release dut.multi_target.layout_ymin;
            release dut.multi_target.layout_ymax;
        end
    endtask
    task probe_label_pixels;
        integer ps,px,py,pwidth;
        begin
            // Only skip otherwise unused pixels after normal scanning has
            // completed placement. Both actual coordinate/output pipelines
            // still run, including both label borders and every glyph bit.
            force dut.S_x=probe_x;force reference.S_x=probe_x;
            force dut.S_y=probe_y;force reference.S_y=probe_y;
            for(ps=0;ps<4;ps=ps+1) begin
                if(reference.multi_target.label_valid[ps]) begin
                    pwidth=reference.multi_target.label_compact[ps] ?
                        reference.multi_target.compact_width : reference.multi_target.full_width;
                    for(py=-1;py<17;py=py+1) begin
                        for(px=-1;px<pwidth+1;px=px+1) begin
                            @(negedge clk);
                            probe_x=12'(reference.multi_target.label_x[ps]+px);
                            probe_y=12'(reference.multi_target.label_y[ps]+py);
                            noise=next_random(noise);rgb=noise[23:0];
                            de=1;user=0;last=0;
                            @(posedge clk);#1;
                            if({got,gde,grd,gsof,ghs,gvs,dut.S_follow_panel_on,
                                dut.S_follow_char,dut.S_follow_row,dut.S_follow_col,
                                dut.S_follow_color} !==
                               {want,wde,wrd,wsof,whs,wvs,reference.S_follow_panel_on,
                                reference.S_follow_char,reference.S_follow_row,reference.S_follow_col,
                                reference.S_follow_color})
                                $fatal(1,"Label pixel mismatch W=%0d f=%0d slot=%0d xy=%0d,%0d",
                                    W,f,ps,probe_x,probe_y);
                            label_pixel_checks=label_pixel_checks+1;
                        end
                    end
                end
            end
            repeat(4) begin
                @(negedge clk);
                de=0;user=0;last=0;
                @(posedge clk);#1;
                if({got,gde,grd,gsof,ghs,gvs} !== {want,wde,wrd,wsof,whs,wvs})
                    $fatal(1,"Label pixel pipeline tail mismatch W=%0d f=%0d",W,f);
            end
            release dut.S_x;release reference.S_x;
            release dut.S_y;release reference.S_y;
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);
        rst_n=1;
        for(f=0;f<CASES;f=f+1) begin
            @(negedge clk);
            noise=next_random(noise);
            mode=f%13;color=f%3;show=f[0];motion=f[1];
            ready=f%13!=0;found=f%11!=0;overflow=f%17==0;
            valid=noise[3:0];held=noise[7:4];shapes=noise[15:8];
            for(s=0;s<4;s=s+1) begin
                noise=next_random(noise);
                case(f%8)
                    0: boxes[s*48+:48]={12'd40,12'd30,12'd10,12'd0};
                    1: boxes[s*48+:48]={12'(H-1),12'(H-40),12'(W-1),12'(W-80)};
                    2: boxes[s*48+:48]={12'd110,12'd110,12'd512,12'd512};
                    3: boxes[s*48+:48]={12'd250,12'd220,12'd250,12'd190};
                    4: boxes[s*48+:48]={12'd100,12'd30,12'd900,12'd880};
                    5: boxes[s*48+:48]={noise,noise[15:0]};
                    default: begin
                        boxes[s*48+:12]=noise[10:0]%W;
                        boxes[s*48+12+:12]=boxes[s*48+:12]+12'(s*30+40);
                        boxes[s*48+24+:12]=noise[21:11]%H;
                        boxes[s*48+36+:12]=boxes[s*48+24+:12]+12'(s*20+30);
                    end
                endcase
                if(SWEEP!=0) begin
                    boxes[s*48+:12]=12'(f+s*1021);
                    boxes[s*48+12+:12]=12'(4095-f+s*19);
                    boxes[s*48+24+:12]=12'(f*73+s*997);
                    boxes[s*48+36+:12]=12'(4095-f*17+s*31);
                end
            end
            if(f%8==0 || f%8==2 || f%8==3) begin
                ready=1;found=1;motion=0;valid=4'hf;
            end
            xmin=boxes[11:0];xmax=boxes[23:12];
            ymin=boxes[35:24];ymax=boxes[47:36];
            cx=(xmin+xmax)>>1;cy=(ymin+ymax)>>1;
            tick(1);
            finish_layout;
            if(SWEEP!=0) sweep_candidates;
            if(PIXEL_PROBES!=0 && f%8==3) probe_label_pixels;
            if(f%9==0) begin
                tick(1);
                repeat(3) tick(0);
                // A new frame cancels any partially checked candidate.
                tick(1);
                finish_layout;
                restarts=restarts+1;
            end
            if(f%23==0) begin
                @(negedge clk);rst_n=0;
                repeat(3) tick(0);
                @(negedge clk);rst_n=1;
            end
        end
        if(complete<CASES || restarts==0)
            $fatal(1,"Incomplete layout/deadline coverage");
        if(SWEEP!=0 && candidate_checks!=CASES*128)
            $fatal(1,"Incomplete explicit candidate coverage checks=%0d",candidate_checks);
        if(PIXEL_PROBES!=0 && W==1280 && label_pixel_checks<10000)
            $fatal(1,"Incomplete label-pixel coverage checks=%0d",label_pixel_checks);
        $display("HDMI_SERIAL_LAYOUT_EQUIVALENCE_PASS W=%0d H=%0d cases=%0d checks=%0d max_layout_cycles=%0d row16_deadline=%0d restarts=%0d candidate_checks=%0d label_pixel_checks=%0d",
            W,H,CASES,checks,max_cycles,16*W,restarts,candidate_checks,label_pixel_checks);
        $finish;
    end
endmodule
