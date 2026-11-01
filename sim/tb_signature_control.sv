`timescale 1ns/1ps
module tb_signature_control;
    reg clk=0;always #10 clk=~clk;
    reg rst=0,sw3=0,sw4=0;
    reg [3:0] requested_mode=0;
    wire [3:0] mode,fast_mode;wire [7:0] command,fast_command;
    integer checks=0;
    signature_control #(.DEBOUNCE_CYCLES(8)) dut(
        .I_clk(clk),.I_rst_n(rst),.I_write_switch(sw3),.I_pause_switch(sw4),
        .I_effect_mode(requested_mode),.I_effect_param(8'd0),
        .O_effect_config({mode,command}));
    signature_control #(.DEBOUNCE_CYCLES(1)) fast_dut(
        .I_clk(clk),.I_rst_n(rst),.I_write_switch(sw3),.I_pause_switch(sw4),
        .I_effect_mode(requested_mode),.I_effect_param(8'd0),
        .O_effect_config({fast_mode,fast_command}));
    task tick(input integer n);repeat(n) @(negedge clk);endtask
    task check(input [3:0] m,input bit p);
        begin checks++;if(mode!==m || command!==p) $fatal(1,"SW3/SW4 got %0d/%0d expected %0d/%0d",mode,command,m,p);end
    endtask
    initial begin
        tick(4);rst=1;tick(20);check(0,0);
        sw3=1;tick(2);sw3=0;tick(2);sw3=1;tick(2);sw3=0;tick(20);check(0,0);
        sw4=1;tick(20);check(0,0);sw3=1;tick(20);check(13,1);tick(100);check(13,1);
        sw4=0;tick(2);sw4=1;tick(20);check(13,1);
        sw4=0;tick(20);check(13,0);sw4=1;tick(20);check(13,1);
        sw3=0;tick(2);sw3=1;tick(20);check(13,1);
        sw3=0;tick(20);check(0,0);sw3=1;tick(20);check(13,1);
        rst=0;tick(4);check(0,0);rst=1;tick(20);check(13,1);
        sw3=0;sw4=0;tick(20);check(0,0);
        sw3=1;tick(2);if(fast_mode!==0) $fatal(1,"Synchronizer bypass");
        tick(2);if(fast_mode!==13) $fatal(1,"One-cycle debounce failed");
        tick(20);check(13,0);requested_mode=12;tick(20);check(13,0);
        sw3=0;tick(20);check(12,0);
        for(integer m=0;m<13;m++) begin requested_mode=m;tick(1);check(m,0);end
        $display("SIGNATURE_CONTROL_PASS checks=%0d debounce startup_on pause_level restore_modes=13",checks);$finish;
    end
    initial begin #1000000;$fatal(1,"control timeout");end
endmodule
