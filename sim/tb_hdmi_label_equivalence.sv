`timescale 1ns/1ps
// Preserve the historical core candidate/peer/layout, frame-cancel and
// pixel/control equivalence proof with both redesigned HUD features disabled.
// Their intentional new pixels/reservations use tb_latency_display_toggle
// and independent display oracles instead of the frozen UI snapshot.
module hdmi_label_equivalence_case #(
    parameter integer W=1280, H=720, CASES=128
)(output reg done=0);
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, de=0, user=0, last=0, show=0;
    reg [3:0] mode=0, valid=0, held=0;
    reg [1:0] color=0;
    reg ready=0, found=0, motion=0, overflow=0;
    reg [191:0] boxes=0;
    reg [7:0] shapes=0;
    reg [11:0] xmin=0,xmax=0,ymin=0,ymax=0,cx=0,cy=0;
    reg [23:0] rgb=0;
    wire [23:0] got,want;
    wire gde,wde,grd,wrd,gsof,wsof,ghs,whs,gvs,wvs;
`define MIXER_PORTS(DATA,DE,RD,SOF,HS,VS) \
        .I_clk(clk),.I_rst_n(rst_n),.I_video_vsync(1'b0), \
        .I_video_hsync(1'b0),.I_video_de(de),.I_video_user(user), \
        .I_video_last(last),.I_effect_mode(mode),.I_effect_param(8'd0), \
        .I_debug_status(4'hf),.I_cam_fail_index(8'd0), \
        .I_raw_stats_valid(1'b0),.I_raw_stats_data(45'd0), \
        .I_ae_readout_valid(1'b0),.I_ae_readout_data(28'd0), \
        .I_latency_sample_strobe(1'b0),.I_latency_show(show), \
        .I_latency_sample_valid(1'b0),.I_latency_total_us(20'd0), \
        .I_latency_isp_us(20'd0),.I_latency_buffer_us(20'd0), \
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
        .SHOW_COLOR_TARGET(1),.SHOW_CAMERA_STATUS(1),.SHOW_EFFECT_LABEL(0),
        .SHOW_LATENCY(0),.LATENCY_SWITCH_ENABLE(1)) dut(
        `MIXER_PORTS(got,gde,grd,gsof,ghs,gvs)
    );
    hdmi_mixer_reference #(.IMG_WIDTH(W),.IMG_HEIGHT(H),.MULTI_TARGET_ENABLE(1),
        .SHOW_COLOR_TARGET(1),.SHOW_CAMERA_STATUS(1),.SHOW_EFFECT_LABEL(0),
        .SHOW_LATENCY(0),.LATENCY_SWITCH_ENABLE(1)) reference(
        `MIXER_PORTS(want,wde,wrd,wsof,whs,wvs)
    );
`undef MIXER_PORTS
    reg [31:0] noise=32'h5d1f320a+W;
    integer f,n,s,checks=0,max_cycles=0,layout_cycles;
    function [31:0] next_random(input [31:0] x);
        next_random=x*32'd1664525+32'd1013904223;
    endfunction
    task tick(input reg sof);
        begin
            @(negedge clk);
            user=sof;noise=next_random(noise);rgb=noise[23:0];
            @(posedge clk);#1;
            if ({got,gde,grd,gsof,ghs,gvs} !==
                {want,wde,wrd,wsof,whs,wvs})
                $fatal(1,"Pixel/control mismatch W=%0d f=%0d n=%0d",W,f,n);
            checks=checks+1;
        end
    endtask
    task compare_layout;
        begin
            if (dut.multi_target.layout_busy || reference.multi_target.layout_busy)
                $fatal(1,"Layout exceeded bound W=%0d f=%0d",W,f);
            if ({dut.multi_target.label_valid,dut.multi_target.label_compact} !==
                {reference.multi_target.label_valid,reference.multi_target.label_compact})
                $fatal(1,"Layout valid mismatch W=%0d f=%0d",W,f);
            for(s=0;s<4;s=s+1)
                if ({dut.multi_target.label_x[s],dut.multi_target.label_y[s]} !==
                    {reference.multi_target.label_x[s],reference.multi_target.label_y[s]})
                    $fatal(1,"Layout geometry mismatch W=%0d f=%0d slot=%0d",W,f,s);
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);
        rst_n=1;
        for(f=0;f<CASES;f=f+1) begin
            @(negedge clk);
            noise=next_random(noise);
            mode=f%13;color=f%3;show=f[0];motion=f[1];
            ready=f%11!=0;found=f%7!=0;overflow=f%17==0;
            valid=noise[3:0];held=noise[7:4];shapes=noise[15:8];
            for(s=0;s<4;s=s+1) begin
                noise=next_random(noise);
                // Mix ordered on-screen rectangles with clipped/invalid ones.
                if(f[2]) begin
                    boxes[s*48 +:12]=noise[10:0]%(W>1 ? W : 1);
                    boxes[s*48+12+:12]=boxes[s*48+:12]+12'd80;
                    boxes[s*48+24+:12]=noise[21:11]%(H>1 ? H : 1);
                    boxes[s*48+36+:12]=boxes[s*48+24+:12]+12'd60;
                end else boxes[s*48+:48]={noise,noise[15:0]};
            end
            if(f%16==0) begin
                // Every attempt intersects the fixed logo, exercising all
                // 128 candidates and 512 serial peer checks.
                ready=1;motion=0;valid=4'hf;
                for(s=0;s<4;s=s+1)
                    boxes[s*48+:48]={12'd40,12'd30,12'd10,12'd0};
            end
            xmin=boxes[11:0];xmax=boxes[23:12];
            ymin=boxes[35:24];ymax=boxes[47:36];
            cx=(xmin+xmax)>>1;cy=(ymin+ymax)>>1;
            de=1;
            tick(1);
            layout_cycles=0;
            // Includes the worst 4*32*4 peer checks; geometry is compared
            // even for invalid labels, preserving all old stored outputs.
            for(n=0;n<520;n=n+1) begin
                tick(0);
                if(dut.multi_target.layout_busy) layout_cycles=layout_cycles+1;
            end
            if(layout_cycles>max_cycles) max_cycles=layout_cycles;
            compare_layout;
            // A new SOF during incomplete layout must cancel the old work.
            if(f%9==0) begin
                tick(1);
                repeat(7) tick(0);
                tick(1);
                repeat(520) tick(0);
                compare_layout;
            end
            if(f%23==0) begin
                @(negedge clk);rst_n=0;
                repeat(3) tick(0);
                @(negedge clk);rst_n=1;
            end
        end
        $display("HDMI_LABEL_EQUIVALENCE_CASE_PASS W=%0d H=%0d cases=%0d checks=%0d max_layout_cycles=%0d",
            W,H,CASES,checks,max_cycles);
        done=1;
    end
endmodule

module tb_hdmi_label_equivalence;
    wire [2:0] done;
    hdmi_label_equivalence_case large_case(done[0]);
    hdmi_label_equivalence_case #(.W(128),.H(80),.CASES(40)) narrow_case(done[1]);
    hdmi_label_equivalence_case #(.W(64),.H(64),.CASES(40)) fallback_case(done[2]);
    initial begin
        wait(&done);
        $display("HDMI_LABEL_EQUIVALENCE_PASS cases=3");
        $finish;
    end
endmodule
