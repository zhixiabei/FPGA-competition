`timescale 1ns/1ps

module tb_video_latency_word_count;
    localparam integer FRAME_WORDS = 172800;
    reg time_clk = 0, csi_clk = 0, ddr_clk = 0, hdmi_clk = 0;
    always #10 time_clk = ~time_clk;
    always #6.1 csi_clk = ~csi_clk;
    always #3 ddr_clk = ~ddr_clk;
    always #7.3 hdmi_clk = ~hdmi_clk;
    reg rst_n = 0;
    reg raw_sof = 0, raw_valid = 0, isp_sof = 0, isp_valid = 0;
    wire [9:0] raw_id;
    reg [9:0] isp_id = 0;
    reg write_start = 0, write_word = 0, read_start = 0, display_start = 0;
    wire sample_strobe, sample_valid;
    wire [9:0] sampled_id;
    wire [19:0] total_us, isp_us, buffer_us;
    integer samples = 0, checks = 0, valid_checks = 0;
    integer current_id = 0;
    integer captured_id = 0, captured_total = 0, captured_isp = 0, captured_buffer = 0;
    bit captured_valid = 0;
    realtime raw_time, isp_time;

    // Intentionally use the production defaults, including the word counter
    // width selected by FRAME_WORDS=172800 and the 50 MHz microsecond clock.
    video_latency_monitor dut (
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

    task automatic begin_frame;
        begin
            @(negedge csi_clk);
            raw_sof = 1; raw_valid = 1;
            #0.1;
            current_id = raw_id;
            @(posedge csi_clk);
            raw_time = $realtime;
            @(negedge csi_clk);
            raw_sof = 0; raw_valid = 0;
            repeat (6) @(negedge csi_clk);
            isp_sof = 1; isp_valid = 1; isp_id = current_id[9:0];
            @(posedge csi_clk);
            isp_time = $realtime;
            @(negedge csi_clk);
            isp_sof = 0; isp_valid = 0;
            repeat (8) @(negedge ddr_clk);
            write_start = 1;
            @(negedge ddr_clk);
            write_start = 0;
        end
    endtask

    task automatic words(input integer count);
        begin
            @(negedge ddr_clk);
            write_word = 1;
            repeat (count) @(negedge ddr_clk);
            write_word = 0;
        end
    endtask

    task automatic display_check(input bit expected_valid,
                                 input [8*72-1:0] scenario);
        integer previous_samples, expected_total, expected_isp;
        realtime display_time;
        begin
            @(negedge ddr_clk);
            read_start = 1;
            @(negedge ddr_clk);
            read_start = 0;
            repeat (12) @(negedge hdmi_clk);
            previous_samples = samples;
            display_start = 1;
            @(posedge hdmi_clk);
            display_time = $realtime;
            @(negedge hdmi_clk);
            display_start = 0;
            repeat (20) @(negedge hdmi_clk);
            if (samples != previous_samples + 1 || captured_valid !== expected_valid)
                $fatal(1, "Production word-count sample wrong %0s count=%0d validity=%0b/%0b",
                       scenario, samples - previous_samples, captured_valid, expected_valid);
            if (expected_valid) begin
                expected_total = $rtoi((display_time - raw_time) / 1000.0);
                expected_isp = $rtoi((isp_time - raw_time) / 1000.0);
                if (captured_id != current_id ||
                    captured_total < expected_total - 2 ||
                    captured_total > expected_total + 2 ||
                    captured_isp < expected_isp - 2 ||
                    captured_isp > expected_isp + 2 ||
                    captured_total != captured_isp + captured_buffer)
                    $fatal(1, "Production frame/time mismatch %0s id=%0d/%0d total=%0d/%0d isp=%0d/%0d",
                           scenario, captured_id, current_id, captured_total, expected_total,
                           captured_isp, expected_isp);
                valid_checks = valid_checks + 1;
            end
            checks = checks + 1;
        end
    endtask

    initial begin
        repeat (8) @(negedge time_clk);
        rst_n = 1;
        repeat (12) @(negedge csi_clk);
        begin_frame();
        words(FRAME_WORDS - 1);
        display_check(0, "production frame remains invalid at 172799 accepted words");
        words(1);
        display_check(1, "production frame becomes valid at accepted word 172800");
        words(17);
        display_check(1, "additional words cannot wrap or relabel the completed frame");
        begin_frame();
        words(1);
        display_check(0, "new frame start clears the production-width word counter");
        rst_n = 0;
        repeat (8) @(negedge time_clk);
        rst_n = 1;
        repeat (12) @(negedge csi_clk);
        words(FRAME_WORDS - 1);
        display_check(0, "reset cancels write-active even with 172799 trailing words");
        if (checks != 5 || valid_checks != 2)
            $fatal(1, "Production word-count coverage incomplete");
        $display("VIDEO_LATENCY_WORD_COUNT_PASS checks=%0d valid=%0d threshold=%0d reset=1",
                 checks, valid_checks, FRAME_WORDS);
        $finish;
    end

    initial begin
        #5000000;
        $fatal(1, "Production word-count regression timed out");
    end
endmodule
