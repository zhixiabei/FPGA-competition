`timescale 1ns/1ps

module tb_single_target_mixer;
    localparam integer W=640, H=360;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, de=0, user=0, last=0, hs=0, vs=0;
    reg [23:0] rgb=24'h123456;
    reg ready=1, found=1;
    reg [1:0] color_mode=2;
    reg [3:0] multi_valid=4'b1111, multi_hold=4'b1111;
    reg [191:0] multi_boxes=0;
    reg [7:0] multi_shapes=8'b11_01_11_10;
    reg [11:0] xmin=180, xmax=260, ymin=190, ymax=220;
    reg [11:0] center_x=220, center_y=205;
    wire rd, out_de, out_hs, out_vs;
    wire [23:0] out_rgb;

    integer output_x=0, output_y=0, output_frames=0, pixels=0;
    integer follow_pixels=0, follow_shape_pixels=0, panel_pixels=0;
    integer panel_shape_pixels=0, box_pixels=0, shape_glyphs=0;
    reg [7:0] ref_char;
    reg [3:0] ref_row, ref_col;
    wire [15:0] ref_bits;

    hdmi_mixer #(
        .IMG_WIDTH(W), .IMG_HEIGHT(H),
        .MULTI_TARGET_ENABLE(1), .TARGET_SLOTS(1),
        .SHOW_COLOR_TARGET(1)
    ) dut (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_video_de(de), .I_video_user(user), .I_video_last(last),
        .I_video_hsync(hs), .I_video_vsync(vs),
        .I_effect_mode(4'd0), .I_effect_param(8'd0),
        .I_debug_status(4'b1111), .I_cam_fail_index(8'd0),
        .I_latency_sample_strobe(1'b0), .I_latency_sample_valid(1'b0),
        .I_latency_total_us(20'd0), .I_latency_isp_us(20'd0),
        .I_latency_buffer_us(20'd0), .I_video_rd_data(rgb),
        .O_video_rd_en(rd), .O_display_frame_start(),
        .I_target_result_ready(ready), .I_target_found(found),
        .I_target_motion_mode(1'b0), .I_target_color_mode(color_mode),
        .I_target_xmin(xmin), .I_target_xmax(xmax),
        .I_target_ymin(ymin), .I_target_ymax(ymax),
        .I_target_center_x(center_x), .I_target_center_y(center_y),
        .I_target_multi_valid(multi_valid), .I_target_multi_hold(multi_hold),
        .I_target_multi_boxes(multi_boxes), .I_target_multi_shapes(multi_shapes),
        .I_target_multi_overflow(1'b0),
        .O_hdmi_de(out_de), .O_hdmi_hsync(out_hs),
        .O_hdmi_vsync(out_vs), .O_hdmi_data(out_rgb)
    );

    osd_char_lib reference_font (
        .I_char(ref_char), .I_row(ref_row), .O_row_bits(ref_bits)
    );

    function automatic [7:0] panel_char(input integer column);
        begin
            case (column)
                0: panel_char="B";
                1: panel_char="L";
                2: panel_char="U";
                3: panel_char=":";
                4: panel_char="F";
                5: panel_char="O";
                6: panel_char="U";
                7: panel_char="N";
                8: panel_char="D";
                10: panel_char="T";
                11: panel_char="R";
                12: panel_char="I";
                default: panel_char=" ";
            endcase
        end
    endfunction

    function automatic [7:0] follow_char(input integer column);
        begin
            case (column)
                0: follow_char="1";
                2: follow_char="B";
                3: follow_char="L";
                4: follow_char="U";
                6: follow_char="T";
                7: follow_char="R";
                8: follow_char="I";
                10: follow_char="H";
                default: follow_char=" ";
            endcase
        end
    endfunction

    always @(*) begin
        ref_char=8'h20;
        ref_row=0;
        ref_col=0;
        if (dut.S_target_panel_on) begin
            ref_char=panel_char(dut.S_target_char_index);
            ref_row=dut.S_target_text_y;
            ref_col=dut.S_target_text_x[3:0];
        end else if (dut.S_follow_panel_on) begin
            ref_char=follow_char((dut.S_x_2d-dut.multi_target.label_x[0])/16);
            ref_row=dut.S_follow_row;
            ref_col=dut.S_follow_col;
        end
    end

    task automatic blank(input integer cycles);
        begin
            @(negedge clk);
            de=0; user=0; last=0; rgb=0; hs=1;
            repeat (cycles) @(negedge clk);
            hs=0;
        end
    endtask

    always @(posedge clk) begin : check_pixels
        integer x,y,follow_column,panel_column;
        bit box_on,font_on,sample_box,sample_panel,sample_follow;
        reg [23:0] expected_rgb;
        reg [7:0] expected_char,sample_panel_char,sample_follow_char;
        x=dut.S_x_2d;
        y=dut.S_y_2d;
        sample_box=dut.S_multi_box_on;
        sample_panel=dut.S_target_panel_on;
        sample_follow=dut.S_follow_panel_on;
        sample_panel_char=dut.S_target_char;
        sample_follow_char=dut.S_follow_char;
        panel_column=dut.S_target_char_index;
        follow_column=(x-dut.multi_target.label_x[0])/16;
        font_on=ref_bits[15-ref_col];
        #1;
        if (rst_n && out_de) begin
            if (x!=output_x || y!=output_y)
                $fatal(1,"single-slot coordinate mismatch expected=%0d,%0d got=%0d,%0d",
                    output_x,output_y,x,y);
            if ($bits(dut.multi_target.valid)!=1 ||
                dut.multi_target.valid!==1'b1 ||
                dut.S_multi_count!==3'd1 ||
                dut.multi_target.overflow!==1'b0 ||
                dut.multi_target.shapes!==2'b10)
                $fatal(1,"single-slot state was not restricted to target zero");
            if (y>0 &&
                (dut.multi_target.label_valid!==1'b1 ||
                 dut.multi_target.label_compact!==1'b0 ||
                 dut.multi_target.label_x[0]!=180 ||
                 dut.multi_target.label_y[0]!=172))
                $fatal(1,"single following label placement changed");

            box_on=(x>=180 && x<=260 && y>=190 && y<=220 &&
                (x<182 || x>258 || y<192 || y>218));
            if (sample_box!==box_on)
                $fatal(1,"upper target lanes affected single-target box geometry");
            if (box_on) begin
                if (dut.S_multi_box_color!==24'hff3030 ||
                    out_rgb!==24'hff3030)
                    $fatal(1,"single target bounding box was not rendered at %0d,%0d",x,y);
                box_pixels=box_pixels+1;
            end

            if (sample_panel) begin
                expected_char=panel_char(panel_column);
                expected_rgb=font_on ? 24'hfff200 : 24'h101010;
                if (sample_panel_char!==expected_char || out_rgb!==expected_rgb)
                    $fatal(1,"single FOUND/shape panel mismatch at %0d,%0d char=%h expected=%h rgb=%h",
                        x,y,sample_panel_char,expected_char,out_rgb);
                panel_pixels=panel_pixels+1;
                if (panel_column>=10 && panel_column<=12) begin
                    panel_shape_pixels=panel_shape_pixels+1;
                    if (font_on) shape_glyphs=shape_glyphs+1;
                end
            end else if (sample_follow) begin
                expected_char=follow_char(follow_column);
                expected_rgb=font_on ? 24'hff3030 : 24'h101010;
                if (sample_follow_char!==expected_char || out_rgb!==expected_rgb ||
                    dut.S_follow_color!==24'hff3030)
                    $fatal(1,"single following label mismatch at %0d,%0d char=%h expected=%h rgb=%h",
                        x,y,sample_follow_char,expected_char,out_rgb);
                follow_pixels=follow_pixels+1;
                if (follow_column>=6 && follow_column<=8) begin
                    follow_shape_pixels=follow_shape_pixels+1;
                    if (font_on) shape_glyphs=shape_glyphs+1;
                end
            end

            pixels=pixels+1;
            if (output_x==W-1) begin
                output_x=0;
                if (output_y==H-1) begin
                    output_y=0;
                    output_frames=output_frames+1;
                end else output_y=output_y+1;
            end else output_x=output_x+1;
        end
    end

    initial begin
        multi_boxes[0 +: 48]={12'd220,12'd190,12'd260,12'd180};
        multi_boxes[48 +: 48]={12'd280,12'd240,12'd260,12'd180};
        multi_boxes[96 +: 48]={12'd300,12'd230,12'd560,12'd480};
        multi_boxes[144 +: 48]={12'd350,12'd290,12'd600,12'd540};
        blank(6);
        rst_n=1;
        for (integer yy=0; yy<H; yy=yy+1) begin
            for (integer xx=0; xx<W; xx=xx+1) begin
                @(negedge clk);
                de=1;
                user=(xx==0 && yy==0);
                last=(xx==W-1);
                rgb=24'h123456;
            end
            blank(8);
        end
        blank(12);
        if (output_frames!=1 || pixels!=W*H ||
            follow_pixels!=192*16 || follow_shape_pixels!=3*16*16 ||
            panel_pixels!=240*16 || panel_shape_pixels!=3*16*16 ||
            box_pixels==0 || shape_glyphs==0)
            $fatal(1,"single-slot mixer coverage incomplete frames=%0d pixels=%0d follow=%0d follow_shape=%0d panel=%0d panel_shape=%0d box=%0d glyphs=%0d",
                output_frames,pixels,follow_pixels,follow_shape_pixels,
                panel_pixels,panel_shape_pixels,box_pixels,shape_glyphs);
        $display("SINGLE_TARGET_MIXER_PASS frames=%0d pixels=%0d follow=%0d shape_follow=%0d panel=%0d shape_panel=%0d box=%0d glyphs=%0d",
            output_frames,pixels,follow_pixels,follow_shape_pixels,
            panel_pixels,panel_shape_pixels,box_pixels,shape_glyphs);
        $finish;
    end

    initial begin
        #30000000;
        $fatal(1,"Single-target mixer test timed out");
    end
endmodule
