`timescale 1ns/1ps
module tb_latency_display_toggle;
    localparam integer W=1280, H=280, FRAMES=8;
    reg sys_clk=0, hdmi_clk=0;
    always #10 sys_clk=~sys_clk;
    always #6.5 hdmi_clk=~hdmi_clk;
    reg rst_n=0, switch_high=0;
    reg de=0, user=0, last=0, hs=0, vs=0;
    reg [23:0] rgb=0;
    reg [3:0] effect_mode=0;
    reg sample_strobe=0, sample_valid=0;
    reg [19:0] total_us=0, isp_us=0, buffer_us=0;
    wire [23:0] toggle_rgb, shown_rgb, hidden_rgb;
    wire toggle_de, toggle_hs, toggle_vs, toggle_rd;
    wire shown_de, shown_hs, shown_vs, shown_rd;
    wire hidden_de, hidden_hs, hidden_vs, hidden_rd;
    wire [191:0] boxes={144'd0,12'd150,12'd110,12'd950,12'd900};
    integer frame_index=0, input_frame=0;
    integer pixels=0, frames=0, panel_pixels=0, hidden_panel_pixels=0;
    integer label_frames=0, extrema_checks=0, sample_count=0;
    integer assertions=0, transitions=0, request_id=0, hold_checks=0;
    integer output_x=0, output_y=0;
    reg previous_request=0;
    event switch_request;
    reg pipe_de[0:2], pipe_hs[0:2], pipe_vs[0:2];
    integer pipe_frame[0:2], pipe_x[0:2], pipe_y[0:2];
    reg [3:0] active_effect=0;

`define MIXER(NAME,LATENCY,TOGGLE,DATA,DE,HS,VS,RD) \
    hdmi_mixer #(.IMG_WIDTH(W),.IMG_HEIGHT(H),.SHOW_LATENCY(LATENCY), \
        .LATENCY_SWITCH_ENABLE(TOGGLE),.MULTI_TARGET_ENABLE(1), \
        .SHOW_CAMERA_STATUS(1),.SHOW_COLOR_TARGET(1), \
        .SHOW_EFFECT_LABEL(1)) NAME ( \
        .I_clk(hdmi_clk),.I_rst_n(rst_n),.I_video_de(de), \
        .I_video_user(user),.I_video_last(last),.I_video_hsync(hs), \
        .I_video_vsync(vs),.I_effect_mode(effect_mode),.I_effect_param(8'd0), \
        .I_debug_status(4'b1111),.I_cam_fail_index(8'd0), \
        .I_raw_stats_valid(1'b0),.I_raw_stats_data(45'd0), \
        .I_ae_readout_valid(1'b0),.I_ae_readout_data(28'd0), \
        .I_latency_show(switch_high),.I_latency_sample_strobe(sample_strobe), \
        .I_latency_sample_valid(sample_valid),.I_latency_total_us(total_us), \
        .I_latency_isp_us(isp_us),.I_latency_buffer_us(buffer_us), \
        .I_target_result_ready(1'b1),.I_target_found(1'b1), \
        .I_target_motion_mode(1'b0),.I_target_color_mode(2'd0),.I_target_xmin(12'd900), \
        .I_target_xmax(12'd950),.I_target_ymin(12'd110), \
        .I_target_ymax(12'd150),.I_target_center_x(12'd925), \
        .I_target_center_y(12'd130),.I_target_multi_valid(4'b0001), \
        .I_target_multi_hold(4'd0),.I_target_multi_boxes(boxes), \
        .I_target_multi_overflow(1'b0),.I_video_rd_data(rgb), \
        .O_video_rd_en(RD),.O_display_frame_start(),.O_hdmi_de(DE), \
        .O_hdmi_hsync(HS),.O_hdmi_vsync(VS),.O_hdmi_data(DATA))
    `MIXER(dut,1,1,toggle_rgb,toggle_de,toggle_hs,toggle_vs,toggle_rd);
    `MIXER(always_shown,1,0,shown_rgb,shown_de,shown_hs,shown_vs,shown_rd);
    `MIXER(always_hidden,0,0,hidden_rgb,hidden_de,hidden_hs,hidden_vs,hidden_rd);
`undef MIXER

    task automatic check(input bit condition,input string message_text);
        begin
            if (!condition) $fatal(1,"%s",message_text);
            assertions=assertions+1;
        end
    endtask
    function automatic bit expected_show(input integer f);
        expected_show=(f==1 || f==3 || f==5 || f==6);
    endfunction
    function automatic [3:0] frame_effect(input integer f);
        case (f)
            0: frame_effect=1;
            1: frame_effect=3;
            2: frame_effect=2;
            3: frame_effect=0;
            4: frame_effect=5;
            5: frame_effect=7;
            default: frame_effect=8;
        endcase
    endfunction
    function automatic [23:0] pixel_rgb(input integer f,xx,yy);
        pixel_rgb={8'((xx+f*11)%256),8'((yy*3+31)%256),
                   8'((xx+yy+83)%256)};
    endfunction
    function automatic [23:0] bcd(input integer value);
        bcd={4'((value/100000)%10),4'((value/10000)%10),
             4'((value/1000)%10),4'((value/100)%10),
             4'((value/10)%10),4'(value%10)};
    endfunction
    always @(posedge sys_clk) begin
        #1;
        if (!rst_n) previous_request=0;
        else begin
            if (switch_high!==previous_request) transitions=transitions+1;
            previous_request=switch_high;
        end
    end

    initial begin: switch_stimulus
        bit new_level;
        forever begin
            @switch_request;
            new_level=(request_id%2==0);
            @(negedge sys_clk); switch_high=new_level;
            repeat(100) @(negedge sys_clk);
            check(switch_high==new_level &&
                  dut.latency_switch.show_sync==new_level,
                "Maintained switch level did not synchronize into HDMI");
            check(dut.S_latency_visible==expected_show(request_id),
                "Mid-frame switch change must wait until the next frame");
            hold_checks=hold_checks+1;
        end
    end

    // Both comparison instances see identical pixels and metadata. The
    // enabled instance must equal the corresponding static reference for
    // every output pixel, including moving labels and existing overlays.
    always @(posedge hdmi_clk) begin: verify
        integer xx, yy, ff;
        bit visible, sample_panel, reset_at_edge;
        reg [23:0] expected_rgb;
        // I_rst_n is asynchronous to hdmi_clk. Capture reset before shifting
        // the reference pipe so an assertion during the #1 settle delay is
        // treated as a reset transition instead of a timing failure.
        reset_at_edge = !rst_n;
        if (reset_at_edge) begin
            for (integer p=0;p<3;p=p+1) begin
                pipe_de[p]=0; pipe_hs[p]=0; pipe_vs[p]=0;
                pipe_frame[p]=0; pipe_x[p]=0; pipe_y[p]=0;
            end
            active_effect=0;
        end else begin
            sample_panel=dut.S_latency_panel;
            xx=dut.S_x_2d; yy=dut.S_y_2d;
            for (integer p=2;p>0;p=p-1) begin
                pipe_de[p]=pipe_de[p-1]; pipe_hs[p]=pipe_hs[p-1];
                pipe_vs[p]=pipe_vs[p-1]; pipe_frame[p]=pipe_frame[p-1];
                pipe_x[p]=pipe_x[p-1]; pipe_y[p]=pipe_y[p-1];
            end
            pipe_de[0]=de; pipe_hs[0]=hs; pipe_vs[0]=vs;
            pipe_frame[0]=input_frame;
            pipe_x[0]=de ? frame_index%W : 0;
            pipe_y[0]=de ? frame_index/W : 0;
            if (user) active_effect=effect_mode;
            #1;
            // If reset asserted after this edge, the DUT outputs have already
            // been asynchronously cleared while the reference pipe contains
            // pre-reset inputs. Discard this transition and clear the pipe.
            if (!rst_n) begin
                for (integer p=0;p<3;p=p+1) begin
                    pipe_de[p]=0; pipe_hs[p]=0; pipe_vs[p]=0;
                    pipe_frame[p]=0; pipe_x[p]=0; pipe_y[p]=0;
                end
                active_effect=0;
            end
            if (reset_at_edge || !rst_n) begin
                // No video timing invariant is meaningful during reset.
            end else begin
            if (toggle_rd!==de || shown_rd!==de || hidden_rd!==de ||
                toggle_de!==pipe_de[2] || toggle_hs!==pipe_hs[2] ||
                toggle_vs!==pipe_vs[2] || shown_de!==toggle_de ||
                hidden_de!==toggle_de || shown_hs!==toggle_hs ||
                hidden_hs!==toggle_hs || shown_vs!==toggle_vs ||
                hidden_vs!==toggle_vs)
                $fatal(1,"Switch visibility changed read enable or three-clock video timing");
            if (dut.S_effect_mode!==active_effect)
                $fatal(1,"Switch visibility changed frame-boundary K1 effect selection");
            if (toggle_de) begin
                ff=pipe_frame[2];
                visible=expected_show(ff);
                if (xx!=pipe_x[2] || yy!=pipe_y[2])
                    $fatal(1,"Switch overlay shifted pixel coordinates f=%0d got=%0d,%0d expected=%0d,%0d",
                        ff,xx,yy,pipe_x[2],pipe_y[2]);
                expected_rgb=visible ? shown_rgb : hidden_rgb;
                if (toggle_rgb!==expected_rgb)
                    $fatal(1,"Panel or label mismatch f=%0d x=%0d y=%0d visible=%0b got=%h expected=%h",
                        ff,xx,yy,visible,toggle_rgb,expected_rgb);
                if (sample_panel!==(visible && xx>=864 && xx<1264 &&
                                      yy>=16 && yy<232))
                    $fatal(1,"Latency panel visibility changed within frame %0d at %0d,%0d",ff,xx,yy);
                if (sample_panel) panel_pixels=panel_pixels+1;
                if (!visible && xx>=864 && xx<1264 && yy>=16 && yy<232)
                    hidden_panel_pixels=hidden_panel_pixels+1;
                if (xx==1200 && yy==260) begin
                    if (visible) begin
                        check(dut.multi_target.label_valid==always_shown.multi_target.label_valid,
                            "Visible latency panel no longer reserves its label area");
                        if (dut.multi_target.label_valid[0])
                            check(dut.multi_target.label_x[0]==always_shown.multi_target.label_x[0] &&
                                dut.multi_target.label_y[0]==always_shown.multi_target.label_y[0],
                                "Visible label placement differs from static latency mode");
                    end else begin
                        check(dut.multi_target.label_valid[0] &&
                            dut.multi_target.label_x[0]==900 &&
                            dut.multi_target.label_y[0]==92,
                            "Hidden latency panel still prevents a label in its former area");
                    end
                    label_frames=label_frames+1;
                end
                pixels=pixels+1;
                if (xx==W-1 && yy==H-1) frames=frames+1;
            end
            end
        end
    end

    task automatic blank(input integer cycles);
        begin
            @(negedge hdmi_clk);
            de=0; user=0; last=0; hs=1; sample_strobe=0; rgb=0;
            repeat(cycles) @(negedge hdmi_clk);
            hs=0;
        end
    endtask

    initial begin: video_stimulus
        repeat(5) @(negedge sys_clk);
        rst_n=1;
        repeat(20) @(negedge sys_clk);
        check(switch_high==0 && dut.S_latency_visible==0,
            "Latency visibility must start hidden with the switch low");
        for (integer f=0;f<FRAMES;f=f+1) begin
            if (f==6 || f==7) begin
                @(negedge sys_clk); rst_n=0; switch_high=(f==6);
                repeat(6) @(negedge sys_clk);
                rst_n=1;
                repeat(20) @(negedge sys_clk);
                check(dut.S_latency_visible==0,
                    "Reset must hide the panel until a new frame, for either switch level");
            end
            input_frame=f; frame_index=0; effect_mode=frame_effect(f);
            for (integer yy=0;yy<H;yy=yy+1) begin
                for (integer xx=0;xx<W;xx=xx+1) begin
                    @(negedge hdmi_clk);
                    de=1; user=(xx==0 && yy==0); last=(xx==W-1);
                    frame_index=yy*W+xx; rgb=pixel_rgb(f,xx,yy);
                    sample_strobe=(xx==8 && yy==0);
                    if (sample_strobe) begin
                        sample_valid=1; total_us=20000+f*3000;
                        isp_us=100+f; buffer_us=total_us-isp_us;
                        sample_count=sample_count+1;
                    end
                    if (xx==200 && yy==0) begin
                        check(dut.latency_readout.u_osd.bcd_total==bcd(20000+f*3000),
                            "Latency conversion stopped while its panel was hidden");
                        check(dut.latency_readout.u_osd.min_us==(f>=6 ? 20000+f*3000 : 20000) &&
                            dut.latency_readout.u_osd.max_us==20000+f*3000,
                            "Latency extrema failed to update continuously while hidden");
                        extrema_checks=extrema_checks+1;
                    end
                    if (xx==50 && yy==10) effect_mode=4'd6;
                    if (f<5 && xx==100 && yy==20) begin
                        request_id=f; ->switch_request;
                    end
                end
                blank(12);
            end
            vs=1; blank(25); vs=0;
        end
        blank(12);
        check(frames==FRAMES && pixels==FRAMES*W*H,
            "Switch simulation did not complete all video frames");
        check(panel_pixels==4*400*216 && hidden_panel_pixels==4*400*216,
            "Full-frame visible or hidden panel coverage is incomplete");
        check(label_frames==FRAMES && extrema_checks==FRAMES && sample_count==FRAMES,
            "Missing label placement, hidden statistics, or sample checks");
        check(transitions==6 && hold_checks==5,
            "Maintained switch changes or long-hold coverage is incomplete");
        $display("LATENCY_DISPLAY_TOGGLE_PASS frames=%0d pixels=%0d shown_pixels=%0d hidden_pixels=%0d holds=%0d hidden_stats=%0d labels=%0d checks=%0d",
            frames,pixels,panel_pixels,hidden_panel_pixels,hold_checks,extrema_checks,label_frames,assertions);
        $finish;
    end
    initial begin #100000000; $fatal(1,"Latency display toggle test timeout"); end
endmodule

module anlogic_logo_rom(
    input wire I_clk,input wire [14:0] I_addr,output reg [24:0] O_pixel
);
    always @(posedge I_clk)
        O_pixel<=(I_addr<160*160) ? 25'h1234567 : 25'd0;
endmodule
