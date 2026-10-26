`timescale 1ns/1ps
// Exercise the real mixer, its native pixel coordinates, external target result
// latch, decimal text, original OSD and output timing at actual 720p size.
module tb_color_target_mixer;
    parameter integer MASK_VIEW = 0;
    parameter integer FRAMES = 8;
    localparam W=1280, H=720;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, de=0, user=0, last=0, hs=0, vs=0;
    reg [23:0] rgb=0;
    reg target_ready=0, target_found=0;
    reg [11:0] tx0=0,tx1=0,ty0=0,ty1=0,tcx=0,tcy=0;
    wire rd, out_de, out_hs, out_vs;
    wire [23:0] out_rgb;
    integer output_frame=0, output_x=0, output_y=0;
    integer output_pixels=0, boxes=0, crosses=0, label_pixels=0, logo_pixels=0;
    integer preview;
    bit sample_de, sample_hs, sample_vs, sample_osd;
    reg [23:0] sample_native, sample_osd_rgb;
    integer sample_x, sample_y;

    hdmi_mixer #(.IMG_WIDTH(W),.IMG_HEIGHT(H),
        .SHOW_COLOR_TARGET(1),.SHOW_CAMERA_STATUS(1),.SHOW_RED_MASK(MASK_VIEW)) dut (
        .I_clk(clk),.I_rst_n(rst_n),.I_video_de(de),
        .I_effect_mode(4'd0),.I_effect_param(8'd0),
        .I_video_user(user),.I_video_last(last),
        .I_video_hsync(hs),.I_video_vsync(vs),
        .I_debug_status(4'b1111),.I_cam_fail_index(8'd0),
        .I_video_rd_data(rgb),.O_video_rd_en(rd),
        .I_target_result_ready(target_ready),.I_target_found(target_found),
        .I_target_motion_mode(1'b0),.I_target_color_mode(2'd0),
        .I_target_xmin(tx0),.I_target_xmax(tx1),
        .I_target_ymin(ty0),.I_target_ymax(ty1),
        .I_target_center_x(tcx),.I_target_center_y(tcy),
        .O_hdmi_de(out_de),.O_hdmi_hsync(out_hs),
        .O_hdmi_vsync(out_vs),.O_hdmi_data(out_rgb)
    );

    function automatic [23:0] camera_pixel(input integer f, xx, yy);
        begin
            camera_pixel=24'h202830;
            if ((f<=1 && xx>=500 && xx<=639 && yy>=240 && yy<=379) ||
                ((f==2 || f==3) && xx>=800 && xx<=959 && yy>=450 && yy<=609))
                camera_pixel=24'hc82020;
            if (f==6) camera_pixel=24'hfafafa;
            if (f==7) camera_pixel=(xx[4]^yy[4]) ? 24'hffffff : 24'h000000;
        end
    endfunction

    function automatic [7:0] tone_channel(input integer value);
        integer x0,x1,y0,y1;
        begin
            if(value<16) begin x0=0;x1=16;y0=0;y1=23;end
            else if(value<32) begin x0=16;x1=32;y0=23;y1=44;end
            else if(value<64) begin x0=32;x1=64;y0=44;y1=80;end
            else if(value<96) begin x0=64;x1=96;y0=80;y1=104;end
            else if(value<128) begin x0=96;x1=128;y0=104;y1=128;end
            else if(value<160) begin x0=128;x1=160;y0=128;y1=152;end
            else if(value<192) begin x0=160;x1=192;y0=152;y1=180;end
            else if(value<224) begin x0=192;x1=224;y0=180;y1=210;end
            else if(value<240) begin x0=224;x1=240;y0=210;y1=232;end
            else begin x0=240;x1=255;y0=232;y1=255;end
            tone_channel=y0+((value-x0)*(y1-y0)+(x1-x0)/2)/(x1-x0);
        end
    endfunction
    function automatic [23:0] tone_pixel(input [23:0] source_rgb);
        tone_pixel={tone_channel(source_rgb[23:16]),tone_channel(source_rgb[15:8]),
            tone_channel(source_rgb[7:0])};
    endfunction

    function automatic bit expected_found(input integer f);
        // Frame 7 is monochrome video with a target result produced from the
        // RGB branch. It must retain the box despite having no red pixels.
        expected_found=(f>=1 && f<=4) || (f==7);
    endfunction
    function automatic integer expected_x0(input integer f);
        expected_x0=(f<=2) ? 500 : 800;
    endfunction
    function automatic integer expected_y0(input integer f);
        expected_y0=(f<=2) ? 240 : 450;
    endfunction
    function automatic integer expected_x1(input integer f);
        expected_x1=(f<=2) ? 639 : 959;
    endfunction
    function automatic integer expected_y1(input integer f);
        expected_y1=(f<=2) ? 379 : 609;
    endfunction
    function automatic [15:0] decimal_bcd(input integer value);
        decimal_bcd={4'(value/1000),4'((value/100)%10),4'((value/10)%10),4'(value%10)};
    endfunction
    function automatic integer abs_value(input integer value);
        abs_value=(value<0) ? -value : value;
    endfunction

    always @(posedge clk) begin: check_output
        integer x0,x1,y0,y1,cx,cy;
        bit box_on,cross_on,panel_on;
        reg [23:0] expected_rgb,expected_native;
        sample_de=dut.S_video_de_2d;
        sample_hs=dut.S_video_hsync_2d;
        sample_vs=dut.S_video_vsync_2d;
        sample_x=dut.S_x_2d; sample_y=dut.S_y_2d;
        sample_native=dut.S_video_data_2d;
        sample_osd=dut.S_osd_hit; sample_osd_rgb=dut.S_osd_color;
        #1;
        if (rst_n) begin
            if (rd !== de || out_de !== sample_de || out_hs !== sample_hs || out_vs !== sample_vs)
                $fatal(1,"Mixer altered output sync or read enable");
            if (out_de) begin
                if (sample_x != output_x || sample_y != output_y)
                    $fatal(1,"Coordinate mismatch frame=%0d expected=%0d,%0d got=%0d,%0d",
                        output_frame,output_x,output_y,sample_x,sample_y);
                expected_native=tone_pixel(camera_pixel(output_frame,output_x,output_y));
                if (sample_native !== expected_native)
                    $fatal(1,"Native pixel/gamma mismatch");
                if (dut.S_target_found !== expected_found(output_frame))
                    $fatal(1,"Frame-latched target status mismatch frame=%0d",output_frame);
                x0=expected_x0(output_frame); x1=expected_x1(output_frame);
                y0=expected_y0(output_frame); y1=expected_y1(output_frame);
                cx=(x0+x1)/2; cy=(y0+y1)/2;
                if (expected_found(output_frame)) begin
                    if (dut.S_target_xmin != x0 || dut.S_target_xmax != x1 ||
                        dut.S_target_ymin != y0 || dut.S_target_ymax != y1 ||
                        dut.S_target_center_x != cx || dut.S_target_center_y != cy)
                        $fatal(1,"Frame-latched box or center mismatch");
                    if (output_y>0 && (dut.S_target_bcd_x !== decimal_bcd(cx) ||
                                      dut.S_target_bcd_y !== decimal_bcd(cy)))
                        $fatal(1,"Decimal coordinate conversion mismatch");
                end
                box_on=expected_found(output_frame) &&
                    output_x>=x0 && output_x<=x1 && output_y>=y0 && output_y<=y1 &&
                    (output_x<x0+2 || output_x+2>x1 || output_y<y0+2 || output_y+2>y1);
                cross_on=expected_found(output_frame) &&
                    (((abs_value(output_x-cx)<=1) && (abs_value(output_y-cy)<=6)) ||
                     ((abs_value(output_y-cy)<=1) && (abs_value(output_x-cx)<=6)));
                panel_on=(output_x>=16 && output_x<384 && output_y>=H-32 && output_y<H-16);
                // Original OSD priority is tested on every OSD pixel; green
                // status blocks are outside its mask and checked separately.
                if (sample_osd) begin
                    if (out_rgb !== sample_osd_rgb) $fatal(1,"Existing OSD overwritten");
                    logo_pixels=logo_pixels+1;
                end else if (output_y>=16 && output_y<32 &&
                    ((output_x>=192 && output_x<208) ||
                     (output_x>=216 && output_x<232) ||
                     (output_x>=240 && output_x<256) ||
                     (output_x>=264 && output_x<280))) begin
                    if (out_rgb !== 24'h00ff00) $fatal(1,"Camera status overwritten");
                end else if (panel_on) begin
                    if (out_rgb !== 24'hfff200 && out_rgb !== 24'h101010)
                        $fatal(1,"Text panel has an invalid color");
                    if (out_rgb == 24'hfff200) label_pixels=label_pixels+1;
                end else begin
                    expected_rgb=box_on ? 24'hff3030 : cross_on ? 24'hfff200 : expected_native;
                    if (out_rgb !== expected_rgb) $fatal(1,"Overlay mismatch %0d,%0d",output_x,output_y);
                    if (box_on) boxes=boxes+1;
                    if (cross_on) crosses=crosses+1;
                end
                if (output_frame==1)
                    $fwrite(preview,"%c%c%c",out_rgb[23:16],out_rgb[15:8],out_rgb[7:0]);
                output_pixels=output_pixels+1;
                if (output_x==W-1) begin
                    output_x=0;
                    if (output_y==H-1) begin output_y=0; output_frame=output_frame+1; end
                    else output_y=output_y+1;
                end else output_x=output_x+1;
            end
        end
    end

    task automatic blank(input integer cycles);
        begin
            @(negedge clk); de=0; user=0; last=0; rgb=0; hs=1;
            repeat(cycles) @(negedge clk);
            hs=0;
        end
    endtask

    initial begin
        preview=$fopen(MASK_VIEW ? "red_target_mask_preview.ppm" : "red_target_preview.ppm","wb");
        if (!preview) $fatal(1,"Cannot open temporary preview");
        $fwrite(preview,"P6\n1280 720\n255\n");
        blank(6); rst_n=1;
        for (integer f=0; f<FRAMES; f=f+1) begin
            target_ready=(f>0);
            target_found=expected_found(f);
            tx0=expected_x0(f); tx1=expected_x1(f);
            ty0=expected_y0(f); ty1=expected_y1(f);
            tcx=(tx0+tx1)/2; tcy=(ty0+ty1)/2;
            for (integer yy=0; yy<H; yy=yy+1) begin
                for (integer xx=0; xx<W; xx=xx+1) begin
                    @(negedge clk);
                    de=1; user=(xx==0 && yy==0); last=(xx==W-1);
                    rgb=camera_pixel(f,xx,yy);
                end
                blank(12);
            end
            vs=1; blank(25); vs=0;
        end
        blank(12);
        $fclose(preview);
        if (output_frame!=FRAMES || output_pixels!=FRAMES*W*H || boxes==0 || crosses==0 ||
            label_pixels==0 || logo_pixels==0) $fatal(1,"Incomplete mixer verification");
        $display("COLOR_TARGET_MIXER_PASS mask=%0d pixels=%0d box=%0d cross=%0d text=%0d osd=%0d",
            MASK_VIEW,output_pixels,boxes,crosses,label_pixels,logo_pixels);
        $finish;
    end
    initial begin #120000000; $fatal(1,"Mixer test timeout"); end
endmodule
