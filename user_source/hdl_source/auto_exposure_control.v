// Frame-rate automatic exposure for the SC520CS exposure/gain register table.
// All arithmetic is integer comparisons, shifts and additions; no divider.
// Input statistics must already be transferred coherently into I_clk.
// I_sum_y is the sum of NON-HIGHLIGHT luma; I_sample_count includes every
// metered sample and I_bright_count counts the samples excluded from that sum.
module auto_exposure_control #(
    parameter integer EXPOSURE_MIN = 4,
    parameter integer EXPOSURE_MAX = 1991,
    parameter integer EXPOSURE_DEFAULT = 1000,
    parameter integer GAIN_MIN = 16,
    parameter integer GAIN_MAX = 144,
    parameter integer GAIN_DEFAULT = 16,
    parameter integer TARGET_LOW = 96,
    parameter integer TARGET_HIGH = 128,
    parameter integer DARK_FAST = 48,
    parameter integer BRIGHT_FAST = 160,
    parameter integer SETTLE_FRAMES = 3
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
    // Constant scaling is expressed as shift/add to prohibit inferred
    // runtime multipliers. Thresholds are 8-bit luma values.
    function [31:0] count_scale;
        input [15:0] count;
        input [7:0] level;
        integer bit_index;
        reg [31:0] total;
        begin
            total = 32'd0;
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
                if (level[bit_index])
                    total = total + ({16'd0, count} << bit_index);
            count_scale = total;
        end
    endfunction

    localparam [2:0] ST_INITIAL = 3'd0;
    localparam [2:0] ST_WAIT_BUSY = 3'd1;
    localparam [2:0] ST_WAIT_DONE = 3'd2;
    localparam [2:0] ST_SETTLE = 3'd3;
    localparam [2:0] ST_TRACK = 3'd4;
    reg [2:0] state;
    reg [7:0] settle_remaining;

    wire [15:0] background_count = I_sample_count - I_bright_count;
    wire stats_ok = (I_sample_count != 0) &&
                    (I_bright_count <= I_sample_count) &&
                    (I_sum_y <= count_scale(background_count, 8'd255));
    wire too_dark = I_sum_y < count_scale(background_count, TARGET_LOW);
    wire too_bright = I_sum_y > count_scale(background_count, TARGET_HIGH);
    wire fast_dark = I_sum_y < count_scale(background_count, DARK_FAST);
    wire fast_bright = I_sum_y > count_scale(background_count, BRIGHT_FAST);
    // Meter non-highlight objects rather than a lamp/screen's contribution.
    // If over 87.5% of samples are highlights, recover from near-full white.
    // Brightening needs at least 25% useful background; a dark background
    // fraction of 12.5%..25% holds exposure to avoid boundary oscillation.
    wire near_full_white = ({16'd0, background_count} << 3) <
                           {16'd0, I_sample_count};
    wire enough_background = ({16'd0, background_count} << 2) >=
                             {16'd0, I_sample_count};
    wire reduce_light = too_bright || near_full_white;
    wire increase_light = too_dark && enough_background;
    wire fast_step = fast_dark || fast_bright || near_full_white;
    wire [15:0] exposure_step_shift = fast_step ? (O_ae >> 2) : (O_ae >> 3);
    wire [15:0] exposure_step =
        (exposure_step_shift < 4) ? 16'd4 : exposure_step_shift;
    wire [15:0] gain_step = fast_step ? 16'd16 : 16'd4;
    reg [15:0] next_exposure;
    reg [15:0] next_gain;

    always @(*) begin
        next_exposure = O_ae;
        next_gain = O_ag;
        if (reduce_light) begin
            // Remove electronic amplification before shortening exposure.
            if (O_ag > GAIN_MIN)
                next_gain = (O_ag > GAIN_MIN + gain_step) ?
                            O_ag - gain_step : GAIN_MIN;
            else if (O_ae > EXPOSURE_MIN)
                next_exposure = (O_ae > EXPOSURE_MIN + exposure_step) ?
                                O_ae - exposure_step : EXPOSURE_MIN;
        end else if (increase_light) begin
            // Use photon collection first; gain cannot restore information
            // that the sensor never captured.
            if (O_ae < EXPOSURE_MAX)
                next_exposure = ({1'b0, O_ae} + exposure_step < EXPOSURE_MAX) ?
                                O_ae + exposure_step : EXPOSURE_MAX;
            else if (O_ag < GAIN_MAX)
                next_gain = ({1'b0, O_ag} + gain_step < GAIN_MAX) ?
                            O_ag + gain_step : GAIN_MAX;
        end
    end

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            state <= ST_INITIAL;
            settle_remaining <= 8'd0;
            O_ae_req <= 1'b0;
            O_ae <= EXPOSURE_DEFAULT;
            O_ag <= GAIN_DEFAULT;
        end else begin
            O_ae_req <= 1'b0;
            if (!I_cam_cfg_done) begin
                // A failed/restarted camera configuration must pass through
                // the safe initial write again. Retain parameters meanwhile.
                state <= ST_INITIAL;
                settle_remaining <= 8'd0;
            end else case (state)
                ST_INITIAL: if (I_ae_cfg_done) begin
                    O_ae <= EXPOSURE_DEFAULT;
                    O_ag <= GAIN_DEFAULT;
                    O_ae_req <= 1'b1;
                    state <= ST_WAIT_BUSY;
                end
                // "done" starts high. Require its falling and rising edges
                // so a stale done level cannot complete a new request.
                ST_WAIT_BUSY: if (!I_ae_cfg_done)
                    state <= ST_WAIT_DONE;
                ST_WAIT_DONE: if (I_ae_cfg_done) begin
                    settle_remaining <= SETTLE_FRAMES;
                    state <= (SETTLE_FRAMES == 0) ? ST_TRACK : ST_SETTLE;
                end
                ST_SETTLE: if (I_stats_valid && stats_ok) begin
                    if (settle_remaining <= 1) begin
                        settle_remaining <= 8'd0;
                        state <= ST_TRACK;
                    end else
                        settle_remaining <= settle_remaining - 1'b1;
                end
                ST_TRACK: if (I_ae_cfg_done && I_stats_valid && stats_ok &&
                              ((next_exposure != O_ae) || (next_gain != O_ag))) begin
                    O_ae <= next_exposure;
                    O_ag <= next_gain;
                    O_ae_req <= 1'b1;
                    state <= ST_WAIT_BUSY;
                end
                default: state <= ST_INITIAL;
            endcase
        end
    end
endmodule
