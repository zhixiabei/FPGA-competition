`timescale 1ns/1ps
module tb_ae_highlight_control;
    reg clk=0;
    always #5 clk=~clk;
    reg rst=1, camera_done=0, ae_done=0, valid=0;
    reg [31:0] total=0;
    reg [15:0] count=0, near_count=0;
    reg [4:0] p95=0;
    wire req, hold_awb;
    wire [15:0] exposure,gain;
    integer checks=0, windows=0;
    auto_exposure_control #(.HIGHLIGHT_ENABLE(1)) dut (
        .I_clk(clk),.I_rst(rst),.I_cam_cfg_done(camera_done),
        .I_ae_cfg_done(ae_done),.I_stats_valid(valid),.I_sum_y(total),
        .I_sample_count(count),.I_bright_count(near_count),.I_p95(p95),
        .O_ae_req(req),.O_ae(exposure),.O_ag(gain),.O_awb_hold(hold_awb));
    task automatic tick;
        @(posedge clk); #2;
    endtask
    task automatic sample(input integer sum_value, input integer n,
                          input integer near_value,input integer percentile);
        @(negedge clk); valid=1; total=sum_value; count=n;
        near_count=near_value; p95=percentile;
        tick();
        @(negedge clk); valid=0;
    endtask
    task automatic finish_write;
        integer i;
        @(negedge clk); ae_done=0; tick();
        if(!hold_awb) $fatal(1,"AWB not held while I2C busy");
        @(negedge clk); ae_done=1; tick();
        for(i=0;i<3;i=i+1) begin
            sample(192*65535,65535,65535,31);
            if(req || !hold_awb) $fatal(1,"Settling did not hold WB/control");
        end
        tick();
        if(hold_awb) $fatal(1,"AWB hold did not release after stable frames");
    endtask
    task automatic initialize;
        @(negedge clk); rst=1; camera_done=0; ae_done=0; valid=0;
        repeat(3) tick();
        @(negedge clk); rst=0; camera_done=1; ae_done=1;
        tick();
        if(!req || exposure!=1000 || gain!=16 || !hold_awb)
            $fatal(1,"Initial request/hold wrong");
        tick();
        finish_write();
    endtask
    task automatic check_window(input integer mean_value,input integer n,
                                input integer percentile);
        integer i, before_e,before_g,score,step,expected_e;
        bit expected_request;
        before_e=exposure; before_g=gain;
        score=mean_value + (percentile>23 ? 2*(percentile-23) : 0);
        step=score<64 ? before_e/2 : score>144 ? before_e/4 : before_e/8;
        if(step==0) step=1;
        expected_e=score<96 ? before_e+step : score>120 ? before_e-step : before_e;
        if(expected_e<4) expected_e=4;
        if(expected_e>1991) expected_e=1991;
        expected_request=expected_e!=before_e;
        for(i=0;i<6;i=i+1) begin
            sample(mean_value*n,n,0,percentile);
            if(i!=5 && (req || exposure!=before_e || gain!=before_g))
                $fatal(1,"Partial averaging window changed exposure");
        end
        checks=checks+1; windows=windows+1;
        if(req!==expected_request || exposure!=expected_e || gain!=16)
            $fatal(1,"Independent score decision mean=%0d p95=%0d expected=%0d/%b got=%0d/%b",
                mean_value,percentile,expected_e,expected_request,exposure,req);
        if(expected_request) finish_write();
    endtask
    integer q,m,k,before_e;
    initial begin
        // Each percentile code and decision boundary, at interface count max.
        for(q=0;q<32;q=q+1) begin
            for(k=0;k<8;k=k+1) begin
                case(k)
                    0:m=0; 1:m=63; 2:m=79; 3:m=80;
                    4:m=95; 5:m=104; 6:m=120; default:m=192;
                endcase
                initialize(); check_window(m,65535,q);
            end
        end
        initialize();
        // Per-frame bias must be accumulated with its own count, not the
        // last frame's quantile applied retroactively to the entire window.
        for(k=0;k<6;k=k+1) sample(92*(k+1),k+1,0,k%2 ? 31 : 0);
        // Weighted bias is (2+4+6)*16/21, score=101.14, inside the deadband.
        if(req || exposure!=1000) $fatal(1,"Mixed-count/quantile averaging corrupted");
        checks=checks+1;
        before_e=exposure;
        // Invalid counts and overflowed sums cannot consume averaging frames.
        sample(32'hffffffff,65535,0,31);
        sample(0,0,0,31);
        sample(192*10,10,11,31);
        repeat(5) sample(0,65535,0,31);
        if(req || exposure!=before_e) $fatal(1,"Malformed input counted as a frame");
        sample(0,65535,0,31);
        if(!req || exposure<=before_e) $fatal(1,"High percentile locked a dark frame");
        checks=checks+1;
        $display("AE_HIGHLIGHT_CONTROL_PASS checks=%0d windows=%0d",checks,windows);
        $finish;
    end
    initial begin #2000000; $fatal(1,"Highlight controller timeout"); end
endmodule
