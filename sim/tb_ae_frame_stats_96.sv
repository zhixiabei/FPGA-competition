`timescale 1ns/1ps

module tb_ae_frame_stats_96;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg user_small = 0, valid_small = 0, last_small = 0;
    reg [95:0] data_small = 0;
    wire ready_small;
    wire [31:0] sum_small;
    wire [15:0] count_small, bright_small;
    reg user_large = 0, valid_large = 0, last_large = 0;
    reg [95:0] data_large = 0;
    wire ready_large;
    wire [31:0] sum_large;
    wire [15:0] count_large, bright_large;
    integer small_results = 0, large_results = 0;
    integer checks = 0;

    // Full sampling makes the final beat a sampled beat for boundary tests.
    ae_frame_stats_96 #(
        .IMG_WIDTH(32), .IMG_HEIGHT(8),
        .SAMPLE_GROUP_LOG2(0), .SAMPLE_ROW_LOG2(0)
    ) dut_small (
        .I_clk(clk), .I_rst_n(rst_n), .I_tuser(user_small),
        .I_tlast(last_small), .I_tvalid(valid_small), .I_tdata(data_small),
        .O_stats_valid(ready_small), .O_sum_y(sum_small),
        .O_sample_count(count_small), .O_bright_count(bright_small)
    );
    ae_frame_stats_96 dut_large (
        .I_clk(clk), .I_rst_n(rst_n), .I_tuser(user_large),
        .I_tlast(last_large), .I_tvalid(valid_large), .I_tdata(data_large),
        .O_stats_valid(ready_large), .O_sum_y(sum_large),
        .O_sample_count(count_large), .O_bright_count(bright_large)
    );

    always @(posedge clk) begin
        #1;
        if (ready_small) small_results = small_results + 1;
        if (ready_large) large_results = large_results + 1;
    end
    task automatic tick;
        begin
            @(posedge clk);
            #2;
        end
    endtask
    task automatic blank_small;
        begin
            @(negedge clk);
            user_small = 0;
            valid_small = 0;
            last_small = 0;
            tick();
        end
    endtask
    task automatic marker_small;
        begin
            @(negedge clk);
            user_small = 1;
            valid_small = 0;
            last_small = 0;
            tick();
            blank_small();
            blank_small();
        end
    endtask
    task automatic beat_small(input integer beat, input integer gray,
                              input integer marker, input integer bad_last);
        begin
            @(negedge clk);
            user_small = marker;
            valid_small = 1;
            last_small = ((beat % 8) == 7) ^ bad_last;
            // Other three lanes are intentionally saturated and ignored.
            data_small = {{3{gray[7:0]}}, 72'hffffffffffffffffff};
            tick();
        end
    endtask
    task automatic full_small(input integer marker_mode, input integer bad_beat,
                              input integer final_gray);
        integer beat, gray;
        integer expected_sum, expected_bright, before_results;
        begin
            before_results = small_results;
            expected_sum = 0;
            expected_bright = 0;
            if (marker_mode == 0) marker_small();
            for (beat = 0; beat < 64; beat = beat + 1) begin
                gray = (beat == 63) ? final_gray : beat + 10;
                if (gray >= 232)
                    expected_bright = expected_bright + 1;
                else
                    expected_sum = expected_sum + gray;
                beat_small(beat, gray,
                           (marker_mode == 1 && beat == 0) ||
                           (marker_mode == 2 && beat < 5),
                           beat == bad_beat);
                if (beat != 63 && ready_small)
                    $fatal(1, "Incomplete frame published at beat %0d", beat);
                // Gaps do not change frame coordinates or sums.
                if (beat % 9 == 4) blank_small();
            end
            checks = checks + 1;
            if (bad_beat < 0) begin
                if (!ready_small || sum_small != expected_sum ||
                    count_small != 64 || bright_small != expected_bright)
                    $fatal(1, "Complete frame wrong sum/count/bright: %0d/%0d/%0d",
                           sum_small, count_small, bright_small);
                if (small_results != before_results + 1)
                    $fatal(1, "Expected exactly one complete-frame result");
            end else if (ready_small || small_results != before_results)
                $fatal(1, "Malformed TLAST frame published");
            blank_small();
        end
    endtask

    // Independently calculate RGB luminance, exercising single-channel
    // saturation, white/pink colours and both sides of the Y=232 boundary.
    task automatic full_rgb_small;
        integer beat, y_value, expected_sum, expected_bright, before_results;
        reg [23:0] rgb;
        begin
            expected_sum = 0;
            expected_bright = 0;
            before_results = small_results;
            marker_small();
            for (beat = 0; beat < 64; beat = beat + 1) begin
                case (beat % 8)
                    0: rgb = 24'hff0000;
                    1: rgb = 24'h00ff00;
                    2: rgb = 24'h0000ff;
                    3: rgb = 24'hffffff;
                    4: rgb = 24'hffaaaa;
                    5: rgb = 24'he7e7e7;
                    6: rgb = 24'he8e8e8;
                    7: rgb = 24'h000000;
                endcase
                y_value = (rgb[23:16] + 2*rgb[15:8] + rgb[7:0]) / 4;
                if (y_value >= 232)
                    expected_bright = expected_bright + 1;
                else
                    expected_sum = expected_sum + y_value;
                @(negedge clk);
                user_small = 0;
                valid_small = 1;
                last_small = beat % 8 == 7;
                data_small = {rgb, 72'hffffffffffffffffff};
                tick();
                if (beat != 63 && ready_small)
                    $fatal(1, "RGB partial frame generated statistics");
            end
            checks = checks + 1;
            if (!ready_small || count_small != 64 ||
                bright_small != expected_bright || sum_small != expected_sum ||
                small_results != before_results + 1)
                $fatal(1, "RGB metering wrong: sum%0d expected%0d bright%0d expected%0d",
                       sum_small, expected_sum, bright_small, expected_bright);
            blank_small();
        end
    endtask

    task automatic full_white_small;
        integer beat, before_results;
        begin
            before_results = small_results;
            marker_small();
            for (beat = 0; beat < 64; beat = beat + 1)
                beat_small(beat, 255, 0, 0);
            checks = checks + 1;
            if (!ready_small || sum_small != 0 || count_small != 64 ||
                bright_small != 64 || small_results != before_results + 1)
                $fatal(1, "All-white frame must retain total count but exclude all luma");
            blank_small();
        end
    endtask

    integer beat, row, group_index, before_results, expected_y_sum;
    integer red_value, green_value, blue_value;
    initial begin
        repeat (3) tick();
        @(negedge clk);
        rst_n = 1;
        // No marker means no frame, even if a full frame worth of data arrives.
        for (beat = 0; beat < 64; beat = beat + 1)
            beat_small(beat, 200, 0, 0);
        if (small_results != 0) $fatal(1, "Data without frame marker accepted");
        blank_small();
        full_small(0, -1, 255);
        full_small(1, -1, 231);
        full_small(2, -1, 232);

        // Extra data cannot wrap silently into another frame.
        before_results = small_results;
        for (beat = 0; beat < 64; beat = beat + 1)
            beat_small(beat, 255, 0, 0);
        if (small_results != before_results)
            $fatal(1, "Extra unmarked data generated a result");
        blank_small();
        // A new marker abandons a truncated frame, then correctly restarts.
        marker_small();
        for (beat = 0; beat < 29; beat = beat + 1)
            beat_small(beat, 240, 0, 0);
        blank_small();
        repeat (30) tick();
        if (small_results != before_results)
            $fatal(1, "Stopped partial frame generated a result");
        full_small(0, -1, 250);
        full_small(0, 4, 255);
        full_small(0, 7, 255);

        // Reset in the middle invalidates the frame; a marker is needed again.
        marker_small();
        for (beat = 0; beat < 20; beat = beat + 1)
            beat_small(beat, 120, 0, 0);
        @(negedge clk);
        rst_n = 0;
        tick();
        @(negedge clk);
        rst_n = 1;
        before_results = small_results;
        for (beat = 20; beat < 64; beat = beat + 1)
            beat_small(beat, 120, 0, 0);
        if (small_results != before_results)
            $fatal(1, "Reset-truncated frame generated a result");
        blank_small();
        full_small(0, -1, 128);
        full_rgb_small();
        full_white_small();

        // Full 720p frame proves the production sampling count and sparse
        // coordinate selection. Only the sampled lane may affect statistics.
        @(negedge clk);
        user_large = 1;
        tick();
        @(negedge clk);
        user_large = 0;
        repeat (4) tick();
        expected_y_sum = 0;
        for (row = 0; row < 720; row = row + 1) begin
            for (group_index = 0; group_index < 320; group_index = group_index + 1) begin
                red_value = (row + group_index) % 190;
                green_value = (row * 3 + group_index * 2) % 210;
                blue_value = (row * 5 + group_index) % 170;
                if (row % 4 == 0 && group_index % 8 == 0)
                    expected_y_sum = expected_y_sum +
                                     (red_value + green_value * 2 + blue_value) / 4;
                @(negedge clk);
                valid_large = 1;
                last_large = group_index == 319;
                data_large = {red_value[7:0], green_value[7:0], blue_value[7:0],
                              72'hffffffffffffffffff};
                tick();
                if ((row != 719 || group_index != 319) && ready_large)
                    $fatal(1, "Production frame published before completion");
            end
            if (row != 719) begin
                @(negedge clk);
                valid_large = 0;
                last_large = 0;
                repeat (3) tick();
            end
        end
        checks = checks + 1;
        if (!ready_large || large_results != 1 || count_large != 7200 ||
            sum_large != expected_y_sum || bright_large != 0)
            $fatal(1, "720p stats wrong: sum%0d expected%0d count%0d bright%0d",
                   sum_large, expected_y_sum, count_large, bright_large);
        @(negedge clk);
        valid_large = 0;
        last_large = 0;
        repeat (10) tick();
        if (ready_large) $fatal(1, "Stats valid must be one clock pulse");
        $display("AE_FRAME_STATS_PASS small_frames=%0d large_frames=%0d production_samples=%0d checks=%0d",
                 small_results, large_results, count_large, checks);
        $finish;
    end
    initial begin
        #10000000;
        $fatal(1, "Frame metering test timed out");
    end
endmodule
