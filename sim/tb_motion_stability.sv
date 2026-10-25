`timescale 1ns/1ps

// Scene truth drives these measurements. No copy of the detector's block
// arithmetic or spatial filter decides whether an output is acceptable.
module tb_motion_stability #(
    parameter integer STABLE_PIPELINE = 1,
    parameter integer CHECK_BEHAVIOR = 0
);
    localparam integer W = 256;
    localparam integer H = 256;
    localparam integer QUIET = 0;
    localparam integer MOVING = 1;
    localparam integer STOPPED = 2;
    localparam integer WARMUP = 3;
    localparam integer VANISHED = 4;
    localparam integer MAX_SCENES = 24;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg tuser = 0, tlast = 0, tvalid = 0;
    reg [95:0] tdata = 0;
    wire ready, found, frame_toggle;
    wire [11:0] xmin, xmax, ymin, ymax, center_x, center_y;
    wire [23:0] pixels;
    wire diagnostic_found, diagnostic_scene_change;
    wire [23:0] diagnostic_support, diagnostic_pixels;
    wire [11:0] diagnostic_x0, diagnostic_x1, diagnostic_y0, diagnostic_y1;
    generate
        if (STABLE_PIPELINE) begin : stable
            target_detect_switch_96 #(.IMG_WIDTH(W), .IMG_HEIGHT(H)) dut (
                .I_clk(clk), .I_rst_n(rst_n), .I_motion_mode_async(1'b1),
                .I_color_mode_async(2'd3),
                .I_tuser(tuser), .I_tlast(tlast), .I_tvalid(tvalid), .I_tdata(tdata),
                .O_result_ready(ready), .O_found(found),
                .O_xmin(xmin), .O_xmax(xmax), .O_ymin(ymin), .O_ymax(ymax),
                .O_center_x(center_x), .O_center_y(center_y),
                .O_pixels(pixels), .O_frame_toggle(frame_toggle),
                .O_target_motion_mode(), .O_motion_mode_active()
            );
            assign diagnostic_found = dut.raw_motion_found;
            assign diagnostic_scene_change = dut.motion_scene_change;
            assign diagnostic_support = dut.motion_supported_blocks;
            assign diagnostic_pixels = dut.raw_motion_pixels;
            assign diagnostic_x0 = dut.raw_motion_xmin;
            assign diagnostic_x1 = dut.raw_motion_xmax;
            assign diagnostic_y0 = dut.raw_motion_ymin;
            assign diagnostic_y1 = dut.raw_motion_ymax;
        end else begin : raw
            motion_target_detect_96 #(.IMG_WIDTH(W), .IMG_HEIGHT(H)) dut (
                .I_clk(clk), .I_rst_n(rst_n), .I_tuser(tuser),
                .I_tlast(tlast), .I_tvalid(tvalid), .I_tdata(tdata),
                .O_result_ready(ready), .O_found(found),
                .O_xmin(xmin), .O_xmax(xmax), .O_ymin(ymin), .O_ymax(ymax),
                .O_center_x(center_x), .O_center_y(center_y),
                .O_pixels(pixels), .O_frame_toggle(frame_toggle)
            );
            assign diagnostic_found = found;
            assign diagnostic_scene_change = 1'b0;
            assign diagnostic_support = 24'd0;
            assign diagnostic_pixels = pixels;
            assign diagnostic_x0 = xmin; assign diagnostic_x1 = xmax;
            assign diagnostic_y0 = ymin; assign diagnostic_y1 = ymax;
        end
    endgenerate

    reg [7:0] image [0:H-1][0:W-1];
    integer received = 0, sent = 0, csv_file;
    reg previous_toggle = 0;
    reg sample_found;
    integer sample_x0, sample_x1, sample_y0, sample_y1, sample_cx, sample_cy;
    integer sample_pixels;
    integer scene = -1, scene_count = 0;
    string names [0:MAX_SCENES-1];
    bit require_motion [0:MAX_SCENES-1];
    integer frames [0:MAX_SCENES-1], quiet_frames [0:MAX_SCENES-1];
    integer false_found [0:MAX_SCENES-1], motion_frames [0:MAX_SCENES-1];
    integer motion_found [0:MAX_SCENES-1], steady_frames [0:MAX_SCENES-1];
    integer steady_found [0:MAX_SCENES-1], first_detection [0:MAX_SCENES-1];
    integer stop_frames [0:MAX_SCENES-1], stop_found [0:MAX_SCENES-1];
    integer first_clear [0:MAX_SCENES-1], visibility_changes [0:MAX_SCENES-1];
    integer max_center_jump [0:MAX_SCENES-1], center_jump_sum [0:MAX_SCENES-1];
    integer max_edge_jump [0:MAX_SCENES-1], edge_jump_sum [0:MAX_SCENES-1];
    integer max_center_error [0:MAX_SCENES-1], center_error_sum [0:MAX_SCENES-1];
    integer max_edge_error [0:MAX_SCENES-1], edge_error_sum [0:MAX_SCENES-1];
    integer max_edge_residual [0:MAX_SCENES-1], edge_residual_sum [0:MAX_SCENES-1];
    integer total_quiet = 0, total_false = 0, total_motion = 0, total_detected = 0;
    integer required_steady_frames = 0, required_steady_found = 0;
    bit previous_visible, have_visible, previous_moving_visible;
    integer last_x0, last_x1, last_y0, last_y1, last_cx, last_cy;
    integer last_motion_x0, last_motion_x1, last_motion_y0, last_motion_y1;
    integer last_truth_x0, last_truth_x1, last_truth_y0, last_truth_y1;

    function integer abs_value;
        input integer value;
        begin abs_value = value < 0 ? -value : value; end
    endfunction
    function integer maximum;
        input integer first_value, second_value;
        begin maximum = first_value > second_value ? first_value : second_value; end
    endfunction

    task automatic clear_image(input integer level);
        integer x, y;
        begin
            for (y = 0; y < H; y = y+1)
                for (x = 0; x < W; x = x+1)
                    image[y][x] = 8'(level);
        end
    endtask
    task automatic rectangle(input integer x0, input integer y0,
                             input integer width, input integer height,
                             input integer level);
        integer x, y;
        begin
            for (y = y0; y < y0+height; y = y+1)
                for (x = x0; x < x0+width; x = x+1)
                    if (x >= 0 && x < W && y >= 0 && y < H)
                        image[y][x] = 8'(level);
        end
    endtask
    task automatic block_patch(input integer delta);
        integer bx, by;
        begin
            for (by = 6; by < 16; by = by+1)
                for (bx = 9; bx < 19; bx = bx+1)
                    rectangle(bx*8, by*8, 8, 8, 64+delta+((bx+by)%2));
        end
    endtask
    task automatic jumping_clusters(input integer frame);
        integer cluster, bx, by;
        reg [31:0] state;
        begin
            state = 32'h738eadb1 ^ (32'(frame)*32'h1fb35721);
            for (cluster = 0; cluster < 3; cluster = cluster+1) begin
                state = state*32'd1664525+32'd1013904223;
                bx = 2+integer'((state >> 8)%26);
                state = state*32'd1664525+32'd1013904223;
                by = 2+integer'((state >> 8)%26);
                rectangle(bx*8, by*8, 16, 16, 128);
                if ((frame+cluster)%2)
                    rectangle((bx+1)*8, (by+1)*8, 8, 8, 64);
            end
        end
    endtask
    task automatic shifted_texture(input integer shift);
        integer x, y, sx, value;
        begin
            for (y = 0; y < H; y = y+1) begin
                for (x = 0; x < W; x = x+1) begin
                    sx = (x+shift+W)%W;
                    value = 64+((sx/24+y/32)%4 == 0 ? 48 : 0);
                    image[y][x] = 8'(value);
                end
            end
        end
    endtask

    task automatic begin_scene(input string name, input bit motion_required);
        begin
            scene = scene+1; scene_count = scene_count+1;
            names[scene] = name; require_motion[scene] = motion_required;
            previous_visible = 0; have_visible = 0; previous_moving_visible = 0;
            @(negedge clk); rst_n = 0; tvalid = 0; tuser = 0; tlast = 0;
            repeat (5) @(negedge clk);
            rst_n = 1;
            repeat (8) @(negedge clk);
        end
    endtask

    task automatic measure_sample(input integer kind, input integer tx0,
                                  input integer tx1, input integer ty0, input integer ty1);
        integer center_step, edge_step, center_error, edge_error, residual;
        begin
            frames[scene] = frames[scene]+1;
            if (kind == QUIET || kind == VANISHED) begin
                quiet_frames[scene] = quiet_frames[scene]+1;
                if (sample_found) false_found[scene] = false_found[scene]+1;
            end
            if (kind == MOVING) begin
                motion_frames[scene] = motion_frames[scene]+1;
                if (sample_found) begin
                    motion_found[scene] = motion_found[scene]+1;
                    if (first_detection[scene] == 0)
                        first_detection[scene] = motion_frames[scene];
                end
                // Three candidate frames are allowed before stable output.
                if (motion_frames[scene] >= 3) begin
                    steady_frames[scene] = steady_frames[scene]+1;
                    if (sample_found) steady_found[scene] = steady_found[scene]+1;
                end
            end
            if (kind == STOPPED) begin
                stop_frames[scene] = stop_frames[scene]+1;
                if (sample_found) stop_found[scene] = stop_found[scene]+1;
                else if (first_clear[scene] == 0) first_clear[scene] = stop_frames[scene];
            end
            if (sample_found != previous_visible)
                visibility_changes[scene] = visibility_changes[scene]+1;
            previous_visible = sample_found;
            if (sample_found) begin
                if (have_visible) begin
                    center_step = maximum(abs_value(sample_cx-last_cx), abs_value(sample_cy-last_cy));
                    edge_step = maximum(maximum(abs_value(sample_x0-last_x0), abs_value(sample_x1-last_x1)),
                                        maximum(abs_value(sample_y0-last_y0), abs_value(sample_y1-last_y1)));
                    max_center_jump[scene] = maximum(max_center_jump[scene], center_step);
                    max_edge_jump[scene] = maximum(max_edge_jump[scene], edge_step);
                    center_jump_sum[scene] = center_jump_sum[scene]+center_step;
                    edge_jump_sum[scene] = edge_jump_sum[scene]+edge_step;
                end
                have_visible = 1;
                last_x0 = sample_x0; last_x1 = sample_x1;
                last_y0 = sample_y0; last_y1 = sample_y1;
                last_cx = sample_cx; last_cy = sample_cy;
                if (kind == MOVING) begin
                    center_error = maximum(abs_value(sample_cx-(tx0+tx1)/2),
                                           abs_value(sample_cy-(ty0+ty1)/2));
                    edge_error = maximum(maximum(abs_value(sample_x0-tx0), abs_value(sample_x1-tx1)),
                                         maximum(abs_value(sample_y0-ty0), abs_value(sample_y1-ty1)));
                    max_center_error[scene] = maximum(max_center_error[scene], center_error);
                    max_edge_error[scene] = maximum(max_edge_error[scene], edge_error);
                    center_error_sum[scene] = center_error_sum[scene]+center_error;
                    edge_error_sum[scene] = edge_error_sum[scene]+edge_error;
                    if (previous_moving_visible) begin
                        residual = maximum(
                            maximum(abs_value(sample_x0-last_motion_x0-(tx0-last_truth_x0)),
                                    abs_value(sample_x1-last_motion_x1-(tx1-last_truth_x1))),
                            maximum(abs_value(sample_y0-last_motion_y0-(ty0-last_truth_y0)),
                                    abs_value(sample_y1-last_motion_y1-(ty1-last_truth_y1))));
                        max_edge_residual[scene] = maximum(max_edge_residual[scene], residual);
                        edge_residual_sum[scene] = edge_residual_sum[scene]+residual;
                    end
                    last_motion_x0 = sample_x0; last_motion_x1 = sample_x1;
                    last_motion_y0 = sample_y0; last_motion_y1 = sample_y1;
                    last_truth_x0 = tx0; last_truth_x1 = tx1;
                    last_truth_y0 = ty0; last_truth_y1 = ty1;
                end
            end
            previous_moving_visible = kind == MOVING && sample_found;
        end
    endtask

    task automatic send_frame(input string name, input integer kind,
                              input integer tx0, input integer tx1,
                              input integer ty0, input integer ty1);
        integer y, group_index, lane, waited;
        begin
            sent = sent+1;
            @(negedge clk); tuser = 1; tvalid = 0; tlast = 0;
            repeat (2) @(negedge clk);
            tuser = 0;
            for (y = 0; y < H; y = y+1) begin
                for (group_index = 0; group_index < W/4; group_index = group_index+1) begin
                    if ((y*(W/4)+group_index)%251 == 13) begin
                        @(negedge clk); tvalid = 0; tlast = 0;
                    end
                    @(negedge clk); tvalid = 1; tlast = group_index == W/4-1;
                    for (lane = 0; lane < 4; lane = lane+1)
                        tdata[95-lane*24-:24] = {3{image[y][group_index*4+lane]}};
                end
            end
            @(negedge clk); tvalid = 0; tuser = 0; tlast = 0;
            waited = 0;
            while (received < sent && waited < 256) begin
                @(negedge clk); waited = waited+1;
            end
            if (received != sent) $fatal(1, "Missing stability result for %s", name);
            measure_sample(kind, tx0, tx1, ty0, ty1);
            $fdisplay(csv_file, "%0d,%s,%s,%0d,%b,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%b,%0d,%b,%0d,%0d,%0d,%0d,%0d",
                      sent, names[scene], name, kind, sample_found,
                      sample_x0, sample_x1, sample_y0, sample_y1,
                      sample_cx, sample_cy, sample_pixels, tx0, tx1, ty0, ty1,
                      diagnostic_found, diagnostic_support, diagnostic_scene_change,
                      diagnostic_x0, diagnostic_x1, diagnostic_y0, diagnostic_y1, diagnostic_pixels);
            repeat (5) @(negedge clk);
        end
    endtask

    task automatic motion_sequence(input integer speed, input integer contrast);
        integer frame, ox;
        begin
            begin_scene($sformatf("translate_dx%0d_contrast%0d", speed, contrast),
                        speed != 1 || contrast != 48);
            clear_image(64); rectangle(32, 64, 80, 96, 64+contrast);
            send_frame("reference", WARMUP, 0, 0, 0, 0);
            for (frame = 1; frame <= 16; frame = frame+1) begin
                ox = 32+frame*speed;
                clear_image(64); rectangle(ox, 64, 80, 96, 64+contrast);
                send_frame($sformatf("move_%0d", frame), MOVING,
                           ox-speed, ox+79, 64, 159);
            end
            for (frame = 1; frame <= 8; frame = frame+1)
                send_frame($sformatf("stop_%0d", frame), STOPPED, 0, 0, 0, 0);
            clear_image(64);
            send_frame("disappears_after_stop", VANISHED, 0, 0, 0, 0);
            for (frame = 1; frame <= 5; frame = frame+1)
                send_frame($sformatf("absent_%0d", frame), QUIET, 0, 0, 0, 0);
        end
    endtask

    always @(posedge clk) begin
        #1;
        if (!rst_n) previous_toggle = 0;
        else if (ready) begin
            if (received >= sent) $fatal(1, "Duplicate/unrequested stability result");
            if ((found !== 0 && found !== 1) || (^pixels === 1'bx))
                $fatal(1, "Unknown stability output");
            if (found && ((^({xmin,xmax,ymin,ymax,center_x,center_y}) === 1'bx) ||
                          xmin > xmax || ymin > ymax || xmax >= W || ymax >= H ||
                          center_x < xmin || center_x > xmax || center_y < ymin || center_y > ymax))
                $fatal(1, "Invalid stability box %0d,%0d..%0d,%0d", xmin, ymin, xmax, ymax);
            if (frame_toggle !== ~previous_toggle)
                $fatal(1, "Stability result toggle did not toggle once per frame");
            previous_toggle = frame_toggle;
            sample_found = found; sample_x0 = xmin; sample_x1 = xmax;
            sample_y0 = ymin; sample_y1 = ymax;
            sample_cx = center_x; sample_cy = center_y; sample_pixels = pixels;
            received = received+1;
        end
    end

    integer index, frame, event_index, speed, contrast, margin, phase;
    initial begin
        csv_file = $fopen("motion_stability_frames.csv", "w");
        if (csv_file == 0) $fatal(1, "Cannot open stability CSV");
        $fdisplay(csv_file, "frame,scene,stimulus,kind,found,xmin,xmax,ymin,ymax,center_x,center_y,pixels,truth_xmin,truth_xmax,truth_ymin,truth_ymax,raw_found,raw_supported_blocks,raw_scene_change,raw_xmin,raw_xmax,raw_ymin,raw_ymax,raw_pixels");
        for (index = 0; index < MAX_SCENES; index = index+1) begin
            frames[index] = 0; quiet_frames[index] = 0; false_found[index] = 0;
            motion_frames[index] = 0; motion_found[index] = 0;
            steady_frames[index] = 0; steady_found[index] = 0; first_detection[index] = 0;
            stop_frames[index] = 0; stop_found[index] = 0; first_clear[index] = 0;
            visibility_changes[index] = 0;
            max_center_jump[index] = 0; center_jump_sum[index] = 0;
            max_edge_jump[index] = 0; edge_jump_sum[index] = 0;
            max_center_error[index] = 0; center_error_sum[index] = 0;
            max_edge_error[index] = 0; edge_error_sum[index] = 0;
            max_edge_residual[index] = 0; edge_residual_sum[index] = 0;
        end

        begin_scene("block_mean_jitter_6_to_9", 0);
        clear_image(64); send_frame("reference", WARMUP, 0, 0, 0, 0);
        for (frame = 0; frame < 24; frame = frame+1) begin
            clear_image(64);
            if (frame%2 == 0) block_patch(6+(frame/2)%3);
            send_frame($sformatf("jitter_%0d", frame), QUIET, 0, 0, 0, 0);
        end
        for (frame = 0; frame < 6; frame = frame+1)
            send_frame($sformatf("quiet_%0d", frame), QUIET, 0, 0, 0, 0);

        begin_scene("random_three_to_four_block_clusters", 0);
        clear_image(64); send_frame("reference", WARMUP, 0, 0, 0, 0);
        for (frame = 0; frame < 24; frame = frame+1) begin
            clear_image(64); jumping_clusters(frame);
            send_frame($sformatf("clusters_%0d", frame), QUIET, 0, 0, 0, 0);
        end
        clear_image(64);
        for (frame = 0; frame < 6; frame = frame+1)
            send_frame($sformatf("quiet_%0d", frame), QUIET, 0, 0, 0, 0);

        begin_scene("same_position_single_frame_flash", 0);
        clear_image(64); send_frame("reference", WARMUP, 0, 0, 0, 0);
        for (event_index = 0; event_index < 4; event_index = event_index+1) begin
            rectangle(96, 72, 32, 32, 192);
            send_frame($sformatf("flash_%0d", event_index), QUIET, 0, 0, 0, 0);
            clear_image(64);
            for (frame = 0; frame < 5; frame = frame+1)
                send_frame($sformatf("flash_%0d_absent_%0d", event_index, frame), QUIET, 0, 0, 0, 0);
        end

        begin_scene("global_light_steps_8_and_12", 0);
        clear_image(64); send_frame("reference", WARMUP, 0, 0, 0, 0);
        for (frame = 0; frame < 8; frame = frame+1) begin
            case (frame/2)
                0: clear_image(72);
                1: clear_image(84);
                2: clear_image(72);
                3: clear_image(64);
            endcase
            send_frame($sformatf("light_%0d", frame), QUIET, 0, 0, 0, 0);
        end

        begin_scene("full_frame_texture_shift_one_pixel", 0);
        shifted_texture(0); send_frame("reference", WARMUP, 0, 0, 0, 0);
        for (frame = 0; frame < 16; frame = frame+1) begin
            case (frame%4)
                0: shifted_texture(1);
                1: shifted_texture(0);
                2: shifted_texture(-1);
                3: shifted_texture(0);
            endcase
            send_frame($sformatf("camera_jitter_%0d", frame), QUIET, 0, 0, 0, 0);
        end
        for (frame = 0; frame < 4; frame = frame+1)
            send_frame($sformatf("camera_stops_%0d", frame), QUIET, 0, 0, 0, 0);

        begin_scene("object_edge_variation_plus_minus_8", 1);
        clear_image(64); rectangle(48, 64, 80, 96, 192);
        send_frame("reference", WARMUP, 0, 0, 0, 0);
        for (frame = 1; frame <= 24; frame = frame+1) begin
            phase = ((frame-1)/3)%4;
            margin = phase == 0 ? -8 : phase == 2 ? 8 : 0;
            clear_image(64); rectangle(48+frame*2-margin, 64-margin, 80+margin*2, 96+margin*2, 192);
            send_frame($sformatf("edge_variation_%0d", frame), MOVING,
                       48+(frame-1)*2, 48+frame*2+79, 64, 159);
        end
        for (frame = 1; frame <= 8; frame = frame+1)
            send_frame($sformatf("stop_%0d", frame), STOPPED, 0, 0, 0, 0);
        clear_image(64); send_frame("object_vanishes", VANISHED, 0, 0, 0, 0);
        for (frame = 1; frame <= 7; frame = frame+1)
            send_frame($sformatf("absent_%0d", frame), QUIET, 0, 0, 0, 0);

        for (index = 0; index < 8; index = index+1) begin
            speed = 1 << (index%4);
            contrast = index < 4 ? 48 : 128;
            motion_sequence(speed, contrast);
        end
        for (index = 0; index < scene_count; index = index+1) begin
            total_quiet = total_quiet+quiet_frames[index];
            total_false = total_false+false_found[index];
            total_motion = total_motion+motion_frames[index];
            total_detected = total_detected+motion_found[index];
            if (require_motion[index]) begin
                required_steady_frames = required_steady_frames+steady_frames[index];
                required_steady_found = required_steady_found+steady_found[index];
            end
            $display("STABILITY_SCENE name=%s frames=%0d quiet=%0d false=%0d motion=%0d found=%0d steady=%0d steady_found=%0d first_detect=%0d stop_frames=%0d stop_found=%0d first_clear=%0d visible_changes=%0d center_jump_max=%0d center_jump_sum=%0d edge_jump_max=%0d edge_jump_sum=%0d center_error_max=%0d edge_error_max=%0d edge_residual_max=%0d edge_residual_sum=%0d",
                     names[index], frames[index], quiet_frames[index], false_found[index],
                     motion_frames[index], motion_found[index], steady_frames[index], steady_found[index],
                     first_detection[index], stop_frames[index], stop_found[index], first_clear[index],
                     visibility_changes[index], max_center_jump[index], center_jump_sum[index],
                     max_edge_jump[index], edge_jump_sum[index], max_center_error[index], max_edge_error[index],
                     max_edge_residual[index], edge_residual_sum[index]);
            if (CHECK_BEHAVIOR) begin
                if (false_found[index] != 0)
                    $fatal(1, "Nuisance false motion in %s: %0d/%0d",
                           names[index], false_found[index], quiet_frames[index]);
                if (require_motion[index] &&
                    (first_detection[index] == 0 || first_detection[index] > 3 ||
                     steady_found[index] != steady_frames[index]))
                    $fatal(1, "Sustained motion missing in %s", names[index]);
                if (stop_frames[index] != 0 &&
                    (first_clear[index] == 0 || first_clear[index] > 3))
                    $fatal(1, "Motion box was retained too long in %s", names[index]);
            end
        end
        if (sent != 406 || received != sent || scene_count != 14)
            $fatal(1, "Incomplete stability coverage sent=%0d received=%0d scenes=%0d",
                   sent, received, scene_count);
        $display("MOTION_STABILITY_PASS pipeline_stable=%0d check=%0d frames=%0d scenes=%0d quiet=%0d false=%0d moving=%0d detected=%0d required_steady=%0d required_steady_found=%0d",
                 STABLE_PIPELINE, CHECK_BEHAVIOR, sent, scene_count, total_quiet, total_false,
                 total_motion, total_detected, required_steady_frames, required_steady_found);
        $fclose(csv_file);
        $finish;
    end
    initial begin
        #100000000;
        $fatal(1, "Motion stability timeout");
    end
endmodule
