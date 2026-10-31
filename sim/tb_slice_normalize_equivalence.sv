`timescale 1ns/1ps
module tb_slice_normalize_equivalence;
    reg clk=0;
    always #5 clk=~clk;
    reg [10:0] address=0;
    wire [15:0] current_value,reference_value;
    handcnn_normalize dut(clk,address,current_value);
    handcnn_normalize_reference reference(clk,address,reference_value);
    integer i;
    initial begin
        // Every mode/channel/pixel address, ascending and descending, checks
        // the exact signed value, unused addresses and the one-cycle latency.
        for(i=0;i<4096;i=i+1) begin
            @(negedge clk);address=i<2048 ? i : 4095-i;
            @(posedge clk);#1;
            if(current_value !== reference_value)
                $fatal(1,"Normalization address=%0d current=%h reference=%h",
                    address,current_value,reference_value);
        end
        $display("SLICE_NORMALIZE_EQUIVALENCE_PASS addresses=2048 checks=4096 latency=1");
        $finish;
    end
endmodule
