`timescale 1ns/1ps

// Synthetic illumination verifies feedback wiring and sensor-table semantics.
// It is deliberately not a model of noise, optics, demosaicing or sensor QE.
module tb_ae_lighting_loop #(
    parameter integer TARGET_LOW = 96,
    parameter integer TARGET_HIGH = 128,
    parameter integer GAIN_MAX = 144,
    parameter integer POST_LSC_RGB = 0
);
    localparam integer WIDTH = 128, HEIGHT = 40, GROUPS = WIDTH/4;
    localparam integer TILE_COUNT = 40, METERED_PIXELS = 40;
    reg src_clk = 0, control_clk = 0;
    bit src_run = 1;
    always #5 if (src_run) src_clk = ~src_clk;
    initial begin
        #2.3;
        forever #21 control_clk = ~control_clk;
    end
    reg rst_n = 0, camera_done = 0;
    reg frame_start = 0, video_valid = 0, line_last = 0;
    reg [95:0] video_data = 0;
    wire stats_valid;
    wire [31:0] frame_sum;
    wire [15:0] frame_count, frame_bright;
    wire cdc_valid;
    wire [63:0] cdc_data;
    wire ae_request;
    wire [15:0] exposure, gain;
    reg ae_done = 0;

    ae_frame_stats_96 #(.IMG_WIDTH(WIDTH), .IMG_HEIGHT(HEIGHT),
        .BRIGHT_RGB_ENABLE(POST_LSC_RGB),.BRIGHT_G(141),.BRIGHT_B(223)) stats (
        .I_clk(src_clk), .I_rst_n(rst_n), .I_tuser(frame_start),
        .I_tlast(line_last), .I_tvalid(video_valid), .I_tdata(video_data),
        .O_stats_valid(stats_valid), .O_sum_y(frame_sum),
        .O_sample_count(frame_count), .O_bright_count(frame_bright)
    );
    ae_stats_cdc cdc (
        .I_src_clk(src_clk), .I_dst_clk(control_clk), .I_rst_n(rst_n),
        .I_src_valid(stats_valid),
        .I_src_data({frame_sum, frame_count, frame_bright}),
        .O_dst_valid(cdc_valid), .O_dst_data(cdc_data)
    );
    auto_exposure_control #(
        .TARGET_LOW(TARGET_LOW), .TARGET_HIGH(TARGET_HIGH), .GAIN_MAX(GAIN_MAX)
    ) control (
        .I_clk(control_clk), .I_rst(!rst_n), .I_cam_cfg_done(camera_done),
        .I_ae_cfg_done(ae_done), .I_stats_valid(cdc_valid),
        .I_sum_y(cdc_data[63:32]), .I_sample_count(cdc_data[31:16]),
        .I_bright_count(cdc_data[15:0]), .O_ae_req(ae_request),
        .O_ae(exposure), .O_ag(gain)
    );
    wire [23:0] gain_registers;
    reg [8:0] table_index = 0;
    wire [23:0] table_data;
    wire [8:0] table_size;
    SC520GainTbl gain_table(.I_AG(gain), .O(gain_registers));
    uics520regAE register_table(
        .REG_INDEX(table_index), .REG_DATA(table_data), .REG_SIZE(table_size),
        .I_AE(exposure), .I_AG(gain_registers)
    );

    // Model an eight-register I2C transaction, with the group released only
    // at the final 0x3812 write. Requests/parameters must not change mid-write.
    reg model_busy = 0;
    reg [2:0] byte_wait = 0;
    reg [15:0] held_exposure = 0, held_gain = 0;
    reg [3:0] staged_exposure_high = 0;
    reg [7:0] staged_exposure_mid = 0;
    reg [3:0] staged_exposure_low = 0;
    reg [7:0] staged_coarse = 0, staged_digital = 0, staged_fine = 128;
    reg [15:0] active_exposure = 1991;
    reg [7:0] active_coarse = 0, active_fine = 128;
    integer requests = 0, commits = 0, stability_checks = 0;
    integer increases = 0, decreases = 0, direction_changes = 0;
    integer last_direction = 0, transaction_direction;
    always @(posedge control_clk or negedge rst_n) begin
        if (!rst_n) begin
            ae_done <= 0;
            model_busy <= 0;
            byte_wait <= 0;
            table_index <= 0;
            held_exposure <= 0;
            held_gain <= 16;
            staged_exposure_high <= 0;
            staged_exposure_mid <= 0;
            staged_exposure_low <= 0;
            staged_coarse <= 0;
            staged_digital <= 0;
            staged_fine <= 128;
            active_exposure <= 1991;
            active_coarse <= 0;
            active_fine <= 128;
        end else if (!camera_done) begin
            ae_done <= 0;
            model_busy <= 0;
        end else if (!model_busy) begin
            ae_done <= 1;
            if (ae_request) begin
                requests = requests + 1;
                if (exposure<4 || exposure>1991 || gain<16 || gain>GAIN_MAX)
                    $fatal(1,"Sensor request exceeds configured exposure/gain limits");
                // Track actual requested sensor settings, independent of
                // controller thresholds and internal state.
                transaction_direction =
                    exposure > active_exposure || gain > held_gain ? 1 :
                    exposure < active_exposure || gain < held_gain ? -1 : 0;
                if (transaction_direction > 0) increases = increases+1;
                if (transaction_direction < 0) decreases = decreases+1;
                if (transaction_direction != 0) begin
                    if (last_direction != 0 && transaction_direction != last_direction)
                        direction_changes = direction_changes+1;
                    last_direction = transaction_direction;
                end
                ae_done <= 0;
                model_busy <= 1;
                byte_wait <= 0;
                table_index <= 0;
                held_exposure <= exposure;
                held_gain <= gain;
            end
        end else begin
            stability_checks = stability_checks + 1;
            if (ae_request || exposure !== held_exposure || gain !== held_gain)
                $fatal(1, "AE overwrote an active sensor-register transaction");
            if (table_size != 8)
                $fatal(1, "Unexpected AE register table size");
            byte_wait <= byte_wait + 1'b1;
            if (byte_wait == 3) begin
                byte_wait <= 0;
                case (table_index)
                    0: if (table_data !== 24'h381200)
                        $fatal(1, "Exposure group must first be held");
                    1: begin
                        if (table_data[23:8] !== 16'h3e00)
                            $fatal(1, "Wrong high-exposure register");
                        staged_exposure_high <= table_data[3:0];
                    end
                    2: begin
                        if (table_data[23:8] !== 16'h3e01)
                            $fatal(1, "Wrong middle-exposure register");
                        staged_exposure_mid <= table_data[7:0];
                    end
                    3: begin
                        if (table_data[23:8] !== 16'h3e02)
                            $fatal(1, "Wrong low-exposure register");
                        staged_exposure_low <= table_data[7:4];
                    end
                    4: staged_coarse <= table_data[7:0];
                    5: staged_digital <= table_data[7:0];
                    6: staged_fine <= table_data[7:0];
                    7: begin
                        if (table_data !== 24'h381230 || staged_digital != 0 ||
                            {staged_exposure_high, staged_exposure_mid,
                             staged_exposure_low} !== held_exposure)
                            $fatal(1, "Group release or decoded sensor parameters wrong");
                        active_exposure <= {
                            staged_exposure_high, staged_exposure_mid, staged_exposure_low};
                        active_coarse <= staged_coarse;
                        active_fine <= staged_fine;
                        model_busy <= 0;
                        ae_done <= 1;
                        commits = commits + 1;
                    end
                endcase
                table_index <= table_index + 1'b1;
            end
        end
    end

    function integer modeled_luma(input integer illumination);
        integer analog_multiplier;
        reg [63:0] numerator;
        begin
            case (active_coarse)
                8'h00: analog_multiplier = 1;
                8'h08: analog_multiplier = 2;
                8'h09: analog_multiplier = 4;
                8'h0b: analog_multiplier = 8;
                8'h0f: analog_multiplier = 16;
                8'h1f: analog_multiplier = 32;
                default: $fatal(1, "Illegal coarse gain code %h", active_coarse);
            endcase
            // Mixed scenes use illumination=1000. Retain 64 bits throughout
            // to avoid wrapping at high analog gain and long exposure.
            numerator = illumination;
            numerator = numerator * active_exposure * analog_multiplier * active_fine;
            modeled_luma = numerator / 128000;
            if (modeled_luma > 255) modeled_luma = 255;
        end
    endfunction

    // Separate illumination response from post-LSC metering. The actual
    // 720p interpolator/demosaic is exercised in tb_lsc_white_field.
    function automatic [23:0] post_lsc_colour(input integer raw_luma);
        integer green,blue;
        begin
            green=POST_LSC_RGB ? raw_luma*156/256 : raw_luma;
            blue=POST_LSC_RGB ? raw_luma*247/256 : raw_luma;
            post_lsc_colour={raw_luma[7:0],green[7:0],blue[7:0]};
        end
    endfunction
    function automatic integer metered_luma(input integer illumination);
        reg [23:0] colour;
        begin
            colour=post_lsc_colour(modeled_luma(illumination));
            metered_luma=(int'(colour[23:16])+2*int'(colour[15:8])+int'(colour[7:0]))/4;
        end
    endfunction

    reg [63:0] expected_payload [0:8191];
    integer stats_written = 0, stats_read = 0;
    integer total_frames = 0, convergence_checks = 0;
    integer generated_gray = 0;
    reg [23:0] frozen_image [0:WIDTH*HEIGHT-1];
    integer expected_frame_sum = 0, expected_frame_bright = 0;
    integer mixed_checks = 0, boundary_checks = 0, color_checks = 0;
    always @(posedge src_clk) begin
        #1;
        if (rst_n && stats_valid) begin
            if (frame_count != METERED_PIXELS ||
                frame_sum != expected_frame_sum ||
                frame_bright != expected_frame_bright)
                $fatal(1, "Frame metering does not match frozen camera frame");
            if (stats_written >= 8192) $fatal(1, "Stats reference queue overflow");
            expected_payload[stats_written] = {frame_sum, frame_count, frame_bright};
            stats_written = stats_written + 1;
        end
    end
    always @(posedge control_clk) begin
        #1;
        if (rst_n && cdc_valid) begin
            if (stats_read >= stats_written ||
                cdc_data !== expected_payload[stats_read])
                $fatal(1, "Stats CDC lost or corrupted a complete frame");
            stats_read = stats_read + 1;
        end
    end

    task automatic source_tick;
        begin
            @(posedge src_clk);
            #2;
        end
    endtask
    // Construct the full RGB source image, then independently meter the
    // actual RGB samples. The reference does not copy AE decision logic.
    // Each 32-pixel x four-row tile contains one metered sample. Permuting
    // tiles changes the source location while preserving exact area.
    task automatic camera_scene(
        input integer illumination, input integer light_tiles = 0,
        input integer offset = 0, input integer color_pattern = -1
    );
        integer row, group_index, x, tile, position, luma;
        integer red, green, blue, sampled_y;
        bit sampled_bright;
        reg [23:0] rgb;
        reg [95:0] group_rgb;
        begin
            generated_gray = modeled_luma(illumination);
            for (row=0; row<HEIGHT; row=row+1) begin
                for (x=0; x<WIDTH; x=x+1) begin
                    tile=(row/4)*4+x/32;
                    position=(13*tile+offset)%TILE_COUNT;
                    luma=modeled_luma(position<light_tiles ? 1000 : illumination);
                    rgb=post_lsc_colour(luma);
                    case (color_pattern)
                        0: rgb=24'hff0000;
                        1: rgb=24'h00ff00;
                        2: rgb=24'h0000ff;
                        3: rgb=24'hffaaBE;
                        default: begin end
                    endcase
                    frozen_image[row*WIDTH+x]=rgb;
                end
            end
            expected_frame_sum=0;
            expected_frame_bright=0;
            for (row=0; row<HEIGHT; row=row+4) begin
                for (x=0; x<WIDTH; x=x+32) begin
                    rgb=frozen_image[row*WIDTH+x];
                    red=rgb[23:16];green=rgb[15:8];blue=rgb[7:0];
                    sampled_y=(red+2*green+blue)/4;
`ifdef AE_LEGACY_POLICY_REPRO
                    sampled_bright=sampled_y>=232 || red>=250 ||
                                   green>=250 || blue>=250;
                    expected_frame_sum=expected_frame_sum+sampled_y;
