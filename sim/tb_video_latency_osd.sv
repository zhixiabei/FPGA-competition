`timescale 1ns/1ps
module tb_video_latency_osd;
    localparam integer PX=984, PY=16, PANEL_W=280, PANEL_H=64;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, de=0, strobe=0, valid=0;
    reg [11:0] x=0, y=0;
    reg [19:0] total_us=0, isp_us=0, buffer_us=0;
    wire panel, text, alert;
    video_latency_osd dut(
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
                    line_text=ref_valid ?
                        $sformatf("TOTAL:%03d.%03d MS",value/1000,value%1000) :
                        "TOTAL:N/A     MS";
                end
                1: begin
                    value=ref_isp>999999 ? 999999 : ref_isp;
                    line_text=ref_valid ?
                        $sformatf("ISP:  %03d.%03d MS",value/1000,value%1000) :
                        "ISP:  N/A     MS";
                end
                default: begin
                    value=ref_buffer>999999 ? 999999 : ref_buffer;
                    line_text=ref_valid ?
                        $sformatf("BUF:  %03d.%03d MS",value/1000,value%1000) :
                        "BUF:  N/A     MS";
                end
            endcase
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
            text_area=inside_panel && local_x>=8 && local_x<264 &&
                local_y>=4 && local_y<52;
            row=(local_y-4)/16; col=(local_x-8)/16;
            ref_char=" "; ref_row=0; ref_col=0;
            if(text_area) begin
                ref_char=expected_character(row,col);
                ref_row=(local_y-4)%16;
                ref_col=(local_x-8)%16;
            end
            #1;
            glyph_on=ref_char=="." ?
                ((ref_row==11 || ref_row==12) && (ref_col==6 || ref_col==7)) :
                ref_char=="/" ?
                (ref_row>=2 && ref_row<=11 && ref_col==13-ref_row) :
                ref_glyph[15-ref_col];
            alert_on=text_area && row==0 && col>=6 && col<=12 && ref_valid &&
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
        reg [23:0] rgb;
        begin
            @(negedge clk); x=px; y=py; de=enabled;
            expected_masks(px,py,enabled,expected);
            @(posedge clk); #1;
            if({panel,text,alert}!==expected)
                $fatal(1,"OSD pixel mismatch at %0d,%0d actual=%b expected=%b",
                    px,py,{panel,text,alert},expected);
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
        sample(1,56789,1234,55555);
        sample(1,128000,123,127877);
        sample(1,128001,124,127877);
        scan_panel(0);
        check(alert_pixels>0,"Over-limit TOTAL did not show an alert");

        sample(1,100000,1048575,0);
        scan_panel(0);
        check(dut.current_overflow,"Out-of-range component did not show an alert");
        sample(0,0,0,0);
        sample(1,66733,12,66721);

        preview=$fopen("video_latency_compact.ppm","wb");
        $fwrite(preview,"P6\n296 80\n255\n");
        scan_panel(1);
        $fclose(preview);
        check(glyph_pixels>1000,"Compact panel preview lacks text");
        pixel(PX-1,PY,1,0); pixel(PX,PY,1,0);
        pixel(PX+PANEL_W-1,PY+PANEL_H-1,1,0);
        pixel(PX+PANEL_W,PY+PANEL_H-1,1,0);
        pixel(PX,PY+PANEL_H,1,0);
        pixel(PX+8,PY+4,0,0);
        $display("VIDEO_LATENCY_OSD_PASS checks=%0d pixels=%0d glyph_pixels=%0d alerts=%0d",
            checks,checked_pixels,glyph_pixels,alert_pixels);
        $finish;
    end
    initial begin #10000000; $fatal(1,"Latency OSD test timeout"); end
endmodule
