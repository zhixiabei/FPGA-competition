// Frame-rate automatic exposure for the SC520CS exposure/gain register table.
// Statistics are capped RAW10 component sums; all decisions use comparisons,
// shifts and additions. Frame averaging limits chasing lighting modulation;
// it does not synchronize sensor exposure time to mains lighting.
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
    parameter integer AVERAGE_FRAMES = 6,
    parameter integer FAST_AVERAGE_FRAMES = 0,
    parameter integer HIGHLIGHT_ENABLE = 0,
    parameter integer FIXED_SAMPLE_COUNT = 0,
    parameter integer CHECK_BRIGHT_COUNT = 1
) (
    input wire I_clk,
    input wire I_rst,
    input wire I_cam_cfg_done,
    input wire I_ae_cfg_done,
    input wire I_stats_valid,
    input wire [31:0] I_sum_y,
    input wire [15:0] I_sample_count,
    input wire [15:0] I_bright_count,
    input wire [4:0] I_p95,
    output reg O_ae_req,
    output reg [15:0] O_ae,
    output reg [15:0] O_ag,
    output reg O_awb_hold
);
    function integer bit_width;
        input integer size;
        integer value;
        begin
            value = size - 1;
            bit_width = 0;
            while (value > 0) begin
                value = value >> 1;
                bit_width = bit_width + 1;
            end
            if (bit_width < 1)
                bit_width = 1;
        end
    endfunction

    // A valid frame has at most 65535 samples and METER_MAX per sample.
    // Keep the interface full width so malformed sums cannot wrap into valid
    // statistics; only the accepted window uses these bounded accumulators.
    // The integrated RAW meter publishes exactly one fixed-size sample set.
    // Specializing that contract removes variable count products and the
    // window count accumulator. Zero retains the variable-count interface.
    localparam integer MAX_WINDOW_COUNT =
        (FIXED_SAMPLE_COUNT != 0 ? FIXED_SAMPLE_COUNT : 65535) * AVERAGE_FRAMES;
    localparam integer COUNT_BITS = bit_width(MAX_WINDOW_COUNT + 1);
    localparam integer SUM_BITS =
        bit_width(MAX_WINDOW_COUNT * (METER_MAX + (HIGHLIGHT_ENABLE ? 16 : 0)) + 1);
    localparam integer FRAME_BITS = bit_width(AVERAGE_FRAMES);
    localparam integer SETTLE_BITS = bit_width(SETTLE_FRAMES + 1);
    localparam integer MAX_CONTROL_CODE =
        EXPOSURE_MAX > GAIN_MAX ? EXPOSURE_MAX : GAIN_MAX;
    // Gain steps can be 16 even with a smaller configured range.
    localparam integer CONTROL_BITS =
        bit_width(MAX_CONTROL_CODE + 1) < 5 ? 5 :
        bit_width(MAX_CONTROL_CODE + 1);

    function [SUM_BITS-1:0] count_scale;
        input [COUNT_BITS-1:0] count;
        input [7:0] level;
        integer bit_index;
        reg [SUM_BITS-1:0] total;
        begin
            total = {SUM_BITS{1'b0}};
            // The default upper target is 120 = 128 - 8. Use one
            // subtraction instead of the three adders in 8 + 16 + 32 + 64.
            if (level == 8'd120)
                total = ({{(SUM_BITS-COUNT_BITS){1'b0}}, count} << 7) -
                        ({{(SUM_BITS-COUNT_BITS){1'b0}}, count} << 3);
            else
                for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
                    if (level[bit_index])
                        total = total +
                            ({{(SUM_BITS-COUNT_BITS){1'b0}}, count} << bit_index);
            count_scale = total;
        end
    endfunction

    localparam [2:0] ST_INITIAL = 3'd0;
    localparam [2:0] ST_WAIT_BUSY = 3'd1;
    localparam [2:0] ST_WAIT_DONE = 3'd2;
    localparam [2:0] ST_SETTLE = 3'd3;
    localparam [2:0] ST_COLLECT = 3'd4;

    reg [2:0] state;
    reg [SETTLE_BITS-1:0] settle_remaining;
    reg [FRAME_BITS-1:0] frame_count;
    reg [SUM_BITS-1:0] sum_accum;
    reg [COUNT_BITS-1:0] count_accum;
    reg fast_window_dark, fast_window_bright;

    wire [COUNT_BITS-1:0] input_count =
        FIXED_SAMPLE_COUNT != 0 ? FIXED_SAMPLE_COUNT : I_sample_count;
    wire stats_ok = (I_sample_count != 0) &&
                    (FIXED_SAMPLE_COUNT == 0 ||
                     I_sample_count == FIXED_SAMPLE_COUNT) &&
                    (CHECK_BRIGHT_COUNT == 0 ||
                     I_bright_count <= I_sample_count) &&
                    (I_sum_y <= count_scale(input_count, METER_MAX));
    // One monotonic score, not competing mean/highlight directions. P95
    // at RAW 768 or above contributes at most 16 meter codes. Therefore mean<80
    // always brightens with the production lower target 96, even if clipped.
    // Quantile bucket code uses an 8-RAW8-code grid (RAW10 / 32).
    wire [4:0] highlight_bias = HIGHLIGHT_ENABLE && I_p95>23 ?
        ({1'b0,I_p95[3:0]}-5'd7)<<1 : 5'd0;
    wire [SUM_BITS-1:0] frame_sum = I_sum_y[SUM_BITS-1:0] +
        count_scale(input_count, {3'd0,highlight_bias});
    wire [SUM_BITS-1:0] window_sum = sum_accum + frame_sum;
    // Shorten a window only when every accepted frame is far from target
    // in the same direction. Mixed or near-target scenes retain averaging.
    wire frame_fast_dark = frame_sum < count_scale(input_count, DARK_FAST);
    wire frame_fast_bright = frame_sum > count_scale(input_count, BRIGHT_FAST);
    wire fast_window_complete = FAST_AVERAGE_FRAMES != 0 &&
        frame_count == FAST_AVERAGE_FRAMES-1 &&
        ((fast_window_dark && frame_fast_dark) ||
         (fast_window_bright && frame_fast_bright));
    // Fixed-count builds select two constant bounds, without a multiplier.
    wire [COUNT_BITS-1:0] window_count = FIXED_SAMPLE_COUNT != 0 ?
        (fast_window_complete ? FIXED_SAMPLE_COUNT * FAST_AVERAGE_FRAMES :
         MAX_WINDOW_COUNT) : count_accum + input_count;
    wire window_complete = frame_count == AVERAGE_FRAMES - 1 || fast_window_complete;

    wire too_dark = window_sum < count_scale(window_count, TARGET_LOW);
    wire too_bright = window_sum > count_scale(window_count, TARGET_HIGH);
    wire fast_dark = window_sum < count_scale(window_count, DARK_FAST);
    wire fast_bright = window_sum > count_scale(window_count, BRIGHT_FAST);
    // A bounded highlight contribution shares the same deadband/direction.
    // Near-clipping count remains checked; it cannot latch dark scenes.
    wire reduce_light = too_bright;
    wire increase_light = too_dark;
    wire fast_step = fast_dark || fast_bright;
    wire [CONTROL_BITS-1:0] exposure_step_shift =
        fast_dark ? (O_ae >> 1) :
        fast_bright ? (O_ae >> 2) : (O_ae >> 3);
    // One-code resolution avoids large relative jumps near EXPOSURE_MIN.
    wire [CONTROL_BITS-1:0] exposure_step =
        exposure_step_shift == 0 ? 1 : exposure_step_shift;
    wire [CONTROL_BITS-1:0] gain_step = fast_step ? 16 : 4;

    // Each command changes only one register. Share its bounded add/subtract
    // path across exposure and gain, including saturation at either endpoint.
    wire adjust_gain = reduce_light ? (O_ag > GAIN_MIN) :
                                     (O_ae >= EXPOSURE_MAX);
    wire [CONTROL_BITS-1:0] control_value =
        adjust_gain ? O_ag[CONTROL_BITS-1:0] : O_ae[CONTROL_BITS-1:0];
    wire [CONTROL_BITS-1:0] control_step =
        adjust_gain ? gain_step : exposure_step;
    wire [CONTROL_BITS-1:0] control_min =
        adjust_gain ? GAIN_MIN : EXPOSURE_MIN;
    wire [CONTROL_BITS-1:0] control_max =
        adjust_gain ? GAIN_MAX : EXPOSURE_MAX;
    wire [CONTROL_BITS:0] control_operand =
        {1'b0, control_step} ^ {(CONTROL_BITS+1){reduce_light}};
    wire [CONTROL_BITS:0] control_adjusted =
        {1'b0, control_value} + control_operand + reduce_light;
    wire [CONTROL_BITS-1:0] control_clamped =
        reduce_light ?
            ((control_adjusted[CONTROL_BITS] || control_adjusted < control_min) ?
             control_min : control_adjusted[CONTROL_BITS-1:0]) :
            (control_adjusted > control_max ?
             control_max : control_adjusted[CONTROL_BITS-1:0]);
    reg [15:0] next_exposure;
    reg [15:0] next_gain;

    always @(*) begin
        next_exposure = O_ae;
        next_gain = O_ag;
        if (reduce_light || increase_light) begin
            if (adjust_gain)
                next_gain = control_clamped;
            else
                next_exposure = control_clamped;
        end
    end

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            state <= ST_INITIAL;
            settle_remaining <= {SETTLE_BITS{1'b0}};
            frame_count <= {FRAME_BITS{1'b0}};
            sum_accum <= {SUM_BITS{1'b0}};
            count_accum <= {COUNT_BITS{1'b0}};
            fast_window_dark <= 1'b0;
            fast_window_bright <= 1'b0;
            O_ae_req <= 1'b0;
            O_ae <= EXPOSURE_DEFAULT;
            O_ag <= GAIN_DEFAULT;
            O_awb_hold <= 1'b1;
        end else begin
            O_ae_req <= 1'b0;
            // Collection is not convergence: keep WB frozen through every
            // write/settle/window until a complete window needs no change.
            if (!I_ae_cfg_done) O_awb_hold <= 1'b1;
            if (!I_cam_cfg_done) begin
                O_awb_hold <= 1'b1;
                state <= ST_INITIAL;
                settle_remaining <= {SETTLE_BITS{1'b0}};
                frame_count <= {FRAME_BITS{1'b0}};
                sum_accum <= {SUM_BITS{1'b0}};
                count_accum <= {COUNT_BITS{1'b0}};
            end else case (state)
                ST_INITIAL: begin
                    O_awb_hold <= 1'b1;
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
                    frame_count <= {FRAME_BITS{1'b0}};
                    sum_accum <= {SUM_BITS{1'b0}};
                    count_accum <= {COUNT_BITS{1'b0}};
                    state <= SETTLE_FRAMES == 0 ? ST_COLLECT : ST_SETTLE;
                end
                ST_SETTLE: if (I_stats_valid && stats_ok) begin
                    if (settle_remaining <= 1) begin
                        settle_remaining <= {SETTLE_BITS{1'b0}};
                        state <= ST_COLLECT;
                    end else begin
                        settle_remaining <= settle_remaining - 1'b1;
                    end
                end
                ST_COLLECT: if (I_stats_valid && stats_ok) begin
                    fast_window_dark <= frame_fast_dark &&
                        (frame_count == 0 || fast_window_dark);
                    fast_window_bright <= frame_fast_bright &&
                        (frame_count == 0 || fast_window_bright);
                    if (window_complete) begin
                        frame_count <= {FRAME_BITS{1'b0}};
                        sum_accum <= {SUM_BITS{1'b0}};
                        count_accum <= {COUNT_BITS{1'b0}};
                        if (I_ae_cfg_done &&
                            ((next_exposure != O_ae) || (next_gain != O_ag))) begin
                            O_ae <= next_exposure;
                            O_ag <= next_gain;
                            O_ae_req <= 1'b1;
                            O_awb_hold <= 1'b1;
                            state <= ST_WAIT_BUSY;
                        end else if (I_ae_cfg_done) begin
                            // A saturated sensor setting is stable too;
                            // unreachable brightness must not freeze WB forever.
                            O_awb_hold <= 1'b0;
                        end
                    end else begin
                        frame_count <= frame_count + 1'b1;
                        sum_accum <= window_sum;
                        count_accum <= window_count;
                    end
                end
                default: begin
                    state <= ST_INITIAL;
                    O_awb_hold <= 1'b1;
                end
            endcase
        end
    end

    // synthesis translate_off
    initial begin
        if (AVERAGE_FRAMES < 1 || AVERAGE_FRAMES > 16)
            $fatal(1, "AE averaging window is outside 1..16 frames");
        if (FAST_AVERAGE_FRAMES != 0 &&
            (FAST_AVERAGE_FRAMES < 2 || FAST_AVERAGE_FRAMES >= AVERAGE_FRAMES))
            $fatal(1, "Fast AE window must be disabled or in 2..AVERAGE_FRAMES-1");
        if (SETTLE_FRAMES < 0 || SETTLE_FRAMES > 255)
            $fatal(1, "AE settle interval is outside 0..255 frames");
        if (METER_MAX < 1 || METER_MAX > 255)
            $fatal(1, "AE meter maximum is outside 1..255");
        if (FIXED_SAMPLE_COUNT < 0 || FIXED_SAMPLE_COUNT > 65535)
            $fatal(1, "AE fixed sample count is outside 0..65535");
        if (EXPOSURE_MIN < 0 || EXPOSURE_MAX > 65535 ||
            EXPOSURE_MIN > EXPOSURE_DEFAULT || EXPOSURE_DEFAULT > EXPOSURE_MAX ||
            GAIN_MIN < 0 || GAIN_MAX > 65535 ||
            GAIN_MIN > GAIN_DEFAULT || GAIN_DEFAULT > GAIN_MAX)
            $fatal(1, "AE control defaults must be inside unsigned 16-bit bounds");
        if (!(DARK_FAST < TARGET_LOW && TARGET_LOW < TARGET_HIGH &&
              TARGET_HIGH < BRIGHT_FAST && BRIGHT_FAST <= METER_MAX))
            $fatal(1, "AE thresholds are not strictly ordered");
    end
    // synthesis translate_on
endmodule