`else
                    sampled_bright=sampled_y>=232 ||
                        (POST_LSC_RGB && red>=232 && green>=141 && blue>=223);
                    if (!sampled_bright)
                        expected_frame_sum=expected_frame_sum+sampled_y;
`endif
                    if (sampled_bright)
                        expected_frame_bright=expected_frame_bright+1;
                end
            end
            @(negedge src_clk);
            frame_start = 1;
            video_valid = 0;
            line_last = 0;
            source_tick();
            @(negedge src_clk);
            frame_start = 0;
            source_tick();
            for (row = 0; row < HEIGHT; row = row + 1) begin
                for (group_index = 0; group_index < GROUPS; group_index = group_index + 1) begin
                    @(negedge src_clk);
                    video_valid = 1;
                    line_last = group_index == GROUPS-1;
                    for (x=0; x<4; x=x+1)
                        group_rgb[95-x*24 -:24]=
                            frozen_image[row*WIDTH+group_index*4+x];
                    video_data = group_rgb;
                    source_tick();
                end
                @(negedge src_clk);
                video_valid = 0;
                line_last = 0;
                repeat (2) source_tick();
            end
            repeat (20) source_tick();
            total_frames = total_frames + 1;
        end
    endtask
    task automatic camera_frame(input integer illumination);
        camera_scene(illumination);
    endtask
    task automatic converge(input integer illumination, input string label_text);
        integer frame_index, consecutive, mean_luma;
        begin
            consecutive = 0;
            frame_index = 0;
            while (consecutive < 8 && frame_index < 200) begin
                camera_frame(illumination);
                mean_luma = metered_luma(illumination);
                if (mean_luma >= TARGET_LOW && mean_luma <= TARGET_HIGH && !model_busy)
                    consecutive = consecutive + 1;
                else
                    consecutive = 0;
                frame_index = frame_index + 1;
            end
            if (consecutive < 8)
                $fatal(1, "%s failed to converge: mean%0d exposure%0d gain%0d",
                       label_text, mean_luma, exposure, gain);
            convergence_checks = convergence_checks + 1;
            $display("AE_LOOP_CONVERGED %s frames=%0d mean=%0d exposure=%0d gain=%0d",
                     label_text, frame_index, mean_luma, exposure, gain);
        end
    endtask

    task automatic low_light_limit;
        integer frame_index,request_base,commit_base;
        reg [7:0] expected_coarse;
        begin
            // Use a scene too dark for either ceiling, then verify the
            // actual register group and that the loop stops at the bound.
            expected_coarse=GAIN_MAX==176 ? 8'h1f : 8'h0f;
            if (GAIN_MAX!=144 && GAIN_MAX!=176)
                $fatal(1,"Low-light register fixture supports limits 144 or 176");
            frame_index=0;
            while ((active_exposure!=1991 || active_coarse!=expected_coarse ||
                    active_fine!=128 || gain!=GAIN_MAX || model_busy) && frame_index<200) begin
                camera_frame(1);
                frame_index=frame_index+1;
            end
            if(frame_index==200 || exposure!=1991 || metered_luma(1)>=TARGET_LOW)
                $fatal(1,"Low-light scene failed to reach the applied register limit");
            request_base=requests;commit_base=commits;
            repeat(20) camera_frame(1);
            if(requests!=request_base || commits!=commit_base || gain!=GAIN_MAX)
                $fatal(1,"Low-light limit caused redundant writes or gain drift");
            $display("AE_LOW_LIGHT_LIMIT_PASS E=%0d G=%0d analog=%h digital=00 fine=%h mean=%0d stable_frames=20",
                active_exposure,gain,active_coarse,active_fine,metered_luma(1));
        end
    endtask

    task automatic mixed_converge(
        input integer light_tiles, input integer offset, input string label_text
    );
        integer frame_index, consecutive, background_y, request_base, commit_base;
        begin
            consecutive=0;frame_index=0;
            while(consecutive<8 && frame_index<200) begin
                camera_scene(16,light_tiles,offset);
                background_y=metered_luma(16);
                if(background_y>=TARGET_LOW && background_y<=TARGET_HIGH && !model_busy)
                    consecutive=consecutive+1;
                else consecutive=0;
                frame_index=frame_index+1;
            end
            if(consecutive<8)
                $fatal(1,"%s background failed to converge Y=%0d AE=%0d AG=%0d B=%0d",
                    label_text,background_y,exposure,gain,frame_bright);
            request_base=requests;commit_base=commits;
            repeat(20) begin
                camera_scene(16,light_tiles,offset);
                background_y=metered_luma(16);
                if(background_y<TARGET_LOW || background_y>TARGET_HIGH)
                    $fatal(1,"%s background left the target interval",label_text);
            end
            if(requests!=request_base || commits!=commit_base)
                $fatal(1,"%s kept requesting light changes after convergence",label_text);
            mixed_checks=mixed_checks+1;
            $display("AE_MIXED_CONVERGED %s fraction=%0d/40 location=%0d frames=%0d background=%0d source=%0d AE=%0d AG=%0d stable_frames=20",
                label_text,light_tiles,offset,frame_index,background_y,
                modeled_luma(1000),exposure,gain);
        end
    endtask

    task automatic boundary_scene(
        input integer light_tiles,input integer offset,input string label_text
    );
        integer frame_index, direction_base, late_request_base, background_y;
        begin
            if (modeled_luma(1000) != 255)
                $fatal(1,"%s did not begin with an actually clipped light source",label_text);
            direction_base=direction_changes;
            for(frame_index=0;frame_index<200;frame_index=frame_index+1) begin
                camera_scene(16,light_tiles,offset);
                if(frame_index==0 && frame_bright!=light_tiles)
                    $fatal(1,"%s missed the intended first-frame high-white fraction",label_text);
                if(frame_index==159) late_request_base=requests;
            end
            background_y=metered_luma(16);
            // One direction reversal can occur while recovering from a
            // previously bright full-frame scene. Repeated reversals or
            // continued requests at the boundary are not permitted.
            if(direction_changes-direction_base>1 || requests!=late_request_base)
                $fatal(1,"%s oscillated increases/decreases: reversals=%0d late_requests=%0d Y=%0d",
                    label_text,direction_changes-direction_base,
                    requests-late_request_base,background_y);
            boundary_checks=boundary_checks+1;
            $display("AE_BOUNDARY_HELD %s fraction=%0d/40 location=%0d background=%0d source=%0d AE=%0d AG=%0d reversals=%0d stable_frames=40",
                label_text,light_tiles,offset,background_y,modeled_luma(1000),
                exposure,gain,direction_changes-direction_base);
        end
    endtask

    task automatic saturated_color_scene(input integer color_pattern);
        integer repeat_index;
        begin
            for(repeat_index=0;repeat_index<8;repeat_index=repeat_index+1) begin
                camera_scene(16,0,0,color_pattern);
                if(frame_bright!=0)
                    $fatal(1,"Saturated RGB/pink was mistaken for a bright white field");
            end
            color_checks=color_checks+1;
        end
    endtask

    integer before_requests, before_commits, before_stats;
    integer old_background_min,old_background_max,old_y,old_old_requests;
    initial begin
        repeat (10) source_tick();
        @(negedge src_clk);
        rst_n = 1;
        repeat (6) @(posedge control_clk);
        @(negedge control_clk);
        camera_done = 1;
        repeat (80) @(posedge control_clk);
        if (commits != 1 || active_exposure != 1000 ||
            active_coarse != 0 || active_fine != 128)
            $fatal(1, "Safe default did not reach sensor register group");
