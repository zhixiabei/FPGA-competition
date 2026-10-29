`timescale 1ns/1ps

module tb_fruit_showcase_panel;
    localparam integer W = 1280;
    localparam integer H = 720;
    localparam [23:0] CAMERA_RGB = 24'h123456;

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;

    wire [23:0] show_data, probe_data, runtime_data;
    wire show_de, show_hs, show_vs, show_rd, show_sof;
    wire probe_de, probe_hs, probe_vs, probe_rd, probe_sof;
    wire runtime_de, runtime_hs, runtime_vs, runtime_rd, runtime_sof;

`define MIXER_PORTS(DATA,DE,HS,VS,RD,SOF) \
        .I_clk(clk),.I_rst_n(rst_n),.I_video_vsync(1'b0), \
        .I_video_hsync(1'b0),.I_video_de(1'b0),.I_video_user(1'b0), \
        .I_video_last(1'b0),.I_effect_mode(4'd0),.I_effect_param(8'd0), \
        .I_debug_status(4'hf),.I_cam_fail_index(8'd0), \
        .I_raw_stats_valid(1'b0),.I_raw_stats_data(45'd0), \
        .I_ae_readout_valid(1'b0),.I_ae_readout_data(28'd0), \
        .I_latency_sample_strobe(1'b0),.I_latency_show(1'b0), \
        .I_latency_sample_valid(1'b0),.I_latency_total_us(20'd0), \
        .I_latency_isp_us(20'd0),.I_latency_buffer_us(20'd0), \
        .I_cnn_enable(1'b0),.I_cnn_result_valid(1'b0),.I_cnn_class(3'd1), \
        .I_checkout_weight_bcd(16'h1250),.I_checkout_price_bcd(16'h1000), \
        .I_checkout_weight_valid(1'b1),.I_checkout_price_valid(1'b1), \
        .I_hand_box_valid(1'b0),.I_hand_box(48'd0), \
        .I_resnet_probe_status(32'd0),.I_video_rd_data(CAMERA_RGB), \
        .I_target_result_ready(1'b0),.I_target_found(1'b0), \
        .I_target_motion_mode(1'b0),.I_target_color_mode(2'd0), \
        .I_target_xmin(12'd0),.I_target_xmax(12'd0), \
        .I_target_ymin(12'd0),.I_target_ymax(12'd0), \
        .I_target_center_x(12'd0),.I_target_center_y(12'd0), \
        .I_target_multi_valid(4'd0),.I_target_multi_hold(4'd0), \
        .I_target_multi_boxes(192'd0),.I_target_multi_shapes(8'd0), \
        .I_target_multi_overflow(1'b0),.O_hdmi_data(DATA),.O_hdmi_de(DE), \
        .O_hdmi_hsync(HS),.O_hdmi_vsync(VS),.O_video_rd_en(RD), \
        .O_display_frame_start(SOF)

    hdmi_mixer #(
        .IMG_WIDTH(W),.IMG_HEIGHT(H),.SHOW_CNN(1),.FRUIT_CNN(1),
        .HANDCNN_DYNAMIC_ROI(1),.CNN_RESULT_TIMEOUT_FRAMES(0)
    ) dut_show (`MIXER_PORTS(show_data,show_de,show_hs,show_vs,show_rd,show_sof));

    hdmi_mixer #(
        .IMG_WIDTH(W),.IMG_HEIGHT(H),.SHOW_CNN(1),.FRUIT_CNN(1),
        .SHOW_RESNET_PROBE(1),.SHOW_RESNET_RUNTIME(0)
    ) dut_probe (`MIXER_PORTS(probe_data,probe_de,probe_hs,probe_vs,probe_rd,probe_sof));

    hdmi_mixer #(
        .IMG_WIDTH(W),.IMG_HEIGHT(H),.SHOW_CNN(1),.FRUIT_CNN(1),
        .SHOW_RESNET_PROBE(0),.SHOW_RESNET_RUNTIME(1)
    ) dut_runtime (`MIXER_PORTS(runtime_data,runtime_de,runtime_hs,runtime_vs,runtime_rd,runtime_sof));
`undef MIXER_PORTS

    reg [7:0] glyph_char = 8'h82;
    reg [3:0] glyph_row = 0;
    wire [15:0] glyph_bits;
    osd_char_rom_sync glyph_rom(
        .I_clk(clk),.I_char(glyph_char),.I_row(glyph_row),.O_row_bits(glyph_bits)
    );

    integer checks = 0;
    integer i;
    reg [79:0] expected_english;
    reg [15:0] expected_chinese;
    reg [23:0] expected_color;
    reg [15:0] glyph_union;

    task check_bit(input condition, input [255:0] message);
        begin
            checks = checks + 1;
            if (!condition)
                $fatal(1, "%0s", message);
        end
    endtask

    task show_coord(input integer x, input integer y);
        begin
            release dut_show.S_x_2d;
            release dut_show.S_y_2d;
            force dut_show.S_x_2d = x;
            force dut_show.S_y_2d = y;
            #1;
        end
    endtask

    task legacy_coord(input integer x, input integer y);
        begin
            release dut_probe.S_x_2d;
            release dut_probe.S_y_2d;
            release dut_runtime.S_x_2d;
            release dut_runtime.S_y_2d;
            force dut_probe.S_x_2d = x;
            force dut_probe.S_y_2d = y;
            force dut_runtime.S_x_2d = x;
            force dut_runtime.S_y_2d = y;
            #1;
        end
    endtask

    task check_class(input integer class_id);
        reg [7:0] expected_char;
        begin
            case (class_id)
                2: begin
                    expected_english = "  APPLE   ";
                    expected_chinese = 16'h8283;
                    expected_color = 24'hff4058;
                end
                3: begin
                    expected_english = "  BANANA  ";
                    expected_chinese = 16'h8485;
                    expected_color = 24'hffd43b;
                end
                4: begin
                    expected_english = "  GRAPE   ";
                    expected_chinese = 16'h8687;
                    expected_color = 24'hb080ff;
                end
                5: begin
                    expected_english = "  ORANGE  ";
                    expected_chinese = 16'h8889;
                    expected_color = 24'hff8a30;
                end
                6: begin
                    expected_english = "STRAWBERRY";
                    expected_chinese = 16'h8a8b;
                    expected_color = 24'hff4068;
                end
                default: begin
                    expected_english = " UNKNOWN  ";
                    expected_chinese = 16'h2020;
                    expected_color = 24'hffc040;
                end
            endcase

            release dut_show.S_cnn_class;
            force dut_show.S_cnn_class = class_id;
            #1;
            check_bit(dut_show.S_fruit_color === expected_color,
                "fruit class color mismatch");

            show_coord(960, 500);
            check_bit(dut_show.S_fruit_panel_bg_on && dut_show.S_fruit_accent_on,
                "left accent bar missing");
            check_bit(dut_show.S_rgb_next === expected_color,
                "left accent bar color mismatch");

            show_coord(400, 300);
            check_bit(dut_show.S_cnn_roi_on, "dynamic ROI border missing");
            check_bit(dut_show.S_rgb_next === expected_color,
                "ROI border did not follow fruit color");

            for (i = 0; i < 10; i = i + 1) begin
                show_coord(960+i*32, 328);
                expected_char = expected_english[79-i*8 -: 8];
                check_bit(dut_show.S_cnn_char === expected_char,
                    "English fruit label mismatch or truncation");
                check_bit(dut_show.S_cnn_font_col === 0,
                    "2x English glyph scaling lost cell alignment");
            end

            if (class_id != 1) begin
                show_coord(1056, 216);
                check_bit(dut_show.S_cnn_char === expected_chinese[15:8],
                    "first Chinese fruit glyph code mismatch");
                check_bit(dut_show.u_target_char_lib.font_index ===
                    6'(32+expected_chinese[11:8]),
                    "first Chinese glyph ROM mapping mismatch");
                show_coord(1120, 216);
                check_bit(dut_show.S_cnn_char === expected_chinese[7:0],
                    "second Chinese fruit glyph code mismatch");
                check_bit(dut_show.u_target_char_lib.font_index ===
                    6'(32+expected_chinese[3:0]),
                    "second Chinese glyph ROM mapping mismatch");
            end else begin
                show_coord(1056, 216);
                check_bit(!dut_show.S_fruit_chinese_on,
                    "unknown class should not show Chinese name");
            end
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);

        force dut_show.S_cnn_visible = 1'b1;
        force dut_show.S_video_de_2d = 1'b1;
        force dut_show.S_video_data_2d = CAMERA_RGB;
        force dut_show.S_osd_hit = 1'b0;
        force dut_show.S_hand_box = {1'b1,12'd600,12'd120,12'd880,12'd400};

        show_coord(959, 500);
        check_bit(!dut_show.S_fruit_panel_bg_on,
            "showcase panel starts before x=960");
        check_bit(dut_show.S_rgb_next === CAMERA_RGB,
            "camera image changed to the left of the panel");
        show_coord(968, 500);
        check_bit(dut_show.S_rgb_next === 24'h101418,
            "main showcase background color mismatch");
        show_coord(1000, 608);
        check_bit(dut_show.S_rgb_next === 24'h181e24,
            "showcase footer band color mismatch");

        force dut_show.S_cnn_class = 3'd2;
        show_coord(1000, 105);
        check_bit(dut_show.S_rgb_next === 24'hff4058,
            "upper accent rule missing");
        show_coord(1000, 188);
        check_bit(dut_show.S_rgb_next === 24'hff4058,
            "name accent rule missing");
        show_coord(984, 64);
        check_bit(dut_show.S_cnn_char === "F" &&
            dut_show.S_font_valid_next &&
            dut_show.S_font_color_next === 24'hffffff,
            "showcase header style mismatch");
        show_coord(1040, 136);
        check_bit(dut_show.S_cnn_char === "I" &&
            dut_show.S_font_color_next === 24'ha8b3bb,
            "identified status style mismatch");
        show_coord(1056, 216);
        check_bit(dut_show.S_font_color_next === 24'hff4058,
            "Chinese name did not use class color");
        show_coord(1024, 392);
        check_bit(dut_show.S_cnn_char === "W",
            "weight label missing");
        show_coord(1024, 424);
        check_bit(dut_show.S_cnn_char === "1" &&
            dut_show.S_font_color_next === 24'hffffff,
            "weight value style mismatch");
        show_coord(976, 520);
        check_bit(dut_show.S_cnn_char === "1",
            "price integer digits missing");
        show_coord(1040, 520);
        check_bit(dut_show.S_cnn_char === ".",
            "price decimal point missing");
        show_coord(1024, 656);
        check_bit(dut_show.S_cnn_char === "A" &&
            dut_show.S_font_color_next === 24'ha8b3bb,
            "showcase footer style mismatch");

        for (i = 1; i <= 6; i = i + 1)
            check_class(i);

        force dut_probe.S_cnn_visible = 1'b1;
        force dut_probe.S_video_de_2d = 1'b1;
        force dut_runtime.S_cnn_visible = 1'b1;
        force dut_runtime.S_video_de_2d = 1'b1;
        legacy_coord(16, 16);
        check_bit(!dut_probe.S_fruit_showcase && dut_probe.S_cnn_panel_on,
            "probe mode no longer uses legacy panel");
        check_bit(!dut_runtime.S_fruit_showcase && dut_runtime.S_cnn_panel_on,
            "runtime mode no longer uses legacy panel");
        legacy_coord(335, 31);
        check_bit(dut_probe.S_cnn_panel_on,
            "probe panel legacy 320x16 geometry shrank");
        legacy_coord(336, 31);
        check_bit(!dut_probe.S_cnn_panel_on,
            "probe panel exceeds legacy width");
        legacy_coord(271, 47);
        check_bit(dut_runtime.S_cnn_panel_on,
            "runtime panel legacy 256x32 geometry shrank");
        legacy_coord(272, 48);
        check_bit(!dut_runtime.S_cnn_panel_on,
            "runtime panel exceeds legacy geometry");

        for (i = 0; i < 10; i = i + 1) begin
            glyph_union = 16'd0;
            glyph_char = 8'h82+i;
            for (glyph_row = 0; glyph_row < 15; glyph_row = glyph_row + 1) begin
                @(negedge clk);
                @(posedge clk); #1;
                glyph_union = glyph_union | glyph_bits;
            end
            glyph_row = 15;
            @(negedge clk);
            @(posedge clk); #1;
            glyph_union = glyph_union | glyph_bits;
            check_bit(glyph_union != 16'd0, "Chinese glyph ROM entry is blank");
        end

        $display("FRUIT_SHOWCASE_PANEL_PASS checks=%0d", checks);
        $finish;
    end
endmodule
