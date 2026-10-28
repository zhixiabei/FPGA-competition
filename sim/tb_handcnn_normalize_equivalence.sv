`timescale 1ns/1ps

module tb_handcnn_normalize_equivalence;
    reg clk=0;
    always #5 clk=~clk;

    reg [10:0] address=0;
    wire [15:0] optimized_value;
    wire [15:0] reference_value;
    integer i;

    handcnn_normalize optimized(
        .clk(clk),.address(address),.value(optimized_value));
    handcnn_normalize_case_ref reference_rom(
        .clk(clk),.address(address),.value(reference_value));

    initial begin
        for(i=0;i<2048;i=i+1) begin
            @(negedge clk);
            address=i[10:0];
            @(posedge clk);
            #1;
            if(optimized_value!==reference_value)
                $fatal(1,"normalization mismatch address=%0d expected=%h actual=%h",
                    address,reference_value,optimized_value);
        end
        $display("HANDCNN_NORMALIZE_EQUIVALENCE_PASS addresses=%0d",i);
        $finish;
    end

    initial begin
        #30000;
        $fatal(1,"normalization equivalence test timeout");
    end
endmodule
