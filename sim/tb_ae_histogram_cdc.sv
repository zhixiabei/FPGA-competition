`timescale 1ns/1ps

module tb_ae_histogram_cdc;
    localparam integer WIDTH = 144, HEIGHT = 3;
    localparam integer GROUPS = WIDTH / 4;
    localparam integer PERIOD = 4, BLACK = 64, FRAMES = 12;
    localparam integer SAMPLES = 2 * (GROUPS / PERIOD) * 4;
    reg src_clk = 0, dst_clk = 0;
    always #5 src_clk = !src_clk;
    initial begin
        #3.7;
        forever #7 dst_clk = !dst_clk;
    end
    reg rst_n = 0, tuser = 0, tlast = 0, tvalid = 0;
    reg [39:0] tdata = 0;
    wire [1:0] stats_valid, dst_valid;
    wire [99:0] payload [0:1];
    wire [99:0] dst_payload [0:1];
    reg [99:0] expected [0:FRAMES-1];
    integer source_captures = 0, sof_collisions = 0;
    integer completed [0:1];
    reg [1:0] previous_dst_valid = 0;
    integer frame_number, beat, lane, row, group_number;
    integer raw_value, corrected, value8, bucket, k, total;
    integer reference_sum, reference_bright, reference_clip;
    integer reference_bins [0:31];
    reg [4:0] p5, p50, p95, p99;
    reg [39:0] packed_data;
    reg [99:0] capture_expected;
    integer direct_changed = 0;
    genvar h;
    generate for (h = 0; h < 2; h = h + 1) begin : variants
        wire [31:0] sum_y;
        wire [15:0] count, bright, clip;
        wire [4:0] result_p5, result_p50, result_p95, result_p99;
        assign payload[h] = {sum_y, count, bright, clip,
                             result_p5, result_p50, result_p95, result_p99};
        ae_frame_stats_raw10_4x #(
            .IMG_WIDTH(WIDTH), .IMG_HEIGHT(HEIGHT),
            .SAMPLE_GROUP_LOG2(2), .BLACK_LEVEL(BLACK),
            .BRIGHT_LEVEL(248), .HISTOGRAM_ENABLE(1),
            .HIST_BIN_BITS(5), .HOLD_OUTPUTS(h)
        ) stats (
            .I_clk(src_clk), .I_rst_n(rst_n),
            .I_tuser(tuser), .I_tlast(tlast), .I_tvalid(tvalid),
            .I_tdata(tdata), .O_stats_valid(stats_valid[h]),
            .O_sum_y(sum_y), .O_sample_count(count),
            .O_bright_count(bright), .O_clip_count(clip),
            .O_p5(result_p5), .O_p50(result_p50),
            .O_p95(result_p95), .O_p99(result_p99)
        );
        // All one hundred summary bits are transported together, including
        // the production AE sum/count/P95/near-top fields.
        ae_stats_cdc #(.WIDTH(100)) cdc (
            .I_src_clk(src_clk), .I_dst_clk(dst_clk), .I_rst_n(rst_n),
            .I_src_valid(stats_valid[h]), .I_src_data(payload[h]),
            .O_dst_valid(dst_valid[h]), .O_dst_data(dst_payload[h])
        );
    end endgenerate

    function automatic integer raw_pattern(input integer f,
                                           input integer index,
                                           input integer component);
        reg [31:0] x;
        begin
            case (f % 6)
                0: raw_pattern = 0;
                1: raw_pattern = 1023;
                2: raw_pattern = 65 + component;
                3: raw_pattern = (component & 1) ? 1023 : 512;
                4: raw_pattern = 991 + component;
                default: begin
                    x = 32'h243f6a88 ^ (f * 32'h9e3779b9) ^
                        (index * 32'h85ebca6b) ^ (component * 32'hc2b2ae35);
                    x = x ^ (x << 13);
                    x = x ^ (x >> 17);
                    x = x ^ (x << 5);
                    raw_pattern = x & 1023;
                end
            endcase
        end
    endfunction

    function automatic integer reference_percentile(input integer percent);
        integer rank, cumulative, b, found;
        begin
            rank = (SAMPLES * percent + 99) / 100;
            cumulative = 0;
            found = 0;
            reference_percentile = -1;
            for (b = 0; b < 32; b = b + 1) begin
                cumulative = cumulative + reference_bins[b];
                if (!found && cumulative >= rank) begin
                    reference_percentile = b;
                    found = 1;
                end
            end
        end
    endfunction

    // This checks the consumer's sampling edge, before nonblocking updates.
    // A new SOF is deliberately accepted on the edge after publication.
    always @(posedge src_clk) begin
        if (rst_n) begin
            if (stats_valid[0] !== stats_valid[1])
                $fatal(1, "Held/direct publication cycles differ");
            if (stats_valid[0]) begin
                if (source_captures >= FRAMES)
                    $fatal(1, "Extra source publication");
                capture_expected = expected[source_captures];
                if (payload[0] !== capture_expected ||
                    payload[1] !== capture_expected)
                    $fatal(1, "Completed source payload wrong on capture edge frame=%0d direct=%h held=%h expected=%h",
                        source_captures, payload[0], payload[1], capture_expected);
                source_captures = source_captures + 1;
                if (tuser && tvalid) begin
                    sof_collisions = sof_collisions + 1;
                    #1;
                    // Observe a real overlap: accumulators may already
                    // represent the next frame, while CDC owns the old one.
                    if (payload[0] !== capture_expected)
                        direct_changed = direct_changed + 1;
                    if (variants[0].cdc.payload_hold !== capture_expected ||
                        variants[1].cdc.payload_hold !== capture_expected)
                        $fatal(1, "CDC captured next-frame/reset data at immediate SOF");
                end
            end
        end
    end

    integer monitor_index;
    always @(posedge dst_clk) begin
        #1;
        if (rst_n) begin
            if (dst_valid[0] !== dst_valid[1])
                $fatal(1, "Held/direct CDC destination timing differs");
            for (monitor_index = 0; monitor_index < 2; monitor_index = monitor_index + 1) begin
                if (dst_valid[monitor_index] && previous_dst_valid[monitor_index])
                    $fatal(1, "Destination valid is longer than one clock");
                if (dst_valid[monitor_index]) begin
                    if (completed[monitor_index] >= FRAMES ||
                        dst_payload[monitor_index] !== expected[completed[monitor_index]])
                        $fatal(1, "Destination payload torn or reordered hold=%0d frame=%0d actual=%h expected=%h",
                            monitor_index, completed[monitor_index],
                            dst_payload[monitor_index], expected[completed[monitor_index]]);
                    completed[monitor_index] = completed[monitor_index] + 1;
                end
            end
        end
        previous_dst_valid = dst_valid;
    end

    initial begin
        completed[0] = 0; completed[1] = 0;
        // Build an independent whole-frame model before streaming. Reference
        // positions come from driver loop coordinates, never RTL counters.
        for (frame_number = 0; frame_number < FRAMES; frame_number = frame_number + 1) begin
            for (k = 0; k < 32; k = k + 1) reference_bins[k] = 0;
            reference_sum = 0; reference_bright = 0; reference_clip = 0;
            total = 0;
            for (row = 0; row < 2; row = row + 1)
                for (group_number = 0; group_number < GROUPS; group_number = group_number + PERIOD)
                    for (lane = 0; lane < 4; lane = lane + 1) begin
                        raw_value = raw_pattern(frame_number, row * GROUPS + group_number, lane);
                        corrected = raw_value > BLACK ? raw_value - BLACK : 0;
                        value8 = corrected / 4;
                        bucket = corrected / 32;
                        reference_bins[bucket] = reference_bins[bucket] + 1;
                        reference_sum = reference_sum + (value8 > 192 ? 192 : value8);
                        reference_bright = reference_bright + (value8 >= 248);
                        reference_clip = reference_clip + (raw_value == 1023);
                        total = total + 1;
                    end
            if (total != SAMPLES) $fatal(1, "Invalid reference geometry");
            p5 = reference_percentile(5); p50 = reference_percentile(50);
            p95 = reference_percentile(95); p99 = reference_percentile(99);
            expected[frame_number] =
                {reference_sum[31:0], 16'(SAMPLES),
                 reference_bright[15:0], reference_clip[15:0],
                 p5, p50, p95, p99};
        end
        repeat (4) @(posedge src_clk);
        @(negedge src_clk); rst_n = 1;
        // Clear the one-bank histogram before the first complete frame.
        repeat (40) @(posedge src_clk);
        for (frame_number = 0; frame_number < FRAMES; frame_number = frame_number + 1)
            for (beat = 0; beat < GROUPS * HEIGHT; beat = beat + 1) begin
                packed_data = 0;
                for (lane = 0; lane < 4; lane = lane + 1)
                    packed_data[lane * 10 +: 10] = raw_pattern(frame_number, beat, lane);
                @(negedge src_clk);
                tdata = packed_data;
                tuser = beat == 0;
                tvalid = 1;
                tlast = (beat % GROUPS) == GROUPS - 1;
                @(posedge src_clk); #2;
            end
        @(negedge src_clk);
        tuser = 0; tvalid = 0; tlast = 0;
        repeat (40) @(posedge dst_clk);
        #2;
        if (source_captures != FRAMES ||
            completed[0] != FRAMES || completed[1] != FRAMES ||
            sof_collisions != FRAMES - 1 || direct_changed < FRAMES / 2)
            $fatal(1, "Incomplete CDC coverage src=%0d direct=%0d held=%0d collisions=%0d changed=%0d",
                source_captures, completed[0], completed[1],
                sof_collisions, direct_changed);
        $display("AE_HISTOGRAM_CDC_PASS frames=%0d holds=0,1 payload_bits=100 immediate_sof_collisions=%0d direct_changed_after_capture=%0d min_tail=39",
            source_captures, sof_collisions, direct_changed);
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "Integrated histogram/CDC verification timed out");
    end
endmodule
