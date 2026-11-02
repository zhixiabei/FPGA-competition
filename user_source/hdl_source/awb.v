// Four RGB888 pixels per clock, with frame-stable automatic white balance.
// Only complete frames with enough unsaturated, approximately neutral samples
// update the gains. A single sequential divider computes G/R then G/B during
// subsequent clocks; a pending result is committed only at the next input SOF.
//
// This camera pipeline uses an EARLY frame marker: retain O_tuser=I_tuser.
// Pixel data/valid retain the original 54-clock delay: two correction stages
// plus a 52-clock distributed-RAM delay. video_in needs this lead time to
// finish its frame FIFO reset before the first pixel arrives. Vertical
// blanking must let the preceding frame's delayed pixels drain before SOF.
// O_tlast follows the input line marker through the same 54-clock pixel delay.
module awb #(
    parameter integer IMG_HEIGHT = 1080,
    parameter integer IMG_WIDTH = 1920,
    parameter integer SAMPLE_LOG2 = 4,
    parameter integer MIN_GAIN_Q8 = 128,
    parameter integer MAX_GAIN_Q8 = 1024,
    parameter integer CONFIDENCE_ENABLE = 0,
    parameter integer RED_RECOVERY_ENABLE = 0,
    parameter integer GAIN_DEADBAND_Q8 = 2,
    parameter integer CANDIDATE_TOLERANCE_Q8 = 24,
    parameter integer CAPTURE_RED_MIN_Q8 = 170,
    parameter integer CAPTURE_RED_MAX_Q8 = 512,
    parameter integer CAPTURE_BLUE_MIN_Q8 = 170,
    parameter integer CAPTURE_BLUE_MAX_Q8 = 512,
    parameter integer TRACK_TOLERANCE_Q8 = 64,
    parameter integer COMMON_CAST_TOLERANCE_Q8 = 48,
    parameter integer REACQUIRE_FRAMES = 4,
    parameter integer DIAGNOSTIC_ENABLE = 0
) (
    input wire I_clk,
    input wire I_rst_n,
    input wire I_tlast,
    input wire I_tuser,
    input wire [95:0] I_tdata,
    input wire I_tvalid,
    output wire I_tready,
    output wire O_tlast,
    output wire O_tuser,
    output wire [95:0] O_tdata,
    output wire O_tvalid,
    input wire O_tready,
    input wire I_hold,
    output wire O_diag_valid,
    output wire O_diag_user,
    output wire O_diag_last,
    output wire [95:0] O_diag_data,
    output wire [7:0] O_diag_clip_new,
    output wire [10:0] O_diag_gain_r_q8,
    output wire [10:0] O_diag_gain_b_q8,
    output wire O_diag_candidate_valid,
    output wire O_diag_stats_valid,
    output wire [15:0] O_diag_sample_count
);
    localparam integer FRAME_BEATS = (IMG_HEIGHT * IMG_WIDTH + 3) / 4;
    localparam integer COUNT_BITS = $clog2(FRAME_BEATS + 1);
    localparam integer MAX_SAMPLES =
        (FRAME_BEATS + (1 << SAMPLE_LOG2) - 1) >> SAMPLE_LOG2;
    localparam integer MIN_SAMPLES =
        MAX_SAMPLES >= 128 ? MAX_SAMPLES / 32 :
        MAX_SAMPLES >= 4 ? 4 : MAX_SAMPLES;
    // Accepted samples have every channel <= 220. Size the statistics from
    // that bound; retain the original 32-bit modulo arithmetic if a larger
    // legal image would exceed it. Use a wide constant for the bound itself.
    localparam [63:0] MAX_CHANNEL_SUM = 64'd220 * MAX_SAMPLES;
    localparam integer SUM_BITS = MAX_CHANNEL_SUM >= 64'h00000000ffffffff ?
        32 : (MAX_CHANNEL_SUM == 0 ? 1 : $clog2(MAX_CHANNEL_SUM + 64'd1));
    localparam integer SAMPLE_COUNT_BITS =
        MAX_SAMPLES == 0 ? 1 : $clog2(MAX_SAMPLES + 64'd1);
    localparam integer DIV_BITS = SUM_BITS + 8;
    localparam integer LINE_BEATS = (IMG_WIDTH + 3) / 4;
    localparam integer COLUMN_BITS = LINE_BEATS <= 1 ? 1 : $clog2(LINE_BEATS);
    localparam integer REGION_MIN = MIN_SAMPLES >= 16 ? MIN_SAMPLES / 8 : 1;
    localparam integer REGION_BITS = $clog2(REGION_MIN + 1);
    localparam integer REACQUIRE_BITS =
        REACQUIRE_FRAMES <= 1 ? 1 : $clog2(REACQUIRE_FRAMES);
    localparam [1:0] DIV_IDLE = 2'd0, DIV_RED = 2'd1, DIV_BLUE = 2'd2;

    reg frame_active;
    reg [COUNT_BITS-1:0] beat_count;
    reg [SAMPLE_LOG2-1:0] sample_phase;
    reg [1:0] sample_lane;
    reg [SUM_BITS-1:0] sum_r, sum_g, sum_b;
    reg [SAMPLE_COUNT_BITS-1:0] sample_count;

    reg [10:0] gain_r_q8, gain_b_q8;
    reg [10:0] pending_r_q8, pending_b_q8;
    reg pending_ready;

    reg [1:0] div_state;
    reg [5:0] div_bit_count;
    reg [DIV_BITS-1:0] div_quotient;
    reg [SUM_BITS:0] div_remainder;
    reg [SUM_BITS-1:0] div_denominator;
    reg [SUM_BITS-1:0] div_green_sum, div_blue_denominator;
    reg [10:0] div_red_result;
    reg [10:0] candidate_r, candidate_b;
    reg candidate_valid;
    reg tracking_valid;
    reg [REACQUIRE_BITS-1:0] reacquire_count;
    reg frame_bad, completed_frame_bad, overrun_block;
    reg [COLUMN_BITS-1:0] column_count;
    // I_hold is a synchronous enable in I_clk. The AE clock crossing is at
    // the ISP boundary, before this module; do not sample it as an async bus.
    wire hold_updates = I_hold;
    reg half_d0, half_d1, half_d2;
    reg bad_d0, bad_d1, bad_d2;
    reg [REGION_BITS-1:0] upper_samples, lower_samples;
    // Hold invalidation is mandatory even with optional colour-confidence
    // checks disabled. A partial frame after release cannot update WB.
    wire coverage_ok = !completed_frame_bad && (CONFIDENCE_ENABLE == 0 ||
        (upper_samples == REGION_MIN && lower_samples == REGION_MIN));

    // Selecting a different lane at successive sample points avoids sampling
    // only one of the four Bayer reconstruction positions.
    wire [1:0] selected_lane = I_tuser ? 2'd0 : sample_lane;
    wire [23:0] sample_rgb = I_tdata >> (selected_lane * 24);
    wire stats_valid = I_tvalid && (frame_active || I_tuser);
    wire take_sample = stats_valid &&
        (I_tuser || sample_phase == {SAMPLE_LOG2{1'b0}});
    wire frame_complete = stats_valid &&
        (I_tuser ? FRAME_BEATS == 1 : beat_count == FRAME_BEATS-1);
    wire expected_last = (I_tuser ? 0 : column_count) == LINE_BEATS-1;
    wire line_bad = stats_valid && (I_tlast != expected_last);
    wire abandoned_frame = I_tuser && frame_active;
    wire extra_pixels = I_tvalid && !frame_active && !I_tuser;

    // Statistics are pipelined independently of the delayed video path.
    // Never combine lane selection, neutral filtering, accumulation, zero
    // detection and divider launch into one MIPI-clock combinational path.
    reg [23:0] sample_rgb_d0, sample_rgb_d1, sample_rgb_d2;
    reg sample_take_d0, sample_take_d1, sample_accept_d2;
    reg stats_start_d0, stats_start_d1, stats_start_d2;
    reg stats_end_d0, stats_end_d1, stats_end_d2;
    reg [7:0] sample_max_d1, sample_min_d1;
    reg stats_ready;
    wire [7:0] red_d0 = sample_rgb_d0[23:16];
    wire [7:0] green_d0 = sample_rgb_d0[15:8];
    wire [7:0] blue_d0 = sample_rgb_d0[7:0];
    wire [7:0] max_rg_d0 = red_d0 > green_d0 ? red_d0 : green_d0;
    wire [7:0] min_rg_d0 = red_d0 < green_d0 ? red_d0 : green_d0;
    wire [7:0] red_d1 = sample_rgb_d1[23:16];
    wire [7:0] green_d1_stats = sample_rgb_d1[15:8];
    wire [7:0] blue_d1 = sample_rgb_d1[7:0];
    wire [7:0] sample_spread_d1 = sample_max_d1 - sample_min_d1;
    wire [8:0] neutral_upper_d1 =
        {1'b0, green_d1_stats} + (green_d1_stats >> 1);
    wire [7:0] neutral_lower_d1 = green_d1_stats >> 1;
    // A cyan-cast neutral can have R below the normal half-G gate. Require
    // G/B agreement and usable R signal before extending capture to 4x.
    wire [7:0] gb_difference_d1 = green_d1_stats >= blue_d1 ?
        green_d1_stats-blue_d1 : blue_d1-green_d1_stats;
    wire red_recovery_d1 = RED_RECOVERY_ENABLE != 0 &&
        sample_max_d1 >= 8'd40 && sample_max_d1 <= 8'd220 &&
        red_d1 >= 8'd20 && red_d1 >= (green_d1_stats >> 2) &&
        red_d1 < neutral_lower_d1 &&
        gb_difference_d1 <= (green_d1_stats >> 3);
    wire sample_neutral_d1 =
        red_recovery_d1 || (sample_max_d1 >= 8'd40 && sample_max_d1 <= 8'd220 &&
        sample_spread_d1 <= (sample_max_d1 >> 1) &&
        {1'b0, red_d1} <= neutral_upper_d1 && red_d1 >= neutral_lower_d1 &&
        {1'b0, blue_d1} <= neutral_upper_d1 && blue_d1 >= neutral_lower_d1);

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            sample_rgb_d0 <= 0;
            sample_rgb_d1 <= 0;
            sample_rgb_d2 <= 0;
            sample_max_d1 <= 0;
            sample_min_d1 <= 0;
            sample_take_d0 <= 1'b0;
            sample_take_d1 <= 1'b0;
            sample_accept_d2 <= 1'b0;
            stats_start_d0 <= 1'b0;
            stats_start_d1 <= 1'b0;
            stats_start_d2 <= 1'b0;
            stats_end_d0 <= 1'b0;
            stats_end_d1 <= 1'b0;
            stats_end_d2 <= 1'b0;
            half_d0 <= 1'b0;
            half_d1 <= 1'b0;
            half_d2 <= 1'b0;
            bad_d0 <= 1'b0;
            bad_d1 <= 1'b0;
            bad_d2 <= 1'b0;
        end else begin
            // Stage 0: select and capture one of the four input pixels.
            sample_rgb_d0 <= sample_rgb;
            sample_take_d0 <= take_sample;
            stats_start_d0 <= I_tuser;
            stats_end_d0 <= frame_complete;
            half_d0 <= !I_tuser && beat_count >= FRAME_BEATS/2;
            bad_d0 <= hold_updates || (CONFIDENCE_ENABLE != 0 && line_bad) ||
                      (!I_tuser && frame_bad);
            // Stage 1: channel extrema, aligned with the sample and tokens.
            sample_rgb_d1 <= sample_rgb_d0;
            sample_max_d1 <= max_rg_d0 > blue_d0 ? max_rg_d0 : blue_d0;
            sample_min_d1 <= min_rg_d0 < blue_d0 ? min_rg_d0 : blue_d0;
            sample_take_d1 <= sample_take_d0;
            stats_start_d1 <= stats_start_d0;
            stats_end_d1 <= stats_end_d0;
            half_d1 <= half_d0;
            bad_d1 <= bad_d0;
            // Stage 2: qualify a non-clipped, approximately neutral sample.
            sample_rgb_d2 <= sample_rgb_d1;
            sample_accept_d2 <= sample_take_d1 && sample_neutral_d1;
            stats_start_d2 <= stats_start_d1;
            stats_end_d2 <= stats_end_d1;
            half_d2 <= half_d1;
            bad_d2 <= bad_d1;
        end
    end

    // Stage 3: sum accepted samples. The last sample is accumulated before
    // stats_ready can launch division at stage 4. A following frame's SOF
    // may reset these sums at stage 3 while stage 4 reads the completed OLD
    // registered sums; this remains correct for back-to-back valid frames.
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            sum_r <= 0;
            sum_g <= 0;
            sum_b <= 0;
            sample_count <= 0;
            stats_ready <= 1'b0;
            upper_samples <= 0;
            lower_samples <= 0;
            completed_frame_bad <= 1'b1;
        end else begin
            stats_ready <= stats_end_d2;
            if (stats_end_d2) completed_frame_bad <= bad_d2;
            if (stats_start_d2) begin
                sum_r <= 0;
                sum_g <= 0;
                sum_b <= 0;
                sample_count <= 0;
                upper_samples <= 0;
                lower_samples <= 0;
            end
            if (sample_accept_d2) begin
                sum_r <= (stats_start_d2 ? {SUM_BITS{1'b0}} : sum_r) +
                    sample_rgb_d2[23:16];
                sum_g <= (stats_start_d2 ? {SUM_BITS{1'b0}} : sum_g) +
                    sample_rgb_d2[15:8];
                sum_b <= (stats_start_d2 ? {SUM_BITS{1'b0}} : sum_b) +
                    sample_rgb_d2[7:0];
                sample_count <=
                    (stats_start_d2 ? {SAMPLE_COUNT_BITS{1'b0}} : sample_count) + 1'b1;
                if (!half_d2) begin
                    if (stats_start_d2 || upper_samples < REGION_MIN)
                        upper_samples <= (stats_start_d2 ? 0 : upper_samples) + 1'b1;
                end else if (stats_start_d2 || lower_samples < REGION_MIN)
                    lower_samples <= (stats_start_d2 ? 0 : lower_samples) + 1'b1;
            end
        end
    end

    // Restoring division: one quotient bit each clock, using one subtractor.
    // Retain every G<<8 bit. Keep 40 division clocks for frame-commit
    // equivalence: the leading 40-DIV_BITS clocks are zero-bit padding.
    wire [SUM_BITS:0] div_trial =
        {div_remainder[SUM_BITS-1:0], div_quotient[DIV_BITS-1]};
    wire [SUM_BITS+1:0] div_difference =
        {1'b0, div_trial} - {2'b00, div_denominator};
    wire div_subtract = !div_difference[SUM_BITS+1];
    wire [SUM_BITS:0] div_next_remainder = div_subtract ?
        div_difference[SUM_BITS:0] : div_trial;
    wire [DIV_BITS-1:0] div_next_quotient =
        {div_quotient[DIV_BITS-2:0], div_subtract};

    function [10:0] F_limit_gain;
        input [DIV_BITS-1:0] quotient;
        begin
            if (quotient < MIN_GAIN_Q8)
                F_limit_gain = MIN_GAIN_Q8;
            else if (quotient > MAX_GAIN_Q8)
                F_limit_gain = MAX_GAIN_Q8;
            else
                F_limit_gain = quotient[10:0];
        end
    endfunction

    // One eighth of the difference, rounded towards the target; optional
    // confidence-mode deadband suppresses one- and two-LSB colour hunting.
    function [10:0] F_smooth_gain;
        input [10:0] current_gain;
        input [10:0] target_gain;
        reg signed [11:0] difference;
        reg signed [12:0] rounded;
        reg signed [12:0] step;
        begin
            difference = $signed({1'b0,target_gain}) -
                $signed({1'b0,current_gain});
            rounded = $signed({difference[11],difference}) +
                (difference[11] ? 13'sd0 : 13'sd7);
            step = rounded >>> 3;
            F_smooth_gain = CONFIDENCE_ENABLE &&
                difference >= -GAIN_DEADBAND_Q8 &&
                difference <= GAIN_DEADBAND_Q8 ? current_gain :
                $signed({2'b00,current_gain}) + step;
        end
    endfunction

    // Calculate once when the ratio is accepted, before SOF selects the gain.
    reg [10:0] committed_gain_r, committed_gain_b;
    // When SOF and the first valid pixel coincide, that pixel already belongs
    // to the new frame and must use the same gain as the rest of that frame.
    wire [10:0] pixel_gain_r = I_tuser && pending_ready && !hold_updates ?
        committed_gain_r : gain_r_q8;
    wire [10:0] pixel_gain_b = I_tuser && pending_ready && !hold_updates ?
        committed_gain_b : gain_b_q8;
    wire [10:0] blue_result = F_limit_gain(div_next_quotient);
    wire signed [11:0] red_delta =
        $signed({1'b0,div_red_result}) - $signed({1'b0,candidate_r});
    wire signed [11:0] blue_delta =
        $signed({1'b0,blue_result}) - $signed({1'b0,candidate_b});
    wire consistent_candidate = candidate_valid &&
        red_delta >= -CANDIDATE_TOLERANCE_Q8 &&
        red_delta <= CANDIDATE_TOLERANCE_Q8 &&
        blue_delta >= -CANDIDATE_TOLERANCE_Q8 &&
        blue_delta <= CANDIDATE_TOLERANCE_Q8;
    // Bounds are provisional configuration, not a measured camera profile.
    // Ratios are evaluated once per frame as G/R and G/B, using the existing
    // divider. A conservative same-direction guard rejects dominant
    // green/magenta candidates; a measured illuminant profile can retune it.
    wire capture_range_ok =
        div_red_result >= CAPTURE_RED_MIN_Q8 &&
        div_red_result <= CAPTURE_RED_MAX_Q8 &&
        blue_result >= CAPTURE_BLUE_MIN_Q8 &&
        blue_result <= CAPTURE_BLUE_MAX_Q8 &&
        !((div_red_result > 256 + COMMON_CAST_TOLERANCE_Q8 &&
           blue_result > 256 + COMMON_CAST_TOLERANCE_Q8) ||
          (div_red_result < 256 - COMMON_CAST_TOLERANCE_Q8 &&
           blue_result < 256 - COMMON_CAST_TOLERANCE_Q8));
    wire signed [11:0] tracked_red_delta =
        $signed({1'b0,div_red_result}) - $signed({1'b0,pending_r_q8});
    wire signed [11:0] tracked_blue_delta =
        $signed({1'b0,blue_result}) - $signed({1'b0,pending_b_q8});
    wire tracking_range_ok = !tracking_valid ||
        (tracked_red_delta >= -TRACK_TOLERANCE_Q8 &&
         tracked_red_delta <= TRACK_TOLERANCE_Q8 &&
         tracked_blue_delta >= -TRACK_TOLERANCE_Q8 &&
         tracked_blue_delta <= TRACK_TOLERANCE_Q8);
    wire frame_stats_ok = sample_count >= MIN_SAMPLES &&
        sum_r != 0 && sum_b != 0 && coverage_ok &&
        !overrun_block;
    wire ratio_finished = div_state == DIV_BLUE && div_bit_count == 0;
    wire candidate_approved =
        capture_range_ok && tracking_range_ok && consistent_candidate;
    wire confidence_failure =
        (stats_ready && (!frame_stats_ok || div_state != DIV_IDLE)) ||
        (ratio_finished && !(capture_range_ok && tracking_range_ok)) ||
        abandoned_frame;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            frame_active <= 1'b0;
            beat_count <= 0;
            sample_phase <= 0;
            sample_lane <= 0;
            gain_r_q8 <= 11'd256;
            gain_b_q8 <= 11'd256;
            pending_r_q8 <= 11'd256;
            pending_b_q8 <= 11'd256;
            committed_gain_r <= 11'd256;
            committed_gain_b <= 11'd256;
            pending_ready <= 1'b0;
            div_state <= DIV_IDLE;
            div_bit_count <= 0;
            div_quotient <= 0;
            div_remainder <= 0;
            div_denominator <= 0;
            div_green_sum <= 0;
            div_blue_denominator <= 0;
            div_red_result <= 11'd256;
            candidate_r <= 256;
            candidate_b <= 256;
            candidate_valid <= 0;
            tracking_valid <= 0;
            reacquire_count <= 0;
            frame_bad <= 1;
            overrun_block <= 0;
            column_count <= 0;
        end else begin
            if (I_tuser) begin
                frame_active <= 1'b1;
                beat_count <= 0;
                sample_phase <= 0;
                sample_lane <= 0;
                frame_bad <= hold_updates || (CONFIDENCE_ENABLE != 0 && line_bad);
                column_count <= 0;
                if (pending_ready && !hold_updates) begin
                    gain_r_q8 <= committed_gain_r;
                    gain_b_q8 <= committed_gain_b;
                    pending_ready <= 1'b0;
                end
            end

            if (stats_valid) begin
                beat_count <= (I_tuser ? 0 : beat_count) + 1'b1;
                column_count <= expected_last ? 0 :
                    (I_tuser ? 0 : column_count) + 1'b1;
                if ((CONFIDENCE_ENABLE != 0 && line_bad) || hold_updates)
                    frame_bad <= 1'b1;
                sample_phase <= (I_tuser ? 0 : sample_phase) + 1'b1;
                if (take_sample)
                    sample_lane <= (I_tuser ? 0 : sample_lane) + 1'b1;
                if (frame_complete) begin
                    // Ignore extra valid pixels until the next marker, and
                    // discard a truncated frame when that marker arrives.
                    frame_active <= 1'b0;
                    overrun_block <= 0;
                end
            end

            // Stage 4: use registered complete-frame statistics only.
            if (stats_ready && frame_stats_ok && !hold_updates &&
                div_state == DIV_IDLE && !pending_ready) begin
                div_state <= DIV_RED;
                div_bit_count <= 6'd39;
                div_quotient <= {sum_g, 8'd0};
                div_remainder <= 0;
                div_denominator <= sum_r;
                div_green_sum <= sum_g;
                div_blue_denominator <= sum_b;
            end

            if (div_state != DIV_IDLE) begin
                if (div_bit_count < DIV_BITS) begin
                    div_quotient <= div_next_quotient;
                    div_remainder <= div_next_remainder;
                end
                if (div_bit_count != 0) begin
                    div_bit_count <= div_bit_count - 1'b1;
                end else if (div_state == DIV_RED) begin
                    div_red_result <= F_limit_gain(div_next_quotient);
                    div_state <= DIV_BLUE;
                    div_bit_count <= 6'd39;
                    div_quotient <= {div_green_sum, 8'd0};
                    div_remainder <= 0;
                    div_denominator <= div_blue_denominator;
                end else begin
                    if (CONFIDENCE_ENABLE == 0 || candidate_approved) begin
                        pending_r_q8 <= div_red_result;
                        pending_b_q8 <= blue_result;
                        committed_gain_r <= F_smooth_gain(gain_r_q8, div_red_result);
                        committed_gain_b <= F_smooth_gain(gain_b_q8, blue_result);
                        pending_ready <= 1'b1;
                        tracking_valid <= 1'b1;
                        reacquire_count <= 0;
                    end
                    candidate_r <= div_red_result;
                    candidate_b <= blue_result;
                    candidate_valid <= capture_range_ok;
                    div_state <= DIV_IDLE;
                end
            end
            if (CONFIDENCE_ENABLE && confidence_failure) begin
                candidate_valid <= 0;
                if (reacquire_count == REACQUIRE_FRAMES-1) begin
                    tracking_valid <= 0;
                    reacquire_count <= 0;
                end else reacquire_count <= reacquire_count + 1'b1;
            end
            if (CONFIDENCE_ENABLE &&
                (abandoned_frame || (stats_ready &&
                 (!frame_stats_ok || div_state != DIV_IDLE)))) begin
                pending_ready <= 0;
                div_state <= DIV_IDLE;
            end
            if (hold_updates && frame_active) frame_bad <= 1'b1;
            if (CONFIDENCE_ENABLE && extra_pixels) begin
                overrun_block <= 1;
                pending_ready <= 0;
                candidate_valid <= 0;
                div_state <= DIV_IDLE;
            end
            if (hold_updates) begin
                overrun_block <= 1;
                pending_ready <= 0;
                candidate_valid <= 0;
                div_state <= DIV_IDLE;
                reacquire_count <= 0;
            end
        end
    end

    reg valid_d1, valid_d2;
    reg last_d1, last_d2;
    reg [18:0] product_r [0:3];
    reg [18:0] product_b [0:3];
    reg [7:0] green_d1 [0:3];
    reg [95:0] output_data;
    integer lane;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            valid_d1 <= 1'b0;
            valid_d2 <= 1'b0;
            last_d1 <= 1'b0;
            last_d2 <= 1'b0;
            output_data <= 0;
            for (lane = 0; lane < 4; lane = lane+1) begin
                product_r[lane] <= 0;
                product_b[lane] <= 0;
                green_d1[lane] <= 0;
            end
        end else begin
            valid_d1 <= I_tvalid;
            valid_d2 <= valid_d1;
            last_d1 <= I_tvalid && I_tlast;
            last_d2 <= last_d1;
            for (lane = 0; lane < 4; lane = lane+1) begin
                product_r[lane] <=
                    I_tdata[lane*24+16 +: 8] * pixel_gain_r;
                product_b[lane] <=
                    I_tdata[lane*24 +: 8] * pixel_gain_b;
                green_d1[lane] <= I_tdata[lane*24+8 +: 8];
                output_data[lane*24+16 +: 8] <=
                    |product_r[lane][18:16] ? 8'd255 :
                    product_r[lane][15:8];
                output_data[lane*24+8 +: 8] <= green_d1[lane];
                output_data[lane*24 +: 8] <=
                    |product_b[lane][18:16] ? 8'd255 :
                    product_b[lane][15:8];
            end
        end
    end

    // Preserve the early frame-start marker and the old pixel arrival time.
    // A fixed delay shifts bubbles too, so row lengths and byte order stay
    // unchanged. 64x96 distributed RAM avoids the old 2048-word frame buffer
    // and a 4992-flip-flop pixel shift register.
    reg [51:0] video_valid_delay;
    reg [51:0] video_last_delay;
    wire [95:0] video_delayed_data;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            video_valid_delay <= 52'd0;
            video_last_delay <= 52'd0;
        end else begin
            video_valid_delay <= {video_valid_delay[50:0], valid_d2};
            video_last_delay <= {video_last_delay[50:0], last_d2};
        end
    end
    genvar video_bank;
    generate for (video_bank=0; video_bank<4; video_bank=video_bank+1) begin : g_video_delay
        // Independent same-phase pointers keep address routing local to a lane.
        (* preserve=1 *) reg [5:0] write_address, read_address;
        always @(posedge I_clk or negedge I_rst_n) begin
            if (!I_rst_n) begin
                write_address <= 6'd0;
                // 51 stored clocks behind the write pointer plus one read FF.
                read_address <= 6'd13;
            end else begin
                write_address <= write_address + 1'b1;
                read_address <= read_address + 1'b1;
            end
        end
        PH1P_LOGIC_DRAM #(
            .DATA_WIDTH_W(24), .DATA_WIDTH_R(24),
            .ADDR_WIDTH_W(6), .ADDR_WIDTH_R(6),
            .DATA_DEPTH_W(64), .DATA_DEPTH_R(64),
            .READREG("ENABLE"), .RESETMODE("ASYNC"),
            .INIT_FILE("NONE"), .FILL_ALL("NONE")
        ) u_video_start_guard (
            .di(output_data[video_bank*24 +: 24]),
            .waddr(write_address), .we(I_rst_n), .wclk(I_clk),
            .raddr(read_address), .rclk(I_clk), .rrst(!I_rst_n), .rce(1'b1),
            .rdo(), .rdoq(video_delayed_data[video_bank*24 +: 24])
        );
    end endgenerate

    assign I_tready = O_tready;
    assign O_tuser = I_tuser;
    assign O_tvalid = video_valid_delay[51];
    assign O_tdata = O_tvalid ? video_delayed_data : 96'd0;
    assign O_tlast = O_tvalid && video_last_delay[51];

    generate
        if (DIAGNOSTIC_ENABLE != 0) begin : g_diagnostic
            reg [1:0] user_delay;
            reg [7:0] clip_new;
            integer diag_lane;
            always @(posedge I_clk or negedge I_rst_n) begin
                if (!I_rst_n) begin
                    user_delay <= 0;
                    clip_new <= 0;
                end else begin
                    user_delay <= {user_delay[0],I_tuser};
                    for (diag_lane=0; diag_lane<4; diag_lane=diag_lane+1) begin
                        clip_new[2*diag_lane+1] <= |product_r[diag_lane][18:16];
                        clip_new[2*diag_lane] <= |product_b[diag_lane][18:16];
                    end
                end
            end
            assign O_diag_valid = valid_d2;
            assign O_diag_user = user_delay[1];
            assign O_diag_last = valid_d2 && last_d2;
            assign O_diag_data = valid_d2 ? output_data : 96'd0;
            assign O_diag_clip_new = valid_d2 ? clip_new : 8'd0;
            assign O_diag_gain_r_q8 = gain_r_q8;
            assign O_diag_gain_b_q8 = gain_b_q8;
            assign O_diag_candidate_valid = candidate_valid;
            assign O_diag_stats_valid = stats_ready;
            assign O_diag_sample_count =
                sample_count > 65535 ? 16'hffff : sample_count;
        end else begin : g_no_diagnostic
            assign O_diag_valid = 1'b0;
            assign O_diag_user = 1'b0;
            assign O_diag_last = 1'b0;
            assign O_diag_data = 96'd0;
            assign O_diag_clip_new = 8'd0;
            assign O_diag_gain_r_q8 = 11'd0;
            assign O_diag_gain_b_q8 = 11'd0;
            assign O_diag_candidate_valid = 1'b0;
            assign O_diag_stats_valid = 1'b0;
            assign O_diag_sample_count = 16'd0;
        end
    endgenerate
endmodule
