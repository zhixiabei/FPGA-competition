`timescale 1ns/1ps

// Independent tensor convolution/pooling reference plus a DDR device model.
// No DUT state is used to calculate numerical expected values or MAC order.
module tb_fruit_core_numeric;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0, start = 0;
    reg [383:0] descriptor;
    wire [2:0] group_id;
    wire busy, done, fault, mem_valid, mem_write;
    wire [31:0] mem_addr, cycles, mac_cycles, wait_cycles;
    wire [127:0] mem_data;
    reg mem_ready = 0, mem_rsp_valid = 0;
    reg [127:0] mem_rsp_data = 0;
    fruitcnn128_core dut(
        .clk(clk), .rst_n(rst_n), .start(start), .operation(5'd9),
        .group(group_id), .descriptor(descriptor), .busy(busy),
        .done(done), .fault(fault), .mem_valid(mem_valid),
        .mem_write(mem_write), .mem_addr(mem_addr), .mem_data(mem_data),
        .mem_ready(mem_ready), .mem_rsp_valid(mem_rsp_valid),
        .mem_rsp_data(mem_rsp_data), .cycles(cycles),
        .mac_cycles(mac_cycles), .wait_cycles(wait_cycles)
    );
`ifdef FRUIT_CORE_ROUTING_REFERENCE
    wire [2:0] reference_group;
    wire reference_busy, reference_done, reference_fault;
    wire reference_mem_valid, reference_mem_write;
    wire [31:0] reference_mem_addr, reference_cycles, reference_mac_cycles, reference_wait_cycles;
    wire [127:0] reference_mem_data;
    integer equivalence_cycles = 0;
    fruitcnn128_core_reference reference_core(
        .clk(clk), .rst_n(rst_n), .start(start), .operation(5'd9),
        .group(reference_group), .descriptor(descriptor), .busy(reference_busy),
        .done(reference_done), .fault(reference_fault), .mem_valid(reference_mem_valid),
        .mem_write(reference_mem_write), .mem_addr(reference_mem_addr), .mem_data(reference_mem_data),
        .mem_ready(mem_ready), .mem_rsp_valid(mem_rsp_valid), .mem_rsp_data(mem_rsp_data),
        .cycles(reference_cycles), .mac_cycles(reference_mac_cycles), .wait_cycles(reference_wait_cycles)
    );
    always @(negedge clk) begin
        #2;
        if ({group_id,busy,done,fault,mem_valid,mem_write,mem_addr,mem_data,cycles,mac_cycles,wait_cycles} !==
            {reference_group,reference_busy,reference_done,reference_fault,reference_mem_valid,
             reference_mem_write,reference_mem_addr,reference_mem_data,reference_cycles,
             reference_mac_cycles,reference_wait_cycles})
            $fatal(1, "FRUIT_CORE_ROUTING_EQUIVALENCE_FAIL cycle=%0d state=%0d/%0d",
                   equivalence_cycles,dut.state,reference_core.state);
        equivalence_cycles = equivalence_cycles + 1;
    end
    genvar checked_lane;
    generate for (checked_lane=0;checked_lane<24;checked_lane=checked_lane+1) begin: lane_equivalence
        always @(posedge clk) if (rst_n) begin
            if (dut.lanes[checked_lane].mac.enable !== reference_core.mac_enable)
                $fatal(1,"FRUIT_CORE_ROUTING_ENABLE_FAIL lane=%0d",checked_lane);
            if (reference_core.mac_enable &&
                ({dut.lanes[checked_lane].mac.activation,dut.lanes[checked_lane].mac.opctrl,
                  dut.lanes[checked_lane].mac.muxctrl} !==
                 {reference_core.lanes[checked_lane].mac.activation,reference_core.lanes[checked_lane].mac.opctrl,
                  reference_core.lanes[checked_lane].mac.muxctrl}))
                $fatal(1,"FRUIT_CORE_ROUTING_MAC_INPUT_FAIL lane=%0d",checked_lane);
        end
    end endgenerate
`endif

    localparam [31:0] SRC_BASE = 32'h1000;
    localparam [31:0] WEIGHT_BASE = 32'h20000;
    localparam [31:0] COEFF_BASE = 32'h60000;
    localparam [31:0] DST_BASE = 32'h80000;
    integer width = 8, height = 1, kernel = 1, stride = 1, padding = 0;
    integer input_channels = 1, output_channels = 1;
    integer output_width = 8, output_height = 1, area = 8;
    integer source_plane = 8, destination_plane = 8, terms = 1;
    integer pooling = 0, relu = 0, pattern_id = 0;
    integer response_mode = 0, stall_mode = 0;
    integer wall_cycle = 0, qhead = 0, qtail = 0, qcount = 0;
    integer queue_due [0:31];
    reg [127:0] queue_data [0:31];
    integer reads = 0, activation_reads = 0, writes = 0, stalls = 0;
    integer observed_macs = 0, expected_term = 0, expected_pos = 0, expected_group = 0;
    integer write_group = 0, write_tile = 0, write_lane = 0;
    integer last_cycles = 0, cases_passed = 0;
    reg [31:0] operation_cycle_base = 0, operation_mac_base = 0;
    reg checking = 0, previous_stall = 0;
    reg [31:0] stalled_addr;
    reg [127:0] stalled_data;
    reg stalled_write;

    always @* begin
        descriptor = 0;
        descriptor[0] = pooling != 0;
        descriptor[8] = relu != 0;
        descriptor[19:16] = kernel;
        descriptor[27:24] = stride;
        descriptor[35:32] = padding;
        descriptor[57:48] = input_channels;
        descriptor[73:64] = output_channels;
        descriptor[87:80] = width;
        descriptor[95:88] = height;
        descriptor[103:96] = output_width;
        descriptor[111:104] = output_height;
        descriptor[127:112] = source_plane;
        descriptor[143:128] = destination_plane;
        descriptor[175:144] = SRC_BASE;
        descriptor[207:176] = DST_BASE;
        descriptor[239:208] = WEIGHT_BASE + group_id * 32'h8000;
        descriptor[271:240] = COEFF_BASE + group_id * 32'h1000;
        descriptor[287:272] = input_channels * source_plane / 8;
        descriptor[303:288] = terms;
        descriptor[319:304] = area;
        descriptor[351:320] = DST_BASE + group_id * 24 * destination_plane * 2;
    end

    function integer activation_value;
        input integer address;
        integer value;
        begin
            value = ((address * 137 + pattern_id * 431 + 37) % 4096) - 2048;
            case (address % 17)
                0: value = -2048;
                1: value = 2047;
                2: value = -1;
                3: value = 0;
                4: value = 1;
            endcase
            activation_value = value;
        end
    endfunction

    function integer weight_value;
        input integer channel, term_index;
        begin
            if (channel >= output_channels) weight_value = 0;
            else weight_value = ((channel * 29 + term_index * 43 + pattern_id * 7) % 256) - 128;
        end
    endfunction

    function signed [39:0] bias_value;
        input integer channel;
        begin
            case (channel % 8)
                0: bias_value = 40'sd40001;
                1: bias_value = -40'sd40003;
                2: bias_value = 40'sd2047;
                3: bias_value = -40'sd2048;
                4: bias_value = 40'sd1;
                5: bias_value = -40'sd1;
                6: bias_value = 40'sd109951;
                default: bias_value = -40'sd109953;
            endcase
        end
    endfunction

    function integer shift_value;
        input integer channel;
        begin shift_value = channel % 5; end
    endfunction

    function integer expected_activation;
        input integer position, term_index;
        integer x, y, input_channel, xx, yy;
        begin
            input_channel = term_index / (kernel * kernel);
            y = (term_index / kernel) % kernel;
            x = term_index % kernel;
            xx = (position % output_width) * stride + x - padding;
            yy = (position / output_width) * stride + y - padding;
            if (xx < 0 || yy < 0 || xx >= width || yy >= height)
                expected_activation = 0;
            else expected_activation = activation_value(input_channel * source_plane + yy * width + xx);
        end
    endfunction

    function [15:0] expected_output;
        input integer channel, position;
        reg signed [63:0] sum, product, biased_sum, shifted_sum;
        integer t, xx, yy, input_channel;
        begin
            sum = 0;
            if (pooling) begin
                input_channel = channel / 4;
                for (yy = 0; yy < 4; yy = yy + 1)
                    for (xx = 0; xx < 4; xx = xx + 1)
                        sum = sum + activation_value(input_channel * source_plane +
                            ((channel / 2) % 2 * 4 + yy) * width + (channel % 2) * 4 + xx);
                shifted_sum = sum >>> 4;
            end else begin
                for (t = 0; t < terms; t = t + 1) begin
                    product = expected_activation(position, t);
                    product = product * weight_value(channel, t);
                    sum = sum + product;
                end
                biased_sum = sum + $signed(bias_value(channel));
                shifted_sum = biased_sum >>> shift_value(channel);
                if (relu && shifted_sum < 0) shifted_sum = 0;
                else if (relu && shifted_sum > 2047) shifted_sum = 2047;
                else if (shifted_sum > 32767) shifted_sum = 32767;
                else if (shifted_sum < -32768) shifted_sum = -32768;
            end
            expected_output = shifted_sum[15:0];
        end
    endfunction

    function [127:0] read_beat;
        input [31:0] address;
        integer index, lane_index, channel, t, half, b, g;
        reg [127:0] word;
        reg signed [39:0] bias;
        begin
            word = 0;
            if (address >= SRC_BASE && address < SRC_BASE + input_channels * source_plane * 2) begin
                index = (address - SRC_BASE) / 2;
                for (b = 0; b < 8; b = b + 1)
                    word[b*16 +: 16] = activation_value(index + b);
            end else if (address >= WEIGHT_BASE && address < COEFF_BASE) begin
                g = (address - WEIGHT_BASE) / 'h8000;
                index = ((address - WEIGHT_BASE) % 'h8000) / 16;
                t = index / 2;
                half = index % 2;
                for (b = 0; b < 16; b = b + 1) begin
                    lane_index = half * 16 + b;
                    if (lane_index < 24) word[b*8 +: 8] = weight_value(g * 24 + lane_index, t);
                end
            end else if (address >= COEFF_BASE && address < DST_BASE) begin
                g = (address - COEFF_BASE) / 'h1000;
                index = ((address - COEFF_BASE) % 'h1000) / 16;
                for (b = 0; b < 2; b = b + 1) begin
                    channel = g * 24 + index * 2 + b;
                    bias = bias_value(channel);
                    word[b*64 +: 40] = bias;
                    word[b*64+40 +: 6] = shift_value(channel);
                end
            end else $fatal(1, "Unexpected DDR read address %h", address);
            read_beat = word;
        end
    endfunction

    // The device responds in request order. Mode 0 permits a response on the
    // request's accepting edge; modes 1/2 delay it and permit burst overlap.
    integer delay_cycles;
    always @(negedge clk) begin
        mem_rsp_valid = 0;
        mem_rsp_data = 0;
        if (!rst_n) begin
            mem_ready = 0;
            qhead = 0; qtail = 0; qcount = 0;
        end else begin
            mem_ready = !stall_mode || ((wall_cycle % 7) != 0 && (wall_cycle % 11) > 2);
            if (qcount > 0 && queue_due[qhead] <= wall_cycle) begin
                mem_rsp_valid = 1;
                mem_rsp_data = queue_data[qhead];
                qhead = (qhead + 1) % 32;
                qcount = qcount - 1;
            end
            if (mem_valid && mem_ready && !mem_write) begin
                reads = reads + 1;
                if (mem_addr < WEIGHT_BASE) activation_reads = activation_reads + 1;
                if (response_mode == 0 && qcount == 0 && !mem_rsp_valid) begin
                    mem_rsp_valid = 1;
                    mem_rsp_data = read_beat(mem_addr);
                end else begin
                    delay_cycles = response_mode == 1 ? 1 : 2 + ((reads * 3 + pattern_id) % 7);
                    if (qcount >= 31) $fatal(1, "DDR response queue overflow");
                    queue_data[qtail] = read_beat(mem_addr);
                    queue_due[qtail] = wall_cycle + delay_cycles;
                    qtail = (qtail + 1) % 32;
                    qcount = qcount + 1;
                end
            end
        end
    end

    integer lane_index, global_channel, expected_act, expected_wt, element, live_lanes;
    reg [31:0] expected_address;
    reg [15:0] expected_element;
    always @(posedge clk) begin
        wall_cycle = wall_cycle + 1;
        if (!rst_n) previous_stall = 0;
        else if (checking) begin
            if (previous_stall &&
                (!mem_valid || mem_write !== stalled_write || mem_addr !== stalled_addr ||
                 (stalled_write && mem_data !== stalled_data)))
                $fatal(1, "DDR request changed under backpressure");
            previous_stall = mem_valid && !mem_ready;
            if (previous_stall) begin
                stalled_addr = mem_addr; stalled_data = mem_data; stalled_write = mem_write;
                stalls = stalls + 1;
            end
            if (dut.mac_enable && !$test$plusargs("SKIP_MAC_ORDER")) begin
                if (pooling || expected_group * 24 >= output_channels)
                    $fatal(1, "Unexpected/repeated MAC");
                expected_act = expected_activation(expected_pos, expected_term);
                if ($signed(dut.activation) !== expected_act || dut.pipe_first !== (expected_term == 0)) begin
                    $display("FRUIT_CORE_MAC_ORDER_FAIL case=%0d observed=%0d group=%0d pos=%0d term=%0d act=%0d expected=%0d first=%b",
                             pattern_id, observed_macs, expected_group, expected_pos,
                             expected_term, $signed(dut.activation), expected_act, dut.pipe_first);
                    $fatal(1, "Missing, repeated, or reordered MAC term");
                end
                for (lane_index = 0; lane_index < 24; lane_index = lane_index + 1) begin
                    expected_wt = weight_value(expected_group * 24 + lane_index, expected_term);
                    if ($signed(dut.weight_q[lane_index*8 +: 8]) !== expected_wt)
                        $fatal(1, "Weight mismatch group=%0d pos=%0d term=%0d lane=%0d got=%0d expected=%0d",
                               expected_group, expected_pos, expected_term, lane_index,
                               $signed(dut.weight_q[lane_index*8 +: 8]), expected_wt);
                end
                observed_macs = observed_macs + 1;
                if (expected_term == terms - 1) begin
                    expected_term = 0;
                    if (expected_pos == area - 1) begin expected_pos = 0; expected_group = expected_group + 1; end
                    else expected_pos = expected_pos + 1;
                end else expected_term = expected_term + 1;
            end
            if (mem_valid && mem_ready && mem_write) begin
                if (pooling) begin
                    expected_address = DST_BASE + writes * 16;
                    if (mem_addr !== expected_address || mem_data[127:16] !== 112'd0 ||
                        mem_data[15:0] !== expected_output(writes, 0))
                        $fatal(1, "Pooling numeric mismatch channel=%0d addr=%h got=%h expected=%h",
                               writes, mem_addr, mem_data, expected_output(writes, 0));
                end else begin
                    global_channel = write_group * 24 + write_lane;
                    expected_address = DST_BASE + global_channel * destination_plane * 2 + write_tile * 16;
                    if (mem_addr !== expected_address) $fatal(1, "Output address/order mismatch got=%h expected=%h", mem_addr, expected_address);
                    for (element = 0; element < 8; element = element + 1) begin
                        expected_element = write_tile * 8 + element < area ?
                            expected_output(global_channel, write_tile * 8 + element) : 16'd0;
                        if (mem_data[element*16 +: 16] !== expected_element) begin
                            $display("FRUIT_CORE_NUMERIC_FAIL case=%0d channel=%0d pos=%0d got=%0d expected=%0d",
                                     pattern_id, global_channel, write_tile*8+element,
                                     $signed(mem_data[element*16 +: 16]), $signed(expected_element));
                            $fatal(1, "Convolution output mismatch");
                        end
                    end
                    live_lanes = output_channels - write_group * 24;
                    if (live_lanes > 24) live_lanes = 24;
                    if (write_lane == live_lanes - 1) begin
                        write_lane = 0;
                        if (write_tile == (area + 7) / 8 - 1) begin write_tile = 0; write_group = write_group + 1; end
                        else write_tile = write_tile + 1;
                    end else write_lane = write_lane + 1;
                end
                writes = writes + 1;
            end
        end
    end

    task reset_core;
        begin
            @(negedge clk); #1; checking = 0; start = 0; rst_n = 0;
            repeat (3) @(negedge clk);
            #1; rst_n = 1;
            @(negedge clk); #1;
        end
    endtask

    task configure;
        input integer id, w, h, k, s, p, ci, co, pool, rectified, response, stalled;
        begin
            pattern_id = id; width = w; height = h; kernel = k;
            stride = s; padding = p; input_channels = ci; output_channels = co;
            pooling = pool; relu = rectified; response_mode = response; stall_mode = stalled;
            output_width = pool ? 1 : (w + 2*p - k) / s + 1;
            output_height = pool ? 1 : (h + 2*p - k) / s + 1;
            area = output_width * output_height;
            source_plane = ((w*h + 7) / 8) * 8;
            destination_plane = ((area + 7) / 8) * 8;
            terms = k*k*ci;
        end
    endtask

    task begin_operation;
        begin
            reads = 0; activation_reads = 0; writes = 0; stalls = 0;
            observed_macs = 0; expected_term = 0; expected_pos = 0; expected_group = 0;
            write_group = 0; write_tile = 0; write_lane = 0; previous_stall = 0;
            operation_cycle_base = cycles;
            operation_mac_base = mac_cycles;
            checking = 1;
            @(negedge clk); #1; start = 1;
            @(negedge clk); #1; start = 0;
        end
    endtask

    task finish_operation;
        integer timeout_cycles, expected_mac_count, expected_write_count;
        begin
            timeout_cycles = 0;
            while (!done && timeout_cycles < 1000000) begin
                @(negedge clk); #1; timeout_cycles = timeout_cycles + 1;
            end
            if (!done || fault) $fatal(1, "Core failed to complete case=%0d fault=%b", pattern_id, fault);
            expected_mac_count = pooling ? 0 : ((output_channels + 23) / 24) * area * terms;
            expected_write_count = pooling ? output_channels : output_channels * ((area + 7) / 8);
            if (observed_macs != expected_mac_count || writes != expected_write_count ||
                mac_cycles - operation_mac_base != expected_mac_count || qcount != 0 || group_id != 0)
                $fatal(1, "Completion accounting mismatch case=%0d macs=%0d/%0d writes=%0d/%0d counter=%0d queued=%0d group=%0d",
                       pattern_id, observed_macs, expected_mac_count, writes, expected_write_count,
                       mac_cycles - operation_mac_base, qcount, group_id);
            last_cycles = cycles - operation_cycle_base;
            cases_passed = cases_passed + 1;
            $display("FRUIT_CORE_CASE_PASS id=%0d pool=%0d k=%0d stride=%0d pad=%0d in=%0dx%0dx%0d out=%0dx%0dx%0d response=%0d stalls=%0d cycles=%0d macs=%0d reads=%0d activation_reads=%0d writes=%0d",
                     pattern_id, pooling, kernel, stride, padding, width, height, input_channels,
                     output_width, output_height, output_channels, response_mode, stalls,
                     last_cycles, observed_macs, reads, activation_reads, writes);
            checking = 0;
            repeat (3) @(negedge clk);
        end
    endtask

    integer mode;
    initial begin
        // Three memory schedules cover same-edge, one-cycle, and variable
        // responses; the latter two also throttle requests and writes.
        for (mode = 0; mode < 3; mode = mode + 1) begin
            configure(100+mode, 8, 2, 1, 1, 0, 2, 5, 0, 0, mode, mode != 0);
            reset_core(); begin_operation(); finish_operation();
            configure(200+mode, 6, 6, 3, 1, 1, 2, 3, 0, 1, mode, mode != 0);
            reset_core(); begin_operation(); finish_operation();
            configure(300+mode, 8, 8, 3, 2, 1, 3, 25, 0, 0, mode, mode != 0);
            reset_core(); begin_operation(); finish_operation();
            // 576 terms exercise both the 512-entry RAM and its 64-entry tail.
            configure(400+mode, 1, 1, 3, 1, 1, 64, 1, 0, 0, mode, mode != 0);
            reset_core(); begin_operation(); finish_operation();
            // Single-term products keep the DSP's first-term output mux
            // selected; 49 channels also exercise the third group and tail.
            configure(450+mode, 2, 2, 1, 1, 0, 1, 49, 0, 0, mode, mode != 0);
            reset_core(); begin_operation(); finish_operation();
            configure(500+mode, 8, 8, 4, 4, 0, 2, 8, 1, 0, mode, mode != 0);
            reset_core(); begin_operation(); finish_operation();
        end
        // Restart after cancelling a pending activation response.
        configure(600, 8, 2, 1, 1, 0, 2, 5, 0, 0, 2, 1);
        reset_core(); begin_operation();
        wait (dut.state == 5'd23);
        reset_core();
        if (busy || done || mem_valid || dut.pipe_valid) $fatal(1, "Reset did not cancel pending operation");
        begin_operation(); finish_operation();
        // A real classifier starts several different operations without a
        // core reset. Check that each accepted start replaces prior geometry,
        // including convolution -> pooling -> convolution transitions.
        configure(700, 6, 6, 3, 1, 1, 2, 3, 0, 1, 2, 1);
        begin_operation(); finish_operation();
        configure(701, 8, 8, 3, 2, 1, 3, 25, 0, 0, 2, 1);
        begin_operation(); finish_operation();
        configure(702, 8, 8, 4, 4, 0, 2, 8, 1, 0, 2, 1);
        begin_operation(); finish_operation();
        configure(703, 4, 2, 1, 1, 0, 2, 5, 0, 0, 2, 1);
        begin_operation(); finish_operation();
        // The 64-wide layer fills all 288 row-cache words. Exercise its last
        // channel/word/sample and the 128-wide input's 16 words per row.
        configure(800, 64, 3, 3, 1, 1, 12, 2, 0, 0, 2, 1);
        begin_operation(); finish_operation();
        configure(801, 128, 3, 3, 2, 1, 3, 2, 0, 1, 2, 1);
        begin_operation(); finish_operation();
        $display("FRUIT_CORE_NUMERIC_PASS cases=%0d reset_pending_response=1 signed_A12_W8 saturation_relu=1 weight_tail=1 multigroup=1 restart_geometry=6 full_row_cache=1 width128=1",
                 cases_passed);
`ifdef FRUIT_CORE_ROUTING_REFERENCE
        $display("FRUIT_CORE_ROUTING_EQUIVALENCE_PASS cycles=%0d lanes=24",equivalence_cycles);
`endif
        $finish;
    end
    initial begin
        #100000000;
        $fatal(1, "Fruit numerical regression timeout");
    end
endmodule
