`timescale 1ns/1ps

// Independent decimal-string reference checks the compressed production path
// and the public 24-bit/custom-clip interface, including unused output bytes.
module voice_phrase_width_check #(
    parameter integer VALUE_WIDTH=14,
    parameter [7:0] KG=11,YUAN=12,POINT=13
)(output reg finished=0);
    reg clk=0,rst_n=0,start=0;
    always #5 clk=~clk;
    reg [23:0] weight_g=0,amount_fen=0;
    wire ready,done;
    wire [4:0] count;
    wire [199:0] clips;
    localparam integer MAX_VALUE=(1<<VALUE_WIDTH)-1;
    scale_voice_phrase #(.VALUE_WIDTH(VALUE_WIDTH),.CLIP_KG(KG),
        .CLIP_YUAN(YUAN),.CLIP_POINT(POINT)) dut(
        .clk(clk),.rst_n(rst_n),.start(start),.weight_g(weight_g),
        .amount_fen(amount_fen),.ready(ready),.done(done),
        .clip_count(count),.clips(clips));

    task check(input integer weight_value,amount_value);
        string weight_text,amount_text;
        reg [199:0] expected;
        integer n,i;
        begin
            weight_text=$sformatf("%0d.%03d",weight_value/1000,weight_value%1000);
            amount_text=$sformatf("%0d.%02d",amount_value/100,amount_value%100);
            expected=0;n=0;
            for(i=0;i<weight_text.len();i=i+1) begin
                expected[n*8+:8]=weight_text[i]==46 ? POINT:weight_text[i]-48+1;
                n=n+1;
            end
            expected[n*8+:8]=KG;n=n+1;
            for(i=0;i<amount_text.len();i=i+1) begin
                expected[n*8+:8]=amount_text[i]==46 ? POINT:amount_text[i]-48+1;
                n=n+1;
            end
            expected[n*8+:8]=YUAN;n=n+1;
            @(negedge clk);
            if(!ready) $fatal(1,"phrase was not ready width=%0d",VALUE_WIDTH);
            weight_g=weight_value;amount_fen=amount_value;start=1;
            @(negedge clk);start=0;
            wait(done);@(negedge clk);
            if(count!==n || clips!==expected || !ready)
                $fatal(1,"width=%0d weight=%0d amount=%0d count=%0d/%0d clips=%h/%h",
                    VALUE_WIDTH,weight_value,amount_value,count,n,clips,expected);
        end
    endtask

    integer i;
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        check(0,0);check(MAX_VALUE,MAX_VALUE);
        check(0,MAX_VALUE);check(MAX_VALUE,0);
        if(MAX_VALUE>=9999) check(9999,9999);
        for(i=0;i<100;i=i+1)
            check($urandom_range(0,MAX_VALUE),$urandom_range(0,MAX_VALUE));
        finished=1;
    end
endmodule

module tb_voice_phrase_widths;
    wire minimum_done,production_done,full_done;
    voice_phrase_width_check #(.VALUE_WIDTH(1)) minimum(minimum_done);
    voice_phrase_width_check #(.VALUE_WIDTH(14)) production(production_done);
    voice_phrase_width_check #(.VALUE_WIDTH(24),.KG(255),.YUAN(254),.POINT(253))
        full(full_done);
    initial begin
        wait(minimum_done && production_done && full_done);
        $display("VOICE_PHRASE_WIDTHS_PASS 1-bit 14-bit 24-bit full-range custom-clips unused-bytes");
        $finish;
    end
    initial begin #1000000;$fatal(1,"phrase width watchdog");end
endmodule
