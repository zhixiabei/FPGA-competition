`timescale 1ns/1ps
// Real asynchronous configuration mailbox, effects, mixer and overlay logic.
// The camera/DDR path is replaced by a known stream with line blanking.
module tb_display_effects_mixer;
    localparam integer W = 576;
    localparam integer H = 224;
    localparam integer PLAN_FRAMES = 15;
    reg src_clk = 0;
    reg hdmi_clk = 0;
    always #10 src_clk = ~src_clk;
    always #6.667 hdmi_clk = ~hdmi_clk;
    reg rst_n = 0;
    reg [11:0] source_config = {4'd0, 8'd128};
    wire [11:0] requested_config;
    bit published [0:4095];
    reg [11:0] last_snapshot = 0;
    integer snapshots = 0;
    reg de = 0, user = 0, last = 0, hs = 0, vs = 0;
    reg [23:0] rgb = 0;
    wire rd, out_de, out_hs, out_vs, frame_start;
    wire [23:0] out_rgb;
    reg [3:0] planned_mode = 0;
    reg [7:0] planned_param = 128;
    reg [3:0] active_mode = 0;
    reg [7:0] active_param = 128;
    reg pipe_de [0:2];
    reg pipe_hs [0:2];
    reg pipe_vs [0:2];
    reg pipe_user [0:2];
    reg [23:0] pipe_rgb [0:2];
    reg [23:0] pipe_native [0:2];
    integer pipe_x [0:2];
    integer pipe_y [0:2];
    integer scan_x = 0, scan_y = 0;
    integer pixels = 0, frames = 0, first_pixels = 0;
    integer osd_pixels = 0, box_pixels = 0, status_pixels = 0;
    integer changed_pixels = 0, ignored_parameter_frames = 0;
    integer requests = 0;
    integer mode_pixels [0:4];
    integer mode_osd_pixels [0:4];
    integer mode_box_pixels [0:4];
    integer mode_status_pixels [0:4];
    integer mode_label_pixels [0:4];
    integer label_checks = 0, label_glyphs = 0;
    integer removed_parameter_checks = 0;

    camera_diag_cdc #(.WIDTH(12)) config_cdc (
        .I_src_clk(src_clk), .I_dst_clk(hdmi_clk), .I_rst_n(rst_n),
        .I_src_data(source_config), .O_dst_data(requested_config)
    );
    hdmi_mixer #(.IMG_WIDTH(W), .IMG_HEIGHT(H),
        .SHOW_CAMERA_STATUS(1), .SHOW_COLOR_TARGET(1), .SHOW_EFFECT_LABEL(1)) dut (
        .I_clk(hdmi_clk), .I_rst_n(rst_n),
        .I_video_vsync(vs), .I_video_hsync(hs), .I_video_de(de),
        .I_video_user(user), .I_video_last(last),
        .I_effect_mode(requested_config[11:8]),
        .I_effect_param(requested_config[7:0]),
        .I_debug_status(4'b1111), .I_cam_fail_index(8'd0),
        .I_raw_stats_valid(1'b0), .I_raw_stats_data(45'd0),
        .I_ae_readout_valid(1'b0), .I_ae_readout_data(28'd0),
        .I_latency_sample_strobe(1'b0), .I_latency_sample_valid(1'b0),
        .I_latency_total_us(20'd0), .I_latency_isp_us(20'd0),
        .I_latency_buffer_us(20'd0),
        .O_video_rd_en(rd), .O_display_frame_start(frame_start),
        .I_video_rd_data(rgb),
        .I_target_result_ready(1'b1), .I_target_found(1'b1),
        .I_target_motion_mode(1'b1),
        .I_target_xmin(12'd180), .I_target_xmax(12'd279),
        .I_target_ymin(12'd170), .I_target_ymax(12'd189),
        .I_target_center_x(12'd229), .I_target_center_y(12'd179),
        .O_hdmi_vsync(out_vs), .O_hdmi_hsync(out_hs),
        .O_hdmi_de(out_de), .O_hdmi_data(out_rgb)
    );

    function automatic integer gamma_channel(input integer value);
        integer x0, x1, y0, y1;
        begin
            // Independent interpolation of the documented tone-curve anchors.
            if (value<16) begin x0=0; x1=16; y0=0; y1=23; end
            else if (value<32) begin x0=16; x1=32; y0=23; y1=44; end
            else if (value<64) begin x0=32; x1=64; y0=44; y1=80; end
            else if (value<96) begin x0=64; x1=96; y0=80; y1=104; end
            else if (value<128) begin x0=96; x1=128; y0=104; y1=128; end
            else if (value<160) begin x0=128; x1=160; y0=128; y1=152; end
            else if (value<192) begin x0=160; x1=192; y0=152; y1=180; end
            else if (value<224) begin x0=192; x1=224; y0=180; y1=210; end
            else if (value<240) begin x0=224; x1=240; y0=210; y1=232; end
            else begin x0=240; x1=255; y0=232; y1=255; end
            gamma_channel = y0 + ((value-x0)*(y1-y0)+(x1-x0)/2)/(x1-x0);
        end
    endfunction

    function automatic [23:0] expected_pixel(input [23:0] value,
                                            input [3:0] mode);
        integer r, g, b, y;
        begin
            r = value[23:16]; g = value[15:8]; b = value[7:0];
            y = (77*r + 150*g + 29*b + 128) / 256;
            case (mode)
                1: begin r=y; g=y; b=y; end
                2,4: begin r=r; g=g; b=b; end
                3: begin r=255-r; g=255-g; b=255-b; end
                default: begin r=gamma_channel(r); g=gamma_channel(g); b=gamma_channel(b); end
            endcase
            expected_pixel = {8'(r), 8'(g), 8'(b)};
        end
    endfunction

    function automatic [11:0] frame_config(input integer frame_index);
        begin
            frame_config = {4'(frame_index%5),
                frame_index<5 ? 8'd128 : frame_index<10 ? 8'd0 : 8'd255};
        end
    endfunction

    function automatic [7:0] label_char(input [3:0] mode,
                                        input integer column);
        reg [95:0] name;
        begin
            case (mode)
                0: name = "COLOR GAMMA ";
                1: name = "GRAYSCALE   ";
                2: name = "SCHARR EDGE ";
                3: name = "NEGATIVE    ";
                4: name = "EMBOSS      ";
                default: name = "COLOR GAMMA ";
            endcase
            label_char = " ";
            if (column == 0) label_char = "0" + mode/10;
            else if (column == 1) label_char = "0" + mode%10;
            else if (column >= 3 && column <= 14)
                label_char = name[95-8*(column-3) -:8];
        end
    endfunction

    wire [7:0] reference_label_char =
        label_char(active_mode,(dut.S_x_2d-192)/16);
    wire [3:0] reference_label_row = dut.S_y_2d-80;
    wire [15:0] reference_label_bits;
    osd_char_lib reference_label_font (
        .I_char(reference_label_char), .I_row(reference_label_row),
        .O_row_bits(reference_label_bits)
    );

    task automatic publish(input [3:0] mode, input [7:0] setting);
        begin
            @(negedge src_clk);
            published[{mode, setting}] = 1;
            source_config = {mode, setting};
            requests = requests + 1;
        end
    endtask

    task automatic wait_config(input [11:0] expected);
        integer count;
        begin
            count = 0;
            while (requested_config !== expected && count < 160) begin
                @(negedge hdmi_clk);
                count = count + 1;
            end
            if (requested_config !== expected)
                $fatal(1, "Configuration mailbox did not converge to %h", expected);
        end
    endtask

    always @(posedge hdmi_clk) begin
        #1;
        if (rst_n) begin
            if (!published[requested_config])
                $fatal(1, "Mailbox produced a mixed mode/parameter snapshot %h", requested_config);
            if (requested_config !== last_snapshot) begin
                snapshots = snapshots + 1;
                last_snapshot = requested_config;
            end
        end else begin
            last_snapshot = 0;
        end
    end

    always @(posedge hdmi_clk) begin: verify_video
        bit sample_osd, sample_text, sample_frame_start;
        bit panel_on, box_on, cross_on, status_on, effect_panel, effect_text;
        integer x, y;
        reg [23:0] sample_osd_color, sample_native, expected_rgb;
        if (!rst_n) begin
            active_mode = 0; active_param = 128; scan_x = 0; scan_y = 0;
            for (integer i=0; i<3; i=i+1) begin
                pipe_de[i]=0; pipe_hs[i]=0; pipe_vs[i]=0; pipe_user[i]=0;
                pipe_rgb[i]=0; pipe_native[i]=0; pipe_x[i]=0; pipe_y[i]=0;
            end
        end else begin
            sample_osd = dut.S_osd_hit;
            sample_osd_color = dut.S_osd_color;
            sample_text = dut.S_target_text_on;
            sample_frame_start = frame_start;
            sample_native = dut.S_video_data_2d;
            x = dut.S_x_2d; y = dut.S_y_2d;
            for (integer i=2; i>0; i=i-1) begin
                pipe_de[i]=pipe_de[i-1]; pipe_hs[i]=pipe_hs[i-1];
                pipe_vs[i]=pipe_vs[i-1]; pipe_user[i]=pipe_user[i-1];
                pipe_rgb[i]=pipe_rgb[i-1]; pipe_native[i]=pipe_native[i-1];
                pipe_x[i]=pipe_x[i-1]; pipe_y[i]=pipe_y[i-1];
            end
            if (user) begin
                if (requested_config !== {planned_mode, planned_param})
                    $fatal(1, "Unexpected requested configuration at frame start");
                active_mode = requested_config[11:8];
                active_param = requested_config[7:0];
                scan_x=0; scan_y=0;
            end
            pipe_de[0]=de; pipe_hs[0]=hs; pipe_vs[0]=vs; pipe_user[0]=user;
            pipe_rgb[0]=rgb;
            pipe_native[0]=expected_pixel(rgb, active_mode);
            pipe_x[0]=scan_x; pipe_y[0]=scan_y;
            if (de) begin
                if (last) begin
                    scan_x=0;
                    scan_y=scan_y==H-1 ? 0 : scan_y+1;
                end else scan_x=scan_x+1;
            end
            if (pipe_de[2]) begin
                if (x!=pipe_x[2] || y!=pipe_y[2])
                    $fatal(1, "Coordinates lost three-clock alignment at %0d,%0d", x,y);
                if (sample_native !== pipe_native[2])
                    $fatal(1, "Frame effect changed early/late at %0d,%0d: want=%h got=%h",
                           x,y,pipe_native[2],sample_native);
            end
            if (sample_frame_start !== (pipe_de[2] && pipe_user[2]))
                $fatal(1, "Display frame-start event shifted");
            panel_on=pipe_de[2] && x>=16 && x<384 && y>=H-32 && y<H-16;
            box_on=pipe_de[2] && x>=180 && x<=279 && y>=170 && y<=189 &&
                (x<182 || x>277 || y<172 || y>187);
            cross_on=pipe_de[2] &&
                ((x>=228 && x<=230 && y>=173 && y<=185) ||
                 (y>=178 && y<=180 && x>=223 && x<=235));
            status_on=pipe_de[2] && y>=16 && y<32 &&
                ((x>=192 && x<208) || (x>=216 && x<232) ||
                 (x>=240 && x<256) || (x>=264 && x<280));
            effect_panel=pipe_de[2] && x>=192 && x<432 && y>=80 && y<96;
            effect_text=reference_label_bits[15-((x-192)%16)];
            if (dut.S_effect_panel_on !== effect_panel)
                $fatal(1,"Effect panel bounds mismatch at %0d,%0d",x,y);
            if (effect_panel) begin
                if (dut.S_effect_char !== reference_label_char ||
                    dut.S_effect_text_on !== effect_text)
                    $fatal(1,"Effect label mismatch mode=%0d param=%0d column=%0d char=%h want=%h",
                        active_mode,active_param,(x-192)/16,dut.S_effect_char,
                        reference_label_char);
                label_checks=label_checks+1;
                if (effect_text) label_glyphs=label_glyphs+1;
                mode_label_pixels[active_mode]=mode_label_pixels[active_mode]+1;
            end
            if (pipe_de[2] && x>=432 && x<544 && y>=80 && y<96) begin
                if (dut.S_effect_char !== " " || dut.S_effect_panel_on)
                    $fatal(1,"Removed parameter label is still present at %0d,%0d",x,y);
                removed_parameter_checks=removed_parameter_checks+1;
            end
            expected_rgb=status_on ? 24'h00ff00 :
                effect_panel ? (effect_text ? 24'h00e6ff : 24'h101010) :
                sample_osd ? sample_osd_color :
                panel_on ? (sample_text ? 24'hfff200 : 24'h101010) :
                box_on ? 24'hff3030 : cross_on ? 24'hfff200 : pipe_native[2];
            #1;
            if (out_de !== pipe_de[2] || out_hs !== pipe_hs[2] ||
                out_vs !== pipe_vs[2] || rd !== de)
                $fatal(1, "Effect stage changed three-clock DE/HS/VS or read-enable timing");
            if (dut.S_effect_mode !== active_mode)
                $fatal(1, "Active configuration changed outside frame start");
            if (out_de) begin
                if (out_rgb !== expected_rgb)
                    $fatal(1, "Overlay/effect color mismatch at %0d,%0d want=%h got=%h",
                           x,y,expected_rgb,out_rgb);
                pixels=pixels+1;
                mode_pixels[active_mode]=mode_pixels[active_mode]+1;
                if (pipe_user[2]) begin
                    frames=frames+1; first_pixels=first_pixels+1;
                    if (active_param!=128)
                        ignored_parameter_frames=ignored_parameter_frames+1;
                end
                if (sample_osd) begin
                    osd_pixels=osd_pixels+1;
                    mode_osd_pixels[active_mode]=mode_osd_pixels[active_mode]+1;
                end
                if (box_on && !sample_osd && !panel_on) begin
                    box_pixels=box_pixels+1;
                    mode_box_pixels[active_mode]=mode_box_pixels[active_mode]+1;
                end
                if (status_on) begin
                    status_pixels=status_pixels+1;
                    mode_status_pixels[active_mode]=mode_status_pixels[active_mode]+1;
                end
                if (!sample_osd && !status_on && !effect_panel && !panel_on && !box_on &&
                    !cross_on && out_rgb !== pipe_rgb[2]) changed_pixels=changed_pixels+1;
            end
        end
    end

    task automatic blank(input integer clocks);
        begin
            @(negedge hdmi_clk); de=0; user=0; last=0; hs=1; rgb=0;
            repeat (clocks) @(negedge hdmi_clk);
            hs=0;
        end
    endtask

    task automatic display_frame;
        integer emboss_shade;
        begin
            for (integer yy=0; yy<H; yy=yy+1) begin
                for (integer xx=0; xx<W; xx=xx+1) begin
                    @(negedge hdmi_clk);
                    de=1; user=(xx==0 && yy==0); last=(xx==W-1); hs=0; vs=0;
                    if (planned_mode == 4) begin
                        // Camera-side emboss is already a grayscale RGB stream.
                        emboss_shade=(xx*3+yy*7+128)%256;
                        rgb={3{8'(emboss_shade)}};
                    end else begin
                        rgb={8'((xx*3+yy*7+64)%256), 8'((xx*5+yy*11+96)%256),
                             8'((xx*13+yy*17+128)%256)};
                    end
                end
                blank(3);
            end
            vs=1; blank(128); vs=0;
        end
    endtask

    task automatic midframe_request(input integer frame_index);
        reg [11:0] next_config;
        begin
            wait (de && scan_y==40 && scan_x==80);
            // Busy snapshots may coalesce, but must preserve atomic pairs.
            if (frame_index == 5) begin
                publish(0,0); publish(1,224); publish(3,7); publish(2,224);
            end
            next_config = frame_config(frame_index+1);
            publish(next_config[11:8],next_config[7:0]);
        end
    endtask

    initial begin
        for (integer i=0; i<4096; i=i+1) published[i]=0;
        for (integer i=0; i<5; i=i+1) begin
            mode_pixels[i]=0; mode_osd_pixels[i]=0;
            mode_box_pixels[i]=0; mode_status_pixels[i]=0;
            mode_label_pixels[i]=0;
        end
        published[0]=1; published[{4'd0,8'd128}]=1;
        repeat (6) @(negedge hdmi_clk); rst_n=1;
        wait_config({4'd0,8'd128}); blank(16);
        for (integer frame_index=0; frame_index<PLAN_FRAMES; frame_index=frame_index+1) begin
            {planned_mode,planned_param}=frame_config(frame_index);
            wait_config({planned_mode,planned_param});
            if (frame_index<PLAN_FRAMES-1) begin
                fork
                    display_frame();
                    midframe_request(frame_index);
                join
            end else display_frame();
        end
        // Reset after a populated effect/configuration pipeline restores Gamma.
        @(negedge hdmi_clk); rst_n=0; de=0; user=0; last=0; vs=0; hs=0;
        source_config={4'd0,8'd128};
        repeat (6) @(negedge hdmi_clk); rst_n=1;
        planned_mode=0; planned_param=128;
        wait_config({4'd0,8'd128}); blank(16); display_frame(); blank(16);
        for (integer i=0; i<5; i=i+1) begin
            if (mode_pixels[i]<W*H || mode_osd_pixels[i]==0 ||
                mode_box_pixels[i]==0 || mode_status_pixels[i]==0 ||
                mode_label_pixels[i]<240*16)
                $fatal(1, "Incomplete per-mode pixel/overlay coverage for mode %0d",i);
        end
        if (pixels!=(PLAN_FRAMES+1)*W*H || frames!=PLAN_FRAMES+1 ||
            first_pixels!=PLAN_FRAMES+1 || ignored_parameter_frames!=10 ||
            snapshots<PLAN_FRAMES-1 || requests!=PLAN_FRAMES+3 ||
            osd_pixels==0 || box_pixels==0 || status_pixels==0 ||
            label_checks!=(PLAN_FRAMES+1)*240*16 || label_glyphs<1000 ||
            removed_parameter_checks!=(PLAN_FRAMES+1)*112*16 ||
            changed_pixels<100000)
            $fatal(1, "Incomplete mixer/effect integration coverage: pixels=%0d frames=%0d snapshots=%0d requests=%0d",
                   pixels,frames,snapshots,requests);
        $display("DISPLAY_EFFECTS_MIXER_PASS modes=5 pixels=%0d frames=%0d first_pixels=%0d ignored_parameter_frames=%0d snapshots=%0d requests=%0d osd=%0d box=%0d status=%0d changed=%0d label=%0d glyphs=%0d removed_parameter=%0d default=COLOR_GAMMA emboss_precomputed=1",
                 pixels,frames,first_pixels,ignored_parameter_frames,snapshots,requests,
                 osd_pixels,box_pixels,status_pixels,changed_pixels,label_checks,label_glyphs,
                 removed_parameter_checks);
        $finish;
    end

    initial begin
        #80000000;
        $fatal(1, "Display effect mixer integration timeout");
    end
endmodule
