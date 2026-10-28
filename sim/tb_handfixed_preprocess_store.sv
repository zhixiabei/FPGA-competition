`timescale 1ns/1ps

module tb_handfixed_preprocess_store;
    reg clk=0,rst_n=0;
    always #5 clk=~clk;
    wire [127:0] mem_data;
    integer channel_index,word_index,checks=0;
    reg [127:0] expected;
    reg [15:0] sample_value;

    handfixed_preprocess dut(
        .clk(clk),.rst_n(rst_n),.start(1'b0),.classifier(1'b0),
        .snapshot_base(0),.roi_x(0),.roi_y(0),.roi_side(1),
        .has_texture(),.texture_edges(),.texture_range(),
        .green_valid(),.green_row_end(),.green_pixel(),.busy(),.done(),
        .mem_valid(),.mem_write(),.mem_addr(),.mem_data(mem_data),
        .mem_ready(1'b0),.mem_rsp_valid(1'b0),.mem_rsp_data(0));

    initial begin
        repeat(3) @(negedge clk);
        rst_n=1;
        for(channel_index=0;channel_index<3;channel_index=channel_index+1) begin
            expected=0;
            for(word_index=0;word_index<8;word_index=word_index+1) begin
                sample_value=16'h1000+channel_index*16'h0100+word_index;
                expected[word_index*16 +: 16]=sample_value;
                @(negedge clk);
                dut.channel=channel_index;
                dut.pack_index=word_index;
                force dut.normalized=sample_value;
                dut.state=5'd12;
                @(posedge clk);
                #1;
                release dut.normalized;
            end
            @(posedge clk);
            #1;
            if(dut.state!==5'd13 || mem_data!==expected)
                $fatal(1,"store mismatch channel=%0d state=%0d expected=%h actual=%h",
                    channel_index,dut.state,expected,mem_data);
            checks=checks+1;
        end
        $display("HANDFIXED_PREPROCESS_STORE_PASS channels=%0d words=%0d",checks,checks*8);
        $finish;
    end

    initial begin
        #10000;
        $fatal(1,"preprocess store test timeout");
    end
endmodule
