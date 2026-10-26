`timescale 1ns/1ps
// Independent colour-ratio/reference-pixel checks for the frame AWB.
// The small frame has 65 beats, so its final beat is also a sample point.
module tb_awb_frame_adaptation;
    localparam integer WIDTH = 20, HEIGHT = 13, BEATS = 65;
    localparam integer VIDEO_LATENCY = 54;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg valid = 0, user = 0, last = 0, ready = 1;
    reg [95:0] data = 0;
    wire out_valid, out_user, out_last, in_ready;
    wire [95:0] out_data;
    awb #(.IMG_WIDTH(WIDTH), .IMG_HEIGHT(HEIGHT)) dut (
        .I_clk(clk), .I_rst_n(rst_n), .I_tlast(last), .I_tuser(user),
        .I_tdata(data), .I_tvalid(valid), .I_tready(in_ready),
        .O_tlast(out_last), .O_tuser(out_user), .O_tdata(out_data),
        .O_tvalid(out_valid), .O_tready(ready), .I_hold(1'b0)
    );

    reg large_valid = 0, large_user = 0, large_last = 0;
    reg [95:0] large_data = 0;
    wire large_out_valid, large_out_user, large_out_last;
    wire [95:0] large_out_data;
    awb #(.IMG_WIDTH(1280), .IMG_HEIGHT(720)) full720p (
        .I_clk(clk), .I_rst_n(rst_n), .I_tlast(large_last),
        .I_tuser(large_user), .I_tdata(large_data), .I_tvalid(large_valid),
        .I_tready(), .O_tlast(large_out_last), .O_tuser(large_out_user),
        .O_tdata(large_out_data), .O_tvalid(large_out_valid),
        .O_tready(1'b1), .I_hold(1'b0)
    );

    integer expected_r = 256, expected_b = 256;
    integer pending_r = 256, pending_b = 256;
    bit expected_pending = 0;
    integer frames = 0, pixel_checks = 0, large_beats = 0;
    integer pending_checks = 0, hold_checks = 0, resets = 0;
    integer line_checks = 0, adjacent_lines = 0, invalid_last_inputs = 0;
    integer large_lines = 0, large_adjacent_lines = 0;
    reg [VIDEO_LATENCY-1:0] ref_valid = 0, large_ref_valid = 0;
    reg [VIDEO_LATENCY-1:0] ref_last = 0, large_ref_last = 0;
    reg [95:0] ref_data [0:VIDEO_LATENCY-1];
    reg [95:0] large_ref_data [0:VIDEO_LATENCY-1];
    reg [10:0] previous_gain_r = 256, previous_gain_b = 256;
    reg previous_last = 0, large_previous_last = 0;
    reg sampled_user;
    integer reference_stage;

    function automatic integer smooth(input integer current, input integer target);
        smooth = target >= current ?
            current + (target-current+7)/8 :
            current - (current-target+7)/8;
    endfunction
    function automatic [95:0] rgb4(input integer r, input integer g, input integer b);
        rgb4 = {4{{r[7:0], g[7:0], b[7:0]}}};
    endfunction
    function automatic [95:0] corrected(
        input [95:0] original, input integer red_gain, input integer blue_gain
    );
        integer lane, r, b;
        begin
            for (lane = 0; lane < 4; lane = lane+1) begin
                r = original[lane*24+16 +: 8] * red_gain / 256;
                b = original[lane*24 +: 8] * blue_gain / 256;
                corrected[lane*24+16 +: 8] = r > 255 ? 255 : r;
                corrected[lane*24+8 +: 8] = original[lane*24+8 +: 8];
                corrected[lane*24 +: 8] = b > 255 ? 255 : b;
            end
        end
    endfunction

    always @(posedge clk) begin
        sampled_user = user;
        if (!rst_n) begin
            ref_valid = 0; large_ref_valid = 0;
            ref_last = 0; large_ref_last = 0;
            for (reference_stage=0; reference_stage<VIDEO_LATENCY;
                 reference_stage=reference_stage+1) begin
                ref_data[reference_stage] = 0;
                large_ref_data[reference_stage] = 0;
            end
            previous_gain_r = 256; previous_gain_b = 256;
        end else begin
            ref_valid = {ref_valid[VIDEO_LATENCY-2:0], valid};
            large_ref_valid = {large_ref_valid[VIDEO_LATENCY-2:0], large_valid};
            ref_last = {ref_last[VIDEO_LATENCY-2:0], valid && last};
            large_ref_last =
                {large_ref_last[VIDEO_LATENCY-2:0], large_valid && large_last};
            if (!valid && last) invalid_last_inputs = invalid_last_inputs+1;
            for (reference_stage=VIDEO_LATENCY-1; reference_stage>0;
                 reference_stage=reference_stage-1) begin
                ref_data[reference_stage] = ref_data[reference_stage-1];
                large_ref_data[reference_stage] = large_ref_data[reference_stage-1];
            end
            ref_data[0] = corrected(data, expected_r, expected_b);
            large_ref_data[0] = large_data; // First 720p frame uses unity gain.
        end
        #1;
        if (out_valid !== ref_valid[VIDEO_LATENCY-1] || out_user !== user ||
            out_last !== ref_last[VIDEO_LATENCY-1] || in_ready !== ready)
            $fatal(1, "AWB stream markers/latency mismatch at %0t", $time);
        if (out_data !== (ref_valid[VIDEO_LATENCY-1] ?
                         ref_data[VIDEO_LATENCY-1] : 96'd0))
            $fatal(1, "AWB pixel mismatch at %0t got=%h expected=%h gains=%0d,%0d",
                   $time, out_data, ref_data[VIDEO_LATENCY-1], expected_r, expected_b);
        if (ref_valid[VIDEO_LATENCY-1]) pixel_checks = pixel_checks + 4;
        if (out_last) line_checks = line_checks+1;
        if (previous_last && out_valid) adjacent_lines = adjacent_lines+1;
        previous_last = rst_n && out_last;
        if (rst_n) begin
            if (!sampled_user &&
                (dut.gain_r_q8 !== previous_gain_r ||
                 dut.gain_b_q8 !== previous_gain_b))
                $fatal(1, "AWB gain changed inside a frame");
            if (dut.gain_r_q8 !== expected_r || dut.gain_b_q8 !== expected_b)
                $fatal(1, "AWB frame gain mismatch got=%0d,%0d expected=%0d,%0d",
                    dut.gain_r_q8, dut.gain_b_q8, expected_r, expected_b);
            previous_gain_r = dut.gain_r_q8;
            previous_gain_b = dut.gain_b_q8;
        end
        if (large_out_valid !== large_ref_valid[VIDEO_LATENCY-1] ||
            large_out_user !== large_user ||
            large_out_last !== large_ref_last[VIDEO_LATENCY-1])
            $fatal(1, "720p stream marker mismatch");
        if (large_out_data !== (large_ref_valid[VIDEO_LATENCY-1] ?
                               large_ref_data[VIDEO_LATENCY-1] : 96'd0))
            $fatal(1, "720p data mismatch");
        if (large_ref_valid[VIDEO_LATENCY-1]) large_beats = large_beats+1;
        if (large_out_last) large_lines = large_lines+1;
        if (large_previous_last && large_out_valid)
            large_adjacent_lines = large_adjacent_lines+1;
        large_previous_last = rst_n && large_out_last;
    end

    task automatic tick(
        input bit v, input bit u, input [95:0] pixels, input bit l = 0
    );
        @(negedge clk);
        valid = v; user = u; data = pixels; last = l;
        // Ready remains a pass-through, as in the non-stallable original.
        ready = ~ready;
        @(posedge clk); #2;
    endtask
    task automatic idle(input integer cycles);
        integer i;
        for (i=0; i<cycles; i=i+1) tick(0, 0, 0);
    endtask
    task automatic consume_expected;
        if (expected_pending) begin
            expected_r = smooth(expected_r, pending_r);
            expected_b = smooth(expected_b, pending_b);
            expected_pending = 0;
        end
    endtask
    task automatic check_candidate(
        input bit qualifies, input integer target_r, input integer target_b
    );
        idle(90);
        if (dut.pending_ready !== qualifies)
            $fatal(1, "Unexpected candidate status expected=%b got=%b",
                qualifies, dut.pending_ready);
        if (qualifies) begin
            if (dut.pending_r_q8 !== target_r || dut.pending_b_q8 !== target_b)
                $fatal(1, "Wrong divider ratio got=%0d,%0d expected=%0d,%0d",
                    dut.pending_r_q8, dut.pending_b_q8, target_r, target_b);
            pending_r = target_r; pending_b = target_b;
            expected_pending = 1;
            pending_checks = pending_checks+1;
        end else hold_checks = hold_checks+1;
    endtask
    task automatic uniform_frame(
        input integer r, input integer g, input integer b,
        input bit qualifies, input bit early_marker = 0
    );
        integer i;
        consume_expected();
        if (early_marker) tick(0, 1, 0);
        for (i=0; i<BEATS; i=i+1) begin
            tick(1, i==0 && !early_marker, rgb4(r,g,b), i%5==4);
            if (i%5==4) idle(2);
        end
        frames = frames+1;
        check_candidate(qualifies, qualifies ? g*256/r : 256,
                         qualifies ? g*256/b : 256);
    endtask
    task automatic explicit_line_frame(input bit adjacent_tail_only);
        integer beat, lines_before, adjacent_before, invalid_before;
        begin
            consume_expected();
            lines_before = line_checks;
            adjacent_before = adjacent_lines;
            invalid_before = invalid_last_inputs;
            for (beat=0; beat<BEATS; beat=beat+1) begin
                tick(1,beat==0,rgb4(120,100,80),beat%5==4);
                if (beat%5==4 && adjacent_tail_only &&
                    beat/5<HEIGHT-2) begin
                    // Last is undefined while invalid; it must not leak out.
                    tick(0,0,96'hfedcba987654321001234567,1);
                    tick(0,0,0,1);
                end
            end
            frames=frames+1;
            check_candidate(1,213,320);
            if (line_checks-lines_before != HEIGHT ||
                adjacent_lines-adjacent_before !=
                    (adjacent_tail_only ? 1 : HEIGHT-1))
                $fatal(1,"Explicit line markers lost across adjacent rows");
            if (adjacent_tail_only && invalid_last_inputs==invalid_before)
                $fatal(1,"Invalid-cycle line-marker coverage was not exercised");
        end
    endtask
    task automatic reset_all;
        @(negedge clk);
        rst_n = 0;
        valid = 0; user = 0; last = 0;
        large_valid = 0; large_user = 0; large_last = 0;
        expected_r = 256; expected_b = 256; expected_pending = 0;
        repeat (3) begin @(posedge clk); #2; end
        @(negedge clk); rst_n = 1;
        resets = resets+1;
    endtask

    integer i, f;
    reg [95:0] varied;
    initial begin
        reset_all();

        // Different lane values, full-range saturation and arbitrary bubbles.
        for (i=0; i<40; i=i+1) begin
            varied = {24'hff00ff, 24'h0180fe, 24'h705030, 24'h00ff00} ^
                     (96'h010204081020408001020408 * i);
            tick(i%5!=2, i==0, varied, i%7==6);
        end
        idle(90);
        // The random truncated frame must not generate an update.
        if (dut.pending_ready) $fatal(1, "A truncated random frame updated AWB");

        // Explicit row markers must survive fully packed rows and the real
        // demosaic pattern where only the final two rows are contiguous.
        reset_all();
        explicit_line_frame(0);
        explicit_line_frame(1);

        reset_all();
        // Warm and cool illumination converge to the known channel ratios.
        for (f=0; f<40; f=f+1) uniform_frame(150,100,80,1,f%2);
        consume_expected(); tick(0,1,0); idle(3);
        if (expected_r != 170 || expected_b != 320)
            $fatal(1, "Warm neutral scene did not converge");
        for (f=0; f<48; f=f+1) uniform_frame(80,100,150,1,f%2);
        consume_expected(); tick(0,1,0); idle(3);
        if (expected_r != 320 || expected_b != 170)
            $fatal(1, "Cool neutral scene did not converge");

        // Dominant red, black, clipped white and pink must retain white balance.
        uniform_frame(200,45,35,0);
        uniform_frame(0,0,0,0);
        uniform_frame(18,20,16,0);
        uniform_frame(255,255,255,0);
        uniform_frame(255,160,200,0);
        uniform_frame(180,100,100,0); // Pale red is outside neutral tolerance.

        // Three neutral samples are insufficient; a fourth on the final
        // beat completes a valid statistic and must be included.
        consume_expected();
        for (i=0; i<BEATS; i=i+1)
            tick(1,i==0, i==0 || i==16 || i==32 ?
                 rgb4(100,70,60) : rgb4(200,45,35), i%5==4);
        frames=frames+1; check_candidate(0,256,256);
        consume_expected();
        for (i=0; i<BEATS; i=i+1)
            tick(1,i==0, i==0 || i==16 || i==32 || i==64 ?
                 rgb4(100,70,60) : rgb4(200,45,35), i%5==4);
        frames=frames+1; check_candidate(1,179,298);
        if (dut.sample_count != 4)
            $fatal(1, "Last valid beat was omitted from statistics");

        // The five sampled positions select lane0,1,2,3,0. Their known sums
        // are R=600, G=500, B=510; using only lane0 gives a different ratio.
        consume_expected();
        for (i=0; i<BEATS; i=i+1)
            tick(1,i==0,{24'h646464,24'h506496,24'h786464,24'h966450});
        frames=frames+1; check_candidate(1,213,250);

        // Consume the prior complete frame result, then truncate a new one.
        consume_expected();
        for (i=0; i<25; i=i+1) tick(1,i==0,rgb4(150,100,80));
        uniform_frame(200,45,35,0);

        // Exercise saturation with a non-unity gain and four different lanes.
        for (i=0; i<40; i=i+1) begin
            varied = {24'hff40ff,24'hfc80fd,24'h808080,24'hfe00ff};
            tick(i%4!=2,i==0,varied);
        end
        idle(90);

        // The AWB arithmetic and delayed pixels also survive adjacent input
        // frames. The complete camera/DDR path requires vertical blanking
        // because its SOF is an early reset token, not a delayed pixel tag.
        reset_all();
        for (f=0; f<4; f=f+1) begin
            if (f==3) begin
                expected_r=smooth(256,170);
                expected_b=smooth(256,320);
            end
            for (i=0; i<BEATS; i=i+1)
                tick(1,i==0,f==1 ? rgb4(80,100,150) :
                     f==2 ? rgb4(140,100,80) : rgb4(150,100,80),i%5==4);
            frames=frames+1;
        end
        // With statistics pipelined, frame2's completed sums launch just
        // after frame3 SOF consumes frame0's pending result. The calculation
        // must use frame2 (140,100,80), never frame3's newly reset sums.
        check_candidate(1,182,320);

        // Reset while valid and while a colour calculation is pending.
        consume_expected();
        for (i=0; i<20; i=i+1) tick(1,i==0,rgb4(80,100,150));
        reset_all();
        idle(100);
        if (dut.pending_ready || dut.div_state != 0)
            $fatal(1, "Reset retained a stale gain calculation");

        // Full 1280x720 frame: 230400 valid beats and 14400 sparse samples.
        @(negedge clk); large_user=1; large_valid=0;
        @(posedge clk); #2;
        for (i=0; i<230400; i=i+1) begin
            @(negedge clk);
            large_user=0; large_valid=1;
            large_data=rgb4(120,100,80); large_last=i%320==319;
            @(posedge clk); #2;
            if (i%320==319 && i/320<718) begin
                @(negedge clk); large_valid=0; large_last=1;
                repeat (3) begin @(posedge clk); #2; end
            end
        end
        @(negedge clk); large_valid=0; large_last=0;
        idle(100);
        if (large_beats != 230400 || large_lines != 720 ||
            large_adjacent_lines != 1 || full720p.sample_count != 14400 ||
            !full720p.pending_ready ||
            full720p.pending_r_q8 != 213 || full720p.pending_b_q8 != 320)
            $fatal(1, "720p frame/statistics mismatch beats=%0d samples=%0d",
                   large_beats,full720p.sample_count);
        $display("AWB_FRAME_ADAPTATION_PASS frames=%0d pixels=%0d full720p_beats=%0d candidates=%0d holds=%0d resets=%0d lines=%0d adjacent=%0d invalid_last=%0d full720p_lines=%0d full720p_adjacent=%0d",
                 frames,pixel_checks,large_beats,pending_checks,hold_checks,resets,
                 line_checks,adjacent_lines,invalid_last_inputs,
                 large_lines,large_adjacent_lines);
        $finish;
    end
    initial begin
        #20000000;
        $fatal(1,"AWB regression timeout");
    end
endmodule
