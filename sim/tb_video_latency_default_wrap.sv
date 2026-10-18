`timescale 1ns/1ps

// Use the production timestamp width and one-second expiry. One reference
// clock cycle advances one microsecond to exercise complete 24-bit wraps.
module tb_video_latency_default_wrap;
    localparam integer PERIOD = 16777216;
    localparam integer MAX_AGE = 1000000;
    reg time_clk = 0, csi_clk = 0, ddr_clk = 0, hdmi_clk = 0;
    bit csi_run = 1;
    realtime ddr_half = 6.7, hdmi_half = 6.3;
    always #5 time_clk = ~time_clk;
    initial forever begin #4.1; if (csi_run) csi_clk = ~csi_clk; end
    initial forever begin #(ddr_half); ddr_clk = ~ddr_clk; end
    initial forever begin #(hdmi_half); hdmi_clk = ~hdmi_clk; end
    reg rst_n = 0;
    reg raw_sof = 0, raw_valid = 0, isp_sof = 0, isp_valid = 0;
    wire [9:0] raw_id;
    reg [9:0] isp_id = 0;
    reg write_start = 0, write_word = 0, read_start = 0, display_start = 0;
    wire sample_strobe, sample_valid;
    wire [9:0] sampled_id;
    wire [19:0] total_us, isp_us, buffer_us;
    integer ideal_us = 0, samples = 0, checks = 0, valid_checks = 0;
    integer current_id, raw_time, isp_time;
    integer captured_id, captured_total, captured_isp, captured_buffer;
    bit captured_valid = 0;

    video_latency_monitor #(.TIME_DEN(1), .FRAME_WORDS(8)) dut (
        .I_time_clk(time_clk), .I_csi_clk(csi_clk), .I_ddr_clk(ddr_clk),
        .I_hdmi_clk(hdmi_clk), .I_rst_n(rst_n),
        .I_raw_sof(raw_sof), .I_raw_valid(raw_valid), .O_raw_frame_id(raw_id),
        .I_isp_sof(isp_sof), .I_isp_valid(isp_valid), .I_isp_frame_id(isp_id),
        .I_write_start(write_start), .I_write_slot(2'd0), .I_write_word(write_word),
        .I_read_start(read_start), .I_read_slot(2'd0),
        .I_display_frame_start(display_start),
        .O_sample_strobe(sample_strobe), .O_sample_valid(sample_valid),
        .O_frame_id(sampled_id), .O_total_us(total_us),
        .O_isp_us(isp_us), .O_buffer_us(buffer_us)
    );

    always @(posedge time_clk) begin
        if (rst_n) ideal_us = ideal_us + 1;
    end
    always @(posedge hdmi_clk) begin
        #0.1;
        if (rst_n && sample_strobe) begin
            samples = samples + 1;
            captured_valid = sample_valid;
            captured_id = sampled_id;
            captured_total = total_us;
            captured_isp = isp_us;
            captured_buffer = buffer_us;
        end
    end

    task automatic complete_frame;
        begin
            @(negedge csi_clk);
            raw_sof = 1; raw_valid = 1;
            #0.1;
            current_id = raw_id;
            @(posedge csi_clk);
            raw_time = ideal_us;
            @(negedge csi_clk);
            raw_sof = 0; raw_valid = 0;
            repeat (6) @(negedge csi_clk);
            isp_sof = 1; isp_valid = 1; isp_id = current_id[9:0];
            @(posedge csi_clk);
            isp_time = ideal_us;
            @(negedge csi_clk);
            isp_sof = 0; isp_valid = 0;
            repeat (8) @(negedge ddr_clk);
            write_start = 1;
            @(negedge ddr_clk);
            write_start = 0;
            repeat (4) @(negedge ddr_clk);
            write_word = 1;
            repeat (8) @(negedge ddr_clk);
            write_word = 0;
            repeat (12) @(negedge ddr_clk);
        end
    endtask

    task automatic select_read;
        begin
            @(negedge ddr_clk);
            read_start = 1;
            @(negedge ddr_clk);
            read_start = 0;
            repeat (12) @(negedge hdmi_clk);
        end
    endtask

    task automatic display_check(input bit expected_valid,
                                 input [8*80-1:0] scenario);
        integer previous_samples, display_time, expected_total, expected_isp;
        begin
            @(negedge hdmi_clk);
            previous_samples = samples;
            display_start = 1;
            @(posedge hdmi_clk);
            display_time = ideal_us;
            @(negedge hdmi_clk);
            display_start = 0;
            repeat (20) @(negedge hdmi_clk);
            if (samples != previous_samples + 1 || captured_valid !== expected_valid)
                $fatal(1, "Default wrap sample wrong %0s count=%0d validity=%0b/%0b",
                       scenario, samples-previous_samples, captured_valid, expected_valid);
            if (expected_valid) begin
                expected_total = display_time - raw_time;
                expected_isp = isp_time - raw_time;
                if (captured_id != current_id ||
                    captured_total < expected_total - 4 ||
                    captured_total > expected_total + 4 ||
                    captured_isp < expected_isp - 4 ||
                    captured_isp > expected_isp + 4 ||
                    captured_total != captured_isp + captured_buffer)
                    $fatal(1, "Default wrap time mismatch %0s id=%0d/%0d total=%0d/%0d isp=%0d/%0d",
                           scenario, captured_id, current_id, captured_total, expected_total,
                           captured_isp, expected_isp);
                valid_checks = valid_checks + 1;
            end
            checks = checks + 1;
        end
    endtask

    task automatic idle_until(input integer target_time);
        begin
            if (csi_run) begin
                @(negedge csi_clk);
                csi_run = 0;
            end
            // Coarse expiry is independently clocked even while CSI stops.
            // Slower DDR/HDMI clocks keep long-wrap simulation inexpensive.
            ddr_half = 1000; hdmi_half = 1000;
            wait (ideal_us >= target_time);
            ddr_half = 6.7; hdmi_half = 6.3;
            repeat (20) @(negedge ddr_clk);
            repeat (20) @(negedge hdmi_clk);
        end
    endtask

    integer next_wrap;
    initial begin
        if (dut.TIME_WIDTH != 24 || dut.MAX_AGE_US != MAX_AGE)
            $fatal(1, "Default-width test must use 24 bits and the production 1s expiry");
        repeat (8) @(negedge time_clk);
        rst_n = 1;
        repeat (12) @(negedge csi_clk);
        complete_frame();
        select_read();
        display_check(1, "fresh production-width frame");
        idle_until(raw_time + MAX_AGE - 1000);
        select_read();
        display_check(1, "stopped camera remains valid just below one second");
        select_read();
        idle_until(raw_time + MAX_AGE + 64);
        display_check(0, "pending read snapshot expires after one second");
        select_read();
        display_check(0, "new read of stopped-camera frame is stale");
        idle_until(raw_time + PERIOD + 500);
        select_read();
        display_check(0, "expired slot cannot revive after first complete 24-bit wrap");
        idle_until(raw_time + 2*PERIOD + 500);
        select_read();
        display_check(0, "expired slot cannot revive after second complete 24-bit wrap");
        csi_run = 1;
        repeat (12) @(negedge csi_clk);
        complete_frame();
        select_read();
        display_check(1, "fresh camera frame recovers after two wraps");

        next_wrap = (ideal_us/PERIOD + 1)*PERIOD;
        idle_until(next_wrap - 500);
        csi_run = 1;
        repeat (12) @(negedge csi_clk);
        complete_frame();
        if (raw_time >= next_wrap)
            $fatal(1, "Fresh-wrap frame was not captured before counter rollover");
        idle_until(next_wrap + 100);
        select_read();
        display_check(1, "fresh production-width frame spans timestamp wrap");
        if (checks != 8 || valid_checks != 4 || ideal_us/PERIOD != 3)
            $fatal(1, "Default wrap coverage incomplete checks=%0d valid=%0d wraps=%0d",
                   checks, valid_checks, ideal_us/PERIOD);
        $display("VIDEO_LATENCY_DEFAULT_WRAP_PASS width=24 max_age_us=1000000 resolution_us=1 checks=%0d valid=%0d full_wraps=%0d camera_stop=1 recovery=1",
                 checks, valid_checks, ideal_us/PERIOD);
        $finish;
    end

    initial begin
        #600000000;
        $fatal(1, "Default-width latency wrap regression timed out");
    end
endmodule
