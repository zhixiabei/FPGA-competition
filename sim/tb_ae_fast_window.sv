`timescale 1ns/1ps
module tb_ae_fast_window;
    reg clk=0;
    always #5 clk=~clk;
    reg rst=1, camera_done=0, ae_done=0, valid=0;
    reg [31:0] total=0;
    reg [15:0] samples=16;
    reg [4:0] p95=0;
    wire [3:0] request, hold_awb;
    wire [15:0] exposure[0:3], gain[0:3];
    integer checks=0, i, f;
    genvar n;
    generate for(n=0;n<4;n=n+1) begin: cases
        auto_exposure_control #(
            .FAST_AVERAGE_FRAMES(2), .HIGHLIGHT_ENABLE(n>=2),
            .FIXED_SAMPLE_COUNT(n%2 ? 16 : 0)
        ) dut (
            .I_clk(clk), .I_rst(rst), .I_cam_cfg_done(camera_done),
            .I_ae_cfg_done(ae_done), .I_stats_valid(valid),
            .I_sum_y(total), .I_sample_count(samples), .I_bright_count(16'd0),
            .I_p95(p95), .O_ae_req(request[n]), .O_ae(exposure[n]),
            .O_ag(gain[n]), .O_awb_hold(hold_awb[n])
        );
    end endgenerate
    task automatic tick;
        @(posedge clk); #2;
    endtask
    task automatic sample(input integer mean_value, input integer percentile=0,
                          input integer count_value=16);
        @(negedge clk);
        valid=1; total=mean_value*count_value; samples=count_value; p95=percentile;
        tick();
        @(negedge clk); valid=0;
    endtask
    task automatic expect_values(input [3:0] req,
                                 input integer plain_e, input integer highlight_e);
        if(request!==req) $fatal(1,"Fast window request: expected %b got %b",req,request);
        for(i=0;i<4;i=i+1)
            if(exposure[i]!=(i>=2 ? highlight_e : plain_e) || gain[i]!=16)
                $fatal(1,"Fast window exposure/gain mismatch case=%0d E=%0d G=%0d",
                       i,exposure[i],gain[i]);
        checks=checks+1;
    endtask
    task automatic reset_case;
        @(negedge clk); rst=1; camera_done=0; ae_done=0; valid=0;
        repeat(3) tick();
        @(negedge clk); rst=0; camera_done=1; ae_done=1;
        tick(); expect_values(4'b1111,1000,1000);
        @(negedge clk); ae_done=0; tick();
        @(negedge clk); ae_done=1; tick();
        repeat(3) begin
            sample(0); expect_values(0,1000,1000);
            if(hold_awb!==4'b1111) $fatal(1,"Settling must freeze AWB");
        end
    endtask
    initial begin
        reset_case();
        sample(0); expect_values(0,1000,1000);
        sample(0); expect_values(4'b1111,1500,1500);
        if(hold_awb!==4'b1111) $fatal(1,"Adjustment must keep AWB frozen");

        reset_case();
        sample(192); expect_values(0,1000,1000);
        sample(192); expect_values(4'b1111,750,750);

        // Near-target dark frames still need six samples and a small step.
        reset_case();
        repeat(5) begin sample(88); expect_values(0,1000,1000); end
        sample(88); expect_values(4'b1111,1125,1125);

        // Opposing excursions cannot trigger the fast path.
        reset_case();
        for(f=0;f<6;f=f+1) begin
            sample(f%2 ? 192 : 0); expect_values(0,1000,1000);
        end
        if(hold_awb!==0) $fatal(1,"A stable complete mean must release AWB");

        // A first neutral frame disqualifies early action for that window.
        reset_case();
        sample(108); expect_values(0,1000,1000);
        repeat(4) begin sample(0); expect_values(0,1000,1000); end
        sample(0); expect_values(4'b1111,1500,1500);

        // Existing P95 information must affect the production decision.
        reset_case();
        repeat(5) begin sample(112,31); expect_values(0,1000,1000); end
        sample(112,31); expect_values(4'b1100,1000,875);

        // Invalid fixed counts do not count towards the short window.
        reset_case();
        sample(0,0,8); expect_values(0,1000,1000);
        sample(0);
        if(request!==4'b0101 || exposure[0]!=1500 || exposure[2]!=1500 ||
           exposure[1]!=1000 || exposure[3]!=1000)
            $fatal(1,"Invalid fixed-count frame consumed the fast window");
        checks=checks+1;
        $display("AE_FAST_WINDOW_PASS checks=%0d configurations=4",checks);
        $finish;
    end
    initial begin #100000; $fatal(1,"Fast window timeout"); end
endmodule
