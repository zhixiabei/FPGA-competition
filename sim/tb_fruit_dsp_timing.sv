`timescale 1ns/1ps

// Run against the production wrapper and TD's DSP simulation primitives.
// This reference uses independent signed 64-bit arithmetic, then wraps to
// the actual 54-bit accumulator. First-term muxctrl=02 exposes a combinational
// product; muxctrl=22 exposes the registered accumulator. The reference checks
// both the visible p port and the enabled-edge accumulation semantics.
module tb_fruit_dsp_timing;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 1;
    reg enable = 0;
    reg signed [15:0] activation = 0;
    reg signed [7:0] weight = 0;
    reg [10:0] opctrl = 11'h404;
    reg [6:0] muxctrl = 7'h02;
    wire [53:0] result;

    resnet_ph1p_dsp #(.ACTIVATION_WIDTH(16), .WEIGHT_WIDTH(8)) dut (
        .clk(clk), .rst_n(rst_n), .enable(enable),
        .activation(activation), .weight(weight),
        .opctrl(opctrl), .muxctrl(muxctrl), .result(result)
    );

    reg signed [53:0] reference_acc = 0;
    reg [31:0] random_state = 32'h31415926;
    reg signed [15:0] activation_corners [0:6];
    reg signed [7:0] weight_corners [0:6];
    integer checked_edges = 0;
    integer checked_holds = 0;
    integer enabled_terms = 0;
    integer fresh_sums = 0;
    integer bubbles = 0;
    integer async_resets = 0;
    integer a, w, i;
    reg [31:0] random_control, random_data;

    function [31:0] next_random;
        input [31:0] value;
        reg [31:0] shifted;
        begin
            shifted = value ^ (value << 13);
            shifted = shifted ^ (shifted >> 17);
            next_random = shifted ^ (shifted << 5);
        end
    endfunction

    task check_result;
        input [127:0] phase;
        input [53:0] expected;
        begin
            if (result !== expected) begin
                $display("FRUIT_DSP_TIMING_FAIL phase=%0s edge=%0d en=%0d a=%0d w=%0d op=%h mux=%h got=%0d expected=%0d",
                         phase, checked_edges, enable, activation, weight,
                         opctrl, muxctrl, $signed(result), $signed(expected));
                $fatal(1, "DSP latency, hold, reset, or signed arithmetic mismatch");
            end
        end
    endtask

    task cycle;
        input issued;
        input first;
        input signed [15:0] act;
        input signed [7:0] wt;
        reg signed [63:0] cpu_activation, cpu_weight, cpu_product;
        reg signed [63:0] cpu_next;
        begin
            @(negedge clk);
            enable = issued;
            activation = act;
            weight = wt;
            opctrl = first ? 11'h404 : 11'h40c;
            muxctrl = first ? 7'h02 : 7'h22;
            cpu_activation = $signed(act);
            cpu_weight = $signed(wt);
            cpu_product = cpu_activation * cpu_weight;
            #1;
            check_result("before_edge", first ? cpu_product[53:0] : reference_acc);
            checked_holds = checked_holds + 1;
            @(posedge clk);
            if (issued) begin
                cpu_next = first ? cpu_product : $signed(reference_acc) + cpu_product;
                reference_acc = cpu_next[53:0];
                enabled_terms = enabled_terms + 1;
                if (first) fresh_sums = fresh_sums + 1;
            end else bubbles = bubbles + 1;
            #1;
            checked_edges = checked_edges + 1;
            check_result("after_edge", first ? cpu_product[53:0] : reference_acc);
        end
    endtask

    task reset_between_edges;
        begin
            @(negedge clk);
            enable = 1;
            opctrl = 11'h40c;
            muxctrl = 7'h22;
            #1;
            rst_n = 0;
            reference_acc = 0;
            #1;
            check_result("async_reset", 54'd0);
            @(posedge clk);
            #1;
            check_result("reset_priority", 54'd0);
            @(negedge clk);
            enable = 0;
            rst_n = 1;
            #1;
            check_result("reset_release", 54'd0);
            async_resets = async_resets + 1;
        end
    endtask

    initial begin
        activation_corners[0] = -32768;
        activation_corners[1] = -2048;
        activation_corners[2] = -1;
        activation_corners[3] = 0;
        activation_corners[4] = 1;
        activation_corners[5] = 2047;
        activation_corners[6] = 32767;
        weight_corners[0] = -128;
        weight_corners[1] = -127;
        weight_corners[2] = -1;
        weight_corners[3] = 0;
        weight_corners[4] = 1;
        weight_corners[5] = 126;
        weight_corners[6] = 127;

        // The vendor GSR model releases its startup gate after 20 ns.
        #100;
        reset_between_edges();
        for (a = 0; a < 7; a = a + 1)
            for (w = 0; w < 7; w = w + 1) begin
                cycle(1, 1, activation_corners[a], weight_corners[w]);
                cycle(1, 0, activation_corners[6-a], weight_corners[6-w]);
                // Inactive first-term controls expose a product but must not
                // alter the feedback accumulator used by the following term.
                cycle(0, 1, 16'sh8000, 8'sh80);
                cycle(1, 0, activation_corners[a], weight_corners[w]);
            end

        // A long sequence exceeds a 32-bit accumulator and checks signed A16
        // rather than only the narrower A12 values normally stored in DDR.
        cycle(1, 1, -32768, -128);
        for (i = 0; i < 2048; i = i + 1)
            cycle(1, 0, -32768, -128);
        cycle(0, 0, 32767, 127);
        reset_between_edges();

        for (i = 0; i < 8192; i = i + 1) begin
            random_state = next_random(random_state);
            random_control = random_state;
            random_state = next_random(random_state);
            random_data = random_state;
            cycle(random_control[1:0] != 0, random_control[5:2] == 0,
                  random_data[15:0], random_data[23:16]);
            if (i == 1023 || i == 4095) reset_between_edges();
        end
        cycle(1, 1, -12345, 73);
        reset_between_edges();
        cycle(0, 0, 32767, 127);
        cycle(1, 1, -32768, -128);
        cycle(1, 0, 32767, 127);
        $display("FRUIT_DSP_TIMING_PASS edges=%0d prechecks=%0d enabled=%0d fresh=%0d bubbles=%0d async_resets=%0d first_p=COMBINATIONAL accumulate_p=REGISTERED",
                 checked_edges, checked_holds, enabled_terms, fresh_sums,
                 bubbles, async_resets);
        $finish;
    end

    initial begin
        #500000;
        $fatal(1, "DSP regression timeout");
    end
endmodule
