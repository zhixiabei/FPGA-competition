`timescale 1ns/1ps
// Source-only regression for maintained SW2. Not run during merge preparation.
module tb_handfixed_switch_control;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,key_n=1;
    wire enabled;
    handfixed_key_control #(.DEBOUNCE_CYCLES(4),.LEVEL_CONTROL(1)) dut(.*);
    task level(input bit value,input integer cycles);
        begin @(negedge clk);key_n=value;repeat(cycles) @(negedge clk);end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        level(1,12);if(enabled) $fatal(1,"SW2 OFF must remain stopped");
        level(0,1);level(1,12);
        if(enabled) $fatal(1,"SW2 bounce must not start recognition");
        level(0,12);if(!enabled) $fatal(1,"SW2 ON must start without KEY4");
        level(0,100);if(!enabled) $fatal(1,"Maintained ON must not toggle off");
        level(1,1);level(0,12);
        if(!enabled) $fatal(1,"SW2 release bounce must not stop recognition");
        level(1,12);if(enabled) $fatal(1,"SW2 OFF must stop without another press");
        level(0,12);if(!enabled) $fatal(1,"SW2 must restart on the next ON");
        rst_n=0;#1;if(enabled) $fatal(1,"Reset must stop recognition");
        repeat(3) @(negedge clk);rst_n=1;
        repeat(12) @(negedge clk);
        if(!enabled) $fatal(1,"SW2 already ON at reset release must be honored");
        $display("HANDFIXED_SWITCH_CONTROL_PASS");$finish;
    end
    initial begin #10000;$fatal(1,"Switch control timeout");end
endmodule
