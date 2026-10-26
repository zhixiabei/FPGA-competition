`timescale 1ns/1ps
// The expected label locations below are fixed examples of the placement
// contract, rather than results read back from the DUT layout engine.
module tb_multi_target_mixer;
    localparam integer W=640, H=360, FRAMES=12;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, de=0, user=0, last=0, hs=0, vs=0;
    reg [23:0] rgb=0;
    reg [3:0] effect_mode=2;
    reg ready=0, found=0, motion=0, overflow=0;
    reg [1:0] color_mode=0;
    reg [3:0] multi_valid=0, multi_hold=0;
    reg [191:0] multi_boxes=0;
    reg [7:0] multi_shapes=0, ref_shapes=0;
    reg [11:0] tx0=0,tx1=0,ty0=0,ty1=0,tcx=0,tcy=0;
    wire rd, out_de, out_hs, out_vs;
    wire [23:0] out_rgb;

    reg [3:0] ref_valid=0, ref_hold=0, ref_label_valid=0, ref_compact=0;
    reg ref_motion=0, ref_overflow=0;
    reg [1:0] ref_color=0;
    integer bx0[0:3], bx1[0:3], by0[0:3], by1[0:3];
    integer lx[0:3], ly[0:3];
    integer ref_cx=0, ref_cy=0;
    integer output_frame=0, output_x=0, output_y=0, pixels=0;
    integer box_pixels[0:3], glyph_pixels[0:3];
    integer cross_pixels=0, fixed_priority_pixels=0, compact_pixels=0;
    integer label_checks=0, frame_checks=0, preview_four, preview_crowded;
    reg pipe_de[0:2], pipe_hs[0:2], pipe_vs[0:2];
    reg [23:0] pipe_rgb[0:2];
    reg [7:0] ref_char;
    reg [3:0] ref_row, ref_col;
    wire [15:0] ref_bits;
    reg ref_label_hit;
    integer ref_label_slot, ref_lx, ref_ly;
    reg [7:0] ref_counter_char;
    reg [3:0] ref_counter_row, ref_counter_col;
    reg ref_counter_panel, ref_counter_valid;
    wire [15:0] ref_counter_bits;
    integer counter_checks=0;

    hdmi_mixer #(.IMG_WIDTH(W),.IMG_HEIGHT(H),.MULTI_TARGET_ENABLE(1),
        .SHOW_COLOR_TARGET(1),.SHOW_CAMERA_STATUS(1),.SHOW_EFFECT_LABEL(1)) dut (
        .I_clk(clk),.I_rst_n(rst_n),.I_video_de(de),
        .I_video_user(user),.I_video_last(last),
        .I_video_hsync(hs),.I_video_vsync(vs),
        .I_effect_mode(effect_mode),.I_effect_param(8'd0),
        .I_debug_status(4'b1111),.I_cam_fail_index(8'd0),
        .I_raw_stats_valid(1'b0),.I_raw_stats_data(45'd0),
        .I_ae_readout_valid(1'b0),.I_ae_readout_data(28'd0),
        .I_latency_sample_strobe(1'b0),.I_latency_sample_valid(1'b0),
        .I_latency_total_us(20'd0),.I_latency_isp_us(20'd0),
        .I_latency_buffer_us(20'd0),.I_video_rd_data(rgb),
        .O_video_rd_en(rd),.O_display_frame_start(),
        .I_target_result_ready(ready),.I_target_found(found),
        .I_target_motion_mode(motion),.I_target_color_mode(color_mode),
        .I_target_xmin(tx0),.I_target_xmax(tx1),
        .I_target_ymin(ty0),.I_target_ymax(ty1),
        .I_target_center_x(tcx),.I_target_center_y(tcy),
        .I_target_multi_valid(multi_valid),.I_target_multi_hold(multi_hold),
        .I_target_multi_boxes(multi_boxes),.I_target_multi_overflow(overflow),
        .I_target_multi_shapes(multi_shapes),
        .O_hdmi_de(out_de),.O_hdmi_hsync(out_hs),
        .O_hdmi_vsync(out_vs),.O_hdmi_data(out_rgb)
    );
    osd_char_lib reference_font (
        .I_char(ref_char),.I_row(ref_row),.O_row_bits(ref_bits)
    );
    osd_char_lib reference_counter_font (
        .I_char(ref_counter_char),.I_row(ref_counter_row),
        .O_row_bits(ref_counter_bits)
    );

    function automatic [23:0] slot_color(input integer slot);
        case (slot)
            0: slot_color=24'hff3030;
            1: slot_color=24'h00e6ff;
            2: slot_color=24'hfff200;
            default: slot_color=24'h40ff70;
        endcase
    endfunction
    function automatic [7:0] shape_char(input integer slot, column);
        reg [23:0] name;
        begin
            case (ref_shapes[2*slot+:2])
                1: name="SQR";
                2: name="TRI";
                3: name="CIR";
                default: name="UNK";
            endcase
            shape_char=name[23-8*column-:8];
        end
    endfunction
    function automatic integer abs_value(input integer value);
        abs_value=(value<0) ? -value : value;
    endfunction
    function automatic integer target_count(input [3:0] mask);
        target_count=integer'(mask[0])+integer'(mask[1])+
                     integer'(mask[2])+integer'(mask[3]);
    endfunction
    function automatic [7:0] target_mode_char(input integer column);
        begin
            target_mode_char=" ";
            if (ref_motion) begin
                case (column)
                    0: target_mode_char="M";
                    1: target_mode_char="O";
                    2: target_mode_char="V";
                endcase
            end else begin
                case (ref_color)
                    1: case (column)
                        0: target_mode_char="G";
                        1: target_mode_char="R";
                        2: target_mode_char="N";
                    endcase
                    2: case (column)
                        0: target_mode_char="B";
                        1: target_mode_char="L";
                        2: target_mode_char="U";
                    endcase
                    default: case (column)
                        0: target_mode_char="R";
                        1: target_mode_char="E";
                        2: target_mode_char="D";
                    endcase
                endcase
            end
        end
    endfunction
    function automatic [23:0] camera_pixel(input integer f, xx, yy);
        camera_pixel={8'((xx+f*11)%256),8'((yy*3+31)%256),
                      8'((xx+yy+83)%256)};
    endfunction
    function automatic [7:0] following_char(input integer slot, column);
        begin
            following_char=" ";
            if (column==0) following_char="1"+slot;
            if (ref_motion && ref_compact[slot]) begin
                if (column==2) following_char=ref_hold[slot] ? "H" : "O";
                if (column==3) following_char=ref_hold[slot] ? " " : "K";
            end else if (ref_motion) begin
                if (column>=2 && column<=4)
                    following_char=target_mode_char(column-2);
                if (column==6) following_char=ref_hold[slot] ? "H" : "O";
                if (column==7) following_char=ref_hold[slot] ? " " : "K";
            end else if (ref_compact[slot]) begin
                if (column>=2 && column<=4)
                    following_char=shape_char(slot,column-2);
                if (column==6) following_char=ref_hold[slot] ? "H" : "O";
                if (column==7) following_char=ref_hold[slot] ? " " : "K";
            end else begin
                if (column>=2 && column<=4)
                    following_char=target_mode_char(column-2);
                if (column>=6 && column<=8)
                    following_char=shape_char(slot,column-6);
                if (column==10) following_char=ref_hold[slot] ? "H" : "O";
                if (column==11) following_char=ref_hold[slot] ? " " : "K";
            end
        end
    endfunction
    function automatic [7:0] panel_char(input integer column);
        begin
            panel_char=" ";
            case (column)
                0,1,2: panel_char=target_mode_char(column);
                4: panel_char="C";
                5: panel_char="O";
                6: panel_char="U";
                7: panel_char="N";
                8: panel_char="T";
                9: panel_char=":";
                10: panel_char="0"+target_count(ref_valid);
                12: panel_char=ref_overflow ? "O" : " ";
                13: panel_char=ref_overflow ? "V" : " ";
                14: panel_char=ref_overflow ? "F" : " ";
                default: panel_char=" ";
            endcase
        end
    endfunction
    function automatic [7:0] effect_char(input integer column);
        reg [119:0] title;
        begin
            title="02 SCHARR EDGE ";
            effect_char=(column>=0 && column<15) ?
                title[119-8*column -:8] : " ";
        end
    endfunction

    always @(*) begin: reference_text
        integer xx, yy, slot;
        xx=dut.S_x_2d; yy=dut.S_y_2d;
        ref_label_hit=0; ref_label_slot=0; ref_lx=0; ref_ly=0;
        for (slot=3;slot>=0;slot=slot-1) begin
            if (ref_label_valid[slot] && xx>=lx[slot] &&
                xx<lx[slot]+(ref_motion ?
                    (ref_compact[slot] ? 64 : 128) :
                    (ref_compact[slot] ? 128 : 192)) &&
                yy>=ly[slot] && yy<ly[slot]+16) begin
                ref_label_hit=1; ref_label_slot=slot;
                ref_lx=xx-lx[slot]; ref_ly=yy-ly[slot];
            end
        end
        ref_char=following_char(ref_label_slot,ref_lx/16);
        ref_row=ref_ly; ref_col=ref_lx;
        if (xx>=16 && xx<256 && yy>=H-32 && yy<H-16) begin
            ref_char=panel_char((xx-16)/16);
            ref_row=yy-(H-32); ref_col=xx-16;
        end
        if (xx>=192 && xx<432 && yy>=80 && yy<96) begin
            ref_char=effect_char((xx-192)/16);
            ref_row=yy-80; ref_col=xx-192;
        end
    end

    // Independent coordinates and arithmetic preserve the original enlarged
    // Chinese prefix and six decimal digits across the timing pipeline.
    always @(*) begin: reference_counter
        integer dx, dy, digit_column, place_value;
        dx=dut.S_x_2d-375; dy=dut.S_y_2d-120;
        ref_counter_char=0; ref_counter_row=0; ref_counter_col=0;
        ref_counter_panel=dx>=0 && dx<200 && dy>=0 && dy<24;
        ref_counter_valid=0;
        digit_column=0; place_value=1;
        if (ref_counter_panel) begin
            if (dx<48 && dy>=2) begin
                ref_counter_char=dx<24 ? 8'h80 : 8'h81;
                ref_counter_col=((dx%24)*16)/24;
                ref_counter_row=((dy-2)*16)/24;
                ref_counter_valid=1;
            end else if (dx>=52 && dx<100 && dy>=4 && dy<20) begin
                ref_counter_char=dx<68 ? "C" : dx<84 ? "N" : "T";
                ref_counter_col=(dx-52)%16; ref_counter_row=dy-4;
                ref_counter_valid=1;
            end else if (dx>=100 && dx<108 && dy>=4 && dy<20) begin
                ref_counter_char=":";
                ref_counter_col=(dx-100)*2; ref_counter_row=dy-4;
                ref_counter_valid=1;
            end else if (dx>=110) begin
                digit_column=(dx-110)/15;
                for (integer place=0;place<5;place=place+1)
                    if (place<5-digit_column) place_value=place_value*10;
                ref_counter_char="0"+((output_frame+1)/place_value)%10;
                ref_counter_col=(dx-110)%15; ref_counter_row=(dy*16)/24;
                ref_counter_valid=1;
            end
        end
    end

    always @(posedge clk) begin: verify
        integer xx, yy, box_slot;
        bit sample_osd, sample_label, sample_glyph, sample_follow_panel;
        bit camera_on, effect_on, panel_on, box_on, cross_on;
        reg [23:0] sample_osd_rgb, expected_rgb, sample_native;
        reg [7:0] sample_char, sample_follow_char;
        integer sample_label_slot;
        bit sample_counter_panel, sample_counter_glyph;
        if (!rst_n) begin
            for (integer p=0;p<3;p=p+1) begin
                pipe_de[p]=0; pipe_hs[p]=0; pipe_vs[p]=0; pipe_rgb[p]=0;
            end
        end else begin
            xx=dut.S_x_2d; yy=dut.S_y_2d;
            sample_osd=dut.S_osd_hit; sample_osd_rgb=dut.S_osd_color;
            sample_native=dut.S_video_data_2d;
            sample_label=ref_label_hit;
            sample_label_slot=ref_label_slot;
            sample_glyph=ref_bits[15-ref_col];
            sample_char=ref_char;
            sample_follow_panel=dut.S_follow_panel_on;
            sample_follow_char=dut.S_follow_char;
            sample_counter_panel=ref_counter_panel;
            sample_counter_glyph=ref_counter_valid &&
                ref_counter_bits[15-ref_counter_col];
            for (integer p=2;p>0;p=p-1) begin
                pipe_de[p]=pipe_de[p-1]; pipe_hs[p]=pipe_hs[p-1];
                pipe_vs[p]=pipe_vs[p-1]; pipe_rgb[p]=pipe_rgb[p-1];
            end
            pipe_de[0]=de; pipe_hs[0]=hs; pipe_vs[0]=vs; pipe_rgb[0]=rgb;
            #1;
            if (rd!==de || out_de!==pipe_de[2] ||
                out_hs!==pipe_hs[2] || out_vs!==pipe_vs[2])
                $fatal(1,"Three-cycle mixer sync/read enable mismatch");
            if (out_de) begin
                if (xx!=output_x || yy!=output_y)
                    $fatal(1,"Pixel coordinate mismatch frame=%0d expected=%0d,%0d got=%0d,%0d",
                        output_frame,output_x,output_y,xx,yy);
                if (sample_native!==camera_pixel(output_frame,xx,yy) ||
                    sample_native!==pipe_rgb[2])
                    $fatal(1,"Two-cycle effect data changed or shifted");
                if (sample_counter_panel) begin
                    if (sample_osd!==sample_counter_glyph ||
                        (sample_osd && sample_osd_rgb!==24'hfff200))
                        $fatal(1,"Original counter glyph changed frame=%0d at %0d,%0d",
                            output_frame,xx,yy);
                    counter_checks=counter_checks+1;
                end
                if (dut.multi_target.valid!==ref_valid ||
                    dut.multi_target.held!==ref_hold ||
                    dut.multi_target.shapes!==ref_shapes ||
                    dut.S_target_motion_mode!==ref_motion ||
                    dut.S_target_color_mode!==ref_color ||
                    dut.S_multi_count!==3'(target_count(ref_valid)) ||
                    dut.S_multi_overflow!==ref_overflow)
                    $fatal(1,"Metadata changed inside frame=%0d x=%0d y=%0d",
                        output_frame,xx,yy);
                for (integer slot=0;slot<4;slot=slot+1)
                    if (ref_valid[slot] &&
                        (dut.multi_target.xmin[slot]!=bx0[slot] ||
                         dut.multi_target.xmax[slot]!=bx1[slot] ||
                         dut.multi_target.ymin[slot]!=by0[slot] ||
                         dut.multi_target.ymax[slot]!=by1[slot]))
                        $fatal(1,"Latched or clipped geometry mismatch slot=%0d frame=%0d",
                            slot,output_frame);
                if (yy==0 && xx==W-1) begin
                    if (dut.multi_target.layout_busy)
                        $fatal(1,"Label layout did not finish in scan row zero");
                    frame_checks=frame_checks+1;
                end
                if (yy>=16) begin
                    if (dut.multi_target.label_valid!==ref_label_valid ||
                        dut.multi_target.label_compact!==ref_compact)
                        $fatal(1,"Label visibility/compact mismatch frame=%0d got=%b/%b expected=%b/%b",
                            output_frame,dut.multi_target.label_valid,
                            dut.multi_target.label_compact,ref_label_valid,ref_compact);
                    for (integer slot=0;slot<4;slot=slot+1)
                        if (ref_label_valid[slot] &&
                            (dut.multi_target.label_x[slot]!=lx[slot] ||
                             dut.multi_target.label_y[slot]!=ly[slot]))
                            $fatal(1,"Following label placement mismatch frame=%0d slot=%0d got=%0d,%0d expected=%0d,%0d",
                                output_frame,slot,dut.multi_target.label_x[slot],
                                dut.multi_target.label_y[slot],lx[slot],ly[slot]);
                    label_checks=label_checks+1;
                end
                if (sample_follow_panel!==sample_label ||
                    (sample_label && sample_follow_char!==sample_char))
                    $fatal(1,"Following ID/status character mismatch frame=%0d x=%0d y=%0d",
                        output_frame,xx,yy);
                // Use the old overlay's hit/color as a preservation oracle;
                // all new geometry and text above have independent references.
                camera_on=yy>=16 && yy<32 &&
                    ((xx>=192 && xx<208) || (xx>=216 && xx<232) ||
                     (xx>=240 && xx<256) || (xx>=264 && xx<280));
                effect_on=xx>=192 && xx<432 && yy>=80 && yy<96;
                panel_on=xx>=16 && xx<256 && yy>=H-32 && yy<H-16;
                box_on=0; box_slot=0;
                for (integer slot=3;slot>=0;slot=slot-1) begin
                    if (ref_valid[slot] && xx>=bx0[slot] && xx<=bx1[slot] &&
                        yy>=by0[slot] && yy<=by1[slot] &&
                        (xx-bx0[slot]<2 || bx1[slot]-xx<2 ||
                         yy-by0[slot]<2 || by1[slot]-yy<2)) begin
                        box_on=1; box_slot=slot;
                    end
                end
                cross_on=ref_motion && ref_valid[0] &&
                    ((abs_value(xx-ref_cx)<=1 && abs_value(yy-ref_cy)<=6) ||
                     (abs_value(yy-ref_cy)<=1 && abs_value(xx-ref_cx)<=6));
                if (camera_on) expected_rgb=24'h00ff00;
                else if (effect_on) expected_rgb=sample_glyph ? 24'h00e6ff : 24'h101010;
                else if (sample_osd) expected_rgb=sample_osd_rgb;
                else if (panel_on) expected_rgb=sample_glyph ? 24'hfff200 : 24'h101010;
                else if (sample_label)
                    expected_rgb=sample_glyph ? slot_color(sample_label_slot) : 24'h101010;
                else if (box_on) expected_rgb=slot_color(box_slot);
                else if (cross_on) expected_rgb=24'hfff200;
                else expected_rgb=sample_native;
                if (out_rgb!==expected_rgb)
                    $fatal(1,"Pixel mismatch frame=%0d at %0d,%0d got=%h expected=%h char=%h label=%0d box=%0d",
                        output_frame,xx,yy,out_rgb,expected_rgb,sample_char,sample_label,box_on);
                if (box_on && (camera_on || effect_on || sample_osd || panel_on))
                    fixed_priority_pixels=fixed_priority_pixels+1;
                if (sample_label && !sample_osd && !panel_on && !effect_on && !camera_on) begin
                    if (sample_glyph) begin
                        glyph_pixels[sample_label_slot]=glyph_pixels[sample_label_slot]+1;
                        if (ref_compact[sample_label_slot]) compact_pixels=compact_pixels+1;
                    end
                end else if (box_on && !camera_on && !effect_on && !sample_osd && !panel_on)
                    box_pixels[box_slot]=box_pixels[box_slot]+1;
                else if (cross_on) cross_pixels=cross_pixels+1;
                if (output_frame==1)
                    $fwrite(preview_four,"%c%c%c",out_rgb[23:16],out_rgb[15:8],out_rgb[7:0]);
                if (output_frame==7)
                    $fwrite(preview_crowded,"%c%c%c",out_rgb[23:16],out_rgb[15:8],out_rgb[7:0]);
                pixels=pixels+1;
                if (output_x==W-1) begin
                    output_x=0;
                    if (output_y==H-1) begin output_y=0; output_frame=output_frame+1; end
                    else output_y=output_y+1;
                end else output_x=output_x+1;
            end
        end
    end

    task automatic set_box(input integer slot,x0,x1,y0,y1);
        begin
            multi_boxes[slot*48+:48]={12'(y1),12'(y0),12'(x1),12'(x0)};
            bx0[slot]=x0; bx1[slot]=(x1>=W) ? W-1 : x1;
            by0[slot]=y0; by1[slot]=(y1>=H) ? H-1 : y1;
        end
    endtask
    task automatic set_label(input integer slot,x0,y0,compact);
        begin
            ref_label_valid[slot]=1; ref_compact[slot]=compact;
            lx[slot]=x0; ly[slot]=y0;
        end
    endtask
    task automatic configure_frame(input integer f);
        begin
            ready=1; found=1; motion=0; color_mode=0; overflow=0; effect_mode=2;
            multi_valid=15; multi_hold=0; multi_boxes=0;
            multi_shapes=8'b00_11_10_01; ref_shapes=multi_shapes;
            tx0=320; tx1=450; ty0=200; ty1=300; tcx=385; tcy=250;
            ref_valid=15; ref_hold=0; ref_motion=0; ref_color=0; ref_overflow=0;
            ref_label_valid=0; ref_compact=0; ref_cx=385; ref_cy=250;
            for (integer slot=0;slot<4;slot=slot+1) begin
                set_box(slot,0,0,0,0); lx[slot]=0; ly[slot]=0;
            end
            case (f)
                0,9: begin ready=0; ref_valid=0; end
                1: begin
                    set_box(0,180,260,190,220); set_label(0,180,172,0);
                    set_box(1,430,520,190,220); set_label(1,430,172,0);
                    set_box(2,180,260,280,310); set_label(2,180,262,0);
                    set_box(3,430,520,280,310); set_label(3,430,262,0);
                end
                2: begin
                    color_mode=1; ref_color=1;
                    multi_hold=10; ref_hold=10; overflow=1; ref_overflow=1;
                    set_box(0,200,270,210,240); set_label(0,200,192,0);
                    set_box(1,450,530,210,240); set_label(1,448,192,0);
                    set_box(2,200,270,300,320); set_label(2,200,282,0);
                    set_box(3,450,530,300,320); set_label(3,448,282,0);
                end
                3: begin
                    color_mode=2; ref_color=2;
                    set_box(0,290,350,0,20); set_label(0,290,23,0);
                    set_box(1,620,700,0,20); set_label(1,512,23,1);
                    set_box(2,0,20,340,500);
                    set_box(3,620,999,340,999); set_label(3,448,322,0);
                end
                4: begin
                    ref_valid=0;
                    set_box(0,700,800,200,240);
                    set_box(1,300,250,200,240);
                    set_box(2,300,350,400,450);
                    set_box(3,300,350,300,250);
                end
                5: begin
                    motion=1; ref_motion=1; ref_valid=1;
                    ref_shapes=0;
                    overflow=1; multi_hold=15;
                    set_box(0,320,450,200,300); set_label(0,320,182,0);
                end
                6: begin
                    motion=1; ref_motion=1; found=0; ref_valid=0;
                    ref_shapes=0;
                    multi_hold=15; overflow=1;
                end
                7: begin
                    color_mode=1; ref_color=1;
                    multi_hold=2; ref_hold=2;
                    for (integer slot=0;slot<4;slot=slot+1)
                        set_box(slot,512,512,110,110);
                    set_label(0,448,92,0);
                end
                8: begin
                    set_box(0,0,639,0,359); set_label(0,448,341,0);
                    set_box(1,192,431,16,95); set_label(1,192,98,0);
                    set_box(2,375,574,120,143); set_label(2,375,146,0);
                    set_box(3,16,255,328,343); set_label(3,16,310,0);
                end
                10: begin
                    multi_valid=1; ref_valid=1;
                    // A legacy instance with an unconnected shape field
                    // must display UNK using deterministic glyphs.
                    multi_shapes[1:0]=2'bzz; ref_shapes=multi_shapes;
                    set_box(0,300,350,34,80); set_label(0,300,16,0);
                end
                11: begin
                    // Four point boxes wholly inside Logo exhaust all 32
                    // full/compact attempts each, checking the 128-cycle bound.
                end
                default: $fatal(1,"Unknown frame fixture");
            endcase
        end
    endtask
    task automatic blank(input integer cycles);
        begin
            @(negedge clk); de=0; user=0; last=0; rgb=0; hs=1;
            repeat(cycles) @(negedge clk);
            hs=0;
        end
    endtask

    initial begin
        for (integer slot=0;slot<4;slot=slot+1) begin
            bx0[slot]=0; bx1[slot]=0; by0[slot]=0; by1[slot]=0;
            lx[slot]=0; ly[slot]=0; box_pixels[slot]=0; glyph_pixels[slot]=0;
        end
        preview_four=$fopen("multi_target_four_preview.ppm","wb");
        preview_crowded=$fopen("multi_target_crowded_preview.ppm","wb");
        if (!preview_four || !preview_crowded) $fatal(1,"Cannot open previews");
        $fwrite(preview_four,"P6\n640 360\n255\n");
        $fwrite(preview_crowded,"P6\n640 360\n255\n");
        blank(6); rst_n=1;
        for (integer f=0;f<FRAMES;f=f+1) begin
            configure_frame(f);
            for (integer yy=0;yy<H;yy=yy+1) begin
                for (integer xx=0;xx<W;xx=xx+1) begin
                    @(negedge clk);
                    de=1; user=(xx==0 && yy==0); last=(xx==W-1);
                    rgb=camera_pixel(f,xx,yy);
                    if (f==1 && yy==100 && xx==300) begin
                        // No result/configuration input may tear this frame.
                        ready=0; found=0; motion=1; multi_valid=0;
                        color_mode=2;
                        multi_hold=15; multi_boxes={192{1'b1}}; overflow=1;
                        multi_shapes=8'hff;
                        tx0=4095; tx1=4095; ty0=4095; ty1=4095;
                        tcx=4095; tcy=4095; effect_mode=3;
                    end
                end
                blank(8);
            end
            vs=1; blank(16); vs=0;
        end
        blank(12);
        $fclose(preview_four); $fclose(preview_crowded);
        if (output_frame!=FRAMES || pixels!=FRAMES*W*H || frame_checks!=FRAMES ||
            cross_pixels==0 || fixed_priority_pixels==0 || compact_pixels==0 ||
            label_checks==0 || counter_checks!=FRAMES*200*24)
            $fatal(1,"Incomplete multi-target coverage");
        for (integer slot=0;slot<4;slot=slot+1)
            if (box_pixels[slot]==0 || glyph_pixels[slot]==0)
                $fatal(1,"Slot %0d color/ID was not rendered",slot);
        $display("MULTI_TARGET_MIXER_PASS frames=%0d pixels=%0d labels=%0d compact=%0d cross=%0d fixed_priority=%0d counter=%0d",
            output_frame,pixels,label_checks,compact_pixels,cross_pixels,
            fixed_priority_pixels,counter_checks);
        $finish;
    end
    initial begin #45000000; $fatal(1,"Multi-target mixer timeout"); end
endmodule
