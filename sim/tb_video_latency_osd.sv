`timescale 1ns/1ps
module tb_video_latency_osd #(
    parameter integer LARGE_TEXT=0,
    parameter integer NARROW_TEXT=0
);
    localparam integer NARROW_LAYOUT=LARGE_TEXT && NARROW_TEXT;
    localparam integer PX=LARGE_TEXT ? (NARROW_LAYOUT ? 960 : 16) : 984;
    localparam integer PY=LARGE_TEXT ? 592 : 16;
    localparam integer PANEL_W=LARGE_TEXT ? (NARROW_LAYOUT ? 320 : 400) : 280;
    localparam integer PANEL_H=LARGE_TEXT ? 112 : 64;
    localparam integer TEXT_LEFT=NARROW_LAYOUT ? 4 : 8;
    localparam integer TEXT_TOP=LARGE_TEXT ? 8 : 4;
    localparam integer TEXT_W=LARGE_TEXT ? (NARROW_LAYOUT ? 312 : 384) : 256;
    localparam integer TEXT_H=LARGE_TEXT ? 96 : 48;
    localparam integer NUMERIC_LEFT=NARROW_LAYOUT ? 4 : 6;
    localparam integer CELL_W=LARGE_TEXT ? 24 : 16;
    localparam integer CELL_H=LARGE_TEXT ? 32 : 16;
    localparam integer PREVIEW_W=PANEL_W+16, PREVIEW_H=PANEL_H+16;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, de=0, strobe=0, valid=0;
    reg [11:0] x=0, y=0;
    reg [19:0] total_us=0, isp_us=0, buffer_us=0;
    wire panel, text, alert;
    video_latency_osd #(.PANEL_X(PX),.PANEL_Y(PY),.LARGE_TEXT(LARGE_TEXT),
        .NARROW_TEXT(NARROW_TEXT)) dut(
        .I_clk(clk),.I_rst_n(rst_n),.I_sample_strobe(strobe),
        .I_sample_valid(valid),.I_total_us(total_us),.I_isp_us(isp_us),
        .I_buffer_us(buffer_us),.I_de(de),.I_x(x),.I_y(y),
        .O_panel(panel),.O_text(text),.O_alert(alert));

    integer ref_total=0, ref_isp=0, ref_buffer=0;
    bit ref_valid=0;
    reg [7:0] ref_char=" ";
    reg [3:0] ref_row=0, ref_col=0;
    wire [15:0] ref_glyph;
    osd_char_lib ref_font(.I_char(ref_char),.I_row(ref_row),.O_row_bits(ref_glyph));
    integer checks=0, checked_pixels=0, glyph_pixels=0, alert_pixels=0;
    integer preview;

    task automatic check(input bit condition,input string message_text);
        begin
            if(!condition) $fatal(1,"%s",message_text);
            checks=checks+1;
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
        integer value;
        begin
            case(row)
                0: begin
                    value=ref_total>999999 ? 999999 : ref_total;
                    if(NARROW_LAYOUT)
                        line_text=ref_valid ?
                            $sformatf("TOT:%03d.%03dMS",value/1000,value%1000) :
                            "TOT:N/A    MS";
                    else
                        line_text=ref_valid ?
                            $sformatf("TOTAL:%03d.%03d MS",value/1000,value%1000) :
                            "TOTAL:N/A     MS";
                end
                1: begin
                    value=ref_isp>999999 ? 999999 : ref_isp;
                    if(NARROW_LAYOUT)
                        line_text=ref_valid ?
                            $sformatf("ISP:%03d.%03dMS",value/1000,value%1000) :
                            "ISP:N/A    MS";
                    else
                        line_text=ref_valid ?
                            $sformatf("ISP:  %03d.%03d MS",value/1000,value%1000) :
                            "ISP:  N/A     MS";
                end
                default: begin
                    value=ref_buffer>999999 ? 999999 : ref_buffer;
                    if(NARROW_LAYOUT)
                        line_text=ref_valid ?
                            $sformatf("BUF:%03d.%03dMS",value/1000,value%1000) :
                            "BUF:N/A    MS";
                    else
                        line_text=ref_valid ?
                            $sformatf("BUF:  %03d.%03d MS",value/1000,value%1000) :
                            "BUF:  N/A     MS";
                end
            endcase
            if(NARROW_LAYOUT && line_text.len()!=13)
                $fatal(1,"Narrow latency oracle must retain exactly thirteen characters");
            expected_character=col<line_text.len() ? line_text[col] : " ";
        end
    endfunction

    task automatic expected_masks(input integer px,py,input bit enabled,
        output reg [2:0] masks);
        integer local_x,local_y,row,col;
        bit inside_panel,text_area,glyph_on,alert_on;
        begin
            masks=0; local_x=px-PX; local_y=py-PY;
            inside_panel=enabled && local_x>=0 && local_x<PANEL_W &&
                local_y>=0 && local_y<PANEL_H;
            text_area=inside_panel && local_x>=TEXT_LEFT && local_x<TEXT_LEFT+TEXT_W &&
                local_y>=TEXT_TOP && local_y<TEXT_TOP+TEXT_H;
            row=(local_y-TEXT_TOP)/CELL_H; col=(local_x-TEXT_LEFT)/CELL_W;
            ref_char=" "; ref_row=0; ref_col=0;
            if(text_area) begin
                ref_char=expected_character(row,col);
                ref_row=LARGE_TEXT ? ((local_y-TEXT_TOP)/2)%16 :
                    (local_y-TEXT_TOP)%16;
                ref_col=LARGE_TEXT ? 2+((local_x-TEXT_LEFT)/2)%12 :
                    (local_x-TEXT_LEFT)%16;
            end
            #1;
            glyph_on=ref_glyph[15-ref_col];
            alert_on=text_area && row==0 && col>=NUMERIC_LEFT &&
                col<=NUMERIC_LEFT+6 && ref_valid &&
                (ref_total>128000 || ref_isp>999999 || ref_buffer>999999);
            masks[2]=inside_panel;
            masks[1]=text_area && glyph_on;
            masks[0]=alert_on;
        end
    endtask

    function automatic [23:0] panel_color(input [2:0] masks);
        panel_color=masks[1] ? (masks[0] ? 24'hffb040 : 24'hffffff) : 24'h101418;
    endfunction

    task automatic sample(input bit sample_valid,
        input integer total_value,isp_value,buffer_value);
        begin
            @(negedge clk);
            strobe=1; valid=sample_valid; total_us=total_value;
            isp_us=isp_value; buffer_us=buffer_value;
            ref_valid=sample_valid; ref_total=total_value;
            ref_isp=isp_value; ref_buffer=buffer_value;
            @(negedge clk); strobe=0;
            repeat(65) @(negedge clk);
            check(dut.display_valid==sample_valid,"Current sample validity mismatch");
            check(!dut.busy,"Three-field conversion did not finish within 60 clocks");
            if(sample_valid)
                check(dut.bcd_total==decimal_bcd(total_value) &&
                    dut.bcd_isp==decimal_bcd(isp_value) &&
                    dut.bcd_buffer==decimal_bcd(buffer_value),
                    "Latency decimal conversion mismatch");
        end
    endtask

    task automatic pixel(input integer px,py,input bit enabled,input bit save_pixel);
        reg [2:0] expected;
        reg [2:0] previous;
        reg [23:0] rgb;
        begin
            @(negedge clk);
            previous={panel,text,alert};
            x=px; y=py; de=enabled;
            expected_masks(px,py,enabled,expected);
            if({panel,text,alert}!==previous)
                $fatal(1,"OSD output changed before its registered edge large=%0d narrow=%0d",
                    LARGE_TEXT,NARROW_TEXT);
            @(posedge clk); #1;
            if({panel,text,alert}!==expected)
                $fatal(1,"OSD pixel mismatch large=%0d narrow=%0d at %0d,%0d actual=%b expected=%b",
                    LARGE_TEXT,NARROW_TEXT,px,py,{panel,text,alert},expected);
            checked_pixels=checked_pixels+1;
            if(text) glyph_pixels=glyph_pixels+1;
            if(alert) alert_pixels=alert_pixels+1;
            if(save_pixel) begin
                rgb=panel ? panel_color(expected) : 24'h405060;
                $fwrite(preview,"%c%c%c",rgb[23:16],rgb[15:8],rgb[7:0]);
            end
        end
    endtask

    task automatic scan_panel(input bit save_pixels);
        begin
            for(integer yy=PY-8;yy<PY+PANEL_H+8;yy=yy+1)
                for(integer xx=PX-8;xx<PX+PANEL_W+8;xx=xx+1)
                    pixel(xx,yy,1,save_pixels);
        end
    endtask

    initial begin
        repeat(5) @(negedge clk); rst_n=1;
        sample(0,0,0,0);
        for(integer yy=PY;yy<PY+PANEL_H;yy=yy+1)
            for(integer xx=PX;xx<PX+PANEL_W;xx=xx+1) pixel(xx,yy,1,0);

        sample(1,20000,321,19679);
        scan_panel(0);
        sample(1,56789,1234,55555);
        scan_panel(0);
        sample(1,128000,123,127877);
        scan_panel(0);
        check(alert_pixels==0,"TOTAL at or below the limit showed an alert");
        sample(1,128001,124,127877);
        scan_panel(0);
        check(alert_pixels>0,"Over-limit TOTAL did not show an alert");

        sample(1,100000,1048575,0);
        scan_panel(0);
        check(dut.current_overflow,"Out-of-range component did not show an alert");
        sample(1,1048575,1048575,1048575);
        scan_panel(0);
        sample(0,0,0,0);
        sample(1,24123,1750,22373);

        preview=$fopen(NARROW_LAYOUT ? "video_latency_narrow.ppm" :
            (LARGE_TEXT ? "video_latency_large.ppm" : "video_latency_compact.ppm"),"wb");
        $fwrite(preview,"P6\n%0d %0d\n255\n",PREVIEW_W,PREVIEW_H);
        scan_panel(1);
        $fclose(preview);
        check(glyph_pixels>1000,"Latency panel preview lacks text");
        pixel(PX-1,PY,1,0); pixel(PX,PY,1,0);
        pixel(PX+PANEL_W-1,PY+PANEL_H-1,1,0);
        pixel(PX+PANEL_W,PY+PANEL_H-1,1,0);
        pixel(PX,PY+PANEL_H,1,0);
        pixel(PX+TEXT_LEFT,PY+TEXT_TOP,0,0);
        pixel(PX+PANEL_W-1,PY+PANEL_H-1,0,0);
        pixel(PX+PANEL_W/2,PY+PANEL_H/2,0,0);
        pixel(PX+PANEL_W/2,PY+PANEL_H/2,1,0);
        check(dut.PANEL_WIDTH==PANEL_W && dut.PANEL_HEIGHT==PANEL_H,
            "Latency panel dimensions mismatch");
        $display("VIDEO_LATENCY_OSD_PASS large=%0d narrow=%0d panel=%0dx%0d checks=%0d pixels=%0d glyph_pixels=%0d alerts=%0d",
            LARGE_TEXT,NARROW_TEXT,PANEL_W,PANEL_H,checks,checked_pixels,glyph_pixels,alert_pixels);
        $finish;
    end
    initial begin #10000000; $fatal(1,"Latency OSD test timeout"); end
endmodule
