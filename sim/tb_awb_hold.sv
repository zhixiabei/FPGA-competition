`timescale 1ns/1ps
// Production CONFIDENCE_ENABLE=0 must still obey AE hold, including blanking
// pulses and statistics that have already entered the four-stage pipeline.
module tb_awb_hold;
    localparam integer BEATS=128, LATENCY=54;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, valid=0, user=0, last=0, hold_wb=0;
    reg [95:0] data=0;
    wire out_valid, out_user, out_last;
    wire [95:0] out_data;
    awb #(.IMG_WIDTH(32),.IMG_HEIGHT(16),.CONFIDENCE_ENABLE(0)) dut (
        .I_clk(clk),.I_rst_n(rst_n),.I_tvalid(valid),.I_tuser(user),
        .I_tlast(last),.I_tdata(data),.I_hold(hold_wb),.I_tready(),
        .O_tvalid(out_valid),.O_tuser(out_user),.O_tlast(out_last),
        .O_tdata(out_data),.O_tready(1'b1));
    integer checks=0, pixels=0, expected_r=256, expected_b=256;
    reg [LATENCY-1:0] valid_ref=0, last_ref=0;
    reg [95:0] data_ref[0:LATENCY-1];
    integer stage, lane, red_value, blue_value;
    always @(posedge clk) begin
        if (!rst_n) begin
            valid_ref=0; last_ref=0;
            for(stage=0;stage<LATENCY;stage=stage+1) data_ref[stage]=0;
        end else begin
            valid_ref={valid_ref[LATENCY-2:0],valid};
            last_ref={last_ref[LATENCY-2:0],valid && last};
            for(stage=LATENCY-1;stage>0;stage=stage-1)
                data_ref[stage]=data_ref[stage-1];
            for(lane=0;lane<4;lane=lane+1) begin
                red_value=data[lane*24+16 +: 8]*expected_r/256;
                blue_value=data[lane*24 +: 8]*expected_b/256;
                data_ref[0][lane*24+16 +: 8]=red_value>255 ? 255 : red_value;
                data_ref[0][lane*24+8 +: 8]=data[lane*24+8 +: 8];
                data_ref[0][lane*24 +: 8]=blue_value>255 ? 255 : blue_value;
            end
        end
        #1;
        if(rst_n) begin
            if(out_valid!==valid_ref[LATENCY-1] || out_last!==last_ref[LATENCY-1] ||
               out_user!==user) $fatal(1,"AE hold changed video timing");
            if(out_valid) begin
                if(out_data!==data_ref[LATENCY-1])
                    $fatal(1,"AE hold changed frame gain or pixel arithmetic");
                pixels=pixels+4;
            end
        end
    end
    task automatic tick(input bit v,input bit u,input bit l,input bit h);
        @(negedge clk);
        valid=v; user=u; last=l; hold_wb=h;
        data={4{24'h506478}}; // G/R=320, G/B=213 in Q8.
        @(posedge clk); #2;
    endtask
    task automatic idle(input integer cycles,input bit h=0);
        integer k;
        for(k=0;k<cycles;k=k+1) tick(0,0,0,h);
    endtask
    task automatic reset_all;
        @(negedge clk);
        rst_n=0; valid=0; user=0; last=0; hold_wb=0;
        expected_r=256; expected_b=256;
        repeat(3) begin @(posedge clk); #2; end
        @(negedge clk); rst_n=1;
    endtask
    task automatic frame(input integer hold_beat=-1,input bit blank_pulse=0);
        integer k;
        for(k=0;k<BEATS;k=k+1) begin
            if(blank_pulse && k==32) begin
                tick(0,0,0,1);
                tick(0,0,0,0);
            end
            tick(1,k==0,k%8==7,k==hold_beat);
        end
    endtask
    task automatic no_candidate(input string reason);
        idle(100);
        checks=checks+1;
        if(dut.pending_ready || dut.div_state!=0 ||
           dut.gain_r_q8!=expected_r || dut.gain_b_q8!=expected_b)
            $fatal(1,"Invalid frozen frame survived: %s",reason);
    endtask
    task automatic recover_clean;
        frame(); idle(100);
        checks=checks+1;
        if(!dut.pending_ready || dut.pending_r_q8!=320 || dut.pending_b_q8!=213)
            $fatal(1,"A complete clean frame did not restore adaptation");
        expected_r=264; expected_b=250;
        // SOF shares its cycle with the first pixel: both must use new gains.
        tick(1,1,0,0); idle(60);
        if(dut.gain_r_q8!=264 || dut.gain_b_q8!=250)
            $fatal(1,"Clean candidate was not committed at SOF");
    endtask
    task automatic wait_final_ratio;
        integer clocks;
        clocks=0;
        while (!(dut.div_state==2 && dut.div_bit_count==0)) begin
            tick(0,0,0,0);
            clocks=clocks+1;
            if(clocks>90) $fatal(1,"Ratio did not reach its final clock");
        end
    endtask
    integer phase;
    initial begin
        // SOF on ratio completion sees no candidate yet. The immediately
        // following SOF must use the new gain for its first pixel as well.
        reset_all(); frame(); wait_final_ratio();
        tick(1,1,0,0);
        if(!dut.pending_ready || dut.gain_r_q8!=256 || dut.gain_b_q8!=256)
            $fatal(1,"Ratio completion and SOF changed commit ordering");
        expected_r=264; expected_b=250;
        tick(1,1,0,0); idle(60);
        if(dut.pending_ready || dut.gain_r_q8!=264 || dut.gain_b_q8!=250)
            $fatal(1,"Earliest SOF did not use the prepared gain");
        checks=checks+2;

        // A hold on the completion edge must discard the prepared result.
        reset_all(); frame(); wait_final_ratio();
        tick(0,0,0,1);
        no_candidate("hold on ratio completion"); recover_clean();

        reset_all();
        frame(); idle(100);
        if(!dut.pending_ready) $fatal(1,"Pending-cancel case lacks a candidate");
        tick(1,1,0,1); // Hold and SOF must win over a queued gain update.
        no_candidate("hold at commit");
        recover_clean();

        reset_all(); frame(0); no_candidate("hold at first pixel"); recover_clean();
        reset_all(); frame(31); no_candidate("hold mid-frame"); recover_clean();
        reset_all(); frame(-1,1); no_candidate("hold only in blanking"); recover_clean();
        reset_all(); frame(BEATS-1); no_candidate("hold at final pixel"); recover_clean();

        // Sweep EOF through statistics launch and both divider phases.
        for(phase=0;phase<8;phase=phase+1) begin
            reset_all(); frame();
            case(phase)
                0: idle(0); 1: idle(1); 2: idle(2); 3: idle(3);
                4: idle(4); 5: idle(20); 6: idle(50); 7: idle(82);
            endcase
            tick(0,0,0,1);
            no_candidate("hold after EOF"); recover_clean();
        end

        reset_all();
        // Release mid-frame: wait for a new full frame before adapting.
        for(phase=0;phase<BEATS;phase=phase+1)
            tick(1,phase==0,phase%8==7,phase<32);
        no_candidate("release mid-frame"); recover_clean();
        $display("AWB_HOLD_PASS checks=%0d pixels=%0d confidence=0 latency=54",checks,pixels);
        $finish;
    end
    initial begin #1000000; $fatal(1,"AWB hold test timeout"); end
endmodule
