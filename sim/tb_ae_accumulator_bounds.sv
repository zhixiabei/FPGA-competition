`timescale 1ns/1ps

// Interface maxima and inclusive threshold tests for narrowed accumulators.
module ae_accumulator_case #(
    parameter integer AVERAGE_FRAMES = 6,
    parameter integer SETTLE_FRAMES = 3
) (
    output reg O_done = 0
);
    localparam integer MAX_COUNT = 65535;
    reg clk = 0;
    always #21 clk = ~clk;
    reg rst = 1;
    reg camera_done = 0;
    reg ae_done = 0;
    reg stats_valid = 0;
    reg [31:0] sum_y = 0;
    reg [15:0] sample_count = 0;
    reg [15:0] bright_count = 0;
    wire request;
    wire [15:0] exposure, gain;
    integer checks = 0;
    integer request_count = 0;

    auto_exposure_control #(
        .AVERAGE_FRAMES(AVERAGE_FRAMES), .SETTLE_FRAMES(SETTLE_FRAMES)
    ) dut (
        .I_clk(clk), .I_rst(rst), .I_cam_cfg_done(camera_done),
        .I_ae_cfg_done(ae_done), .I_stats_valid(stats_valid),
        .I_sum_y(sum_y), .I_sample_count(sample_count),
        .I_bright_count(bright_count), .O_ae_req(request),
        .O_ae(exposure), .O_ag(gain)
    );

    always @(posedge clk) begin
        #1;
        if (!rst && request)
            request_count = request_count + 1;
    end

    task automatic tick;
        begin
            @(posedge clk);
            #2;
        end
    endtask
    task automatic check(input integer expected_exposure,
                         input integer expected_request,
                         input string label_text);
        begin
            checks = checks + 1;
            if (exposure !== expected_exposure || gain !== 16 ||
                request !== expected_request[0])
                $fatal(1,
                    "average=%0d settle=%0d %s expected E%0d req%0d got E%0d G%0d req%0d",
                    AVERAGE_FRAMES, SETTLE_FRAMES, label_text,
                    expected_exposure, expected_request,
                    exposure, gain, request);
        end
    endtask
    task automatic frame(input [31:0] total,
                         input integer count,
                         input integer bright);
        begin
            @(negedge clk);
            sum_y = total;
            sample_count = count;
            bright_count = bright;
            stats_valid = 1;
            tick();
            @(negedge clk);
            stats_valid = 0;
        end
    endtask
    task automatic acknowledge;
        integer frame_index;
        integer held;
        begin
            held = exposure;
            repeat (2) tick();
            check(held, 0, "stale done high holds");
            @(negedge clk);
            ae_done = 0;
            tick();
            frame(MAX_COUNT * 192, MAX_COUNT, MAX_COUNT);
            check(held, 0, "busy maximum statistics are ignored");
            @(negedge clk);
            ae_done = 1;
            tick();
            for (frame_index = 0; frame_index < SETTLE_FRAMES;
                 frame_index = frame_index + 1) begin
                frame(32'hffffffff, MAX_COUNT, 0);
                check(held, 0, "invalid statistics do not finish settling");
                frame(MAX_COUNT * 192, MAX_COUNT, MAX_COUNT);
                check(held, 0, "valid settling frame is discarded");
            end
        end
    endtask
    task automatic initialize;
        begin
            @(negedge clk);
            rst = 1;
            camera_done = 0;
            ae_done = 0;
            stats_valid = 0;
            repeat (2) tick();
            @(negedge clk);
            rst = 0;
            camera_done = 1;
            ae_done = 1;
            tick();
            check(1000, 1, "initial request");
            acknowledge();
        end
    endtask
    task automatic boundary_window(input integer mean,
                                   input integer final_offset,
                                   input integer expected_exposure,
                                   input integer expected_request);
        integer frame_index;
        begin
            for (frame_index = 0; frame_index < AVERAGE_FRAMES - 1;
                 frame_index = frame_index + 1) begin
                frame(mean * MAX_COUNT, MAX_COUNT, 0);
                check(1000, 0, "maximum-count partial window");
            end
            frame(mean * MAX_COUNT + final_offset, MAX_COUNT, 0);
            check(expected_exposure, expected_request,
                  "maximum-count threshold with final one-unit offset");
        end
    endtask

    integer frame_index;
    initial begin
        initialize();
        boundary_window(96, 0, 1000, 0);
        boundary_window(120, 0, 1000, 0);
        boundary_window(96, -1, 1125, 1);

        initialize();
        boundary_window(120, 1, 875, 1);

        initialize();
        for (frame_index = 0; frame_index < AVERAGE_FRAMES - 1;
             frame_index = frame_index + 1) begin
            frame(MAX_COUNT * 192, MAX_COUNT, MAX_COUNT);
            check(1000, 0, "maximum legal sum partial window");
        end
        frame(MAX_COUNT * 192, MAX_COUNT, MAX_COUNT);
        check(750, 1, "maximum legal sum does not wrap");

        initialize();
        for (frame_index = 0; frame_index < AVERAGE_FRAMES - 1;
             frame_index = frame_index + 1) begin
            frame(MAX_COUNT * 63, MAX_COUNT, 0);
            check(1000, 0, "maximum count dark partial window");
        end
        frame(MAX_COUNT * 192 + 1, MAX_COUNT, 0);
        check(1000, 0, "cap plus one is rejected before narrowing");
        frame(32'h80000001, MAX_COUNT, 0);
        check(1000, 0, "high 32-bit payload is rejected before narrowing");
        frame(0, 0, 0);
        check(1000, 0, "zero-count payload does not advance");
        frame(0, 1, 2);
        check(1000, 0, "bright count overflow does not advance");
        frame(MAX_COUNT * 63, MAX_COUNT, 0);
        check(1500, 1, "only final valid frame completes maximum-count window");

        $display("AE_ACCUMULATOR_CASE_PASS average=%0d settle=%0d max_count=%0d checks=%0d requests=%0d",
                 AVERAGE_FRAMES, SETTLE_FRAMES, MAX_COUNT, checks, request_count);
        O_done = 1;
    end
endmodule

module tb_ae_accumulator_bounds;
    wire [2:0] done;
    ae_accumulator_case #(.AVERAGE_FRAMES(1), .SETTLE_FRAMES(0))
        single(.O_done(done[0]));
    ae_accumulator_case #(.AVERAGE_FRAMES(6), .SETTLE_FRAMES(3))
        production(.O_done(done[1]));
    ae_accumulator_case #(.AVERAGE_FRAMES(16), .SETTLE_FRAMES(255))
        maximum(.O_done(done[2]));
    initial begin
        wait (&done);
        $display("AE_ACCUMULATOR_BOUNDS_PASS averages=1,6,16 settle=0,3,255 count=65535 raw_sum_bits=32");
        $finish;
    end
    initial begin
        #4000000;
        $fatal(1, "AE accumulator boundary test timed out");
    end
endmodule
