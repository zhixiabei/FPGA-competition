`timescale 1ns/1ps
module tb_video_packer_pipeline;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,valid=0,sof=0;
    reg [95:0] data=0;
    wire out_valid,out_sof;
    wire [127:0] packed_data;
    data_96bit_to_128bit dut(
        .I_clk(clk),.I_rst_n(rst_n),.I_96b_frame_start(sof),
        .I_96b_valid(valid),.I_96b_data(data),
        .O_128b_frame_start(out_sof),.O_128b_valid(out_valid),.O_128b_data(packed_data)
    );
    reg [7:0] bytes[0:131071];
    reg expected_sof=0,expected_valid=0;
    integer line_beats=0;
    integer written=0,read_count=0,checked_bytes=0,checked_sofs=0;
    integer byte_index;
    always @(posedge clk) begin
        if(!rst_n) begin
            written=0;read_count=0;expected_sof=0;expected_valid=0;line_beats=0;
        end else begin
            if(out_sof!==expected_sof) $fatal(1,"SOF latency changed from one clock");
            if(out_valid!==expected_valid) $fatal(1,"Packed output cycle changed");
            if(out_sof) checked_sofs=checked_sofs+1;
            expected_sof=sof;
            expected_valid=valid && line_beats%4!=0;
            line_beats=valid ? line_beats+1 : 0;
            if(valid) begin
                for(byte_index=0;byte_index<12;byte_index=byte_index+1)
                    bytes[written+byte_index]=data[95-byte_index*8-:8];
                written=written+12;
            end
            if(out_valid) begin
                if(read_count+16>written) $fatal(1,"Packer emitted unreceived bytes");
                for(byte_index=0;byte_index<16;byte_index=byte_index+1)
                    if(packed_data[127-byte_index*8-:8]!==bytes[read_count+byte_index])
                        $fatal(1,"Packer byte order mismatch at %0d",read_count+byte_index);
                read_count=read_count+16;checked_bytes=checked_bytes+16;
            end
        end
    end
    integer frame,line_index,beat,lane,serial=0;
    task sample;
        begin
            for(lane=0;lane<12;lane=lane+1) begin
                data[95-lane*8-:8]=(serial*73)^(serial>>7);
                serial=serial+1;
            end
        end
    endtask
    task blank;
        input integer count;
        begin
            valid=0;sof=0;
            repeat(count) begin sample();@(negedge clk);end
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);
        rst_n=1;
        for(frame=0;frame<6;frame=frame+1) begin
            sof=1;
            // Exercise SOF both with the first pixel and before active data.
            if(frame[0]) begin @(negedge clk);blank(4);end
            for(line_index=0;line_index<8;line_index=line_index+1) begin
                for(beat=0;beat<320;beat=beat+1) begin
                    valid=1;sample();@(negedge clk);sof=0;
                end
                // A single blank cycle is sufficient to restart phase.
                blank(line_index%3+1);
            end
            blank(8);
            if(written!=read_count) $fatal(1,"Lost bytes at frame end");
            rst_n=0;repeat(2) @(negedge clk);rst_n=1;
        end
        // A reset aborts the partially accumulated group and in-flight SOF.
        sof=1;valid=1;sample();@(negedge clk);
        rst_n=0;blank(3);rst_n=1;
        for(beat=0;beat<4;beat=beat+1) begin valid=1;sample();@(negedge clk);end
        blank(5);
        if(written!=read_count || checked_sofs!=6)
            $fatal(1,"Reset or frame-marker coverage failed");
        $display("VIDEO_PACKER_PIPELINE_PASS bytes=%0d frames=%0d reset_inflight=1 latency=1",checked_bytes,checked_sofs);
        $finish;
    end
    initial begin #1000000;$fatal(1,"Packer pipeline timeout");end
endmodule
