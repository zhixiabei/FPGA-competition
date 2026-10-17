`timescale 1ns/1ps
// Real RAW tap -> asynchronous mailbox -> real mixer/OSD -> HDMI pixels.
// Only the unrelated logo ROM is blanked. Original output timing is checked.
module tb_raw_stats_hdmi;
    reg cam=0, hdmi=0;
    always #4.83 cam=~cam;
    always #6.667 hdmi=~hdmi;
    reg rst=0, rv=0, ru=0, rl=0;
    reg [39:0] raw=0;
    wire sv,dv; wire [44:0] sd,dd;
    reg control=0,ae_valid=0;
    always #21.3 control=~control;
    reg [27:0] ae_data=0;
    wire ae_dst_valid;
    wire [27:0] ae_dst_data;
    integer expected_e=-1,expected_g=0,expected_ae_status=0;
    reg de=0,user=0,last=0,hs=0,vs=0;
    reg [23:0] video=24'h406080;
    wire ode,ohs,ovs,rd; wire [23:0] rgb;
    integer expected_frame=-1, expected_stale=0, pixels=0, glyph_pixels=0, preview=0;
    bit capture=0;
    reg [7:0] expected_char;
    reg [3:0] expected_row;
    wire [15:0] expected_glyph;
    osd_char_lib reference_font(expected_char,expected_row,expected_glyph);
    raw_region_stats tap(.I_clk(cam),.I_rst_n(rst),.I_tdata(raw),.I_tvalid(rv),
        .I_tuser(ru),.I_tlast(rl),.O_valid(sv),.O_data(sd));
    ae_stats_cdc #(.WIDTH(45)) mailbox(.I_src_clk(cam),.I_dst_clk(hdmi),.I_rst_n(rst),
        .I_src_valid(sv),.I_src_data(sd),.O_dst_valid(dv),.O_dst_data(dd));
    ae_stats_cdc #(.WIDTH(28)) ae_mailbox(.I_src_clk(control),.I_dst_clk(hdmi),.I_rst_n(rst),
        .I_src_valid(ae_valid),.I_src_data(ae_data),.O_dst_valid(ae_dst_valid),.O_dst_data(ae_dst_data));
    hdmi_mixer #(.SHOW_RAW_STATS(1)) dut(.I_clk(hdmi),.I_rst_n(rst),
        .I_effect_mode(4'd0),.I_effect_param(8'd0),
        .I_video_de(de),.I_video_user(user),.I_video_last(last),.I_video_hsync(hs),.I_video_vsync(vs),
        .I_debug_status(4'b1111),.I_cam_fail_index(8'd0),.I_raw_stats_valid(dv),.I_raw_stats_data(dd),
        .I_ae_readout_valid(ae_dst_valid),.I_ae_readout_data(ae_dst_data),
        .I_video_rd_data(video),.O_video_rd_en(rd),
        .I_target_result_ready(1'b0),.I_target_found(1'b0),
        .I_target_motion_mode(1'b0),
        .I_target_xmin(12'd0),.I_target_xmax(12'd0),.I_target_ymin(12'd0),.I_target_ymax(12'd0),
        .I_target_center_x(12'd0),.I_target_center_y(12'd0),
        .O_hdmi_de(ode),.O_hdmi_hsync(ohs),.O_hdmi_vsync(ovs),.O_hdmi_data(rgb));
    function automatic integer roi(input integer x,y);
        integer a,b,xx,yy;
        begin
            roi=-1;
            for(b=0;b<3;b++) for(a=0;a<3;a++) begin
                xx=a==0?16:a==1?624:1232;
                yy=b==0?16:b==1?344:672;
                if(x>=xx && x<xx+32 && y>=yy && y<yy+32) roi=b*3+a;
            end
        end
    endfunction
    function automatic integer number(input integer f,r,c);
        if(f==1) number=(r==8?1023:r*101+c*7);
        else number=100+r*73+c*11;
    endfunction
    task automatic camera_frame(input integer f,rows);
        integer y,g,k,r,c,v;
        begin
            for(y=0;y<rows;y++) for(g=0;g<320;g++) begin
                @(negedge cam); rv=1; ru=y==0 && g==0; rl=g==319;
                for(k=0;k<4;k++) begin
                    r=roi(g*4+k,y);
                    c=y%2==0 ? (k%2==0?3:2) : (k%2==0?1:0);
                    v=r<0?511:number(f,r,c);
                    raw[k*10+:10]=10'(v);
                end
            end
            @(negedge cam); rv=0; ru=0; rl=0;
            repeat(160) @(negedge cam);
        end
    endtask
    task automatic send_ae(input integer e,g,sequence_number,seen=1);
        begin
            @(negedge control);ae_data={1'(seen),8'(sequence_number),11'(e),8'(g)};ae_valid=1;
            @(negedge control);ae_valid=0;
            repeat(100) @(negedge hdmi);
        end
    endtask
    function automatic [7:0] table_char(input integer row,col);
        integer c,d,v;
        begin
            table_char=" "; c=-1; d=0;
            if(row==0) begin
                case(col)
                    0:table_char="R";1:table_char="A";2:table_char="W";3:table_char="1";4:table_char="0";
                    6:table_char=expected_frame<0?"W":expected_stale?"S":"L";
                    7:table_char=expected_frame<0?"A":expected_stale?"T":"I";
                    8:table_char=expected_frame<0?"I":expected_stale?"A":"V";
                    9:table_char=expected_frame<0?"T":expected_stale?"L":"E";
                    10:table_char=expected_frame>=0 && expected_stale?"E":" ";
                    12:table_char="E";18:table_char="G";22:table_char="A";
                    23:table_char=expected_ae_status==0?"W":expected_ae_status==2?"S":"L";
                endcase
                if(expected_e>=0 && col>=13 && col<=16) begin
                    v=expected_e;
                    case(col) 13:v=v/1000;14:v=(v/100)%10;15:v=(v/10)%10;16:v=v%10;endcase
                    table_char=8'h30+v;
                end
                if(expected_e>=0 && col>=19 && col<=21) begin
                    v=expected_g;
                    case(col) 19:v=(v/100)%10;20:v=(v/10)%10;21:v=v%10;endcase
                    table_char=8'h30+v;
                end
            end else if(row==1) begin
                case(col)
                    0:table_char="I";1:table_char="D";4:table_char="R";
                    9:table_char="G";10:table_char="R";14:table_char="G";15:table_char="B";
                    19:table_char="B";23:table_char="S";
                endcase
            end else begin
                if(col==0) table_char="0";
                if(col==1) table_char=8'h30+row-1;
                if(col>=4 && col<=7) begin c=0;d=col-4;end
                if(col>=9 && col<=12) begin c=1;d=col-9;end
                if(col>=14 && col<=17) begin c=2;d=col-14;end
                if(col>=19 && col<=22) begin c=3;d=col-19;end
                if(c>=0 && expected_frame>=0) begin
                    v=number(expected_frame,row-2,c);
                    case(d) 0:v=v/1000;1:v=(v/100)%10;2:v=(v/10)%10;3:v=v%10;endcase
                    table_char=8'h30+v;
                end
                if(col==23 && expected_frame==1 && row==10) table_char="S";
            end
        end
    endfunction
    always @(posedge hdmi) begin: check
        integer x,y,px,py;
        bit sde,shs,svs,panel,alert,osd;
        reg [23:0] want,osd_rgb;
        sde=dut.S_video_de_2d; shs=dut.S_video_hsync_2d; svs=dut.S_video_vsync_2d;
        x=dut.S_x_2d; y=dut.S_y_2d;
        osd=dut.S_osd_hit; osd_rgb=dut.S_osd_color;
        panel=sde && x>=496 && x<1264 && y>=176 && y<528;
        px=x-496;py=y-176;
        expected_char=panel ? table_char(py/32,px/32) : 8'h20;
        expected_row=(py%32)/2;
        #1;
        if(rst) begin
            if(ode!==sde || ohs!==shs || ovs!==svs || rd!==de) $fatal(1,"HDMI timing/read-enable changed");
            if(sde) begin
                alert=expected_frame>=0 && (expected_stale || (expected_frame==1 && py/32==10));
                // Source 0x406080 lies at the 64, 96 and 128 curve knots.
                want=osd?osd_rgb:24'h506880;
                if(panel) begin
                    want=expected_glyph[15-(px%32)/2] ? (alert?24'hffb040:24'hffffff) : 24'h101010;
                    if(expected_glyph[15-(px%32)/2]) glyph_pixels++;
                end
                if(rgb!==want) $fatal(1,"HDMI pixel (%0d,%0d) f=%0d char=%c want=%h got=%h",x,y,expected_frame,expected_char,want,rgb);
                pixels++;
                if(capture) $fwrite(preview,"%c%c%c",rgb[23:16],rgb[15:8],rgb[7:0]);
            end
        end
    end
    task automatic display_frame;
        integer y,x;
        begin
            for(y=0;y<720;y++) begin
                for(x=0;x<1280;x++) begin
                    @(negedge hdmi); de=1;user=x==0 && y==0;last=x==1279;hs=0;vs=0;
                end
                @(negedge hdmi); de=0;user=0;last=0;hs=1;
                repeat(3) @(negedge hdmi);
            end
            de=0;user=0;last=0;hs=0;vs=1;
            repeat(8) @(negedge hdmi);
            vs=0;
        end
    endtask
    task automatic frame_pulses(input integer count);
        repeat(count) begin
            @(negedge hdmi); de=1;user=1;last=0;
            @(negedge hdmi); de=0;user=0;
            repeat(10) @(negedge hdmi);
        end
    endtask
    initial begin
        repeat(8) @(negedge hdmi);rst=1;
        display_frame; // WAIT, no spurious zeros from uninitialized memory
        camera_frame(0,720);
        send_ae(1991,144,255);
        expected_e=1991;expected_g=144;expected_ae_status=1;
        expected_frame=0;
        preview=$fopen("raw_stats_hdmi.ppm","wb");
        $fwrite(preview,"P6\n1280 720\n255\n");capture=1;
        // Camera completes a newer snapshot during display. No mixed table.
        fork
            display_frame;
            camera_frame(1,720);
            begin
                // Change both parameters after the title has been scanned.
                // The displayed pair must wait for the next HDMI frame.
                repeat(300000) @(negedge hdmi);
                send_ae(1000,16,0); // sequence wrap still means a fresh frame
            end
        join
        capture=0;$fclose(preview);
        expected_e=1000;expected_g=16;
        expected_frame=1;frame_pulses(16);display_frame;
        // Incomplete RAW frame must never replace the last complete snapshot.
        camera_frame(0,400);frame_pulses(17);display_frame;
        // Completed parameter writes with the SAME sequence must not make
        // stopped metering look live, even though E/G are still updated.
        frame_pulses(100);send_ae(1250,32,0);frame_pulses(20);
        expected_e=1250;expected_g=32;expected_ae_status=2;
        expected_stale=1;display_frame;
        camera_frame(0,720);send_ae(4,16,1);
        expected_e=4;expected_g=16;expected_ae_status=1;
        expected_frame=0;expected_stale=0;display_frame;
        @(negedge hdmi);rst=0;
        repeat(8) @(negedge hdmi);rst=1;
        expected_frame=-1;expected_e=-1;expected_ae_status=0;display_frame;
        $display("RAW_STATS_HDMI_PASS pixels=%0d glyph_pixels=%0d",pixels,glyph_pixels);
        $finish;
    end
    initial begin #200000000; $fatal(1,"HDMI timeout"); end
endmodule
module anlogic_logo_rom(input wire I_clk,input wire [14:0] I_addr,output reg [24:0] O_pixel);
    always @(posedge I_clk) O_pixel<=0;
endmodule
