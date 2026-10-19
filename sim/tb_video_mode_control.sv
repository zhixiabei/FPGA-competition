`timescale 1ns/1ps
module tb_video_mode_control;
    reg clk = 0;
    always #10 clk = ~clk;
    reg rst_n = 0;
    reg key_n = 1;
    wire [1:0] mode;
    wire motion;
    integer transitions = 0;
    reg [1:0] previous;
    video_mode_control #(.DEBOUNCE_CYCLES(8), .DEFAULT_MODE(0)) dut (
        .I_clk(clk), .I_rst_n(rst_n), .I_key_n(key_n),
        .O_detection_mode(mode), .O_edge_mode(motion)
    );
    always @(posedge clk) begin
        #1;
        if (motion !== (mode == 2'd3))
            $fatal(1, "Motion decode disagrees with mode %0d",mode);
        if (!rst_n) previous = mode;
        else begin
            if (previous != mode) transitions = transitions + 1;
            previous = mode;
        end
    end
    task automatic hold_key(input bit level, input integer cycles);
        begin
            @(negedge clk); key_n = level;
            repeat (cycles) @(negedge clk);
        end
    endtask
    task automatic check(input [1:0] expected, input integer count);
        begin
            if (mode !== expected || transitions != count)
                $fatal(1, "Button expected mode=%b transitions=%0d, got %b/%0d",
                       expected, count, mode, transitions);
        end
    endtask
    initial begin
        hold_key(1, 4);
        rst_n = 1;
        hold_key(1, 16); check(0, 0);
        hold_key(0, 2); hold_key(1, 2);
        hold_key(0, 2); hold_key(1, 16); check(0, 0);
        hold_key(0, 16); check(1, 1);
        hold_key(0, 100); check(1, 1);
        hold_key(1, 2); hold_key(0, 2);
        hold_key(1, 2); hold_key(0, 16); check(1, 1);
        hold_key(1, 16); check(1, 1);
        hold_key(0, 16); check(2, 2);
        hold_key(0, 100); check(2, 2);
        hold_key(1, 16);
        hold_key(0, 16); check(3, 3);
        hold_key(1, 16);
        hold_key(0, 16); check(0, 4);
        rst_n = 0;
        hold_key(1, 4);
        rst_n = 1;
        hold_key(1, 16); check(0, 4);
        hold_key(0, 16); check(1, 5);
        $display("VIDEO_MODE_BUTTON_TEST_PASS: RED GREEN BLUE MOTION cycle, bounce, hold, reset");
        $finish;
    end
    initial begin #1000000; $fatal(1, "Button test timeout"); end
endmodule
