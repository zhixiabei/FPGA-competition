`timescale 1ns/1ps

// This probe isolates the combinational parameter decision. Fixed-light
// convergence, state, timing and I2C handshake are tested by separate benches.
module ae_arithmetic_case #(
    parameter integer CASE_ID = 0,
    parameter integer EXPOSURE_MIN = 4,
    parameter integer EXPOSURE_MAX = 1991,
    parameter integer GAIN_MIN = 16,
    parameter integer GAIN_MAX = 176,
    parameter integer EXHAUSTIVE = 0
) (
    output reg O_done = 0
);
    reg [15:0] probe_exposure = EXPOSURE_MIN;
    reg [15:0] probe_gain = GAIN_MIN;
    reg [31:0] probe_sum = 0;
    wire request;
    wire [15:0] exposure, gain;
    integer probes = 0;

    auto_exposure_control #(
        .EXPOSURE_MIN(EXPOSURE_MIN), .EXPOSURE_MAX(EXPOSURE_MAX),
        .EXPOSURE_DEFAULT(EXPOSURE_MIN),
        .GAIN_MIN(GAIN_MIN), .GAIN_MAX(GAIN_MAX), .GAIN_DEFAULT(GAIN_MIN)
    ) dut (
        .I_clk(1'b0), .I_rst(1'b0),
        .I_cam_cfg_done(1'b1), .I_ae_cfg_done(1'b1),
        .I_stats_valid(1'b1), .I_sum_y(probe_sum),
        .I_sample_count(16'd256), .I_bright_count(16'd0),
        .O_ae_req(request), .O_ae(exposure), .O_ag(gain)
    );

    function automatic integer test_mean(input integer index);
        begin
            case (index)
                0: test_mean = 0;
                1: test_mean = 80;
                2: test_mean = 108;
                3: test_mean = 132;
                4: test_mean = 160;
                5: test_mean = 63;
                6: test_mean = 64;
                7: test_mean = 95;
                8: test_mean = 96;
                9: test_mean = 120;
                10: test_mean = 121;
                11: test_mean = 144;
                default: test_mean = 145;
            endcase
        end
    endfunction

    // Include both unsigned endpoints, gain step borrow/carry boundaries,
    // small exposures and the high bit of the full 16-bit control interface.
    function automatic integer control_point(input integer index,
                                              input integer minimum,
                                              input integer maximum);
        integer value;
        begin
            case (index)
                0: value = minimum;
                1: value = minimum + 1;
                2: value = minimum + 2;
                3: value = minimum + 3;
                4: value = minimum + 4;
                5: value = minimum + 15;
                6: value = minimum + 16;
                7: value = minimum + 17;
                8: value = 7;
                9: value = 8;
                10: value = 15;
                11: value = 16;
                12: value = 17;
                13: value = 31;
                14: value = 32;
                15: value = 32767;
                16: value = 32768;
                17: value = maximum / 2;
                18: value = maximum - 17;
                19: value = maximum - 16;
                20: value = maximum - 15;
                21: value = maximum - 4;
                22: value = maximum - 3;
                23: value = maximum - 2;
                24: value = maximum - 1;
                default: value = maximum;
            endcase
            if (value < minimum)
                value = minimum;
            if (value > maximum)
                value = maximum;
            control_point = value;
        end
    endfunction

    task automatic probe(input integer exposure_code,
                         input integer gain_code,
                         input integer mean);
        integer expected_exposure;
        integer expected_gain;
        integer step;
        begin
            expected_exposure = exposure_code;
            expected_gain = gain_code;
            // Integer specification, with explicit ordered branch/clamps.
            // No shared adder, bit masks, narrowed widths or DUT flags appear.
            if (mean < 96) begin
                if (exposure_code < EXPOSURE_MAX) begin
                    step = exposure_code / ((mean < 64) ? 2 : 8);
                    if (step < 1)
                        step = 1;
                    expected_exposure = exposure_code + step;
                    if (expected_exposure > EXPOSURE_MAX)
                        expected_exposure = EXPOSURE_MAX;
                end else if (gain_code < GAIN_MAX) begin
                    expected_gain = gain_code + ((mean < 64) ? 16 : 4);
                    if (expected_gain > GAIN_MAX)
                        expected_gain = GAIN_MAX;
                end
            end else if (mean > 120) begin
                if (gain_code > GAIN_MIN) begin
                    expected_gain = gain_code - ((mean > 144) ? 16 : 4);
                    if (expected_gain < GAIN_MIN)
                        expected_gain = GAIN_MIN;
                end else if (exposure_code > EXPOSURE_MIN) begin
                    step = exposure_code / ((mean > 144) ? 4 : 8);
                    if (step < 1)
                        step = 1;
                    expected_exposure = exposure_code - step;
                    if (expected_exposure < EXPOSURE_MIN)
                        expected_exposure = EXPOSURE_MIN;
                end
            end

            probe_exposure = exposure_code;
            probe_gain = gain_code;
            probe_sum = mean * 256;
            #1;
            probes = probes + 1;
            if (dut.next_exposure !== expected_exposure[15:0] ||
                dut.next_gain !== expected_gain[15:0])
                $fatal(1,
                    "Arithmetic case=%0d E=%0d G=%0d mean=%0d expected E%0d/G%0d got E%0d/G%0d ranges E%0d..%0d G%0d..%0d",
                    CASE_ID, exposure_code, gain_code, mean,
                    expected_exposure, expected_gain,
                    dut.next_exposure, dut.next_gain,
                    EXPOSURE_MIN, EXPOSURE_MAX, GAIN_MIN, GAIN_MAX);
        end
    endtask

    integer e;
    integer g;
    integer e_index;
    integer g_index;
    integer mean_index;
    initial begin
        force dut.O_ae = probe_exposure;
        force dut.O_ag = probe_gain;
        force dut.sum_accum = 0;
        force dut.count_accum = 0;
        #1;
        if (EXHAUSTIVE) begin
            for (e = EXPOSURE_MIN; e <= EXPOSURE_MAX; e = e + 1)
                for (g = GAIN_MIN; g <= GAIN_MAX; g = g + 1)
                    for (mean_index = 0; mean_index < 5;
                         mean_index = mean_index + 1)
                        probe(e, g, test_mean(mean_index));
        end else begin
            for (e_index = 0; e_index < 26; e_index = e_index + 1)
                for (g_index = 0; g_index < 26; g_index = g_index + 1)
                    for (mean_index = 0; mean_index < 13;
                         mean_index = mean_index + 1)
                        probe(control_point(e_index, EXPOSURE_MIN, EXPOSURE_MAX),
                              control_point(g_index, GAIN_MIN, GAIN_MAX),
                              test_mean(mean_index));
        end
        $display("AE_ARITHMETIC_CASE_PASS id=%0d exhaustive=%0d probes=%0d E=%0d..%0d G=%0d..%0d",
                 CASE_ID, EXHAUSTIVE, probes,
                 EXPOSURE_MIN, EXPOSURE_MAX, GAIN_MIN, GAIN_MAX);
        O_done = 1;
    end
endmodule

module tb_ae_control_arithmetic;
    wire [8:0] done;
    ae_arithmetic_case #(.CASE_ID(0), .EXHAUSTIVE(1))
        production(.O_done(done[0]));
    ae_arithmetic_case #(
        .CASE_ID(1), .EXPOSURE_MIN(0), .EXPOSURE_MAX(65535),
        .GAIN_MIN(0), .GAIN_MAX(65535)
    ) full_unsigned(.O_done(done[1]));
    ae_arithmetic_case #(
        .CASE_ID(2), .EXPOSURE_MIN(65535), .EXPOSURE_MAX(65535),
        .GAIN_MIN(65535), .GAIN_MAX(65535)
    ) fixed_maximum(.O_done(done[2]));
    ae_arithmetic_case #(
        .CASE_ID(3), .EXPOSURE_MIN(0), .EXPOSURE_MAX(0),
        .GAIN_MIN(0), .GAIN_MAX(0)
    ) fixed_zero(.O_done(done[3]));
    ae_arithmetic_case #(
        .CASE_ID(4), .EXPOSURE_MIN(0), .EXPOSURE_MAX(7),
        .GAIN_MIN(0), .GAIN_MAX(3)
    ) tiny_unsigned(.O_done(done[4]));
    ae_arithmetic_case #(
        .CASE_ID(5), .EXPOSURE_MIN(4), .EXPOSURE_MAX(15),
        .GAIN_MIN(1), .GAIN_MAX(15)
    ) below_gain_step(.O_done(done[5]));
    ae_arithmetic_case #(
        .CASE_ID(6), .EXPOSURE_MIN(7), .EXPOSURE_MAX(7),
        .GAIN_MIN(11), .GAIN_MAX(11)
    ) fixed_small(.O_done(done[6]));
    ae_arithmetic_case #(
        .CASE_ID(7), .EXPOSURE_MIN(4), .EXPOSURE_MAX(65535)
    ) wide_exposure(.O_done(done[7]));
    ae_arithmetic_case #(
        .CASE_ID(8), .GAIN_MIN(16), .GAIN_MAX(65535)
    ) wide_gain(.O_done(done[8]));

    initial begin
        wait (&done);
        $display("AE_CONTROL_ARITHMETIC_PASS exhaustive_production=1600340 generic_boundary_cases=8 generic_probes=70304 total=1670644");
        $finish;
    end
    initial begin
        #5000000;
        $fatal(1, "AE control arithmetic probe timed out");
    end
endmodule
