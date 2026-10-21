`timescale 1ns/1ps

module awb_width_case #(
    parameter integer CASE_ID = 0,
    parameter integer WIDTH = 1280,
    parameter integer HEIGHT = 720,
    parameter integer SAMPLE_LOG2 = 4
) (output reg done);
    localparam integer BEATS = (WIDTH*HEIGHT+3)/4;
    localparam integer MAX_SAMPLES =
        (BEATS+(1<<SAMPLE_LOG2)-1) >> SAMPLE_LOG2;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0, valid = 0, user = 0, last = 0, ready = 0;
    reg [95:0] data = 0;
    wire [95:0] actual_data, baseline_data;
    wire actual_valid, baseline_valid, actual_user, baseline_user;
    wire actual_last, baseline_last, actual_ready, baseline_ready;
    integer checks = 0, full_frames = 0, upper_bound_checks = 0;
    reg [31:0] random_state = 32'h9e3779b9 ^ CASE_ID;
    awb #(.IMG_WIDTH(WIDTH), .IMG_HEIGHT(HEIGHT), .SAMPLE_LOG2(SAMPLE_LOG2)) dut (
        .I_clk(clk), .I_rst_n(rst_n), .I_tvalid(valid), .I_tuser(user),
        .I_tlast(last), .I_tdata(data), .I_tready(actual_ready),
        .O_tvalid(actual_valid), .O_tuser(actual_user), .O_tlast(actual_last),
        .O_tdata(actual_data), .O_tready(ready)
    );
    awb_baseline #(.IMG_WIDTH(WIDTH), .IMG_HEIGHT(HEIGHT),
                   .SAMPLE_LOG2(SAMPLE_LOG2)) reference (
        .I_clk(clk), .I_rst_n(rst_n), .I_tvalid(valid), .I_tuser(user),
        .I_tlast(last), .I_tdata(data), .I_tready(baseline_ready),
        .O_tvalid(baseline_valid), .O_tuser(baseline_user), .O_tlast(baseline_last),
        .O_tdata(baseline_data), .O_tready(ready)
    );
    always @(posedge clk) begin
        #1;
        if ({actual_ready,actual_valid,actual_user,actual_last,actual_data} !==
            {baseline_ready,baseline_valid,baseline_user,baseline_last,baseline_data})
            $fatal(1,"AWB width output mismatch case=%0d check=%0d",CASE_ID,checks);
        if (dut.sum_r !== reference.sum_r || dut.sum_g !== reference.sum_g ||
            dut.sum_b !== reference.sum_b ||
            dut.sample_count !== reference.sample_count ||
            dut.div_state !== reference.div_state ||
            dut.div_bit_count !== reference.div_bit_count ||
            dut.div_quotient !== reference.div_quotient ||
            dut.div_remainder !== reference.div_remainder ||
            dut.div_denominator !== reference.div_denominator ||
            dut.div_green_sum !== reference.div_green_sum ||
            dut.div_blue_denominator !== reference.div_blue_denominator ||
            dut.div_red_result !== reference.div_red_result ||
            {dut.gain_r_q8,dut.gain_b_q8,dut.pending_r_q8,
             dut.pending_b_q8,dut.pending_ready} !==
            {reference.gain_r_q8,reference.gain_b_q8,reference.pending_r_q8,
             reference.pending_b_q8,reference.pending_ready})
            $fatal(1,"AWB width state mismatch case=%0d check=%0d count=%0d/%0d sum=%0d/%0d",
                   CASE_ID,checks,dut.sample_count,reference.sample_count,
                   dut.sum_r,reference.sum_r);
        checks = checks+1;
    end
    task automatic tick(input bit v, input bit u, input [95:0] rgb);
        @(negedge clk);
        valid = v; user = u; data = rgb;
        random_state = (random_state << 1) ^
            (random_state[31] ? 32'h04c11db7 : 0);
        last = random_state[3]; ready = random_state[7];
        @(posedge clk); #2;
    endtask
    task automatic idle(input integer count);
        integer i;
        for (i=0;i<count;i=i+1) tick(0,0,96'd0);
    endtask
    task automatic frame(input integer pattern, input bit early_sof,
                          input bit bubbles);
        integer beat, lane, red, green, blue;
        reg [95:0] rgb;
        begin
            if (early_sof) tick(0,1,0);
            for (beat=0;beat<BEATS;beat=beat+1) begin
                for (lane=0;lane<4;lane=lane+1) begin
                    case (pattern)
                        0: rgb[lane*24+:24] = 24'hdcdcdc;
                        1: rgb[lane*24+:24] = 24'h6edc6e;
                        2: rgb[lane*24+:24] = 24'hdc6edc;
                        3: rgb[lane*24+:24] = 24'hff00ff;
                        default: begin
                            red = 80+((beat+lane*31)%80);
                            green = 100+((beat+lane*7)%40);
                            blue = 80+((beat+lane*13)%80);
                            rgb[lane*24+:24] = {red[7:0],green[7:0],blue[7:0]};
                        end
                    endcase
                end
                tick(1,beat==0 && !early_sof,rgb);
                if (bubbles && beat%37==36) tick(0,0,96'hffffffffffffffffffffffff);
            end
            full_frames = full_frames+1;
        end
    endtask
    integer beat;
    initial begin
        done = 0;
        repeat (4) @(negedge clk);
        rst_n = 1;
        // Exercise the exact accepted-sample and channel-sum upper bound.
        frame(0,0,1);
        idle(100);
        if (dut.sample_count != MAX_SAMPLES ||
            dut.sum_r != 220*MAX_SAMPLES || dut.sum_g != 220*MAX_SAMPLES ||
            dut.sum_b != 220*MAX_SAMPLES ||
            !dut.pending_ready || dut.pending_r_q8 != 256 || dut.pending_b_q8 != 256)
            $fatal(1,"AWB maximum statistics not reached case=%0d",CASE_ID);
        upper_bound_checks = upper_bound_checks+1;
        // Ratios exercise both restoring-divider polarities and clamping.
        frame(1,1,0); idle(100);
        frame(2,0,0); idle(100);
        frame(3,1,1); idle(100);
        // SOF truncation, then immediately adjacent complete frames.
        for (beat=0;beat<BEATS/3;beat=beat+1)
            tick(1,beat==0,96'h96785a96785a96785a96785a);
        frame(4,0,0); frame(1,0,0); frame(2,0,0); idle(100);
        // Reset while statistics/colour work can still be in flight.
        for (beat=0;beat<12;beat=beat+1)
            tick(1,beat==0,96'h966450966450966450966450);
        @(negedge clk); rst_n=0; valid=0; user=0; last=0;
        repeat (3) @(negedge clk);
        rst_n=1; idle(110);
        $display("AWB_WIDTH_CASE_PASS case=%0d width=%0d height=%0d sample_log2=%0d checks=%0d full_frames=%0d max_stats=%0d sum_bits=%0d count_bits=%0d",
                 CASE_ID,WIDTH,HEIGHT,SAMPLE_LOG2,checks,full_frames,upper_bound_checks,
                 dut.SUM_BITS,dut.SAMPLE_COUNT_BITS);
        done=1;
    end
endmodule

module tb_awb_width_equivalence;
    wire [4:0] done;
    awb_width_case #(.CASE_ID(0)) c0(done[0]);
    awb_width_case #(.CASE_ID(1),.WIDTH(20),.HEIGHT(13)) c1(done[1]);
    awb_width_case #(.CASE_ID(2),.WIDTH(8),.HEIGHT(1),.SAMPLE_LOG2(1)) c2(done[2]);
    awb_width_case #(.CASE_ID(3),.WIDTH(1),.HEIGHT(1)) c3(done[3]);
    awb_width_case #(.CASE_ID(4),.WIDTH(160),.HEIGHT(120),.SAMPLE_LOG2(1)) c4(done[4]);
    initial begin
        wait (&done);
        $display("AWB_WIDTH_EQUIVALENCE_PASS cases=5 frozen_baseline=1 all_outputs_every_clock=1 stats_and_divider_every_clock=1 production_upper_bound=3168000");
        $finish;
    end
    initial begin
        #30000000;
        $fatal(1,"AWB width equivalence timeout");
    end
endmodule
