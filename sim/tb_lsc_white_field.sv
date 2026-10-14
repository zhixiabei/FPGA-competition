`timescale 1ns/1ps
// Actual LSC -> actual demosaic -> actual AWB. The input fixtures interpolate
// the two measured RAW tables. They do not read the DUT correction surface.
module tb_lsc_white_field;
    `include "lsc_mesh_reference.vh"
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,v=0,u=0,l=0;
    reg [39:0] data=0;
    reg [39:0] white1[0:230399],white2[0:230399];
    wire [39:0] ld;
    wire lv,lu,ll,dv,du,dl,av,au,al;
    wire [127:0] dd;
    wire [95:0] rgb,ad;
    lsc_raw10_4x #(.MESH_ENABLE(1),.MESH_CURVE_ENABLE(REF_CURVE_ENABLE),.MESH_GR_Q8(REF_GR),
        .MESH_GB_Q8(REF_GB),.MESH_B_Q8(REF_B)) lsc (
        .I_clk(clk),.I_rst_n(rst_n),.I_tdata(data),.I_tvalid(v),.I_tuser(u),.I_tlast(l),
        .I_tready(),.O_tdata(ld),.O_tvalid(lv),.O_tuser(lu),.O_tlast(ll),.O_tready(1'b1));
    demosaic #(.IMG_WIDTH(1280),.IMG_HEIGHT(720),.BAYER_MODE("BGGR")) dm (
        .I_clk(clk),.I_rst_n(rst_n),.axi4s_video_tdata(ld),.axi4s_video_tdest(10'd0),
        .axi4s_video_tlast(ll),.axi4s_video_tuser(lu),.axi4s_video_tvalid(lv),
        .axi4s_video_tready(),.O_tlast(dl),.O_tuser(du),.O_tdata(dd),
        .O_tvalid(dv),.O_tready(1'b1));
    data128_96 pack_rgb(.I_tdata(dd),.O_tdata(rgb));
    wire meter_valid;
    wire [31:0] meter_sum;
    wire [15:0] meter_count,meter_bright;
    ae_frame_stats_96 old_meter (
        .I_clk(clk),.I_rst_n(rst_n),.I_tdata(rgb),.I_tvalid(dv),.I_tuser(du),.I_tlast(dl),
        .O_stats_valid(meter_valid),.O_sum_y(meter_sum),
        .O_sample_count(meter_count),.O_bright_count(meter_bright));
    wire corrected_valid;
    wire [31:0] corrected_sum;
    wire [15:0] corrected_count,corrected_bright;
    ae_frame_stats_96 #(.BRIGHT_RGB_ENABLE(1),.BRIGHT_R(232),
        .BRIGHT_G(141),.BRIGHT_B(223)) corrected_meter (
        .I_clk(clk),.I_rst_n(rst_n),.I_tdata(rgb),.I_tvalid(dv),.I_tuser(du),.I_tlast(dl),
        .O_stats_valid(corrected_valid),.O_sum_y(corrected_sum),
        .O_sample_count(corrected_count),.O_bright_count(corrected_bright));
    integer metered_frames=0;
    always @(posedge clk) begin
        #1;
        if(rst_n && meter_valid) begin
            metered_frames=metered_frames+1;
            if(meter_count!=7200) $fatal(1,"Actual demosaic did not publish full-frame AE stats");
            if(!corrected_valid || corrected_count!=7200)
                $fatal(1,"Corrected meter lost an actual RGB frame");
            if(metered_frames>6) begin
                $display("LSC_METER_REPRO frame=%0d samples=%0d legacy_bright=%0d legacy_background_mean=%0d corrected_bright=%0d corrected_background_mean=%0d",
                    metered_frames,meter_count,meter_bright,
                    meter_count>meter_bright ? meter_sum/(meter_count-meter_bright) : 0,
                    corrected_bright, corrected_count>corrected_bright ?
                        corrected_sum/(corrected_count-corrected_bright) : 0);
                if(metered_frames==7 && (meter_bright>=6000 || corrected_bright<7100))
                    $fatal(1,"Did not recover post-LSC clipped white field");
                // The 60% lamp has interpolated boundary pixels. Allow a
                // two-sample perimeter band, but require the remaining
                // background to demand FAST brightening rather than hold.
                if(metered_frames==8 && (corrected_bright<4320-348 || corrected_bright>4320+348 ||
                    corrected_sum>=48*(corrected_count-corrected_bright) ||
                    meter_sum<112*(meter_count-meter_bright) ||
                    meter_sum>144*(meter_count-meter_bright)))
                    $fatal(1,"Did not reproduce lamp-biased background metering");
            end
        end
    end
    awb #(.IMG_WIDTH(1280),.IMG_HEIGHT(720)) wb (
        .I_clk(clk),.I_rst_n(rst_n),.I_tdata(rgb),.I_tvalid(dv),.I_tuser(du),.I_tlast(dl),
        .I_tready(),.O_tdata(ad),.O_tvalid(av),.O_tuser(au),.O_tlast(al),.O_tready(1'b1));
    // Include the four intermediate columns/rows missed by the old 3x3 check.
    integer sums[0:24][0:2],counts[0:24];
    integer pixel_count=0,frames=0,lane,x,y,c,region,x0,y0,largest,smallest;
    integer f,yy,xx,k;
    reg [23:0] colour;
    real error,worst=0;
    always @(posedge clk) begin
        #1;
        if(rst_n && au) begin
            if(pixel_count!=0 && pixel_count!=921600) $fatal(1,"White field frame truncated");
            pixel_count=0;
            for(region=0;region<25;region=region+1) begin
                counts[region]=0;
                for(c=0;c<3;c=c+1)sums[region][c]=0;
            end
        end
        if(rst_n && av) begin
            for(lane=0;lane<4;lane=lane+1) begin
                x=pixel_count%1280;y=pixel_count/1280;
                colour=ad[95-24*lane -:24];
                if(^colour===1'bx) $fatal(1,"Unknown output pixel");
                for(region=0;region<25;region=region+1) begin
                    x0=16+304*(region%5);y0=16+164*(region/5);
                    if(x>=x0 && x<x0+32 && y>=y0 && y<y0+32) begin
                        counts[region]=counts[region]+1;
                        sums[region][0]=sums[region][0]+colour[23:16];
                        sums[region][1]=sums[region][1]+colour[15:8];
                        sums[region][2]=sums[region][2]+colour[7:0];
                    end
                end
                pixel_count=pixel_count+1;
            end
            if(pixel_count==921600) begin
                frames=frames+1;
                if(frames<=6) for(region=0;region<25;region=region+1) begin
                    if(counts[region]!=1024) $fatal(1,"White field ROI count");
                    largest=sums[region][0];smallest=largest;
                    for(c=1;c<3;c=c+1) begin
                        if(sums[region][c]>largest)largest=sums[region][c];
                        if(sums[region][c]<smallest)smallest=sums[region][c];
                    end
                    error=1.0*(largest-smallest)/largest;
                    if(error>worst)worst=error;
                    if(error>0.035) $fatal(1,"White field RGB spread >3.5%% frame=%0d ROI=%0d RGB=%0d/%0d/%0d",
                        frames,region+1,sums[region][0]/1024,sums[region][1]/1024,sums[region][2]/1024);
                    if(frames==6) $display("WHITE_ROI id=%0d RGB=%0.2f/%0.2f/%0.2f",region+1,
                        sums[region][0]/1024.0,sums[region][1]/1024.0,sums[region][2]/1024.0);
                end
            end
        end
    end
    initial begin
        $readmemh("white1.hex",white1);$readmemh("white2.hex",white2);
        repeat(5)@(negedge clk);rst_n=1;
        for(f=0;f<6;f=f+1) begin
            @(negedge clk);u=1;v=0;l=0;
            @(negedge clk);u=0;
            for(yy=0;yy<720;yy=yy+1) begin
                for(xx=0;xx<320;xx=xx+1) begin
                    @(negedge clk);v=1;l=xx==319;
                    data=f<3 ? white1[yy*320+xx] : white2[yy*320+xx];
                end
                @(negedge clk);v=0;l=0;
                repeat(24)@(negedge clk);
            end
            repeat(1000)@(negedge clk);
        end
        if(frames!=6) $fatal(1,"White field output frame count");
        if(wb.gain_r_q8<246 || wb.gain_r_q8>266 || wb.gain_b_q8<246 || wb.gain_b_q8>266)
            $fatal(1,"Unexpected global white balance gain");
        $display("LSC_WHITE_FIELD_PASS frames=%0d pixels=%0d max_roi_spread=%0.3f%% final_awb_q8=%0d/%0d",
            frames,frames*921600,worst*100,wb.gain_r_q8,wb.gain_b_q8);
        // RAW clipping is physically before LSC. Use the actual interpolation
        // and demosaic, rather than feeding an ideal grey value to the meter.
        for(f=6;f<8;f=f+1) begin
            @(negedge clk);u=1;v=0;l=0;
            @(negedge clk);u=0;
            for(yy=0;yy<720;yy=yy+1) begin
                for(xx=0;xx<320;xx=xx+1) begin
                    @(negedge clk);v=1;l=xx==319;
                    data=(f==6 || (xx>=40 && xx<280 && yy>=72 && yy<648)) ?
                         {4{10'd1023}} : {4{10'd40}};
                end
                @(negedge clk);v=0;l=0;
                repeat(24)@(negedge clk);
            end
            repeat(1000)@(negedge clk);
        end
        if(metered_frames!=8 || frames!=8) $fatal(1,"LSC metering frame count");
        $display("LSC_METER_REPRO_PASS frames=%0d",metered_frames);
        $finish;
    end
    initial begin #30000000;$fatal(1,"White field timeout");end
endmodule
