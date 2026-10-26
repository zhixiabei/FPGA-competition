`timescale 1ns/1ps
module tb_handfixed_key_control;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,key_n=1;
    wire enabled;
    integer transitions=0;
    reg last_enabled=0;
    handfixed_key_control #(.DEBOUNCE_CYCLES(4)) dut(.*);
    always @(negedge clk) if(rst_n && enabled!=last_enabled) begin
        transitions=transitions+1;last_enabled=enabled;
    end
    task level(input integer value,input integer cycles);
        begin @(negedge clk);key_n=value;repeat(cycles) @(negedge clk);end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        level(1,10);if(enabled) $fatal(1,"reset not stopped");
        level(0,1);level(1,1);level(0,2);level(1,10);
        if(enabled || transitions!=0) $fatal(1,"press bounce toggled");
        level(0,15);if(!enabled || transitions!=1) $fatal(1,"first press failed");
        level(0,100);if(!enabled || transitions!=1) $fatal(1,"long hold repeated");
        level(1,1);level(0,2);level(1,15);
        if(!enabled || transitions!=1) $fatal(1,"release bounce toggled");
        level(0,15);if(enabled || transitions!=2) $fatal(1,"second press failed");
        level(1,15);level(0,15);if(!enabled || transitions!=3) $fatal(1,"restart failed");
        rst_n=0;#1;if(enabled) $fatal(1,"reset did not stop");
        $display("HANDFIXED_KEY_CONTROL_PASS bounce hold release start stop restart reset");$finish;
    end
endmodule
