`timescale 1ns/1ps

module tb_auto_exposure_control;
    reg clk = 0;
    always #21 clk = ~clk;
    reg rst = 1;
    reg camera_done = 0;
    reg ae_done = 0;
    reg stats_valid = 0;
    reg [31:0] sum_y = 0;
    reg [15:0] sample_count = 256;
    reg [15:0] bright_count = 0;
    wire request;
    wire [15:0] exposure, gain;
    integer requests = 0;
    integer checks = 0;
    integer accepted_updates = 0;

    auto_exposure_control dut (
        .I_clk(clk), .I_rst(rst),
        .I_cam_cfg_done(camera_done), .I_ae_cfg_done(ae_done),
        .I_stats_valid(stats_valid), .I_sum_y(sum_y),
        .I_sample_count(sample_count), .I_bright_count(bright_count),
        .O_ae_req(request), .O_ae(exposure), .O_ag(gain)
    );

    always @(posedge clk) begin
        #1;
        if (!rst) begin
            if (request)
                requests = requests + 1;
            if (exposure < 4 || exposure > 1991 || gain < 16 || gain > 144)
                $fatal(1, "Illegal sensor parameter range: %0d/%0d", exposure, gain);
        end
    end

    task automatic tick;
        begin
            @(posedge clk);
            #2;
        end
    endtask

    task automatic assert_state(input integer expected_ae, input integer expected_ag,
                                input integer expected_req, input string label_text);
        begin
            checks = checks + 1;
            if (exposure !== expected_ae || gain !== expected_ag ||
                request !== expected_req[0])
                $fatal(1, "%s: expected %0d/%0d req%0d, got %0d/%0d req%0d",
                       label_text, expected_ae, expected_ag, expected_req,
                       exposure, gain, request);
        end
    endtask

    // mean_y describes NON-HIGHLIGHT background samples, never the lamp/screen.
    task automatic stats(input integer mean_y, input integer highlights);
        begin
            @(negedge clk);
            stats_valid = 1;
            sample_count = 256;
            sum_y = mean_y * (256 - highlights);
            bright_count = highlights;
            tick();
            @(negedge clk);
            stats_valid = 0;
        end
    endtask

    task automatic complete_transaction;
        integer ae_hold, ag_hold;
        begin
            ae_hold = exposure;
            ag_hold = gain;
            // done initially remains high for a few clocks. This cannot be
            // mistaken for completion of the newly issued transaction.
            repeat (3) begin
                tick();
                assert_state(ae_hold, ag_hold, 0, "stale done high");
            end
            stats(255, 256);
            assert_state(ae_hold, ag_hold, 0, "stats before bus acceptance");
            @(negedge clk);
            ae_done = 0;
            tick();
            stats(0, 0);
            assert_state(ae_hold, ag_hold, 0, "stats during I2C busy");
            repeat (5) tick();
            @(negedge clk);
            ae_done = 1;
            tick();
            // Three whole-frame statistics after commit are discarded.
            repeat (3) begin
                stats(0, 0);
                assert_state(ae_hold, ag_hold, 0, "settling frame");
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
            repeat (2) tick();
            @(negedge clk);
            rst = 0;
            stats(0, 0);
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

    integer previous_ae, previous_ag, expected_ae, expected_ag, loop_count;
    integer before_requests, highlight_case, highlight_samples;
    initial begin
        initialize();
        stats(96, 0);
        assert_state(1000, 16, 0, "inclusive low target");
        stats(128, 0);
        assert_state(1000, 16, 0, "inclusive high target");
        stats(95, 0);
        assert_state(1125, 16, 1, "normal dark exposure step");
        complete_transaction();
        stats(47, 0);
        assert_state(1406, 16, 1, "fast dark exposure step");
        complete_transaction();

        // Darkness consumes exposure range before gain, then clamps both.
        loop_count = 0;
        while (exposure != 1991 || gain != 144) begin
            previous_ae = exposure;
            previous_ag = gain;
            expected_ae = previous_ae;
            expected_ag = previous_ag;
            if (previous_ae < 1991) begin
                expected_ae = previous_ae + (previous_ae >> 2);
                if (expected_ae > 1991) expected_ae = 1991;
            end else begin
                expected_ag = previous_ag + 16;
                if (expected_ag > 144) expected_ag = 144;
            end
            stats(0, 0);
            assert_state(expected_ae, expected_ag, 1, "dark exposure before gain");
            complete_transaction();
            loop_count = loop_count + 1;
            if (loop_count > 30) $fatal(1, "Darkness feedback failed to converge");
        end
        stats(0, 0);
        assert_state(1991, 144, 0, "maximum brightness parameters clamp");

        // Strong light removes gain first; only then shorten exposure.
        stats(129, 0);
        assert_state(1991, 140, 1, "normal bright gain step");
        complete_transaction();
        while (gain != 16) begin
            expected_ag = (gain > 32) ? gain - 16 : 16;
            stats(255, 256);
            assert_state(1991, expected_ag, 1, "strong light removes gain first");
            complete_transaction();
        end
        stats(255, 256);
        assert_state(1494, 16, 1, "strong light shortens exposure after gain");
        complete_transaction();
        loop_count = 0;
        while (exposure != 4) begin
            previous_ae = exposure;
            expected_ae = previous_ae >> 2;
            if (expected_ae < 4) expected_ae = 4;
            expected_ae = (previous_ae > expected_ae + 4) ?
                          previous_ae - expected_ae : 4;
            stats(255, 256);
            assert_state(expected_ae, 16, 1, "exposure lower clamp");
            complete_transaction();
            loop_count = loop_count + 1;
            if (loop_count > 35) $fatal(1, "Bright feedback failed to converge");
        end
        stats(255, 256);
        assert_state(4, 16, 0, "sensor minimum exposure code four");

        // Lamps/screens covering 5%, 33%, 50%, 75% do not override a
        // dark non-emissive background. 75% is the inclusive increase limit.
        for (highlight_case = 0; highlight_case < 4;
             highlight_case = highlight_case + 1) begin
            case (highlight_case)
                0: highlight_samples = 13;
                1: highlight_samples = 85;
                2: highlight_samples = 128;
                3: highlight_samples = 192;
            endcase
            initialize();
            stats(110, highlight_samples);
            assert_state(1000, 16, 0, "balanced background ignores bright screen");
            stats(70, highlight_samples);
            assert_state(1125, 16, 1, "dark background brightens despite screen");
            complete_transaction();
            stats(96, highlight_samples);
            assert_state(1125, 16, 0, "background low mean inclusive");
            stats(128, highlight_samples);
            assert_state(1125, 16, 0, "background high mean inclusive");
            stats(129, highlight_samples);
            assert_state(985, 16, 1, "bright background still dims");
            complete_transaction();
        end

        // 12.5%..25% useful background is a dark-scene deadband. These
        // thresholds concern sample counts, not total-frame average luma.
        initialize();
        stats(70, 193);
        assert_state(1000, 16, 0, "just over 75 percent highlights holds");
        stats(0, 220);
        assert_state(1000, 16, 0, "few useful samples cannot cause brightening");
        stats(70, 224);
        assert_state(1000, 16, 0, "87.5 percent highlight boundary inclusive hold");
        stats(129, 224);
        assert_state(875, 16, 1, "bright background dims inside count deadband");
        complete_transaction();
        stats(70, 225);
        assert_state(657, 16, 1, "over 87.5 percent highlights recovers full white");
        complete_transaction();
        stats(0, 256);
        assert_state(493, 16, 1, "all-white zero-background frame dims safely");
        complete_transaction();
        stats(110, 0);
        assert_state(493, 16, 0, "full-white recovery retains luma deadband");

        // A saturated colour is not a high-luma highlight: red/blue have
        // luma63, green luma127. The stats tap verifies these RGB semantics.
        initialize();
        stats(63, 0);
        assert_state(1125, 16, 1, "pure red is not treated as full white");
        complete_transaction();
        stats(127, 0);
        assert_state(1125, 16, 0, "pure green remains in target deadband");

        // Invalid payloads cannot drive the loop or consume settling frames.
        @(negedge clk);
        stats_valid = 1;
        sample_count = 0;
        sum_y = 0;
        bright_count = 0;
        tick();
        assert_state(1125, 16, 0, "reject zero sample count");
        @(negedge clk);
        sample_count = 256;
        sum_y = 0;
        bright_count = 257;
        tick();
        assert_state(1125, 16, 0, "reject invalid highlight count");
        @(negedge clk);
        bright_count = 0;
        sum_y = 65536;
        tick();
        assert_state(1125, 16, 0, "reject impossible luma sum");
        @(negedge clk);
        bright_count = 128;
        sum_y = 40000;
        tick();
        assert_state(1125, 16, 0, "reject sum exceeding background capacity");
        @(negedge clk);
        bright_count = 256;
        sum_y = 1;
        tick();
        assert_state(1125, 16, 0, "reject nonzero sum with no background samples");
        @(negedge clk);
        stats_valid = 0;

        // A stopped camera does not cause time-based drift or repeated writes.
        before_requests = requests;
        repeat (200) tick();
        assert_state(1125, 16, 0, "stopped camera parameter hold");
        if (before_requests != requests)
            $fatal(1, "Stopped camera generated an exposure request");
        @(negedge clk);
        ae_done = 0;
        stats(0, 0);
        assert_state(1125, 16, 0, "external I2C busy blocks update");
        @(negedge clk);
        ae_done = 1;
        stats(0, 0);
        assert_state(1406, 16, 1, "bus ready resumes feedback");
        // Camera reconfiguration cancels tracking, then forces one safe write.
        @(negedge clk);
        camera_done = 0;
        tick();
        assert_state(1406, 16, 0, "camera reconfiguration preserves payload");
        repeat (5) tick();
        @(negedge clk);
        camera_done = 1;
        tick();
        assert_state(1000, 16, 1, "camera restart forces safe default");
        complete_transaction();
        stats(110, 0);
        assert_state(1000, 16, 0, "camera restart no repeated initial requests");

        // Reset during an outstanding transaction returns to startup state.
        stats(0, 0);
        assert_state(1250, 16, 1, "pre-reset pending update");
        @(negedge clk);
        rst = 1;
        ae_done = 0;
        tick();
        assert_state(1000, 16, 0, "reset during busy");
        $display("AUTO_EXPOSURE_CONTROL_PASS requests=%0d commits=%0d checks=%0d",
                 requests, accepted_updates, checks);
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "Automatic exposure test timed out");
    end
endmodule
