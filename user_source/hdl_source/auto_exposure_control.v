// Frame-rate automatic exposure for the SC520CS exposure/gain register table.
// Statistics are capped RAW10 component sums; all decisions use comparisons,
// shifts and additions. Six-frame windows reject 50 Hz lighting modulation.
module auto_exposure_control #(
    parameter integer EXPOSURE_MIN = 4,
    parameter integer EXPOSURE_MAX = 1991,
    parameter integer EXPOSURE_DEFAULT = 1000,
    parameter integer GAIN_MIN = 16,
    parameter integer GAIN_MAX = 176,
    parameter integer GAIN_DEFAULT = 16,
    parameter integer METER_MAX = 192,
    parameter integer TARGET_LOW = 96,
    parameter integer TARGET_HIGH = 120,
    parameter integer DARK_FAST = 64,
    parameter integer BRIGHT_FAST = 144,
    parameter integer SETTLE_FRAMES = 3,
    parameter integer AVERAGE_FRAMES = 6
) (
    input wire I_clk,
    input wire I_rst,
    input wire I_cam_cfg_done,
    input wire I_ae_cfg_done,
    input wire I_stats_valid,
    input wire [31:0] I_sum_y,
    input wire [15:0] I_sample_count,
    input wire [15:0] I_bright_count,
    output reg O_ae_req,
    output reg [15:0] O_ae,
    output reg [15:0] O_ag
);
    function [31:0] count_scale;
        input [19:0] count;
        input [7:0] level;
        integer bit_index;
        reg [31:0] total;
        begin
            total = 32'd0;
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
                if (level[bit_index])
                    total = total + ({12'd0, count} << bit_index);
            count_scale = total;
        end
    endfunction

    localparam [2:0] ST_INITIAL = 3'd0;
    localparam [2:0] ST_WAIT_BUSY = 3'd1;
    localparam [2:0] ST_WAIT_DONE = 3'd2;
    localparam [2:0] ST_SETTLE = 3'd3;
    localparam [2:0] ST_COLLECT = 3'd4;

    reg [2:0] state;
    reg [7:0] settle_remaining;
    reg [7:0] frame_count;
    reg [31:0] sum_accum;
    reg [19:0] count_accum;
    reg [19:0] bright_accum;
    reg highlight_latched;

    wire [19:0] input_count = {4'd0, I_sample_count};
    wire [19:0] input_bright = {4'd0, I_bright_count};
    wire stats_ok = (I_sample_count != 0) &&
                    (I_bright_count <= I_sample_count) &&
                    (I_sum_y <= count_scale(input_count, METER_MAX));
    wire [31:0] window_sum = sum_accum + I_sum_y;
    wire [19:0] window_count = count_accum + input_count;
    wire [19:0] window_bright = bright_accum + input_bright;
    wire window_complete = frame_count == AVERAGE_FRAMES - 1;

    wire too_dark = window_sum < count_scale(window_count, TARGET_LOW);
    wire too_bright = window_sum > count_scale(window_count, TARGET_HIGH);
    wire fast_dark = window_sum < count_scale(window_count, DARK_FAST);
    wire fast_bright = window_sum > count_scale(window_count, BRIGHT_FAST);
    // At 25 percent clipped samples, reduce exposure even if the capped mean
    // still lies in the target band. Keep a 12.5..25 percent hysteresis band
    // after that event so the next window cannot immediately brighten again.
    wire highlight_set = ({2'b0, window_bright} << 2) >=
                         {2'b0, window_count};
    wire highlight_clear = ({3'b0, window_bright} << 3) <
                           {3'b0, window_count};
    wire highlight_next = highlight_set ? 1'b1 :
                          highlight_clear ? 1'b0 : highlight_latched;
    wire reduce_light = too_bright || highlight_set;
    wire increase_light = too_dark && !highlight_next;
    // A dark mean must not turn a highlight-triggered reduction into a fast
    // step. Fast movement is selected only by the active direction.
    wire fast_step = (reduce_light && fast_bright) ||
                     (increase_light && fast_dark);
    wire [15:0] exposure_step_shift = fast_step ? (O_ae >> 2) : (O_ae >> 3);
    wire [15:0] exposure_step =
        exposure_step_shift < 4 ? 16'd4 : exposure_step_shift;
    wire [15:0] gain_step = fast_step ? 16'd16 : 16'd4;
    wire [16:0] exposure_increase =
        {1'b0, O_ae} + {1'b0, exposure_step};
    wire [16:0] gain_increase = {1'b0, O_ag} + {1'b0, gain_step};
    reg [15:0] next_exposure;
    reg [15:0] next_gain;

    always @(*) begin
        next_exposure = O_ae;
        next_gain = O_ag;
        if (reduce_light) begin
            if (O_ag > GAIN_MIN)
                next_gain = O_ag > GAIN_MIN + gain_step ?
                            O_ag - gain_step : GAIN_MIN;
            else if (O_ae > EXPOSURE_MIN)
                next_exposure = O_ae > EXPOSURE_MIN + exposure_step ?
                                O_ae - exposure_step : EXPOSURE_MIN;
        end else if (increase_light) begin
            if (O_ae < EXPOSURE_MAX)
                next_exposure = exposure_increase < EXPOSURE_MAX ?
                                exposure_increase[15:0] : EXPOSURE_MAX;
            else if (O_ag < GAIN_MAX)
                next_gain = gain_increase < GAIN_MAX ?
                            gain_increase[15:0] : GAIN_MAX;
        end
    end

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            state <= ST_INITIAL;
            settle_remaining <= 8'd0;
            frame_count <= 8'd0;
            sum_accum <= 32'd0;
            count_accum <= 20'd0;
            bright_accum <= 20'd0;
            highlight_latched <= 1'b0;
            O_ae_req <= 1'b0;
            O_ae <= EXPOSURE_DEFAULT;
            O_ag <= GAIN_DEFAULT;
        end else begin
            O_ae_req <= 1'b0;
            if (!I_cam_cfg_done) begin
                state <= ST_INITIAL;
                settle_remaining <= 8'd0;
                frame_count <= 8'd0;
                sum_accum <= 32'd0;
                count_accum <= 20'd0;
                bright_accum <= 20'd0;
                highlight_latched <= 1'b0;
            end else case (state)
                ST_INITIAL: begin
                    highlight_latched <= 1'b0;
                    if (I_ae_cfg_done) begin
                        O_ae <= EXPOSURE_DEFAULT;
                        O_ag <= GAIN_DEFAULT;
                        O_ae_req <= 1'b1;
                        state <= ST_WAIT_BUSY;
                    end
                end
                // Done starts high. Observe both edges for every I2C write.
                ST_WAIT_BUSY: if (!I_ae_cfg_done)
                    state <= ST_WAIT_DONE;
                ST_WAIT_DONE: if (I_ae_cfg_done) begin
                    settle_remaining <= SETTLE_FRAMES;
                    frame_count <= 8'd0;
                    sum_accum <= 32'd0;
                    count_accum <= 20'd0;
                    bright_accum <= 20'd0;
                    state <= SETTLE_FRAMES == 0 ? ST_COLLECT : ST_SETTLE;
                end
                ST_SETTLE: if (I_stats_valid && stats_ok) begin
                    if (settle_remaining <= 1) begin
                        settle_remaining <= 8'd0;
                        state <= ST_COLLECT;
                    end else begin
                        settle_remaining <= settle_remaining - 1'b1;
                    end
                end
                ST_COLLECT: if (I_stats_valid && stats_ok) begin
                    if (window_complete) begin
                        frame_count <= 8'd0;
                        sum_accum <= 32'd0;
                        count_accum <= 20'd0;
                        bright_accum <= 20'd0;
                        highlight_latched <= highlight_next;
                        if (I_ae_cfg_done &&
                            ((next_exposure != O_ae) || (next_gain != O_ag))) begin
                            O_ae <= next_exposure;
                            O_ag <= next_gain;
                            O_ae_req <= 1'b1;
                            state <= ST_WAIT_BUSY;
                        end
                    end else begin
                        frame_count <= frame_count + 1'b1;
                        sum_accum <= window_sum;
                        count_accum <= window_count;
                        bright_accum <= window_bright;
                    end
                end
                default: state <= ST_INITIAL;
            endcase
        end
    end

    // synthesis translate_off
    initial begin
        if (AVERAGE_FRAMES < 1 || AVERAGE_FRAMES > 16)
            $fatal(1, "AE averaging window is outside 1..16 frames");
        if (SETTLE_FRAMES < 0 || SETTLE_FRAMES > 255)
            $fatal(1, "AE settle interval is outside 0..255 frames");
        if (!(DARK_FAST < TARGET_LOW && TARGET_LOW < TARGET_HIGH &&
              TARGET_HIGH < BRIGHT_FAST && BRIGHT_FAST <= METER_MAX))
            $fatal(1, "AE thresholds are not strictly ordered");
    end
    // synthesis translate_on
endmodule
