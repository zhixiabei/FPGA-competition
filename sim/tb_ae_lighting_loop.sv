`timescale 1ns/1ps

// End-to-end RAW statistics, CDC, six-frame AE and SC520 register-table model.
module tb_ae_lighting_loop #(
    parameter integer TARGET_LOW = 96,
    parameter integer TARGET_HIGH = 120,
    parameter integer DARK_FAST = 64,
    parameter integer BRIGHT_FAST = 144,
    parameter integer GAIN_MAX = 176,
    parameter integer SETTLE_FRAMES = 3,
    parameter integer AVERAGE_FRAMES = 6,
    parameter integer METER_CAP = 192,
    parameter integer SENSOR_APPLY_FRAMES = 2,
    parameter integer EXPECT_LEGACY = 0,
    parameter integer HIGHLIGHT_ENABLE = 0,
    parameter integer FIXED_SAMPLE_COUNT = 0,
    parameter integer CHECK_BRIGHT_COUNT = 1,
    parameter integer HOLD_OUTPUTS = 1,
    parameter integer HISTOGRAM_ENABLE = HIGHLIGHT_ENABLE,
    parameter integer HIST_BIN_BITS = 5,
    parameter integer BRIGHT_LEVEL = METER_CAP
);
    localparam integer WIDTH = 128;
    localparam integer HEIGHT = 40;
    localparam integer GROUPS = WIDTH / 4;
    localparam integer METERED_COMPONENTS = 160;

    reg src_clk = 0;
    reg control_clk = 0;
    bit src_run = 1;
    always #5 if (src_run) src_clk = ~src_clk;
    initial begin
        #2.3;
        forever #21 control_clk = ~control_clk;
    end

    reg rst_n = 0;
    reg camera_done = 0;
    reg frame_start = 0;
    reg video_valid = 0;
    reg line_last = 0;
    reg [39:0] video_data = 0;
    wire stats_valid;
    wire [31:0] frame_sum;
    wire [15:0] frame_count, frame_bright;
    wire [4:0] frame_p95;
    wire cdc_valid;
    wire [68:0] cdc_data;
    wire ae_request;
    wire [15:0] exposure, gain;
    reg ae_done = 0;

    ae_frame_stats_raw10_4x #(
        .IMG_WIDTH(WIDTH), .IMG_HEIGHT(HEIGHT), .CLIP_LEVEL(METER_CAP),
        .HISTOGRAM_ENABLE(HISTOGRAM_ENABLE), .HIST_BIN_BITS(HIST_BIN_BITS),
        .BRIGHT_LEVEL(BRIGHT_LEVEL), .HOLD_OUTPUTS(HOLD_OUTPUTS)
    ) stats (
        .I_clk(src_clk), .I_rst_n(rst_n), .I_tuser(frame_start),
        .I_tlast(line_last), .I_tvalid(video_valid), .I_tdata(video_data),
        .O_stats_valid(stats_valid), .O_sum_y(frame_sum),
        .O_sample_count(frame_count), .O_bright_count(frame_bright),
        .O_p95(frame_p95)
    );

    ae_stats_cdc #(.WIDTH(69)) cdc (
        .I_src_clk(src_clk), .I_dst_clk(control_clk), .I_rst_n(rst_n),
        .I_src_valid(stats_valid),
        .I_src_data({frame_p95, frame_sum, frame_count, frame_bright}),
        .O_dst_valid(cdc_valid), .O_dst_data(cdc_data)
    );

    auto_exposure_control #(
        .TARGET_LOW(TARGET_LOW), .TARGET_HIGH(TARGET_HIGH),
        .DARK_FAST(DARK_FAST), .BRIGHT_FAST(BRIGHT_FAST), .METER_MAX(METER_CAP),
        .GAIN_MAX(GAIN_MAX),
        .SETTLE_FRAMES(SETTLE_FRAMES), .AVERAGE_FRAMES(AVERAGE_FRAMES),
        .HIGHLIGHT_ENABLE(HIGHLIGHT_ENABLE),
        .FIXED_SAMPLE_COUNT(FIXED_SAMPLE_COUNT != 0 ? METERED_COMPONENTS : 0),
        .CHECK_BRIGHT_COUNT(CHECK_BRIGHT_COUNT)
    ) control (
        .I_clk(control_clk), .I_rst(!rst_n), .I_cam_cfg_done(camera_done),
        .I_ae_cfg_done(ae_done), .I_stats_valid(cdc_valid),
        .I_sum_y(cdc_data[63:32]), .I_sample_count(cdc_data[31:16]),
        .I_bright_count(cdc_data[15:0]), .O_ae_req(ae_request),
        .I_p95(cdc_data[68:64]),
        .O_ae(exposure), .O_ag(gain)
    );

    wire [23:0] gain_registers;
    reg [8:0] table_index = 0;
    wire [23:0] table_data;
    wire [8:0] table_size;
    SC520GainTbl gain_table(.I_AG(gain), .O(gain_registers));
    uics520regAE register_table(
        .REG_INDEX(table_index), .REG_DATA(table_data), .REG_SIZE(table_size),
        .I_AE(exposure), .I_AG(gain_registers)
    );

    reg model_busy = 0;
    reg [2:0] byte_wait = 0;
    reg [15:0] held_exposure = 0, held_gain = 16;
    reg [3:0] staged_exposure_high = 0;
    reg [7:0] staged_exposure_mid = 0;
    reg [3:0] staged_exposure_low = 0;
    reg [7:0] staged_coarse = 0, staged_digital = 0, staged_fine = 128;
    reg [15:0] active_exposure = 1991, active_gain_setting = 16;
    reg [7:0] active_coarse = 0, active_fine = 128;
    reg sensor_pending = 0;
    integer apply_frames_remaining = 0;
    reg [15:0] pending_exposure = 1000, pending_gain = 16;
    reg [7:0] pending_coarse = 0, pending_fine = 128;
    integer requests = 0, commits = 0, stability_checks = 0;
    integer convergence_failures = 0;

    function automatic integer analog_multiplier(input [7:0] coarse_code);
        begin
            case (coarse_code)
                8'h00: analog_multiplier = 1;
                8'h08: analog_multiplier = 2;
                8'h09: analog_multiplier = 4;
                8'h0b: analog_multiplier = 8;
                8'h0f: analog_multiplier = 16;
                8'h1f: analog_multiplier = 32;
                default: begin
                    analog_multiplier = 0;
                    $fatal(1, "Illegal SC520 coarse gain code %h", coarse_code);
                end
            endcase
        end
    endfunction

    function automatic [63:0] sensor_product(input integer exposure_code,
                                              input [7:0] coarse_code,
                                              input [7:0] fine_code);
        reg [63:0] product_value;
        begin
            product_value = exposure_code;
            product_value = product_value * analog_multiplier(coarse_code);
            product_value = product_value * fine_code;
            sensor_product = product_value;
        end
    endfunction

    always @(posedge control_clk or negedge rst_n) begin
        if (!rst_n) begin
            ae_done <= 0;
            model_busy <= 0;
            byte_wait <= 0;
            table_index <= 0;
            held_exposure <= 0;
            held_gain <= 16;
            staged_exposure_high <= 0;
            staged_exposure_mid <= 0;
            staged_exposure_low <= 0;
            staged_coarse <= 0;
            staged_digital <= 0;
            staged_fine <= 128;
            active_exposure <= 1991;
            active_gain_setting <= 16;
            active_coarse <= 0;
            active_fine <= 128;
            sensor_pending <= 0;
            apply_frames_remaining <= 0;
        end else if (!camera_done) begin
            ae_done <= 0;
            model_busy <= 0;
        end else if (!model_busy) begin
            ae_done <= 1;
            if (ae_request) begin
                requests = requests + 1;
                if (exposure < 4 || exposure > 1991 ||
                    gain < 16 || gain > GAIN_MAX)
                    $fatal(1, "Sensor request exceeds exposure/gain limits");
                ae_done <= 0;
                model_busy <= 1;
                byte_wait <= 0;
                table_index <= 0;
                held_exposure <= exposure;
                held_gain <= gain;
            end
        end else begin
            stability_checks = stability_checks + 1;
            if (ae_request || exposure !== held_exposure || gain !== held_gain)
                $fatal(1, "AE changed parameters during an active register write");
            if (table_size != 8)
                $fatal(1, "Unexpected AE register table size");
            byte_wait <= byte_wait + 1'b1;
            if (byte_wait == 3) begin
                byte_wait <= 0;
                case (table_index)
                    0: if (table_data !== 24'h381200)
                        $fatal(1, "Exposure group must first be held");
                    1: begin
                        if (table_data[23:8] !== 16'h3e00)
                            $fatal(1, "Wrong high-exposure register");
                        staged_exposure_high <= table_data[3:0];
                    end
                    2: begin
                        if (table_data[23:8] !== 16'h3e01)
                            $fatal(1, "Wrong middle-exposure register");
                        staged_exposure_mid <= table_data[7:0];
                    end
                    3: begin
                        if (table_data[23:8] !== 16'h3e02)
                            $fatal(1, "Wrong low-exposure register");
                        staged_exposure_low <= table_data[7:4];
                    end
                    4: staged_coarse <= table_data[7:0];
                    5: staged_digital <= table_data[7:0];
                    6: staged_fine <= table_data[7:0];
                    7: begin
                        if (table_data !== 24'h381230 || staged_digital != 0 ||
                            {staged_exposure_high, staged_exposure_mid,
                             staged_exposure_low} !== held_exposure)
                            $fatal(1, "Group release or decoded sensor parameters wrong");
                        if (sensor_pending)
                            $fatal(1, "New register write before prior image parameters applied");
                        if (SENSOR_APPLY_FRAMES == 0) begin
                            active_exposure <= held_exposure;
                            active_gain_setting <= held_gain;
                            active_coarse <= staged_coarse;
                            active_fine <= staged_fine;
                        end else begin
                            pending_exposure <= held_exposure;
                            pending_gain <= held_gain;
                            pending_coarse <= staged_coarse;
                            pending_fine <= staged_fine;
                            apply_frames_remaining <= SENSOR_APPLY_FRAMES;
                            sensor_pending <= 1;
                        end
                        model_busy <= 0;
                        ae_done <= 1;
                        commits = commits + 1;
                    end
                endcase
                table_index <= table_index + 1'b1;
            end
        end
    end

    function automatic integer modeled_raw(input integer illumination);
        reg [63:0] numerator;
        integer raw_value;
        begin
            numerator = illumination;
            numerator = numerator * active_exposure;
            numerator = numerator * analog_multiplier(active_coarse);
            numerator = numerator * active_fine;
            raw_value = numerator / 32000;
            modeled_raw = raw_value > 1023 ? 1023 : raw_value;
        end
    endfunction

    function automatic integer meter_value(input integer raw_value);
        integer value_8;
        begin
            value_8 = raw_value >> 2;
            meter_value = value_8 >= METER_CAP ? METER_CAP : value_8;
        end
    endfunction

    reg [68:0] expected_payload [0:8191];
    integer stats_written = 0, stats_read = 0;
    integer total_frames = 0;
    integer expected_frame_sum = 0, expected_frame_bright = 0;
    integer last_frame_sum = 0, last_frame_bright = 0;
    integer expected_near_sat = 0, expected_saturated = 0;
    integer expected_background_sum = 0, expected_background_count = 0;
    integer last_near_sat = 0, last_saturated = 0;
    integer last_background_raw = 0;
    integer expected_histogram[0:31];
    integer expected_p95 = 0;
    integer last_frame_score = 0, last_frame_p95 = 0;
    reg [9:0] frozen_raw [0:WIDTH*HEIGHT-1];

    always @(posedge src_clk) begin
        #1;
        if (rst_n && stats_valid) begin
            if (frame_count != METERED_COMPONENTS ||
                frame_sum != expected_frame_sum ||
                frame_bright != expected_frame_bright ||
                frame_p95 != expected_p95)
                $fatal(1,
                    "RAW metering mismatch sum=%0d/%0d count=%0d bright=%0d/%0d",
                    frame_sum, expected_frame_sum, frame_count,
                    frame_bright, expected_frame_bright);
            if (stats_written >= 8192)
                $fatal(1, "Statistics reference queue overflow");
            expected_payload[stats_written] = {frame_p95, frame_sum, frame_count, frame_bright};
            stats_written = stats_written + 1;
            last_frame_sum = frame_sum;
            last_frame_bright = frame_bright;
            last_frame_p95=frame_p95;
            last_frame_score=frame_sum + METERED_COMPONENTS *
                (HIGHLIGHT_ENABLE && expected_p95>23 ? 2*(expected_p95-23) : 0);
            last_near_sat = expected_near_sat;
            last_saturated = expected_saturated;
            last_background_raw = expected_background_count == 0 ? 0 :
                                  expected_background_sum / expected_background_count;
        end
    end

    always @(posedge control_clk) begin
        #1;
        if (rst_n && cdc_valid) begin
            if (stats_read >= stats_written ||
                cdc_data !== expected_payload[stats_read])
                $fatal(1, "Statistics CDC lost or corrupted a complete frame");
            stats_read = stats_read + 1;
        end
    end

    task automatic source_tick;
        begin
            @(posedge src_clk);
            #2;
        end
    endtask

    task automatic camera_scene(input integer background_illumination,
                                input integer light_components = 0,
                                input integer offset = 0,
                                input integer raw_noise = 0,
                                input integer lamp_illumination = 1000);
        integer row;
        integer group_index;
        integer lane;
        integer pixel_index;
        integer component_index;
        integer permuted_index;
        integer raw_value;
        integer hist_index, hist_cumulative, bucket;
        reg [39:0] raw_pack;
        begin
            component_index = 0;
            expected_frame_sum = 0;
            expected_frame_bright = 0;
            expected_near_sat = 0;
            expected_saturated = 0;
            expected_background_sum = 0;
            expected_background_count = 0;
            expected_p95=0;
            for (hist_index=0; hist_index<32; hist_index=hist_index+1)
                expected_histogram[hist_index]=0;
            for (row = 0; row < HEIGHT; row = row + 1) begin
                for (group_index = 0; group_index < GROUPS;
                     group_index = group_index + 1) begin
                    for (lane = 0; lane < 4; lane = lane + 1) begin
                        raw_value = modeled_raw(background_illumination);
                        if ((row % 8) < 2 && (group_index % 8) == 0) begin
                            permuted_index = (37 * component_index + offset) %
                                             METERED_COMPONENTS;
                            if (permuted_index < light_components)
                                raw_value = modeled_raw(lamp_illumination);
                            if (raw_noise > 0) begin
                                raw_value = raw_value +
                                    ((13 * component_index + 7 * row +
                                      5 * total_frames) % (2 * raw_noise + 1)) -
                                    raw_noise;
                                if (raw_value < 0) raw_value = 0;
                                if (raw_value > 1023) raw_value = 1023;
                            end
                            expected_frame_sum = expected_frame_sum +
                                                 meter_value(raw_value);
                            if ((raw_value >> 2) >= BRIGHT_LEVEL)
                                expected_frame_bright = expected_frame_bright + 1;
                            bucket=raw_value>>(10-HIST_BIN_BITS);
                            expected_histogram[bucket]=expected_histogram[bucket]+1;
                            // These are RAW10 image diagnostics. The meter's
                            // bright_count starts at 4*METER_CAP, not saturation.
                            if (raw_value >= 992)
                                expected_near_sat = expected_near_sat + 1;
                            if (raw_value == 1023)
                                expected_saturated = expected_saturated + 1;
                            if (permuted_index >= light_components) begin
                                expected_background_sum = expected_background_sum + raw_value;
                                expected_background_count = expected_background_count + 1;
                            end
                            component_index = component_index + 1;
                        end
                        pixel_index = row * WIDTH + group_index * 4 + lane;
                        frozen_raw[pixel_index] = raw_value;
                    end
                end
            end
            if (component_index != METERED_COMPONENTS)
                $fatal(1, "Scene generated the wrong metered component count");
            hist_cumulative=0;
            if (HISTOGRAM_ENABLE)
                for (hist_index=0; hist_index<(1<<HIST_BIN_BITS); hist_index=hist_index+1) begin
                    if (hist_cumulative<(95*METERED_COMPONENTS+99)/100 &&
                        hist_cumulative+expected_histogram[hist_index]>=(95*METERED_COMPONENTS+99)/100)
                        expected_p95=((hist_index+1)<<(5-HIST_BIN_BITS))-1;
                    hist_cumulative=hist_cumulative+expected_histogram[hist_index];
                end

            @(negedge src_clk);
            frame_start = 1;
            video_valid = 0;
            line_last = 0;
            source_tick();
            @(negedge src_clk);
            frame_start = 0;
            source_tick();
            for (row = 0; row < HEIGHT; row = row + 1) begin
                for (group_index = 0; group_index < GROUPS;
                     group_index = group_index + 1) begin
                    raw_pack = 0;
                    for (lane = 0; lane < 4; lane = lane + 1) begin
                        pixel_index = row * WIDTH + group_index * 4 + lane;
                        raw_pack[lane*10 +: 10] = frozen_raw[pixel_index];
                    end
                    @(negedge src_clk);
                    video_valid = 1;
                    line_last = group_index == GROUPS-1;
                    video_data = raw_pack;
                    source_tick();
                end
                @(negedge src_clk);
                video_valid = 0;
                line_last = 0;
                repeat (2) source_tick();
            end
            repeat (20) source_tick();
            total_frames = total_frames + 1;
            // A complete frame is frozen before it is streamed. A group write
            // may finish during that frame; the configured number of old
            // image frames must pass before new sensor settings are visible.
            if (sensor_pending) begin
                if (apply_frames_remaining <= 1) begin
                    active_exposure = pending_exposure;
                    active_gain_setting = pending_gain;
                    active_coarse = pending_coarse;
                    active_fine = pending_fine;
                    sensor_pending = 0;
                    apply_frames_remaining = 0;
                end else begin
                    apply_frames_remaining = apply_frames_remaining - 1;
                end
            end
        end
    endtask

    task automatic camera_frame(input integer illumination);
        begin
            camera_scene(illumination, 0, 0);
        end
    endtask

    task automatic reset_loop;
        integer commit_before;
        begin
            commit_before = commits;
            @(negedge src_clk);
            camera_done = 0;
            rst_n = 0;
            repeat (10) source_tick();
            @(negedge src_clk);
            rst_n = 1;
            repeat (6) @(posedge control_clk);
            @(negedge control_clk);
            camera_done = 1;
            repeat (100) @(posedge control_clk);
            if (commits != commit_before + 1 || exposure != 1000 || gain != 16)
                $fatal(1, "Safe default did not reach the sensor register group");
            // Includes up to three old image frames after the group release.
            repeat (3) camera_frame(108);
            if (sensor_pending || active_exposure != 1000 ||
                active_gain_setting != 16 || active_coarse != 0 ||
                active_fine != 128)
                $fatal(1, "Safe default was not applied after settling");
        end
    endtask

    task automatic report_scene(input string label_text,
                                input integer elapsed_frames,
                                input integer convergence_ok);
        begin
            $display("AE_SCENE_RESULT %s legacy=%0d cap=%0d apply_delay=%0d converged=%0d frames=%0d mean=%0d background_raw=%0d meter_high=%0d/%0d near_sat_ge992=%0d/%0d sat1023=%0d/%0d E=%0d G=%0d p95=%0d score=%0d highlight=%0d bins=%0d",
                     label_text, EXPECT_LEGACY, METER_CAP, SENSOR_APPLY_FRAMES,
                     convergence_ok, elapsed_frames,
                     last_frame_sum / METERED_COMPONENTS, last_background_raw,
                     last_frame_bright, METERED_COMPONENTS,
                     last_near_sat, METERED_COMPONENTS,
                     last_saturated, METERED_COMPONENTS, exposure, gain,
                     last_frame_p95,last_frame_score/METERED_COMPONENTS,
                     HIGHLIGHT_ENABLE,1<<HIST_BIN_BITS);
        end
    endtask

    integer last_converged;
    task automatic converge_scene(input integer illumination,
                                  input integer light_components,
                                  input integer offset,
                                  input integer expected_direction,
                                  input string label_text,
                                  input integer hold_frames = 30,
                                  input integer lamp_illumination = 1000);
        integer frame_index;
        integer consecutive;
        integer request_base;
        integer commit_seen;
        reg [63:0] previous_product;
        reg [63:0] current_product;
        begin
            frame_index = 0;
            consecutive = 0;
            last_converged = 0;
            commit_seen = commits;
            previous_product = sensor_product(active_exposure,
                                              active_coarse, active_fine);
            while (consecutive < 12 && frame_index < 320) begin
                camera_scene(illumination, light_components, offset, 0,
                             lamp_illumination);
                if (commits != commit_seen) begin
                    if (commits != commit_seen + 1)
                        $fatal(1, "%s committed more than once per frame", label_text);
                    commit_seen = commits;
                end
                current_product = sensor_product(active_exposure,
                                                 active_coarse, active_fine);
                if (current_product != previous_product) begin
                    if (!EXPECT_LEGACY &&
                        ((expected_direction > 0 && current_product <= previous_product) ||
                         (expected_direction < 0 && current_product >= previous_product)))
                        $fatal(1,
                            "%s reversed direction product=%0d previous=%0d E=%0d G=%0d",
                            label_text, current_product, previous_product,
                            active_exposure, active_gain_setting);
                    previous_product = current_product;
                end
                if (last_frame_score >= METERED_COMPONENTS * TARGET_LOW &&
                    last_frame_score <= METERED_COMPONENTS * TARGET_HIGH &&
                    !model_busy && active_exposure == exposure &&
                    active_gain_setting == gain)
                    consecutive = consecutive + 1;
                else
                    consecutive = 0;
                frame_index = frame_index + 1;
            end
            if (consecutive < 12) begin
                convergence_failures = convergence_failures + 1;
                report_scene(label_text, frame_index, 0);
                if (!EXPECT_LEGACY)
                    $fatal(1,
                        "%s failed to converge sum=%0d mean=%0d bright=%0d E=%0d G=%0d",
                        label_text, last_frame_sum,
                        last_frame_sum / METERED_COMPONENTS,
                        last_frame_bright, exposure, gain);
            end else begin
                last_converged = 1;
                request_base = requests;
                repeat (hold_frames) begin
                    camera_scene(illumination, light_components, offset, 0,
                                 lamp_illumination);
                    if (last_frame_score < METERED_COMPONENTS * TARGET_LOW ||
                        last_frame_score > METERED_COMPONENTS * TARGET_HIGH)
                        $fatal(1, "%s left the target interval", label_text);
                    if (last_frame_sum < METERED_COMPONENTS*(TARGET_LOW-(HIGHLIGHT_ENABLE ? 16 : 0)))
                        $fatal(1,"%s violated the bounded global brightness floor",label_text);
                end
                if (requests != request_base)
                    $fatal(1, "%s kept writing after stable convergence", label_text);
                $display("AE_SCENE_CONVERGED %s frames=%0d mean=%0d bright=%0d/%0d E=%0d G=%0d",
                         label_text, frame_index,
                         last_frame_sum / METERED_COMPONENTS,
                         last_frame_bright, METERED_COMPONENTS, exposure, gain);
                report_scene(label_text, frame_index, 1);
            end
        end
    endtask

    integer frame_index;
    integer fraction_index;
    integer lamp_count;
    integer request_base;
    integer commit_base;
    integer before_stats;
    initial begin
        if (SENSOR_APPLY_FRAMES < 0 || SENSOR_APPLY_FRAMES > 3)
            $fatal(1, "This test covers sensor image delays of zero to three frames");
        reset_loop();

        // This six-frame modulation sequence averages to 108; it is not a
        // model of sensor exposure synchronized to physical 50 Hz lighting.
        request_base = requests;
        repeat (5) begin
            for (frame_index = 0; frame_index < 6; frame_index = frame_index + 1)
                camera_frame((frame_index & 1) ? 136 : 80);
        end
        if (requests != request_base || exposure != 1000 || gain != 16)
            $fatal(1, "Six-frame mains flicker caused an exposure write");

        // Reproduce the former lock: 25 percent lamps, then a fixed 20 percent.
        // Both traces run the same scene. Legacy mode records the defect;
        // current RTL must brighten the dark background and settle instead.
        request_base = requests;
        repeat (6) camera_scene(16, 40, 0);
        if (requests != request_base + 1 || gain != 16 ||
            last_frame_bright != (BRIGHT_LEVEL==248 ? last_near_sat : 40) ||
            (EXPECT_LEGACY && exposure != 875) ||
            (!EXPECT_LEGACY && exposure <= 1000))
            $fatal(1, "Wrong response to a dark mean with 25 percent lamps");
        converge_scene(16, 32, 23, 1, "twenty percent lamps after highlight trigger", 300);
        if (!EXPECT_LEGACY && !HIGHLIGHT_ENABLE && last_background_raw < 280)
            $fatal(1, "Fixed 20 percent lamps still prevented useful background exposure");

        // Bright daylight, lit indoor night, then daylight again. Every
        // applied update within each fixed scene must move in one direction.
        reset_loop();
        converge_scene(220, 0, 0, -1, "daylight");
        if (last_converged && (gain != 16 || exposure >= 1000))
            $fatal(1, "Daylight did not remove gain and shorten exposure");
        converge_scene(16, 0, 0, 1, "lit indoor night");
        if (last_converged && (exposure != 1991 || gain <= 16))
            $fatal(1, "Night scene did not use exposure before sensor gain");
        converge_scene(220, 0, 0, -1, "daylight recovery");
        if (last_converged && gain != 16)
            $fatal(1, "Daylight recovery retained unnecessary sensor gain");

        // A moderate-contrast scene distinguishes metering compression from
        // actual highlight preservation. At the defaults, lamps are RAW920
        // and the background RAW280: cap192 already gives mean100.5, whereas
        // cap160 gives mean92.5 and can drive still-recoverable lamps to 1023.
        reset_loop();
        converge_scene(70, 40, 0, 0, "recoverable lamp highlights", 300, 230);
        if (!EXPECT_LEGACY && METER_CAP == 192 &&
            (last_near_sat != 0 || exposure != 1000 || gain != 16))
            $fatal(1, "Recoverable highlight scene needlessly increased exposure");

        // Fixed fractions cover both old hysteresis thresholds and scenes
        // dominated by lamps. A global mean cannot promise a bright background
        // in majority-light scenes; record that tradeoff instead of hiding it.
        for (fraction_index = 0; fraction_index < 6;
             fraction_index = fraction_index + 1) begin
            case (fraction_index)
                0: lamp_count = 16;  // 10 percent
                1: lamp_count = 20;  // 12.5 percent
                2: lamp_count = 32;  // 20 percent
                3: lamp_count = 40;  // 25 percent
                4: lamp_count = 80;  // 50 percent
                5: lamp_count = 120; // 75 percent
            endcase
            reset_loop();
            converge_scene(16, lamp_count, 7, 0,
                           $sformatf("fixed lamps %0d of 160", lamp_count), 300);
            if (!EXPECT_LEGACY && !HIGHLIGHT_ENABLE && lamp_count <= 32 && last_background_raw < 280)
                $fatal(1, "Small lamp fractions prevented useful background exposure");
        end

        // Spatial motion preserves the exact metered population, including
        // at the former 25 percent veto boundary.
        reset_loop();
        converge_scene(16, 40, 0, 1, "moving lamps initial");
        request_base = requests;
        for (frame_index = 0; frame_index < 120; frame_index = frame_index + 1)
            camera_scene(16, 40, (frame_index * 23) % METERED_COMPONENTS);
        if (!EXPECT_LEGACY && requests != request_base)
            $fatal(1, "Moving a fixed lamp fraction changed stable exposure");
        report_scene("moving fixed lamp fraction", 120, last_converged);

        // Repeatedly straddle the former 12.5 and 25 percent thresholds.
        // Small population changes at a stable background must not restart a
        // persistent opposite-direction exposure cycle.
        reset_loop();
        converge_scene(16, 30, 0, 1, "threshold crossing initial");
        request_base = requests;
        for (frame_index = 0; frame_index < 180; frame_index = frame_index + 1) begin
            case (frame_index % 4)
                0: lamp_count = 19;
                1: lamp_count = 21;
                2: lamp_count = 39;
                3: lamp_count = 41;
            endcase
            camera_scene(16, lamp_count, (frame_index * 19) % METERED_COMPONENTS);
            // A bounded highlight target may need to re-centre when the
            // population changes. Require no persistent hunting after that
            // finite adaptation, not identical exposure under different data.
            if (HIGHLIGHT_ENABLE && frame_index==59) request_base=requests;
        end
        if (!EXPECT_LEGACY && requests != request_base)
            $fatal(1, "Old highlight-boundary crossings restarted exposure writes");
        report_scene("former highlight boundaries", 180, last_converged);

        // Cross the real analog-gain table boundaries, then recover to daylight.
        reset_loop();
        converge_scene(2, 0, 0, 1, "deep night gain boundaries");
        converge_scene(220, 0, 0, -1, "deep night daylight recovery");

        // Illumination below the hardware range must stop issuing redundant
        // writes at E_MAX/G_MAX. This also reaches the final 32x gain stage.
        reset_loop();
        frame_index = 0;
        while ((active_exposure != 1991 || active_gain_setting != GAIN_MAX ||
                model_busy || sensor_pending) && frame_index < 320) begin
            camera_frame(1);
            frame_index = frame_index + 1;
        end
        if (frame_index >= 320 || active_coarse != 8'h1f ||
            active_fine != 8'h80)
            $fatal(1, "Very dark scene did not reach the final gain table stage");
        request_base = requests;
        repeat (30) camera_frame(1);
        if (requests != request_base)
            $fatal(1, "Exposure saturation caused redundant sensor writes");
        report_scene("dark scene at hardware limit", frame_index, 0);

        // Very short exposures need a one-code minimum step. A four-code
        // minimum bounces between exposures 4 and 8 in this scene.
        reset_loop();
        converge_scene(20000, 0, 0, -1, "short exposure boundary");

        // Deterministic +/-8 RAW10-code sample noise is added before clipping.
        // Six-frame alternating illumination checks controller modulation
        // rejection, not physical 50/60-Hz banding or flicker removal.
        reset_loop();
        converge_scene(108, 0, 0, 0, "noise and flicker initial");
        request_base = requests;
        for (frame_index = 0; frame_index < 180; frame_index = frame_index + 1)
            camera_scene((frame_index & 1) ? 136 : 80, 0, 0, 8);
        if (requests != request_base)
            $fatal(1, "Noise and six-frame modulation caused stable-scene writes");
        report_scene("noise and alternating illumination", 180, 1);

        // No source clock means no new statistics and no control drift.
        @(negedge src_clk);
        src_run = 0;
        request_base = requests;
        commit_base = commits;
        before_stats = stats_read;
        repeat (600) @(posedge control_clk);
        if (requests != request_base || commits != commit_base ||
            stats_read != before_stats)
            $fatal(1, "Stopped video source caused AE drift");
        src_run = 1;
        repeat (20) source_tick();

        if (stats_written != stats_read)
            repeat (40) @(posedge control_clk);
        if (stats_written != stats_read)
            $fatal(1, "Final RAW frame was not delivered through CDC");
        if (EXPECT_LEGACY)
            $display("AE_LIGHTING_LEGACY_CHARACTERIZATION_PASS known_nonconverged=%0d cap=%0d apply_delay=%0d frames=%0d requests=%0d commits=%0d stable_checks=%0d samples=%0d target=%0d..%0d gain_max=%0d",
                     convergence_failures, METER_CAP, SENSOR_APPLY_FRAMES,
                     total_frames, requests, commits, stability_checks,
                     METERED_COMPONENTS, TARGET_LOW, TARGET_HIGH, GAIN_MAX);
        else
            $display("AE_LIGHTING_LOOP_PASS legacy=0 known_nonconverged=%0d cap=%0d apply_delay=%0d frames=%0d requests=%0d commits=%0d stable_checks=%0d samples=%0d target=%0d..%0d gain_max=%0d",
                     convergence_failures, METER_CAP, SENSOR_APPLY_FRAMES,
                     total_frames, requests, commits, stability_checks,
                     METERED_COMPONENTS, TARGET_LOW, TARGET_HIGH, GAIN_MAX);
        $finish;
    end

    initial begin
        #250000000;
        $fatal(1, "RAW lighting feedback integration test timed out");
    end
endmodule
