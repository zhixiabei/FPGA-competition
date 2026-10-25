`timescale 1ns/1ps
// Independent image-domain Bayer reference, including reflected borders.
module tb_demosaic_quality #(
    parameter integer W=64, H=48, ALLOW_ERRORS=0,
    parameter integer EDGE_AWARE_REFERENCE=1,
    parameter integer CSI_SOURCE=0,
    parameter BAYER="BGGR"
);
    reg clk=0;
    always #4.830 clk=~clk;
    reg rst_n=0, in_valid=0, in_user=0, in_last=0;
    reg [39:0] in_data=0;
    reg hs_valid=0;
    reg [15:0] hs_data=0;
    wire source_valid,source_user,source_last;
    wire [39:0] source_data;
    wire raw_valid;
    wire [39:0] raw_data;
    generate if(CSI_SOURCE) begin: csi_source
        wire csi_start,csi_end,csi_valid,raw_start,raw_end;
        wire [31:0] csi_data;
        csi_unpacket_2lane u_csi (
            .I_clk(clk),.I_rst_n(rst_n),.I_hs_valid(hs_valid),.I_hs_data(hs_data),
            .O_csi_frame_start(csi_start),.O_csi_frame_end(csi_end),
            .O_csi_valid(csi_valid),.O_csi_hs(),.O_csi_data(csi_data)
        );
        raw10_unpacket_2lane u_raw (
            .I_clk(clk),.I_rst_n(rst_n),.I_csi_frame_start(csi_start),
            .I_csi_frame_end(csi_end),.I_csi_valid(csi_valid),.I_csi_data(csi_data),
            .I_camera_black_level(10'd0),.O_raw10_frame_start(raw_start),
            .O_raw10_frame_end(raw_end),.O_raw10_valid(raw_valid),
            .O_raw10_data(raw_data)
        );
        uial2axis #(.IMG_WIDTH(W),.IMG_HEIGHT(H),.INPUT_DATA_WIDTH(40)) u_axis (
            .I_native_clk(clk),.I_rst_n(rst_n),.I_data(raw_data),
            .I_data_valid(raw_valid),.I_data_start(raw_start),.I_data_end(raw_end),
            .axis_tvalid(source_valid),.axis_tdata(source_data),
            .axis_tuser(source_user),.axis_tlast(source_last)
        );
    end else begin: direct_source
        assign source_data=in_data;
        assign source_valid=in_valid;assign source_user=in_user;assign source_last=in_last;
        assign raw_data=in_data;assign raw_valid=in_valid;
    end endgenerate
    wire out_valid,out_user,out_last;
    wire [127:0] out_data;
    demosaic #(.IMG_WIDTH(W),.IMG_HEIGHT(H),.BAYER_MODE(BAYER)) dut (
        .I_clk(clk),.I_rst_n(rst_n),.axi4s_video_tdata(source_data),
        .axi4s_video_tdest(10'd0),.axi4s_video_tvalid(source_valid),
        .axi4s_video_tuser(source_user),.axi4s_video_tlast(source_last),
        .axi4s_video_tready(),.O_tvalid(out_valid),.O_tuser(out_user),
        .O_tlast(out_last),.O_tdata(out_data),.O_tready(1'b1)
    );
`ifdef LEGACY_DEMOSAIC_RAM_TIES
    // The old wrappers omit unused port B writes. TD ties these pins low,
    // but the functional model treats Z as an indeterminate write mode.
    initial begin
        force dut.raw_matrix_3x3_buffer_d.zhenghe_d.blk_mem_gen_zhenghe_d1.web=1'b0;
        force dut.raw_matrix_3x3_buffer_d.zhenghe_d.blk_mem_gen_zhenghe_d1.dib=32'd0;
        force dut.raw_matrix_3x3_buffer_d.two_line_buffer[1].line_buffer_demosaic_r1.blk_mem_gen_demosaic_r0.web=1'b0;
        force dut.raw_matrix_3x3_buffer_d.two_line_buffer[1].line_buffer_demosaic_r1.blk_mem_gen_demosaic_r0.dib=33'd0;
        force dut.raw_matrix_3x3_buffer_d.two_line_buffer[2].line_buffer_demosaic_r1.blk_mem_gen_demosaic_r0.web=1'b0;
        force dut.raw_matrix_3x3_buffer_d.two_line_buffer[2].line_buffer_demosaic_r1.blk_mem_gen_demosaic_r0.dib=33'd0;
    end
