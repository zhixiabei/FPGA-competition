`timescale 1ns/1ps

module tb_voice_phrase_equivalence;
    reg clk=0,rst_n=0,start=0;
    always #5 clk=~clk;
    reg [23:0] w=0,a=0;
    wire [199:0] clips[0:5];
    wire [4:0] counts[0:5];
    wire [5:0] ready,done;
    scale_voice_phrase_reference ref_full(clk,rst_n,start,w,a,ready[0],done[0],counts[0],clips[0]);
    scale_voice_phrase new_full(clk,rst_n,start,w,a,ready[1],done[1],counts[1],clips[1]);
    scale_voice_phrase_reference ref_small(clk,rst_n,start,{10'd0,w[13:0]},
        {10'd0,a[13:0]},ready[2],done[2],counts[2],clips[2]);
    scale_voice_phrase #(.VALUE_WIDTH(14),.DECIMAL_DIGITS(5)) new_small(
        clk,rst_n,start,w[13:0],a[13:0],ready[3],done[3],counts[3],clips[3]);
    scale_voice_phrase_reference #(.CLIP_KG(200),.CLIP_YUAN(250),.CLIP_POINT(128))
        ref_custom(clk,rst_n,start,w,a,ready[4],done[4],counts[4],clips[4]);
    scale_voice_phrase #(.CLIP_KG(200),.CLIP_YUAN(250),.CLIP_POINT(128))
        new_custom(clk,rst_n,start,w,a,ready[5],done[5],counts[5],clips[5]);
    integer pair_index;
    always @(posedge clk) begin
        #1;
        if(rst_n) for(pair_index=0;pair_index<6;pair_index=pair_index+2)
            if({ready[pair_index],done[pair_index],counts[pair_index],clips[pair_index]} !==
               {ready[pair_index+1],done[pair_index+1],counts[pair_index+1],clips[pair_index+1]})
                $fatal(1,"phrase equivalence pair=%0d w=%0d a=%0d",pair_index,w,a);
    end
    task convert(input reg [23:0] weight_value,amount_value);
        begin
            @(negedge clk);w=weight_value;a=amount_value;start=1;
            @(negedge clk);start=0;
            wait(done[0]);@(negedge clk);
        end
    endtask
    integer i;
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        // Both operands cover every 14-bit value, including 9999 and 16383.
        for(i=0;i<16384;i=i+1) convert(i,(i*4051)%16384);
        convert(24'hffffff,24'hffffff);
        for(i=0;i<1024;i=i+1) convert($urandom,$urandom);
        $display("VOICE_PHRASE_EQUIVALENCE_PASS exhaustive-14-bit=16384 full-24-bit-random=1024 custom-8-bit-clips");
        $finish;
    end
    initial begin #30000000;$fatal(1,"phrase test timeout");end
endmodule

module voice_stable_equivalence_case #(
    parameter integer CLOCK=1000,AGE=4,FRESH=8,SAMPLES=3
)(input wire clk,rst_n,enable,sample,ready,
  input wire [13:0] w,a, output integer quotes=0);
    wire q0,q1;
    wire [23:0] w0,a0;
    wire [13:0] w1,a1;
    scale_voice_stable_reference #(.CLOCK_HZ(CLOCK),.STABLE_MS(AGE),
        .SAMPLE_TIMEOUT_MS(FRESH),.MIN_SAMPLES(SAMPLES)) ref_dut(
        .clk(clk),.rst_n(rst_n),.enable(enable),.sample_valid(sample),
        .weight_g({10'd0,w}),.amount_fen({10'd0,a}),.quote_ready(ready),
        .quote_valid(q0),.quote_weight_g(w0),.quote_amount_fen(a0));
    scale_voice_stable #(.CLOCK_HZ(CLOCK),.STABLE_MS(AGE),.SAMPLE_TIMEOUT_MS(FRESH),
        .MIN_SAMPLES(SAMPLES),.VALUE_WIDTH(14)) new_dut(
        .clk(clk),.rst_n(rst_n),.enable(enable),.sample_valid(sample),.ms_tick_in(1'b0),
        .weight_g(w),.amount_fen(a),.quote_ready(ready),
        .quote_valid(q1),.quote_weight_g(w1),.quote_amount_fen(a1));
    always @(posedge clk) begin
        #1;
        if(rst_n && {q0,w0,a0}!=={q1,10'd0,w1,10'd0,a1})
            $fatal(1,"stability equivalence CLOCK=%0d AGE=%0d FRESH=%0d SAMPLES=%0d",
                CLOCK,AGE,FRESH,SAMPLES);
        if(q1) quotes=quotes+1;
    end
endmodule

module voice_auto_equivalence_case #(
    parameter integer STARTUP=2,GAP=2,AGE=4,FRESH=20,POLL=10,GRACE=10,TIMEOUT=200
)(input wire clk,rst_n,enable,sample,rx,
  input wire [13:0] w,a,output integer starts=0,timeouts=0,finishes=0);
    wire tx0,tx1,i0,i1,b0,b1,s0,s1,f0,f1,t0,t1;
    wire [23:0] w0,a0;
    wire [13:0] w1,a1;
    scale_voice_auto_reference #(.CLOCK_HZ(96000),.STARTUP_MS(STARTUP),.INIT_GAP_MS(GAP),
        .STABLE_MS(AGE),.SAMPLE_TIMEOUT_MS(FRESH),.POLL_MS(POLL),
        .START_GRACE_MS(GRACE),.PLAY_TIMEOUT_MS(TIMEOUT),.VOLUME(30)) ref_dut(
        .clk(clk),.rst_n(rst_n),.enable(enable),.sample_valid(sample),
        .weight_g({10'd0,w}),.amount_fen({10'd0,a}),.rx(rx),.tx(tx0),
        .initialized(i0),.busy(b0),.announcement_started(s0),.announcement_finished(f0),
        .playback_timeout(t0),.spoken_weight_g(w0),.spoken_amount_fen(a0));
    scale_voice_auto #(.CLOCK_HZ(96000),.STARTUP_MS(STARTUP),.INIT_GAP_MS(GAP),
        .STABLE_MS(AGE),.SAMPLE_TIMEOUT_MS(FRESH),.POLL_MS(POLL),
        .START_GRACE_MS(GRACE),.PLAY_TIMEOUT_MS(TIMEOUT),.VOLUME(30),
        .VALUE_WIDTH(14),.DECIMAL_DIGITS(5),.COMPACT_TRANSPORT(1)) new_dut(
        .clk(clk),.rst_n(rst_n),.enable(enable),.sample_valid(sample),
        .weight_g(w),.amount_fen(a),.rx(rx),.tx(tx1),
        .initialized(i1),.busy(b1),.announcement_started(s1),.announcement_finished(f1),
        .playback_timeout(t1),.spoken_weight_g(w1),.spoken_amount_fen(a1));
    always @(posedge clk) begin
        #1;
        if(rst_n && {tx0,i0,b0,s0,f0,t0,w0,a0} !== {tx1,i1,b1,s1,f1,t1,10'd0,w1,10'd0,a1})
            $fatal(1,"automatic voice equivalence AGE=%0d POLL=%0d TIMEOUT=%0d",AGE,POLL,TIMEOUT);
        if(s1) starts=starts+1;
        if(t1) timeouts=timeouts+1;
        if(f1) finishes=finishes+1;
    end
endmodule

module tb_voice_control_equivalence;
    reg clk=0,rst_n=0,enable=0,sample=0,stable_sample=0,ready=1,rx=1;
    always #5 clk=~clk;
    reg [13:0] w=0,a=0;
    wire [31:0] quotes[0:4],starts[0:3],timeouts[0:3],finishes[0:3];
    voice_stable_equivalence_case normal(clk,rst_n,enable,stable_sample,ready,w,a,quotes[0]);
    voice_stable_equivalence_case #(.CLOCK(2000),.AGE(0),.FRESH(1),.SAMPLES(1))
        zero_age(clk,rst_n,enable,stable_sample,ready,w,a,quotes[1]);
    voice_stable_equivalence_case #(.CLOCK(8000),.AGE(8),.FRESH(16),.SAMPLES(4))
        powers(clk,rst_n,enable,stable_sample,ready,w,a,quotes[2]);
    voice_stable_equivalence_case #(.CLOCK(1000),.AGE(1),.FRESH(0),.SAMPLES(0))
        zero_fresh(clk,rst_n,enable,stable_sample,ready,w,a,quotes[3]);
    voice_stable_equivalence_case #(.CLOCK(4000),.AGE(1000),.FRESH(2000),.SAMPLES(16))
        production_age(clk,rst_n,enable,stable_sample,ready,w,a,quotes[4]);
    voice_auto_equivalence_case auto_normal(clk,rst_n,enable,sample,rx,w,a,starts[0],timeouts[0],finishes[0]);
    voice_auto_equivalence_case #(.TIMEOUT(1),.GRACE(0))
        early_timeout(clk,rst_n,enable,sample,rx,w,a,starts[1],timeouts[1],finishes[1]);
    voice_auto_equivalence_case #(.STARTUP(0),.GAP(0),.AGE(0),.POLL(0),.TIMEOUT(0),.GRACE(0))
        zeros(clk,rst_n,enable,sample,rx,w,a,starts[2],timeouts[2],finishes[2]);
    voice_auto_equivalence_case #(.AGE(8),.FRESH(16),.POLL(16),.GRACE(8),.TIMEOUT(128))
        auto_powers(clk,rst_n,enable,sample,rx,w,a,starts[3],timeouts[3],finishes[3]);
    wire bridge_tx0,bridge_tx1;
    reg run_switch=0,weight_valid=1,price_valid=0,weight_updated=0;
    reg [3:0] status=7;
    checkout_voice_bridge_reference #(.CLOCK_HZ(96000),.STARTUP_MS(2),.INIT_GAP_MS(2),
        .STABLE_MS(4),.SAMPLE_TIMEOUT_MS(20),.POLL_MS(10),.START_GRACE_MS(10),
        .PLAY_TIMEOUT_MS(200)) bridge_ref(
        clk,rst_n,run_switch,w,a,weight_valid,price_valid,weight_updated,status,rx,bridge_tx0);
    checkout_voice_bridge #(.CLOCK_HZ(96000),.STARTUP_MS(2),.INIT_GAP_MS(2),
        .STABLE_MS(4),.SAMPLE_TIMEOUT_MS(20),.POLL_MS(10),.START_GRACE_MS(10),
        .PLAY_TIMEOUT_MS(200)) bridge_new(
        clk,rst_n,run_switch,w,a,weight_valid,price_valid,weight_updated,status,rx,bridge_tx1);
    always @(posedge clk) begin
        #1;if(rst_n && bridge_tx0!==bridge_tx1) $fatal(1,"checkout bridge equivalence");
    end
    task send_byte(input reg [7:0] value);
        integer j;
        begin
            @(negedge clk);rx=0;repeat(10) @(negedge clk);
            for(j=0;j<8;j=j+1) begin rx=value[j];repeat(10) @(negedge clk);end
            rx=1;repeat(10) @(negedge clk);
        end
    endtask
    task send_status(input integer value,bad_sum);
        begin
            send_byte('hfe);send_byte(8);send_byte(0);send_byte(1);send_byte(1);
            send_byte(value);send_byte(8+value+bad_sum);send_byte('hbe);
        end
    endtask
    initial begin
        wait(rst_n);
        forever begin
            repeat(1700) @(negedge clk);send_status(0,1);
            repeat(500) @(negedge clk);send_status(1,0);
            repeat(700) @(negedge clk);send_status(0,0);
        end
    end
    integer cycle_index,i;
    reg [31:0] random_state=32'h730eda21;
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        for(cycle_index=0;cycle_index<160000;cycle_index=cycle_index+1) begin
            @(negedge clk);
            random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
            // Long stable periods, noisy ramps, stale data, empty pan, max14,
            // backpressure, sensor fault, disable in flight and reset in flight.
            case((cycle_index/5000)%8)
                0: begin w=1250;a=1250;end
                1: begin w=1250+(random_state%3);a=1250+(random_state%2);end
                2: begin w=0;a=0;end
                3: begin w=9999;a=9999;end
                4: begin w=16383;a=16383;end
                5: begin w=(cycle_index/100)%2000;a=w;end
                6: begin w=227;a=182;end
                7: begin w=1250;a=1250;end
            endcase
            enable=cycle_index%13000<12500;
            run_switch=enable;
            ready=cycle_index%7000<6500;
            sample=cycle_index%50==0 && cycle_index%17000<14000;
            stable_sample=cycle_index%2==0 && cycle_index%17000<14000;
            weight_updated=sample;price_valid=sample;
            status=cycle_index%19000>18000 ? 1:sample ? 10:7;
            weight_valid=status!=1;
            rst_n=cycle_index!=32001 && cycle_index!=100001;
        end
        for(i=0;i<3;i=i+1)
            if(quotes[i]==0) $fatal(1,"no stable quote coverage case=%0d",i);
        if(quotes[4]==0) $fatal(1,"production timer was not exercised");
        for(i=0;i<4;i=i+1) begin
            if(starts[i]<2) $fatal(1,"no automatic playback coverage case=%0d",i);
            $display("auto-case=%0d starts=%0d finishes=%0d timeouts=%0d",i,starts[i],finishes[i],timeouts[i]);
        end
        if(timeouts[1]==0 || timeouts[2]==0 || finishes[0]==0) $fatal(1,"missing end condition coverage");
        $display("VOICE_CONTROL_EQUIVALENCE_PASS cycles=160000 counter-boundaries status-crc reset disable early-timeout bridge");
        $finish;
    end
endmodule

module tb_voice_transport_equivalence;
    reg clk=0,rst_n=0,start=0;
    always #5 clk=~clk;
    reg [7:0] command=0;
    reg [4:0] count=0;
    reg [199:0] data=0;
    wire tx0,tx1,ready0,ready1,done0,done1,bad0,bad1,sv0,sv1;
    wire [1:0] status0,status1;
    cx_sp5t_uart_reference #(.CLOCK_HZ(96000)) ref_dut(
        clk,rst_n,1'b1,tx0,start,command,count,data,ready0,done0,bad0,sv0,status0);
    cx_sp5t_uart #(.CLOCK_HZ(96000)) new_dut(
        clk,rst_n,1'b1,tx1,start,command,count,data,ready1,done1,bad1,sv1,status1);
    wire compact_start=start && (command==8'h1b ? count<=14:count<=1);
    reg [199:0] compact_data;
    integer byte_index;
    always @* begin
        compact_data=0;
        for(byte_index=0;byte_index<25;byte_index=byte_index+1)
            compact_data[byte_index*8+:8]={4'd0,data[byte_index*8+:4]};
        if(command!=8'h1b) compact_data[7:0]=data[7:0];
    end
    wire ctx0,ctx1,cr0,cr1,cd0,cd1,cb0,cb1,cs0,cs1;
    wire [1:0] cp0,cp1;
    cx_sp5t_uart_reference #(.CLOCK_HZ(96000)) ref_compact(
        clk,rst_n,1'b1,ctx0,compact_start,command,count,compact_data,cr0,cd0,cb0,cs0,cp0);
    cx_sp5t_uart #(.CLOCK_HZ(96000),.MAX_DATA_BYTES(14),.COMPACT_PLAY(1)) new_compact(
        clk,rst_n,1'b1,ctx1,compact_start,command,count,compact_data,cr1,cd1,cb1,cs1,cp1);
    always @(posedge clk) begin
        #1;
        if(rst_n && {tx0,ready0,done0,bad0,sv0,status0}!=={tx1,ready1,done1,bad1,sv1,status1})
            $fatal(1,"generic UART snapshot or framing equivalence");
        if(rst_n && {ctx0,cr0,cd0,cb0,cs0,cp0}!=={ctx1,cr1,cd1,cb1,cs1,cp1})
            $fatal(1,"compact UART snapshot, control byte or framing equivalence");
    end
    task send_command(input integer opcode,length);
        integer j;
        begin
            wait(ready0);@(negedge clk);
            command=opcode;count=length;
            for(j=0;j<25;j=j+1) data[j*8+:8]=$urandom;
            start=1;@(negedge clk);start=0;
            // Change producer storage while the latched frame is being sent.
            data=~data;command=0;count=0;
            wait(ready0);@(negedge clk);
        end
    endtask
    integer i;
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        for(i=0;i<32;i=i+1) send_command('h1b,i);
        for(i=0;i<26;i=i+1) send_command('h13,i);
        $display("VOICE_TRANSPORT_EQUIVALENCE_PASS bytes=0..31 compact=0..14 snapshot-mutation generic-commands invalid-length");
        $finish;
    end
    initial begin #10000000;$fatal(1,"transport test timeout");end
endmodule
