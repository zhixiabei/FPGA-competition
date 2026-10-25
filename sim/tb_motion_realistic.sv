`timescale 1ns/1ps

// Pixel-level motion stimuli, independent of the detector's internal timing.
// This test records an adjacent-frame reference and checks the actual RTL
// result against complete-image block arithmetic and spatial neighborhoods.
module tb_motion_realistic #(
    parameter integer DIFF_THRESHOLD = 6,
    parameter integer SPATIAL_VOTES = 3,
    parameter integer MIN_BLOCKS = 8,
    parameter integer REQUIRE_DETECTIONS = 0
);
    localparam integer W = 256;
    localparam integer H = 256;
    localparam integer BW = W/8;
    localparam integer BH = H/8;
    localparam integer MAX_RESULTS = 256;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg tuser = 0, tlast = 0, tvalid = 0;
    reg [95:0] tdata = 0;
    wire ready, found, frame_toggle;
    wire [11:0] xmin, xmax, ymin, ymax, center_x, center_y;
    wire [23:0] pixels;
    motion_target_detect_96 #(
        .IMG_WIDTH(W), .IMG_HEIGHT(H), .DIFF_THRESHOLD(DIFF_THRESHOLD),
        .MIN_BLOCKS(MIN_BLOCKS), .GLOBAL_CHANGE_PERCENT(40)
    ) dut (
        .I_clk(clk), .I_rst_n(rst_n), .I_tuser(tuser), .I_tlast(tlast),
        .I_tvalid(tvalid), .I_tdata(tdata), .O_result_ready(ready),
        .O_found(found), .O_xmin(xmin), .O_xmax(xmax),
        .O_ymin(ymin), .O_ymax(ymax), .O_center_x(center_x),
        .O_center_y(center_y), .O_pixels(pixels), .O_frame_toggle(frame_toggle)
    );

    reg [7:0] image [0:H-1][0:W-1];
    integer previous_mean [0:BH-1][0:BW-1];
    integer current_mean [0:BH-1][0:BW-1];
    bit changed [0:BH-1][0:BW-1];
    bit reference_valid = 0;
    string result_name [0:MAX_RESULTS-1];
    integer expected_found [0:MAX_RESULTS-1], expected_count [0:MAX_RESULTS-1];
    integer expected_x0 [0:MAX_RESULTS-1], expected_x1 [0:MAX_RESULTS-1];
    integer expected_y0 [0:MAX_RESULTS-1], expected_y1 [0:MAX_RESULTS-1];
    integer expected_max_votes [0:MAX_RESULTS-1];
    integer expected_max_difference [0:MAX_RESULTS-1];
    bit is_motion [0:MAX_RESULTS-1], required_detection [0:MAX_RESULTS-1];
    integer queued = 0, received = 0, motion_frames = 0, detected_frames = 0;
    integer threshold_misses = 0, spatial_misses = 0, count_misses = 0;
    integer non_motion_frames = 0, false_positives = 0;
    reg previous_toggle = 0;

    task automatic clear_image(input integer value);
        integer x, y;
        begin
            for (y = 0; y < H; y = y+1)
                for (x = 0; x < W; x = x+1)
                    image[y][x] = 8'(value);
        end
    endtask

    task automatic rectangle(input integer x0, input integer y0,
                             input integer width, input integer height,
                             input integer level);
        integer x, y;
        begin
            for (y = y0; y < y0+height; y = y+1)
                for (x = x0; x < x0+width; x = x+1)
                    if (x >= 0 && x < W && y >= 0 && y < H)
                        image[y][x] = 8'(level);
        end
    endtask

    task automatic diagonal_arm(input integer offset_x, input integer offset_y,
                                input integer level);
        integer x, y, lower_x;
        begin
            for (y = 32+offset_y; y < 128+offset_y; y = y+1) begin
                lower_x = 48+offset_x+(y-32-offset_y)/2;
                for (x = lower_x; x < lower_x+12; x = x+1)
                    if (x >= 0 && x < W && y >= 0 && y < H)
                        image[y][x] = 8'(level);
            end
        end
    endtask

    task automatic pixel_noise(input integer seed);
        integer x, y, value;
        reg [31:0] state;
        begin
            state = 32'(seed);
            for (y = 0; y < H; y = y+1) begin
                for (x = 0; x < W; x = x+1) begin
                    state = {state[30:0], state[31]^state[21]^state[1]^state[0]};
                    value = 32+integer'(state[15:0] % 7)-3;
                    image[y][x] = 8'(value);
                end
            end
        end
    endtask

    task automatic sparse_blocks;
        integer index, x, y;
        begin
            for (index = 0; index < 8; index = index+1)
                for (y = 24+(index/4)*64; y < 32+(index/4)*64; y = y+1)
                    for (x = 24+(index%4)*48; x < 32+(index%4)*48; x = x+1)
                        image[y][x] = 160;
        end
    endtask

    task automatic prepare_reference(input string name, input bit moving,
                                     input bit must_detect);
        integer bx, by, x, y, sum, delta, raw_count, max_difference;
        integer wx, wy, dx, dy, votes, max_votes;
        integer box_x0, box_x1, box_y0, box_y1;
        bit has_window, qualify;
        begin
            raw_count = 0; max_difference = 0;
            for (by = 0; by < BH; by = by+1) begin
                for (bx = 0; bx < BW; bx = bx+1) begin
                    sum = 0;
                    for (y = by*8; y < by*8+8; y = y+1)
                        for (x = bx*8; x < bx*8+8; x = x+1)
                            sum = sum+integer'(image[y][x]);
                    current_mean[by][bx] = sum/64;
                    delta = current_mean[by][bx]-previous_mean[by][bx];
                    if (delta < 0) delta = -delta;
                    if (reference_valid && delta > max_difference) max_difference = delta;
                    changed[by][bx] = reference_valid && delta >= DIFF_THRESHOLD;
                    if (changed[by][bx]) raw_count = raw_count+1;
                end
            end
            has_window = 0; max_votes = 0;
            box_x0 = BW; box_x1 = -1; box_y0 = BH; box_y1 = -1;
            for (wy = 0; wy <= BH-3; wy = wy+1) begin
                for (wx = 0; wx <= BW-3; wx = wx+1) begin
                    votes = 0;
                    for (dy = 0; dy < 3; dy = dy+1)
                        for (dx = 0; dx < 3; dx = dx+1)
                            if (changed[wy+dy][wx+dx]) votes = votes+1;
                    if (votes > max_votes) max_votes = votes;
                    if (votes >= SPATIAL_VOTES) begin
                        has_window = 1;
                        for (dy = 0; dy < 3; dy = dy+1) begin
                            for (dx = 0; dx < 3; dx = dx+1) begin
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
            qualify = reference_valid && has_window && raw_count >= MIN_BLOCKS &&
                      raw_count*100 < BW*BH*40;
            result_name[queued] = name;
            expected_found[queued] = qualify;
            expected_count[queued] = raw_count;
            expected_max_votes[queued] = max_votes;
            expected_max_difference[queued] = max_difference;
            expected_x0[queued] = qualify ? box_x0*8 : 0;
            expected_x1[queued] = qualify ? (box_x1+1)*8-1 : 0;
            expected_y0[queued] = qualify ? box_y0*8 : 0;
            expected_y1[queued] = qualify ? (box_y1+1)*8-1 : 0;
            is_motion[queued] = moving;
            required_detection[queued] = must_detect;
            queued = queued+1;
            reference_valid = 1;
            for (by = 0; by < BH; by = by+1)
                for (bx = 0; bx < BW; bx = bx+1)
                    previous_mean[by][bx] = current_mean[by][bx];
        end
    endtask

    task automatic send_frame(input string name, input bit moving,
                              input bit must_detect);
        integer y, group_index, lane, cycles;
        begin
            prepare_reference(name, moving, must_detect);
            @(negedge clk); tuser = 1; tvalid = 0; tlast = 0;
            repeat (2) @(negedge clk);
            tuser = 0;
            for (y = 0; y < H; y = y+1) begin
                for (group_index = 0; group_index < W/4; group_index = group_index+1) begin
                    if ((y*(W/4)+group_index) % 113 == 7) begin
                        @(negedge clk); tvalid = 0; tlast = 0;
                    end
                    @(negedge clk); tvalid = 1; tlast = group_index == W/4-1;
                    for (lane = 0; lane < 4; lane = lane+1)
                        tdata[95-lane*24-:24] = {3{image[y][group_index*4+lane]}};
                end
            end
            @(negedge clk); tvalid = 0; tuser = 0; tlast = 0;
            cycles = 0;
            while (received < queued && cycles < 128) begin
                @(negedge clk); cycles = cycles+1;
            end
            if (received != queued)
                $fatal(1, "Realistic motion result missing for %s", name);
            repeat (4) @(negedge clk);
        end
    endtask

    task automatic reset_detector;
        begin
            @(negedge clk); rst_n = 0; tvalid = 0; tuser = 0; tlast = 0;
            repeat (4) @(negedge clk);
            reference_valid = 0;
            rst_n = 1;
            repeat (4) @(negedge clk);
        end
    endtask

    task automatic rectangle_sequence(input string name, input integer step_x,
                                      input integer step_y, input integer width,
                                      input integer height, input integer foreground,
                                      input bit must_detect);
        integer frame, ox, oy;
        begin
            reset_detector();
            for (frame = 0; frame <= 8; frame = frame+1) begin
                ox = 32+frame*step_x; oy = 32+frame*step_y;
                clear_image(32);
                rectangle(ox, oy, width, height, foreground);
                send_frame($sformatf("%s_f%0d_dx%0d_dy%0d", name, frame, step_x, step_y),
                           frame != 0, must_detect && frame != 0);
            end
            send_frame({name, "_stopped"}, 0, 0);
        end
    endtask

    always @(posedge clk) begin
        #1;
        if (!rst_n) previous_toggle = 0;
        else if (ready) begin
            if (received >= queued)
                $fatal(1, "Unrequested realistic result");
            if (found !== expected_found[received][0] ||
                pixels !== expected_count[received]*64 ||
                xmin !== expected_x0[received][11:0] ||
                xmax !== expected_x1[received][11:0] ||
                ymin !== expected_y0[received][11:0] ||
                ymax !== expected_y1[received][11:0] ||
                center_x !== (expected_x0[received]+expected_x1[received])/2 ||
                center_y !== (expected_y0[received]+expected_y1[received])/2)
                $fatal(1, "%s RTL/ref mismatch found=%b/%0d pixels=%0d/%0d box=%0d,%0d..%0d,%0d expected=%0d,%0d..%0d,%0d",
                       result_name[received], found, expected_found[received],
                       pixels, expected_count[received]*64, xmin, ymin, xmax, ymax,
                       expected_x0[received], expected_y0[received],
                       expected_x1[received], expected_y1[received]);
            if (frame_toggle !== ~previous_toggle)
                $fatal(1, "Realistic result toggle did not change");
            previous_toggle = frame_toggle;
            if (is_motion[received]) begin
                motion_frames = motion_frames+1;
                if (found) detected_frames = detected_frames+1;
                else if (expected_count[received] == 0) threshold_misses = threshold_misses+1;
                else if (expected_max_votes[received] < SPATIAL_VOTES) spatial_misses = spatial_misses+1;
                else if (expected_count[received] < MIN_BLOCKS) count_misses = count_misses+1;
            end else begin
                non_motion_frames = non_motion_frames+1;
                if (found) false_positives = false_positives+1;
            end
            $display("REALISTIC_CASE name=%s moving=%b found=%b blocks=%0d max_votes=%0d max_mean_difference=%0d box=%0d,%0d..%0d,%0d",
                     result_name[received], is_motion[received], found,
                     expected_count[received], expected_max_votes[received],
                     expected_max_difference[received], xmin, ymin, xmax, ymax);
            if (REQUIRE_DETECTIONS && required_detection[received] && !found)
                $fatal(1, "Required natural motion was suppressed: %s", result_name[received]);
            received = received+1;
        end
    end

    integer step_index, step_size, frame;
    initial begin
        for (step_index = 0; step_index < 5; step_index = step_index+1) begin
            step_size = 1 << step_index;
            rectangle_sequence("flat_contrast128_horizontal", step_size, 0, 80, 96, 160, 1);
        end
        for (step_index = 0; step_index < 5; step_index = step_index+1) begin
            step_size = 1 << step_index;
            rectangle_sequence("flat_contrast48_horizontal", step_size, 0, 80, 96, 80, 1);
        end
        for (step_index = 0; step_index < 5; step_index = step_index+1) begin
            step_size = 1 << step_index;
            rectangle_sequence("vertical_arm12px", step_size, 0, 12, 96, 160, 1);
        end
        for (step_index = 0; step_index < 5; step_index = step_index+1) begin
            step_size = 1 << step_index;
            rectangle_sequence("flat_diagonal", step_size, step_size, 64, 64, 160, 1);
        end
        reset_detector();
        for (frame = 0; frame <= 8; frame = frame+1) begin
            clear_image(32);
            diagonal_arm(frame*2, frame, 160);
            send_frame($sformatf("slanted_arm_f%0d_dx2_dy1", frame),
                       frame != 0, frame != 0);
        end
        send_frame("slanted_arm_stopped", 0, 0);
        reset_detector();
        clear_image(32);
        send_frame("nuisance_clean_reference", 0, 0);
        for (frame = 0; frame < 4; frame = frame+1) begin
            pixel_noise(32'hfa326db1+frame*32'h137da);
            send_frame($sformatf("independent_pixel_noise_amplitude3_f%0d", frame), 0, 0);
        end
        clear_image(32);
        send_frame("pixel_noise_stops", 0, 0);
        sparse_blocks();
        send_frame("eight_spatially_separate_blocks", 0, 0);
        clear_image(32);
        send_frame("eight_spatially_separate_blocks_clear", 0, 0);
        clear_image(96);
        send_frame("global_brightness_step64", 0, 0);
        send_frame("global_brightness_stable", 0, 0);
        clear_image(99);
        send_frame("global_brightness_step3", 0, 0);
        send_frame("small_brightness_stable", 0, 0);
        if (received != 222 || motion_frames != 168 || non_motion_frames != 54 || false_positives != 0)
            $fatal(1, "Incomplete realistic coverage received=%0d moving=%0d",
                   received, motion_frames);
        $display("MOTION_REALISTIC_PASS frames=%0d moving=%0d detected=%0d non_motion=%0d false_positives=%0d threshold_misses=%0d spatial_misses=%0d count_misses=%0d threshold=%0d votes=%0d",
                 received, motion_frames, detected_frames, non_motion_frames, false_positives, threshold_misses,
                 spatial_misses, count_misses, DIFF_THRESHOLD, SPATIAL_VOTES);
        $finish;
    end

    initial begin
        #50000000;
        $fatal(1, "Realistic motion timeout");
    end
endmodule
