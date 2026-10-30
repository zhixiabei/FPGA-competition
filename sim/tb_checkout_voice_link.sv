`timescale 1ns/1ps
// Actual checkout arithmetic -> production bridge -> decoded UART commands.
module tb_checkout_voice_link;
    reg clk=0,rst_n=0,sample_valid=0,tare=0,calibrate=0,fruit_valid=0;
    reg run_switch=0,sensor_fault=0;
    reg signed [23:0] raw_sample=0;
    reg [2:0] fruit_class=1;
    wire [13:0] weight_g,total_fen;
    wire weight_valid,price_valid,weight_updated,tared,calibrated,pending,overload;
    // The scale core's status policy, including its normal recalculation gap.
    wire [3:0] status=sensor_fault ? 4'd1 : pending ? 4'd4 : !tared ? 4'd5 :
        !calibrated ? 4'd6 : overload ? 4'd8 : weight_valid ? 4'd7 : 4'd10;
    wire tx;
    integer index=0,expected_length=0,sum=0,quotes=0,empty_updates=0;
    reg [7:0] packet[0:31];
    always #5 clk=~clk;
    always @(posedge clk) if(weight_updated && weight_valid && weight_g==0)
        empty_updates=empty_updates+1;
    fruit_checkout #(.CLK_HZ(96000),.FRUIT_TIMEOUT_CYCLES(100000),.CALIBRATION_GRAMS(1000)) checkout(
        .clk(clk),.rst_n(rst_n),.sample_valid(sample_valid),.sensor_fault(sensor_fault),.sample(raw_sample),
        .tare(tare),.calibrate(calibrate),.fruit_valid(fruit_valid),.fruit_class(fruit_class),
        .weight_g(weight_g),.total_fen(total_fen),.weight_valid(weight_valid),.price_valid(price_valid),
        .weight_updated(weight_updated),.overload(overload),.tared(tared),
        .calibrated(calibrated),.calibration_pending(pending));
    checkout_voice_bridge #(.CLOCK_HZ(96000),.STARTUP_MS(1),.INIT_GAP_MS(1),
        .STABLE_MS(4),.SAMPLE_TIMEOUT_MS(20),.POLL_MS(5),
        .START_GRACE_MS(1),.PLAY_TIMEOUT_MS(40)) voice(
        .clk(clk),.rst_n(rst_n),.run_switch(run_switch),
        .weight_g(weight_g),.total_fen(total_fen),.weight_valid(weight_valid),
        .price_valid(price_valid),.weight_updated(weight_updated),.status(status),.rx(1'b1),.tx(tx));
    wire byte_valid;
    wire [7:0] rx_byte;
    resnet18_uart #(.CLOCK_HZ(96000),.BAUD(9600)) monitor_uart(
        .clk(clk),.rst_n(rst_n),.rx(tx),.tx(),.rx_valid(byte_valid),.rx_error(),.rx_data(rx_byte),
        .tx_valid(1'b0),.tx_data(8'd0),.tx_ready());
    always @(negedge clk) if(byte_valid) begin
        packet[index]=rx_byte;
        if(index==1) begin
            expected_length=rx_byte;
            if(expected_length<7 || expected_length>32) $fatal(1,"invalid packet length");
        end
        if(index==expected_length-1 && index>1) begin
            sum=0;
            for(integer j=0;j<expected_length-2;j=j+1) sum=(sum+packet[j])&255;
            if(packet[0]!=8'hfe || packet[expected_length-1]!=8'hbe ||
               packet[expected_length-2]!=sum) $fatal(1,"invalid packet framing/checksum");
            if(packet[4]==8'h13 && packet[5]!=30) $fatal(1,"expected volume 30");
            if(packet[4]==8'h1b) begin
                if(expected_length!=18 || packet[5]!=1 || packet[6]!=13 || packet[7]!=3 || packet[8]!=3 ||
                   packet[9]!=8 || packet[10]!=11 || packet[11]!=2 || packet[12]!=13 ||
                   packet[13]!=9 || packet[14]!=3 || packet[15]!=12)
                    $fatal(1,"checkout output was not 0.227 kg / 1.82 yuan");
                quotes=quotes+1;
            end
            index=0;expected_length=0;
        end else index=index+1;
    end
    task average(input integer raw_value);
        integer j;
        begin
            for(j=0;j<8;j=j+1) begin
                @(negedge clk);raw_sample=raw_value;sample_valid=1;
                @(negedge clk);sample_valid=0;
            end
            repeat(200) @(negedge clk);
        end
    endtask
    task averages(input integer raw_value,n);
        integer j;
        begin for(j=0;j<n;j=j+1) average(raw_value);end
    endtask
    task identify(input [2:0] class_id);
        begin
            @(negedge clk);fruit_class=class_id;fruit_valid=1;
            @(negedge clk);fruit_valid=0;
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        @(negedge clk);tare=1;@(negedge clk);tare=0;average(100000);
        @(negedge clk);calibrate=1;@(negedge clk);calibrate=0;average(110000);
        run_switch=1;
        averages(102270,8);
        if(quotes!=0 || price_valid) $fatal(1,"quote before valid fruit price");
        run_switch=0;identify(2);averages(102270,20);
        if(quotes!=0) $fatal(1,"quote with SW2 off");
        run_switch=1;averages(102270,50);
        if(quotes!=1 || weight_g!=227 || total_fen!=182) $fatal(1,"checkout quote count=%0d",quotes);
        // Allow playback to time out, and keep recalculating an identical load.
        averages(102270,30);
        if(quotes!=1) $fatal(1,"status-10 calculation gaps repeated the quote");
        sensor_fault=1;averages(102270,20);
        if(quotes!=1) $fatal(1,"quote while sensor fault active");
        sensor_fault=0;run_switch=0;averages(102270,20);
        if(quotes!=1) $fatal(1,"quote with SW2 off after sensor recovery");
        run_switch=1;averages(102270,50);
        if(quotes!=2) $fatal(1,"no quote after explicit re-enable");
        // Exact zero never lowers weight_valid. Fresh zero observations must
        // still rearm, even when there is no classified fruit or valid price.
        identify(1);averages(100000,10);
        if(quotes!=2 || empty_updates<8 || price_valid)
            $fatal(1,"empty pan failed updates=%0d quotes=%0d",empty_updates,quotes);
        identify(2);averages(102270,50);
        if(quotes!=3) $fatal(1,"same load was not rearmed by empty pan");
        repeat(5000) @(negedge clk);
        if(quotes!=3) $fatal(1,"held valid flags treated as new samples");
        $display("CHECKOUT_VOICE_LINK_PASS real-checkout volume30 switch fault calculation-gaps empty-zero-rearm stale-flags");
        $finish;
    end
    initial begin #10000000;$fatal(1,"checkout link watchdog");end
endmodule
