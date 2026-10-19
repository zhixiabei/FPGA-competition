`timescale 1ns/1ps
module tb_cnn_display_status;
    localparam integer W = 1280;
    localparam integer H = 720;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg de = 0, user = 0, last = 0;
    reg result_valid = 0;
    reg [2:0] result_class = 1;
    wire out_de, hidden_de, frame_start;
    wire [23:0] out_rgb, hidden_rgb;
    wire rd;

`define MIXER_PORTS \
        .I_clk(clk), .I_rst_n(rst_n), \
        .I_video_vsync(1'b0), .I_video_hsync(1'b0), \
        .I_video_de(de), .I_video_user(user), .I_video_last(last), \
        .I_effect_mode(4'd1), .I_effect_param(8'd0), \
        .I_debug_status(4'd0), .I_cam_fail_index(8'd0), \
        .I_raw_stats_valid(1'b0), .I_raw_stats_data(45'd0), \
        .I_ae_readout_valid(1'b0), .I_ae_readout_data(28'd0), \
        .I_latency_sample_strobe(1'b0), .I_latency_show(1'b0), \
        .I_latency_sample_valid(1'b0), .I_latency_total_us(20'd0), \
        .I_latency_isp_us(20'd0), .I_latency_buffer_us(20'd0), \
        .I_cnn_result_valid(result_valid), .I_cnn_class(result_class), \
        .I_video_rd_data(24'h606060), \
        .I_target_result_ready(1'b0), .I_target_found(1'b0), \
        .I_target_motion_mode(1'b0), .I_target_color_mode(2'd0), \
        .I_target_xmin(12'd0), .I_target_xmax(12'd0), \
        .I_target_ymin(12'd0), .I_target_ymax(12'd0), \
        .I_target_center_x(12'd0), .I_target_center_y(12'd0), \
        .I_target_multi_valid(4'd0), .I_target_multi_hold(4'd0), \
        .I_target_multi_boxes(192'd0), .I_target_multi_overflow(1'b0)

    hdmi_mixer #(.CNN_RESULT_TIMEOUT_FRAMES(3)) dut (
        `MIXER_PORTS,
        .O_video_rd_en(rd), .O_display_frame_start(frame_start),
        .O_hdmi_de(out_de), .O_hdmi_data(out_rgb),
        .O_hdmi_vsync(), .O_hdmi_hsync()
    );
    hdmi_mixer #(.SHOW_CNN(0)) hidden (
        `MIXER_PORTS,
        .O_video_rd_en(), .O_display_frame_start(),
        .O_hdmi_de(hidden_de), .O_hdmi_data(hidden_rgb),
        .O_hdmi_vsync(), .O_hdmi_hsync()
    );
