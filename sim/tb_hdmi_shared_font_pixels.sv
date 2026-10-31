`timescale 1ns/1ps
// Every pixel in each text rectangle, including one-pixel borders and
// transparent glyph backgrounds, is compared against the frozen two-font
// mixer. Source coordinate registers are injected identically to skip unused
// camera pixels; both real pixel pipelines and final output registers run.
// A separate full-raster regression checks ordinary coordinate progression.
// Legacy H=160 deliberately overlaps the bottom panel and counter.
// Restrict the frozen-source proof to unchanged fonts, legacy overlays and
// core label placement. Disable the relocated HUD on both sides; its new
// pixels/priority are checked by tb_fruit_font_pixels and the independent
// tb_latency_display_toggle oracle, rather than copying new UI into golden RTL.
module tb_hdmi_shared_font_pixels #(
    parameter integer W=1280, H=192, FRAMES=13, MULTI=1
);
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,de=0,user=0,last=0,hs=0,vs=0;
    reg [3:0] mode=0;
    reg [23:0] rgb=0;
    reg cnn_enable=0,cnn_valid=0,latency_strobe=0,latency_valid=0;
    reg [2:0] cnn_class=1;
    reg [31:0] runtime=0;
    reg [19:0] total_us=0,isp_us=0,buffer_us=0;
    reg [1:0] color=0;
    reg [191:0] boxes=0;
    reg [7:0] shapes=8'b00_11_10_01;
    reg [11:0] injected_x=0,injected_y=0;
    wire [23:0] got,want;
    wire gde,wde,ghs,whs,gvs,wvs,grd,wrd,gsof,wsof;
`define MIXER_PORTS(DATA,DE,HS,VS,RD,SOF) \
        .I_clk(clk),.I_rst_n(rst_n),.I_video_vsync(vs),.I_video_hsync(hs), \
        .I_video_de(de),.I_video_user(user),.I_video_last(last), \
        .I_effect_mode(mode),.I_effect_param(8'd0), \
        .I_debug_status(4'hf),.I_cam_fail_index(8'h89), \
        .I_raw_stats_valid(1'b0),.I_raw_stats_data(45'd0), \
        .I_ae_readout_valid(1'b0),.I_ae_readout_data(28'd0), \
        .I_latency_sample_strobe(latency_strobe),.I_latency_show(1'b1), \
        .I_latency_sample_valid(latency_valid),.I_latency_total_us(total_us), \
        .I_latency_isp_us(isp_us),.I_latency_buffer_us(buffer_us), \
        .I_cnn_enable(cnn_enable),.I_cnn_result_valid(cnn_valid), \
        .I_cnn_class(cnn_class),.I_hand_box_valid(1'b1), \
        .I_hand_box({12'd150,12'd110,12'd700,12'd620}), \
        .I_resnet_probe_status(runtime),.I_video_rd_data(rgb), \
        .I_target_result_ready(1'b1),.I_target_found(1'b1), \
        .I_target_motion_mode(1'b0),.I_target_color_mode(color), \
        .I_target_xmin(12'd350),.I_target_xmax(12'd570), \
        .I_target_ymin(12'd100),.I_target_ymax(12'd150), \
        .I_target_center_x(12'd1234),.I_target_center_y(12'd999), \
        .I_target_multi_valid(4'hf),.I_target_multi_hold(4'ha), \
        .I_target_multi_boxes(boxes),.I_target_multi_shapes(shapes), \
        .I_target_multi_overflow(1'b1),.O_hdmi_data(DATA),.O_hdmi_de(DE), \
        .O_hdmi_hsync(HS),.O_hdmi_vsync(VS),.O_video_rd_en(RD), \
        .O_display_frame_start(SOF)
    hdmi_mixer #(.IMG_WIDTH(W),.IMG_HEIGHT(H),.MULTI_TARGET_ENABLE(MULTI),
        .SHOW_COLOR_TARGET(1),.SHOW_CAMERA_STATUS(1),.SHOW_EFFECT_LABEL(0),
        .SHOW_RAW_STATS(MULTI),.SHOW_LATENCY(0),.SHOW_CNN(MULTI),
        .HANDCNN_DYNAMIC_ROI(1),.FRUIT_CNN(1),.SHOW_RESNET_RUNTIME(1)) dut(
        `MIXER_PORTS(got,gde,ghs,gvs,grd,gsof)
    );
    hdmi_mixer_reference #(.IMG_WIDTH(W),.IMG_HEIGHT(H),.MULTI_TARGET_ENABLE(MULTI),
        .SHOW_COLOR_TARGET(1),.SHOW_CAMERA_STATUS(1),.SHOW_EFFECT_LABEL(0),
        .SHOW_RAW_STATS(MULTI),.SHOW_LATENCY(0),.SHOW_CNN(MULTI),
        .HANDCNN_DYNAMIC_ROI(1),.FRUIT_CNN(1),.SHOW_RESNET_RUNTIME(1)) reference(
        `MIXER_PORTS(want,wde,whs,wvs,wrd,wsof)
    );
