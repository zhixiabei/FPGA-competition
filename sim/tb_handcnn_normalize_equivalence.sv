`timescale 1ns/1ps

module tb_handcnn_normalize_equivalence;
    reg clk=0;
    always #5 clk=~clk;

    reg [10:0] address=0;
    wire [15:0] optimized_value;
    wire [15:0] reference_value;
    integer i;
    integer vectors=0,hold_checks=0;
    reg primed=0;
    reg [15:0] previous_value;

    handcnn_normalize optimized(
        .clk(clk),.address(address),.value(optimized_value));
    handcnn_normalize_case_ref reference_rom(
        .clk(clk),.address(address),.value(reference_value));

    task apply_address(input [10:0] next_address);
        begin
            @(negedge clk);
            address=next_address;
            #1;
            if(primed) begin
                if(optimized_value!==previous_value)
                    $fatal(1,"normalization changed before rising edge address=%0d",address);
                hold_checks=hold_checks+1;
            end
            @(posedge clk);
            #1;
            if(optimized_value!==reference_value)
                $fatal(1,"normalization mismatch address=%0d expected=%h actual=%h",
                    address,reference_value,optimized_value);
            previous_value=optimized_value;
            primed=1;
            vectors=vectors+1;
        end
    endtask

    initial begin
        for(i=0;i<2048;i=i+1) apply_address(i[10:0]);
        // An odd-stride permutation visits every address again, crossing
        // active/zero pages and all three signed channel ranges frequently.
        for(i=0;i<2048;i=i+1) apply_address((i*151+997)&2047);
        $display("HANDCNN_NORMALIZE_EQUIVALENCE_PASS addresses=2048 vectors=%0d hold_checks=%0d signed12_to_int16=1 unused_pages_zero=1",
            vectors,hold_checks);
        $finish;
    end

    initial begin
        #100000;
        $fatal(1,"normalization equivalence test timeout");
    end
endmodule