`undef MIXER_PORTS

    reg pipe_de [0:2];
    integer pipe_x [0:2], pipe_y [0:2];
    integer scan_x = 0, scan_y = 0;
    integer checked_pixels = 0, roi_pixels = 0, label_pixels = 0;
    integer checked_frames = 0;
    reg verify_pixels = 0;
    reg [7:0] ref_char;
    reg [3:0] ref_row;
    wire [15:0] ref_bits;
    osd_char_lib reference_font (
        .I_char(ref_char), .I_row(ref_row), .O_row_bits(ref_bits)
    );

    function automatic [95:0] title(input [2:0] value);
        case (value)
            0: title = "CNN: OK     ";
            1: title = "CNN: NOTHING";
            2: title = "CNN: PEACE  ";
            3: title = "CNN: PUNCH  ";
            4: title = "CNN: STOP   ";
            default: title = "CNN: NOTHING";
        endcase
    endfunction

    always @(posedge clk) begin: monitor
        integer x, y, column;
        reg roi_on, label_on, ignore_original_osd;
        reg [95:0] text;
        reg [23:0] expected;
        if (!rst_n) begin
            scan_x = 0;
            scan_y = 0;
            for (integer n = 0; n < 3; n = n+1) begin
                pipe_de[n] = 0;
                pipe_x[n] = 0;
                pipe_y[n] = 0;
            end
            ref_char = " ";
            ref_row = 0;
        end else begin
            for (integer n = 2; n > 0; n = n-1) begin
                pipe_de[n] = pipe_de[n-1];
                pipe_x[n] = pipe_x[n-1];
                pipe_y[n] = pipe_y[n-1];
            end
            if (user) begin
                scan_x = 0;
                scan_y = 0;
            end
            pipe_de[0] = de;
            pipe_x[0] = scan_x;
            pipe_y[0] = scan_y;
            if (de) begin
                if (last) begin
                    scan_x = 0;
                    scan_y = scan_y+1;
                end else
                    scan_x = scan_x+1;
            end
            x = pipe_x[2];
            y = pipe_y[2];
            roi_on = x >= 512 && x <= 767 && y >= 232 && y <= 487 &&
                (x <= 513 || x >= 766 || y <= 233 || y >= 486);
            label_on = x >= 16 && x < 208 && y >= 16 && y < 32;
            ignore_original_osd = (x < 160 && y < 160) ||
                (x >= 375 && x < 575 && y >= 120 && y < 144);
            text = title(dut.S_cnn_class);
            column = (x-16)/16;
            ref_char = label_on ? text[95-8*column -: 8] : " ";
            ref_row = y-16;
            if (frame_start)
                checked_frames = checked_frames+1;
            #1;
            if (out_de !== pipe_de[2] || hidden_de !== pipe_de[2] || rd !== de)
                $fatal(1, "CNN display changed video timing");
            if (verify_pixels && out_de) begin
                expected = roi_on ? 24'h40ff80 : 24'h606060;
                if (label_on)
                    expected = ref_bits[15-((x-16)%16)] ? 24'h40ff80 : 24'h101010;
                if ((!ignore_original_osd || label_on) && out_rgb !== expected)
                    $fatal(1, "CNN overlay mismatch at %0d,%0d: got=%h want=%h",
                           x, y, out_rgb, expected);
                if (!ignore_original_osd && hidden_rgb !== 24'h606060)
                    $fatal(1, "SHOW_CNN=0 changed the video at %0d,%0d", x, y);
                checked_pixels = checked_pixels+1;
                if (roi_on) roi_pixels = roi_pixels+1;
                if (label_on) label_pixels = label_pixels+1;
            end
        end
    end

    task automatic check_class(input [2:0] visible, input [2:0] background);
        if (dut.S_cnn_class !== visible || hidden.S_cnn_class !== background)
            $fatal(1, "Unexpected class visible=%0d/%0d hidden=%0d/%0d",
                   dut.S_cnn_class, visible, hidden.S_cnn_class, background);
    endtask

    task automatic publish(input [2:0] value);
        begin
            @(negedge clk);
            result_valid = 1;
            result_class = value;
            @(negedge clk);
            result_valid = 0;
            check_class(value <= 4 ? value : 3'd1,
                        value <= 4 ? value : 3'd1);
        end
    endtask

    task automatic tick_frame(input bit refresh);
        begin
            @(negedge clk);
            de = 1; user = 1; last = 1;
            @(negedge clk);
            de = 0; user = 0; last = 0;
            @(negedge clk);
            // This result coincides with the delayed display-frame event.
            result_valid = refresh;
            result_class = 4;
            @(negedge clk);
            result_valid = 0;
            repeat (4) @(negedge clk);
        end
    endtask

    task automatic draw_frame(input integer rows);
        begin
            for (integer y = 0; y < rows; y = y+1) begin
                for (integer x = 0; x < W; x = x+1) begin
                    @(negedge clk);
                    de = 1; user = x == 0 && y == 0; last = x == W-1;
                end
                @(negedge clk);
                de = 0; user = 0; last = 0;
                repeat (3) @(negedge clk);
            end
            repeat (8) @(negedge clk);
        end
    endtask

    initial begin
        repeat (6) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);
        check_class(1, 1);
        publish(4);
        repeat (200) @(negedge clk);
        check_class(4, 4);
        tick_frame(0); check_class(4, 4);
        tick_frame(0); check_class(4, 4);
        tick_frame(0); check_class(1, 4);
        for (integer n = 4; n < 60; n = n+1) begin
            tick_frame(0);
            check_class(1, 4);
        end
        tick_frame(0); check_class(1, 1);
        repeat (70) tick_frame(0);
        check_class(1, 1);
        tick_frame(1); check_class(4, 4);
        tick_frame(0); check_class(4, 4);
        tick_frame(0); check_class(4, 4);
        tick_frame(0); check_class(1, 4);
        publish(7); check_class(1, 1);
        publish(5); check_class(1, 1);
        verify_pixels = 1;
        for (integer value = 0; value < 5; value = value+1) begin
            publish(value[2:0]);
            draw_frame(value == 4 ? H : 32);
        end
        if (checked_pixels != W*(H+4*32) || roi_pixels != 2032 ||
            label_pixels != 5*192*16)
            $fatal(1, "Incomplete CNN overlay coverage pixels=%0d ROI=%0d label=%0d",
                   checked_pixels, roi_pixels, label_pixels);
        verify_pixels = 0;
        @(negedge clk);
        rst_n = 0;
        repeat (4) @(negedge clk);
        check_class(1, 1);
        $display("CNN_DISPLAY_STATUS_PASS pixels=%0d ROI=%0d label=%0d frames=%0d timeout=3/default60 invalid_class=NOTHING simultaneous_result_priority=1 SHOW_CNN_0=clean",
                 checked_pixels, roi_pixels, label_pixels, checked_frames);
        $finish;
    end

    initial begin
        #20000000;
        $fatal(1, "CNN display status simulation timeout");
    end
endmodule