`ifdef AE_LEGACY_POLICY_REPRO
        // Compile only against the frozen old statistics and controller.
        // This is an end-to-end reproduction, not a mathematical replica of
        // the old policy fed by new statistics.
        old_background_min=255;old_background_max=0;
        old_old_requests=requests;
        repeat(200) camera_scene(16,6,0);
        repeat(80) begin
            camera_scene(16,6,0);
            old_y=modeled_luma(16);
            if(old_y<old_background_min) old_background_min=old_y;
            if(old_y>old_background_max) old_background_max=old_y;
        end
        if(old_background_max>8 || requests-old_old_requests<5)
            $fatal(1,"Old policy did not reproduce lamp-dominated dark background");
        $display("AE_LEGACY_MIXED_REPRO_PASS fraction=6/40 source_illumination=1000 background_illumination=16 background_min=%0d background_max=%0d AE=%0d AG=%0d requests=%0d",
            old_background_min,old_background_max,exposure,gain,
            requests-old_old_requests);
        $finish;
`endif
        converge(220, "bright startup");
        converge(16, "dark transition");
        if (exposure != 1991 || gain <= 16)
            $fatal(1, "Dark transition did not prioritize exposure before gain");
        low_light_limit();
        converge(220, "bright recovery");
        if (gain != 16)
            $fatal(1, "Bright recovery did not remove unnecessary gain");

        // No source-clock activity means no new frames and no control drift.
        repeat (30) @(posedge control_clk);
        @(negedge src_clk);
        src_run = 0;
        before_requests = requests;
        before_commits = commits;
        before_stats = stats_read;
        repeat (500) @(posedge control_clk);
        if (before_requests != requests || before_commits != commits ||
            before_stats != stats_read)
            $fatal(1, "Stopped video source caused AE drift");
        src_run = 1;
        converge(16, "resumed source");

        // Global reset during a partial frame discards it and reinstalls
        // defaults before the next independent light adaptation sequence.
        @(negedge src_clk);
        frame_start = 1;
        video_valid = 0;
        source_tick();
        @(negedge src_clk);
        frame_start = 0;
        video_valid = 1;
        video_data = {12{8'd255}};
        repeat (5) source_tick();
        @(negedge src_clk);
        rst_n = 0;
        camera_done = 0;
        frame_start = 0;
        video_valid = 0;
        line_last = 0;
        repeat (10) source_tick();
        stats_written = 0;
        stats_read = 0;
        @(negedge src_clk);
        rst_n = 1;
        repeat (8) @(posedge control_clk);
        @(negedge control_clk);
        camera_done = 1;
        repeat (80) @(posedge control_clk);
        if (active_exposure != 1000 || active_coarse != 0 || active_fine != 128)
            $fatal(1, "Reset did not restore safe camera settings");
        converge(110, "reset recovery");

        // Mixed scenes use exact tile fractions and moved light-source
        // positions. Preserve the useful background even if the light
        // itself remains clipped; no request may follow stable convergence.
        mixed_converge(6,0,"15 percent screen");
        mixed_converge(6,11,"15 percent moved screen");
        mixed_converge(12,3,"30 percent screen");
        mixed_converge(12,17,"30 percent moved screen");
        mixed_converge(20,7,"50 percent screen");
        mixed_converge(20,23,"50 percent moved screen");
        mixed_converge(30,9,"75 percent screen");
        mixed_converge(30,31,"75 percent moved screen");

        // A near-full white field must recover rather than hold the
        // preceding high gain. This is an illumination-based sensor model.
        converge(1000,"full white recovery");
        before_requests=requests;before_commits=commits;
        repeat(20) camera_frame(1000);
        if(requests!=before_requests || commits!=before_commits)
            $fatal(1,"Full-white recovery did not stabilize");
        mixed_converge(6,5,"high-exposure boundary setup");
        boundary_scene(34,13,"85 percent near-white boundary");
        boundary_scene(36,29,"90 percent near-white boundary");
        mixed_converge(6,21,"high-exposure moved-boundary setup");
        boundary_scene(34,27,"85 percent moved boundary");
        boundary_scene(36,5,"90 percent moved boundary");

        // These RGB fields are direct sensor-byte fixtures, not sensor
        // exposure-response models; they test metering semantics only.
        // Pink Y=196 can correctly request less light, but is not all white.
        saturated_color_scene(0);
        saturated_color_scene(1);
        saturated_color_scene(2);
        saturated_color_scene(3);
        if(mixed_checks!=10 || boundary_checks!=4 || color_checks!=4)
            $fatal(1,"Mixed-scene coverage did not reach every requested case");
        repeat (30) @(posedge control_clk);
        if (stats_written != stats_read)
            $fatal(1, "Final complete frame was not delivered through CDC");
        $display("AE_LIGHTING_LOOP_PASS frames=%0d requests=%0d commits=%0d stable_checks=%0d convergences=%0d mixed=%0d boundaries=%0d color_fields=%0d target=%0d..%0d post_lsc=%0d gain_max=%0d",
                 total_frames, requests, commits, stability_checks, convergence_checks,
                 mixed_checks,boundary_checks,color_checks,TARGET_LOW,TARGET_HIGH,POST_LSC_RGB,GAIN_MAX);
        $finish;
    end
    initial begin
        #80000000;
        $fatal(1, "Lighting feedback integration test timed out");
    end
endmodule
