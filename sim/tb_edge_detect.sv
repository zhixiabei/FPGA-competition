`timescale 1ns/1ps

// Standalone behavioral test of the ORIGINAL edge_detect_96 module.
// No Anlogic primitives or simulation libraries are required by this module.
module tb_edge_detect;
    parameter integer WIDTH = 320;
    parameter integer HEIGHT = 180;
    localparam integer THRESHOLD = 80;
    localparam integer SAMPLE_WIDTH = WIDTH / 2;

    reg clk = 0;
    always #8 clk = ~clk; // 62.5 MHz test clock; not a timing signoff.
    reg rst_n = 0;
    reg in_valid = 0, in_user = 0, in_last = 0;
    reg [95:0] in_data = 0;
    wire out_valid, out_user, out_last, out_ready;
    wire [95:0] out_data;

    edge_detect_96 #(
        .IMG_WIDTH(WIDTH), .IMG_HEIGHT(HEIGHT), .EDGE_TH(THRESHOLD)
    ) dut (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_tlast(in_last), .I_tuser(in_user), .I_tdata(in_data),
        .I_tvalid(in_valid), .I_tready(1'b1),
        .O_tlast(out_last), .O_tuser(out_user), .O_tdata(out_data),
        .O_tvalid(out_valid), .O_tready(out_ready)
    );

    reg [23:0] input_image [0:WIDTH*HEIGHT-1];
    reg [23:0] expected_image [0:WIDTH*HEIGHT-1];
    reg [23:0] output_image [0:WIDTH*HEIGHT-1];
    integer gray_pairs [0:SAMPLE_WIDTH*HEIGHT-1];
    integer frame_id = 0;
    integer received = 0;
    integer total_pixels = 0;
    integer total_lines = 0;
    integer total_frames = 0;
    integer checked_cycles = 0;
    integer white_pixels = 0;
    integer status_file;

    function automatic integer gray(input reg [23:0] rgb);
        gray = (rgb[23:16] >> 2) + (rgb[15:8] >> 1) + (rgb[7:0] >> 2);
    endfunction

    function automatic integer absolute(input integer value);
        absolute = value < 0 ? -value : value;
    endfunction

    // Build an image-domain reference from a complete frame. This deliberately
    // does not reproduce the DUT's line-buffer/register implementation.
    task automatic prepare_frame(input integer kind);
        integer x, y, idx, s, gx, gy, magnitude;
        reg [23:0] color;
        reg [31:0] noise;
        begin
            noise = 32'hc001c0de;
            for (y = 0; y < HEIGHT; y = y + 1) begin
                for (x = 0; x < WIDTH; x = x + 1) begin
                    case (kind)
                        0: begin
                            color = 24'h101010;
                            if (x >= WIDTH/8 && x < WIDTH/2 &&
                                y >= HEIGHT/6 && y < HEIGHT*5/6)
                                color = 24'hffffff;
                            if (x >= WIDTH*5/8 && x < WIDTH*7/8 &&
                                y >= HEIGHT/4 && y < HEIGHT*3/4)
                                color = 24'hff3000;
                        end
                        1: color = 24'hffffff;
                        2: color = 24'h000000;
                        3: begin
                            noise = noise ^ (noise << 13);
                            noise = noise ^ (noise >> 17);
                            noise = noise ^ (noise << 5);
                            color = noise[23:0];
                        end
                        default: color = ((x*HEIGHT/WIDTH + y) % 32 < 16)
                                          ? 24'h00ff00 : 24'h0000ff;
                    endcase
                    idx = y*WIDTH+x;
                    input_image[idx] = color;
                    expected_image[idx] = 0;
                    output_image[idx] = 24'hxxxxxx;
                end
            end
            for (y = 0; y < HEIGHT; y = y + 1)
                for (s = 0; s < SAMPLE_WIDTH; s = s + 1)
                    gray_pairs[y*SAMPLE_WIDTH+s] =
                        (gray(input_image[y*WIDTH+2*s]) +
                         gray(input_image[y*WIDTH+2*s+1])) / 2;

            // DUT reports the window ending at (s,y), duplicates each sample,
            // and masks its first two rows / first four original pixels.
            for (y = 2; y < HEIGHT; y = y + 1) begin
                for (s = 2; s < SAMPLE_WIDTH; s = s + 1) begin
                    idx = y*SAMPLE_WIDTH+s;
                    gx = -gray_pairs[idx-2*SAMPLE_WIDTH-2]
                         +gray_pairs[idx-2*SAMPLE_WIDTH]
                         -2*gray_pairs[idx-SAMPLE_WIDTH-2]
                         +2*gray_pairs[idx-SAMPLE_WIDTH]
                         -gray_pairs[idx-2]+gray_pairs[idx];
                    gy = gray_pairs[idx-2*SAMPLE_WIDTH-2]
                         +2*gray_pairs[idx-2*SAMPLE_WIDTH-1]
                         +gray_pairs[idx-2*SAMPLE_WIDTH]
                         -gray_pairs[idx-2]-2*gray_pairs[idx-1]-gray_pairs[idx];
                    magnitude = absolute(gx) + absolute(gy);
                    color = magnitude >= THRESHOLD ? 24'hffffff : 24'h000000;
                    expected_image[y*WIDTH+2*s] = color;
                    expected_image[y*WIDTH+2*s+1] = color;
                end
            end
        end
    endtask

    task automatic send_cycle(input reg valid, input reg user,
                              input reg last, input reg [95:0] data);
        integer lane;
        reg [23:0] actual;
        begin
            @(negedge clk);
            in_valid = valid; in_user = user; in_last = last; in_data = data;
            @(posedge clk);
            #1; // Sample after the DUT's nonblocking register updates.
            checked_cycles = checked_cycles + 1;
            if (out_valid !== valid || out_user !== user || out_last !== last)
                $fatal(1, "Control/latency mismatch, frame=%0d pixel=%0d", frame_id, received);
            if (out_ready !== 1'b1)
                $fatal(1, "Unexpected ready level");
            if (valid) begin
                for (lane = 0; lane < 4; lane = lane + 1) begin
                    actual = out_data[95-lane*24 -: 24];
                    if (actual !== expected_image[received+lane])
                        $fatal(1, "Pixel mismatch frame=%0d x=%0d y=%0d expected=%h actual=%h",
                               frame_id, (received+lane)%WIDTH, (received+lane)/WIDTH,
                               expected_image[received+lane], actual);
                    output_image[received+lane] = actual;
                    if (actual == 24'hffffff) white_pixels = white_pixels + 1;
                end
                received = received + 4;
                total_pixels = total_pixels + 4;
                if (last) total_lines = total_lines + 1;
                if (user) total_frames = total_frames + 1;
            end else if (out_data !== 96'b0) begin
                $fatal(1, "Unexpected nonzero data during blanking");
            end
        end
    endtask

    task automatic apply_reset;
        begin
            @(negedge clk);
            rst_n = 0;
            in_valid = 0; in_user = 0; in_last = 0; in_data = 0;
            repeat (5) @(posedge clk);
            #1;
            if ({out_valid,out_user,out_last,out_data} !== 99'b0)
                $fatal(1, "Reset did not clear output registers");
            @(negedge clk);
            rst_n = 1;
        end
    endtask

    // Write uncompressed 24-bit BMPs, directly viewable in Windows Photos.
    task automatic byte_out(input integer fd, input integer value);
        $fwrite(fd, "%c", value[7:0]);
    endtask
    task automatic word_out(input integer fd, input integer value);
        begin byte_out(fd,value); byte_out(fd,value>>8); end
    endtask
    task automatic dword_out(input integer fd, input integer value);
        begin word_out(fd,value); word_out(fd,value>>16); end
    endtask
    task automatic write_bmp(input string filename, input integer image_kind);
        integer fd, x, y, pad, stride;
        reg [23:0] color;
        begin
            stride = ((WIDTH*3+3)/4)*4;
            fd = $fopen(filename,"wb");
            if (!fd) $fatal(1,"Cannot open output image %s", filename);
            byte_out(fd,66); byte_out(fd,77);
            dword_out(fd,54+stride*HEIGHT); dword_out(fd,0); dword_out(fd,54);
            dword_out(fd,40); dword_out(fd,WIDTH); dword_out(fd,HEIGHT);
            word_out(fd,1); word_out(fd,24);
            dword_out(fd,0); dword_out(fd,stride*HEIGHT);
            dword_out(fd,2835); dword_out(fd,2835); dword_out(fd,0); dword_out(fd,0);
            for (y = HEIGHT-1; y >= 0; y = y - 1) begin
                for (x = 0; x < WIDTH; x = x + 1) begin
                    case (image_kind)
                        0: color = input_image[y*WIDTH+x];
                        1: color = output_image[y*WIDTH+x];
                        default: color = expected_image[y*WIDTH+x];
                    endcase
                    byte_out(fd,color[7:0]);
                    byte_out(fd,color[15:8]);
                    byte_out(fd,color[23:16]);
                end
                for (pad = WIDTH*3; pad < stride; pad = pad + 1) byte_out(fd,0);
            end
            $fclose(fd);
        end
    endtask

    integer x, y, gap, idx;
    initial begin
        if (WIDTH < 8 || WIDTH % 4 != 0 || HEIGHT < 4)
            $fatal(1,"WIDTH must be a multiple of four and >=8; HEIGHT must be >=4");
        status_file = $fopen("result.txt","w");
        $fdisplay(status_file,"RUNNING");
        $fclose(status_file);
        apply_reset();
        for (frame_id = 0; frame_id < 5; frame_id = frame_id + 1) begin
            // Test recovery after reset with previously populated line RAMs.
            if (frame_id == 4) apply_reset();
            prepare_frame(frame_id);
            received = 0;
            white_pixels = 0;
            for (y = 0; y < HEIGHT; y = y + 1) begin
                for (x = 0; x < WIDTH; x = x + 4) begin
                    // Only this standalone edge block is tested with bubbles;
                    // the original downstream packer has a different contract.
                    if (frame_id == 3 && (x/4+y)%7 == 0)
                        send_cycle(0,0,0,0);
                    idx = y*WIDTH+x;
                    send_cycle(1, x == 0 && y == 0, x == WIDTH-4,
                        {input_image[idx],input_image[idx+1],
                         input_image[idx+2],input_image[idx+3]});
                end
                for (gap = 0; gap < 3+y%3; gap = gap + 1)
                    send_cycle(0,0,0,0);
            end
            if (received != WIDTH*HEIGHT) $fatal(1,"Wrong frame size");
            if ((frame_id == 1 || frame_id == 2) && white_pixels != 0)
                $fatal(1,"A uniform frame produced false edges");
            if ((frame_id == 0 || frame_id == 3 || frame_id == 4) && white_pixels == 0)
                $fatal(1,"Nonuniform frame produced no edges");
            if (frame_id == 0) begin
                write_bmp("input.bmp",0);
                write_bmp("edge_output.bmp",1);
                write_bmp("edge_expected.bmp",2);
            end
            $display("FRAME_PASS frame=%0d size=%0dx%0d pixels=%0d white=%0d",
                     frame_id,WIDTH,HEIGHT,received,white_pixels);
            repeat (12) send_cycle(0,0,0,0);
        end
        if (total_frames != 5 || total_lines != HEIGHT*5)
            $fatal(1,"Frame/line count mismatch");
        status_file = $fopen("result.txt","w");
        $fdisplay(status_file,"PASS");
        $fdisplay(status_file,"Frames: %0d; pixels: %0d; lines: %0d; checked cycles: %0d",
                  total_frames,total_pixels,total_lines,checked_cycles);
        $fdisplay(status_file,"Size: %0dx%0d; threshold: %0d",WIDTH,HEIGHT,THRESHOLD);
        $fdisplay(status_file,"Scope: standalone edge_detect_96, ready=1, SOF on first valid beat.");
        $fclose(status_file);
        $display("ALL_TESTS_PASS: %0d frames, %0d pixels checked",total_frames,total_pixels);
        $finish;
    end

    initial begin
        #500000000;
        $fatal(1,"Simulation timeout");
    end
endmodule
