`timescale 1ns/1ps
module tb_five_class_checkout;
    reg clk=0,rst_n=0,sample_valid=0,sensor_fault=0,tare=0,calibrate=0,fruit_valid=0;
    reg signed [23:0] sample=0;
    reg [2:0] fruit_class=1;
    wire [13:0] weight_g,total_fen;
    wire weight_valid,price_valid,overload,tared,calibrated,calibration_pending;
    integer errors=0;
    always #5 clk=~clk;

    fruit_checkout #(.CLK_HZ(100),.FRUIT_TIMEOUT_CYCLES(1000),.CALIBRATION_GRAMS(1000)) dut(
        .clk(clk),.rst_n(rst_n),.sample_valid(sample_valid),.sensor_fault(sensor_fault),.sample(sample),
        .tare(tare),.calibrate(calibrate),.fruit_valid(fruit_valid),.fruit_class(fruit_class),
        .weight_g(weight_g),.total_fen(total_fen),.weight_valid(weight_valid),.price_valid(price_valid),
        .overload(overload),.tared(tared),.calibrated(calibrated),.calibration_pending(calibration_pending));

    task pulse_command(input integer which);
        begin
            @(negedge clk); tare=which==1;calibrate=which==2;
            @(negedge clk); tare=0;calibrate=0;
        end
    endtask
    task send_average(input integer raw);
        integer i;
        begin
            for(i=0;i<8;i=i+1) begin
                @(negedge clk);sample=raw;sample_valid=1;
                @(negedge clk);sample_valid=0;
            end
            repeat(4) @(negedge clk);
        end
    endtask
    task identify(input [2:0] class_id);
        begin
            @(negedge clk);fruit_class=class_id;fruit_valid=1;
            @(negedge clk);fruit_valid=0;
        end
    endtask
    task wait_price(input integer expected);
        integer cycles;
        begin
            cycles=0;
            while(!price_valid && cycles<250) begin @(negedge clk);cycles=cycles+1;end
            if(!price_valid || total_fen!==expected) begin
                $display("PRICE_FAIL class=%0d weight=%0d expected=%0d got=%0d valid=%0b",
                    fruit_class,weight_g,expected,total_fen,price_valid);errors=errors+1;
            end
        end
    endtask
    task weigh(input integer grams);
        integer cycles;
        begin
            send_average(100000+grams*10);
            cycles=0;
            while((!weight_valid || weight_g!==grams) && cycles<300) begin @(negedge clk);cycles=cycles+1;end
            if(!weight_valid || weight_g!==grams) begin
                $display("WEIGHT_FAIL expected=%0d got=%0d valid=%0b",grams,weight_g,weight_valid);errors=errors+1;
            end
        end
    endtask

    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        pulse_command(1);send_average(100000);
        if(!tared) begin $display("TARE_FAIL");errors=errors+1;end
        pulse_command(2);send_average(110000);
        if(!calibrated) begin $display("CALIBRATION_FAIL");errors=errors+1;end

        identify(2);weigh(227);wait_price(182);
        identify(3);wait_price(136);
        identify(4);wait_price(272);
        identify(5);wait_price(114);
        identify(6);wait_price(454);

        identify(5);weigh(5);wait_price(3);
        identify(6);weigh(6000);
        repeat(150) @(negedge clk);
        if(price_valid || total_fen!==9999) begin
            $display("PRICE_LIMIT_FAIL total=%0d valid=%0b",total_fen,price_valid);errors=errors+1;
        end
        identify(1);repeat(4) @(negedge clk);
        if(price_valid) begin $display("UNKNOWN_CLASS_FAIL");errors=errors+1;end

        if(errors==0) $display("FIVE_CLASS_CHECKOUT_PASS");
        else $display("FIVE_CLASS_CHECKOUT_FAIL errors=%0d",errors);
        $finish;
    end
endmodule
