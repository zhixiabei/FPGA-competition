// Equivalence check: active CNN datapath vs address-generation rework.
//
// Both engines are driven by the identical AXI4-Stream stimulus and every
// affected internal signal is compared on every rising edge:
//
//   * the read/capture pointers  (input_rd_addr, conv1_rd_addr, input_wr_addr)
//   * the weight/bias pointers   (w1_addr, w2_addr, wf_addr)
//   * the tap operands           (c1_in_data, c2_in_data)
//   * the loop state             (c1_oc/x/y/k, c2_oc/x/y/k, acc)
//   * the published results      (O_class, O_result_valid, O_busy, O_overrun)
//
// Comparing the pointers rather than only the class makes the check sensitive
// to any address-generation drift, not just to drift that flips the argmax.
module tb_cnn_infer_32;
    localparam integer IMG_W  = 1280;
    localparam integer IMG_H  = 720;
    localparam integer BEATS  = IMG_W/4;
    localparam integer NFRAMES = 12;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg tuser = 1'b0, tlast = 1'b0, tvalid = 1'b0;
    reg [95:0] tdata = 96'd0;

    wire        ref_rv, ref_busy, ref_ovr;
    wire [2:0]  ref_class;
    wire        opt_rv, opt_busy, opt_ovr;
    wire [2:0]  opt_class;

    cnn_infer_32 u_ref (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_tuser(tuser), .I_tlast(tlast), .I_tvalid(tvalid), .I_tdata(tdata),
        .O_result_valid(ref_rv), .O_class(ref_class),
        .O_busy(ref_busy), .O_overrun(ref_ovr)
    );

    cnn_infer_32_opt u_opt (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_tuser(tuser), .I_tlast(tlast), .I_tvalid(tvalid), .I_tdata(tdata),
        .O_result_valid(opt_rv), .O_class(opt_class),
        .O_busy(opt_busy), .O_overrun(opt_ovr)
    );

    // 103.52 MHz, same period as the MIPI byte clock in the build.
    always #4.83 clk = ~clk;

    integer errors = 0;
    integer checks = 0;
    integer results = 0;
    integer wr_pulses = 0;
    integer c1_writes = 0;
    integer c2_results = 0;
    integer dropped_frames = 0;
    integer early_sof_frames = 0;
    integer malformed_frames = 0;
    integer unknown_hits = 0;
    integer i;

    task fail(input [255:0] what, input [31:0] a, input [31:0] b);
        begin
            errors = errors + 1;
            if (errors <= 20)
                $display("MISMATCH @%0t %0s ref=%0d opt=%0d", $time, what, a, b);
        end
    endtask

    always @(posedge clk) if (rst_n && u_ref.input_wr_valid) wr_pulses = wr_pulses + 1;

    // Uninitialised RAM is legal while idle. Unknowns are errors whenever an
    // operand is actually consumed by a convolution, FC, or capture write.
    always @(posedge clk) begin
        if (rst_n) begin
            if ((u_ref.state == 1 && u_ref.c1_rd_valid &&
                 $isunknown({u_ref.c1_in_data,u_ref.c1_weight_rd,u_ref.c1_sum_next})) ||
                (u_opt.state == 1 && u_opt.c1_rd_valid &&
                 $isunknown({u_opt.c1_in_data,u_opt.c1_weight_rd,u_opt.c1_sum_next}))) begin
                unknown_hits = unknown_hits + 1;
                fail("unknown consumed C1", 1, 0);
            end
            if ((u_ref.state == 2 && u_ref.c2_rd_valid &&
                 $isunknown({u_ref.c2_in_data,u_ref.c2_weight_rd,u_ref.c2_product})) ||
                (u_opt.state == 2 && u_opt.c2_rd_valid &&
                 $isunknown({u_opt.c2_in_data,u_opt.c2_weight_rd,u_opt.c2_product})) ||
                (u_ref.state == 2 && u_ref.c2_pipe_valid &&
                 $isunknown(u_ref.c2_pipe_sum_next)) ||
                (u_opt.state == 2 && u_opt.c2_pipe_valid &&
                 $isunknown(u_opt.c2_pipe_sum_next))) begin
                unknown_hits = unknown_hits + 1;
                fail("unknown consumed C2", 1, 0);
            end
            if ((u_ref.state == 3 && $isunknown(u_ref.fc_sum_next)) ||
                (u_opt.state == 3 && $isunknown(u_opt.fc_sum_next))) begin
                unknown_hits = unknown_hits + 1;
                fail("unknown consumed FC", 1, 0);
            end
            if (u_ref.input_wr_valid &&
                $isunknown({u_ref.input_wr_addr,u_ref.input_wr_data})) begin
                unknown_hits = unknown_hits + 1;
                fail("unknown capture write", 1, 0);
            end
            if (u_ref.conv1_wr_valid) c1_writes = c1_writes + 1;
            if (u_ref.conv2_result_valid) c2_results = c2_results + 1;
            if (u_ref.capture_drop) dropped_frames = dropped_frames + 1;
            if (u_ref.input_wr_valid && ref_busy && u_ref.capture_buf == u_ref.infer_buf)
                fail("capture overwrote inference bank", u_ref.capture_buf, u_ref.infer_buf);
        end
    end

    // ---------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n) begin
            checks = checks + 1;

            if (u_ref.input_rd_addr  !== u_opt.input_rd_addr)
                fail("input_rd_addr", u_ref.input_rd_addr, u_opt.input_rd_addr);
            if (u_ref.conv1_rd_addr  !== u_opt.conv1_rd_addr)
                fail("conv1_rd_addr", u_ref.conv1_rd_addr, u_opt.conv1_rd_addr);
            // The capture pointer is only meaningful on a sampling beat; off
            // the ROI it is don't-care and the two widths legitimately differ.
            if (u_ref.input_wr_valid !== u_opt.input_wr_valid)
                fail("input_wr_valid", u_ref.input_wr_valid, u_opt.input_wr_valid);
            else if (u_ref.input_wr_valid && u_ref.input_wr_addr !== u_opt.input_wr_addr)
                fail("input_wr_addr", u_ref.input_wr_addr, u_opt.input_wr_addr);
            if (u_ref.input_wr_valid && u_ref.input_wr_data !== u_opt.input_wr_data)
                fail("input_wr_data", u_ref.input_wr_data, u_opt.input_wr_data);

            if (u_ref.w1_addr !== u_opt.w1_addr)
                fail("w1_addr", u_ref.w1_addr, u_opt.w1_addr);
            if (u_ref.w2_addr !== u_opt.w2_addr)
                fail("w2_addr", u_ref.w2_addr, u_opt.w2_addr);
            if (u_ref.wf_addr !== u_opt.wf_addr)
                fail("wf_addr", u_ref.wf_addr, u_opt.wf_addr);
            if (u_ref.b1_addr !== u_opt.b1_addr)
                fail("b1_addr", u_ref.b1_addr, u_opt.b1_addr);
            if (u_ref.b2_addr !== u_opt.b2_addr)
                fail("b2_addr", u_ref.b2_addr, u_opt.b2_addr);
            if (u_ref.bf_addr !== u_opt.bf_addr)
                fail("bf_addr", u_ref.bf_addr, u_opt.bf_addr);

            if (u_ref.c1_rd_valid && u_ref.c1_in_data !== u_opt.c1_in_data)
                fail("c1_in_data", u_ref.c1_in_data, u_opt.c1_in_data);
            if (u_ref.c2_rd_valid && u_ref.c2_in_data !== u_opt.c2_in_data)
                fail("c2_in_data", u_ref.c2_in_data, u_opt.c2_in_data);
            if (u_ref.c1_rd_valid !== u_opt.c1_rd_valid)
                fail("c1_rd_valid", u_ref.c1_rd_valid, u_opt.c1_rd_valid);
            if (u_ref.c2_rd_valid !== u_opt.c2_rd_valid)
                fail("c2_rd_valid", u_ref.c2_rd_valid, u_opt.c2_rd_valid);
            if (u_ref.c2_pipe_valid !== u_opt.c2_pipe_valid)
                fail("c2_pipe_valid", u_ref.c2_pipe_valid, u_opt.c2_pipe_valid);
            if (u_ref.conv1_wr_valid !== u_opt.conv1_wr_valid)
                fail("conv1_wr_valid", u_ref.conv1_wr_valid, u_opt.conv1_wr_valid);
            if (u_ref.conv1_wr_valid &&
                {u_ref.conv1_wr_addr,u_ref.conv1_wr_data} !==
                {u_opt.conv1_wr_addr,u_opt.conv1_wr_data})
                fail("conv1 write", {u_ref.conv1_wr_addr,u_ref.conv1_wr_data},
                     {u_opt.conv1_wr_addr,u_opt.conv1_wr_data});
            if (u_ref.conv2_result_valid !== u_opt.conv2_result_valid)
                fail("conv2_result_valid", u_ref.conv2_result_valid, u_opt.conv2_result_valid);
            if (u_ref.conv2_result_valid &&
                {u_ref.conv2_result_addr,u_ref.conv2_result_data} !==
                {u_opt.conv2_result_addr,u_opt.conv2_result_data})
                fail("conv2 result", {u_ref.conv2_result_addr,u_ref.conv2_result_data},
                     {u_opt.conv2_result_addr,u_opt.conv2_result_data});
            if (u_ref.capture_frame_enabled !== u_opt.capture_frame_enabled)
                fail("capture_frame_enabled", u_ref.capture_frame_enabled, u_opt.capture_frame_enabled);
            if (u_ref.capture_frame_bad !== u_opt.capture_frame_bad)
                fail("capture_frame_bad", u_ref.capture_frame_bad, u_opt.capture_frame_bad);
            if (u_ref.capture_drop !== u_opt.capture_drop)
                fail("capture_drop", u_ref.capture_drop, u_opt.capture_drop);

            if (u_ref.state !== u_opt.state)
                fail("state", u_ref.state, u_opt.state);
            if (u_ref.c1_oc !== u_opt.c1_oc) fail("c1_oc", u_ref.c1_oc, u_opt.c1_oc);
            if (u_ref.c1_x  !== u_opt.c1_x ) fail("c1_x",  u_ref.c1_x,  u_opt.c1_x);
            if (u_ref.c1_y  !== u_opt.c1_y ) fail("c1_y",  u_ref.c1_y,  u_opt.c1_y);
            if (u_ref.c1_k  !== u_opt.c1_k ) fail("c1_k",  u_ref.c1_k,  u_opt.c1_k);
            if (u_ref.c2_oc !== u_opt.c2_oc) fail("c2_oc", u_ref.c2_oc, u_opt.c2_oc);
            if (u_ref.c2_x  !== u_opt.c2_x ) fail("c2_x",  u_ref.c2_x,  u_opt.c2_x);
            if (u_ref.c2_y  !== u_opt.c2_y ) fail("c2_y",  u_ref.c2_y,  u_opt.c2_y);
            if (u_ref.c2_k  !== u_opt.c2_k ) fail("c2_k",  u_ref.c2_k,  u_opt.c2_k);
            if (u_ref.acc   !== u_opt.acc  ) fail("acc",   u_ref.acc,   u_opt.acc);

            if (u_ref.O_class        !== u_opt.O_class)        fail("O_class", u_ref.O_class, u_opt.O_class);
            if (u_ref.O_result_valid !== u_opt.O_result_valid) fail("O_result_valid", u_ref.O_result_valid, u_opt.O_result_valid);
            if (u_ref.O_busy         !== u_opt.O_busy)         fail("O_busy", u_ref.O_busy, u_opt.O_busy);
            if (u_ref.O_overrun      !== u_opt.O_overrun)      fail("O_overrun", u_ref.O_overrun, u_opt.O_overrun);
        end
    end

    always @(posedge clk) begin
        if (rst_n && ref_rv) begin
            results = results + 1;
            $display("RESULT %0d @%0t class=%0d (opt class=%0d)",
                     results, $time, ref_class, opt_class);
        end
    end

    // ---------------------------------------------------------------------
    function [23:0] px;
        input integer x, y;
        reg [7:0] r, g, b;
        begin
            r = (x*3  + y*5  + 17) & 255;
            g = (x*7  + y*11 + 40) & 255;
            b = (x*13 + y*17 + 90) & 255;
            px = {r, g, b};
        end
    endfunction

    task drive_frame(input integer frame_index);
        integer y, bx;
        integer line_beats;
        reg early_sof;
        reg malformed;
        reg old_toggle;
        begin
            early_sof = (frame_index % 2) != 0;
            malformed = (frame_index == 2);
            old_toggle = u_ref.frame_toggle;
            if (early_sof) begin
                early_sof_frames = early_sof_frames + 1;
                @(negedge clk);
                tvalid = 1'b0; tuser = 1'b1; tlast = 1'b0; tdata = 0;
                @(posedge clk);
                #1;
                if (u_ref.frame_seen !== 1'b1)
                    fail("early SOF not latched", u_ref.frame_seen, 1);
                @(negedge clk);
                tuser = 1'b0;
                repeat (53) @(negedge clk);
            end
            for (y = 0; y < IMG_H; y = y + 1) begin
                line_beats = (malformed && y == 100) ? BEATS-1 : BEATS;
                for (bx = 0; bx < line_beats; bx = bx + 1) begin
                    @(negedge clk);
                    tvalid = 1'b1;
                    tuser  = (!early_sof && y == 0 && bx == 0);
                    tlast  = (bx == line_beats-1);
                    tdata  = { px(bx*4, y), px(bx*4+1, y),
                               px(bx*4+2, y), px(bx*4+3, y) };
                end
            end
            @(negedge clk);
            tvalid = 1'b0; tuser = 1'b0; tlast = 1'b0; tdata = 96'd0;
            if (malformed) begin
                malformed_frames = malformed_frames + 1;
                if (u_ref.frame_toggle !== old_toggle)
                    fail("malformed frame published", u_ref.frame_toggle, old_toggle);
            end
        end
    endtask

    integer f;
    initial begin
        if ($test$plusargs("dump")) begin
            $dumpfile("tb_cnn_infer_32.vcd");
            $dumpvars(0, tb_cnn_infer_32);
        end

        rst_n = 1'b0;
        repeat (8) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        if (ref_class !== 3'd1 || opt_class !== 3'd1)
            fail("reset class must be NOTHING", ref_class, opt_class);

        for (f = 0; f < NFRAMES; f = f + 1) begin
            drive_frame(f);
            $display("frame %0d done @%0t  (results so far %0d)", f, $time, results);
        end

        // Let any in-flight inference drain.
        repeat (1400000) @(negedge clk);
        if (ref_busy || opt_busy)
            fail("inference did not drain", ref_busy, opt_busy);
        if (dropped_frames == 0) fail("no dropped-frame coverage", 0, 1);
        if (early_sof_frames == 0) fail("no early-SOF coverage", 0, 1);
        if (malformed_frames == 0) fail("no malformed-frame coverage", 0, 1);
        if (c1_writes != results*8192) fail("C1 result count", c1_writes, results*8192);
        if (c2_results != results*16384) fail("C2 result count", c2_results, results*16384);

        // Final state comparison, including the pooled feature vector.
        for (i = 0; i < 16; i = i + 1) begin
            checks = checks + 1;
            if (u_ref.feat_mem[i] !== u_opt.feat_mem[i])
                fail("feat_mem", u_ref.feat_mem[i], u_opt.feat_mem[i]);
            if (u_ref.pool_sum[i] !== u_opt.pool_sum[i])
                fail("pool_sum", u_ref.pool_sum[i], u_opt.pool_sum[i]);
        end

        $display("-----------------------------------------------");
        $display("feat_mem : %0d %0d %0d %0d %0d %0d %0d %0d", u_ref.feat_mem[0],
                 u_ref.feat_mem[1], u_ref.feat_mem[2], u_ref.feat_mem[3],
                 u_ref.feat_mem[4], u_ref.feat_mem[5], u_ref.feat_mem[6],
                 u_ref.feat_mem[7]);
        $display("           %0d %0d %0d %0d %0d %0d %0d %0d", u_ref.feat_mem[8],
                 u_ref.feat_mem[9], u_ref.feat_mem[10], u_ref.feat_mem[11],
                 u_ref.feat_mem[12], u_ref.feat_mem[13], u_ref.feat_mem[14],
                 u_ref.feat_mem[15]);
        $display("checks      = %0d", checks);
        $display("capture wr  = %0d", wr_pulses);
        $display("C1 writes   = %0d", c1_writes);
        $display("C2 results  = %0d", c2_results);
        $display("frame drops = %0d", dropped_frames);
        $display("early SOF   = %0d", early_sof_frames);
        $display("malformed   = %0d", malformed_frames);
        $display("unknown hit = %0d", unknown_hits);
        $display("results     = %0d", results);
        $display("mismatches  = %0d", errors);
        if (errors == 0 && results > 0)
            $display("CNN_INFER_EQUIV_PASS");
        else if (results == 0)
            $display("CNN_INFER_EQUIV_FAIL no inference completed");
        else
            $display("CNN_INFER_EQUIV_FAIL %0d mismatches", errors);
        $finish;
    end
endmodule
