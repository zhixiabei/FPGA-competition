`timescale 1ns/1ps

module tb_awb_confidence;
    localparam integer WIDTH = 64, HEIGHT = 32;
    localparam integer BEATS = WIDTH*HEIGHT/4;
    localparam integer LINE_BEATS = WIDTH/4;
    localparam integer LATENCY = 54;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0, valid = 0, user = 0, last = 0, hold_updates = 0;
    reg ready = 1;
    reg [95:0] data = 0;
    wire in_ready, out_valid, out_user, out_last;
    wire [95:0] out_data;
    wire diag_valid, diag_user, diag_last, diag_candidate_valid, diag_stats_valid;
    wire [95:0] diag_data;
    wire [7:0] diag_clip_new;
    wire [10:0] diag_gain_r, diag_gain_b;
    wire [15:0] diag_sample_count;
    awb #(.IMG_WIDTH(WIDTH), .IMG_HEIGHT(HEIGHT),
          .CONFIDENCE_ENABLE(1), .DIAGNOSTIC_ENABLE(1)) dut (
        .I_clk(clk), .I_rst_n(rst_n), .I_tlast(last), .I_tuser(user),
        .I_tdata(data), .I_tvalid(valid), .I_tready(in_ready),
        .O_tlast(out_last), .O_tuser(out_user), .O_tdata(out_data),
        .O_tvalid(out_valid), .O_tready(ready), .I_hold(hold_updates),
        .O_diag_valid(diag_valid), .O_diag_user(diag_user),
        .O_diag_last(diag_last), .O_diag_data(diag_data),
        .O_diag_clip_new(diag_clip_new), .O_diag_gain_r_q8(diag_gain_r),
        .O_diag_gain_b_q8(diag_gain_b), .O_diag_candidate_valid(diag_candidate_valid),
        .O_diag_stats_valid(diag_stats_valid), .O_diag_sample_count(diag_sample_count)
    );
    reg large_valid = 0, large_user = 0, large_last = 0;
    reg [95:0] large_data = 0;
    wire large_out_valid, large_out_user, large_out_last;
    wire [95:0] large_out_data;
    awb #(.IMG_WIDTH(1280), .IMG_HEIGHT(720),
          .CONFIDENCE_ENABLE(1)) full720p (
        .I_clk(clk), .I_rst_n(rst_n), .I_tlast(large_last),
        .I_tuser(large_user), .I_tdata(large_data), .I_tvalid(large_valid),
        .I_tready(), .O_tlast(large_out_last), .O_tuser(large_out_user),
        .O_tdata(large_out_data), .O_tvalid(large_out_valid),
        .O_tready(1'b1), .I_hold(1'b0)
    );

    reg [LATENCY-1:0] expected_valid = 0, expected_last = 0;
    reg [LATENCY-1:0] large_expected_valid = 0, large_expected_last = 0;
    reg [1:0] expected_diag_user = 0;
    reg [7:0] expected_clip [0:1];
    reg [95:0] expected_data [0:LATENCY-1];
    reg [95:0] large_expected_data [0:LATENCY-1];
    integer expected_r = 256, expected_b = 256;
    integer edge_r, edge_b, stage;
    integer frames = 0, assertions = 0, pixel_checks = 0;
    integer large_pixel_beats = 0, large_line_checks = 0;
    integer committed_frames = 0, held_frames = 0, resets = 0;
    integer diagnostic_clip_pixels = 0;
    integer f, beat, saved_r, saved_b, arithmetic_gain, hold_offset;

    function automatic [95:0] rgb4(input integer r, input integer g, input integer b);
        rgb4 = {4{{r[7:0],g[7:0],b[7:0]}}};
    endfunction
    function automatic [7:0] new_clip(
        input [95:0] pixels,input integer red_gain,input integer blue_gain
    );
        integer lane;
        begin
            for (lane=0;lane<4;lane=lane+1) begin
                new_clip[2*lane+1] = pixels[lane*24+16 +: 8]*red_gain > 65535;
                new_clip[2*lane] = pixels[lane*24 +: 8]*blue_gain > 65535;
            end
        end
    endfunction
    function automatic integer smooth(input integer current, input integer target);
        integer difference;
        begin
            difference = target >= current ? target-current : current-target;
            if (difference <= 2) smooth = current;
            else smooth = target >= current ?
                current + (difference+7)/8 : current - (difference+7)/8;
        end
    endfunction
    function automatic [95:0] corrected(
        input [95:0] pixels, input integer red_gain, input integer blue_gain
    );
        integer lane, red, blue;
        begin
            for (lane=0; lane<4; lane=lane+1) begin
                red = pixels[lane*24+16 +: 8] * red_gain / 256;
                blue = pixels[lane*24 +: 8] * blue_gain / 256;
                corrected[lane*24+16 +: 8] = red > 255 ? 255 : red;
                corrected[lane*24+8 +: 8] = pixels[lane*24+8 +: 8];
                corrected[lane*24 +: 8] = blue > 255 ? 255 : blue;
            end
        end
    endfunction

    // Independent pixel arithmetic and complete stream timing. The ratio
    // targets themselves are checked against known RGB sums in each case.
    always @(posedge clk) begin
        edge_r = expected_r;
        edge_b = expected_b;
        if (!rst_n) begin
            expected_r = 256; expected_b = 256;
            expected_valid = 0; expected_last = 0;
            large_expected_valid = 0; large_expected_last = 0;
            expected_diag_user = 0;
            expected_clip[0] = 0; expected_clip[1] = 0;
            for (stage=0; stage<LATENCY; stage=stage+1) begin
                expected_data[stage] = 0;
                large_expected_data[stage] = 0;
            end
        end else begin
            if (user && dut.pending_ready && !hold_updates) begin
                edge_r = smooth(expected_r,dut.pending_r_q8);
                edge_b = smooth(expected_b,dut.pending_b_q8);
                committed_frames = committed_frames + 1;
            end
            expected_r = edge_r; expected_b = edge_b;
            expected_diag_user = {expected_diag_user[0],user};
            expected_clip[1] = expected_clip[0];
            expected_clip[0] = new_clip(data,edge_r,edge_b);
            expected_valid = {expected_valid[LATENCY-2:0],valid};
            expected_last = {expected_last[LATENCY-2:0],valid && last};
            large_expected_valid =
                {large_expected_valid[LATENCY-2:0],large_valid};
            large_expected_last =
                {large_expected_last[LATENCY-2:0],large_valid && large_last};
            for (stage=LATENCY-1; stage>0; stage=stage-1) begin
                expected_data[stage] = expected_data[stage-1];
                large_expected_data[stage] = large_expected_data[stage-1];
            end
            expected_data[0] = corrected(data,edge_r,edge_b);
            // Both 720p frames precede the first possible confirmed commit.
            large_expected_data[0] = large_data;
        end
        #1;
        if (out_valid !== expected_valid[LATENCY-1] || out_user !== user ||
            out_last !== expected_last[LATENCY-1] || in_ready !== ready)
            $fatal(1,"Confidence video marker/54-clock delay mismatch at %0t",$time);
        if (out_data !== (expected_valid[LATENCY-1] ?
                         expected_data[LATENCY-1] : 96'd0))
            $fatal(1,"Confidence corrected pixel mismatch at %0t",$time);
        if (rst_n && (dut.gain_r_q8 !== expected_r || dut.gain_b_q8 !== expected_b))
            $fatal(1,"Confidence gain commit/deadband mismatch actual=%0d,%0d expected=%0d,%0d",
                   dut.gain_r_q8,dut.gain_b_q8,expected_r,expected_b);
        if (out_valid) pixel_checks = pixel_checks+4;
        if (diag_valid !== expected_valid[1] || diag_user !== expected_diag_user[1] ||
            diag_last !== expected_last[1] ||
            diag_data !== (expected_valid[1] ? expected_data[1] : 96'd0) ||
            diag_clip_new !== (expected_valid[1] ? expected_clip[1] : 8'd0) ||
            diag_gain_r !== dut.gain_r_q8 || diag_gain_b !== dut.gain_b_q8 ||
            diag_candidate_valid !== dut.candidate_valid ||
            diag_stats_valid !== dut.stats_ready ||
            diag_sample_count !== dut.sample_count)
            $fatal(1,"AWB diagnostic 2-clock stream/clip/state mismatch at %0t",$time);
        if (diag_valid && |diag_clip_new)
            diagnostic_clip_pixels = diagnostic_clip_pixels+1;
        if ({full720p.O_diag_valid,full720p.O_diag_user,full720p.O_diag_last,
             full720p.O_diag_data,full720p.O_diag_clip_new,
             full720p.O_diag_gain_r_q8,full720p.O_diag_gain_b_q8,
             full720p.O_diag_candidate_valid,full720p.O_diag_stats_valid,
             full720p.O_diag_sample_count} !== 147'd0)
            $fatal(1,"Disabled AWB diagnostics were not constant zero");
        if (large_out_valid !== large_expected_valid[LATENCY-1] ||
            large_out_last !== large_expected_last[LATENCY-1] ||
            large_out_user !== large_user ||
            large_out_data !== (large_expected_valid[LATENCY-1] ?
                                large_expected_data[LATENCY-1] : 96'd0))
            $fatal(1,"Confidence production 720p video mismatch");
        if (large_out_valid) large_pixel_beats = large_pixel_beats+1;
        if (large_out_last) large_line_checks = large_line_checks+1;
    end

    task automatic tick(input bit v, input bit u, input [95:0] pixels,
                         input bit l = 0, input bit h = 0);
        @(negedge clk);
        valid=v; user=u; data=pixels; last=l; hold_updates=h;
        ready=~ready;
        @(posedge clk); #2;
    endtask
    task automatic idle(input integer cycles, input bit h = 0);
        integer i;
        for (i=0;i<cycles;i=i+1) tick(0,0,0,0,h);
    endtask
    task automatic reset_all;
        @(negedge clk);
        rst_n=0; valid=0; user=0; last=0; hold_updates=0;
        large_valid=0; large_user=0; large_last=0;
        repeat (3) begin @(posedge clk); #2; end
        @(negedge clk); rst_n=1;
        resets=resets+1;
        idle(3);
    endtask
    task automatic check_pending(input bit expected,
                                 input integer red=256,input integer blue=256);
        begin
            idle(100);
            if (dut.pending_ready !== expected)
                $fatal(1,"Confidence candidate ready expected=%b actual=%b frame=%0d",
                       expected,dut.pending_ready,frames);
            if (expected &&
                (dut.pending_r_q8 != red || dut.pending_b_q8 != blue))
                $fatal(1,"Confidence ratio expected=%0d,%0d actual=%0d,%0d",
                       red,blue,dut.pending_r_q8,dut.pending_b_q8);
            if (!expected) held_frames=held_frames+1;
            assertions=assertions+1;
        end
    endtask
    task automatic frame(input integer r,input integer g,input integer b,
                          input integer pattern=0,input bit early_sof=0);
        integer i;
        reg [95:0] pixels;
        bit line_end;
        begin
            if (early_sof) tick(0,1,0);
            for (i=0;i<BEATS;i=i+1) begin
                pixels=pattern==1 && i>=BEATS/2 ? rgb4(200,40,30) : rgb4(r,g,b);
                line_end=i%LINE_BEATS==LINE_BEATS-1;
                if (pattern==2 && i==LINE_BEATS-2) line_end=1;
                if (pattern==3 && i==LINE_BEATS-1) line_end=0;
                tick(1,i==0 && !early_sof,pixels,line_end);
                if (i%LINE_BEATS==LINE_BEATS-1 && i<BEATS-2*LINE_BEATS)
                    tick(0,0,96'hff00ff00ff00ff00ff00ff00,1);
            end
            frames=frames+1;
        end
    endtask
    task automatic warm_ready;
        frame(150,100,80); check_pending(0);
        frame(150,100,80); check_pending(1,170,320);
    endtask

    initial begin
        // Check both signs, rounding and the full 11-bit input range even
        // when an integrator configures gain limits wider than production.
        for (arithmetic_gain=0;arithmetic_gain<2048;arithmetic_gain=arithmetic_gain+1) begin
            if (dut.F_smooth_gain(arithmetic_gain,0) !== smooth(arithmetic_gain,0) ||
                dut.F_smooth_gain(arithmetic_gain,2047) !== smooth(arithmetic_gain,2047) ||
                dut.F_smooth_gain(arithmetic_gain,arithmetic_gain) !== arithmetic_gain)
                $fatal(1,"Signed smoothing arithmetic failed at gain=%0d",arithmetic_gain);
        end
        reset_all();
        warm_ready();
        for (f=0;f<40;f=f+1) begin
            frame(150,100,80,0,f%2); check_pending(1,170,320);
        end
        if (dut.gain_r_q8 < 170 || dut.gain_r_q8 > 172 ||
            dut.gain_b_q8 < 318 || dut.gain_b_q8 > 320)
            $fatal(1,"Warm light failed to converge within gain deadband");

        // Four out-of-track frames return to capture. Two subsequent valid
        // frames confirm the new source; no permanent old-light lock exists.
        for (f=0;f<4;f=f+1) begin
            frame(80,100,150); check_pending(0);
        end
        if (dut.tracking_valid) $fatal(1,"Reacquisition did not leave old track");
        frame(80,100,150); check_pending(0);
        frame(80,100,150); check_pending(1,320,170);
        for (f=0;f<40;f=f+1) begin
            frame(80,100,150,0,f%2); check_pending(1,320,170);
        end
        if (dut.gain_r_q8 < 318 || dut.gain_r_q8 > 320 ||
            dut.gain_b_q8 < 170 || dut.gain_b_q8 > 172)
            $fatal(1,"Cool light failed to converge within gain deadband");
        // Different lanes cross the R threshold independently. Blue stays
        // below the clipping gain, so a swapped channel/lane flag is visible.
        for (beat=0;beat<8;beat=beat+1)
            tick(1,beat==0,{24'hff10ff,24'h10ffff,24'hff1000,24'h00ff00});
        idle(5);

        // Unsupported dominant colours, dark frames and clipped white hold.
        frame(200,45,35); check_pending(0);
        saved_r=dut.gain_r_q8; saved_b=dut.gain_b_q8;
        frame(35,45,200); check_pending(0);
        frame(80,100,80); check_pending(0);
        if (dut.sample_count != dut.MAX_SAMPLES)
            $fatal(1,"Green-wall guard was not exercised after sample admission");
        frame(150,100,150); check_pending(0);
        frame(0,0,0); check_pending(0);
        frame(18,20,16); check_pending(0);
        frame(255,255,255); check_pending(0);
        if (dut.gain_r_q8 != saved_r || dut.gain_b_q8 != saved_b)
            $fatal(1,"Low-confidence colour/black/clipped frames changed gains");

        reset_all();
        // Enough samples in one half alone still fail spatial coverage.
        frame(150,100,80,1); check_pending(0);
        if (dut.sample_count < dut.MIN_SAMPLES ||
            dut.upper_samples != dut.REGION_MIN || dut.lower_samples != 0)
            $fatal(1,"Spatial coverage rejection was not exercised");
        warm_ready();

        // A bad completed frame breaks two-frame confirmation.
        reset_all();
        frame(150,100,80); check_pending(0);
        frame(0,0,0); check_pending(0);
        frame(150,100,80); check_pending(0);
        frame(150,100,80); check_pending(1,170,320);
        frame(150,100,80,2); check_pending(0);
        if (!dut.completed_frame_bad) $fatal(1,"Early line marker was accepted");
        warm_ready();
        frame(150,100,80,3); check_pending(0);
        if (!dut.completed_frame_bad) $fatal(1,"Missing line marker was accepted");
        warm_ready();

        // SOF truncation resets the continuous-frame candidate chain.
        for (beat=0;beat<BEATS/3;beat=beat+1)
            tick(1,beat==0,rgb4(150,100,80),beat%LINE_BEATS==LINE_BEATS-1);
        warm_ready();

        // An extra valid beat invalidates a nominally complete frame even
        // when it occurs before the statistics pipeline reaches its launch.
        frame(150,100,80);
        tick(1,0,rgb4(150,100,80));
        check_pending(0);
        warm_ready();

        // AE hold revokes an already prepared gain before a SOF commit.
        saved_r=dut.gain_r_q8; saved_b=dut.gain_b_q8;
        idle(2,1); tick(0,1,0,0,1); idle(100,1);
        if (dut.pending_ready || dut.candidate_valid || dut.div_state != 0 ||
            dut.gain_r_q8 != saved_r || dut.gain_b_q8 != saved_b)
            $fatal(1,"AE hold failed to cancel prepared candidate");
        idle(2);
        warm_ready();

        // Hold coincident with SOF and the first valid pixel wins over the
        // existing pending candidate for both that pixel and the frame gain.
        saved_r=dut.gain_r_q8; saved_b=dut.gain_b_q8;
        for (beat=0;beat<BEATS;beat=beat+1)
            tick(1,beat==0,rgb4(150,100,80),beat%LINE_BEATS==LINE_BEATS-1,
                 beat==0);
        frames=frames+1; check_pending(0);
        if (dut.gain_r_q8 != saved_r || dut.gain_b_q8 != saved_b)
            $fatal(1,"SOF hold did not protect gain and first-pixel agreement");
        warm_ready();

        // A one-clock hold on the final pixel, and each of the four clocks
        // until statistics launch, must revoke in-flight frame statistics.
        for (hold_offset=0;hold_offset<=4;hold_offset=hold_offset+1) begin
            if (hold_offset==0) begin
                for (beat=0;beat<BEATS;beat=beat+1)
                    tick(1,beat==0,rgb4(150,100,80),
                         beat%LINE_BEATS==LINE_BEATS-1,beat==BEATS-1);
                frames=frames+1;
            end else begin
                frame(150,100,80); idle(hold_offset-1); tick(0,0,0,0,1);
            end
            check_pending(0);
            warm_ready();
        end

        // A hold pulse during a frame invalidates the whole frame even
        // after the enable returns; the next two clean frames recover.
        for (beat=0;beat<BEATS;beat=beat+1)
            tick(1,beat==0,rgb4(150,100,80),beat%LINE_BEATS==LINE_BEATS-1,
                 beat>=BEATS/3 && beat<BEATS/3+3);
        frames=frames+1; check_pending(0);
        warm_ready();

        // Hold in the restoring divider must not leak a stale result.
        frame(150,100,80); idle(10);
        if (dut.div_state == 0) $fatal(1,"Mid-divider hold was not exercised");
        idle(1,1); idle(100);
        if (dut.pending_ready || dut.candidate_valid || dut.div_state != 0)
            $fatal(1,"Mid-divider hold leaked a candidate");
        warm_ready();

        // Gain changes smaller than the configured 2/256 deadband stop.
        reset_all();
        frame(101,100,100); check_pending(0);
        for (f=0;f<8;f=f+1) begin
            frame(101,100,100); check_pending(1,253,256);
        end
        if (dut.gain_r_q8 != 255 || dut.gain_b_q8 != 256)
            $fatal(1,"Gain deadband failed to retain 255,256");

        // Reset with a divider active, then verify no stale commit survives.
        frame(150,100,80); idle(10); reset_all(); idle(100);
        if (dut.pending_ready || dut.candidate_valid || dut.tracking_valid ||
            dut.div_state != 0 || dut.gain_r_q8 != 256 || dut.gain_b_q8 != 256)
            $fatal(1,"Reset retained AWB confidence state");

        // Exact production geometry and CONFIDENCE_ENABLE=1. The early SOF,
        // invalid-cycle line markers, and adjacent final rows match camera.
        for (f=0;f<2;f=f+1) begin
            @(negedge clk);
            large_valid=0; large_user=1; large_last=0;
            @(posedge clk); #2;
            for (beat=0;beat<230400;beat=beat+1) begin
                @(negedge clk);
                large_user=0; large_valid=1; large_data=rgb4(120,100,80);
                large_last=beat%320==319;
                @(posedge clk); #2;
                if (beat%320==319 && beat/320<718) begin
                    @(negedge clk); large_valid=0; large_last=1;
                    repeat (3) begin @(posedge clk); #2; end
                end
            end
            @(negedge clk); large_valid=0; large_last=0;
            idle(100);
            if (full720p.sample_count != 14400 ||
                full720p.completed_frame_bad ||
                full720p.upper_samples != full720p.REGION_MIN ||
                full720p.lower_samples != full720p.REGION_MIN ||
                full720p.pending_ready !== (f==1) ||
                full720p.candidate_valid !== 1'b1 ||
                (f==1 && (full720p.pending_r_q8 != 213 ||
                          full720p.pending_b_q8 != 320)))
                $fatal(1,"Production CONF1 720p statistics mismatch frame=%0d",f);
        end
        if (large_pixel_beats != 460800 || large_line_checks != 1440)
            $fatal(1,"Production CONF1 720p video count mismatch");
        if (diagnostic_clip_pixels == 0)
            $fatal(1,"AWB diagnostic clipping conditions were not exercised");
        $display("AWB_CONFIDENCE_PASS frames=%0d checks=%0d pixels=%0d commits=%0d held=%0d resets=%0d full720p_frames=2 full720p_beats=%0d full720p_lines=%0d diagnostic_clip_beats=%0d capture_track_reacquire=1 hold_midframe_divider_commit=1 invalid_lines_truncate_overrun=1",
                 frames,assertions,pixel_checks,committed_frames,held_frames,resets,
                 large_pixel_beats,large_line_checks,diagnostic_clip_pixels);
        $finish;
    end
    initial begin
        #20000000;
        $fatal(1,"AWB confidence regression timeout");
    end
endmodule