`undef MIXER_PORTS
    integer f,xx,yy,s,checks=0,pixels=0,counter_pixels=0;
    integer effect_pixels=0,cnn_pixels=0,latency_pixels=0,legacy_overlap=0;
    integer runtime_state;
    always @(posedge clk) begin
        #1;
        if(rst_n) begin
            checks=checks+1;
            if({got,gde,ghs,gvs,grd,gsof} !== {want,wde,whs,wvs,wrd,wsof})
                $fatal(1,"Shared font changed pixel/control W=%0d H=%0d multi=%0d frame=%0d scan=%0d,%0d got=%h want=%h",
                    W,H,MULTI,f,dut.S_x_2d,dut.S_y_2d,got,want);
            if(dut.S_pf_valid && dut.S_pf_on !== reference.S_pf_on)
                $fatal(1,"Original counter glyph changed W=%0d H=%0d",W,H);
            if(gde) pixels=pixels+1;
            if(dut.S_video_de_2d) begin
                if(dut.S_pf_valid) counter_pixels=counter_pixels+1;
                if(dut.S_effect_panel_on) effect_pixels=effect_pixels+1;
                if(dut.S_cnn_panel_on) cnn_pixels=cnn_pixels+1;
                if(dut.S_latency_panel) latency_pixels=latency_pixels+1;
                if(MULTI==0 && dut.S_target_panel_on && dut.S_pf_valid)
                    legacy_overlap=legacy_overlap+1;
            end
        end
    end
    task blank(input integer cycles);
        begin
            @(negedge clk);
            de=0;user=0;last=0;hs=1;latency_strobe=0;cnn_valid=0;
            repeat(cycles) @(negedge clk);
            hs=0;
        end
    endtask
    task probe_rectangle(input integer left,top,width,height);
        integer probe_x,probe_y;
        begin
            for(probe_y=top-1;probe_y<=top+height;probe_y=probe_y+1)
                for(probe_x=left-1;probe_x<=left+width;probe_x=probe_x+1)
                    if(probe_x>=0 && probe_x<W && probe_y>=0 && probe_y<H) begin
                        @(negedge clk);
                        injected_x=12'(probe_x);injected_y=12'(probe_y);
                        de=1;user=0;last=probe_x==W-1;
                        rgb={8'(probe_x+f*11),8'(probe_y*3+31),8'(probe_x+probe_y+83)};
                    end
            blank(3);
        end
    endtask
    initial begin
        force dut.S_x=injected_x;force reference.S_x=injected_x;
        force dut.S_y=injected_y;force reference.S_y=injected_y;
        blank(5);rst_n=1;
        @(negedge clk);
        // Exercise every high decimal position and the 999999 -> 000000 carry.
        dut.S_cnt_d0=8;reference.S_cnt_d0=8;
        dut.S_cnt_d1=9;reference.S_cnt_d1=9;
        dut.S_cnt_d2=9;reference.S_cnt_d2=9;
        dut.S_cnt_d3=9;reference.S_cnt_d3=9;
        dut.S_cnt_d4=9;reference.S_cnt_d4=9;
        dut.S_cnt_d5=9;reference.S_cnt_d5=9;
        for(f=0;f<FRAMES;f=f+1) begin
            @(negedge clk);
            mode=f%13;color=f%3;
            cnn_enable=MULTI!=0 && f!=0;
            cnn_class=3'(1+f%6);
            runtime=32'h02040000;
            runtime_state=f%8;
            case(runtime_state)
                0: runtime=32'h00000000; // WAIT MODEL
                1: runtime=32'h06000000; // CAPTURE
                2: runtime=32'h0e000000; // CAP RETRY
                3: runtime=32'h12000000; // RUN OP
                4: runtime=32'h02000000; // WAIT RESULT
                5: runtime=32'h020c0000; // LOW CONF
                6: runtime=32'h02040000; // RESULT READY
                7: runtime=32'h22040000; // DDR ERROR
            endcase
            runtime[15:0]=16'h1234+f;
            total_us=f%3==0 ? 20'd128001 : 20'd123456;
            isp_us=20'd23456+f;buffer_us=20'd100000+f;
            latency_valid=f%4!=0;
            for(s=0;s<4;s=s+1)
                boxes[s*48+:48]={12'd150,12'd110,12'(700+s*150),12'(620+s*150)};
            // Both synchronizer stages settle before the frame configuration.
            repeat(5) @(negedge clk);
            @(negedge clk);
            injected_x=0;injected_y=0;de=1;user=1;last=0;
            latency_strobe=1;cnn_valid=1;rgb=0;
            blank(1100);
            probe_rectangle(192,80,240,16); // Original effect area restores background.
            probe_rectangle(16,16,256,32);  // Fruit classes and runtime states.
            probe_rectangle(375,120,200,24);// Chinese prefix and six digits.
            probe_rectangle(16,H-32,MULTI!=0 ? 240 : 368,16);
            if(f<3) begin
                probe_rectangle(984,16,280,64); // Original latency area restores background.
                probe_rectangle(0,0,160,160);   // Logo and overlapping panels.
                probe_rectangle(496,176,768,16);// Diagnostic header priority.
            end
            vs=1;blank(8);vs=0;
        end
        blank(8);
        if(pixels<FRAMES*8000 || counter_pixels==0 ||
            (MULTI!=0 && cnn_pixels==0) ||
            (MULTI==0 && legacy_overlap==0))
            $fatal(1,"Incomplete font/priority coverage W=%0d H=%0d pixels=%0d overlap=%0d",
                W,H,pixels,legacy_overlap);
        $display("HDMI_SHARED_FONT_PIXELS_PASS W=%0d H=%0d multi=%0d configs=%0d checks=%0d region_pixels=%0d counter=%0d effect=%0d cnn=%0d latency=%0d legacy_overlap=%0d",
            W,H,MULTI,FRAMES,checks,pixels,counter_pixels,effect_pixels,
            cnn_pixels,latency_pixels,legacy_overlap);
        $finish;
    end
    initial begin #80000000;$fatal(1,"Shared font pixel timeout");end
endmodule
