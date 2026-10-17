`timescale 1ns/1ps

module tb_camera_diag_cdc #(
    parameter [11:0] RESET_DATA = 12'd0
);
    localparam integer WIDTH = 12;
    localparam integer MAX_TRANSFERS = 16384;

    reg src_clk = 0;
    reg dst_clk = 0;
    reg rst_n = 0;
    reg [WIDTH-1:0] src_data = 0;
    wire [WIDTH-1:0] dst_data;
    realtime src_half_period = 21.0;
    realtime dst_half_period = 6.6665;
    bit src_run = 1;
    bit dst_run = 1;

    reg [WIDTH-1:0] expected_data [0:MAX_TRANSFERS-1];
    realtime launch_time [0:MAX_TRANSFERS-1];
    integer write_index = 0;
    integer read_index = 0;
    integer total_launches = 0;
    integer total_captures = 0;
    integer cancelled_transfers = 0;
    integer convergence_checks = 0;
    integer reset_checks = 0;

    camera_diag_cdc #(.WIDTH(WIDTH), .RESET_DATA(RESET_DATA)) dut (
        .I_src_clk(src_clk),
        .I_dst_clk(dst_clk),
        .I_rst_n(rst_n),
        .I_src_data(src_data),
        .O_dst_data(dst_data)
    );

    initial begin
        #2.137;
        forever begin
            #(src_half_period);
            if (src_run)
                src_clk = ~src_clk;
        end
    end

    initial begin
        #5.913;
        forever begin
            #(dst_half_period);
            if (dst_run)
                dst_clk = ~dst_clk;
        end
    end

    // Reference snapshots are recorded at launch, independently of the
    // destination's output. Every acknowledged capture must match in order.
    always @(posedge src_clk) begin : source_scoreboard
        reg active_before;
        reg req_before;
        reg ack_before;
        reg ack_meta_before;
        reg ack_toggle_before;
        reg [WIDTH-1:0] payload_before;
        reg [WIDTH-1:0] input_before;
        active_before = rst_n && dut.src_reset_pipe[1];
        req_before = dut.req_toggle;
        ack_before = dut.ack_sync;
        ack_meta_before = dut.ack_meta;
        ack_toggle_before = dut.ack_toggle;
        payload_before = dut.payload_hold;
        input_before = src_data;
        #0.001;
        if (rst_n) begin
            if (!active_before) begin
                if (dut.req_toggle !== 1'b0 ||
                    dut.payload_hold !== RESET_DATA ||
                    dut.ack_meta !== 1'b0 || dut.ack_sync !== 1'b0)
                    $fatal(1, "Source acted before reset release");
            end else begin
                if (dut.ack_meta !== ack_toggle_before ||
                    dut.ack_sync !== ack_meta_before)
                    $fatal(1, "Acknowledgment synchronizer is not two stages");
                if (req_before !== ack_before &&
                    (dut.payload_hold !== payload_before ||
                     dut.req_toggle !== req_before))
                    $fatal(1, "Source changed an unacknowledged snapshot");
                if (dut.req_toggle !== req_before) begin
                    if (req_before !== ack_before)
                        $fatal(1, "Source launched while mailbox was busy");
                    if (dut.payload_hold !== input_before)
                        $fatal(1, "Launch did not snapshot source input");
                    if (write_index == MAX_TRANSFERS)
                        $fatal(1, "Reference transfer storage exhausted");
                    expected_data[write_index] = input_before;
                    launch_time[write_index] = $realtime;
                    write_index = write_index + 1;
                    total_launches = total_launches + 1;
                end else if (dut.payload_hold !== payload_before) begin
                    $fatal(1, "Payload changed without a request");
                end
                if ((^{dut.req_toggle, dut.ack_meta, dut.ack_sync,
                       dut.payload_hold}) === 1'bx)
                    $fatal(1, "Unknown source mailbox state");
            end
        end
    end

    always @(posedge dst_clk) begin : destination_scoreboard
        reg active_before;
        reg req_before;
        reg req_meta_before;
        reg req_sync_before;
        reg ack_before;
        reg [WIDTH-1:0] output_before;
        active_before = rst_n && dut.dst_reset_pipe[1];
        req_before = dut.req_toggle;
        req_meta_before = dut.req_meta;
        req_sync_before = dut.req_sync;
        ack_before = dut.ack_toggle;
        output_before = dst_data;
        #0.001;
        if (rst_n) begin
            if (!active_before) begin
                if (dst_data !== RESET_DATA ||
                    dut.ack_toggle !== 1'b0 ||
                    dut.req_meta !== 1'b0 || dut.req_sync !== 1'b0)
                    $fatal(1, "Destination acted before reset release");
            end else begin
                if (dut.req_meta !== req_before ||
                    dut.req_sync !== req_meta_before)
                    $fatal(1, "Request synchronizer is not two stages");
                if (dut.ack_toggle !== ack_before) begin
                    if (req_sync_before === ack_before ||
                        dut.ack_toggle !== req_sync_before)
                        $fatal(1, "Acknowledged an absent or wrong request");
                    if (read_index >= write_index)
                        $fatal(1, "Destination captured without source launch");
                    if (dst_data !== expected_data[read_index])
                        $fatal(1, "Torn or reordered snapshot: got %h expected %h",
                               dst_data, expected_data[read_index]);
                    if ($realtime - launch_time[read_index] <
                        4.0 * dst_half_period - 0.002)
                        $fatal(1, "Payload captured before two destination periods");
                    read_index = read_index + 1;
                    total_captures = total_captures + 1;
                end else if (dst_data !== output_before) begin
                    $fatal(1, "Output changed without capture acknowledgment");
                end
                if ((^{dst_data, dut.req_meta, dut.req_sync,
                       dut.ack_toggle}) === 1'bx)
                    $fatal(1, "Unknown destination mailbox state");
            end
        end
    end

    always @(negedge rst_n) begin
        if (write_index - read_index > 1 || read_index > write_index)
            $fatal(1, "Invalid transfer occupancy at reset");
        cancelled_transfers = cancelled_transfers + write_index - read_index;
        write_index = 0;
        read_index = 0;
        #0.001;
        if (dst_data !== RESET_DATA ||
            dut.payload_hold !== RESET_DATA ||
            dut.req_toggle !== 1'b0 || dut.ack_toggle !== 1'b0 ||
            dut.req_meta !== 1'b0 || dut.req_sync !== 1'b0 ||
            dut.ack_meta !== 1'b0 || dut.ack_sync !== 1'b0 ||
            dut.src_reset_pipe !== 2'b00 ||
            dut.dst_reset_pipe !== 2'b00)
            $fatal(1, "Reset did not clear both domains asynchronously");
        reset_checks = reset_checks + 1;
    end

    task automatic set_source(input [WIDTH-1:0] value);
        begin
            @(negedge src_clk);
            #0.173;
            src_data = value;
        end
    endtask

    task automatic wait_converged(input [WIDTH-1:0] value);
        integer cycles;
        begin
            cycles = 0;
            while (dst_data !== value ||
                   dut.req_toggle !== dut.ack_sync ||
                   dut.payload_hold !== value ||
                   read_index != write_index) begin
                @(negedge src_clk);
                cycles = cycles + 1;
                if (cycles > 100)
                    $fatal(1, "Latest state did not converge to %h: got %h",
                           value, dst_data);
            end
            convergence_checks = convergence_checks + 1;
        end
    endtask

    task automatic send_and_check(input [WIDTH-1:0] value);
        begin
            set_source(value);
            wait_converged(value);
        end
    endtask

    task automatic wait_busy;
        integer cycles;
        begin
            cycles = 0;
            while (dut.req_toggle === dut.ack_sync) begin
                @(negedge src_clk);
                cycles = cycles + 1;
                if (cycles > 10)
                    $fatal(1, "Source failed to launch request");
            end
        end
    endtask

    task automatic pulse_reset(input [WIDTH-1:0] initial_value);
        begin
            #0.271;
            rst_n = 0;
            src_data = initial_value;
            #17.319;
            rst_n = 1;
            wait_converged(initial_value);
        end
    endtask

    integer value;
    integer cycle;
    reg [WIDTH-1:0] held_data;
    reg [WIDTH-1:0] held_output;
    reg held_request;

    initial begin
        // Make reset assertion an actual edge, including at startup.
        #0.019 rst_n = 1;
        #0.021 rst_n = 0;
        src_data = RESET_DATA;
        #19.417 rst_n = 1;
        repeat (5) @(negedge src_clk);
        if (dst_data !== RESET_DATA || total_launches != 0)
            $fatal(1, "Matching reset payload launched a spurious transfer");
        send_and_check(12'hA35);

        for (value = 0; value < (1 << WIDTH); value = value + 1)
            send_and_check(value[WIDTH-1:0]);
        $display("PASS: all 4096 payloads at 42 ns / 13.333 ns clocks");

        // A faster source forces intermediate values to coalesce. The
        // scoreboard still checks every launched snapshot, then the latest.
        src_half_period = 4.25;
        dst_half_period = 27.125;
        repeat (3) @(negedge dst_clk);
        for (cycle = 0; cycle < 600; cycle = cycle + 1)
            set_source((cycle * 97) ^ 12'h5A3);
        send_and_check(12'h9D2);
        for (value = 0; value < WIDTH; value = value + 1) begin
            send_and_check(12'h001 << value);
            send_and_check(~(12'h001 << value));
        end
        $display("PASS: faster source, rapid changes, walking bits");

        // No destination clocks: the first snapshot must remain held even
        // while source input changes. On resumption the final value follows.
        @(negedge dst_clk);
        dst_run = 0;
        held_output = dst_data;
        set_source(12'hC16);
        wait_busy;
        held_data = dut.payload_hold;
        held_request = dut.req_toggle;
        for (cycle = 0; cycle < 150; cycle = cycle + 1)
            set_source((cycle * 211) ^ 12'h739);
        set_source(12'h2AC);
        if (dut.payload_hold !== held_data ||
            dut.req_toggle !== held_request || dst_data !== held_output)
            $fatal(1, "Destination stall corrupted pending snapshot");
        dst_run = 1;
        wait_converged(12'h2AC);

        // Stop the source immediately after launch. The destination can
        // capture it, but cannot observe a new input until source resumes.
        set_source(12'hE47);
        wait_busy;
        @(negedge src_clk);
        src_run = 0;
        cycle = 0;
        while (dst_data !== 12'hE47) begin
            @(negedge dst_clk);
            cycle = cycle + 1;
            if (cycle > 10)
                $fatal(1, "Destination failed to capture with source stopped");
        end
        #0.173 src_data = 12'h1B8;
        repeat (6) @(negedge dst_clk);
        if (dst_data !== 12'hE47)
            $fatal(1, "Output changed while source clock was stopped");
        src_run = 1;
        wait_converged(12'h1B8);
        $display("PASS: destination and source clock stalls");

        // Reset cancels a pending transfer even while destination is
        // stopped. Its reset release waits for actual destination clocks.
        @(negedge dst_clk);
        dst_run = 0;
        set_source(12'hD03);
        wait_busy;
        #0.271 rst_n = 0;
        src_data = 12'h46F;
        #17.319 rst_n = 1;
        repeat (12) @(negedge src_clk);
        if (dst_data !== RESET_DATA ||
            dut.dst_reset_pipe !== 2'b00)
            $fatal(1, "Stopped destination released reset without clocks");
        dst_run = 1;
        wait_converged(12'h46F);

        // Also reset after capture while acknowledgment has not returned.
        set_source(12'h83E);
        wait_busy;
        @(negedge src_clk);
        src_run = 0;
        cycle = 0;
        while (dst_data !== 12'h83E) begin
            @(negedge dst_clk);
            cycle = cycle + 1;
            if (cycle > 10)
                $fatal(1, "No capture before reset-with-source-stopped");
        end
        #0.271 rst_n = 0;
        src_data = 12'h721;
        #17.319 rst_n = 1;
        repeat (6) @(negedge dst_clk);
        if (dut.src_reset_pipe !== 2'b00 || dut.req_toggle !== 1'b0)
            $fatal(1, "Stopped source released reset without clocks");
        src_run = 1;
        wait_converged(12'h721);
        pulse_reset(12'hFFF);
        pulse_reset(12'h000);
        pulse_reset(12'h5AA);
        $display("PASS: reset during pending/acknowledged transfer and startup");

        if (read_index != write_index)
            $fatal(1, "Unconsumed source snapshot at test completion");
        if (total_launches != total_captures + cancelled_transfers)
            $fatal(1, "Transfer accounting mismatch across reset");
        $display("PASS tb_camera_diag_cdc: reset_data=%h launches=%0d captures=%0d cancelled=%0d checks=%0d resets=%0d",
                 RESET_DATA,
                 total_launches, total_captures, cancelled_transfers,
                 convergence_checks, reset_checks);
        $finish;
    end

    initial begin
        #10000000;
        $fatal(1, "Testbench timeout");
    end
endmodule
