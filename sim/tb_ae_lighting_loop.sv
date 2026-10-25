`timescale 1ns/1ps

// End-to-end RAW statistics, CDC, six-frame AE and SC520 register-table model.
module tb_ae_lighting_loop #(
    parameter integer TARGET_LOW = 96,
    parameter integer TARGET_HIGH = 120,
    parameter integer GAIN_MAX = 176
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
    wire cdc_valid;
    wire [63:0] cdc_data;
    wire ae_request;
    wire [15:0] exposure, gain;
    reg ae_done = 0;

    ae_frame_stats_raw10_4x #(
        .IMG_WIDTH(WIDTH), .IMG_HEIGHT(HEIGHT)
    ) stats (
        .I_clk(src_clk), .I_rst_n(rst_n), .I_tuser(frame_start),
        .I_tlast(line_last), .I_tvalid(video_valid), .I_tdata(video_data),
        .O_stats_valid(stats_valid), .O_sum_y(frame_sum),
        .O_sample_count(frame_count), .O_bright_count(frame_bright)
    );

    ae_stats_cdc cdc (
        .I_src_clk(src_clk), .I_dst_clk(control_clk), .I_rst_n(rst_n),
        .I_src_valid(stats_valid),
        .I_src_data({frame_sum, frame_count, frame_bright}),
        .O_dst_valid(cdc_valid), .O_dst_data(cdc_data)
    );

    auto_exposure_control #(
        .TARGET_LOW(TARGET_LOW), .TARGET_HIGH(TARGET_HIGH),
        .DARK_FAST(64), .BRIGHT_FAST(144), .GAIN_MAX(GAIN_MAX),
        .SETTLE_FRAMES(3), .AVERAGE_FRAMES(6)
    ) control (
        .I_clk(control_clk), .I_rst(!rst_n), .I_cam_cfg_done(camera_done),
        .I_ae_cfg_done(ae_done), .I_stats_valid(cdc_valid),
        .I_sum_y(cdc_data[63:32]), .I_sample_count(cdc_data[31:16]),
        .I_bright_count(cdc_data[15:0]), .O_ae_req(ae_request),
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
    integer requests = 0, commits = 0, stability_checks = 0;

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
                        active_exposure <= {
                            staged_exposure_high, staged_exposure_mid,
                            staged_exposure_low};
                        active_gain_setting <= held_gain;
                        active_coarse <= staged_coarse;
                        active_fine <= staged_fine;
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
            meter_value = value_8 >= 192 ? 192 : value_8;
        end
    endfunction

    reg [63:0] expected_payload [0:4095];
    integer stats_written = 0, stats_read = 0;
    integer total_frames = 0;
    integer expected_frame_sum = 0, expected_frame_bright = 0;
    integer last_frame_sum = 0, last_frame_bright = 0;
    reg [9:0] frozen_raw [0:WIDTH*HEIGHT-1];

    always @(posedge src_clk) begin
        #1;
        if (rst_n && stats_valid) begin
            if (frame_count != METERED_COMPONENTS ||
                frame_sum != expected_frame_sum ||
                frame_bright != expected_frame_bright)
                $fatal(1,
                    "RAW metering mismatch sum=%0d/%0d count=%0d bright=%0d/%0d",
                    frame_sum, expected_frame_sum, frame_count,
                    frame_bright, expected_frame_bright);
            if (stats_written >= 4096)
                $fatal(1, "Statistics reference queue overflow");
            expected_payload[stats_written] = {frame_sum, frame_count, frame_bright};
            stats_written = stats_written + 1;
            last_frame_sum = frame_sum;
            last_frame_bright = frame_bright;
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
                                input integer offset = 0);
        integer row;
        integer group_index;
        integer lane;
        integer pixel_index;
        integer component_index;
        integer permuted_index;
        integer raw_value;
        reg [39:0] raw_pack;
        begin
            component_index = 0;
            expected_frame_sum = 0;
            expected_frame_bright = 0;
            for (row = 0; row < HEIGHT; row = row + 1) begin
                for (group_index = 0; group_index < GROUPS;
                     group_index = group_index + 1) begin
                    for (lane = 0; lane < 4; lane = lane + 1) begin
                        raw_value = modeled_raw(background_illumination);
                        if ((row % 8) < 2 && (group_index % 8) == 0) begin
                            permuted_index = (37 * component_index + offset) %
                                             METERED_COMPONENTS;
                            if (permuted_index < light_components)
                                raw_value = modeled_raw(1000);
                            expected_frame_sum = expected_frame_sum +
                                                 meter_value(raw_value);
                            if ((raw_value >> 2) >= 192)
                                expected_frame_bright = expected_frame_bright + 1;
                            component_index = component_index + 1;
                        end
                        pixel_index = row * WIDTH + group_index * 4 + lane;
                        frozen_raw[pixel_index] = raw_value;
                    end
                end
            end
            if (component_index != METERED_COMPONENTS)
                $fatal(1, "Scene generated the wrong metered component count");

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
        end
    endtask

    task automatic camera_frame(input integer illumination);
        begin
            camera_scene(illumination, 0, 0);
        end
    endtask

    task automatic wait_for_applied_parameters;
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while ((model_busy || active_exposure != exposure ||
                    active_gain_setting != gain) && wait_cycles < 500) begin
                @(posedge control_clk);
                wait_cycles = wait_cycles + 1;
            end
            if (wait_cycles == 500)
                $fatal(1, "Timed out waiting for applied sensor parameters");
        end
    endtask

    task automatic converge_scene(input integer illumination,
                                  input integer light_components,
                                  input integer offset,
                                  input integer expected_direction,
                                  input string label_text);
        integer frame_index;
        integer consecutive;
        integer request_base;
        integer commit_seen;
        reg [63:0] previous_product;
        reg [63:0] current_product;
        begin
            frame_index = 0;
            consecutive = 0;
            commit_seen = commits;
            previous_product = sensor_product(active_exposure,
                                              active_coarse, active_fine);
            while (consecutive < 12 && frame_index < 320) begin
                camera_scene(illumination, light_components, offset);
                if (commits != commit_seen) begin
                    if (commits != commit_seen + 1)
                        $fatal(1, "%s committed more than once per frame", label_text);
                    current_product = sensor_product(active_exposure,
                                                     active_coarse, active_fine);
                    if ((expected_direction > 0 && current_product <= previous_product) ||
                        (expected_direction < 0 && current_product >= previous_product))
                        $fatal(1,
                            "%s reversed direction product=%0d previous=%0d E=%0d G=%0d",
                            label_text, current_product, previous_product,
                            active_exposure, active_gain_setting);
                    previous_product = current_product;
                    commit_seen = commits;
                end
                if (last_frame_sum >= METERED_COMPONENTS * TARGET_LOW &&
                    last_frame_sum <= METERED_COMPONENTS * TARGET_HIGH &&
                    !model_busy && active_exposure == exposure &&
                    active_gain_setting == gain)
                    consecutive = consecutive + 1;
                else
                    consecutive = 0;
                frame_index = frame_index + 1;
            end
            if (consecutive < 12)
                $fatal(1,
                    "%s failed to converge sum=%0d mean=%0d bright=%0d E=%0d G=%0d",
                    label_text, last_frame_sum,
                    last_frame_sum / METERED_COMPONENTS,
                    last_frame_bright, exposure, gain);
            request_base = requests;
            repeat (30) begin
                camera_scene(illumination, light_components, offset);
                if (last_frame_sum < METERED_COMPONENTS * TARGET_LOW ||
                    last_frame_sum > METERED_COMPONENTS * TARGET_HIGH)
                    $fatal(1, "%s left the target interval", label_text);
            end
            if (requests != request_base)
                $fatal(1, "%s kept writing after stable convergence", label_text);
            $display("AE_SCENE_CONVERGED %s frames=%0d mean=%0d bright=%0d/%0d E=%0d G=%0d",
                     label_text, frame_index,
                     last_frame_sum / METERED_COMPONENTS,
                     last_frame_bright, METERED_COMPONENTS, exposure, gain);
        end
    endtask

    integer frame_index;
    integer request_base;
    integer commit_base;
    integer before_stats;
    initial begin
        repeat (10) source_tick();
        @(negedge src_clk);
        rst_n = 1;
        repeat (6) @(posedge control_clk);
        @(negedge control_clk);
        camera_done = 1;
        repeat (100) @(posedge control_clk);
        if (commits != 1 || active_exposure != 1000 ||
            active_gain_setting != 16 || active_coarse != 0 || active_fine != 128)
            $fatal(1, "Safe default did not reach the sensor register group");

        // Consume the three post-startup settling frames.
        repeat (3) camera_frame(108);

        // A six-frame 50 Hz sequence averages to 108 and must not ping-pong.
        request_base = requests;
        repeat (5) begin
            for (frame_index = 0; frame_index < 6; frame_index = frame_index + 1)
                camera_frame((frame_index & 1) ? 136 : 80);
        end
        if (requests != request_base || exposure != 1000 || gain != 16)
            $fatal(1, "Six-frame mains flicker caused an exposure write");

        // Exactly 25 percent clipped components must force a slow reduction.
        // The 12.5..25 percent band then holds until the highlight fraction
        // drops below the clear threshold.
        request_base = requests;
        repeat (6) camera_scene(16, 40, 0);
        if (requests != request_base + 1 || exposure != 875 || gain != 16 ||
            last_frame_bright != 40)
            $fatal(1, "Exact 25 percent highlight boundary did not reduce");
        wait_for_applied_parameters();
        repeat (3) camera_scene(16, 32, 23);
        request_base = requests;
        repeat (6) camera_scene(16, 32, 23);
        if (requests != request_base || exposure != 875 || gain != 16 ||
            last_frame_bright != 32)
            $fatal(1, "Highlight hysteresis band did not hold exposure");
        repeat (6) camera_scene(16, 16, 47);
        if (requests != request_base + 1 || exposure != 1093 || gain != 16 ||
            last_frame_bright != 16)
            $fatal(1, "Low highlight fraction did not clear and brighten");
        wait_for_applied_parameters();

        // Bright daylight, lit indoor night, then daylight again. Every
        // applied update within each fixed scene must move in one direction.
        converge_scene(220, 0, 0, -1, "daylight");
        if (gain != 16 || exposure >= 1000)
            $fatal(1, "Daylight did not remove gain and shorten exposure");
        converge_scene(16, 0, 0, 1, "lit indoor night");
        if (exposure != 1991 || gain <= 16)
            $fatal(1, "Night scene did not use exposure before sensor gain");
        converge_scene(220, 0, 0, -1, "daylight recovery");
        if (gain != 16)
            $fatal(1, "Daylight recovery retained unnecessary sensor gain");

        // A 10 percent lamp field still permits the dark surroundings to rise.
        converge_scene(16, 16, 7, 1, "night with ten percent lamps");
        if (last_frame_bright != 16 || meter_value(modeled_raw(16)) < 70)
            $fatal(1, "Small lamps prevented useful night background exposure");
        request_base = requests;
        repeat (12) camera_scene(16, 16, 91);
        if (requests != request_base || last_frame_bright != 16)
            $fatal(1, "Moving the same lamp fraction changed stable exposure");

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
        $display("AE_LIGHTING_LOOP_PASS frames=%0d requests=%0d commits=%0d stable_checks=%0d samples=%0d target=%0d..%0d gain_max=%0d",
                 total_frames, requests, commits, stability_checks,
                 METERED_COMPONENTS, TARGET_LOW, TARGET_HIGH, GAIN_MAX);
        $finish;
    end

    initial begin
        #120000000;
        $fatal(1, "RAW lighting feedback integration test timed out");
    end
endmodule
