`timescale 1ns/1ps

// Timestamp expectations use a free-running testbench timeline. They never
// derive the selected frame identity from the DUT's slot or CDC registers.
module tb_video_latency_monitor;
    localparam integer TW = 12;
    localparam integer DEN = 8;
    localparam integer WORDS = 8;
    localparam integer MAX_AGE = 500;
    localparam integer PERIOD = 1 << TW;
    reg time_clk = 0, csi_clk = 0, ddr_clk = 0, hdmi_clk = 0;
    bit csi_run = 1, ddr_run = 1;
    realtime csi_half = 6, ddr_half = 3, hdmi_half = 7.3;
    always #5 time_clk = ~time_clk;
    initial begin
        #1.3;
        forever begin
            #(csi_half);
            if (csi_run) csi_clk = ~csi_clk;
        end
    end
    initial begin
        #0.9;
        forever begin
            #(ddr_half);
            if (ddr_run) ddr_clk = ~ddr_clk;
        end
    end
    initial begin
        #2.1;
        forever #(hdmi_half) hdmi_clk = ~hdmi_clk;
    end
    reg rst_n = 0;
    reg raw_sof = 0, raw_valid = 0;
    wire [9:0] raw_frame_id;
    reg isp_sof = 0, isp_valid = 0;
    reg [9:0] isp_frame_id = 0;
    reg write_start = 0, write_word = 0;
    reg [1:0] write_slot = 0;
    reg read_start = 0;
    reg [1:0] read_slot = 0;
    reg display_start = 0;
    wire sample_strobe, sample_valid;
    wire [9:0] sampled_frame_id;
    wire [19:0] total_us, isp_us, buffer_us;

    video_latency_monitor #(
        .TIME_WIDTH(TW), .TIME_NUM(1), .TIME_DEN(DEN),
        .FRAME_WORDS(WORDS), .MAX_AGE_US(MAX_AGE)
    ) dut (
        .I_time_clk(time_clk), .I_csi_clk(csi_clk),
        .I_ddr_clk(ddr_clk), .I_hdmi_clk(hdmi_clk), .I_rst_n(rst_n),
        .I_raw_sof(raw_sof), .I_raw_valid(raw_valid),
        .O_raw_frame_id(raw_frame_id),
        .I_isp_sof(isp_sof), .I_isp_valid(isp_valid),
        .I_isp_frame_id(isp_frame_id),
        .I_write_start(write_start), .I_write_slot(write_slot),
        .I_write_word(write_word),
        .I_read_start(read_start), .I_read_slot(read_slot),
        .I_display_frame_start(display_start),
        .O_sample_strobe(sample_strobe), .O_sample_valid(sample_valid),
        .O_frame_id(sampled_frame_id),
        .O_total_us(total_us), .O_isp_us(isp_us), .O_buffer_us(buffer_us)
    );

    integer ideal_cycles = 0;
    integer ideal_us = 0;
    integer sample_count = 0, checks = 0, valid_count = 0, invalid_count = 0;
    integer raw_events = 0, write_events = 0, read_events = 0;
    integer wrap_events = 0;
    integer last_total = 0;
    reg last_sample_valid = 0;
    reg [9:0] last_sample_id = 0;
    integer last_sample_total = 0, last_sample_isp = 0, last_sample_buffer = 0;
    reg previous_strobe = 0;

    always @(posedge time_clk or negedge rst_n) begin
        if (!rst_n) begin
            ideal_cycles = 0;
            ideal_us = 0;
        end else begin
            ideal_cycles = ideal_cycles + 1;
            ideal_us = ideal_cycles / DEN;
        end
    end
    always @(posedge hdmi_clk) begin
        #0.1;
        if (!rst_n) begin
            previous_strobe = 0;
        end else begin
            if (sample_strobe && previous_strobe)
                $fatal(1, "Display sample strobe is wider than one HDMI clock");
            previous_strobe = sample_strobe;
            if (sample_strobe) begin
                sample_count = sample_count + 1;
                last_sample_valid = sample_valid;
                last_sample_id = sampled_frame_id;
                last_sample_total = total_us;
                last_sample_isp = isp_us;
                last_sample_buffer = buffer_us;
            end
        end
    end

    task automatic wait_us(input integer duration);
        integer target;
        begin
            target = ideal_us + duration;
            while (ideal_us < target) @(negedge time_clk);
        end
    endtask

    task automatic reset_test;
        begin
            rst_n = 0;
            csi_run = 1;
            ddr_run = 1;
            raw_sof = 0; raw_valid = 0;
            isp_sof = 0; isp_valid = 0; isp_frame_id = 0;
            write_start = 0; write_word = 0; write_slot = 0;
            read_start = 0; read_slot = 0; display_start = 0;
            repeat (8) @(negedge time_clk);
            rst_n = 1;
            repeat (12) @(negedge csi_clk);
            repeat (12) @(negedge ddr_clk);
            repeat (12) @(negedge hdmi_clk);
        end
    endtask

    task automatic capture_raw_at_sof(output integer id, output integer timestamp);
        integer previous_id;
        begin
            @(negedge csi_clk);
            previous_id = raw_frame_id;
            raw_sof = 1;
            raw_valid = 1;
            #0.1;
            id = raw_frame_id;
            if (id != ((previous_id + 1) & 1023))
                $fatal(1, "Coincident RAW SOF/first pixel has the wrong ID");
            if (id == 0) wrap_events = wrap_events + 1;
            @(posedge csi_clk);
            timestamp = ideal_us;
            @(negedge csi_clk);
            raw_sof = 0;
            raw_valid = 0;
            raw_events = raw_events + 1;
        end
    endtask

    task automatic capture_raw(output integer id, output integer timestamp);
        integer previous_id;
        begin
            @(negedge csi_clk);
            previous_id = raw_frame_id;
            raw_sof = 1;
            #0.1;
            id = raw_frame_id;
            if (id != ((previous_id + 1) & 1023))
                $fatal(1, "RAW SOF did not expose the incoming frame ID");
            if (id == 0) wrap_events = wrap_events + 1;
            @(negedge csi_clk);
            raw_sof = 0;
            repeat (3) @(negedge csi_clk);
            raw_valid = 1;
            @(posedge csi_clk);
            timestamp = ideal_us;
            @(negedge csi_clk);
            raw_valid = 0;
            raw_events = raw_events + 1;
        end
    endtask

    task automatic capture_isp_at_sof(input integer id, output integer timestamp);
        begin
            @(negedge csi_clk);
            isp_frame_id = id[9:0];
            isp_sof = 1;
            isp_valid = 1;
            @(posedge csi_clk);
            timestamp = ideal_us;
            @(negedge csi_clk);
            isp_sof = 0;
            isp_valid = 0;
        end
    endtask

    task automatic start_isp(input integer id);
        begin
            @(negedge csi_clk);
            isp_frame_id = id[9:0];
            isp_sof = 1;
            @(negedge csi_clk);
            isp_sof = 0;
        end
    endtask

    task automatic capture_isp(output integer timestamp);
        begin
            @(negedge csi_clk);
            isp_valid = 1;
            @(posedge csi_clk);
            timestamp = ideal_us;
            @(negedge csi_clk);
            isp_valid = 0;
        end
    endtask

    task automatic begin_write(input integer slot);
        begin
            repeat (8) @(negedge ddr_clk);
            write_slot = slot[1:0];
            write_start = 1;
            @(negedge ddr_clk);
            write_start = 0;
            write_events = write_events + 1;
        end
    endtask

    task automatic enqueue_words(input integer count);
        begin
            @(negedge ddr_clk);
            write_word = 1;
            repeat (count) @(negedge ddr_clk);
            write_word = 0;
        end
    endtask

    task automatic select_read(input integer slot);
        begin
            @(negedge ddr_clk);
            read_slot = slot[1:0];
            read_start = 1;
            @(negedge ddr_clk);
            read_start = 0;
            read_events = read_events + 1;
            repeat (12) @(negedge hdmi_clk);
        end
    endtask

    task automatic check_display(input [1:0] expected_valid, input integer id,
                                 input integer raw_timestamp, input integer isp_timestamp,
                                 input [8*80-1:0] scenario);
        integer before_count, display_timestamp, expected_total, expected_isp;
        integer total_error, isp_error;
        begin
            before_count = sample_count;
            @(negedge hdmi_clk);
            display_start = 1;
            @(posedge hdmi_clk);
            display_timestamp = ideal_us;
            @(negedge hdmi_clk);
            display_start = 0;
            repeat (20) @(negedge hdmi_clk);
            if (sample_count != before_count + 1)
                $fatal(1, "Missing/duplicate display sample %0s before=%0d after=%0d",
                       scenario, before_count, sample_count);
            if (expected_valid < 2 && last_sample_valid !== expected_valid[0])
                $fatal(1, "Validity mismatch %0s got=%0b expected=%0b id=%0d total=%0d",
                       scenario, last_sample_valid, expected_valid,
                       last_sample_id, last_sample_total);
            checks = checks + 1;
            if (last_sample_valid) begin
                expected_total = display_timestamp - raw_timestamp;
                expected_isp = isp_timestamp - raw_timestamp;
                total_error = last_sample_total - expected_total;
                isp_error = last_sample_isp - expected_isp;
                if (last_sample_id != (id & 1023) ||
                    total_error < -2 || total_error > 2 ||
                    isp_error < -2 || isp_error > 2 ||
                    last_sample_total != last_sample_isp + last_sample_buffer ||
                    last_sample_total > MAX_AGE ||
                    last_sample_isp > last_sample_total)
                    $fatal(1, "Wrong frame/time %0s id=%0d/%0d total=%0d/%0d isp=%0d/%0d buffer=%0d",
                           scenario, last_sample_id, id, last_sample_total,
                           expected_total, last_sample_isp, expected_isp, last_sample_buffer);
                valid_count = valid_count + 1;
            end else begin
                invalid_count = invalid_count + 1;
            end
        end
    endtask

    task automatic complete_frame(input integer slot, output integer id,
                                  output integer raw_timestamp, output integer isp_timestamp);
        begin
            capture_raw(id, raw_timestamp);
            wait_us(5);
            start_isp(id);
            begin_write(slot);
            wait_us(2);
            capture_isp(isp_timestamp);
            repeat (16) @(negedge ddr_clk);
            enqueue_words(WORDS);
            repeat (20) @(negedge ddr_clk);
        end
    endtask

    integer id_a, id_b, id_c;
    integer raw_a, raw_b, raw_c, isp_a, isp_b, isp_c;
    integer ignored_id, ignored_timestamp;
    integer iteration;
    initial begin
        reset_test();
        select_read(0);
        check_display(0, 0, 0, 0, "empty slot after reset");

        // A valid timestamp alone cannot make an incomplete DDR frame valid.
        capture_raw(id_a, raw_a);
        wait_us(6);
        start_isp(id_a);
        begin_write(0);
        wait_us(3);
        capture_isp(isp_a);
        repeat (16) @(negedge ddr_clk);
        enqueue_words(WORDS - 1);
        select_read(0);
        check_display(0, id_a, raw_a, isp_a, "seven of eight accepted DDR words");
        enqueue_words(1);
        check_display(0, id_a, raw_a, isp_a, "completion cannot relabel old read snapshot");
        select_read(0);
        check_display(1, id_a, raw_a, isp_a, "same frame becomes available after completion");
        last_total = last_sample_total;
        wait_us(25);
        select_read(0);
        check_display(1, id_a, raw_a, isp_a, "repeated display retains capture identity");
        if (last_sample_total <= last_total + 20)
            $fatal(1, "Repeated frame age did not increase with elapsed time");
        check_display(0, id_a, raw_a, isp_a, "display requires its own read snapshot");

        // Snapshot the selected slot, then overwrite it before HDMI output.
        complete_frame(1, id_a, raw_a, isp_a);
        select_read(1);
        capture_raw(id_b, raw_b);
        wait_us(4);
        start_isp(id_b);
        begin_write(1);
        capture_isp(isp_b);
        check_display(1, id_a, raw_a, isp_a, "read snapshot survives subsequent slot reuse");
        select_read(1);
        check_display(0, id_b, raw_b, isp_b, "slot reuse immediately invalidates old record");
        enqueue_words(WORDS);
        repeat (20) @(negedge ddr_clk);
        select_read(1);
        check_display(1, id_b, raw_b, isp_b, "reused slot publishes only the new frame");

        // Camera frames may be skipped, and older selected slots may repeat.
        complete_frame(0, id_a, raw_a, isp_a);
        complete_frame(2, id_b, raw_b, isp_b);
        complete_frame(3, id_c, raw_c, isp_c);
        select_read(3);
        check_display(1, id_c, raw_c, isp_c, "faster camera skips intermediate frames");
        select_read(0);
        check_display(1, id_a, raw_a, isp_a, "explicitly selected older frame");
        select_read(2);
        check_display(1, id_b, raw_b, isp_b, "nonsequential slot selection");

        // The write counter restarts on SOF; partial prior frames cannot count.
        capture_raw(id_a, raw_a);
        start_isp(id_a);
        begin_write(2);
        capture_isp(isp_a);
        enqueue_words(WORDS - 2);
        capture_raw(id_b, raw_b);
        wait_us(4);
        start_isp(id_b);
        begin_write(2);
        capture_isp(isp_b);
        repeat (16) @(negedge ddr_clk);
        enqueue_words(2);
        select_read(2);
        check_display(0, id_b, raw_b, isp_b, "new write start resets partial frame count");
        enqueue_words(WORDS - 2);
        select_read(2);
        check_display(1, id_b, raw_b, isp_b, "only current frame words complete the slot");

        // Sampling on the final accepted word must not expose a partial frame.
        capture_raw(id_a, raw_a);
        wait_us(4);
        start_isp(id_a);
        begin_write(2);
        capture_isp(isp_a);
        repeat (16) @(negedge ddr_clk);
        enqueue_words(WORDS - 1);
        @(negedge ddr_clk);
        read_slot = 2; read_start = 1; write_word = 1;
        @(negedge ddr_clk);
        read_start = 0; write_word = 0;
        read_events = read_events + 1;
        repeat (12) @(negedge hdmi_clk);
        check_display(0, id_a, raw_a, isp_a, "read selection coincides with final DDR word");
        select_read(2);
        check_display(1, id_a, raw_a, isp_a, "read after final DDR word");

        // A same-cycle overwrite/read cannot borrow the old valid slot record.
        complete_frame(3, id_a, raw_a, isp_a);
        capture_raw(id_b, raw_b);
        wait_us(4);
        start_isp(id_b);
        repeat (8) @(negedge ddr_clk);
        write_slot = 3; write_start = 1; read_slot = 3; read_start = 1;
        @(negedge ddr_clk);
        write_start = 0; read_start = 0;
        write_events = write_events + 1;
        read_events = read_events + 1;
        capture_isp(isp_b);
        repeat (12) @(negedge hdmi_clk);
        check_display(0, id_b, raw_b, isp_b, "write start and read select share the same slot");
        enqueue_words(WORDS);
        select_read(3);
        check_display(1, id_b, raw_b, isp_b, "new frame completes after simultaneous read/write");

        // Metadata may arrive after the final word, or before slot assignment.
        capture_raw(id_a, raw_a);
        wait_us(4);
        start_isp(id_a);
        begin_write(0);
        enqueue_words(WORDS);
        select_read(0);
        check_display(0, id_a, raw_a, 0, "complete DDR frame still waits for ISP first pixel");
        capture_isp(isp_a);
        repeat (20) @(negedge ddr_clk);
        select_read(0);
        check_display(1, id_a, raw_a, isp_a, "late metadata matches an already complete frame");
        capture_raw_at_sof(id_a, raw_a);
        wait_us(4);
        capture_isp_at_sof(id_a, isp_a);
        begin_write(2);
        enqueue_words(WORDS);
        select_read(2);
        check_display(1, id_a, raw_a, isp_a, "SOF first pixels and metadata before write start");

        // A missing RAW frame cannot borrow a previous capture timestamp.
        @(negedge csi_clk);
        raw_sof = 1;
        #0.1;
        id_a = raw_frame_id;
        @(negedge csi_clk);
        raw_sof = 0;
        wait_us(3);
        start_isp(id_a);
        begin_write(0);
        capture_isp(isp_a);
        enqueue_words(WORDS);
        repeat (20) @(negedge ddr_clk);
        select_read(0);
        check_display(0, id_a, 0, isp_a, "RAW SOF with no actual RAW pixel");

        // Full ID matching protects the four-entry RAW timestamp cache.
        capture_raw(id_a, raw_a);
        repeat (4) capture_raw(ignored_id, ignored_timestamp);
        start_isp(id_a);
        begin_write(0);
        capture_isp(isp_a);
        enqueue_words(WORDS);
        repeat (20) @(negedge ddr_clk);
        select_read(0);
        check_display(0, id_a, raw_a, isp_a, "RAW cache index reused by a different frame ID");

        // The independent time clock must keep aging a stopped camera.
        complete_frame(1, id_a, raw_a, isp_a);
        select_read(1);
        check_display(1, id_a, raw_a, isp_a, "camera running reference");
        last_total = last_sample_total;
        @(negedge csi_clk);
        csi_run = 0;
        wait_us(80);
        select_read(1);
        check_display(1, id_a, raw_a, isp_a, "camera clock stopped while timebase runs");
        if (last_sample_total <= last_total + 75)
            $fatal(1, "Stopping CSI incorrectly stopped latency measurement");
        wait_us(MAX_AGE + 20);
        select_read(1);
        check_display(0, id_a, raw_a, isp_a, "stale frame timeout");
        wait_us(PERIOD);
        select_read(1);
        check_display(0, id_a, raw_a, isp_a, "expired frame cannot revive after timestamp wrap");
        csi_run = 1;

        // Reset cancels selected snapshots and partially written frames.
        complete_frame(3, id_a, raw_a, isp_a);
        @(negedge ddr_clk);
        read_slot = 3;
        read_start = 1;
        @(negedge time_clk);
        reset_test();
        check_display(0, 0, 0, 0, "reset cancels pending read snapshot");
        select_read(3);
        check_display(0, 0, 0, 0, "reset clears stored slot metadata");
        capture_raw(id_a, raw_a);
        start_isp(id_a);
        begin_write(2);
        capture_isp(isp_a);
        enqueue_words(WORDS - 1);
        reset_test();
        enqueue_words(1);
        select_read(2);
        check_display(0, 0, 0, 0, "reset cancels pending metadata and partial word count");

        // Cross a timestamp wrap with a newly completed, still fresh frame.
        wait_us(PERIOD - ideal_us - 15);
        complete_frame(0, id_a, raw_a, isp_a);
        wait_us(18);
        select_read(0);
        check_display(1, id_a, raw_a, isp_a, "fresh frame spans timestamp wrap");

        // Exercise the ten-bit source ID wrap, then verify the full record.
        reset_test();
        for (iteration = 0; iteration < 1026; iteration = iteration + 1)
            capture_raw(ignored_id, ignored_timestamp);
        complete_frame(2, id_a, raw_a, isp_a);
        select_read(2);
        check_display(1, id_a, raw_a, isp_a, "frame ID rollover");
        for (iteration = 0; iteration < 16; iteration = iteration + 1) begin
            case (iteration % 4)
                0: begin csi_half = 4.1; ddr_half = 2.7; hdmi_half = 9.3; end
                1: begin csi_half = 8.3; ddr_half = 4.7; hdmi_half = 5.1; end
                2: begin csi_half = 5.3; ddr_half = 3.1; hdmi_half = 7.7; end
                3: begin csi_half = 6.0; ddr_half = 3.0; hdmi_half = 7.3; end
            endcase
            wait_us((iteration % 4) + 1);
            complete_frame(iteration % 4, id_a, raw_a, isp_a);
            select_read(iteration % 4);
            check_display(1, id_a, raw_a, isp_a, "asynchronous phases and continuous frame turnover");
        end

        // An in-flight old mailbox payload cannot become metadata for a new
        // slot generation, even when the finite source ID has wrapped.
        reset_test();
        capture_raw_at_sof(id_a, raw_a);
        wait_us(3);
        start_isp(id_a);
        begin_write(0);
        enqueue_words(WORDS);
        @(negedge ddr_clk);
        ddr_run = 0;
        capture_isp(isp_a);
        for (iteration = 0; iteration < 1024; iteration = iteration + 1)
            capture_raw_at_sof(id_b, raw_b);
        if (id_b != id_a || raw_b - raw_a >= MAX_AGE)
            $fatal(1, "Stalled old-payload ID-wrap scenario was not constructed correctly");
        start_isp(id_b);
        capture_isp(isp_b);
        write_slot = 0;
        write_start = 1;
        ddr_run = 1;
        @(negedge ddr_clk);
        write_start = 0;
        write_events = write_events + 1;
        enqueue_words(WORDS);
        repeat (20) @(negedge ddr_clk);
        select_read(0);
        // A busy mailbox may drop the new sample; a valid result must still
        // contain the new frame's timestamps, never the older same-ID frame.
        check_display(2, id_b, raw_b, isp_b, "late same-ID metadata after slot generation reuse");

        if (checks < 48 || valid_count < 32 || invalid_count < 15 || wrap_events < 2)
            $fatal(1, "Incomplete latency coverage checks=%0d valid=%0d invalid=%0d wraps=%0d",
                   checks, valid_count, invalid_count, wrap_events);
        $display("VIDEO_LATENCY_MONITOR_PASS samples=%0d checks=%0d valid=%0d invalid=%0d raw=%0d writes=%0d reads=%0d id_wraps=%0d tolerance_us=2",
                 sample_count, checks, valid_count, invalid_count,
                 raw_events, write_events, read_events, wrap_events);
        $finish;
    end

    initial begin
        #3000000;
        $fatal(1, "Video latency regression timed out");
    end
endmodule
