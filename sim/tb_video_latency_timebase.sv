`timescale 1ns/1ps

module tb_video_latency_timebase;
    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    wire [31:0] production_us;
    wire [31:0] production_gray;
    wire [15:0] fractional_us;
    wire [15:0] fractional_gray;
    wire [7:0] fast_us;
    wire [7:0] fast_gray;

    video_latency_timebase #(
        .TIME_WIDTH(32), .TIME_NUM(1), .TIME_DEN(50)
    ) production (
        .I_clk(clk), .I_rst_n(rst_n),
        .O_time_us(production_us), .O_time_gray(production_gray)
    );
    video_latency_timebase #(
        .TIME_WIDTH(16), .TIME_NUM(25), .TIME_DEN(2588)
    ) fractional (
        .I_clk(clk), .I_rst_n(rst_n),
        .O_time_us(fractional_us), .O_time_gray(fractional_gray)
    );
    video_latency_timebase #(
        .TIME_WIDTH(8), .TIME_NUM(3), .TIME_DEN(13)
    ) fast (
        .I_clk(clk), .I_rst_n(rst_n),
        .O_time_us(fast_us), .O_time_gray(fast_gray)
    );

    integer cycles = 0;
    integer checks = 0;
    integer ticks_production = 0;
    integer ticks_fractional = 0;
    integer ticks_fast = 0;
    integer fast_wraps = 0;
    reg [31:0] previous_production = 0;
    reg [15:0] previous_fractional = 0;
    reg [7:0] previous_fast = 0;
    reg [31:0] previous_production_gray = 0;
    reg [15:0] previous_fractional_gray = 0;
    reg [7:0] previous_fast_gray = 0;
    reg [31:0] expected_production;
    reg [15:0] expected_fractional;
    reg [7:0] expected_fast;
    reg [31:0] gray_difference;

    function automatic bit zero_or_one_bit(input [31:0] value);
        zero_or_one_bit = (value & (value - 1'b1)) == 0;
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            cycles = 0;
            previous_production = 0;
            previous_fractional = 0;
            previous_fast = 0;
            previous_production_gray = 0;
            previous_fractional_gray = 0;
            previous_fast_gray = 0;
        end else begin
            cycles = cycles + 1;
        end
        #0.1;
        expected_production = cycles / 50;
        expected_fractional = (cycles * 25) / 2588;
        expected_fast = (cycles * 3) / 13;
        if (production_us !== expected_production ||
            fractional_us !== expected_fractional ||
            fast_us !== expected_fast)
            $fatal(1, "Fractional time mismatch cycle=%0d production=%0d/%0d fractional=%0d/%0d fast=%0d/%0d",
                   cycles, production_us, expected_production,
                   fractional_us, expected_fractional, fast_us, expected_fast);
        if (production_gray !== (production_us ^ (production_us >> 1)) ||
            fractional_gray !== (fractional_us ^ (fractional_us >> 1)) ||
            fast_gray !== (fast_us ^ (fast_us >> 1)))
            $fatal(1, "Gray code disagrees with the timestamp cycle=%0d", cycles);
        if (rst_n) begin
            gray_difference = production_gray ^ previous_production_gray;
            if (!zero_or_one_bit(gray_difference))
                $fatal(1, "Production Gray bus changed multiple bits");
            gray_difference = fractional_gray ^ previous_fractional_gray;
            if (!zero_or_one_bit(gray_difference))
                $fatal(1, "Fractional Gray bus changed multiple bits");
            gray_difference = fast_gray ^ previous_fast_gray;
            if (!zero_or_one_bit(gray_difference))
                $fatal(1, "Fast Gray bus changed multiple bits");
            if (production_us != previous_production) begin
                if (production_us !== previous_production + 32'd1)
                    $fatal(1, "Production timestamp skipped an increment");
                ticks_production = ticks_production + 1;
            end
            if (fractional_us != previous_fractional) begin
                if (fractional_us !== previous_fractional + 16'd1)
                    $fatal(1, "Fractional timestamp skipped an increment");
                ticks_fractional = ticks_fractional + 1;
            end
            if (fast_us != previous_fast) begin
                if (fast_us !== previous_fast + 8'd1)
                    $fatal(1, "Fast timestamp skipped an increment");
                ticks_fast = ticks_fast + 1;
                if (fast_us == 0)
                    fast_wraps = fast_wraps + 1;
            end
            previous_production = production_us;
            previous_fractional = fractional_us;
            previous_fast = fast_us;
            previous_production_gray = production_gray;
            previous_fractional_gray = fractional_gray;
            previous_fast_gray = fast_gray;
            checks = checks + 1;
        end
    end

    task automatic reset_counter;
        begin
            @(negedge clk);
            rst_n = 0;
            #0.2;
            if (production_us !== 0 || fractional_us !== 0 || fast_us !== 0 ||
                production_gray !== 0 || fractional_gray !== 0 || fast_gray !== 0)
                $fatal(1, "Timestamp reset is not asynchronous");
            repeat (4) @(negedge clk);
            rst_n = 1;
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (10003) @(negedge clk);
        reset_counter();
        repeat (20704) @(negedge clk);
        reset_counter();
        repeat (2761) @(negedge clk);
        if (fast_wraps < 28 || ticks_production < 600 ||
            ticks_fractional < 300 || ticks_fast < 7000)
            $fatal(1, "Insufficient counter/Gray/wrap coverage");
        $display("VIDEO_LATENCY_TIMEBASE_PASS checks=%0d ticks_50mhz=%0d ticks_25_over_2588=%0d ticks_fast=%0d wraps=%0d resets=3",
                 checks, ticks_production, ticks_fractional, ticks_fast, fast_wraps);
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "Timestamp regression timed out");
    end
endmodule
