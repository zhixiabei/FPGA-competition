`timescale 1ns/1ps

module tb_motion_target_detect_96;
    localparam integer W = 128;
    localparam integer H = 96;
    localparam integer BW = W / 8;
    localparam integer BH = H / 8;
    localparam integer GROUPS = W / 4;
    localparam integer THRESHOLD = 6;
    localparam integer MIN_BLOCKS = 8;
    localparam integer GLOBAL_PERCENT = 40;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg tuser = 0, tlast = 0, tvalid = 0;
    reg [95:0] tdata = 0;
    wire ready, found, frame_toggle;
    wire [11:0] xmin, xmax, ymin, ymax, center_x, center_y;
    wire [23:0] pixels;

    motion_target_detect_96 #(
        .IMG_WIDTH(W), .IMG_HEIGHT(H), .DIFF_THRESHOLD(THRESHOLD),
        .MIN_BLOCKS(MIN_BLOCKS), .GLOBAL_CHANGE_PERCENT(GLOBAL_PERCENT)
    ) dut (
        .I_clk(clk), .I_rst_n(rst_n), .I_tuser(tuser), .I_tlast(tlast),
        .I_tvalid(tvalid), .I_tdata(tdata), .O_result_ready(ready),
        .O_found(found), .O_xmin(xmin), .O_xmax(xmax),
        .O_ymin(ymin), .O_ymax(ymax), .O_center_x(center_x),
        .O_center_y(center_y), .O_pixels(pixels), .O_frame_toggle(frame_toggle)
    );

    // The reference works on complete pixel images. It independently computes
    // all 64-pixel means and all 3x3 windows instead of following RTL cycles.
    reg [23:0] image [0:H-1][0:W-1];
    integer reference_mean [0:BH-1][0:BW-1];
    integer current_mean [0:BH-1][0:BW-1];
    bit changed [0:BH-1][0:BW-1];
    bit reference_valid = 0;
    integer expected_found [0:127], expected_pixels [0:127];
    integer expected_xmin [0:127], expected_xmax [0:127];
    integer expected_ymin [0:127], expected_ymax [0:127];
    bit check_pixels [0:127];
    string expected_name [0:127];
    integer queued = 0, received = 0, all_received = 0;
    reg previous_toggle = 0;
    integer checked_found = 0, checked_suppressed = 0;

    task automatic clear_image(input integer value);
        integer x, y;
        begin
            for (y = 0; y < H; y = y + 1)
                for (x = 0; x < W; x = x + 1)
                    image[y][x] = {8'(value), 8'(value), 8'(value)};
        end
    endtask

    task automatic paint_blocks(input integer x0, input integer y0,
                                input integer x1, input integer y1,
                                input reg [23:0] rgb);
        integer x, y;
        begin
            for (y = y0*8; y < (y1+1)*8; y = y + 1)
                for (x = x0*8; x < (x1+1)*8; x = x + 1)
                    image[y][x] = rgb;
        end
    endtask

    task automatic expect_image(input string name, input bit well_formed);
        integer bx, by, x, y, sum_gray, gray, difference;
        integer raw_count, votes, wx, wy, dx, dy;
        integer box_x0, box_x1, box_y0, box_y1;
        bit has_window, qualify;
        begin
            raw_count = 0;
            for (by = 0; by < BH; by = by + 1) begin
                for (bx = 0; bx < BW; bx = bx + 1) begin
                    sum_gray = 0;
                    for (y = by*8; y < by*8+8; y = y + 1) begin
                        for (x = bx*8; x < bx*8+8; x = x + 1) begin
                            gray = (integer'(image[y][x][23:16]) +
                                    2*integer'(image[y][x][15:8]) +
                                    integer'(image[y][x][7:0])) / 4;
                            sum_gray = sum_gray + gray;
                        end
                    end
                    current_mean[by][bx] = sum_gray / 64;
                    difference = current_mean[by][bx] - reference_mean[by][bx];
                    if (difference < 0) difference = -difference;
                    changed[by][bx] = reference_valid && difference >= THRESHOLD;
                    if (changed[by][bx]) raw_count = raw_count + 1;
                end
            end
            has_window = 0;
            box_x0 = BW; box_x1 = -1;
            box_y0 = BH; box_y1 = -1;
            for (wy = 0; wy <= BH-3; wy = wy + 1) begin
                for (wx = 0; wx <= BW-3; wx = wx + 1) begin
                    votes = 0;
                    for (dy = 0; dy < 3; dy = dy + 1)
                        for (dx = 0; dx < 3; dx = dx + 1)
                            if (changed[wy+dy][wx+dx]) votes = votes + 1;
                    if (votes >= 3) begin
                        has_window = 1;
                        for (dy = 0; dy < 3; dy = dy + 1) begin
                            for (dx = 0; dx < 3; dx = dx + 1) begin
                                if (changed[wy+dy][wx+dx]) begin
                                    if (wx+dx < box_x0) box_x0 = wx+dx;
                                    if (wx+dx > box_x1) box_x1 = wx+dx;
                                    if (wy+dy < box_y0) box_y0 = wy+dy;
                                    if (wy+dy > box_y1) box_y1 = wy+dy;
                                end
                            end
                        end
                    end
                end
            end
            qualify = well_formed && reference_valid && has_window &&
                      raw_count >= MIN_BLOCKS &&
                      raw_count*100 < BW*BH*GLOBAL_PERCENT;
            expected_name[queued] = name;
            expected_found[queued] = qualify;
            expected_pixels[queued] = raw_count * 64;
            check_pixels[queued] = well_formed;
            expected_xmin[queued] = qualify ? box_x0*8 : 0;
            expected_xmax[queued] = qualify ? (box_x1+1)*8-1 : 0;
            expected_ymin[queued] = qualify ? box_y0*8 : 0;
            expected_ymax[queued] = qualify ? (box_y1+1)*8-1 : 0;
            queued = queued + 1;
            reference_valid = well_formed;
            if (well_formed)
                for (by = 0; by < BH; by = by + 1)
                    for (bx = 0; bx < BW; bx = bx + 1)
                        reference_mean[by][bx] = current_mean[by][bx];
        end
    endtask

    // marker_style: 0=with first beat, 1=early during blanking,
    // 2=held across the first three accepted beats.
    task automatic send_image(input string name, input integer marker_style,
                              input bit bubbles, input integer bad_last);
        integer y, group_index, lane, beat_number;
        begin
            expect_image(name, bad_last == 0);
            if (marker_style == 1) begin
                @(negedge clk); tuser = 1; tvalid = 0; tlast = 0;
                repeat (3) @(negedge clk);
                tuser = 0;
                repeat (2) @(negedge clk);
            end
            for (y = 0; y < H; y = y + 1) begin
                for (group_index = 0; group_index < GROUPS; group_index = group_index + 1) begin
                    beat_number = y*GROUPS+group_index;
                    if (bubbles && beat_number % 37 == 11) begin
                        @(negedge clk);
                        tvalid = 0; tuser = 0; tlast = 1; tdata = 96'hfedcba9876543210deadbeef;
                        @(negedge clk);
                        tlast = 0;
                    end
                    @(negedge clk);
                    tuser = (marker_style == 0 && beat_number == 0) ||
                            (marker_style == 2 && beat_number < 3);
                    tvalid = 1;
                    tlast = group_index == GROUPS-1;
                    if (bad_last == 1 && y == 7 && group_index == GROUPS-1)
                        tlast = 0;
                    if (bad_last == 2 && y == 12 && group_index == 3)
                        tlast = 1;
                    for (lane = 0; lane < 4; lane = lane + 1)
                        tdata[95-lane*24-:24] = image[y][group_index*4+lane];
                end
            end
            @(negedge clk); tvalid = 0; tuser = 0; tlast = 0;
        end
    endtask

    task automatic await_results;
        integer cycles;
        begin
            cycles = 0;
            while (received < queued && cycles < 256) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (received != queued)
                $fatal(1, "Motion result missing: received=%0d queued=%0d", received, queued);
            repeat (12) @(negedge clk);
        end
    endtask

    task automatic truncate_image(input integer rows);
        integer y, group_index, lane;
        begin
            for (y = 0; y < rows; y = y + 1) begin
                for (group_index = 0; group_index < GROUPS; group_index = group_index + 1) begin
                    @(negedge clk);
                    tuser = y == 0 && group_index == 0;
                    tvalid = 1;
                    tlast = group_index == GROUPS-1;
                    for (lane = 0; lane < 4; lane = lane + 1)
                        tdata[95-lane*24-:24] = image[y][group_index*4+lane];
                end
            end
            @(negedge clk); tuser = 0; tvalid = 0; tlast = 0;
            repeat (20) @(negedge clk);
            reference_valid = 0;
        end
    endtask

    always @(posedge clk) begin
        #1;
        if (!rst_n) begin
            if (ready !== 0 || found !== 0 || frame_toggle !== 0)
                $fatal(1, "Motion reset did not clear outputs");
            previous_toggle = 0;
        end else if (ready) begin
            if (received >= queued)
                $fatal(1, "Unexpected or duplicate motion result %0d", received);
            if (found !== expected_found[received][0] ||
                xmin !== expected_xmin[received][11:0] ||
                xmax !== expected_xmax[received][11:0] ||
                ymin !== expected_ymin[received][11:0] ||
                ymax !== expected_ymax[received][11:0] ||
                center_x !== ((expected_xmin[received]+expected_xmax[received])/2) ||
                center_y !== ((expected_ymin[received]+expected_ymax[received])/2))
                $fatal(1, "%s: found=%b box=%0d,%0d..%0d,%0d center=%0d,%0d expected found=%0d box=%0d,%0d..%0d,%0d",
                       expected_name[received], found, xmin, ymin, xmax, ymax, center_x, center_y,
                       expected_found[received], expected_xmin[received], expected_ymin[received],
                       expected_xmax[received], expected_ymax[received]);
            if (check_pixels[received] && pixels !== expected_pixels[received][23:0])
                $fatal(1, "%s: pixels=%0d expected=%0d",
                       expected_name[received], pixels, expected_pixels[received]);
            if (frame_toggle !== ~previous_toggle)
                $fatal(1, "%s: frame toggle did not change", expected_name[received]);
            previous_toggle = frame_toggle;
            if (found) checked_found = checked_found + 1;
            else checked_suppressed = checked_suppressed + 1;
            $display("MOTION_CASE_PASS %0d %s found=%b pixels=%0d box=%0d,%0d..%0d,%0d",
                     all_received, expected_name[received], found, pixels, xmin, ymin, xmax, ymax);
            received = received + 1;
            all_received = all_received + 1;
        end
    end

    integer index, x, y;
    initial begin
        clear_image(24);
        repeat (5) @(negedge clk);
        rst_n = 1;
        // Data without a frame marker cannot initialize a reference.
        repeat (11) begin
            @(negedge clk); tvalid = 1; tdata = {4{24'hdcdcdc}};
        end
        @(negedge clk); tvalid = 0;
        repeat (12) @(negedge clk);
        send_image("first clean reference", 1, 1, 0); await_results();
        send_image("unchanged, held SOF", 2, 0, 0); await_results();
        paint_blocks(4, 3, 7, 6, 24'h505050);
        send_image("object appears", 0, 1, 0); await_results();
        clear_image(24); paint_blocks(7, 3, 10, 6, 24'h505050);
        send_image("object translates", 1, 1, 0); await_results();
        send_image("object stops", 0, 0, 0); await_results();
        clear_image(24);
        send_image("object disappears", 0, 0, 0); await_results();
        send_image("empty again", 0, 0, 0); await_results();

        for (index = 0; index < 8; index = index + 1)
            paint_blocks((index % 4)*4, (index / 4)*6,
                         (index % 4)*4, (index / 4)*6, 24'h606060);
        send_image("isolated block noise", 0, 1, 0); await_results();
        clear_image(24);
        send_image("isolated noise disappears", 0, 0, 0); await_results();
        paint_blocks(4, 3, 6, 4, 24'h606060);
        send_image("supported window but below minimum blocks", 0, 0, 0); await_results();
        clear_image(24);
        send_image("clear six-block object", 0, 0, 0); await_results();
        paint_blocks(4, 3, 7, 4, 24'h606060);
        send_image("exact minimum block count", 0, 0, 0); await_results();
        clear_image(24);
        send_image("clear eight-block object", 0, 0, 0); await_results();

        paint_blocks(0, 0, 3, 3, 24'h606060);
        paint_blocks(BW-4, BH-4, BW-1, BH-1, 24'h606060);
        send_image("all borders, two regions union", 1, 1, 0); await_results();
        clear_image(24);
        send_image("clear border regions", 0, 0, 0); await_results();
        paint_blocks(BW-4, BH-4, BW-1, BH-1, 24'h505050);
        paint_blocks(BW-1, BH-1, BW-1, BH-1,
                     {3{8'(24 + THRESHOLD - 1)}});
        for (x = W-4; x < W; x = x + 1)
            image[H-1][x] = {3{8'(24 + THRESHOLD + 15)}};
        send_image("last beat raises final block to threshold", 0, 1, 0); await_results();
        send_image("final-beat image becomes still", 0, 0, 0); await_results();
        clear_image(24);
        send_image("clear final-beat object", 0, 0, 0); await_results();

        paint_blocks(4, 3, 7, 6, {3{8'(24 + THRESHOLD - 1)}});
        send_image("difference below threshold", 0, 0, 0); await_results();
        clear_image(24);
        send_image("return below threshold", 0, 0, 0); await_results();
        paint_blocks(4, 3, 7, 6, {3{8'(24 + THRESHOLD)}});
        send_image("difference equals threshold", 0, 0, 0); await_results();
        clear_image(24);
        send_image("clear threshold object", 0, 0, 0); await_results();
        paint_blocks(4, 3, 7, 6, 24'h503020);
        send_image("weighted RGB block means", 1, 1, 0); await_results();
        clear_image(24);
        send_image("clear weighted object", 0, 0, 0); await_results();
        paint_blocks(0, 0, 8, 7, 24'h606060);
        paint_blocks(0, 8, 3, 8, 24'h606060);
        send_image("76 of 192 blocks below global cutoff", 0, 0, 0); await_results();
        clear_image(24);
        send_image("clear 76-block object", 0, 0, 0); await_results();
        paint_blocks(0, 0, 8, 7, 24'h606060);
        paint_blocks(0, 8, 4, 8, 24'h606060);
        send_image("77 of 192 blocks reaches global cutoff", 0, 0, 0); await_results();
        clear_image(24);
        send_image("clear 77-block global change", 0, 0, 0); await_results();
        clear_image(80);
        send_image("global illumination suppression", 1, 1, 0); await_results();
        send_image("stable changed illumination", 0, 0, 0); await_results();

        clear_image(24);
        send_image("missing line-end invalidates frame", 0, 1, 1); await_results();
        paint_blocks(4, 3, 7, 6, 24'h606060);
        send_image("clean frame warms after malformed", 1, 0, 0); await_results();
        send_image("still after malformed recovery", 0, 0, 0); await_results();
        clear_image(24);
        send_image("early line-end invalidates frame", 0, 1, 2); await_results();
        send_image("warm after early line-end", 0, 0, 0); await_results();

        paint_blocks(0, 0, BW-1, BH-1, 24'ha0a0a0);
        truncate_image(H-3);
        clear_image(24);
        send_image("truncation then early SOF warms", 1, 1, 0); await_results();
        paint_blocks(4, 3, 7, 6, 24'h606060);
        send_image("motion after truncation recovery", 0, 0, 0); await_results();

        // The next SOF arrives before the previous result pipeline drains.
        clear_image(24);
        send_image("back-to-back frame A", 0, 0, 0);
        paint_blocks(4, 3, 7, 6, 24'h606060);
        send_image("back-to-back frame B", 0, 0, 0);
        await_results();

        truncate_image(19);
        @(negedge clk); rst_n = 0;
        repeat (5) @(negedge clk);
        if (received != queued) $fatal(1, "Pending expected results at reset");
        reference_valid = 0;
        queued = 0; received = 0;
        rst_n = 1;
        send_image("reset warms without clearing RAM", 1, 1, 0); await_results();
        clear_image(24);
        send_image("motion after reset recovery", 0, 0, 0); await_results();
        if (all_received != 41 || checked_found < 10 || checked_suppressed < 10)
            $fatal(1, "Incomplete motion coverage frames=%0d found=%0d suppressed=%0d",
                   all_received, checked_found, checked_suppressed);
        $display("MOTION_TARGET_DETECT_PASS frames=%0d detected=%0d suppressed=%0d width=%0d height=%0d",
                 all_received, checked_found, checked_suppressed, W, H);
        $finish;
    end

    initial begin
        #5000000;
        $fatal(1, "Motion detector test timeout");
    end
endmodule

module tb_motion_full_resolution;
    localparam integer W = 1280;
    localparam integer H = 720;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg tuser = 0, tlast = 0, tvalid = 0;
    reg [95:0] tdata = 0;
    wire ready, found, frame_toggle;
    wire [11:0] xmin, xmax, ymin, ymax, center_x, center_y;
    wire [23:0] pixels;
    integer received = 0;
    reg previous_toggle = 0;

    motion_target_detect_96 #(.IMG_WIDTH(W), .IMG_HEIGHT(H)) dut (
        .I_clk(clk), .I_rst_n(rst_n), .I_tuser(tuser), .I_tlast(tlast),
        .I_tvalid(tvalid), .I_tdata(tdata), .O_result_ready(ready),
        .O_found(found), .O_xmin(xmin), .O_xmax(xmax),
        .O_ymin(ymin), .O_ymax(ymax), .O_center_x(center_x),
        .O_center_y(center_y), .O_pixels(pixels), .O_frame_toggle(frame_toggle)
    );

    task automatic drive_frame(input integer scene);
        integer y, group_index, lane, x;
        reg [7:0] level;
        begin
            @(negedge clk); tuser = 1; tvalid = 0;
            repeat (2) @(negedge clk);
            tuser = 0;
            for (y = 0; y < H; y = y + 1) begin
                for (group_index = 0; group_index < W/4; group_index = group_index + 1) begin
                    if ((y*(W/4)+group_index) % 251 == 13) begin
                        @(negedge clk); tvalid = 0; tlast = 0;
                    end
                    @(negedge clk); tvalid = 1; tlast = group_index == W/4-1;
                    for (lane = 0; lane < 4; lane = lane + 1) begin
                        x = group_index*4+lane;
                        level = scene == 3 ? 80 : 24;
                        if ((scene == 1 || scene == 2) && x >= W-32 && y >= H-32)
                            level = 96;
                        tdata[95-lane*24-:24] = {level, level, level};
                    end
                end
            end
            @(negedge clk); tuser = 0; tvalid = 0; tlast = 0;
            repeat (40) @(negedge clk);
        end
    endtask

    always @(posedge clk) begin
        #1;
        if (!rst_n) previous_toggle = 0;
        else if (ready) begin
            if (received >= 4)
                $fatal(1, "Duplicate full-resolution result");
            if (received == 1) begin
                if (found !== 1 || pixels !== 1024 ||
                    xmin !== W-32 || xmax !== W-1 || ymin !== H-32 || ymax !== H-1 ||
                    center_x !== W-17 || center_y !== H-17)
                    $fatal(1, "720p reference-tail object box/count incorrect: found=%b pixels=%0d box=%0d,%0d..%0d,%0d",
                           found, pixels, xmin, ymin, xmax, ymax);
            end else begin
                if (found !== 0 || xmin !== 0 || xmax !== 0 ||
                    ymin !== 0 || ymax !== 0 || center_x !== 0 || center_y !== 0 ||
                    pixels !== (received == 3 ? W*H : 0))
                    $fatal(1, "720p warm-up/still/global result %0d is incorrect", received);
            end
            if (frame_toggle !== ~previous_toggle)
                $fatal(1, "720p frame toggle incorrect");
            previous_toggle = frame_toggle;
            received = received + 1;
        end
    end

    integer scene;
    initial begin
        repeat (5) @(negedge clk); rst_n = 1;
        for (scene = 0; scene < 4; scene = scene + 1)
            drive_frame(scene);
        if (received != 4)
            $fatal(1, "Full-resolution result missing received=%0d", received);
        $display("MOTION_FULL_RESOLUTION_PASS frames=%0d reference_bytes=%0d width=%0d height=%0d",
                 received, W*H/64, W, H);
        $finish;
    end

    initial begin
        #20000000;
        $fatal(1, "Full-resolution motion test timeout");
    end
endmodule

module tb_target_detect_switch_96;
    localparam integer W = 128;
    localparam integer H = 96;
    localparam integer GROUPS = W/4;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg request_motion = 0;
    reg tuser = 0, tlast = 0, tvalid = 0;
    reg [95:0] tdata = 0;
    wire ready, found, frame_toggle, result_motion, active_motion;
    wire [11:0] xmin, xmax, ymin, ymax, center_x, center_y;
    wire [23:0] pixels;
    integer received = 0;
    integer queued = 0;
    integer expected_mode [0:7], expected_found [0:7], expected_pixels [0:7];
    integer expected_xmin [0:7], expected_xmax [0:7];
    integer expected_ymin [0:7], expected_ymax [0:7];
    reg previous_toggle = 0;
    integer completions_after_next_sof = 0;
    integer frame_number = 0;

    target_detect_switch_96 #(
        .IMG_WIDTH(W), .IMG_HEIGHT(H), .DIFF_THRESHOLD(6), .MIN_BLOCKS(8),
        .MOTION_STABLE_ENABLE(0)
    ) dut (
        .I_clk(clk), .I_rst_n(rst_n), .I_motion_mode_async(request_motion),
        .I_color_mode_async(request_motion ? 2'd3 : 2'd0),
        .I_effect_config(12'd0), .I_frame_id(10'd0),
        .I_tuser(tuser), .I_tlast(tlast), .I_tvalid(tvalid), .I_tdata(tdata),
        .O_result_ready(ready), .O_found(found),
        .O_xmin(xmin), .O_xmax(xmax), .O_ymin(ymin), .O_ymax(ymax),
        .O_center_x(center_x), .O_center_y(center_y), .O_pixels(pixels),
        .O_frame_toggle(frame_toggle), .O_target_motion_mode(result_motion),
        .O_motion_mode_active(active_motion), .O_target_color_mode(),
        .O_color_mode_active(), .O_result_frame_id(),
        .O_multi_valid(), .O_multi_hold(), .O_multi_boxes(), .O_multi_shapes(),
        .O_multi_overflow(), .O_mask_pixels()
    );

    task automatic queue_result(input integer mode, input integer detect,
                                input integer count, input integer x0,
                                input integer x1, input integer y0, input integer y1);
        begin
            expected_mode[queued] = mode; expected_found[queued] = detect;
            expected_pixels[queued] = count;
            expected_xmin[queued] = x0; expected_xmax[queued] = x1;
            expected_ymin[queued] = y0; expected_ymax[queued] = y1;
            queued = queued + 1;
        end
    endtask

    // Scene 0 is uniformly red; scene 1 is uniformly gray; scene 2 adds
    // a four-by-four block gray object. The red results have closed-form
    // interior coordinates. Three centred 3x3 binary windows require a
    // complete radius-three support; motion geometry is independent of red.
    task automatic drive_frame(input integer scene, input integer mode,
                               input integer mid_request, input bit early_sof);
        integer y, group_index, lane, px;
        reg [23:0] rgb;
        begin
            frame_number = frame_number + 1;
            if (early_sof) begin
                @(negedge clk); tvalid = 0; tuser = 1; tlast = 0;
                @(negedge clk); tuser = 0;
                repeat (3) @(negedge clk);
                if (active_motion !== mode[0])
                    $fatal(1, "Early SOF did not commit requested detector mode");
            end
            for (y = 0; y < H; y = y + 1) begin
                for (group_index = 0; group_index < GROUPS; group_index = group_index + 1) begin
                    @(negedge clk);
                    tvalid = 1;
                    tuser = !early_sof && y == 0 && group_index == 0;
                    tlast = group_index == GROUPS-1;
                    for (lane = 0; lane < 4; lane = lane + 1) begin
                        px = group_index*4+lane;
                        rgb = scene == 0 ? 24'hb41818 : 24'h181818;
                        if (scene == 2 && px >= 32 && px < 64 && y >= 24 && y < 56)
                            rgb = 24'h606060;
                        tdata[95-lane*24-:24] = rgb;
                    end
                    if (y == H/2 && group_index == 0) request_motion = mid_request[0];
                    if (y > H/2 && active_motion !== mode[0])
                        $fatal(1, "Mid-frame request changed active mode in frame %0d", frame_number);
                end
            end
            @(negedge clk); tuser = 0; tvalid = 0; tlast = 0;
        end
    endtask

    task automatic await_results;
        integer cycles;
        begin
            cycles = 0;
            while (received < queued && cycles < 256) begin
                @(negedge clk); cycles = cycles + 1;
            end
            if (received != queued)
                $fatal(1, "Switch results missing received=%0d queued=%0d", received, queued);
            repeat (12) @(negedge clk);
        end
    endtask

    always @(posedge clk) begin
        #1;
        if (!rst_n) previous_toggle = 0;
        else if (ready) begin
            if (received >= queued)
                $fatal(1, "Switch published an unselected or duplicate completion");
            if (result_motion !== expected_mode[received][0] ||
                found !== expected_found[received][0] ||
                pixels !== expected_pixels[received][23:0] ||
                xmin !== expected_xmin[received][11:0] ||
                xmax !== expected_xmax[received][11:0] ||
                ymin !== expected_ymin[received][11:0] ||
                ymax !== expected_ymax[received][11:0] ||
                center_x !== ((expected_xmin[received]+expected_xmax[received])/2) ||
                center_y !== ((expected_ymin[received]+expected_ymax[received])/2))
                $fatal(1, "Switch result %0d mode=%b found=%b count=%0d box=%0d,%0d..%0d,%0d expected mode=%0d found=%0d count=%0d box=%0d,%0d..%0d,%0d",
                       received, result_motion, found, pixels, xmin, ymin, xmax, ymax,
                       expected_mode[received], expected_found[received], expected_pixels[received],
                       expected_xmin[received], expected_ymin[received],
                       expected_xmax[received], expected_ymax[received]);
            if (frame_toggle !== ~previous_toggle)
                $fatal(1, "Switch output frame toggle did not toggle per selected frame");
            previous_toggle = frame_toggle;
            if (frame_number > received+1)
                completions_after_next_sof = completions_after_next_sof + 1;
            $display("TARGET_SWITCH_CASE_PASS frame=%0d mode=%b found=%b count=%0d",
                     received+1, result_motion, found, pixels);
            received = received + 1;
        end
    end

    initial begin
        repeat (5) @(negedge clk); rst_n = 1;
        repeat (8) @(negedge clk);
        queue_result(0, 1, (W-6)*(H-6), 3, W-4, 3, H-4);
        drive_frame(0, 0, 1, 0);
        queue_result(1, 0, 0, 0, 0, 0, 0);
        drive_frame(0, 1, 0, 0);
        queue_result(0, 1, (W-6)*(H-6), 3, W-4, 3, H-4);
        drive_frame(0, 0, 1, 0);
        await_results();
        queue_result(1, 0, W*H, 0, 0, 0, 0);
        drive_frame(1, 1, 1, 1);
        await_results();
        queue_result(1, 1, 16*64, 32, 63, 24, 55);
        drive_frame(2, 1, 0, 0);
        queue_result(0, 0, 0, 0, 0, 0, 0);
        drive_frame(2, 0, 0, 0);
        await_results();
        if (received != 6 || completions_after_next_sof < 3)
            $fatal(1, "Switch did not cover completion crossing SOF: frames=%0d crossings=%0d",
                   received, completions_after_next_sof);
        $display("TARGET_DETECT_SWITCH_PASS frames=%0d completions_after_next_sof=%0d",
                 received, completions_after_next_sof);
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "Target switch test timeout");
    end
endmodule
