`timescale 1ns/1ps

module tb_ae_stats_cdc;
    reg src_clk = 0, dst_clk = 0;
    bit dst_run = 1;
    always #5 src_clk = ~src_clk;
    initial begin
        #3.7;
        forever begin
            #21;
            if (dst_run) dst_clk = ~dst_clk;
        end
    end
    reg rst_n = 0, src_valid = 0;
    reg [63:0] src_data = 0;
    wire dst_valid;
    wire [63:0] dst_data;
    integer captures = 0, checks = 0;
    integer mode = 0;
    reg [63:0] expected_data;
    reg [31:0] last_sequence = 0;
    reg [31:0] max_sequence = 0;
    reg [63:0] stalled_values [0:3];
    integer stalled_captures = 0;

    ae_stats_cdc dut (
        .I_src_clk(src_clk), .I_dst_clk(dst_clk), .I_rst_n(rst_n),
        .I_src_valid(src_valid), .I_src_data(src_data),
        .O_dst_valid(dst_valid), .O_dst_data(dst_data)
    );
    reg valid_previous = 0;
    always @(posedge dst_clk) begin
        #1;
        if (!rst_n) begin
            valid_previous = 0;
        end else begin
            if (dst_valid && valid_previous)
                $fatal(1, "Destination valid must be a pulse");
            valid_previous = dst_valid;
            if (dst_valid) begin
                captures = captures + 1;
                checks = checks + 1;
                if (mode == 1 && dst_data !== expected_data)
                    $fatal(1, "64-bit payload was torn or changed: %h != %h",
                           dst_data, expected_data);
                if (mode == 2) begin
                    if (dst_data[63:32] !== ~dst_data[31:0] ||
                        dst_data[31:0] <= last_sequence ||
                        dst_data[31:0] > max_sequence)
                        $fatal(1, "Continuous stream payload/order wrong: %h last%0d max%0d",
                               dst_data, last_sequence, max_sequence);
                    last_sequence = dst_data[31:0];
                end
                if (mode == 3) begin
                    if (stalled_captures >= 4)
                        $fatal(1, "Unexpected stalled-destination capture");
                    stalled_values[stalled_captures] = dst_data;
                    stalled_captures = stalled_captures + 1;
                end
                if (mode == 4)
                    $fatal(1, "A reset-cancelled transfer leaked to destination");
            end
        end
    end

    task automatic source_pulse(input [63:0] value);
        begin
            @(negedge src_clk);
            src_data = value;
            src_valid = 1;
            @(negedge src_clk);
            src_valid = 0;
        end
    endtask

    task automatic single_transfer(input [63:0] value);
        integer before_capture, timeout_count;
        begin
            repeat (12) @(posedge src_clk);
            expected_data = value;
            mode = 1;
            before_capture = captures;
            source_pulse(value);
            timeout_count = 0;
            while (captures == before_capture && timeout_count < 100) begin
                @(posedge src_clk);
                #2;
                timeout_count = timeout_count + 1;
            end
            if (captures != before_capture + 1)
                $fatal(1, "Missing or duplicate transfer pulse");
            repeat (15) @(posedge src_clk);
            if (captures != before_capture + 1)
                $fatal(1, "Duplicate pulse after acknowledgement");
        end
    endtask

    integer bit_index, iteration, before_capture;
    reg [63:0] random_value;
    initial begin
        repeat (5) @(posedge src_clk);
        @(negedge src_clk);
        rst_n = 1;
        repeat (10) @(posedge dst_clk);
        // Identical frame statistics must all arrive, unlike a change-only CDC.
        repeat (16) single_transfer(64'h12345678_01a4_0007);
        for (bit_index = 0; bit_index < 64; bit_index = bit_index + 1) begin
            single_transfer(64'd1 << bit_index);
            single_transfer(~(64'd1 << bit_index));
        end
        for (iteration = 0; iteration < 128; iteration = iteration + 1) begin
            random_value = {$urandom, $urandom};
            single_transfer(random_value);
        end

        // Faster source frames may coalesce, but snapshots remain coherent,
        // ordered and ultimately converge to the latest complete input.
        mode = 2;
        last_sequence = 0;
        for (iteration = 1; iteration <= 300; iteration = iteration + 1) begin
            @(negedge src_clk);
            max_sequence = iteration;
            src_data = {~max_sequence, max_sequence};
            src_valid = 1;
        end
        @(negedge src_clk);
        src_valid = 0;
        repeat (80) @(posedge dst_clk);
        if (last_sequence != 300)
            $fatal(1, "Continuous CDC did not converge to latest complete input");

        repeat (20) @(posedge src_clk);
        mode = 3;
        stalled_captures = 0;
        @(negedge dst_clk);
        dst_run = 0;
        source_pulse(64'hfeedface_00000001);
        repeat (10) @(posedge src_clk);
        for (iteration = 2; iteration <= 50; iteration = iteration + 1)
            source_pulse({32'habcdef00, iteration[31:0]});
        repeat (30) @(posedge src_clk);
        if (stalled_captures != 0)
            $fatal(1, "Stopped destination captured data");
        dst_run = 1;
        repeat (80) @(posedge dst_clk);
        if (stalled_captures != 2 ||
            stalled_values[0] !== 64'hfeedface_00000001 ||
            stalled_values[1] !== 64'habcdef00_00000032)
            $fatal(1, "Stopped-destination pending snapshots wrong: count%0d first%h last%h",
                   stalled_captures, stalled_values[0], stalled_values[1]);

        // Reset while both an active and pending snapshot exist cancels both.
        repeat (20) @(posedge src_clk);
        @(negedge dst_clk);
        dst_run = 0;
        source_pulse(64'h11112222_33334444);
        source_pulse(64'h55556666_77778888);
        repeat (6) @(posedge src_clk);
        mode = 4;
        @(negedge src_clk);
        rst_n = 0;
        repeat (8) @(posedge src_clk);
        dst_run = 1;
        repeat (4) @(posedge dst_clk);
        @(negedge src_clk);
        rst_n = 1;
        repeat (20) @(posedge dst_clk);
        single_transfer(64'h01234567_89abcdef);

        // A valid assertion during reset has no effect on later frames.
        mode = 4;
        @(negedge src_clk);
        rst_n = 0;
        src_valid = 1;
        src_data = 64'hffffffff_00000000;
        repeat (5) @(posedge src_clk);
        @(negedge src_clk);
        src_valid = 0;
        rst_n = 1;
        repeat (20) @(posedge dst_clk);
        single_transfer(64'h0);
        $display("AE_STATS_CDC_PASS captures=%0d checks=%0d repeated=16 walking=128 random=128 stream=300 stalled_latest=50 resets=2",
                 captures, checks);
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "AE CDC test timed out");
    end
endmodule
