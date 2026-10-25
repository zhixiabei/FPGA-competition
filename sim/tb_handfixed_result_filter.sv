`timescale 1ns/1ps
module tb_handfixed_result_filter;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,clear=0,in_valid=0;
    reg [2:0] in_class=1;
    wire [2:0] decision_class,stable_class;
    reg [8:0] vectors[0:100000];
    integer n,i,fd;
    handfixed_result_filter dut(.*);
    initial begin
        fd=$fopen("filter_vector_count.txt","r");
        if(!fd || $fscanf(fd,"%d",n)!=1) $fatal(1,"missing filter vectors");
        $fclose(fd);
        $readmemh("filter_vectors.hex",vectors,0,n-1);
        repeat(2) @(negedge clk);
        for(i=0;i<n;i=i+1) begin
            {rst_n,clear,in_valid,in_class}=vectors[i][8:3];
            #1;
            // The source publisher consumes this BEFORE the state edge.
            if(rst_n && decision_class!==vectors[i][2:0])
                $fatal(1,"same-edge result i=%0d got=%0d want=%0d",i,decision_class,vectors[i][2:0]);
            @(posedge clk);#1;
            if(stable_class!==vectors[i][2:0])
                $fatal(1,"registered result i=%0d got=%0d want=%0d",i,stable_class,vectors[i][2:0]);
            @(negedge clk);
        end
        $display("HANDFIXED_FILTER_PASS cycles=%0d exhaustive_histories=4096 stalls clear reset",n);
        $finish;
    end
endmodule
