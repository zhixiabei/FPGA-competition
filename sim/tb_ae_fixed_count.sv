`timescale 1ns/1ps
// A fixed-count specialization must match the variable-count specification
// on every accepted frame, while rejecting all wrong-count frames outright.
module ae_fixed_count_case #(
    parameter integer N=28800, AVG=6, SETTLE=3, HIGHLIGHT=1, CASE_ID=0,
    CHECK_BRIGHT=1
) (output reg done=0);
    reg clk=0;
    always #5 clk=~clk;
    reg rst=1, camera_done=0, config_done=1;
    reg fixed_valid=0, reference_valid=0;
    reg [31:0] total=0;
    reg [15:0] count=N, near_count=0;
    reg [4:0] p95=0;
    wire request_fixed, request_reference, hold_fixed, hold_reference;
    wire [15:0] exposure_fixed,gain_fixed,exposure_reference,gain_reference;
    auto_exposure_control #(.FIXED_SAMPLE_COUNT(N),.AVERAGE_FRAMES(AVG),
        .SETTLE_FRAMES(SETTLE),.HIGHLIGHT_ENABLE(HIGHLIGHT),
        .CHECK_BRIGHT_COUNT(CHECK_BRIGHT)) fixed_dut (
        .I_clk(clk),.I_rst(rst),.I_cam_cfg_done(camera_done),
        .I_ae_cfg_done(config_done),.I_stats_valid(fixed_valid),
        .I_sum_y(total),.I_sample_count(count),.I_bright_count(near_count),
        .I_p95(p95),.O_ae_req(request_fixed),.O_ae(exposure_fixed),
        .O_ag(gain_fixed),.O_awb_hold(hold_fixed));
    auto_exposure_control #(.AVERAGE_FRAMES(AVG),.SETTLE_FRAMES(SETTLE),
        .HIGHLIGHT_ENABLE(HIGHLIGHT),.CHECK_BRIGHT_COUNT(1)) reference_dut (
        .I_clk(clk),.I_rst(rst),.I_cam_cfg_done(camera_done),
        .I_ae_cfg_done(config_done),.I_stats_valid(reference_valid),
        .I_sum_y(total),.I_sample_count(count),.I_bright_count(near_count),
        .I_p95(p95),.O_ae_req(request_reference),.O_ae(exposure_reference),
        .O_ag(gain_reference),.O_awb_hold(hold_reference));
    integer checks=0, requests=0, busy_clocks=0, frame_index, mean_value, bad_kind;
    reg [31:0] random_state=32'h90ab1234+CASE_ID;
    always @(posedge clk) begin
        #2;
        checks=checks+1;
        if ({request_fixed,exposure_fixed,gain_fixed,hold_fixed} !==
            {request_reference,exposure_reference,gain_reference,hold_reference})
            $fatal(1,"Fixed specialization mismatch case=%0d check=%0d N=%0d avg=%0d state=%0d/%0d",
                CASE_ID,checks,N,AVG,fixed_dut.state,reference_dut.state);
        if(request_fixed) requests=requests+1;
    end
    always @(negedge clk) begin
        if(rst) begin
            config_done=1;
            busy_clocks=0;
        end else if(request_fixed) begin
            config_done=0;
            busy_clocks=2;
        end else if(busy_clocks!=0) busy_clocks=busy_clocks-1;
        else config_done=1;
    end
    initial begin
        repeat(4) @(negedge clk);
        rst=0; camera_done=1;
        for(frame_index=0;frame_index<4000;frame_index=frame_index+1) begin
            // Complete the real busy/done handshake before issuing another
            // frame. Controls and invalid frames are compared cycle by cycle.
            random_state={random_state[30:0],
                random_state[31]^random_state[21]^random_state[1]^random_state[0]};
            mean_value=(frame_index/97)%5==0 ? 0 :
                (frame_index/97)%5==1 ? 79 :
                (frame_index/97)%5==2 ? 104 :
                (frame_index/97)%5==3 ? 132 : 192;
            count=N; total=N*mean_value;
            p95=random_state[4:0];
            near_count=random_state[5] ? N : 0;
            fixed_valid=1; reference_valid=1;
            bad_kind=frame_index%17;
            if(bad_kind==0) begin
                // A semantically valid but wrong count must be excluded by
                // the fixed implementation, not folded into its accumulator.
                count=N==65535 ? N-1 : N+1;
                total=count*mean_value;
                near_count=0;
                reference_valid=0;
            end else if(bad_kind==1) begin
                count=0; total=0; near_count=0;
            end else if(bad_kind==2) total=32'hffffffff;
            else if(bad_kind==3 && N<65535 && CHECK_BRIGHT) near_count=N+1;
            @(negedge clk);
            fixed_valid=0; reference_valid=0;
            repeat(3) @(negedge clk);
            if(frame_index==1999) begin
                camera_done=0;
                repeat(3) @(negedge clk);
                camera_done=1;
            end
        end
        if(requests<10) $fatal(1,"Fixed-count test did not exercise control");
        $display("AE_FIXED_COUNT_CASE_PASS case=%0d N=%0d average=%0d settle=%0d highlight=%0d checks=%0d requests=%0d",
            CASE_ID,N,AVG,SETTLE,HIGHLIGHT,checks,requests);
        done=1;
    end
endmodule
module tb_ae_fixed_count;
    wire [5:0] done;
    ae_fixed_count_case #(.CASE_ID(0)) production(.done(done[0]));
    ae_fixed_count_case #(.CASE_ID(1),.N(1),.AVG(1),.SETTLE(0))
        minimum(.done(done[1]));
    ae_fixed_count_case #(.CASE_ID(2),.N(65535),.AVG(16),.SETTLE(3))
        maximum(.done(done[2]));
    ae_fixed_count_case #(.CASE_ID(3),.N(160),.HIGHLIGHT(0))
        no_highlight(.done(done[3]));
    ae_fixed_count_case #(.CASE_ID(4),.N(28800),.AVG(16),.SETTLE(255))
        longest_settle(.done(done[4]));
    ae_fixed_count_case #(.CASE_ID(5),.CHECK_BRIGHT(0))
        trusted_publisher(.done(done[5]));
    initial begin
        wait(&done);
        $display("AE_FIXED_COUNT_PASS cases=6 frames=24000");
        $finish;
    end
    initial begin #3000000; $fatal(1,"Fixed-count timeout"); end
endmodule
