`timescale 1ns/1ps

module tb_ae_frame_stats_raw10_4x;
    localparam integer SMALL_WIDTH = 64;
    localparam integer SMALL_HEIGHT = 16;
    localparam integer SMALL_GROUPS = SMALL_WIDTH / 4;
    localparam integer SMALL_SAMPLES = 32;

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;

    reg small_user = 0, small_valid = 0, small_last = 0;
    reg [39:0] small_data = 0;
    wire small_ready, black_ready;
    wire [31:0] small_sum, black_sum;
    wire [15:0] small_count, small_bright;
    wire [15:0] black_count, black_bright;

    reg large_user = 0, large_valid = 0, large_last = 0;
    reg [39:0] large_data = 0;
    wire large_ready;
    wire [31:0] large_sum;
    wire [15:0] large_count, large_bright;

    integer small_results = 0;
    integer black_results = 0;
    integer large_results = 0;
    integer checks = 0;

    ae_frame_stats_raw10_4x #(
        .IMG_WIDTH(SMALL_WIDTH), .IMG_HEIGHT(SMALL_HEIGHT)
    ) dut_small (
        .I_clk(clk), .I_rst_n(rst_n), .I_tuser(small_user),
        .I_tlast(small_last), .I_tvalid(small_valid), .I_tdata(small_data),
        .O_stats_valid(small_ready), .O_sum_y(small_sum),
        .O_sample_count(small_count), .O_bright_count(small_bright)
    );

    ae_frame_stats_raw10_4x #(
        .IMG_WIDTH(SMALL_WIDTH), .IMG_HEIGHT(SMALL_HEIGHT),
        .BLACK_LEVEL(64)
    ) dut_black (
        .I_clk(clk), .I_rst_n(rst_n), .I_tuser(small_user),
        .I_tlast(small_last), .I_tvalid(small_valid), .I_tdata(small_data),
        .O_stats_valid(black_ready), .O_sum_y(black_sum),
        .O_sample_count(black_count), .O_bright_count(black_bright)
    );

    ae_frame_stats_raw10_4x dut_large (
        .I_clk(clk), .I_rst_n(rst_n), .I_tuser(large_user),
        .I_tlast(large_last), .I_tvalid(large_valid), .I_tdata(large_data),
        .O_stats_valid(large_ready), .O_sum_y(large_sum),
        .O_sample_count(large_count), .O_bright_count(large_bright)
    );

    always @(posedge clk) begin
        #1;
        if (small_ready) small_results = small_results + 1;
        if (black_ready) black_results = black_results + 1;
        if (large_ready) large_results = large_results + 1;
    end

    task automatic tick;
        begin
            @(posedge clk);
            #2;
        end
    endtask

    function automatic integer meter_value(input integer raw_value,
                                             input integer black_level);
        integer corrected;
        integer value_8;
        begin
            corrected = (raw_value > black_level) ? raw_value - black_level : 0;
            value_8 = corrected >> 2;
            meter_value = (value_8 > 192) ? 192 : value_8;
        end
    endfunction

    function automatic integer is_bright(input integer raw_value,
                                          input integer black_level);
        integer corrected;
        begin
            corrected = (raw_value > black_level) ? raw_value - black_level : 0;
            is_bright = ((corrected >> 2) >= 192);
        end
    endfunction

    function automatic integer pattern_raw(input integer pattern,
                                             input integer row,
                                             input integer group_index,
                                             input integer lane);
        integer parity;
        begin
            parity = (row + group_index + lane) & 1;
            case (pattern)
                0: pattern_raw = (row * 37 + group_index * 53 + lane * 211) & 1023;
                1: pattern_raw = parity ? 764 : 400; // Y191 / Y100
                2: pattern_raw = parity ? 768 : 420; // Y192 / Y105
                3: pattern_raw = 1023;
                4: begin
                    case (lane)
                        0: pattern_raw = 63;
                        1: pattern_raw = 64;
                        2: pattern_raw = 831;
                        default: pattern_raw = 832;
                    endcase
                end
                default: pattern_raw = 0;
            endcase
        end
    endfunction

    task automatic blank_small;
        begin
            @(negedge clk);
            small_user = 0;
            small_valid = 0;
            small_last = 0;
            small_data = 0;
            tick();
        end
    endtask

    task automatic marker_small;
        begin
            @(negedge clk);
            small_user = 1;
            small_valid = 0;
            small_last = 0;
            tick();
            blank_small();
        end
    endtask

    task automatic drive_small_beat(input integer beat_index,
                                    input integer pattern,
                                    input integer marker_mode,
                                    input integer bad_beat);
        integer row;
        integer group_index;
        integer lane;
        reg [39:0] packed_value;
        begin
            row = beat_index / SMALL_GROUPS;
            group_index = beat_index % SMALL_GROUPS;
            packed_value = 0;
            for (lane = 0; lane < 4; lane = lane + 1)
                packed_value[39-lane*10 -: 10] =
                    pattern_raw(pattern, row, group_index, lane);
            @(negedge clk);
            small_user = (marker_mode == 1 && beat_index == 0) ||
                         (marker_mode == 2 && beat_index < 5);
            small_valid = 1;
            small_last = (group_index == SMALL_GROUPS-1) ^ (beat_index == bad_beat);
            small_data = packed_value;
            tick();
        end
    endtask

    task automatic send_small_frame(input integer pattern,
                                    input integer marker_mode,
                                    input integer bad_beat,
                                    input integer expect_result);
        integer beat_index;
        integer row;
        integer group_index;
        integer lane;
        integer raw_value;
        integer expected_sum;
        integer expected_bright;
        integer expected_black_sum;
        integer expected_black_bright;
        integer before_small;
        integer before_black;
        begin
            expected_sum = 0;
            expected_bright = 0;
            expected_black_sum = 0;
            expected_black_bright = 0;
            before_small = small_results;
            before_black = black_results;
            if (marker_mode == 0)
                marker_small();
            for (beat_index = 0;
                 beat_index < SMALL_GROUPS * SMALL_HEIGHT;
                 beat_index = beat_index + 1) begin
                row = beat_index / SMALL_GROUPS;
                group_index = beat_index % SMALL_GROUPS;
                if ((row % 8) < 2 && (group_index % 8) == 0) begin
                    for (lane = 0; lane < 4; lane = lane + 1) begin
                        raw_value = pattern_raw(pattern, row, group_index, lane);
                        expected_sum = expected_sum + meter_value(raw_value, 0);
                        expected_bright = expected_bright + is_bright(raw_value, 0);
                        expected_black_sum = expected_black_sum + meter_value(raw_value, 64);
                        expected_black_bright = expected_black_bright +
                                                is_bright(raw_value, 64);
                    end
                end
                drive_small_beat(beat_index, pattern, marker_mode, bad_beat);
                if (beat_index != SMALL_GROUPS * SMALL_HEIGHT - 1 &&
                    (small_ready || black_ready))
                    $fatal(1, "Partial RAW frame published statistics");
                if ((beat_index % 23) == 7)
                    blank_small();
            end
            checks = checks + 1;
            if (expect_result) begin
                if (!small_ready || !black_ready ||
                    small_sum != expected_sum || small_count != SMALL_SAMPLES ||
                    small_bright != expected_bright ||
                    black_sum != expected_black_sum || black_count != SMALL_SAMPLES ||
                    black_bright != expected_black_bright)
                    $fatal(1,
                        "RAW stats mismatch sum=%0d/%0d bright=%0d/%0d black=%0d/%0d black_bright=%0d/%0d",
                        small_sum, expected_sum, small_bright, expected_bright,
                        black_sum, expected_black_sum,
                        black_bright, expected_black_bright);
                if (small_results != before_small + 1 ||
                    black_results != before_black + 1)
                    $fatal(1, "Expected exactly one result per complete RAW frame");
            end else if (small_ready || black_ready ||
                         small_results != before_small || black_results != before_black)
                $fatal(1, "Malformed or unmarked RAW frame published statistics");
            blank_small();
        end
    endtask

    integer beat_index;
    integer row;
    integer group_index;
    integer lane;
    integer raw_value;
    integer expected_large_sum;
    integer expected_large_bright;
    integer before_results;
    integer monotonic_sum_a;
    integer monotonic_sum_b;
    reg [39:0] packed_large;
    initial begin
        repeat (3) tick();
        @(negedge clk);
        rst_n = 1;

        // A complete stream without a frame marker must be ignored.
        send_small_frame(0, 3, -1, 0);
        send_small_frame(0, 0, -1, 1);
        send_small_frame(4, 1, -1, 1);
        send_small_frame(3, 2, -1, 1);

        // Raising one half from Y100/Y191 to Y105/Y192 must never reduce sum.
        send_small_frame(1, 0, -1, 1);
        monotonic_sum_a = small_sum;
        if (small_bright != 0 || monotonic_sum_a != 4656)
            $fatal(1, "Unexpected first monotonic fixture %0d/%0d",
                   monotonic_sum_a, small_bright);
        send_small_frame(2, 0, -1, 1);
        monotonic_sum_b = small_sum;
        if (monotonic_sum_b != 4752 || small_bright != 16 ||
            monotonic_sum_b < monotonic_sum_a)
            $fatal(1, "RAW capped sum is not monotonic: %0d -> %0d bright=%0d",
                   monotonic_sum_a, monotonic_sum_b, small_bright);
        send_small_frame(3, 0, -1, 1);
        if (small_sum != SMALL_SAMPLES * 192 ||
            small_bright != SMALL_SAMPLES)
            $fatal(1, "Full-white RAW frame did not cap every component");

        // Bad TLAST and a truncated frame cannot publish. A new marker resyncs.
        send_small_frame(0, 0, 17, 0);
        marker_small();
        for (beat_index = 0; beat_index < 41; beat_index = beat_index + 1)
            drive_small_beat(beat_index, 0, 3, -1);
        before_results = small_results;
        repeat (20) tick();
        if (small_results != before_results)
            $fatal(1, "Stopped partial RAW frame generated statistics");
        send_small_frame(0, 0, -1, 1);

        // Reset in a partial frame invalidates it and requires a new marker.
        marker_small();
        for (beat_index = 0; beat_index < 29; beat_index = beat_index + 1)
            drive_small_beat(beat_index, 0, 3, -1);
        @(negedge clk);
        rst_n = 0;
        tick();
        @(negedge clk);
        rst_n = 1;
        before_results = small_results;
        for (beat_index = 29;
             beat_index < SMALL_GROUPS * SMALL_HEIGHT;
             beat_index = beat_index + 1)
            drive_small_beat(beat_index, 0, 3, -1);
        if (small_results != before_results)
            $fatal(1, "Reset-truncated RAW frame generated statistics");
        blank_small();

        // One complete 720p frame proves the production 28,800-component count.
        @(negedge clk);
        large_user = 1;
        large_valid = 0;
        large_last = 0;
        tick();
        @(negedge clk);
        large_user = 0;
        tick();
        expected_large_sum = 0;
        expected_large_bright = 0;
        before_results = large_results;
        for (row = 0; row < 720; row = row + 1) begin
            for (group_index = 0; group_index < 320; group_index = group_index + 1) begin
                packed_large = 0;
                for (lane = 0; lane < 4; lane = lane + 1) begin
                    raw_value = (row * 29 + group_index * 47 + lane * 193) & 1023;
                    packed_large[39-lane*10 -: 10] = raw_value;
                    if ((row % 8) < 2 && (group_index % 8) == 0) begin
                        expected_large_sum = expected_large_sum + meter_value(raw_value, 0);
                        expected_large_bright = expected_large_bright +
                                                is_bright(raw_value, 0);
                    end
                end
                @(negedge clk);
                large_valid = 1;
                large_last = group_index == 319;
                large_data = packed_large;
                tick();
                if ((row != 719 || group_index != 319) && large_ready)
                    $fatal(1, "720p RAW statistics published before frame completion");
            end
            if (row != 719) begin
                @(negedge clk);
                large_valid = 0;
                large_last = 0;
                repeat (2) tick();
            end
        end
        checks = checks + 1;
        if (!large_ready || large_results != before_results + 1 ||
            large_count != 28800 || large_sum != expected_large_sum ||
            large_bright != expected_large_bright)
            $fatal(1,
                "720p RAW stats wrong sum=%0d/%0d count=%0d bright=%0d/%0d",
                large_sum, expected_large_sum, large_count,
                large_bright, expected_large_bright);
        @(negedge clk);
        large_valid = 0;
        large_last = 0;
        repeat (10) tick();
        if (large_ready) $fatal(1, "RAW stats valid must be one clock pulse");

        $display("AE_FRAME_STATS_RAW10_PASS small=%0d black=%0d large=%0d samples=%0d checks=%0d",
                 small_results, black_results, large_results, large_count, checks);
        $finish;
    end

    initial begin
        #10000000;
        $fatal(1, "RAW frame metering test timed out");
    end
endmodule
