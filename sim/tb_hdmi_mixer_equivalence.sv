`timescale 1ns/1ps

module mixer_equivalence_pair #(
    parameter integer CASE_ID = 0,
    parameter integer DEBUG_MODE = 0,
    parameter integer SHOW_CAMERA_STATUS = 1,
    parameter integer SHOW_COLOR_TARGET = 1,
    parameter integer SHOW_RED_MASK = 0
) (
    input wire clk, rst_n, vs, hs, de, user, last,
    input wire [23:0] rgb,
    input wire [3:0] status,
    input wire [7:0] fail_index,
    input wire ready, found,
    input wire [11:0] xmin, xmax, ymin, ymax, cx, cy,
    output wire candidate_de,
    output wire [23:0] candidate_rgb
);
    wire ref_rd, ref_vs, ref_hs, ref_de;
    wire dut_rd, dut_vs, dut_hs;
    wire [23:0] ref_rgb;
    integer comparisons = 0;
    integer active_comparisons = 0;
    integer warmup = 0;

    baseline_hdmi_mixer #(
        .H_OFFSET(0), .V_OFFSET(0), .IMG_WIDTH(1280), .IMG_HEIGHT(720),
        .DEBUG_MODE(DEBUG_MODE), .SHOW_CAMERA_STATUS(SHOW_CAMERA_STATUS),
        .SHOW_COLOR_TARGET(SHOW_COLOR_TARGET), .SHOW_RED_MASK(SHOW_RED_MASK)
    ) reference (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_video_vsync(vs), .I_video_hsync(hs), .I_video_de(de),
        .I_video_user(user), .I_video_last(last),
        .I_debug_status(status), .I_cam_fail_index(fail_index),
        .O_video_rd_en(ref_rd), .I_video_rd_data(rgb),
        .I_target_result_ready(ready), .I_target_found(found),
        .I_target_xmin(xmin), .I_target_xmax(xmax),
        .I_target_ymin(ymin), .I_target_ymax(ymax),
        .I_target_center_x(cx), .I_target_center_y(cy),
        .O_hdmi_vsync(ref_vs), .O_hdmi_hsync(ref_hs),
        .O_hdmi_de(ref_de), .O_hdmi_data(ref_rgb)
    );

    hdmi_mixer #(
        .H_OFFSET(0), .V_OFFSET(0), .IMG_WIDTH(1280), .IMG_HEIGHT(720),
        .DEBUG_MODE(DEBUG_MODE), .SHOW_CAMERA_STATUS(SHOW_CAMERA_STATUS),
        .SHOW_COLOR_TARGET(SHOW_COLOR_TARGET), .SHOW_RED_MASK(SHOW_RED_MASK)
    ) candidate (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_video_vsync(vs), .I_video_hsync(hs), .I_video_de(de),
        .I_video_user(user), .I_video_last(last),
        .I_debug_status(status), .I_cam_fail_index(fail_index),
        .O_video_rd_en(dut_rd), .I_video_rd_data(rgb),
        .I_target_result_ready(ready), .I_target_found(found),
        .I_target_xmin(xmin), .I_target_xmax(xmax),
        .I_target_ymin(ymin), .I_target_ymax(ymax),
        .I_target_center_x(cx), .I_target_center_y(cy),
        .O_hdmi_vsync(dut_vs), .O_hdmi_hsync(dut_hs),
        .O_hdmi_de(candidate_de), .O_hdmi_data(candidate_rgb)
    );

    always @(posedge clk) begin
        #0.001;
        if ({dut_rd, dut_vs, dut_hs, candidate_de, candidate_rgb} !==
            {ref_rd, ref_vs, ref_hs, ref_de, ref_rgb})
            $fatal(1, "Mixer differs case=%0d cycle=%0d reset=%b de=%b rgb=%h ref=%h",
                CASE_ID, comparisons, rst_n, candidate_de, candidate_rgb, ref_rgb);
        if (dut_rd !== de)
            $fatal(1, "Read enable differs from input case=%0d", CASE_ID);
        if (!rst_n)
            warmup = 0;
        else
            warmup = warmup + 1;
        // The original pixel pipeline is not reset; allow it to refill.
        if (warmup >= 4 &&
            (^{dut_rd, dut_vs, dut_hs, candidate_de, candidate_rgb}) === 1'bx)
            $fatal(1, "Unknown mixer output after pipeline refill case=%0d", CASE_ID);
        comparisons = comparisons + 1;
        if (candidate_de)
            active_comparisons = active_comparisons + 1;
    end

    always @(negedge rst_n) begin
        #0.001;
        if ({ref_vs, ref_hs, ref_de, ref_rgb} !== 27'd0 ||
            {dut_vs, dut_hs, candidate_de, candidate_rgb} !== 27'd0)
            $fatal(1, "Asynchronous reset did not clear outputs case=%0d", CASE_ID);
    end
endmodule

module tb_hdmi_mixer_equivalence;
    localparam integer W = 1280;
    localparam integer H = 720;
    localparam integer CASES = 6;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0, vs = 0, hs = 0, de = 0, user = 0, last = 0;
    reg [23:0] rgb = 0;
    reg [3:0] status = 0;
    reg [7:0] fail_index = 0;
    reg ready = 0, found = 0;
    reg [11:0] xmin = 0, xmax = 0, ymin = 0, ymax = 0, cx = 0, cy = 0;
    wire [CASES-1:0] out_de;
    wire [23:0] out_rgb [0:CASES-1];
    integer frames = 0;
    integer driven_pixels = 0;
    integer compared_pixels = 0;
    integer reset_discarded_pixels = 0;
    integer blank_checks = 0;
    integer reset_checks = 0;
    integer glyph_checks = 0;
    integer logo_checks = 0;
    integer fail_tiles = 0;
    integer status_tiles = 0;
    integer counter_tiles = 0;
    integer target_tiles = 0;
    integer frame_count = 0;
    integer input_x = 0, input_y = 0;
    integer tags_x [0:1];
    integer tags_y [0:1];
    reg [1:0] tags_de = 0;
    reg [31:0] random_state = 32'h2468ACE1;
    reg [7:0] glyph_char = 0;
    reg [3:0] glyph_row = 0;
    wire [15:0] reference_row, candidate_row;
    reg [14:0] logo_addr = 0;
    reg logo_input_valid = 0;
    reg logo_previous_valid = 0;
    reg [14:0] logo_previous_addr = 0;
    reg [24:0] logo_previous_pixel = 0;
    wire [24:0] reference_logo, candidate_logo;

    baseline_osd_char_lib reference_glyph (
        .I_char(glyph_char), .I_row(glyph_row), .O_row_bits(reference_row)
    );
    osd_char_lib candidate_glyph (
        .I_char(glyph_char), .I_row(glyph_row), .O_row_bits(candidate_row)
    );
    baseline_anlogic_logo_rom reference_logo_rom (
        .I_addr(logo_addr), .O_pixel(reference_logo)
    );
    anlogic_logo_rom candidate_logo_rom (
        .I_clk(clk), .I_addr(logo_addr), .O_pixel(candidate_logo)
    );

    always @(posedge clk) begin : logo_equivalence
        reg check_valid;
        reg [14:0] expected_addr;
        reg [24:0] expected_pixel;
        check_valid = logo_previous_valid;
        expected_addr = logo_previous_addr;
        expected_pixel = logo_previous_pixel;
        logo_previous_valid = logo_input_valid;
        logo_previous_addr = logo_addr;
        logo_previous_pixel = reference_logo;
        #0.003;
        if (check_valid) begin
            if (candidate_logo !== expected_pixel || (^candidate_logo) === 1'bx)
                $fatal(1, "Logo differs after two stages addr=%0d got=%h expected=%h",
                    expected_addr, candidate_logo, expected_pixel);
            logo_checks = logo_checks + 1;
        end
    end

    always @(negedge rst_n)
        reset_discarded_pixels = reset_discarded_pixels + tags_de[0] + tags_de[1];

    genvar case_index;
    generate
        for (case_index = 0; case_index < CASES; case_index = case_index+1) begin : cases
            mixer_equivalence_pair #(
                .CASE_ID(case_index),
                .DEBUG_MODE(case_index >= 3 ? case_index-2 : 0),
                .SHOW_CAMERA_STATUS(case_index == 1 ? 0 : 1),
                .SHOW_COLOR_TARGET(case_index == 1 ? 0 : 1),
                .SHOW_RED_MASK(case_index == 2 ? 1 : 0)
            ) pair (
                .clk(clk), .rst_n(rst_n), .vs(vs), .hs(hs), .de(de),
                .user(user), .last(last), .rgb(rgb), .status(status),
                .fail_index(fail_index), .ready(ready), .found(found),
                .xmin(xmin), .xmax(xmax), .ymin(ymin), .ymax(ymax), .cx(cx), .cy(cy),
                .candidate_de(out_de[case_index]), .candidate_rgb(out_rgb[case_index])
            );
        end
    endgenerate

    // Input tags are delayed independently to prove that active/blanking
    // coverage reaches the actual output, including the last pixel.
    always @(posedge clk) begin : output_coverage
        reg expected_de;
        expected_de = tags_de[1];
        if (!rst_n)
            tags_de = 0;
        else begin
            tags_de = {tags_de[0], de};
            tags_x[1] = tags_x[0];
            tags_y[1] = tags_y[0];
            tags_x[0] = input_x;
            tags_y[0] = input_y;
        end
        #0.002;
        if (rst_n) begin
            if (out_de[0] !== expected_de)
                $fatal(1, "Output DE changed latency");
            if (out_de[0])
                compared_pixels = compared_pixels + 1;
            else
                blank_checks = blank_checks + 1;
        end
    end

    task automatic drive(input bit active, start, finish,
                         input integer x, y, input [23:0] pixel);
        begin
            @(negedge clk);
            de = active;
            user = start;
            last = finish;
            input_x = x;
            input_y = y;
            rgb = pixel;
            if (rst_n && start)
                frame_count = (frame_count + 1) % 1000000;
            if (rst_n && active)
                driven_pixels = driven_pixels + 1;
        end
    endtask

    task automatic blank(input integer cycles);
        begin
            for (integer beat = 0; beat < cycles; beat = beat+1) begin
                random_state = {random_state[30:0],
                    random_state[31]^random_state[21]^random_state[1]^random_state[0]};
                drive(0, 0, 0, 0, 0, random_state[23:0]);
                hs = beat[1];
                vs = beat[2];
            end
            hs = 0;
            vs = 0;
        end
    endtask

    task automatic reset_outputs;
        begin
            @(negedge clk);
            #0.317 rst_n = 0;
            frame_count = 0;
            #0.001;
            reset_checks = reset_checks + 1;
            blank(5);
            #0.193 rst_n = 1;
            blank(6);
        end
    endtask

    task automatic full_frame(input integer id);
        reg [23:0] pixel;
        begin
            for (integer y = 0; y < H; y = y+1) begin
                for (integer x = 0; x < W; x = x+1) begin
                    random_state = {random_state[30:0],
                        random_state[31]^random_state[21]^random_state[1]^random_state[0]};
                    case (id)
                        0: pixel = {x[7:0], y[7:0], (x[7:0]^y[7:0])};
                        1: pixel = random_state[23:0];
                        2: pixel = (x[4]^y[4]) ? 24'hffffff : 24'h000000;
                        default: pixel = 24'hC82820;
                    endcase
                    drive(1, x == 0 && y == 0, x == W-1, x, y, pixel);
                    // The target mailbox may change mid-frame. Both mixers
                    // must continue displaying the geometry latched at (0,0).
                    if (x == 700 && y == 210) begin
                        ready = ~ready;
                        found = ~found;
                        xmin = 12'd45; xmax = 12'd680;
                        ymin = 12'd35; ymax = 12'd700;
                        cx = 12'd401; cy = 12'd555;
                    end
                    if (y == 20)
                        status = x[7:4];
                end
                blank(3+(y % 5));
            end
            blank(12);
            frames = frames + 1;
            $display("MIXER_EQUIVALENCE_FRAME frame=%0d pixels=%0d", id, compared_pixels);
        end
    endtask

    // Short completed lines advance native Y outside the tile. The tile
    // itself scans every column/row without forcing internal DUT state.
    task automatic render_tile(input integer first_y, last_y, width);
        integer line_width;
        begin
            for (integer y = 0; y <= last_y; y = y+1) begin
                line_width = (y >= first_y) ? width : 1;
                for (integer x = 0; x < line_width; x = x+1)
                    drive(1, x == 0 && y == 0, x == line_width-1,
                          x, y, {x[7:0], y[7:0], 8'h6B});
                blank(1);
            end
            blank(6);
        end
    endtask

    task automatic advance_counter(input integer target_before_tile);
        integer distance;
        begin
            distance = (target_before_tile-frame_count+1000000) % 1000000;
            repeat (distance)
                drive(0, 1, 0, 0, 0, 24'h13579B);
            blank(5);
        end
    endtask

    task automatic counter_tile(input integer displayed_count);
        begin
            advance_counter((displayed_count+999999) % 1000000);
            render_tile(120, 143, 575);
            if (frame_count != displayed_count)
                $fatal(1, "Frame-counter stimulus did not reach %0d", displayed_count);
            counter_tiles = counter_tiles + 1;
        end
    endtask

    initial begin
        for (integer code = 0; code < 256; code = code+1) begin
            for (integer row = 0; row < 16; row = row+1) begin
                glyph_char = code;
                glyph_row = row;
                #1;
                if (candidate_row !== reference_row || (^candidate_row) === 1'bx)
                    $fatal(1, "Character ROM differs char=%h row=%0d got=%h expected=%h",
                        glyph_char, row, candidate_row, reference_row);
                glyph_checks = glyph_checks + 1;
            end
        end
    end

    initial begin
        #50;
        for (integer address = 0; address < 32768; address = address+1) begin
            @(negedge clk);
            logo_addr = address;
            logo_input_valid = 1;
        end
        @(negedge clk);
        logo_input_valid = 0;
        repeat (2) @(negedge clk);
        if (logo_checks != 32768)
            $fatal(1, "Logo address coverage incomplete: %0d", logo_checks);
        $display("MIXER_EQUIVALENCE_LOGO addresses=%0d", logo_checks);
    end

    initial begin
        // Assert reset with an actual edge even on simulators initializing
        // the declaration value before procedural event controls start.
        #0.019 rst_n = 1;
        #0.021 rst_n = 0;
        blank(6);
        #0.193 rst_n = 1;
        blank(6);

        status = 4'hF;
        ready = 0; found = 1;
        xmin = 12'd10; xmax = 12'd310; ymin = 12'd10; ymax = 12'd320;
        cx = 12'd160; cy = 12'd165;
        full_frame(0);

        status = 4'h1; fail_index = 8'h03;
        ready = 1; found = 1;
        xmin = 12'd1200; xmax = 12'd1279; ymin = 12'd520; ymax = 12'd719;
        cx = 12'd1234; cy = 12'd567;
        full_frame(1);

        // Reset in an active line with pipeline contents and a latched target.
        for (integer x = 0; x < 317; x = x+1)
            drive(1, x == 0, 0, x, 0, x ^ 24'hF0A591);
        reset_outputs();

        status = 4'h5; fail_index = 8'hA5;
        ready = 1; found = 1;
        xmin = 0; xmax = 1279; ymin = 0; ymax = 719;
        cx = 12'd80; cy = 12'd80;
        full_frame(2);

        status = 4'h0; fail_index = 8'hFF;
        ready = 1; found = 0;
        xmin = 12'hFFF; xmax = 0; ymin = 12'hFFF; ymax = 0;
        cx = 12'hFFF; cy = 12'hFFF;
        full_frame(3);

        // All status states and every hexadecimal failure byte exercise both
        // seven-segment digits, including A-F and diagnostic overlay priority.
        ready = 1; found = 1;
        xmin = 200; xmax = 275; ymin = 16; ymax = 64;
        cx = 235; cy = 40;
        for (integer state = 0; state < 16; state = state+1) begin
            status = state;
            render_tile(16, 31, 280);
            status_tiles = status_tiles + 1;
        end
        status = 4'h1;
        for (integer code = 0; code < 256; code = code+1) begin
            fail_index = code;
            render_tile(40, 63, 256);
            fail_tiles = fail_tiles + 1;
        end
        $display("MIXER_EQUIVALENCE_DIAGNOSTICS status=%0d fail=%0d",
            status_tiles, fail_tiles);

        status = 4'hF;
        counter_tile(123456);
        counter_tile(789012);
        counter_tile(999999);
        counter_tile(0);
        counter_tile(1);

        // Decimal target panel checks include every digit and full 12-bit
        // centers; invalid/inactive target coordinates must not affect video.
        for (integer scenario = 0; scenario < 12; scenario = scenario+1) begin
            ready = scenario != 10;
            found = scenario != 11;
            cx = scenario == 10 ? 12'hFFF : (scenario*111) % 1280;
            cy = scenario == 10 ? 12'hFFF : (scenario*67) % 720;
            xmin = cx; xmax = cx; ymin = cy; ymax = cy;
            render_tile(688, 703, 384);
            target_tiles = target_tiles + 1;
        end
        blank(12);

        if (frames != 4 || glyph_checks != 4096 || logo_checks != 32768 || status_tiles != 16 ||
            fail_tiles != 256 || counter_tiles != 5 || target_tiles != 12 ||
            compared_pixels != driven_pixels-reset_discarded_pixels ||
            reset_discarded_pixels != 2 || blank_checks == 0 || reset_checks == 0)
            $fatal(1, "Coverage incomplete: frames=%0d glyphs=%0d driven=%0d output=%0d",
                frames, glyph_checks, driven_pixels, compared_pixels);
        $display("HDMI_MIXER_EQUIVALENCE_PASS cases=%0d frames=%0d pixels=%0d blanks=%0d glyphs=%0d logo=%0d status=%0d fail=%0d counters=%0d targets=%0d resets=%0d discarded=%0d",
            CASES, frames, compared_pixels, blank_checks, glyph_checks, logo_checks,
            status_tiles, fail_tiles, counter_tiles, target_tiles, reset_checks,
            reset_discarded_pixels);
        $finish;
    end

    initial begin
        #150000000;
        $fatal(1, "Mixer equivalence test timeout");
    end
endmodule
