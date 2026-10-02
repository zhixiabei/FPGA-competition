`timescale 1ns/1ps
module tb_video_mode_control;
    reg clk = 0;
    always #10 clk = ~clk;
    reg rst_n = 0;
    reg key_n = 1;
    wire edge_default, rgb_default;
    integer transitions = 0;
    reg previous;
    video_mode_control #(.DEBOUNCE_CYCLES(8), .DEFAULT_EDGE_MODE(1)) u_edge (
        .I_clk(clk), .I_rst_n(rst_n), .I_key_n(key_n), .O_edge_mode(edge_default)
    );
    video_mode_control #(.DEBOUNCE_CYCLES(8), .DEFAULT_EDGE_MODE(0)) u_rgb (
        .I_clk(clk), .I_rst_n(rst_n), .I_key_n(key_n), .O_edge_mode(rgb_default)
    );
    always @(posedge clk) begin
        #1;
        if (edge_default !== ~rgb_default)
            $fatal(1, "Reset defaults or toggles disagree");
        if (!rst_n) previous = edge_default;
        else begin
            if (previous != edge_default) transitions = transitions + 1;
            previous = edge_default;
        end
    end
    task automatic hold_key(input bit level, input integer cycles);
        begin
            @(negedge clk); key_n = level;
            repeat (cycles) @(negedge clk);
        end
    endtask
    task automatic check(input bit expected, input integer count);
        begin
            if (edge_default !== expected || transitions != count)
                $fatal(1, "Button expected mode=%b transitions=%0d, got %b/%0d",
                       expected, count, edge_default, transitions);
        end
    endtask
    initial begin
        hold_key(1, 4);
        rst_n = 1;
        hold_key(1, 16); check(1, 0);
        hold_key(0, 2); hold_key(1, 2);
        hold_key(0, 2); hold_key(1, 16); check(1, 0);
        hold_key(0, 16); check(0, 1);
        hold_key(0, 100); check(0, 1);
        hold_key(1, 2); hold_key(0, 2);
        hold_key(1, 2); hold_key(0, 16); check(0, 1);
        hold_key(1, 16); check(0, 1);
        hold_key(0, 16); check(1, 2);
        hold_key(0, 100); check(1, 2);
        hold_key(1, 16);
        hold_key(0, 16); check(0, 3);
        rst_n = 0;
        hold_key(1, 4);
        rst_n = 1;
        hold_key(1, 16); check(1, 3);
        hold_key(0, 16); check(0, 4);
        $display("VIDEO_MODE_BUTTON_TEST_PASS: bounce, release, hold, reset, both defaults");
        $finish;
    end
    initial begin #1000000; $fatal(1, "Button test timeout"); end
endmodule
