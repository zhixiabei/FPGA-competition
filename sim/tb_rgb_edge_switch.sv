`timescale 1ns/1ps
// Historical 2026-10-02 grayscale Sobel / one-clock selector test.
// The current run_video_mode.cmd entry uses tb_color_edge_detect_96.sv,
// which verifies the color-vector pipeline and its ten-clock selector.
// Image-domain Sobel reference plus a byte scoreboard through the REAL packer.
// Bubbles occur at complete four-beat boundaries, as required by that packer.
module tb_rgb_edge_switch;
    parameter integer WIDTH = 64;
    parameter integer HEIGHT = 24;
    parameter integer DEFAULT_EDGE = 1;
    localparam integer PAIRS = WIDTH / 2;
    reg clk = 0;
    always #8 clk = ~clk;
    reg rst_n = 0;
    reg request_edge = DEFAULT_EDGE;
    reg in_valid = 0, in_user = 0, in_last = 0;
    reg [95:0] in_data = 0;
    wire out_valid, out_user, out_last, active_edge;
    wire [95:0] out_data;
    wire packed_valid, packed_user;
    wire [127:0] packed_data;
    rgb_edge_switch_96 #(
        .IMG_WIDTH(WIDTH), .IMG_HEIGHT(HEIGHT), .EDGE_TH(80),
        .DEFAULT_EDGE_MODE(DEFAULT_EDGE)
    ) dut (
        .I_clk(clk), .I_rst_n(rst_n), .I_edge_mode_async(request_edge),
        .I_tvalid(in_valid), .I_tuser(in_user), .I_tlast(in_last), .I_tdata(in_data),
        .O_tvalid(out_valid), .O_tuser(out_user), .O_tlast(out_last),
        .O_tdata(out_data), .O_edge_mode(active_edge)
    );
    data_96bit_to_128bit u_pack (
        .I_clk(clk), .I_rst_n(rst_n), .I_96b_frame_start(out_user),
        .I_96b_valid(out_valid), .I_96b_data(out_data),
        .O_128b_frame_start(packed_user), .O_128b_valid(packed_valid),
        .O_128b_data(packed_data)
    );
    reg [23:0] source_image [0:WIDTH*HEIGHT-1];
    reg [23:0] edge_image [0:WIDTH*HEIGHT-1];
    integer pairs [0:PAIRS*HEIGHT-1];
    reg [7:0] byte_queue [0:127];
    integer byte_wr = 0, byte_rd = 0, received = 0, total_pixels = 0;
    integer frame_id = 0, frames = 0, white_pixels = 0;
    reg expected_mode = DEFAULT_EDGE;
    reg previous_mode = DEFAULT_EDGE;
    reg previous_user = 0;
    reg checking = 0;
    function automatic integer gray(input reg [23:0] rgb);
        gray = (rgb[23:16] >> 2) + (rgb[15:8] >> 1) + (rgb[7:0] >> 2);
    endfunction
    function automatic integer abs_int(input integer n);
        abs_int = n < 0 ? -n : n;
    endfunction
    task automatic prepare_image;
        integer x, y, k, s, gx, gy;
        reg [31:0] noise;
        begin
            noise = 32'h51ce0001 + frame_id;
            for (k = 0; k < WIDTH*HEIGHT; k = k + 1) begin
                noise = noise ^ (noise << 13);
                noise = noise ^ (noise >> 17);
                noise = noise ^ (noise << 5);
                source_image[k] = noise[23:0];
                edge_image[k] = 0;
            end
            for (y = 0; y < HEIGHT; y = y + 1)
                for (s = 0; s < PAIRS; s = s + 1)
                    pairs[y*PAIRS+s] = (gray(source_image[y*WIDTH+2*s]) +
                                              gray(source_image[y*WIDTH+2*s+1])) / 2;
            for (y = 2; y < HEIGHT; y = y + 1)
                for (s = 2; s < PAIRS; s = s + 1) begin
                    k = y*PAIRS+s;
                    gx = -pairs[k-2*PAIRS-2] + pairs[k-2*PAIRS]
                         -2*pairs[k-PAIRS-2] + 2*pairs[k-PAIRS]
                         -pairs[k-2] + pairs[k];
                    gy = pairs[k-2*PAIRS-2] + 2*pairs[k-2*PAIRS-1] + pairs[k-2*PAIRS]
                         -pairs[k-2] - 2*pairs[k-1] - pairs[k];
                    edge_image[y*WIDTH+2*s] = (abs_int(gx)+abs_int(gy) >= 80)
                                               ? 24'hffffff : 24'h000000;
                    edge_image[y*WIDTH+2*s+1] = edge_image[y*WIDTH+2*s];
                end
        end
    endtask
    task automatic cycle(input bit valid, input bit user, input bit last,
                         input reg [95:0] data, input integer new_request);
        integer lane, b;
        reg [23:0] pixel;
        reg [95:0] expected_data;
        begin
            @(negedge clk);
            in_valid = valid; in_user = user; in_last = last; in_data = data;
            if (new_request >= 0) request_edge = new_request != 0;
            @(posedge clk); #1;
            if (checking) begin
                if (out_valid !== valid || out_user !== user || out_last !== last)
                    $fatal(1, "Stream marker or latency mismatch frame=%0d", frame_id);
                if (active_edge !== expected_mode)
                    $fatal(1, "Frame mode mismatch frame=%0d pixel=%0d", frame_id, received);
                if (active_edge != previous_mode && !user)
                    $fatal(1, "Mode changed outside a frame boundary");
                if (packed_user !== previous_user)
                    $fatal(1, "Packed frame marker latency changed");
                expected_data = 0;
                if (valid) begin
                    for (lane = 0; lane < 4; lane = lane + 1) begin
                        pixel = expected_mode ? edge_image[received+lane] : source_image[received+lane];
                        expected_data[95-lane*24 -: 24] = pixel;
                        if (expected_mode && pixel == 24'hffffff) white_pixels = white_pixels + 1;
                    end
                    received = received + 4;
                    total_pixels = total_pixels + 4;
                    for (b = 0; b < 12; b = b + 1) begin
                        byte_queue[byte_wr % 128] = expected_data[95-b*8 -: 8];
                        byte_wr = byte_wr + 1;
                    end
                end
                if (out_data !== expected_data)
                    $fatal(1, "Pixel mismatch frame=%0d pixel=%0d expected=%h got=%h",
                           frame_id, received, expected_data, out_data);
                if (packed_valid === 1'b1) begin
                    if (byte_wr - byte_rd < 16) $fatal(1, "Extra packed data");
                    for (b = 0; b < 16; b = b + 1) begin
                        if (packed_data[127-b*8 -: 8] !== byte_queue[byte_rd % 128])
                            $fatal(1, "Packed pixel mismatch at byte %0d", byte_rd);
                        byte_rd = byte_rd + 1;
                    end
                end else if (packed_valid !== 1'b0) $fatal(1, "Unknown packer valid");
                if (byte_wr - byte_rd > 96) $fatal(1, "Packer dropped pixels");
            end
            previous_mode = active_edge;
            previous_user = out_user;
        end
    endtask
    task automatic idle(input integer count);
        repeat (count) cycle(0, 0, 0, 0, -1);
    endtask
    task automatic send_frame(input bit mode, input bit early_sof,
                              input integer middle_request, input integer sof_request,
                              input bit two_requests);
        integer x, y, k, change;
        reg [95:0] data;
        begin
            prepare_image();
            received = 0;
            expected_mode = mode;
            if (early_sof) begin
                cycle(0, 1, 0, 0, sof_request);
                idle(7);
            end
            for (y = 0; y < HEIGHT; y = y + 1) begin
                for (x = 0; x < WIDTH; x = x + 4) begin
                    k = y*WIDTH+x;
                    data = {source_image[k],source_image[k+1],source_image[k+2],source_image[k+3]};
                    change = -1;
                    if (y == HEIGHT/2 && x == 0) change = middle_request;
                    if (two_requests && y == HEIGHT/2+2 && x == 0) change = mode;
                    if (!early_sof && k == 0) change = sof_request;
                    cycle(1, !early_sof && k == 0, x == WIDTH-4, data, change);
                    if (x % 16 == 12 && x != WIDTH-4 && y % 3 == 1) idle(2);
                end
                idle(3 + y % 2);
            end
            idle(5);
            if (received != WIDTH*HEIGHT || byte_wr != byte_rd)
                $fatal(1, "Frame pixel/byte count mismatch");
            $display("FRAME_PASS id=%0d mode=%0d early_sof=%0d pixels=%0d", frame_id, mode, early_sof, received);
            frames = frames + 1;
            frame_id = frame_id + 1;
        end
    endtask
    initial begin
        idle(5);
        @(negedge clk); rst_n = 1;
        idle(5); checking = 1;
        send_frame(DEFAULT_EDGE, 0, !DEFAULT_EDGE, -1, 0);
        send_frame(!DEFAULT_EDGE, 1, DEFAULT_EDGE, -1, 0);
        send_frame(DEFAULT_EDGE, 0, -1, -1, 0);
        // A request arriving at SOF cannot bypass the clock-domain synchronizer.
        send_frame(DEFAULT_EDGE, 0, -1, !DEFAULT_EDGE, 0);
        send_frame(!DEFAULT_EDGE, 1, DEFAULT_EDGE, -1, 1);
        send_frame(!DEFAULT_EDGE, 0, -1, -1, 0);
        checking = 0;
        @(negedge clk); rst_n = 0; request_edge = DEFAULT_EDGE;
        idle(5);
        if (active_edge !== (DEFAULT_EDGE != 0)) $fatal(1, "Reset default failed");
        @(negedge clk); rst_n = 1;
        expected_mode = DEFAULT_EDGE;
        idle(5); checking = 1;
        send_frame(DEFAULT_EDGE, 1, -1, -1, 0);
        if (white_pixels == 0 || frames != 7) $fatal(1, "Insufficient image coverage");
        $display("RGB_EDGE_SWITCH_TEST_PASS: %0dx%0d default=%0d frames=%0d pixels=%0d packed_bytes=%0d",
                 WIDTH, HEIGHT, DEFAULT_EDGE, frames, total_pixels, byte_rd);
        $finish;
    end
    initial begin #1000000000; $fatal(1, "Video switch test timeout"); end
endmodule
