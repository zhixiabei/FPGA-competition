`timescale 1ns/1ps

// Exercise the modified HDMI arithmetic with a valid held-payload mailbox.
// RAW/DDR slot and timebase behavior have their separate integration tests.
// Frozen-baseline comparison includes every output on every HDMI clock,
// including numeric fields when sample_valid is false.
module latency_shared_case #(
    parameter integer CASE_ID = 0,
    parameter integer TW = 24,
    parameter integer MAX_AGE = 1000000
) (output reg done);
    localparam integer PW = 11+2*TW;
    reg time_clk = 0, csi_clk = 0, ddr_clk = 0, hdmi_clk = 0;
    always #2.1 time_clk = ~time_clk;
    always #3.3 csi_clk = ~csi_clk;
    always #7.1 ddr_clk = ~ddr_clk;
    always #5 hdmi_clk = ~hdmi_clk;
    reg rst_n = 0, display_start = 0;
    reg [PW-1:0] injected_payload = 0;
    reg request = 0;
    reg [TW-1:0] timestamp = {TW{1'b1}}-7;
    wire [9:0] actual_raw_id, baseline_raw_id;
    wire actual_strobe, baseline_strobe, actual_valid, baseline_valid;
    wire [9:0] actual_id, baseline_id;
    wire [19:0] actual_total, baseline_total, actual_isp, baseline_isp;
    wire [19:0] actual_buffer, baseline_buffer;
    integer checks = 0, valid_count = 0, invalid_count = 0;
    integer coincident_read = 0, preempt_one = 0, preempt_two = 0;
    integer wrap_count = 0, invalid_nonzero = 0, packets = 0;
    reg [31:0] random_state = 32'h12345678 ^ (CASE_ID*32'h6d2b79f5);
    reg [TW-1:0] old_timestamp, raw_time, isp_time;
    reg [9:0] frame_id = 0;
    integer cycle;
    video_latency_monitor #(.TIME_WIDTH(TW),.TIME_DEN(1),
        .FRAME_WORDS(8),.MAX_AGE_US(MAX_AGE)) dut (
        .I_time_clk(time_clk),.I_csi_clk(csi_clk),.I_ddr_clk(ddr_clk),
        .I_hdmi_clk(hdmi_clk),.I_rst_n(rst_n),
        .I_raw_sof(1'b0),.I_raw_valid(1'b0),.O_raw_frame_id(actual_raw_id),
        .I_isp_sof(1'b0),.I_isp_valid(1'b0),.I_isp_frame_id(10'd0),
        .I_write_start(1'b0),.I_write_slot(2'd0),.I_write_word(1'b0),
        .I_read_start(1'b0),.I_read_slot(2'd0),
        .I_display_frame_start(display_start),
        .O_sample_strobe(actual_strobe),.O_sample_valid(actual_valid),
        .O_frame_id(actual_id),.O_total_us(actual_total),.O_isp_us(actual_isp),
        .O_buffer_us(actual_buffer)
    );
    video_latency_monitor_baseline #(.TIME_WIDTH(TW),.TIME_DEN(1),
        .FRAME_WORDS(8),.MAX_AGE_US(MAX_AGE)) reference (
        .I_time_clk(time_clk),.I_csi_clk(csi_clk),.I_ddr_clk(ddr_clk),
        .I_hdmi_clk(hdmi_clk),.I_rst_n(rst_n),
        .I_raw_sof(1'b0),.I_raw_valid(1'b0),.O_raw_frame_id(baseline_raw_id),
        .I_isp_sof(1'b0),.I_isp_valid(1'b0),.I_isp_frame_id(10'd0),
        .I_write_start(1'b0),.I_write_slot(2'd0),.I_write_word(1'b0),
        .I_read_start(1'b0),.I_read_slot(2'd0),
        .I_display_frame_start(display_start),
        .O_sample_strobe(baseline_strobe),.O_sample_valid(baseline_valid),
        .O_frame_id(baseline_id),.O_total_us(baseline_total),.O_isp_us(baseline_isp),
        .O_buffer_us(baseline_buffer)
    );
    always @(posedge hdmi_clk) begin
        if (rst_n && display_start) begin
            if (dut.S_read_req_sync != dut.S_read_ack)
                coincident_read=coincident_read+1;
            if (dut.S_sample_stage == 1) preempt_one=preempt_one+1;
            if (dut.S_sample_stage == 2) preempt_two=preempt_two+1;
        end
        #0.2;
        if ({actual_raw_id,actual_strobe,actual_valid,actual_id,
             actual_total,actual_isp,actual_buffer} !==
            {baseline_raw_id,baseline_strobe,baseline_valid,baseline_id,
             baseline_total,baseline_isp,baseline_buffer})
            $fatal(1,"Latency shared mismatch case=%0d check=%0d valid=%b/%b strobe=%b/%b id=%0d/%0d total=%0d/%0d isp=%0d/%0d buffer=%0d/%0d",
                   CASE_ID,checks,actual_valid,baseline_valid,actual_strobe,baseline_strobe,
                   actual_id,baseline_id,actual_total,baseline_total,
                   actual_isp,baseline_isp,actual_buffer,baseline_buffer);
        if (rst_n && actual_strobe) begin
            if (actual_valid) valid_count=valid_count+1;
            else begin
                invalid_count=invalid_count+1;
                if (actual_total!=0 || actual_isp!=0 || actual_buffer!=0)
                    invalid_nonzero=invalid_nonzero+1;
            end
        end
        checks=checks+1;
    end
    initial begin
        done = 0;
        force dut.S_hdmi_us = timestamp;
        force reference.S_hdmi_us = timestamp;
        force dut.S_read_payload = injected_payload;
        force reference.S_read_payload = injected_payload;
        force dut.S_read_request = request;
        force reference.S_read_request = request;
        repeat (5) @(negedge hdmi_clk);
        rst_n=1;
        for (cycle=0;cycle<160000;cycle=cycle+1) begin
            @(negedge hdmi_clk);
            random_state = (random_state << 1) ^
                (random_state[31] ? 32'h04c11db7 : 0);
            old_timestamp=timestamp;
            timestamp=timestamp+1+random_state[6:0];
            if (timestamp < old_timestamp) wrap_count=wrap_count+1;
            // Force both kinds of preemption often, alongside long idle runs.
            display_start = cycle%19<4 || random_state[11:8]==4'd0;
            if (dut.S_read_ack_sync == request && cycle%11==0) begin
                frame_id=frame_id+1'b1;
                case (packets%6)
                    0,1,2: begin
                        raw_time=timestamp-128-random_state[5:0];
                        isp_time=raw_time+16+random_state[3:0];
                    end
                    3: begin
                        raw_time=timestamp-128; isp_time=timestamp+128;
                    end
                    4: begin
                        raw_time=timestamp-MAX_AGE-512; isp_time=raw_time+64;
                    end
                    default: begin
                        raw_time=timestamp+123; isp_time=timestamp-456;
                    end
                endcase
                injected_payload={packets%5!=4,frame_id,raw_time,isp_time};
                request=~request;
                packets=packets+1;
            end
        end
        @(negedge hdmi_clk); display_start=0;
        repeat (10) @(negedge hdmi_clk);
        if (valid_count<100 || invalid_count<100 || invalid_nonzero<100 ||
            coincident_read<100 || preempt_one<100 || preempt_two<100 ||
            wrap_count==0)
            $fatal(1,"Latency shared coverage incomplete case=%0d valid=%0d invalid=%0d read_display=%0d preempt=%0d,%0d wraps=%0d",
                   CASE_ID,valid_count,invalid_count,coincident_read,
                   preempt_one,preempt_two,wrap_count);
        $display("LATENCY_SHARED_CASE_PASS case=%0d time_width=%0d checks=%0d packets=%0d valid=%0d invalid=%0d invalid_numeric=%0d read_display_same_clock=%0d preempt_stage1=%0d preempt_stage2=%0d wraps=%0d",
                 CASE_ID,TW,checks,packets,valid_count,invalid_count,
                 invalid_nonzero,coincident_read,preempt_one,preempt_two,wrap_count);
        done=1;
    end
endmodule

module tb_latency_shared_equivalence;
    wire [1:0] done;
    latency_shared_case #(.CASE_ID(0),.TW(12),.MAX_AGE(500)) c0(done[0]);
    latency_shared_case #(.CASE_ID(1)) c1(done[1]);
    initial begin
        wait (&done);
        $display("LATENCY_SHARED_EQUIVALENCE_PASS cases=2 frozen_baseline=1 all_outputs_every_clock=1 widths=12,24");
        $finish;
    end
    initial begin
        #2000000;
        $fatal(1,"Latency shared equivalence timeout");
    end
endmodule
