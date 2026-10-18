`timescale 1ns / 1ps

// Independent tensor reference, exercised with the actual Anlogic ERAM model.
// The vectors come from cnn_fixed_reference.py, not from another RTL engine.
module tb_cnn_fixed_reference;
    localparam integer IMG_W = 256;
    localparam integer IMG_H = 256;
    localparam integer BEATS = IMG_W / 4;
    localparam integer MAX_CYCLES = 4000000;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg tuser = 1'b0;
    reg tlast = 1'b0;
    reg tvalid = 1'b0;
    reg [95:0] tdata = 96'd0;
    wire result_valid, busy, overrun;
    wire [2:0] class_id;

    cnn_infer_32 #(
        .IMG_WIDTH(IMG_W), .IMG_HEIGHT(IMG_H), .ROI_X(0), .ROI_Y(0)
    ) dut (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_tuser(tuser), .I_tlast(tlast), .I_tvalid(tvalid), .I_tdata(tdata),
        .O_result_valid(result_valid), .O_class(class_id),
        .O_busy(busy), .O_overrun(overrun)
    );

    always #5 clk = ~clk;

    reg [7:0] capture0 [0:1023], capture1 [0:1023];
    reg [7:0] c1_0 [0:8191], c1_1 [0:8191];
    reg [7:0] c2_0 [0:16383], c2_1 [0:16383];
    reg [31:0] pool0 [0:15], pool1 [0:15];
    reg [31:0] logits0 [0:4], logits1 [0:4];
    reg [7:0] class0 [0:0], class1 [0:0];
    reg [2047:0] vector_dir;
    reg [2047:0] vector_path;
    integer errors = 0;
    integer checks = 0;
    integer cycles = 0;
    integer results = 0;
    integer expected_sample = 0;
    integer drive_sample = 0;
    integer frame_capture_count = 0;
    integer c1_count = 0;
    integer c2_count = 0;
    integer fc_count = 0;
    integer fast_frames = 0;
    integer dropped_frames = 0;
    integer accepted_frames = 0;
    integer index;
    reg overrun_seen = 1'b0;
    reg reject_inference = 1'b0;
    reg [31:0] expected;

    task fail;
        input [255:0] what;
        input integer addr;
        input [31:0] observed;
        input [31:0] wanted;
        begin
            errors = errors + 1;
            if (errors <= 20)
                $display("MISMATCH sample=%0d %0s[%0d] got=%h expected=%h @%0t",
                         expected_sample, what, addr, observed, wanted, $time);
            if (errors == 20)
                $display("Further mismatch details suppressed.");
        end
    endtask

    // Check only consumed operands; idle RAM outputs may legitimately be X.
    always @(posedge clk) begin
        if (rst_n) begin
            cycles = cycles + 1;
            if (cycles > MAX_CYCLES) begin
                $display("CNN_FIXED_REFERENCE_FAIL timeout results=%0d", results);
                $finish;
            end
            if (overrun === 1'b1)
                overrun_seen = 1'b1;
            if ($isunknown({busy, overrun, result_valid}))
                fail("output controls unknown", cycles, {busy, overrun, result_valid}, 0);
            if (reject_inference &&
                (busy !== 1'b0 || result_valid !== 1'b0 || dut.conv1_wr_valid !== 1'b0))
                fail("malformed frame inferred", cycles, {busy, result_valid, dut.conv1_wr_valid}, 0);

            if (dut.input_wr_valid === 1'b1) begin
                index = dut.input_wr_addr[9:0];
                expected = drive_sample == 0 ? capture0[index] : capture1[index];
                checks = checks + 1;
                if ($isunknown({dut.input_wr_addr, dut.input_wr_data}) ||
                    dut.input_wr_data !== expected[7:0])
                    fail("capture byte", index, dut.input_wr_data, expected);
                if (index != frame_capture_count)
                    fail("capture order", frame_capture_count, index, frame_capture_count);
                // C1 is the only stage reading this bank. A fast camera must
                // never overwrite it while the outstanding inference uses it.
                if (busy && dut.state == 1 &&
                    dut.input_wr_addr[10] == dut.infer_buf)
                    fail("active input bank overwritten", index, dut.input_wr_addr[10],
                         !dut.infer_buf);
                frame_capture_count = frame_capture_count + 1;
            end

            if (dut.conv1_wr_valid === 1'b1) begin
                index = dut.conv1_wr_addr;
                expected = expected_sample == 0 ? c1_0[index] : c1_1[index];
                checks = checks + 1;
                if ($isunknown({dut.conv1_wr_addr, dut.conv1_wr_data}) ||
                    dut.conv1_wr_data !== expected[7:0])
                    fail("conv1 activation", index, dut.conv1_wr_data, expected);
                if (index != c1_count)
                    fail("conv1 order", c1_count, index, c1_count);
                c1_count = c1_count + 1;
            end

            if (dut.conv2_result_valid === 1'b1) begin
                index = dut.conv2_result_addr;
                expected = expected_sample == 0 ? c2_0[index] : c2_1[index];
                checks = checks + 1;
                if ($isunknown({dut.conv2_result_addr, dut.conv2_result_data}) ||
                    dut.conv2_result_data !== expected[7:0])
                    fail("conv2 activation", index, dut.conv2_result_data, expected);
                if (index != c2_count)
                    fail("conv2 order", c2_count, index, c2_count);
                c2_count = c2_count + 1;
            end

            if (dut.state == 3 && dut.fc_k == 15) begin
                index = dut.fc_class;
                expected = expected_sample == 0 ? logits0[index] : logits1[index];
                checks = checks + 1;
                if (dut.fc_sum_next !== expected)
                    fail("FC logit", index, dut.fc_sum_next, expected);
                if (index != fc_count)
                    fail("FC order", fc_count, index, fc_count);
                fc_count = fc_count + 1;
            end

            if (result_valid === 1'b1) begin
                if (c1_count != 8192)
                    fail("conv1 count", 0, c1_count, 8192);
                if (c2_count != 16384)
                    fail("conv2 count", 0, c2_count, 16384);
                if (fc_count != 5)
                    fail("FC count", 0, fc_count, 5);
                for (index = 0; index < 16; index = index + 1) begin
                    expected = expected_sample == 0 ? pool0[index] : pool1[index];
                    checks = checks + 1;
                    if (dut.pool_sum[index] !== expected[16:0])
                        fail("GAP sum", index, dut.pool_sum[index], expected);
                end
                expected = expected_sample == 0 ? class0[0] : class1[0];
                checks = checks + 1;
                if (class_id !== expected[2:0])
                    fail("class", 0, class_id, expected);
                results = results + 1;
                $display("REFERENCE_RESULT sample=%0d class=%0d c1=%0d c2=%0d logits=%0d checks=%0d errors=%0d",
                         expected_sample, class_id, c1_count, c2_count, fc_count, checks, errors);
            end
        end
    end

    function [23:0] pixel;
        input integer x, y, sample_id;
        integer sx, sy;
        reg [7:0] r, g, b;
        begin
            sx = x >> 3;
            sy = y >> 3;
            r = (sx*13 + sy*7 + sample_id*31) & 255;
            g = (sx*3 + sy*17 + sample_id*47) & 255;
            b = (sx*19 + sy*5 + sample_id*61) & 255;
            pixel = {r, g, b};
        end
    endfunction

    task drive_frame;
        input integer sample_id;
        input integer require_capture;
        input integer early_sof;
        integer y, bx;
        begin
            @(negedge clk);
            drive_sample = sample_id;
            frame_capture_count = 0;
            if (early_sof) begin
                // The active AWB path forwards SOF before its delayed pixels.
                tuser = 1'b1;
                tvalid = 1'b0;
                tlast = 1'b0;
                @(negedge clk);
                tuser = 1'b0;
                repeat (54) @(negedge clk);
            end
            for (y = 0; y < IMG_H; y = y + 1) begin
                for (bx = 0; bx < BEATS; bx = bx + 1) begin
                    tvalid = 1'b1;
                    tuser = !early_sof && (y == 0 && bx == 0);
                    tlast = (bx == BEATS-1);
                    tdata = {pixel(bx*4, y, sample_id), pixel(bx*4+1, y, sample_id),
                             pixel(bx*4+2, y, sample_id), pixel(bx*4+3, y, sample_id)};
                    @(negedge clk);
                end
            end
            tvalid = 1'b0;
            tuser = 1'b0;
            tlast = 1'b0;
            tdata = 96'd0;
            if (require_capture && frame_capture_count != 1024)
                fail("required capture count", sample_id, frame_capture_count, 1024);
            if (frame_capture_count != 0 && frame_capture_count != 1024)
                fail("partial captured frame", sample_id, frame_capture_count, 1024);
            if (frame_capture_count == 0)
                dropped_frames = dropped_frames + 1;
            else
                accepted_frames = accepted_frames + 1;
            $display("REFERENCE_FRAME sample=%0d captured=%0d early_sof=%0d busy=%b @%0t",
                     sample_id, frame_capture_count, early_sof, busy, $time);
        end
    endtask

    task drive_malformed_frame;
        input integer short_frame;
        integer y, bx, line_beats, lines;
        reg previous_toggle;
        begin
            @(negedge clk);
            drive_sample = 1;
            frame_capture_count = 0;
            reject_inference = 1'b1;
            previous_toggle = dut.frame_toggle;
            lines = short_frame ? 2 : IMG_H;
            for (y = 0; y < lines; y = y + 1) begin
                // The second line ends early, which must taint the frame even
                // when all remaining lines and the final TLAST are present.
                line_beats = y == 1 ? 16 : BEATS;
                for (bx = 0; bx < line_beats; bx = bx + 1) begin
                    tvalid = 1'b1;
                    tuser = (y == 0 && bx == 0);
                    tlast = (bx == line_beats-1);
                    tdata = {pixel(bx*4, y, 1), pixel(bx*4+1, y, 1),
                             pixel(bx*4+2, y, 1), pixel(bx*4+3, y, 1)};
                    @(negedge clk);
                end
            end
            tvalid = 1'b0;
            tuser = 1'b0;
            tlast = 1'b0;
            tdata = 96'd0;
            repeat (8) @(negedge clk);
            checks = checks + 3;
            if (dut.frame_toggle !== previous_toggle)
                fail("malformed frame published", short_frame, dut.frame_toggle, previous_toggle);
            if (results != 1 || busy !== 1'b0)
                fail("malformed frame result", short_frame, results, 1);
            if (dut.capture_frame_bad !== 1'b1)
                fail("malformed frame not marked", short_frame, dut.capture_frame_bad, 1);
            $display("REFERENCE_REJECT short=%0d captured=%0d busy=%b results=%0d @%0t",
                     short_frame, frame_capture_count, busy, results, $time);
            reject_inference = 1'b0;
        end
    endtask

    initial begin
        if (!$value$plusargs("VECTORS=%s", vector_dir)) begin
            $display("CNN_FIXED_REFERENCE_FAIL missing +VECTORS=directory");
            $finish;
        end
        $sformat(vector_path, "%0s/sample0_capture.hex", vector_dir); $readmemh(vector_path, capture0);
        $sformat(vector_path, "%0s/sample1_capture.hex", vector_dir); $readmemh(vector_path, capture1);
        $sformat(vector_path, "%0s/sample0_c1.hex", vector_dir); $readmemh(vector_path, c1_0);
        $sformat(vector_path, "%0s/sample1_c1.hex", vector_dir); $readmemh(vector_path, c1_1);
        $sformat(vector_path, "%0s/sample0_c2.hex", vector_dir); $readmemh(vector_path, c2_0);
        $sformat(vector_path, "%0s/sample1_c2.hex", vector_dir); $readmemh(vector_path, c2_1);
        $sformat(vector_path, "%0s/sample0_pool.hex", vector_dir); $readmemh(vector_path, pool0);
        $sformat(vector_path, "%0s/sample1_pool.hex", vector_dir); $readmemh(vector_path, pool1);
        $sformat(vector_path, "%0s/sample0_logits.hex", vector_dir); $readmemh(vector_path, logits0);
        $sformat(vector_path, "%0s/sample1_logits.hex", vector_dir); $readmemh(vector_path, logits1);
        $sformat(vector_path, "%0s/sample0_class.hex", vector_dir); $readmemh(vector_path, class0);
        $sformat(vector_path, "%0s/sample1_class.hex", vector_dir); $readmemh(vector_path, class1);

        // GSR releases after 20 ns in the vendor model.
        repeat (12) @(negedge clk);
        rst_n = 1'b1;
        drive_frame(0, 1, 0);
        wait (busy === 1'b1);
        // These extra frames finish before C1 finishes. They must neither
        // corrupt sample0 nor start a second inference while the engine is busy.
        drive_frame(1, 0, 0); fast_frames = fast_frames + 1;
        drive_frame(1, 0, 0); fast_frames = fast_frames + 1;
        drive_frame(1, 0, 0); fast_frames = fast_frames + 1;
        wait (results == 1);
        @(negedge clk);
        if (!overrun_seen)
            fail("overrun not reported", 0, overrun_seen, 1);
        expected_sample = 1;
        c1_count = 0;
        c2_count = 0;
        fc_count = 0;
        // A bad TLAST in a full frame must block publication. A subsequent
        // truncated frame leaves stale row/column state until the next SOF.
        drive_malformed_frame(0);
        drive_malformed_frame(1);
        drive_frame(1, 1, 1);
        wait (results == 2);
        repeat (4) @(negedge clk);
        if (busy !== 1'b0)
            fail("busy after result", 0, busy, 0);
        $display("REFERENCE_COVERAGE samples=2 padding_edges=all kernel_channel_transitions=all early_sof_gap=54 malformed_full=1 truncated=1 fast_frames=%0d accepted=%0d dropped=%0d overrun=%b",
                 fast_frames, accepted_frames, dropped_frames, overrun_seen);
        $display("REFERENCE_TOTAL checks=%0d errors=%0d", checks, errors);
        if (errors == 0)
            $display("CNN_FIXED_REFERENCE_PASS");
        else
            $display("CNN_FIXED_REFERENCE_FAIL mismatches=%0d", errors);
        $finish;
    end
endmodule
