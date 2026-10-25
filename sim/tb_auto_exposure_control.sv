`timescale 1ns/1ps

module tb_auto_exposure_control;
    localparam integer SAMPLE_COUNT = 256;
    localparam integer GAIN_MAX = 176;

    reg clk = 0;
    always #21 clk = ~clk;
    reg rst = 1;
    reg camera_done = 0;
    reg ae_done = 0;
    reg stats_valid = 0;
    reg [31:0] sum_y = 0;
    reg [15:0] sample_count = SAMPLE_COUNT;
    reg [15:0] bright_count = 0;
    wire request;
    wire [15:0] exposure, gain;
    integer requests = 0;
    integer checks = 0;
    integer accepted_updates = 0;

    auto_exposure_control #(.GAIN_MAX(GAIN_MAX)) dut (
        .I_clk(clk), .I_rst(rst),
        .I_cam_cfg_done(camera_done), .I_ae_cfg_done(ae_done),
        .I_stats_valid(stats_valid), .I_sum_y(sum_y),
        .I_sample_count(sample_count), .I_bright_count(bright_count),
        .O_ae_req(request), .O_ae(exposure), .O_ag(gain)
    );

    always @(posedge clk) begin
        #1;
        if (!rst) begin
            if (request) requests = requests + 1;
            if (exposure < 4 || exposure > 1991 ||
                gain < 16 || gain > GAIN_MAX)
                $fatal(1, "Illegal sensor parameter range: %0d/%0d",
                       exposure, gain);
        end
    end

    task automatic tick;
        begin
            @(posedge clk);
            #2;
        end
    endtask

    task automatic assert_state(input integer expected_ae,
                                input integer expected_ag,
                                input integer expected_req,
                                input string label_text);
        begin
            checks = checks + 1;
            if (exposure !== expected_ae || gain !== expected_ag ||
                request !== expected_req[0])
                $fatal(1,
                    "%s: expected E%0d/G%0d req%0d, got E%0d/G%0d req%0d",
                    label_text, expected_ae, expected_ag, expected_req,
                    exposure, gain, request);
        end
    endtask

    task automatic push_raw(input integer frame_sum,
                            input integer frame_count,
                            input integer frame_bright);
        begin
            @(negedge clk);
            stats_valid = 1;
            sum_y = frame_sum;
            sample_count = frame_count;
            bright_count = frame_bright;
            tick();
            @(negedge clk);
            stats_valid = 0;
        end
    endtask

    task automatic push_stats(input integer mean_y,
                              input integer frame_bright);
        begin
            push_raw(mean_y * SAMPLE_COUNT, SAMPLE_COUNT, frame_bright);
        end
    endtask

    task automatic send_window(input integer mean_y,
                               input integer frame_bright,
                               input integer expected_ae,
                               input integer expected_ag,
                               input integer expected_req,
                               input string label_text);
        integer frame_index;
        integer held_ae;
        integer held_ag;
        begin
            held_ae = exposure;
            held_ag = gain;
            for (frame_index = 0; frame_index < 5; frame_index = frame_index + 1) begin
                push_stats(mean_y, frame_bright);
                assert_state(held_ae, held_ag, 0,
                             {label_text, " accumulation"});
            end
            push_stats(mean_y, frame_bright);
            assert_state(expected_ae, expected_ag, expected_req, label_text);
        end
    endtask

    task automatic complete_transaction;
        integer held_ae;
        integer held_ag;
        integer frame_index;
        begin
            held_ae = exposure;
            held_ag = gain;
            repeat (3) begin
                tick();
                assert_state(held_ae, held_ag, 0, "stale done high");
            end
            push_stats(192, SAMPLE_COUNT);
            assert_state(held_ae, held_ag, 0, "stats before bus acceptance");
            @(negedge clk);
            ae_done = 0;
            tick();
            push_stats(0, 0);
            assert_state(held_ae, held_ag, 0, "stats during I2C busy");
            repeat (5) tick();
            @(negedge clk);
            ae_done = 1;
            tick();
            for (frame_index = 0; frame_index < 3; frame_index = frame_index + 1) begin
                push_stats((frame_index & 1) ? 192 : 0,
                           (frame_index & 1) ? SAMPLE_COUNT : 0);
                assert_state(held_ae, held_ag, 0, "post-write settling frame");
            end
            accepted_updates = accepted_updates + 1;
        end
    endtask

    task automatic initialize;
        begin
            @(negedge clk);
            rst = 1;
            camera_done = 0;
            ae_done = 0;
            stats_valid = 0;
            sample_count = SAMPLE_COUNT;
            sum_y = 0;
            bright_count = 0;
            repeat (2) tick();
            @(negedge clk);
            rst = 0;
            push_stats(0, 0);
            assert_state(1000, 16, 0, "camera initialization incomplete");
            @(negedge clk);
            camera_done = 1;
            repeat (4) tick();
            assert_state(1000, 16, 0, "wait initial table done");
            @(negedge clk);
            ae_done = 1;
            tick();
            assert_state(1000, 16, 1, "safe startup write");
            complete_transaction();
        end
    endtask

    task automatic flicker_window(input integer expected_ae,
                                  input integer expected_ag,
                                  input string label_text);
        integer index;
        integer mean_value;
        begin
            for (index = 0; index < 6; index = index + 1) begin
                mean_value = (index & 1) ? 136 : 80;
                push_stats(mean_value, 0);
                assert_state(expected_ae, expected_ag, 0, label_text);
            end
        end
    endtask

    integer loop_count;
    integer previous_ae;
    integer previous_ag;
    integer expected_ae;
    integer expected_ag;
    integer step_value;
    integer request_base;
    integer frame_index;
    initial begin
        initialize();

        send_window(96, 0, 1000, 16, 0, "inclusive target low");
        send_window(120, 0, 1000, 16, 0, "inclusive target high");
        repeat (5) flicker_window(1000, 16, "six-frame mains flicker hold");

        send_window(95, 64, 875, 16, 1,
                    "25 percent highlight forces a slow reduction");
        complete_transaction();
        send_window(95, 51, 875, 16, 0,
                    "latched 20 percent highlight holds exposure");
        send_window(95, 32, 875, 16, 0,
                    "latched 12.5 percent boundary holds exposure");
        send_window(95, 64, 766, 16, 1,
                    "sustained 25 percent highlight keeps reducing");
        complete_transaction();
        send_window(121, 25, 671, 16, 1,
                    "bright mean wins while low highlight clears latch");
        complete_transaction();
        send_window(95, 25, 754, 16, 1,
                    "below 12.5 percent permits normal increase");
        complete_transaction();
        send_window(63, 25, 942, 16, 1, "fast dark increase after clear");
        complete_transaction();

        initialize();
        push_stats(95, 256);
        push_stats(95, 128);
        repeat (3) push_stats(95, 0);
        assert_state(1000, 16, 0, "partial aggregate highlight window holds");
        push_stats(95, 0);
        assert_state(875, 16, 1,
                     "aggregate 25 percent boundary forces reduction");
        complete_transaction();

        initialize();
        send_window(64, 0, 1125, 16, 1, "dark fast boundary is exclusive");
        complete_transaction();
        initialize();
        send_window(144, 0, 875, 16, 1, "bright fast boundary is exclusive");
        complete_transaction();
        initialize();
        send_window(145, SAMPLE_COUNT, 750, 16, 1, "fast bright decrease");
        complete_transaction();
        initialize();
        send_window(121, SAMPLE_COUNT, 875, 16, 1, "normal bright decrease");
        complete_transaction();

        initialize();
        push_raw(0, 0, 0);
        push_raw(0, SAMPLE_COUNT, SAMPLE_COUNT + 1);
        push_raw(SAMPLE_COUNT * 192 + 1, SAMPLE_COUNT, 0);
        repeat (5) begin
            push_stats(95, 0);
            assert_state(1000, 16, 0, "invalid statistics did not advance window");
        end
        push_stats(95, 0);
        assert_state(1125, 16, 1, "sixth valid frame after invalid payloads");
        complete_transaction();

        loop_count = 0;
        while (exposure != 1991 || gain != GAIN_MAX) begin
            previous_ae = exposure;
            previous_ag = gain;
            expected_ae = previous_ae;
            expected_ag = previous_ag;
            if (previous_ae < 1991) begin
                step_value = previous_ae >> 2;
                if (step_value < 4) step_value = 4;
                expected_ae = previous_ae + step_value;
                if (expected_ae > 1991) expected_ae = 1991;
            end else begin
                expected_ag = previous_ag + 16;
                if (expected_ag > GAIN_MAX) expected_ag = GAIN_MAX;
            end
            send_window(0, 0, expected_ae, expected_ag, 1,
                        "dark exposure before gain");
            complete_transaction();
            loop_count = loop_count + 1;
            if (loop_count > 30)
                $fatal(1, "Dark feedback failed to reach the configured limit");
        end
        send_window(0, 0, 1991, GAIN_MAX, 0, "dark upper limit holds");

        send_window(121, SAMPLE_COUNT, 1991, GAIN_MAX-4, 1,
                    "normal bright gain step");
        complete_transaction();
        send_window(145, SAMPLE_COUNT, 1991, GAIN_MAX-20, 1,
                    "fast bright gain step");
        complete_transaction();
        loop_count = 0;
        while (gain != 16) begin
            expected_ag = (gain > 32) ? gain - 16 : 16;
            send_window(192, SAMPLE_COUNT, exposure, expected_ag, 1,
                        "full white removes gain");
            complete_transaction();
            loop_count = loop_count + 1;
            if (loop_count > 20) $fatal(1, "Gain failed to return to unity");
        end
        loop_count = 0;
        while (exposure != 4) begin
            previous_ae = exposure;
            step_value = previous_ae >> 2;
            if (step_value < 4) step_value = 4;
            expected_ae = (previous_ae > step_value + 4) ?
                          previous_ae - step_value : 4;
            send_window(192, SAMPLE_COUNT, expected_ae, 16, 1,
                        "full white exposure lower clamp");
            complete_transaction();
            loop_count = loop_count + 1;
            if (loop_count > 35) $fatal(1, "Exposure failed to reach minimum");
        end
        send_window(192, SAMPLE_COUNT, 4, 16, 0, "bright lower limit holds");

        request_base = requests;
        repeat (300) tick();
        assert_state(4, 16, 0, "stopped camera parameter hold");
        if (requests != request_base)
            $fatal(1, "Stopped camera generated an exposure request");

        for (frame_index = 0; frame_index < 5; frame_index = frame_index + 1)
            push_stats(0, 0);
        @(negedge clk);
        camera_done = 0;
        tick();
        repeat (5) tick();
        @(negedge clk);
        camera_done = 1;
        tick();
        assert_state(1000, 16, 1, "camera restart forces safe default");
        complete_transaction();
        repeat (5) begin
            push_stats(0, 0);
            assert_state(1000, 16, 0, "restart discarded partial window");
        end
        push_stats(0, 0);
        assert_state(1250, 16, 1, "restart sixth frame makes one decision");

        @(negedge clk);
        rst = 1;
        ae_done = 0;
        tick();
        assert_state(1000, 16, 0, "reset during busy");
        $display("AUTO_EXPOSURE_CONTROL_PASS requests=%0d commits=%0d checks=%0d windows=6 gain_max=%0d",
                 requests, accepted_updates, checks, GAIN_MAX);
        $finish;
    end

    initial begin
        #4000000;
        $fatal(1, "Automatic exposure control test timed out");
    end
endmodule
