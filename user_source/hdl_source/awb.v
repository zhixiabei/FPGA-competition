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
    parameter integer MAX_GAIN_Q8 = 1024
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
    input wire O_tready
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
    reg [39:0] div_quotient;
    reg [SUM_BITS:0] div_remainder;
    reg [SUM_BITS-1:0] div_denominator;
    reg [SUM_BITS-1:0] div_green_sum, div_blue_denominator;
    reg [10:0] div_red_result;

    // Selecting a different lane at successive sample points avoids sampling
    // only one of the four Bayer reconstruction positions.
    wire [1:0] selected_lane = I_tuser ? 2'd0 : sample_lane;
    wire [23:0] sample_rgb = I_tdata >> (selected_lane * 24);
    wire stats_valid = I_tvalid && (frame_active || I_tuser);
    wire take_sample = stats_valid &&
        (I_tuser || sample_phase == {SAMPLE_LOG2{1'b0}});
    wire frame_complete = stats_valid &&
        (I_tuser ? FRAME_BEATS == 1 : beat_count == FRAME_BEATS-1);

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
    wire sample_neutral_d1 =
        sample_max_d1 >= 8'd40 && sample_max_d1 <= 8'd220 &&
        sample_spread_d1 <= (sample_max_d1 >> 1) &&
        {1'b0, red_d1} <= neutral_upper_d1 && red_d1 >= neutral_lower_d1 &&
        {1'b0, blue_d1} <= neutral_upper_d1 && blue_d1 >= neutral_lower_d1;

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
        end else begin
            // Stage 0: select and capture one of the four input pixels.
            sample_rgb_d0 <= sample_rgb;
            sample_take_d0 <= take_sample;
            stats_start_d0 <= I_tuser;
            stats_end_d0 <= frame_complete;
            // Stage 1: channel extrema, aligned with the sample and tokens.
            sample_rgb_d1 <= sample_rgb_d0;
            sample_max_d1 <= max_rg_d0 > blue_d0 ? max_rg_d0 : blue_d0;
            sample_min_d1 <= min_rg_d0 < blue_d0 ? min_rg_d0 : blue_d0;
            sample_take_d1 <= sample_take_d0;
            stats_start_d1 <= stats_start_d0;
            stats_end_d1 <= stats_end_d0;
            // Stage 2: qualify a non-clipped, approximately neutral sample.
            sample_rgb_d2 <= sample_rgb_d1;
            sample_accept_d2 <= sample_take_d1 && sample_neutral_d1;
            stats_start_d2 <= stats_start_d1;
            stats_end_d2 <= stats_end_d1;
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
        end else begin
            stats_ready <= stats_end_d2;
            if (stats_start_d2) begin
                sum_r <= 0;
                sum_g <= 0;
                sum_b <= 0;
                sample_count <= 0;
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
            end
        end
    end

    // Restoring division: one quotient bit each clock, using one subtractor.
    // Keep all 40 numerator bits; G<<8 must not lose its high bits.
    wire [SUM_BITS:0] div_trial =
        {div_remainder[SUM_BITS-1:0], div_quotient[39]};
    wire div_subtract = div_trial >= {1'b0, div_denominator};
    wire [SUM_BITS:0] div_next_remainder = div_subtract ?
        div_trial - {1'b0, div_denominator} : div_trial;
    wire [39:0] div_next_quotient =
        {div_quotient[38:0], div_subtract};

    function [10:0] F_limit_gain;
        input [39:0] quotient;
        begin
            if (quotient < MIN_GAIN_Q8)
                F_limit_gain = MIN_GAIN_Q8;
            else if (quotient > MAX_GAIN_Q8)
                F_limit_gain = MAX_GAIN_Q8;
            else
                F_limit_gain = quotient[10:0];
        end
    endfunction

    // One eighth of the difference, rounded towards the target. A minimum
    // one-LSB step prevents a small residual colour error from becoming stuck.
    function [10:0] F_smooth_gain;
        input [10:0] current_gain;
        input [10:0] target_gain;
        reg [11:0] difference;
        reg [11:0] step;
        begin
            if (target_gain >= current_gain) begin
                difference = target_gain - current_gain;
                step = (difference + 12'd7) >> 3;
                F_smooth_gain = current_gain + step;
            end else begin
                difference = current_gain - target_gain;
                step = (difference + 12'd7) >> 3;
                F_smooth_gain = current_gain - step;
            end
        end
    endfunction

    wire [10:0] committed_gain_r =
        F_smooth_gain(gain_r_q8, pending_r_q8);
    wire [10:0] committed_gain_b =
        F_smooth_gain(gain_b_q8, pending_b_q8);
    // When SOF and the first valid pixel coincide, that pixel already belongs
    // to the new frame and must use the same gain as the rest of that frame.
    wire [10:0] pixel_gain_r = I_tuser && pending_ready ?
        committed_gain_r : gain_r_q8;
    wire [10:0] pixel_gain_b = I_tuser && pending_ready ?
        committed_gain_b : gain_b_q8;

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
            pending_ready <= 1'b0;
            div_state <= DIV_IDLE;
            div_bit_count <= 0;
            div_quotient <= 0;
            div_remainder <= 0;
            div_denominator <= 0;
            div_green_sum <= 0;
            div_blue_denominator <= 0;
            div_red_result <= 11'd256;
        end else begin
            if (I_tuser) begin
                frame_active <= 1'b1;
                beat_count <= 0;
                sample_phase <= 0;
                sample_lane <= 0;
                if (pending_ready) begin
                    gain_r_q8 <= committed_gain_r;
                    gain_b_q8 <= committed_gain_b;
                    pending_ready <= 1'b0;
                end
            end

            if (stats_valid) begin
                beat_count <= (I_tuser ? 0 : beat_count) + 1'b1;
                sample_phase <= (I_tuser ? 0 : sample_phase) + 1'b1;
                if (take_sample)
                    sample_lane <= (I_tuser ? 0 : sample_lane) + 1'b1;
                if (frame_complete) begin
                    // Ignore extra valid pixels until the next marker, and
                    // discard a truncated frame when that marker arrives.
                    frame_active <= 1'b0;
                end
            end

            // Stage 4: use registered complete-frame statistics only.
            if (stats_ready && sample_count >= MIN_SAMPLES &&
                sum_r != 0 && sum_b != 0 &&
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
                div_quotient <= div_next_quotient;
                div_remainder <= div_next_remainder;
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
                    pending_r_q8 <= div_red_result;
                    pending_b_q8 <= F_limit_gain(div_next_quotient);
                    pending_ready <= 1'b1;
                    div_state <= DIV_IDLE;
                end
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
    reg [5:0] video_write_address, video_read_address;
    reg [51:0] video_valid_delay;
    reg [51:0] video_last_delay;
    wire [95:0] video_delayed_data;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            video_write_address <= 6'd0;
            // 51 stored clocks behind the write pointer plus one read FF.
            video_read_address <= 6'd13;
            video_valid_delay <= 52'd0;
            video_last_delay <= 52'd0;
        end else begin
            video_write_address <= video_write_address + 1'b1;
            video_read_address <= video_read_address + 1'b1;
            video_valid_delay <= {video_valid_delay[50:0], valid_d2};
            video_last_delay <= {video_last_delay[50:0], last_d2};
        end
    end
    PH1P_LOGIC_DRAM #(
        .DATA_WIDTH_W(96), .DATA_WIDTH_R(96),
        .ADDR_WIDTH_W(6), .ADDR_WIDTH_R(6),
        .DATA_DEPTH_W(64), .DATA_DEPTH_R(64),
        .READREG("ENABLE"), .RESETMODE("ASYNC"),
        .INIT_FILE("NONE"), .FILL_ALL("NONE")
    ) u_video_start_guard (
        .di(output_data), .waddr(video_write_address), .we(I_rst_n), .wclk(I_clk),
        .raddr(video_read_address), .rclk(I_clk), .rrst(!I_rst_n), .rce(1'b1),
        .rdo(), .rdoq(video_delayed_data)
    );

    assign I_tready = O_tready;
    assign O_tuser = I_tuser;
    assign O_tvalid = video_valid_delay[51];
    assign O_tdata = O_tvalid ? video_delayed_data : 96'd0;
    assign O_tlast = O_tvalid && video_last_delay[51];
endmodule
