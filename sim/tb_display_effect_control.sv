`timescale 1ns/1ps
module tb_display_effect_control;
    reg clk = 0;
    always #10 clk = ~clk;
    reg rst_n = 0;
    reg prev_key_n = 1;
    reg effect_key_n = 1;
    reg param_key_n = 1;
    wire [3:0] effect_mode;
    wire [7:0] effect_param;
    reg fast_prev_key_n = 1;
    reg fast_effect_key_n = 1;
    reg fast_param_key_n = 1;
    wire [3:0] fast_mode;
    wire [7:0] fast_param;
    reg default_prev_key_n = 1;
    reg default_effect_key_n = 1;
    reg default_param_key_n = 1;
    wire [3:0] default_mode [0:15];
    wire [7:0] default_param [0:15];
    integer checks = 0;
    integer mode_index;
    integer key_index;
    integer expected_mode;
    integer reset_index;
    integer step_index;

    display_effect_control #(.DEBOUNCE_CYCLES(8)) dut (
        .I_clk(clk), .I_rst_n(rst_n), .I_prev_key_n(prev_key_n),
        .I_effect_key_n(effect_key_n), .I_param_key_n(param_key_n),
        .O_effect_mode(effect_mode), .O_effect_param(effect_param)
    );
    display_effect_control #(.DEBOUNCE_CYCLES(1)) fast_dut (
        .I_clk(clk), .I_rst_n(rst_n), .I_prev_key_n(fast_prev_key_n),
        .I_effect_key_n(fast_effect_key_n), .I_param_key_n(fast_param_key_n),
        .O_effect_mode(fast_mode), .O_effect_param(fast_param)
    );
    genvar default_index;
    generate
        for (default_index = 0; default_index < 16;
             default_index = default_index + 1) begin : default_duts
            display_effect_control #(
                .DEBOUNCE_CYCLES(1), .DEFAULT_MODE(default_index)
            ) default_dut (
                .I_clk(clk), .I_rst_n(rst_n),
                .I_prev_key_n(default_prev_key_n),
                .I_effect_key_n(default_effect_key_n),
                .I_param_key_n(default_param_key_n),
                .O_effect_mode(default_mode[default_index]),
                .O_effect_param(default_param[default_index])
            );
        end
    endgenerate

    task automatic hold_keys(input bit prev_n, input bit effect_n,
                             input bit param_n, input integer cycles);
        begin
            @(negedge clk);
            prev_key_n = prev_n;
            effect_key_n = effect_n;
            param_key_n = param_n;
            repeat (cycles) @(negedge clk);
        end
    endtask

    task automatic hold_one(input integer which, input bit released,
                            input integer cycles);
        begin
            hold_keys(which == 0 ? released : 1'b1,
                      which == 1 ? released : 1'b1,
                      which == 2 ? released : 1'b1, cycles);
        end
    endtask

    task automatic press(input integer which);
        begin
            hold_one(which, 0, 16);
            hold_keys(1, 1, 1, 16);
        end
    endtask

    task automatic check(input integer mode_value);
        begin
            checks = checks + 1;
            if (effect_mode !== mode_value[3:0] || effect_param !== 8'd0)
                $fatal(1, "Check %0d expected mode=%0d param=0 got %0d/%0d",
                       checks, mode_value, effect_mode, effect_param);
        end
    endtask

    task automatic check_defaults(input integer mode_offset);
        integer index;
        integer expected;
        begin
            for (index = 0; index < 16; index = index + 1) begin
                expected = ((index < 5 ? index : 0) + mode_offset) % 5;
                checks = checks + 1;
                if (default_mode[index] !== expected[3:0] ||
                    default_param[index] !== 8'd0)
                    $fatal(1, "DEFAULT_MODE=%0d offset=%0d expected=%0d got=%0d/%0d",
                           index, mode_offset, expected,
                           default_mode[index], default_param[index]);
            end
        end
    endtask

    task automatic reset_controls;
        begin
            @(negedge clk);
            rst_n = 0;
            prev_key_n = 1;
            effect_key_n = 1;
            param_key_n = 1;
            fast_prev_key_n = 1;
            fast_effect_key_n = 1;
            fast_param_key_n = 1;
            default_prev_key_n = 1;
            default_effect_key_n = 1;
            default_param_key_n = 1;
            repeat (4) @(negedge clk);
            rst_n = 1;
            repeat (16) @(negedge clk);
            check(0);
            check_defaults(0);
        end
    endtask

    initial begin
        reset_controls();
        for (step_index = 0; step_index < 3; step_index = step_index + 1) begin
            for (mode_index = 0; mode_index < 5; mode_index = mode_index + 1) begin
                check(mode_index);
                press(2); check(mode_index);
                press(1);
            end
            check(0);
            for (mode_index = 4; mode_index >= 0; mode_index = mode_index - 1) begin
                press(0); check(mode_index);
            end
        end

        // Navigation rejects chatter, fires once per hold and needs release.
        for (key_index = 0; key_index < 2; key_index = key_index + 1) begin
            reset_controls();
            hold_one(key_index, 0, 2); hold_one(key_index, 1, 2);
            hold_one(key_index, 0, 2); hold_one(key_index, 1, 16);
            check(0);
            hold_one(key_index, 0, 16);
            expected_mode = key_index == 0 ? 4 : 1;
            check(expected_mode);
            hold_one(key_index, 0, 100); check(expected_mode);
            hold_one(key_index, 1, 2); hold_one(key_index, 0, 2);
            hold_one(key_index, 1, 2); hold_one(key_index, 0, 16);
            check(expected_mode);
            hold_one(key_index, 1, 16); hold_one(key_index, 0, 16);
            check(key_index == 0 ? 3 : 2);
            hold_keys(1, 1, 1, 16);
        end

        // K4 chatter and a long hold never change either output in any mode.
        reset_controls();
        for (mode_index = 0; mode_index < 5; mode_index = mode_index + 1) begin
            hold_one(2, 0, 2); hold_one(2, 1, 2);
            hold_one(2, 0, 2); hold_one(2, 1, 16); check(mode_index);
            hold_one(2, 0, 100); check(mode_index);
            hold_keys(1, 1, 1, 16);
            press(1);
        end

        reset_controls();
        hold_keys(0, 0, 0, 16); check(1);
        hold_keys(0, 0, 0, 100); check(1);
        hold_keys(1, 1, 1, 16);
        hold_keys(0, 1, 0, 16); check(0);
        hold_keys(1, 1, 1, 16);
        hold_keys(1, 0, 0, 16); check(1);
        hold_keys(1, 1, 1, 16);
        reset_controls();

        // Debounce=1 still synchronizes and never repeats a held press.
        @(negedge clk); fast_prev_key_n = 0;
        repeat (2) @(negedge clk);
        if (fast_mode !== 0 || fast_param !== 0)
            $fatal(1, "DEBOUNCE_CYCLES=1 bypassed synchronization");
        @(negedge clk);
        if (fast_mode !== 4 || fast_param !== 0)
            $fatal(1, "DEBOUNCE_CYCLES=1 previous key did not wrap");
        repeat (50) @(negedge clk);
        if (fast_mode !== 4)
            $fatal(1, "DEBOUNCE_CYCLES=1 repeats while held");
        fast_prev_key_n = 1;
        repeat (4) @(negedge clk);
        for (step_index = 0; step_index < 6; step_index = step_index + 1) begin
            fast_effect_key_n = 0;
            repeat (4) @(negedge clk);
            if (fast_mode !== step_index % 5 || fast_param !== 0)
                $fatal(1, "DEBOUNCE_CYCLES=1 next key wrap/rearm failed");
            fast_effect_key_n = 1;
            repeat (4) @(negedge clk);
        end
        fast_param_key_n = 0;
        repeat (50) @(negedge clk);
        if (fast_mode !== 0 || fast_param !== 0)
            $fatal(1, "Unused K4 changed mode or parameter");

        default_effect_key_n = 0;
        repeat (4) @(negedge clk);
        check_defaults(1);
        default_effect_key_n = 1;
        repeat (4) @(negedge clk);
        default_prev_key_n = 0;
        repeat (4) @(negedge clk);
        check_defaults(0);
        default_prev_key_n = 1;
        repeat (4) @(negedge clk);
        default_prev_key_n = 0;
        repeat (4) @(negedge clk);
        check_defaults(4);
        default_param_key_n = 0;
        repeat (50) @(negedge clk);
        check_defaults(4);

        $display("DISPLAY_EFFECT_CONTROL_PASS checks=%0d modes=5 forward_reverse=3 bounce_keys=2 hold_keys=2 priority=next_prev debounce_min=1 defaults=16 k4_ignored=1 param_zero=1",
                 checks);
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "Display effect control test timeout");
    end
endmodule
