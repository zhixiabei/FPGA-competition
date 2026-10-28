`timescale 1ns/1ps
module tb_fruitfixed_result_filter;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,clear=0,in_valid=0;
    reg [2:0] in_class=1;
    wire [2:0] decision_class,stable_class;

    fruitfixed_result_filter dut(.*);

    task sample;
        input valid;
        input [2:0] raw;
        input [2:0] expected;
        begin
            @(negedge clk);
            in_valid=valid;
            in_class=raw;
            #1;
            if(decision_class!==expected)
                $fatal(1,"decision raw=%0d valid=%0d got=%0d want=%0d",
                    raw,valid,decision_class,expected);
            @(posedge clk);
            #1;
            if(stable_class!==expected)
                $fatal(1,"stable raw=%0d valid=%0d got=%0d want=%0d",
                    raw,valid,stable_class,expected);
        end
    endtask

    initial begin
        repeat(2) @(negedge clk);
        rst_n=1;

        // UNKNOWN -> fruit needs two matching results.
        sample(1,3'd2,3'd1);
        sample(0,3'd6,3'd1);
        sample(1,3'd2,3'd2);

        // A single skipped/flat-frame UNKNOWN must not clear a stable fruit.
        sample(1,3'd1,3'd2);
        sample(1,3'd2,3'd2);

        // Fruit-to-fruit changes need three consecutive matching results.
        sample(1,3'd5,3'd2);
        sample(1,3'd5,3'd2);
        sample(1,3'd5,3'd5);

        // Fruit -> UNKNOWN also needs three consecutive results.
        sample(1,3'd1,3'd5);
        sample(1,3'd1,3'd5);
        sample(0,3'd1,3'd5);
        sample(1,3'd1,3'd1);

        // UNKNOWN -> fruit remains responsive at two results.
        sample(1,3'd3,3'd1);
        sample(1,3'd3,3'd3);

        $display("FRUIT_RESULT_FILTER_PASS unknown_to_fruit=2 switch=3 release=3 bubbles_ignored=1");
        $finish;
    end
endmodule
