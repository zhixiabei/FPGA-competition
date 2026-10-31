`timescale 1ns/1ps
// Compare the real output pipelines with the frozen pre-repair mixer.
// Inject only the identical source x/y counters to visit text rectangles
// efficiently; the stage-one/stage-two coordinates and controls still run.
// The separate full-raster and top-level frame tests cover normal scanning.
// Restrict the frozen-source proof to unchanged fonts, legacy CNN/runtime
// overlays and core label placement. Disable the relocated HUD on both sides;
// tb_fruit_font_pixels and the independent tb_latency_display_toggle oracle
// verify its new placement, pixels and priority without rewriting golden RTL.
module tb_hdmi_runtime_equivalence #(
    parameter integer PROBE=0, RUNTIME=1, FRUIT=1, DEBUG=0
);
    localparam integer W=1280, H=720;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,de=0,user=0,last=0,hs=0,vs=0;
    reg [11:0] injected_x=0,injected_y=0;
    reg [3:0] mode=0;
    reg [3:0] debug_status=4'hf;
    reg [23:0] rgb=0;
    reg cnn_enable=0,cnn_valid=0,latency_strobe=0,latency_valid=0;
    reg [2:0] cnn_class=1;
    reg [31:0] runtime=0;
    reg [19:0] total_us=0,isp_us=0,buffer_us=0;
    reg [1:0] color=0;
    reg motion=0;
    reg [191:0] boxes=0;
    wire [23:0] got,want;
    wire gde,wde,ghs,whs,gvs,wvs,grd,wrd,gsof,wsof;
`define MIXER_PORTS(DATA,DE,HS,VS,RD,SOF) \
        .I_clk(clk),.I_rst_n(rst_n),.I_video_vsync(vs),.I_video_hsync(hs), \
        .I_video_de(de),.I_video_user(user),.I_video_last(last), \
        .I_effect_mode(mode),.I_effect_param(8'd0), \
        .I_debug_status(debug_status),.I_cam_fail_index(8'h89), \
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
        .I_target_motion_mode(motion),.I_target_color_mode(color), \
        .I_target_xmin(12'd350),.I_target_xmax(12'd570), \
        .I_target_ymin(12'd100),.I_target_ymax(12'd150), \
        .I_target_center_x(12'd1234),.I_target_center_y(12'd999), \
        .I_target_multi_valid(4'hf),.I_target_multi_hold(4'ha), \
        .I_target_multi_boxes(boxes),.I_target_multi_shapes(8'b00_11_10_01), \
        .I_target_multi_overflow(1'b1),.O_hdmi_data(DATA),.O_hdmi_de(DE), \
        .O_hdmi_hsync(HS),.O_hdmi_vsync(VS),.O_video_rd_en(RD), \
        .O_display_frame_start(SOF)
    hdmi_mixer #(.IMG_WIDTH(W),.IMG_HEIGHT(H),.DEBUG_MODE(DEBUG),.MULTI_TARGET_ENABLE(1),
        .SHOW_COLOR_TARGET(1),.SHOW_CAMERA_STATUS(1),.SHOW_EFFECT_LABEL(0),
        .SHOW_RAW_STATS(1),.SHOW_LATENCY(0),.SHOW_CNN(1),
        .HANDCNN_DYNAMIC_ROI(1),.FRUIT_CNN(FRUIT),
        .SHOW_RESNET_PROBE(PROBE),.SHOW_RESNET_RUNTIME(RUNTIME)) dut(
        `MIXER_PORTS(got,gde,ghs,gvs,grd,gsof)
    );
    hdmi_mixer_reference #(.IMG_WIDTH(W),.IMG_HEIGHT(H),.DEBUG_MODE(DEBUG),.MULTI_TARGET_ENABLE(1),
        .SHOW_COLOR_TARGET(1),.SHOW_CAMERA_STATUS(1),.SHOW_EFFECT_LABEL(0),
        .SHOW_RAW_STATS(1),.SHOW_LATENCY(0),.SHOW_CNN(1),
        .HANDCNN_DYNAMIC_ROI(1),.FRUIT_CNN(FRUIT),
        .SHOW_RESNET_PROBE(PROBE),.SHOW_RESNET_RUNTIME(RUNTIME)) reference(
        `MIXER_PORTS(want,wde,whs,wvs,wrd,wsof)
    );
