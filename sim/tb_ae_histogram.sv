`timescale 1ns/1ps

module ae_histogram_reference #(
    parameter integer WIDTH = 64,
    parameter integer HEIGHT = 16,
    parameter integer GROUP_LOG2 = 3,
    parameter integer BIN_BITS = 5,
    parameter integer BLACK = 0,
    parameter integer HIST_ENABLE = 1
) (
    input wire clk, rst_n,
    input wire tuser, tlast, tvalid,
    input wire [39:0] tdata,
    input wire ref_first, ref_sample, ref_check_bins,
    input wire expect_hist, expect_legacy,
    output integer results,
    output integer bucket_checks
);
    localparam integer BINS = 1 << BIN_BITS;
    localparam integer BRIGHT = HIST_ENABLE ? 248 : 192;
    wire stats_valid;
    wire direct_valid;
    wire [31:0] sum_y;
    wire [31:0] direct_sum;
    wire [15:0] sample_count, bright_count, clip_count;
    wire [15:0] direct_count, direct_bright, direct_clip;
    wire [4:0] p5, p50, p95, p99;
    wire [4:0] direct_p5, direct_p50, direct_p95, direct_p99;
    wire [99:0] held_payload =
        {sum_y, sample_count, bright_count, clip_count, p5, p50, p95, p99};
    wire [99:0] direct_payload =
        {direct_sum, direct_count, direct_bright, direct_clip,
         direct_p5, direct_p50, direct_p95, direct_p99};
    integer reference_bins [0:BINS-1];
    integer reference_count, reference_sum, reference_bright, reference_clip;
    integer exact_frame_count;
    integer r, g, j, raw_value, corrected, value8, bucket;
    integer bucket_sum;
    reg previous_valid;
    reg held_observed = 0;
    reg [99:0] previous_payload = 0;

    ae_frame_stats_raw10_4x #(
        .IMG_WIDTH(WIDTH), .IMG_HEIGHT(HEIGHT),
        .SAMPLE_GROUP_LOG2(GROUP_LOG2), .BLACK_LEVEL(BLACK),
        .BRIGHT_LEVEL(BRIGHT), .HISTOGRAM_ENABLE(HIST_ENABLE),
        .HIST_BIN_BITS(BIN_BITS), .HOLD_OUTPUTS(1)
    ) dut (
        .I_clk(clk), .I_rst_n(rst_n), .I_tuser(tuser), .I_tlast(tlast),
        .I_tvalid(tvalid), .I_tdata(tdata), .O_stats_valid(stats_valid),
        .O_sum_y(sum_y), .O_sample_count(sample_count),
        .O_bright_count(bright_count), .O_clip_count(clip_count),
        .O_p5(p5), .O_p50(p50), .O_p95(p95), .O_p99(p99)
    );

    // The production interface omits a duplicate output register bank.
    // Compare its entire payload only on the cycle qualified by valid.
    ae_frame_stats_raw10_4x #(
        .IMG_WIDTH(WIDTH), .IMG_HEIGHT(HEIGHT),
        .SAMPLE_GROUP_LOG2(GROUP_LOG2), .BLACK_LEVEL(BLACK),
        .BRIGHT_LEVEL(BRIGHT), .HISTOGRAM_ENABLE(HIST_ENABLE),
        .HIST_BIN_BITS(BIN_BITS), .HOLD_OUTPUTS(0)
    ) direct (
        .I_clk(clk), .I_rst_n(rst_n), .I_tuser(tuser), .I_tlast(tlast),
        .I_tvalid(tvalid), .I_tdata(tdata), .O_stats_valid(direct_valid),
        .O_sum_y(direct_sum), .O_sample_count(direct_count),
        .O_bright_count(direct_bright), .O_clip_count(direct_clip),
        .O_p5(direct_p5), .O_p50(direct_p50),
        .O_p95(direct_p95), .O_p99(direct_p99)
    );

    function automatic integer percentile(input integer percent);
        integer rank, total, k, found;
        begin
            rank = (reference_count * percent + 99) / 100;
            total = 0;
            found = 0;
            percentile = -1;
            for (k = 0; k < BINS; k = k + 1) begin
                total = total + reference_bins[k];
                if (!found && total >= rank) begin
                    // The interface is a five-bit code. Coarse buckets
                    // report their inclusive upper edge in that code domain.
                    percentile = ((k + 1) * 32 / BINS) - 1;
                    found = 1;
                end
            end
        end
    endfunction

    initial begin
        exact_frame_count = 0;
        for (r = 0; r < HEIGHT; r = r + 1)
            for (g = 0; g < WIDTH / 4; g = g + 1)
                if ((r % 8) < 2 && (g % (1 << GROUP_LOG2)) == 0)
                    exact_frame_count = exact_frame_count + 4;
        reference_count = 0;
        reference_sum = 0;
        reference_bright = 0;
        reference_clip = 0;
        previous_valid = 0;
        results = 0;
        bucket_checks = 0;
        for (j = 0; j < BINS; j = j + 1) reference_bins[j] = 0;
    end

    // The driver supplies reference coordinates, independently of the DUT's
    // frame counters and queue scheduling. All arithmetic uses integer RAW10.
    always @(posedge clk) begin
        if (!rst_n || ref_first) begin
            reference_count = 0;
            reference_sum = 0;
            reference_bright = 0;
            reference_clip = 0;
            for (j = 0; j < BINS; j = j + 1) reference_bins[j] = 0;
        end
        if (rst_n && ref_sample) begin
            for (j = 0; j < 4; j = j + 1) begin
                raw_value = (tdata >> (10 * j)) & 1023;
                corrected = raw_value > BLACK ? raw_value - BLACK : 0;
                value8 = corrected / 4;
                bucket = corrected / (1024 / BINS);
                reference_bins[bucket] = reference_bins[bucket] + 1;
                reference_count = reference_count + 1;
                reference_sum = reference_sum + (value8 > 192 ? 192 : value8);
                reference_bright = reference_bright + (value8 >= BRIGHT);
                reference_clip = reference_clip + (raw_value == 1023);
            end
        end
        #1;
        if (rst_n) begin
            if (direct_valid !== stats_valid)
                $fatal(1, "HOLD_OUTPUTS valid mismatch bins=%0d black=%0d hist=%0d",
                    BINS, BLACK, HIST_ENABLE);
            if (held_observed && !stats_valid &&
                held_payload !== previous_payload)
                $fatal(1, "Held statistics changed outside valid bins=%0d black=%0d hist=%0d",
                    BINS, BLACK, HIST_ENABLE);
            if (stats_valid !== (HIST_ENABLE ? expect_hist : expect_legacy))
                $fatal(1, "Unexpected valid bins=%0d black=%0d hist=%0d valid=%b expected=%b at %0t",
                    BINS, BLACK, HIST_ENABLE, stats_valid,
                    HIST_ENABLE ? expect_hist : expect_legacy, $time);
            if (stats_valid && previous_valid)
                $fatal(1, "Statistics valid lasted more than one clock");
            if (stats_valid) begin
                if (direct_payload !== held_payload)
                    $fatal(1, "HOLD_OUTPUTS payload mismatch bins=%0d black=%0d hist=%0d direct=%h held=%h",
                        BINS, BLACK, HIST_ENABLE, direct_payload, held_payload);
                if (reference_count != exact_frame_count ||
                    sample_count !== reference_count ||
                    sum_y !== reference_sum ||
                    bright_count !== reference_bright ||
                    clip_count !== reference_clip)
                    $fatal(1,
                        "Summary mismatch bins=%0d black=%0d hist=%0d count=%0d/%0d sum=%0d/%0d bright=%0d/%0d clip=%0d/%0d",
                        BINS, BLACK, HIST_ENABLE, sample_count, reference_count,
                        sum_y, reference_sum, bright_count, reference_bright,
                        clip_count, reference_clip);
                if (HIST_ENABLE) begin
                    if (p5 !== percentile(5) || p50 !== percentile(50) ||
                        p95 !== percentile(95) || p99 !== percentile(99))
                        $fatal(1,
                            "Percentile mismatch bins=%0d black=%0d P5=%0d/%0d P50=%0d/%0d P95=%0d/%0d P99=%0d/%0d",
                            BINS, BLACK, p5, percentile(5), p50, percentile(50),
                            p95, percentile(95), p99, percentile(99));
                end else if ({p5, p50, p95, p99} !== 20'd0)
                    $fatal(1, "Disabled histogram changed percentile outputs");
                results = results + 1;
            end
            previous_payload = held_payload;
            held_observed = 1;
        end else begin
            held_observed = 0;
        end
        previous_valid = rst_n && stats_valid;
    end

    generate if (HIST_ENABLE) begin : check_bucket_contents
        integer k;
        // Compare every bucket before scanning clears the RAM. Percentiles
        // alone could miss losses or collisions elsewhere in the histogram.
        always @(posedge clk) begin
            if (rst_n && ref_check_bins &&
                dut.histogram.u_histogram.state == 2 &&
                dut.histogram.u_histogram.address == 0) begin
                bucket_sum = 0;
                for (k = 0; k < BINS; k = k + 1) begin
                    if (dut.histogram.u_histogram.bucket_ram[k] !== reference_bins[k])
                        $fatal(1,
                            "Bucket mismatch bins=%0d black=%0d index=%0d actual=%0d expected=%0d at %0t",
                            BINS, BLACK, k,
                            dut.histogram.u_histogram.bucket_ram[k], reference_bins[k], $time);
                    bucket_sum = bucket_sum + dut.histogram.u_histogram.bucket_ram[k];
                end
                if (bucket_sum != exact_frame_count)
                    $fatal(1, "Histogram total %0d differs from %0d", bucket_sum, exact_frame_count);
                bucket_checks = bucket_checks + 1;
            end
        end
    end endgenerate
endmodule

module tb_ae_histogram #(
    parameter integer WIDTH = 64,
    parameter integer HEIGHT = 16,
    parameter integer GROUP_LOG2 = 3,
    parameter integer FULL_SUITE = 1
);
    localparam integer GROUPS = WIDTH / 4;
    localparam integer FRAME_BEATS = GROUPS * HEIGHT;
    localparam integer PERIOD = 1 << GROUP_LOG2;
    localparam integer LAST_SAMPLE_ROW = ((HEIGHT - 1) / 8) * 8 +
        (((HEIGHT - 1) % 8) > 0 ? 1 : 0);
    localparam integer LAST_SAMPLE_GROUP = ((GROUPS - 1) / PERIOD) * PERIOD;
    localparam integer LAST_SAMPLE_BEAT = LAST_SAMPLE_ROW * GROUPS + LAST_SAMPLE_GROUP;
    reg clk = 0;
    always #5 clk = !clk;
    reg rst_n = 0;
    reg tuser = 0, tlast = 0, tvalid = 0;
    reg [39:0] tdata = 0;
    reg ref_first = 0, ref_sample = 0, ref_check_bins = 0;
    reg expect_hist = 0, expect_legacy = 0;
    reg [5:0] histogram_result_mask = 6'b111111;
    wire [31:0] results [0:7];
    wire [31:0] bucket_checks [0:7];
    integer frames = 0;
    integer fixture;
    integer beat;
    genvar n;
    generate for (n = 0; n < 6; n = n + 1) begin : variants
        ae_histogram_reference #(
            .WIDTH(WIDTH), .HEIGHT(HEIGHT), .GROUP_LOG2(GROUP_LOG2),
            .BIN_BITS(3 + (n % 3)), .BLACK(n >= 3 ? 64 : 0)
        ) reference (
            .clk(clk), .rst_n(rst_n), .tuser(tuser), .tlast(tlast),
            .tvalid(tvalid), .tdata(tdata),
            .ref_first(ref_first), .ref_sample(ref_sample),
            .ref_check_bins(ref_check_bins),
            .expect_hist(expect_hist && histogram_result_mask[n]),
            .expect_legacy(expect_legacy),
            .results(results[n]), .bucket_checks(bucket_checks[n])
        );
    end
    for (n = 6; n < 8; n = n + 1) begin : legacy
        ae_histogram_reference #(
            .WIDTH(WIDTH), .HEIGHT(HEIGHT), .GROUP_LOG2(GROUP_LOG2),
            .BLACK(n == 7 ? 64 : 0), .HIST_ENABLE(0)
        ) reference (
            .clk(clk), .rst_n(rst_n), .tuser(tuser), .tlast(tlast),
            .tvalid(tvalid), .tdata(tdata),
            .ref_first(ref_first), .ref_sample(ref_sample),
            .ref_check_bins(ref_check_bins),
            .expect_hist(expect_hist), .expect_legacy(expect_legacy),
            .results(results[n]), .bucket_checks(bucket_checks[n])
        );
    end endgenerate

    function automatic integer raw_pattern(input integer pattern,
                                           input integer index,
                                           input integer lane);
        reg [31:0] value;
        begin
            case (pattern)
                0: raw_pattern = 0;
                1: raw_pattern = 1023;
                2: raw_pattern = 33;
                3: raw_pattern = ((index / PERIOD + lane) & 1) ? 1023 : 0;
                4: begin
                    case (lane)
                        0: raw_pattern = 31;
                        1: raw_pattern = 32;
                        2: raw_pattern = 991;
                        default: raw_pattern = 992;
                    endcase
                end
                5: begin
                    value = 32'h6a09e667 ^ (index * 32'h9e3779b9) ^
                        (lane * 32'h85ebca6b);
                    value = value ^ (value << 13);
                    value = value ^ (value >> 17);
                    value = value ^ (value << 5);
                    raw_pattern = value & 1023;
                end
                6: raw_pattern = ((index / PERIOD + lane) & 1) ? 512 : 511;
                7: begin
                    case (lane)
                        0: raw_pattern = 0;
                        1: raw_pattern = 63;
                        2: raw_pattern = 64;
                        default: raw_pattern = 65;
                    endcase
                end
                8: begin
                    case (lane)
                        0: raw_pattern = 991;
                        1: raw_pattern = 992;
                        2: raw_pattern = 1022;
                        default: raw_pattern = 1023;
                    endcase
                end
                // A narrow non-edge bucket catches stale bucket RAM while
                // sharply different distributions follow without blanking.
                9: raw_pattern = 385;
                default: raw_pattern = (index + lane) & 1023;
            endcase
        end
    endfunction

    task automatic tick;
        begin @(posedge clk); #2; end
    endtask

    task automatic idle(input integer clocks);
        integer k;
        begin
            for (k = 0; k < clocks; k = k + 1) begin
                @(negedge clk);
                tuser = 0; tvalid = 0; tlast = 0;
                ref_first = 0; ref_sample = 0;
                expect_hist = 0; expect_legacy = 0;
                tick();
            end
        end
    endtask

    task automatic marker;
        begin
            @(negedge clk);
            tuser = 1; tvalid = 0; tlast = 0;
            ref_first = 0; ref_sample = 0;
            expect_hist = 0; expect_legacy = 0;
            tick();
            idle(1);
        end
    endtask

    task automatic drive_beat(input integer index, input integer pattern,
                              input integer marker_mode, input integer bad_beat,
                              input integer hist_result, input integer legacy_result,
                              input integer check_bins);
        integer lane, row, group_index;
        reg [39:0] packed_data;
        begin
            row = index / GROUPS;
            group_index = index % GROUPS;
            packed_data = 0;
            for (lane = 0; lane < 4; lane = lane + 1)
                packed_data[lane * 10 +: 10] = raw_pattern(pattern, index, lane);
            @(negedge clk);
            tuser = (marker_mode == 1 && index == 0) ||
                    (marker_mode == 2 && index < 5);
            tvalid = 1;
            tlast = (group_index == GROUPS - 1) ^ (index == bad_beat);
            tdata = packed_data;
            ref_first = index == 0;
            ref_sample = ((row % 8) < 2) && ((group_index % PERIOD) == 0);
            ref_check_bins = check_bins;
            expect_hist = index == FRAME_BEATS - 1 && hist_result;
            expect_legacy = index == FRAME_BEATS - 1 && legacy_result;
            tick();
        end
    endtask

    // marker_mode: 0=separate early marker, 1=first beat, 2=held,
    // 3=no marker. Back-to-back calls with mode 1 have no frame blanking.
    task automatic send_frame(input integer pattern, input integer marker_mode,
                              input integer bad_beat, input integer hist_result,
                              input integer legacy_result, input integer holes);
        integer k;
        begin
            if (marker_mode == 0) marker();
            for (k = 0; k < FRAME_BEATS; k = k + 1) begin
                drive_beat(k, pattern, marker_mode, bad_beat,
                    hist_result, legacy_result, hist_result);
                if (holes && (k % 23) == 7 && k < FRAME_BEATS - 1) idle(2);
            end
            frames = frames + 1;
        end
    endtask

    initial begin
        repeat (3) tick();
        @(negedge clk); rst_n = 1;

        // An immediate first SOF reaches the RAM before initialization has
        // completed. Only the histogram version must drop that first frame.
        send_frame(1, 1, -1, 0, 1, 0);
        send_frame(0, 1, -1, 1, 1, 0);
        send_frame(5, 1, -1, 1, 1, 0);
        send_frame(8, 1, -1, 1, 1, 0);

        if (FULL_SUITE) begin
            for (fixture = 0; fixture < 10; fixture = fixture + 1)
                send_frame(fixture, fixture % 3, -1, 1, 1, fixture & 1);
            send_frame(5, 1, 17, 0, 0, 0);
            send_frame(5, 1, FRAME_BEATS - 1, 0, 0, 0);
            send_frame(2, 1, -1, 1, 1, 0);

            // Drop both an unfinished collection and the replacement frame
            // that arrives while its dirty single bank is being cleared.
            for (beat = 0; beat < 13; beat = beat + 1)
                drive_beat(beat, 5, 1, -1, 0, 0, 0);
            idle(20);
            send_frame(3, 1, -1, 0, 1, 0);
            send_frame(9, 1, -1, 1, 1, 0);

            // SOF colliding with queued writes, then with the first scan.
            drive_beat(0, 1, 1, -1, 0, 0, 0);
            // Make SOF edge-sensitive even though the abandoned frame's
            // first beat had tuser high.
            idle(1);
            send_frame(6, 1, -1, 0, 1, 0);
            send_frame(7, 1, -1, 1, 1, 0);
            for (beat = 0; beat <= LAST_SAMPLE_BEAT; beat = beat + 1)
                drive_beat(beat, 5, 1, -1, 0, 0, 0);
            idle(4);
            send_frame(4, 1, -1, 0, 1, 0);
            send_frame(1, 1, -1, 1, 1, 0);

            // The same edge scans the final 32-bucket address and starts a
            // new frame. That bank is still busy on that edge and must drop
            // the new frame; the already cleared 8/16-bucket banks may use it.
            for (beat = 0; beat <= LAST_SAMPLE_BEAT; beat = beat + 1)
                drive_beat(beat, 5, 1, -1, 0, 0, 0);
            idle(35);
            histogram_result_mask = 6'b011011;
            send_frame(6, 1, -1, 1, 1, 0);
            histogram_result_mask = 6'b111111;
            send_frame(3, 1, -1, 1, 1, 0);

            // Reset while scanning must not leave partial CDF values or
            // uncleared buckets available to a following immediate SOF.
            for (beat = 0; beat <= LAST_SAMPLE_BEAT; beat = beat + 1)
                drive_beat(beat, 5, 1, -1, 0, 0, 0);
            idle(4);
            @(negedge clk); rst_n = 0; tvalid = 0; tuser = 0;
            ref_sample = 0; ref_first = 0; expect_hist = 0; expect_legacy = 0;
            tick();
            @(negedge clk); rst_n = 1;
            send_frame(1, 1, -1, 0, 1, 0);
            send_frame(0, 1, -1, 1, 1, 0);

            // Reset during partial capture, then unmarked continuation.
            for (beat = 0; beat < 13; beat = beat + 1)
                drive_beat(beat, 5, 1, -1, 0, 0, 0);
            @(negedge clk); rst_n = 0; tvalid = 0; tuser = 0;
            ref_sample = 0; ref_first = 0; expect_hist = 0; expect_legacy = 0;
            tick(); tick();
            @(negedge clk); rst_n = 1;
            for (beat = 13; beat < FRAME_BEATS; beat = beat + 1)
                drive_beat(beat, 5, 3, -1, 0, 0, 0);
            idle(40);
            send_frame(5, 3, -1, 0, 0, 1);
            send_frame(5, 0, -1, 1, 1, 0);
        end
        idle(4);
        for (fixture = 0; fixture < 8; fixture = fixture + 1) begin
            if (results[fixture] < 3)
                $fatal(1, "Expected multiple complete-frame checks on variant %0d", fixture);
            if (fixture < 6 && bucket_checks[fixture] < 3)
                $fatal(1, "No full histogram checks on variant %0d", fixture);
        end
        $display("AE_HISTOGRAM_PASS width=%0d height=%0d group_log2=%0d frames=%0d hist_results=%0d legacy_results=%0d bucket_scans=%0d bins=8,16,32 black=0,64 hold_outputs=0,1",
            WIDTH, HEIGHT, GROUP_LOG2, frames, results[0], results[6], bucket_checks[0]);
        $finish;
    end

    initial begin
        #200000000;
        $fatal(1, "Histogram verification timed out");
    end
endmodule

module tb_ae_histogram_unsupported #(
    parameter integer KIND = 0
);
    reg clk = 0;
    always #5 clk = !clk;
    ae_frame_stats_raw10_4x #(
        .IMG_WIDTH(KIND == 4 ? 65536 : 128),
        .IMG_HEIGHT(KIND == 0 ? 3 : 16),
        .SAMPLE_GROUP_LOG2(KIND == 1 ? 1 : 2),
        .HISTOGRAM_ENABLE(1),
        .HIST_BIN_BITS(KIND == 2 ? 2 : KIND == 3 ? 6 : 5)
    ) dut (
        .I_clk(clk), .I_rst_n(1'b0), .I_tuser(1'b0),
        .I_tlast(1'b0), .I_tvalid(1'b0), .I_tdata(40'd0)
    );
    initial begin
        #1000;
        $fatal(1, "Unsupported histogram configuration was not rejected");
    end
endmodule
