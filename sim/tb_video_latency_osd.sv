`timescale 1ns/1ps
module tb_video_latency_osd;
    localparam W=1280, H=720, PX=864, PY=16;
    reg clk=0;
    always #5 clk=~clk;
    reg unit_rst=0, unit_de=0, unit_strobe=0, unit_valid=0;
    reg [11:0] unit_x=0, unit_y=0;
    reg [19:0] unit_total=0, unit_isp=0, unit_buffer=0;
    wire unit_panel, unit_text, unit_graph, unit_alert;
    video_latency_osd unit_dut(
        .I_clk(clk),.I_rst_n(unit_rst),.I_sample_strobe(unit_strobe),
        .I_sample_valid(unit_valid),.I_total_us(unit_total),.I_isp_us(unit_isp),
        .I_buffer_us(unit_buffer),.I_de(unit_de),.I_x(unit_x),.I_y(unit_y),
        .O_panel(unit_panel),.O_text(unit_text),.O_graph(unit_graph),.O_alert(unit_alert));

    reg mix_rst=0, de=0, user=0, last=0, hs=0, vs=0, mix_strobe=0, mix_valid=0;
    reg [19:0] mix_total=0, mix_isp=0, mix_buffer=0;
    reg [23:0] camera_rgb=0;
    wire out_de, out_hs, out_vs, rd, frame_start;
    wire [23:0] out_rgb;
    hdmi_mixer #(.IMG_WIDTH(W),.IMG_HEIGHT(H),.SHOW_LATENCY(1),
        .SHOW_CAMERA_STATUS(1),.SHOW_COLOR_TARGET(1)) mixer(
        .I_clk(clk),.I_rst_n(mix_rst),.I_video_de(de),.I_video_user(user),
        .I_video_last(last),.I_video_hsync(hs),.I_video_vsync(vs),
        .I_debug_status(4'b1111),.I_cam_fail_index(8'd0),
        .I_raw_stats_valid(1'b0),.I_raw_stats_data(45'd0),
        .I_ae_readout_valid(1'b0),.I_ae_readout_data(28'd0),
        .I_latency_sample_strobe(mix_strobe),.I_latency_sample_valid(mix_valid),
        .I_latency_total_us(mix_total),.I_latency_isp_us(mix_isp),
        .I_latency_buffer_us(mix_buffer),.O_display_frame_start(frame_start),
        .O_video_rd_en(rd),.I_video_rd_data(camera_rgb),
        .I_target_result_ready(1'b1),.I_target_found(1'b1),.I_target_motion_mode(1'b1),
        .I_target_xmin(12'd500),.I_target_xmax(12'd700),
        .I_target_ymin(12'd300),.I_target_ymax(12'd450),
        .I_target_center_x(12'd600),.I_target_center_y(12'd375),
        .O_hdmi_de(out_de),.O_hdmi_hsync(out_hs),.O_hdmi_vsync(out_vs),.O_hdmi_data(out_rgb));

    integer reference_history[0:63];
    bit reference_valid[0:63];
    integer reference_head=0, reference_count=0;
    integer reference_total=0, reference_isp=0, reference_buffer=0;
    integer reference_min=0, reference_max=0;
    bit reference_current_valid=0, reference_have_valid=0;
    reg [7:0] reference_character=" ";
    reg [3:0] reference_row=0;
    wire [15:0] reference_glyph;
    osd_char_lib reference_font(.I_char(reference_character),.I_row(reference_row),
        .O_row_bits(reference_glyph));
    integer assertions=0, checked_pixels=0, unit_glyphs=0, unit_points=0, unit_alerts=0;
    integer mixer_pixels=0, mixer_frames=0, mixer_x=0, mixer_y=0;
    integer frame_events=0, mixer_glyphs=0, mixer_points=0, target_pixels=0, original_osd_pixels=0;
    integer history_preview, nominal_preview, overflow_preview, invalid_preview;

    task automatic check(input bit condition, input string message_text);
        begin
            if (!condition) $fatal(1,"%s",message_text);
            assertions=assertions+1;
        end
    endtask

    task automatic clear_reference;
        begin
            reference_head=0; reference_count=0; reference_total=0; reference_isp=0;
            reference_buffer=0; reference_min=0; reference_max=0;
            reference_current_valid=0; reference_have_valid=0;
            for(integer i=0;i<64;i=i+1) begin reference_history[i]=0; reference_valid[i]=0; end
        end
    endtask

    task automatic accept_reference(input bit valid_sample, input integer total_us,isp_us,buffer_us);
        begin
            reference_history[reference_head]=total_us;
            reference_valid[reference_head]=valid_sample;
            reference_head=(reference_head+1)%64;
            if(reference_count<64) reference_count=reference_count+1;
            reference_total=total_us; reference_isp=isp_us; reference_buffer=buffer_us;
            reference_current_valid=valid_sample;
            if(valid_sample) begin
                if(!reference_have_valid || total_us<reference_min) reference_min=total_us;
                if(!reference_have_valid || total_us>reference_max) reference_max=total_us;
                reference_have_valid=1;
            end
        end
    endtask

    function automatic [23:0] decimal_bcd(input integer number);
        integer value;
        begin
            value=number>999999 ? 999999 : number;
            decimal_bcd={4'((value/100000)%10),4'((value/10000)%10),
                4'((value/1000)%10),4'((value/100)%10),4'((value/10)%10),4'(value%10)};
        end
    endfunction

    function automatic [7:0] expected_character(input integer row,col);
        string line_text;
        integer a,b;
        begin
            a=reference_total>999999 ? 999999 : reference_total;
            case(row)
                0: line_text=reference_current_valid ?
                    $sformatf("TOTAL:%03d.%03d MS",a/1000,a%1000) : "TOTAL:N/A     MS";
                1: begin
                    a=reference_isp>999999 ? 999999 : reference_isp;
                    line_text=reference_current_valid ?
                        $sformatf("ISP:  %03d.%03d MS",a/1000,a%1000) : "ISP:  N/A     MS";
                end
                2: begin
                    a=reference_buffer>999999 ? 999999 : reference_buffer;
                    line_text=reference_current_valid ?
                        $sformatf("BUF:  %03d.%03d MS",a/1000,a%1000) : "BUF:  N/A     MS";
                end
                default: begin
                    a=reference_min>999999 ? 999999 : reference_min;
                    b=reference_max>999999 ? 999999 : reference_max;
                    line_text=reference_have_valid ?
                        $sformatf("MIN:%03d.%03d MAX:%03d.%03d",a/1000,a%1000,b/1000,b%1000) :
                        "MIN:N/A     MAX:N/A    ";
                end
            endcase
            expected_character=col<line_text.len() ? line_text[col] : " ";
        end
    endfunction

    // Software reference uses integer arithmetic independently of the shared
    // BCD datapath and circular memory addressing in the hardware.
    task automatic expected_masks(input integer x,y, input bit enabled, output reg [3:0] masks);
        integer px,py,col,row,slot,address,previous,height,current_ms,previous_ms;
        bit panel,text_area,scale_area,graph_area,point,connector,axes,glyph_on,numeric;
        begin
            masks=0; px=x-PX; py=y-PY;
            panel=enabled && px>=0 && px<400 && py>=0 && py<216;
            text_area=panel && px>=8 && px<392 && py>=4 && py<68;
            scale_area=panel && px>=8 && px<104 &&
                ((py>=72 && py<88) || (py>=136 && py<152) || (py>=200 && py<216));
            reference_character=" "; reference_row=0; col=0; row=0; numeric=0;
            if(text_area) begin
                col=(px-8)/16; row=(py-4)/16;
                reference_character=expected_character(row,col);
                reference_row=(py-4)%16;
                numeric=(row<3 && col>=6 && col<=12) ||
                    (row==3 && ((col>=4 && col<=10) || (col>=16 && col<=22)));
            end else if(scale_area) begin
                col=(px-8)/16;
                if(py<88) begin
                    case(col) 0:reference_character="1";1:reference_character="2";
                        2:reference_character="8";3:reference_character="M";4:reference_character="S";
                        default:reference_character=" ";endcase
                    reference_row=py-72;
                end else if(py<152) begin
                    case(col) 1:reference_character="6";2:reference_character="4";
                        3:reference_character="M";4:reference_character="S";
                        default:reference_character=" ";endcase
                    reference_row=py-136;
                end else begin
                    case(col) 2:reference_character="0";3:reference_character="M";4:reference_character="S";
                        default:reference_character=" ";endcase
                    reference_row=py-200;
                end
            end
            #1;
            col=(px-8)%16;
            glyph_on=reference_character=="." ?
                ((reference_row==11 || reference_row==12) && (col==6 || col==7)) :
                reference_character=="/" ?
                (reference_row>=2 && reference_row<=11 && col==13-reference_row) :
                reference_glyph[15-col];
            graph_area=panel && px>=112 && px<368 && py>=80 && py<=208;
            slot=(px-112)/4; height=208-py;
            address=(reference_head+slot)%64; previous=(address+63)%64;
            point=0; connector=0; axes=0;
            if(graph_area) begin
                current_ms=reference_history[address]/1000;
                if(current_ms>128) current_ms=128;
                previous_ms=reference_history[previous]/1000;
                if(previous_ms>128) previous_ms=128;
                point=slot>=64-reference_count && reference_valid[address] && height==current_ms;
                connector=(px-112)%4==0 && slot>64-reference_count &&
                    reference_valid[address] && reference_valid[previous] &&
                    ((height>=current_ms && height<=previous_ms) ||
                     (height<=current_ms && height>=previous_ms));
                axes=(px==112 || py==208 || ((py==80 || py==144) && (px-112)%8==0));
            end
            masks[3]=panel;
            masks[2]=(text_area || scale_area) && glyph_on;
            masks[1]=point || connector || axes;
            masks[0]=((point || connector) && reference_history[address]>128000) ||
                (text_area && row==0 && numeric && reference_current_valid &&
                 (reference_total>128000 || reference_isp>999999 || reference_buffer>999999));
        end
    endtask

    function automatic [23:0] panel_color(input [3:0] masks);
        panel_color=masks[2] ? (masks[0] ? 24'hffb040 : 24'hffffff) :
            masks[1] ? (masks[0] ? 24'hff4040 : 24'h40e0a0) : 24'h101418;
    endfunction

    task automatic sample_unit(input bit valid_sample, input integer total_us,isp_us,buffer_us);
        begin
            @(negedge clk);
            unit_strobe=1; unit_valid=valid_sample; unit_total=total_us;
            unit_isp=isp_us; unit_buffer=buffer_us;
            accept_reference(valid_sample,total_us,isp_us,buffer_us);
            @(negedge clk); unit_strobe=0;
            repeat(105) @(negedge clk);
            check(unit_dut.history_count==reference_count && unit_dut.write_pointer==reference_head,
                "History count or wrap pointer mismatch");
            check(unit_dut.have_valid==reference_have_valid &&
                unit_dut.min_us==reference_min && unit_dut.max_us==reference_max,
                "Invalid input updated extrema or cumulative extrema were lost");
            check(unit_dut.display_valid==valid_sample,"Current validity mismatch");
            if(valid_sample) begin
                check(!unit_dut.busy,"Shared conversion did not finish in 100 cycles");
                check(unit_dut.bcd_total==decimal_bcd(total_us) &&
                    unit_dut.bcd_isp==decimal_bcd(isp_us) &&
                    unit_dut.bcd_buffer==decimal_bcd(buffer_us) &&
                    unit_dut.bcd_min==decimal_bcd(reference_min) &&
                    unit_dut.bcd_max==decimal_bcd(reference_max),"Decimal field conversion mismatch");
            end
        end
    endtask

    task automatic pixel_unit(input integer x,y, input bit enabled, input bit save_pixel);
        reg [3:0] expected;
        reg [23:0] rgb;
        begin
            @(negedge clk); unit_x=x; unit_y=y; unit_de=enabled;
            expected_masks(x,y,enabled,expected);
            @(posedge clk); #1;
            if({unit_panel,unit_text,unit_graph,unit_alert} !== expected)
                $fatal(1,"OSD pixel/pipeline mismatch at %0d,%0d actual=%b expected=%b",
                    x,y,{unit_panel,unit_text,unit_graph,unit_alert},expected);
            checked_pixels=checked_pixels+1;
            if(unit_text) unit_glyphs=unit_glyphs+1;
            if(unit_graph) unit_points=unit_points+1;
            if(unit_alert) unit_alerts=unit_alerts+1;
            if(save_pixel) begin
                rgb=unit_panel ? panel_color(expected) : 24'h405060;
                $fwrite(history_preview,"%c%c%c",rgb[23:16],rgb[15:8],rgb[7:0]);
            end
        end
    endtask

    always @(posedge clk) begin: check_mixer
        bit sample_de,sample_hs,sample_vs,sample_start,sample_osd,target_panel,target_text,box_on,cross_on;
        integer x,y;
        reg [23:0] native_rgb,osd_rgb,expected_rgb;
        reg [3:0] masks;
        if(mix_rst) begin
            sample_de=mixer.S_video_de_2d; sample_hs=mixer.S_video_hsync_2d;
            sample_vs=mixer.S_video_vsync_2d; sample_start=frame_start;
            x=mixer.S_x_2d; y=mixer.S_y_2d; native_rgb=mixer.S_video_data_2d;
            sample_osd=mixer.S_osd_hit; osd_rgb=mixer.S_osd_color;
            target_panel=mixer.S_target_panel_on; target_text=mixer.S_target_text_on;
            box_on=mixer.S_target_box_on; cross_on=mixer.S_target_cross_on;
            expected_masks(x,y,sample_de,masks);
            if(out_de!==sample_de || out_hs!==sample_hs || out_vs!==sample_vs || rd!==de)
                $fatal(1,"Latency overlay changed mixer sync/read timing");
            if(sample_start !== (sample_de && x==0 && y==0))
                $fatal(1,"Display frame-start pulse is not the final first-pixel event");
            if(sample_start) frame_events=frame_events+1;
            if(out_de) begin
                if(x!=mixer_x || y!=mixer_y) $fatal(1,"Mixer native coordinates shifted");
                if(masks[3]) expected_rgb=panel_color(masks);
                else if(y>=16 && y<32 && ((x>=192 && x<208) || (x>=216 && x<232) ||
                    (x>=240 && x<256) || (x>=264 && x<280))) expected_rgb=24'h00ff00;
                else if(sample_osd) begin expected_rgb=osd_rgb; original_osd_pixels=original_osd_pixels+1; end
                else if(target_panel) expected_rgb=target_text ? 24'hfff200 : 24'h101010;
                else if(box_on) begin expected_rgb=24'hff3030; target_pixels=target_pixels+1; end
                else if(cross_on) begin expected_rgb=24'hfff200; target_pixels=target_pixels+1; end
                else expected_rgb=native_rgb;
                if(out_rgb!==expected_rgb)
                    $fatal(1,"Mixer overlay mismatch frame=%0d at %0d,%0d got=%h expected=%h",
                        mixer_frames,x,y,out_rgb,expected_rgb);
                if(masks[2]) mixer_glyphs=mixer_glyphs+1;
                if(masks[1]) mixer_points=mixer_points+1;
                case(mixer_frames)
                    1: $fwrite(nominal_preview,"%c%c%c",out_rgb[23:16],out_rgb[15:8],out_rgb[7:0]);
                    2: $fwrite(overflow_preview,"%c%c%c",out_rgb[23:16],out_rgb[15:8],out_rgb[7:0]);
                    3: $fwrite(invalid_preview,"%c%c%c",out_rgb[23:16],out_rgb[15:8],out_rgb[7:0]);
                endcase
                mixer_pixels=mixer_pixels+1;
                if(mixer_x==W-1) begin
                    mixer_x=0;
                    if(mixer_y==H-1) begin mixer_y=0; mixer_frames=mixer_frames+1; end
                    else mixer_y=mixer_y+1;
                end else mixer_x=mixer_x+1;
            end
        end
    end

    task automatic blank(input integer cycles);
        begin
            @(negedge clk); de=0; user=0; last=0; mix_strobe=0; camera_rgb=0; hs=1;
            repeat(cycles) @(negedge clk);
            hs=0;
        end
    endtask

    initial begin: exercise
        integer value;
        clear_reference();
        repeat(5) @(negedge clk); unit_rst=1;
        // Startup and invalid frames show N/A, including the local '/' glyph.
        for(integer yy=20;yy<84;yy=yy+1)
            for(integer xx=PX+8;xx<PX+392;xx=xx+1) pixel_unit(xx,yy,1,0);
        sample_unit(0,0,0,0);
        sample_unit(1,20000,321,19679);
        sample_unit(1,56789,1234,55555);
        sample_unit(0,0,0,0);
        sample_unit(1,128000,123,127877);
        sample_unit(1,128001,124,127877);
        sample_unit(1,1048575,1048575,0);
        sample_unit(1,0,0,0);
        pixel_unit(PX-1,PY,1,0); pixel_unit(PX,PY,1,0);
        pixel_unit(PX+399,PY+215,1,0); pixel_unit(PX+400,PY+215,1,0);
        pixel_unit(PX,PY+216,1,0); pixel_unit(PX+112,PY+80,0,0);
        @(negedge clk); unit_rst=0; unit_de=0;
        repeat(3) @(negedge clk); clear_reference(); unit_rst=1;
        for(integer i=0;i<70;i=i+1) begin
            value=20000+((i*13)%101)*1000+i;
            if(i==0) value=500;
            if(i==1) value=200000;
            if(i==66) value=188345;
            if(i==69) value=66733;
            sample_unit(i%9!=2,value,100+i,value-100-i);
        end
        check(reference_min==500 && reference_max==200000,
            "Cumulative extrema reference did not retain samples outside history window");
        for(integer i=0;i<64;i=i+1) begin
            check(unit_dut.history[i][9]==reference_valid[i],"History validity slot mismatch");
            if(reference_valid[i]) check(unit_dut.history[i][7:0]==
                (reference_history[i]>=128000 ? 128 : reference_history[i]/1000) &&
                unit_dut.history[i][8]==(reference_history[i]>128000),"History height or clipping mismatch");
        end
        history_preview=$fopen("video_latency_history.ppm","wb");
        $fwrite(history_preview,"P6\n432 240\n255\n");
        for(integer yy=PY-8;yy<PY+232;yy=yy+1)
            for(integer xx=PX-16;xx<PX+416;xx=xx+1) pixel_unit(xx,yy,1,1);
        $fclose(history_preview);
        check(unit_glyphs>1000 && unit_points>500 && unit_alerts>0,"Preview lacks text, graph, or clipping alert");
        @(negedge clk); unit_de=0; clear_reference(); mix_rst=1;
        nominal_preview=$fopen("video_latency_nominal.ppm","wb");
        overflow_preview=$fopen("video_latency_overflow.ppm","wb");
        invalid_preview=$fopen("video_latency_invalid.ppm","wb");
        $fwrite(nominal_preview,"P6\n1280 720\n255\n");
        $fwrite(overflow_preview,"P6\n1280 720\n255\n");
        $fwrite(invalid_preview,"P6\n1280 720\n255\n");
        for(integer f=0;f<4;f=f+1) begin
            for(integer yy=0;yy<H;yy=yy+1) begin
                for(integer xx=0;xx<W;xx=xx+1) begin
                    @(negedge clk);
                    de=1; user=(xx==0 && yy==0); last=xx==W-1;
                    camera_rgb={8'(xx/5),8'(yy/3),8'h60};
                    mix_strobe=yy==0 && xx==8;
                    if(mix_strobe) begin
                        mix_valid=f==1 || f==2;
                        mix_total=f==2 ? 129500 : 66733;
                        mix_isp=f==2 ? 13 : 12; mix_buffer=mix_total-mix_isp;
                        accept_reference(mix_valid,mix_total,mix_isp,mix_buffer);
                    end
                end
                blank(12);
            end
            vs=1; blank(25); vs=0;
        end
        blank(12);
        $fclose(nominal_preview); $fclose(overflow_preview); $fclose(invalid_preview);
        check(mixer_frames==4 && mixer_pixels==4*W*H && frame_events==4,
            "Full-resolution frames or first-pixel events were incomplete");
        check(mixer_glyphs>1000 && mixer_points>500 && target_pixels>1000 &&
            original_osd_pixels>1000,"Mixer lost latency, target, or existing OSD pixels");
        $display("VIDEO_LATENCY_OSD_PASS checks=%0d unit_pixels=%0d mixer_pixels=%0d frames=%0d",
            assertions,checked_pixels,mixer_pixels,mixer_frames);
        $finish;
    end
    initial begin #80000000; $fatal(1,"Latency OSD test timeout"); end
endmodule

// Existing logo/CNT priority is exercised without requiring palette assets.
module anlogic_logo_rom(input wire I_clk,input wire [14:0] I_addr,output reg [24:0] O_pixel);
    always @(posedge I_clk) O_pixel<=(I_addr<160*160) ? 25'h1234567 : 25'd0;
endmodule