`undef MIXER_PORTS
    integer checks=0,pixels=0,char_checks=0,flag_checks=0;
    integer status_vectors=0,midframe_updates=0,switches=0;
    integer i,j,x,y,s,state_index,hex_index,scan_index;
    reg [31:0] lfsr=32'h74a92d31;
    reg [7:0] seen_states=0;
    reg [15:0] seen_hex=0;
    reg [31:0] previous_runtime=0;
    reg [26:0] held_output=0;
    reg have_output=0;
    integer hold_checks=0,reset_checks=0;
    function integer runtime_state(input [31:0] value);
        begin
            if(value[29]) runtime_state=0;
            else if(!value[25]) runtime_state=1;
            else if(value[26]) runtime_state=value[27] ? 2 : 3;
            else if(value[28]) runtime_state=4;
            else if(!value[18]) runtime_state=5;
            else if(value[21:19]==1) runtime_state=6;
            else runtime_state=7;
        end
    endfunction
    function [31:0] canonical_status(input integer state);
        begin
            case(state)
                0: canonical_status=32'h22040000;
                1: canonical_status=32'h00000000;
                2: canonical_status=32'h0e000000;
                3: canonical_status=32'h06000000;
                4: canonical_status=32'h12000000;
                5: canonical_status=32'h02000000;
                6: canonical_status=32'h020c0000;
                default: canonical_status=32'h02040000;
            endcase
        end
    endfunction
    always @(posedge clk) begin
        #1;
        if(rst_n) begin
            checks=checks+1;
            if({got,gde,ghs,gvs,grd,gsof} !== {want,wde,whs,wvs,wrd,wsof})
                $fatal(1,"HDMI runtime pixel/control mismatch probe=%0d runtime=%0d fruit=%0d xy=%0d,%0d status=%h got=%h want=%h",
                    PROBE,RUNTIME,FRUIT,dut.S_x_2d,dut.S_y_2d,runtime,got,want);
            held_output={got,gde,ghs,gvs};have_output=1;
            flag_checks=flag_checks+1;
            if(dut.S_cnn_runtime_row_2d !== (reference.S_y_2d>=32))
                $fatal(1,"Runtime row predicate lost coordinate alignment y=%0d",
                    reference.S_y_2d);
            if(dut.S_cnn_char_index<16) begin
                char_checks=char_checks+1;
                if(dut.S_cnn_char !== reference.S_cnn_char)
                    $fatal(1,"Runtime character mismatch probe=%0d runtime=%0d row=%0d col=%0d status=%h got=%h want=%h",
                        PROBE,RUNTIME,reference.S_y_2d,dut.S_cnn_char_index,
                        runtime,dut.S_cnn_char,reference.S_cnn_char);
            end
            if(gde) pixels=pixels+1;
            if(RUNTIME && dut.S_cnn_runtime_row_2d && dut.S_cnn_char_index<16) begin
                seen_states[runtime_state(runtime)]=1'b1;
                if(runtime[28] && dut.S_cnn_char_index==10)
                    seen_hex[runtime[15:12]]=1'b1;
            end
            if(runtime!=previous_runtime && !user)
                midframe_updates=midframe_updates+1;
            previous_runtime=runtime;
        end
    end
    // Changing status/control inputs between clocks must not reach RGB
    // through the newly combinational final selection.
    always @(negedge clk) begin
        #2;
        if(rst_n && have_output) begin
            hold_checks=hold_checks+1;
            if({got,gde,ghs,gvs} !== held_output)
                $fatal(1,"HDMI output changed between registered edges debug=%0d",DEBUG);
        end
    end
    always @(negedge rst_n) begin
        have_output=0;
        #1;
        reset_checks=reset_checks+1;
        if({got,gde,ghs,gvs} !== 27'd0 || {want,wde,whs,wvs} !== 27'd0)
            $fatal(1,"HDMI asynchronous reset changed output behavior debug=%0d",DEBUG);
    end
    task blank(input integer cycles);
        begin
            @(negedge clk);
            de=0;user=0;last=0;hs=1;latency_strobe=0;cnn_valid=0;
            repeat(cycles) @(negedge clk);
            hs=0;
        end
    endtask
    task pixel(input integer px,py);
        begin
            @(negedge clk);
            injected_x=12'(px);injected_y=12'(py);
            de=1;user=0;last=px==W-1;
            rgb={8'(px+17),8'(py*3+31),8'(px+py+83)};
        end
    endtask
    task rectangle(input integer left,top,width,height);
        integer rx,ry;
        begin
            for(ry=top;ry<top+height;ry=ry+1)
                for(rx=left;rx<left+width;rx=rx+1) pixel(rx,ry);
            blank(3);
        end
    endtask
    task begin_frame(input integer enabled,effect,class_code);
        begin
            blank(2);
            cnn_enable=enabled!=0;mode=4'(effect);cnn_class=3'(class_code);
            repeat(5) @(negedge clk);
            injected_x=0;injected_y=0;de=1;user=1;last=0;
            latency_strobe=1;cnn_valid=1;
            blank(140);
            if(dut.S_cnn_visible !== (enabled!=0))
                $fatal(1,"CNN switch did not settle at frame boundary");
            switches=switches+1;
        end
    endtask
    initial begin
        force dut.S_x=injected_x;force reference.S_x=injected_x;
        force dut.S_y=injected_y;force reference.S_y=injected_y;
        for(s=0;s<4;s=s+1)
            boxes[s*48+:48]={12'd150,12'd110,12'(700+s*150),12'(620+s*150)};
        blank(5);rst_n=1;
        begin_frame(1,0,2);

        if(DEBUG!=0) begin
            for(scan_index=0;scan_index<12000;scan_index=scan_index+1) begin
                @(negedge clk);
                lfsr={lfsr[30:0],lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
                debug_status=4'(scan_index);
                injected_x=12'(scan_index%4096);
                injected_y=12'(scan_index/17);
                rgb=lfsr[23:0];runtime=lfsr;
                de=scan_index%17!=0;user=0;last=scan_index%37==0;
                hs=scan_index%19==0;vs=scan_index%257==0;
            end
            blank(8);
            @(negedge clk);rst_n=0;
            blank(4);rst_n=1;
            begin_frame(0,0,2);
            rectangle(0,0,1024,2);
            blank(8);
            if(checks<14000 || hold_checks<14000 || reset_checks<1)
                $fatal(1,"Incomplete debug/reset coverage checks=%0d holds=%0d resets=%0d",
                    checks,hold_checks,reset_checks);
            $display("HDMI_DEBUG_EQUIVALENCE_PASS debug=%0d checks=%0d pixels=%0d holds=%0d resets=%0d",
                DEBUG,checks,pixels,hold_checks,reset_checks);
            $finish;
        end

        // All glyph pixels for all eight canonical status strings.
        for(state_index=0;state_index<8;state_index=state_index+1) begin
            @(negedge clk);
            runtime=canonical_status(state_index)|32'h0000abcd;
            rectangle(16,32,256,16);
        end

        // Exhaust all status-priority flag combinations and confidence codes.
        // Four clocks per character permit the actual coordinate pipeline to
        // visit every character for each stable status word.
        for(i=0;i<512;i=i+1) begin
            @(negedge clk);
            runtime=32'(i*73)^32'h00005678;
            runtime[29]=i[0];runtime[25]=i[1];runtime[26]=i[2];
            runtime[27]=i[3];runtime[28]=i[4];runtime[18]=i[5];
            runtime[21:19]=i[8:6];
            for(j=0;j<16;j=j+1)
                repeat(4) pixel(16+j*16+((i+j)&15),32+((i+j)&15));
            status_vectors=status_vectors+1;
        end

        // Every hexadecimal digit in both opcode and low-byte overrides,
        // including an error state that takes precedence over RUN OP.
        for(hex_index=0;hex_index<16;hex_index=hex_index+1) begin
            @(negedge clk);
            runtime=canonical_status(4)|32'h20000000;
            runtime[15:0]={4'(hex_index),4'(15-hex_index),
                4'(hex_index),4'(15-hex_index)};
            rectangle(176,32,32,16);
            rectangle(240,32,32,16);
        end

        // Both CNN rows, their one-pixel borders, all fruit/hand classes,
        // and the wider probe panel's unused runtime columns.
        for(i=1;i<=6;i=i+1) begin
            begin_frame(1,i,i);
            runtime=canonical_status(7)|32'h00005a5a;
            rectangle(15,15,PROBE!=0 ? 322 : 258,RUNTIME!=0 ? 34 : 18);
        end
        for(i=0;i<13;i=i+1) begin
            begin_frame(i%2,i,1+i%6);
            color=2'(i%3);motion=i[0];
            // The original effect rectangle now restores background.
            rectangle(191,79,242,18);
        end

        // Unchanged counter, Logo and target overlays remain on their original
        // pixel beat while the CNN switch changes in both directions.
        begin_frame(0,12,6);
        rectangle(0,0,160,160);
        rectangle(374,119,202,26);
        rectangle(15,H-33,242,18);
        for(i=0;i<3;i=i+1) begin
            @(negedge clk);
            latency_valid=i!=0;total_us=i==2 ? 20'd128001 : 20'd123456;
            isp_us=20'd23456;buffer_us=20'd100000;latency_strobe=1;
            blank(100);
            // Disabled latency leaves its original rectangle as background.
            rectangle(984,16,280,64);
        end
        begin_frame(1,6,3);
        for(scan_index=0;scan_index<12000;scan_index=scan_index+1) begin
            @(negedge clk);
            lfsr={lfsr[30:0],lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
            runtime=lfsr;
            // Alternate runtime/text rows with high coordinate bits. Status
            // changes every beat rather than being latched once per frame.
            injected_x=12'(16+(scan_index%20)*16+(scan_index&15));
            case(scan_index%8)
                0: injected_y=15;
                1: injected_y=16;
                2: injected_y=31;
                3: injected_y=32;
                4: injected_y=47;
                5: injected_y=48;
                6: injected_y=1024;
                default: injected_y=4095;
            endcase
            de=scan_index%17!=0;user=0;last=scan_index%37==0;
            hs=scan_index%19==0;vs=scan_index%257==0;
            rgb=lfsr[23:0];
            if(scan_index%503==0) cnn_enable=~cnn_enable;
        end
        blank(8);
        // Reset with a second-row pixel in flight, then restart at row zero.
        @(negedge clk);rst_n=0;
        blank(4);rst_n=1;
        begin_frame(1,0,2);
        rectangle(15,30,258,4);
        blank(8);
        if(status_vectors!=512 || midframe_updates<12000 || switches<20 ||
            pixels<170000 || char_checks<100000 || flag_checks!=checks ||
            hold_checks<170000 || reset_checks<1 ||
            (RUNTIME && (seen_states!=8'hff || seen_hex!=16'hffff)))
            $fatal(1,"Incomplete runtime coverage vectors=%0d updates=%0d switches=%0d pixels=%0d chars=%0d states=%h hex=%h",
                status_vectors,midframe_updates,switches,pixels,char_checks,
                seen_states,seen_hex);
        $display("HDMI_RUNTIME_EQUIVALENCE_PASS probe=%0d runtime=%0d fruit=%0d checks=%0d pixels=%0d chars=%0d status_vectors=%0d midframe_updates=%0d switches=%0d states=%h hex=%h holds=%0d resets=%0d",
            PROBE,RUNTIME,FRUIT,checks,pixels,char_checks,status_vectors,
            midframe_updates,switches,seen_states,seen_hex,hold_checks,reset_checks);
        $finish;
    end
    initial begin #30000000;$fatal(1,"HDMI runtime equivalence timeout");end
endmodule