`endif
    integer scene_id=0, received=0, errors=0, frames=0, total_pixels=0, marker_errors=0;
    integer raw_received=0,total_raw_pixels=0,raw_lane,raw_x,raw_y;
    integer sharpness_checks=0,bilinear_edge_error=0,directional_edge_error=0;
    integer x,y,k,r,g,b,center,ns,ew,diagonal;
    reg [23:0] expected,actual;
    function automatic integer channel(input integer px,input integer py);
        integer phase;
        begin
            phase=2*(py%2)+px%2;
            case(BAYER)
                "BGGR": channel=phase==0?2:phase==3?0:1;
                "RGGB": channel=phase==0?0:phase==3?2:1;
                "GBRG": channel=phase==1?2:phase==2?0:1;
                default: channel=phase==1?0:phase==2?2:1;
            endcase
        end
    endfunction
    function automatic integer raw(input integer px,input integer py);
        integer xx,yy,c;
        begin
            xx=px<0?1:px>=W?W-2:px;
            yy=py<0?1:py>=H?H-2:py;
            c=channel(xx,yy);
            case(scene_id)
                0: raw=c==0?200:c==1?110:60;
                1: raw=24+(xx*7+yy*11)%192;
                2: raw=(xx==W-2 || yy==H-2 || xx==7 || yy==5)?224:32;
                4: raw=xx<W/2?32:224;
                5: raw=yy<H/2?32:224;
                default: raw=(xx*37+yy*61+c*29+(xx*yy)%97)%256;
            endcase
        end
    endfunction
    // Match RAW10 truncation using image coordinates and reflected borders.
    function automatic integer corrected_raw(input integer px,input integer py);
        integer xx,yy,value;
        begin
            xx=px<0?1:px>=W?W-2:px;
            yy=py<0?1:py>=H?H-2:py;
            value=raw(xx,yy)*4+(CSI_SOURCE ? (xx+3*yy+scene_id)%4 : 0);
            corrected_raw=value/4;
        end
    endfunction
    function automatic [23:0] reference(input integer px,input integer py);
        integer c,n,s,e,w,nw,ne,sw,se,rr,gg,bb;
        begin
            c=corrected_raw(px,py);n=corrected_raw(px,py-1);s=corrected_raw(px,py+1);
            e=corrected_raw(px+1,py);w=corrected_raw(px-1,py);
            nw=corrected_raw(px-1,py-1);ne=corrected_raw(px+1,py-1);
            sw=corrected_raw(px-1,py+1);se=corrected_raw(px+1,py+1);
            if(channel(px,py)==0 || channel(px,py)==2) begin
                if(EDGE_AWARE_REFERENCE && ((e>w?e-w:w-e)+8)<(n>s?n-s:s-n)) gg=(e+w)/2;
                else if(EDGE_AWARE_REFERENCE && ((n>s?n-s:s-n)+8)<(e>w?e-w:w-e)) gg=(n+s)/2;
                else gg=(n+s+e+w)/4;
                if(channel(px,py)==0) begin rr=c;bb=(nw+ne+sw+se)/4;end
                else begin bb=c;rr=(nw+ne+sw+se)/4;end
            end else begin
                gg=c;
                if(channel(px+1,py)==0) begin
                    rr=(e+w)/2;bb=(n+s)/2;
                end else begin
                    bb=(e+w)/2;rr=(n+s)/2;
                end
            end
            reference={rr[7:0],gg[7:0],bb[7:0]};
        end
    endfunction
    function automatic [9:0] reference_raw10(input integer px,input integer py);
        reference_raw10=raw(px,py)*4+((px+3*py+scene_id)%4);
    endfunction
    always @(posedge clk) begin
        #1;
        if(rst_n && CSI_SOURCE && raw_valid) begin
            if(raw_received>=W*H) $fatal(1,"Extra CSI RAW10 pixels");
            for(raw_lane=0;raw_lane<4;raw_lane=raw_lane+1) begin
                raw_x=raw_received%W;raw_y=raw_received/W;
                if(raw_data[raw_lane*10 +:10]!==reference_raw10(raw_x,raw_y))
                    $fatal(1,"CSI RAW10 mismatch scene=%0d x=%0d y=%0d got=%h expected=%h",
                        scene_id,raw_x,raw_y,raw_data[raw_lane*10 +:10],
                        reference_raw10(raw_x,raw_y));
                raw_received=raw_received+1;total_raw_pixels=total_raw_pixels+1;
            end
        end
        if(rst_n && out_valid) begin
            if(received>=W*H) $fatal(1,"Extra demosaic pixels");
            if(out_user!==(received==0) || out_last!==((received/4)%(W/4)==W/4-1)) begin
                marker_errors=marker_errors+1;
                if(!ALLOW_ERRORS) $fatal(1,"Demosaic marker mismatch at pixel %0d",received);
            end
            for(k=0;k<4;k=k+1) begin
                x=received%W;y=received/W;
                expected=reference(x,y);
                actual=out_data[k*32 +:24];
                if(actual!==expected) begin
                    if(errors<12) $display("BAYER_MISMATCH scene=%0d x=%0d y=%0d got=%h expected=%h",
                        scene_id,x,y,actual,expected);
                    errors=errors+1;
                end
                if(scene_id>=4 && channel(x,y)!=1) begin
                    center=raw(x,y);
                    g=(raw(x-1,y)+raw(x+1,y)+raw(x,y-1)+raw(x,y+1))/4;
                    bilinear_edge_error=bilinear_edge_error+(g>center?g-center:center-g);
                    g=actual[15:8];
                    directional_edge_error=directional_edge_error+(g>center?g-center:center-g);
                    sharpness_checks=sharpness_checks+1;
                end
                received=received+1;total_pixels=total_pixels+1;
            end
        end
    end
    task automatic tick(input bit v,input bit u,input bit l,input [39:0] d);
        begin
            @(negedge clk);in_valid=v;in_user=u;in_last=l;in_data=d;
        end
    endtask
    task automatic hs_tick(input bit v,input [15:0] d);
        begin @(negedge clk);hs_valid=v;hs_data=d;end
    endtask
    task automatic csi_frame;
        integer yy,xx,byte_index,n;
        reg [7:0] payload[0:W*5/4-1];
        reg [9:0] samples[0:3];
        reg [15:0] word_count;
        begin
            raw_received=0;
            word_count=W*5/4;
            // The production parser ignores ECC/CRC. Zero placeholders here
            // test payload packing only, not packet-integrity checking.
            hs_tick(1,16'h0001);hs_tick(1,16'h0000);
            repeat(32) hs_tick(0,0);
            for(yy=0;yy<H;yy=yy+1) begin
                for(xx=0;xx<W;xx=xx+4) begin
                    for(n=0;n<4;n=n+1) samples[n]=reference_raw10(xx+n,yy);
                    byte_index=xx*5/4;
                    for(n=0;n<4;n=n+1) payload[byte_index+n]=samples[n][9:2];
                    payload[byte_index+4]=
                        {samples[3][1:0],samples[2][1:0],samples[1][1:0],samples[0][1:0]};
                end
                hs_tick(1,{8'h2b,word_count[7:0]});
                hs_tick(1,{word_count[15:8],8'h00});
                for(byte_index=0;byte_index<word_count;byte_index=byte_index+2)
                    hs_tick(1,{payload[byte_index],payload[byte_index+1]});
                hs_tick(1,16'h0000);
                repeat(48+scene_id*7) hs_tick(0,0);
            end
            hs_tick(1,16'h0101);hs_tick(1,16'h0000);
            repeat(W+200) hs_tick(0,0);
            if(raw_received!=W*H)
                $fatal(1,"Incomplete CSI RAW10 frame: %0d/%0d",raw_received,W*H);
        end
    endtask
    task automatic frame(input integer id);
        integer yy,xx,n;
        reg [39:0] group_data;
        begin
            scene_id=id;received=0;
            if(CSI_SOURCE) csi_frame();
            else begin
                // Exercise an early, held SOF as well as SOF on the first beat.
                if(id==3) begin tick(0,1,0,0);tick(0,1,0,0);tick(0,0,0,0);end
                for(yy=0;yy<H;yy=yy+1) begin
                    for(xx=0;xx<W;xx=xx+4) begin
                        for(n=0;n<4;n=n+1) group_data[n*10 +:10]=raw(xx+n,yy)*4;
                        tick(1,id!=3 && yy==0 && xx==0,xx==W-4,group_data);
                        // Production RAW has bubbles. Later scenes add uneven gaps.
                        if(id!=2) tick(0,0,0,0);
                        if(id==3 && xx%12==0) repeat(2) tick(0,0,0,0);
                    end
                    repeat(W/4+80) tick(0,0,0,0);
                end
                repeat(W+200) tick(0,0,0,0);
            end
            if(received!=W*H) $fatal(1,"Incomplete Bayer frame: %0d/%0d",received,W*H);
            frames=frames+1;
        end
    endtask
    initial begin
        repeat(20) tick(0,0,0,0);
        rst_n=1;
        frame(0);frame(1);frame(2);
`ifndef LEGACY_DEMOSAIC_RAM_TIES
        frame(3);frame(4);frame(5);
        // Direct mode resets with queued pixels; CSI mode resets in blanking.
        // Both reuse RAM contents from the preceding complete frames.
        if(!CSI_SOURCE) begin
            tick(0,1,0,0);
            repeat(W/2) tick(1,0,0,40'h123456789a);
        end
        rst_n=0;
        repeat(8) tick(0,0,0,0);
        rst_n=1;
        frame(0);
`endif
        if(errors!=0 && !ALLOW_ERRORS) $fatal(1,"Bayer reference errors=%0d",errors);
        if(CSI_SOURCE)
            $display("CSI_FRONTEND_QUALITY_PASS frames=%0d raw_pixels=%0d rgb_pixels=%0d",
                frames,total_raw_pixels,total_pixels);
        $display("DEMOSAIC_QUALITY_RESULT bayer=%s size=%0dx%0d frames=%0d pixels=%0d errors=%0d markers=%0d",
            BAYER,W,H,frames,total_pixels,errors,marker_errors);
        if(errors==0 && marker_errors==0) $display("DEMOSAIC_QUALITY_PASS");
        if(EDGE_AWARE_REFERENCE && (directional_edge_error!=0 || bilinear_edge_error==0))
            $fatal(1,"Directional green did not preserve the synthetic step");
        if(sharpness_checks!=0)
            $display("GREEN_EDGE_DETAIL_PASS checks=%0d bilinear_error=%0d directional_error=%0d",
                sharpness_checks,bilinear_edge_error,directional_edge_error);
        $finish;
    end
    initial begin #100000000; $fatal(1,"Bayer test timeout");end
endmodule
