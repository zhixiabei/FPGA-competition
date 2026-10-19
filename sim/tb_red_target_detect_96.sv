`timescale 1ns/1ps
// Independent pixel-array reference, including the full centered 3x3 filter.
// Override W/H with vsim -gW=1280 -gH=720 for the camera geometry.
module tb_red_target_detect_96 #(
    parameter integer W = 64,
    parameter integer H = 48
);
    localparam integer GROUPS = W/4;
    localparam integer MAX_RESULTS = 32;
    localparam integer RED_MIN = 24;
    localparam integer RED_DELTA = 6;
    localparam integer MIN_PIXELS = 128;
    localparam integer MIN_WIDTH = 8;
    localparam integer MIN_HEIGHT = 8;
    localparam integer RESULT_LATENCY = 5;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg valid = 1'b0;
    reg user = 1'b0;
    reg [95:0] data = 96'd0;
    wire ready, found, frame_toggle;
    wire [11:0] xmin, xmax, ymin, ymax, center_x, center_y;
    wire [23:0] pixels;
    always #5 clk = ~clk;

    red_target_detect_96 #(
        .IMG_WIDTH(W), .IMG_HEIGHT(H),
        .RED_MIN(RED_MIN), .RED_DELTA(RED_DELTA),
        .MIN_PIXELS(MIN_PIXELS), .MIN_WIDTH(MIN_WIDTH), .MIN_HEIGHT(MIN_HEIGHT)
    ) dut (
        .I_clk(clk), .I_rst_n(rst_n), .I_tuser(user),
        .I_tvalid(valid), .I_tdata(data), .I_color_mode(2'd0),
        .O_result_ready(ready), .O_found(found),
        .O_xmin(xmin), .O_xmax(xmax), .O_ymin(ymin), .O_ymax(ymax),
        .O_center_x(center_x), .O_center_y(center_y),
        .O_pixels(pixels), .O_frame_toggle(frame_toggle)
    );

    reg [23:0] image [0:W*H-1];
    reg reference_mask [0:W*H-1];
    integer expected_count [0:MAX_RESULTS-1];
    integer expected_xmin [0:MAX_RESULTS-1];
    integer expected_xmax [0:MAX_RESULTS-1];
    integer expected_ymin [0:MAX_RESULTS-1];
    integer expected_ymax [0:MAX_RESULTS-1];
    integer expected_found [0:MAX_RESULTS-1];
    integer accepted_final_cycle [0:MAX_RESULTS-1];
    integer queued = 0;
    integer checked = 0;
    integer failures = 0;
    integer bubbles = 0;
    integer color_checks = 0;
    reg previous_toggle = 1'b0;
    integer cycle_index = 0;
    integer accepted_beats = 0;
    integer captured_frames = 0;
    reg monitor_pending = 0;
    reg monitor_open = 0;
    reg monitor_start;

    // Scalar integer channel arithmetic is independent of the DUT's lane
    // packing, bit extensions and streaming implementation.
    function reference_red;
        input [23:0] rgb;
        integer r, g, b, other_min, other_max, hue_distance;
        begin
            r = rgb[23:16];
            g = rgb[15:8];
            b = rgb[7:0];
            other_min = g < b ? g : b;
            other_max = g > b ? g : b;
            hue_distance = g > b ? g-b : b-g;
            reference_red = (r >= RED_MIN) &&
                            (r-g >= RED_DELTA) && (r-b >= RED_DELTA) &&
                            (2*r >= 3*other_max) &&
                            (3*hue_distance <= r-other_min);
        end
    endfunction

    task build_image;
        input integer pattern;
        integer x, y, n;
        begin
            for (y = 0; y < H; y = y+1) begin
                for (x = 0; x < W; x = x+1) begin
                    n = y*W+x;
                    case (pattern)
                        0: image[n] = (x == W/2 && y == H/2) ? 24'hff0000 : 24'h000000;
                        1: image[n] = (x >= W/4 && x < 3*W/4 &&
                                       y >= H/4 && y < 3*H/4) ? 24'hbf0812 : 24'h182020;
                        2: image[n] = 24'hfffafa;
                        3: image[n] = 24'hff0000;
                        4: image[n] = (x >= 3*W/4 && y >= 2*H/3) ? 24'hff0000 : 24'h000000;
                        6: image[n] = (x >= W/4 && x < 3*W/4 &&
                                       y >= H/4 && y < 3*H/4) ? 24'h320f0c : 24'h101010;
                        7: image[n] = (x >= W/4 && x < 3*W/4 &&
                                       y >= H/4 && y < 3*H/4) ? 24'h230a08 : 24'h101010;
                        8: image[n] = 24'hffaaBE;
                        9: image[n] = 24'he632dc;
                        10: image[n] = 24'hff780a;
                        11: image[n] = (x >= W/4 && x < 3*W/4 &&
                                        y >= H/4 && y < 3*H/4) ? 24'hff140f : 24'hffaaBE;
                        default: image[n] = ((n*13+7)%11 < 7) ? 24'hbf0812 : 24'h7f8081;
                    endcase
                end
            end
        end
    endtask

    // Explicit color witnesses protect the intended policy, independently
    // of the general reference formula. Every lane sees each witness.
    task check_color;
        input [23:0] rgb;
        input expected;
        begin
            valid = 0; user = 0; data = {4{rgb}};
            #1;
            if (reference_red(rgb) !== expected || dut.red_mask !== {4{expected}})
                $fatal(1, "Color policy mismatch RGB=%h reference=%b mask=%b expected=%b",
                       rgb, reference_red(rgb), dut.red_mask, expected);
            color_checks = color_checks+4;
        end
    endtask

    task check_color_policy;
        integer n, lane, luminance;
        reg [23:0] rgb;
        reg [3:0] expected_mask;
        reg [31:0] random_state;
        begin
            check_color(24'h320f0c, 1); // Dark red: (50,15,12).
            check_color(24'h230a08, 1); // Dark red: (35,10,8).
            check_color(24'hff140f, 1); // Saturated red must not be rejected.
            check_color(24'hff0000, 1);
            check_color(24'hffaaaa, 1); // Exact normalized saturation boundary.
            check_color(24'hffabab, 0);
            check_color(24'hffaaaa + 24'd20, 0);
            check_color(24'hffaaBE, 0); // Low-saturation highlight/pink.
            check_color(24'he632dc, 0); // Purple: (230,50,220).
            check_color(24'he60a82, 0); // Magenta: (230,10,130).
            check_color(24'hff780a, 0); // Orange: (255,120,10).
            check_color(24'hffd20a, 0); // Yellow.
            check_color(24'hfffaFa, 0); // White highlight.
            check_color(24'h404040, 0); // Gray.
            check_color(24'h171000, 0); // Below the brightness floor.
            check_color(24'h180806, 1); // Floor with strong red chroma.
            check_color(24'h181717, 0); // Near-black channel noise.
            check_color(24'hff5500, 1); // Exactly +20 degree hue boundary.
            check_color(24'hff5600, 0);
            check_color(24'hff0055, 1); // Exactly -20 degree hue boundary.
            check_color(24'hff0056, 0);
            // Linear brightness changes preserve the normalized color
            // classification once the noise/brightness floor is reached.
            for (luminance = 8; luminance <= 255; luminance = luminance+1) begin
                rgb = (luminance << 16) | ((luminance/3) << 8) | (luminance/4);
                check_color(rgb, luminance >= RED_MIN);
            end
            // Independent lanes, broad channel coverage and deterministic
            // pseudo-random jumps exercise extension/overflow boundaries.
            random_state = 32'h712d481f;
            for (n = 0; n < 16384; n = n+1) begin
                for (lane = 0; lane < 4; lane = lane+1) begin
                    random_state = random_state*32'd1664525+32'd1013904223;
                    rgb = random_state[31:8];
                    data[95-lane*24-:24] = rgb;
                    expected_mask[lane] = reference_red(rgb);
                end
                #1;
                if (dut.red_mask !== expected_mask)
                    $fatal(1, "Color mask mismatch data=%h got=%b expected=%b",
                           data, dut.red_mask, expected_mask);
                color_checks = color_checks+4;
            end
        end
    endtask

    task queue_reference;
        integer x, y, dx, dy, votes, count, bx0, bx1, by0, by1;
        begin
            if (queued >= MAX_RESULTS) $fatal(1, "Reference queue overflow");
            count = 0;
            bx0 = W-1; bx1 = 0; by0 = H-1; by1 = 0;
            for (y = 0; y < H; y = y+1)
                for (x = 0; x < W; x = x+1)
                    reference_mask[y*W+x] = reference_red(image[y*W+x]);
            for (y = 1; y < H-1; y = y+1) begin
                for (x = 1; x < W-1; x = x+1) begin
                    votes = 0;
                    for (dy = -1; dy <= 1; dy = dy+1)
                        for (dx = -1; dx <= 1; dx = dx+1)
                            votes = votes + reference_mask[(y+dy)*W+x+dx];
                    if (votes >= 5) begin
                        count = count+1;
                        if (x < bx0) bx0 = x;
                        if (x > bx1) bx1 = x;
                        if (y < by0) by0 = y;
                        if (y > by1) by1 = y;
                    end
                end
            end
            expected_count[queued] = count;
            expected_found[queued] = count >= MIN_PIXELS && bx0 <= bx1 && by0 <= by1 &&
                                     bx1-bx0+1 >= MIN_WIDTH && by1-by0+1 >= MIN_HEIGHT;
            expected_xmin[queued] = expected_found[queued] ? bx0 : 0;
            expected_xmax[queued] = expected_found[queued] ? bx1 : 0;
            expected_ymin[queued] = expected_found[queued] ? by0 : 0;
            expected_ymax[queued] = expected_found[queued] ? by1 : 0;
            queued = queued+1;
        end
    endtask

    // marker=2: early pulse in blanking; 1: pulse on the first valid beat;
    // 0: no marker. There is no automatic gap after the final beat, so two
    // successive calls can drive truly continuous full frames.
    task drive_frame;
        input integer marker;
        input integer with_bubbles;
        integer y, group_index, beat_index;
        begin
            if (marker == 2) begin
                @(negedge clk); valid = 0; user = 1;
                @(negedge clk); user = 0;
                repeat (5) @(negedge clk);
            end
            for (y = 0; y < H; y = y+1) begin
                for (group_index = 0; group_index < GROUPS; group_index = group_index+1) begin
                    @(negedge clk);
                    valid = 1;
                    user = marker == 1 && y == 0 && group_index == 0;
                    beat_index = y*GROUPS+group_index;
                    data = {image[y*W+group_index*4],
                            image[y*W+group_index*4+1],
                            image[y*W+group_index*4+2],
                            image[y*W+group_index*4+3]};
                    if (with_bubbles && (beat_index%17 == 5 || beat_index%29 == 11)) begin
                        @(negedge clk); valid = 0; user = 0; bubbles = bubbles+1;
                        if (beat_index%29 == 11) begin
                            @(negedge clk); bubbles = bubbles+1;
                        end
                    end
                end
            end
        end
    endtask

    task idle;
        input integer cycles;
        begin
            @(negedge clk); valid = 0; user = 0; data = 0;
            repeat (cycles) @(negedge clk);
        end
    endtask

    task reset_detector;
        begin
            @(negedge clk); rst_n = 0; valid = 0; user = 0; data = 0;
            repeat (2) @(negedge clk);
            if (ready !== 0 || found !== 0 || frame_toggle !== 0 ||
                pixels !== 0 || xmin !== 0 || xmax !== 0 ||
                ymin !== 0 || ymax !== 0 || center_x !== 0 || center_y !== 0)
                $fatal(1, "Reset did not clear the published result");
            rst_n = 1;
        end
    endtask

    // Check every publication automatically, including during back-to-back
    // frames. Expected boxes and counts come solely from the pixel reference.
    always @(posedge clk) begin
        cycle_index = cycle_index+1;
        if (!rst_n) begin
            accepted_beats = 0;
            monitor_pending = 0;
            monitor_open = 0;
        end else begin
            monitor_start = monitor_pending || user;
            if (user) monitor_pending = 1;
            if (valid && (monitor_open || monitor_start)) begin
                if (monitor_start) accepted_beats = 0;
                accepted_beats = accepted_beats+1;
                monitor_pending = 0;
                monitor_open = 1;
                if (accepted_beats == W*H/4) begin
                    accepted_final_cycle[captured_frames] = cycle_index;
                    captured_frames = captured_frames+1;
                    accepted_beats = 0;
                end
            end
        end
        #1;
        if (!rst_n) previous_toggle = 0;
        else if (ready) begin
            if (checked >= queued) $fatal(1, "Unexpected result publication");
            if (cycle_index-accepted_final_cycle[checked] != RESULT_LATENCY)
                $fatal(1, "Result latency is %0d, expected %0d",
                       cycle_index-accepted_final_cycle[checked], RESULT_LATENCY);
            if (pixels !== expected_count[checked] ||
                found !== expected_found[checked][0] ||
                frame_toggle === previous_toggle ||
                xmin !== expected_xmin[checked] || xmax !== expected_xmax[checked] ||
                ymin !== expected_ymin[checked] || ymax !== expected_ymax[checked] ||
                center_x !== ((expected_xmin[checked]+expected_xmax[checked])/2) ||
                center_y !== ((expected_ymin[checked]+expected_ymax[checked])/2)) begin
                failures = failures+1;
                $display("FAIL result=%0d got count=%0d found=%b box=(%0d,%0d)-(%0d,%0d), center=(%0d,%0d)",
                         checked, pixels, found, xmin, ymin, xmax, ymax, center_x, center_y);
                $display("Expected count=%0d found=%0d box=(%0d,%0d)-(%0d,%0d)",
                         expected_count[checked], expected_found[checked],
                         expected_xmin[checked], expected_ymin[checked],
                         expected_xmax[checked], expected_ymax[checked]);
            end else
                $display("PASS result=%0d count=%0d found=%b box=(%0d,%0d)-(%0d,%0d)",
                         checked, pixels, found, xmin, ymin, xmax, ymax);
            previous_toggle = frame_toggle;
            checked = checked+1;
        end
    end

    initial begin
        if (W%4 != 0 || W < 32 || H < 32) $fatal(1, "Unsupported test dimensions");
        reset_detector;
        check_color_policy;
        // Startup valid data without SOF is ignored.
        repeat (8) begin @(negedge clk); valid = 1; data = {4{24'hff0000}}; end
        idle(3);
        if (checked != 0) $fatal(1, "Startup data published without a frame marker");

        build_image(0); queue_reference; drive_frame(2,1); idle(3);
        build_image(1); queue_reference; drive_frame(1,1); idle(RESULT_LATENCY+2);

        // Exposure/color policy additions retain the original geometry,
        // result publication latency and continuous-frame behavior.
        build_image(6); queue_reference; drive_frame(2,1); idle(3);
        build_image(7); queue_reference; drive_frame(1,1); idle(3);
        build_image(8); queue_reference; drive_frame(0,0); idle(3);
        build_image(9); queue_reference; drive_frame(0,0); idle(3);
        build_image(10); queue_reference; drive_frame(0,0); idle(3);
        build_image(11); queue_reference; drive_frame(2,1); idle(RESULT_LATENCY+2);
        build_image(2); queue_reference; drive_frame(0,0); idle(3);
        build_image(3); queue_reference; drive_frame(2,0); idle(3);

        // An early marker discards a truncated frame and resynchronizes.
        repeat (5) begin @(negedge clk); valid = 1; data = {4{24'hff0000}}; end
        idle(3);
        build_image(4); queue_reference; drive_frame(2,1); idle(3);

        // Two complete frames have no extra SOF and no gap between them.
        build_image(5); queue_reference; drive_frame(0,0);
        build_image(1); queue_reference; drive_frame(0,0); idle(3);

        // Reset mid-frame; old mask RAM must never leak into a new frame.
        repeat (5) begin @(negedge clk); valid = 1; data = {4{24'hff0000}}; end
        reset_detector;
        repeat (8) begin @(negedge clk); valid = 1; data = {4{24'hff0000}}; end
        idle(3);
        build_image(2); queue_reference; drive_frame(2,1); idle(3);
        build_image(1); queue_reference; drive_frame(1,1); idle(RESULT_LATENCY+2);

        if (checked != queued) $fatal(1, "Missing result: queued=%0d checked=%0d", queued, checked);
        if (bubbles == 0) $fatal(1, "The test did not exercise valid bubbles");
        if (failures != 0) $fatal(1, "%0d reference mismatches", failures);
        $display("RED_TARGET_LIGHTING_PASS W=%0d H=%0d results=%0d bubbles=%0d color_checks=%0d",
                 W,H,checked,bubbles,color_checks);
        $finish;
    end

    initial begin
        #(W*H*100);
        $fatal(1, "Timeout");
    end
endmodule
