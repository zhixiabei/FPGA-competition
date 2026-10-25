`timescale 1ns/1ps
module tb_handfixed_background;
    reg clk=0;always #7.5 clk=~clk;
    reg rst_n=0,enabled=0,start=0,training=0,done=0,pvalid=0,row_end=0;
    reg [7:0] green=0;
    wire ready,foreground;
    wire [10:0] changed;
    handfixed_background dut(.clk(clk),.rst_n(rst_n),.run_enabled(enabled),
        .start(start),.scan_background(training),.done(done),.pixel_valid(pvalid),
        .row_end(row_end),.green(green),.reference_ready(ready),.foreground(foreground),.changed_pixels(changed));
    task scan(input integer train,input integer count,input integer delta,input integer abort_half);
        integer x,y,id,value;
        begin
            @(negedge clk);training=train;start=1;
            @(negedge clk);start=0;
            for(y=0;y<96;y=y+1) for(x=0;x<96;x=x+1) begin
                id=(y/3)*32+x/3;value=32+(x*3+y*5)%128;
                if(id<count) value=value+delta;
                if(abort_half && y==48) enabled=1;
                pvalid=1;row_end=x==95;green=value;
                @(negedge clk);pvalid=0;
                @(negedge clk);
            end
            repeat(4) @(negedge clk);done=1;
            @(negedge clk);done=0;
            repeat(4) @(negedge clk);
        end
    endtask
    task expect_result(input integer count,input integer fg);
        begin
            if(changed!==count || foreground!==fg[0])
                $fatal(1,"background result changed=%0d expected=%0d fg=%0d expected=%0d",changed,count,foreground,fg);
        end
    endtask
    initial begin
        repeat(8) @(negedge clk);rst_n=1;
        enabled=1;scan(0,100,40,0);
        if(ready || foreground) $fatal(1,"uninitialized reference accepted");
        enabled=0;scan(1,0,0,0);if(!ready) $fatal(1,"reference not committed");
        enabled=1;scan(0,0,0,0);expect_result(0,0);
        scan(0,1024,23,0);expect_result(0,0);
        scan(0,63,24,0);expect_result(63,0);
        scan(0,64,24,0);expect_result(64,1);
        // A still hand stays foreground on repeated identical frames.
        scan(0,64,24,0);expect_result(64,1);
        scan(0,32,24,0);expect_result(32,1);
        scan(0,31,24,0);expect_result(31,0);
        scan(0,0,0,0);expect_result(0,0);
        // A press during the next reference write preserves the old full bank.
        enabled=0;scan(1,1024,40,1);
        enabled=1;scan(0,0,0,0);expect_result(0,0);
        // Commit the alternate full bank and compare to the new reference.
        enabled=0;scan(1,1024,40,0);
        enabled=1;scan(0,1024,40,0);expect_result(0,0);
        scan(0,0,0,0);expect_result(1024,1);
        rst_n=0;repeat(4) @(negedge clk);
        if(ready || foreground) $fatal(1,"reset retained reference");
        $display("HANDFIXED_BACKGROUND_PASS no_reference identical noise23 delta24 enter64 exit32 stationary atomic_reference reset");$finish;
    end
    initial begin #100000000;$fatal(1,"background timeout");end
endmodule
