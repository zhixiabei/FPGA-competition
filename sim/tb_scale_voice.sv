`timescale 1ns/1ps
module tb_scale_voice;
    reg clk=0,rst_n=0;
    always #5 clk=~clk;
    reg phrase_start=0;
    reg [23:0] w=0,a=0;
    wire phrase_ready,phrase_done;
    wire [4:0] clip_count;
    wire [199:0] clips;
    scale_voice_phrase phrase(.clk(clk),.rst_n(rst_n),.start(phrase_start),
        .weight_g(w),.amount_fen(a),.ready(phrase_ready),.done(phrase_done),
        .clip_count(clip_count),.clips(clips));

    task check_phrase(input integer weight_value,amount_value);
        string weight_text,amount_text;
        reg [199:0] expected;
        integer count,i,value;
        begin
            // Independent software-style decimal string reference.
            weight_text=$sformatf("%0d.%03d",weight_value/1000,weight_value%1000);
            amount_text=$sformatf("%0d.%02d",amount_value/100,amount_value%100);
            expected=0;count=0;
            for(i=0;i<weight_text.len();i=i+1) begin
                value=weight_text[i]==46 ? 13:weight_text[i]-48+1;
                expected[count*8+:8]=value;count=count+1;
            end
            expected[count*8+:8]=11;count=count+1;
            for(i=0;i<amount_text.len();i=i+1) begin
                value=amount_text[i]==46 ? 13:amount_text[i]-48+1;
                expected[count*8+:8]=value;count=count+1;
            end
            expected[count*8+:8]=12;count=count+1;
            @(negedge clk);w=weight_value;a=amount_value;phrase_start=1;
            @(negedge clk);phrase_start=0;
            wait(phrase_done);@(negedge clk);
            if(clip_count!==count || clips!==expected)
                $fatal(1,"phrase mismatch %s kg %s yuan count=%0d expected=%0d clips=%h expected=%h",
                    weight_text,amount_text,clip_count,count,clips,expected);
        end
    endtask

    reg stable_enable=0,stable_sample=0,stable_ready=1;
    reg [23:0] sw=0,sa=0;
    wire quote;
    wire [23:0] qw,qa;
    integer quotes=0;
    scale_voice_stable #(.CLOCK_HZ(1000),.STABLE_MS(5),.SAMPLE_TIMEOUT_MS(6)) stable(
        .clk(clk),.rst_n(rst_n),.enable(stable_enable),.sample_valid(stable_sample),
        .weight_g(sw),.amount_fen(sa),.quote_ready(stable_ready),
        .quote_valid(quote),.quote_weight_g(qw),.quote_amount_fen(qa));
    always @(posedge clk) if(quote) quotes=quotes+1;
    task samples(input integer weight_value,amount_value,n);
        integer j;
        begin
            for(j=0;j<n;j=j+1) begin
                @(negedge clk);sw=weight_value;sa=amount_value;stable_sample=1;
                @(negedge clk);stable_sample=0;
            end
        end
    endtask

    reg auto_enable=0,auto_sample=0;
    reg [23:0] auto_w=227,auto_a=182;
    wire tx,initialized,auto_busy,started,finished,timed_out;
    reg rx=1;
    integer starts=0,finishes=0,timeouts=0;
    scale_voice_auto #(.CLOCK_HZ(96000),.STARTUP_MS(2),.INIT_GAP_MS(2),
        .STABLE_MS(4),.SAMPLE_TIMEOUT_MS(20),.POLL_MS(20),
        .START_GRACE_MS(10),.PLAY_TIMEOUT_MS(200),.VOLUME(30)) auto_dut(
        .clk(clk),.rst_n(rst_n),.enable(auto_enable),.sample_valid(auto_sample),
        .weight_g(auto_w),.amount_fen(auto_a),.rx(rx),.tx(tx),
        .initialized(initialized),.busy(auto_busy),.announcement_started(started),
        .announcement_finished(finished),.playback_timeout(timed_out),
        .spoken_weight_g(),.spoken_amount_fen());
    always @(posedge clk) begin
        if(started) starts=starts+1;
        if(finished) finishes=finishes+1;
        if(timed_out) timeouts=timeouts+1;
    end
    reg sampling=0;
    initial forever begin
        repeat(100) @(negedge clk);
        if(sampling) begin
            auto_sample=1;@(negedge clk);auto_sample=0;
        end
    end

    // Model the real module using serial wires, not internal DUT byte signals.
    reg [7:0] packet[0:31];
    integer packets=0,play_commands=0,polls=0;
    reg suppress_response=0;
    task read_byte(output reg [7:0] value);
        integer j;
        begin
            @(negedge tx);repeat(5) @(posedge clk);#1;
            if(tx!==0) $fatal(1,"bad start bit");
            for(j=0;j<8;j=j+1) begin
                repeat(10) @(posedge clk);#1;value[j]=tx;
            end
            repeat(10) @(posedge clk);#1;
            if(tx!==1) $fatal(1,"bad stop bit");
        end
    endtask
    task send_byte(input reg [7:0] value);
        integer j;
        begin
            @(negedge clk);rx=0;repeat(10) @(negedge clk);
            for(j=0;j<8;j=j+1) begin rx=value[j];repeat(10) @(negedge clk);end
            rx=1;repeat(10) @(negedge clk);
        end
    endtask
    task send_status(input integer status_value,input integer corrupt);
        begin
            send_byte('hfe);send_byte(8);send_byte(0);send_byte(1);
            send_byte(1);send_byte(status_value);send_byte(8+status_value+corrupt);send_byte('hbe);
        end
    endtask
    initial begin: module_model
        integer n,j,sum;
        forever begin
            read_byte(packet[0]);read_byte(packet[1]);n=packet[1];
            if(packet[0]!==8'hfe || n<7 || n>32) $fatal(1,"invalid wire frame header %h length=%0d",packet[0],n);
            for(j=2;j<n;j=j+1) read_byte(packet[j]);
            sum=0;for(j=0;j<n-2;j=j+1) sum=(sum+packet[j])&255;
            if(packet[n-1]!==8'hbe || packet[n-2]!==sum) $fatal(1,"wire frame checksum");
            if(packet[2]!==255 || packet[3]!==255) $fatal(1,"unexpected address");
            packets=packets+1;
            case(packet[4])
                'h0b: if(n!=8 || packet[5]!=1) $fatal(1,"TF initialization");
                'h13: if(n!=8 || packet[5]!=30) $fatal(1,"volume initialization");
                'h1b: begin
                    play_commands=play_commands+1;
                    if(play_commands==1) begin
                        // 0.227 kg, 1.82 yuan.
                        if(n!=18 || packet[5]!=1 || packet[6]!=13 || packet[7]!=3 || packet[8]!=3 ||
                           packet[9]!=8 || packet[10]!=11 || packet[11]!=2 || packet[12]!=13 ||
                           packet[13]!=9 || packet[14]!=3 || packet[15]!=12)
                            $fatal(1,"227g/182fen audio sequence length=%0d",n);
                    end
                end
                'h01: begin
                    polls=polls+1;
                    if(!suppress_response) begin
                        // First corrupt stop response must be ignored.
                        if(polls==1) begin
                            send_status(0,1);
                            if(finishes!=0) $fatal(1,"accepted corrupt status");
                        end else if(polls==2) send_status(1,0);
                        else send_status(0,0);
                    end
                end
                default: $fatal(1,"unexpected command %h",packet[4]);
            endcase
        end
    end

    integer i;
    initial begin
        repeat(5) @(negedge clk);rst_n=1;
        check_phrase(0,0);check_phrase(227,182);check_phrase(1250,1250);
        check_phrase(9999,9999);check_phrase(16777215,16777215);
        for(i=0;i<100;i=i+1) check_phrase($urandom_range(0,9999),$urandom_range(0,9999));
        stable_enable=1;
        for(i=0;i<20;i=i+1) samples(1000+i*2,800,1);
        if(quotes!=0) $fatal(1,"slow drift incorrectly stable");
        samples(1250,1000,8);
        if(quotes!=1 || qw!=1250 || qa!=1000) $fatal(1,"first stable quote");
        samples(1251,1001,10);
        if(quotes!=1) $fatal(1,"repeated noisy stable quote");
        stable_ready=0;samples(1250,1250,10);
        if(quotes!=1) $fatal(1,"ignored busy backpressure");
        stable_ready=1;samples(1250,1250,2);
        if(quotes!=2) $fatal(1,"amount-only change");
        samples(0,0,8);samples(1250,1250,8);
        if(quotes!=3) $fatal(1,"empty scale did not rearm");
        stable_enable=0;@(negedge clk);stable_enable=1;
        samples(1500,1200,2);repeat(20) @(negedge clk);samples(1500,1200,1);
        if(quotes!=3) $fatal(1,"stale samples counted as stable");
        samples(1500,1200,6);
        if(quotes!=4) $fatal(1,"fresh samples did not stabilize");
        stable_enable=0;

        wait(initialized);auto_enable=1;sampling=1;
        wait(finishes==1);repeat(2500) @(negedge clk);
        if(play_commands!=1 || starts!=1 || timeouts!=0) $fatal(1,"auto repeat or completion error");
        suppress_response=1;auto_a=1830;
        wait(starts==2);wait(timeouts==1);
        if(finishes!=1 || play_commands!=2) $fatal(1,"missing-response timeout");
        $display("SCALE_VOICE_PASS phrases=105 stability drift repeat stale backpressure UART checksum playback timeout");
        $finish;
    end
    initial begin #10000000;$fatal(1,"test watchdog");end
endmodule
