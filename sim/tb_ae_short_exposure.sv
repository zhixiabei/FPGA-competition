`timescale 1ns/1ps

// Closed-loop tests use a fixed, linear sensor response followed by RAW10
// quantization and the production RAW8 cap. They do not predict a DUT step.
module ae_fixed_light_case #(
    parameter integer CASE_ID = 0,
    parameter integer TARGET_EXPOSURE = 4,
    parameter integer TARGET_GAIN = 16,
    parameter integer START_EXPOSURE = 32,
    parameter integer START_GAIN = 16,
    parameter integer GAIN_CASE = 0
) (
    output reg O_done = 0
);
    localparam integer SAMPLE_COUNT = 256;
    localparam integer HOLD_FRAMES = 300;
    reg clk = 0;
    always #21 clk = ~clk;
    reg rst = 1;
    reg camera_done = 0;
    reg ae_done = 0;
    reg stats_valid = 0;
    reg [31:0] sum_y = 0;
    reg [15:0] bright_count = 0;
    wire request;
    wire [15:0] exposure, gain;
    wire [23:0] gain_registers;
    reg busy = 0;
    integer bus_cycles = 0;
    integer held_exposure = START_EXPOSURE;
    integer held_gain = START_GAIN;
    integer active_exposure = START_EXPOSURE;
    integer active_gain = START_GAIN;
    reg [23:0] active_gain_registers = 0;
    integer requests = 0;
    integer commits = 0;
    integer reversals = 0;
    integer last_direction = 0;
    reg [63:0] previous_product = 0;
    reg [63:0] committed_product;

    auto_exposure_control #(
        .EXPOSURE_DEFAULT(START_EXPOSURE), .GAIN_DEFAULT(START_GAIN)
    ) dut (
        .I_clk(clk), .I_rst(rst), .I_cam_cfg_done(camera_done),
        .I_ae_cfg_done(ae_done), .I_stats_valid(stats_valid),
        .I_sum_y(sum_y), .I_sample_count(16'd256),
        .I_bright_count(bright_count), .O_ae_req(request),
        .O_ae(exposure), .O_ag(gain)
    );

    SC520GainTbl register_mapping (
        .I_AG(gain), .O(gain_registers)
    );

    // Independent hardware model: decode actual register coarse codes.
    function automatic integer physical_gain(input [23:0] registers);
        integer analog;
        begin
            case (registers[23:16])
                8'h00: analog = 1;
                8'h08: analog = 2;
                8'h09: analog = 4;
                8'h0b: analog = 8;
                8'h0f: analog = 16;
                8'h1f: analog = 32;
                default: $fatal(1, "case %0d illegal gain register %h",
                                CASE_ID, registers);
            endcase
            if (registers[15:8] != 0 ||
                registers[7:0] < 128)
                $fatal(1, "case %0d illegal digital gain %h",
                       CASE_ID, registers);
            physical_gain = analog * registers[7:0];
        end
    endfunction

    // Required gain for the fixed illuminant, expressed in units of 1/128.
    function automatic integer nominal_gain(input integer control);
        integer index;
        begin
            if (control <= 16)
                nominal_gain = 128;
            else if (control >= 176)
                nominal_gain = 4096;
            else begin
                index = control - 16;
                nominal_gain = (1 << (index / 32)) *
                               (128 + 4 * (index % 32));
            end
        end
    endfunction

    function automatic integer sensor_meter;
        reg [63:0] raw_value;
        reg [63:0] denominator;
        begin
            // Exactly RAW10=432 (RAW8=108) is reachable at the target.
            raw_value = active_exposure;
            raw_value = raw_value * physical_gain(active_gain_registers);
            raw_value = raw_value * 432;
            denominator = TARGET_EXPOSURE * nominal_gain(TARGET_GAIN);
            raw_value = raw_value / denominator;
            if (raw_value > 1023)
                raw_value = 1023;
            sensor_meter = raw_value >> 2;
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            ae_done <= 0;
            busy <= 0;
            bus_cycles <= 0;
        end else begin
            if (!busy) begin
                if (camera_done)
                    ae_done <= 1;
                if (request) begin
                    if (!ae_done)
                        $fatal(1, "case %0d request without bus done", CASE_ID);
                    held_exposure <= exposure;
                    held_gain <= gain;
                    active_gain_registers <= gain_registers;
                    ae_done <= 0;
                    busy <= 1;
                    bus_cycles <= 6;
                    requests = requests + 1;
                end
            end else begin
                if (request || exposure != held_exposure || gain != held_gain)
                    $fatal(1, "case %0d request values changed during busy", CASE_ID);
                if (bus_cycles == 1) begin
                    active_exposure <= held_exposure;
                    active_gain <= held_gain;
                    committed_product = held_exposure;
                    committed_product = committed_product *
                                        physical_gain(active_gain_registers);
                    if (commits != 0) begin
                        if (committed_product > previous_product) begin
                            if (last_direction < 0)
                                reversals = reversals + 1;
                            last_direction = 1;
                        end else if (committed_product < previous_product) begin
                            if (last_direction > 0)
                                reversals = reversals + 1;
                            last_direction = -1;
                        end else begin
                            $fatal(1, "case %0d redundant parameter request", CASE_ID);
                        end
                    end
                    previous_product = committed_product;
                    commits = commits + 1;
                    busy <= 0;
                    ae_done <= 1;
                end else begin
                    bus_cycles <= bus_cycles - 1;
                end
            end
        end
    end

    task automatic tick;
        begin
            @(posedge clk);
            #2;
        end
    endtask

    task automatic send_frame(output integer frame_mean);
        integer uncapped;
        begin
            @(negedge clk);
            uncapped = sensor_meter();
            frame_mean = uncapped > 192 ? 192 : uncapped;
            sum_y = frame_mean * SAMPLE_COUNT;
            bright_count = uncapped >= 192 ? SAMPLE_COUNT : 0;
            stats_valid = 1;
            tick();
            @(negedge clk);
            stats_valid = 0;
            repeat (12) tick();
            if (exposure < 4 || exposure > 1991 ||
                gain < 16 || gain > 176)
                $fatal(1, "case %0d sensor limits violated", CASE_ID);
            if (GAIN_CASE && exposure != 1991)
                $fatal(1, "case %0d changed exposure before finding a gain solution",
                       CASE_ID);
            if (!GAIN_CASE && gain != 16)
                $fatal(1, "case %0d changed gain in a short-exposure scene", CASE_ID);
        end
    endtask

    integer frames = 0;
    integer stable_frames = 0;
    integer measured_mean = 0;
    integer request_base;
    integer hold_index;
    initial begin
        repeat (4) tick();
        @(negedge clk);
        rst = 0;
        camera_done = 1;
        repeat (20) tick();
        if (commits != 1)
            $fatal(1, "case %0d did not commit the initial register group", CASE_ID);
        if (physical_gain(active_gain_registers) != nominal_gain(START_GAIN))
            $fatal(1, "case %0d gain mapping disagrees with physical model", CASE_ID);

        while (stable_frames < 12 && frames < 320) begin
            send_frame(measured_mean);
            if (measured_mean >= 96 && measured_mean <= 120 &&
                !busy && active_exposure == exposure && active_gain == gain)
                stable_frames = stable_frames + 1;
            else
                stable_frames = 0;
            frames = frames + 1;
        end
        if (stable_frames != 12)
            $fatal(1,
                "case %0d fixed light failed to settle target=E%0d/G%0d got E%0d/G%0d mean=%0d reversals=%0d",
                CASE_ID, TARGET_EXPOSURE, TARGET_GAIN,
                exposure, gain, measured_mean, reversals);
        if (reversals > 2)
            $fatal(1, "case %0d repeatedly reversed before settling (%0d)",
                   CASE_ID, reversals);

        request_base = requests;
        for (hold_index = 0; hold_index < HOLD_FRAMES; hold_index = hold_index + 1) begin
            send_frame(measured_mean);
            if (measured_mean < 96 || measured_mean > 120 ||
                requests != request_base)
                $fatal(1,
                    "case %0d sustained oscillation after convergence E%0d/G%0d mean=%0d",
                    CASE_ID, exposure, gain, measured_mean);
        end
        $display("AE_FIXED_LIGHT_CASE_PASS id=%0d target_E=%0d target_G=%0d start_E=%0d start_G=%0d frames=%0d mean=%0d E=%0d G=%0d reversals=%0d hold=%0d",
                 CASE_ID, TARGET_EXPOSURE, TARGET_GAIN,
                 START_EXPOSURE, START_GAIN, frames,
                 measured_mean, exposure, gain, reversals, HOLD_FRAMES);
        O_done = 1;
    end
endmodule

module tb_ae_short_exposure;
    wire [57:0] short_done;
    wire [31:0] gain_done;
    function automatic integer boundary_gain(input integer index);
        begin
            case (index)
                0: boundary_gain = 16;
                1: boundary_gain = 20;
                2: boundary_gain = 44;
                3: boundary_gain = 48;
                4: boundary_gain = 52;
                5: boundary_gain = 76;
                6: boundary_gain = 80;
                7: boundary_gain = 84;
                8: boundary_gain = 108;
                9: boundary_gain = 112;
                10: boundary_gain = 116;
                11: boundary_gain = 140;
                12: boundary_gain = 144;
                13: boundary_gain = 148;
                14: boundary_gain = 172;
                default: boundary_gain = 176;
            endcase
        end
    endfunction

    genvar exposure_index;
    generate
        for (exposure_index = 0; exposure_index < 29;
             exposure_index = exposure_index + 1) begin : short_cases
            ae_fixed_light_case #(
                .CASE_ID(exposure_index * 2),
                .TARGET_EXPOSURE(exposure_index + 4), .START_EXPOSURE(4)
            ) from_low(.O_done(short_done[exposure_index * 2]));
            ae_fixed_light_case #(
                .CASE_ID(exposure_index * 2 + 1),
                .TARGET_EXPOSURE(exposure_index + 4), .START_EXPOSURE(32)
            ) from_high(.O_done(short_done[exposure_index * 2 + 1]));
        end
    endgenerate

    genvar gain_index;
    generate
        for (gain_index = 0; gain_index < 16;
             gain_index = gain_index + 1) begin : gain_cases
            ae_fixed_light_case #(
                .CASE_ID(58 + gain_index * 2),
                .TARGET_EXPOSURE(1991), .TARGET_GAIN(boundary_gain(gain_index)),
                .START_EXPOSURE(1991), .START_GAIN(16), .GAIN_CASE(1)
            ) from_low(.O_done(gain_done[gain_index * 2]));
            ae_fixed_light_case #(
                .CASE_ID(59 + gain_index * 2),
                .TARGET_EXPOSURE(1991), .TARGET_GAIN(boundary_gain(gain_index)),
                .START_EXPOSURE(1991), .START_GAIN(176), .GAIN_CASE(1)
            ) from_high(.O_done(gain_done[gain_index * 2 + 1]));
        end
    endgenerate

    initial begin
        wait ((&short_done) && (&gain_done));
        $display("AE_SHORT_EXPOSURE_PASS short_cases=58 gain_boundary_cases=32 reachable_E=4..32 stable_hold_frames=300");
        $finish;
    end
    initial begin
        #40000000;
        $fatal(1, "Short exposure closed-loop test timed out");
    end
endmodule
