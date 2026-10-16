`timescale 1ns/1ps

// Metadata-only cases have explicit expected boxes. This reference does not
// copy the tracker's state machine or its coordinate smoothing function.
module tb_motion_result_stabilizer;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg input_ready = 0, input_found = 0, scene_change = 0;
    reg [23:0] supported = 0, input_pixels = 0;
    reg [47:0] input_box = 0;
    wire output_ready, output_found, output_toggle;
    wire [11:0] xmin, xmax, ymin, ymax, center_x, center_y;
    wire [23:0] output_pixels;
    motion_result_stabilizer dut (
        .I_clk(clk), .I_rst_n(rst_n), .I_result_ready(input_ready),
        .I_found(input_found), .I_scene_change(scene_change),
        .I_supported_blocks(supported), .I_pixels(input_pixels),
        .I_xmin(input_box[47:36]), .I_xmax(input_box[35:24]),
        .I_ymin(input_box[23:12]), .I_ymax(input_box[11:0]),
        .O_result_ready(output_ready), .O_found(output_found),
        .O_xmin(xmin), .O_xmax(xmax), .O_ymin(ymin), .O_ymax(ymax),
        .O_center_x(center_x), .O_center_y(center_y),
        .O_pixels(output_pixels), .O_frame_toggle(output_toggle)
    );

    string expected_name [0:255];
    bit expected_found [0:255];
    reg [47:0] expected_box [0:255];
    integer expected_pixels [0:255];
    integer queue_head = 0, queue_tail = 0;
    integer submitted = 0, received = 0, canceled = 0;
    integer confirmed = 0, suppressed = 0, idle_checks = 0, resets = 0;
    bit delayed_ready = 0, ready_expected = 0, previous_toggle = 0;
    reg [97:0] previous_payload = 0;
    wire [97:0] output_payload = {
        output_found, xmin, xmax, ymin, ymax,
        center_x, center_y, output_pixels, output_toggle
    };
    integer expected_cx, expected_cy;

    function automatic [47:0] box(
        input integer x0, x1, y0, y1
    );
        box = {x0[11:0], x1[11:0], y0[11:0], y1[11:0]};
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            delayed_ready = 0;
            ready_expected = 0;
            previous_toggle = 0;
            previous_payload = 0;
            #1;
            if (output_ready !== 0 || output_payload !== 98'd0)
                $fatal(1, "Stabilizer reset retained metadata");
        end else begin
            ready_expected = delayed_ready;
            delayed_ready = input_ready;
            #1;
            if (output_ready !== ready_expected)
                $fatal(1, "Stabilizer two-stage publication latency changed");
            if ((^output_payload) === 1'bx)
                $fatal(1, "Stabilizer published unknown metadata");
            if (output_ready) begin
                if (queue_head >= queue_tail)
                    $fatal(1, "Stabilizer duplicated a frame result");
                expected_cx =
                    (integer'(expected_box[queue_head][47:36]) +
                     integer'(expected_box[queue_head][35:24])) / 2;
                expected_cy =
                    (integer'(expected_box[queue_head][23:12]) +
                     integer'(expected_box[queue_head][11:0])) / 2;
                if (output_found !== expected_found[queue_head] ||
                    {xmin,xmax,ymin,ymax} !== expected_box[queue_head] ||
                    output_pixels !== expected_pixels[queue_head][23:0] ||
                    center_x !== expected_cx[11:0] ||
                    center_y !== expected_cy[11:0] ||
                    output_toggle !== !previous_toggle)
                    $fatal(1, "%s: found=%b box=%0d,%0d..%0d,%0d center=%0d,%0d pixels=%0d expected_found=%b expected_box=%h expected_pixels=%0d",
                        expected_name[queue_head], output_found,
                        xmin,ymin,xmax,ymax,center_x,center_y,output_pixels,
                        expected_found[queue_head],expected_box[queue_head],
                        expected_pixels[queue_head]);
                if (output_found &&
                    (xmin > xmax || ymin > ymax || xmax >= 1280 || ymax >= 720))
                    $fatal(1, "Stabilizer published an invalid box");
                previous_toggle = output_toggle;
                received = received + 1;
                if (output_found) confirmed = confirmed + 1;
                else suppressed = suppressed + 1;
                $display("MOTION_STABILIZER_CASE_PASS %0d %s found=%b box=%0d,%0d..%0d,%0d",
                    received,expected_name[queue_head],output_found,xmin,ymin,xmax,ymax);
                queue_head = queue_head + 1;
            end else begin
                if (output_payload !== previous_payload)
                    $fatal(1, "Stabilizer metadata advanced without a camera-frame token");
                idle_checks = idle_checks + 1;
            end
            previous_payload = output_payload;
        end
    end

    task automatic submit(
        input string name,
        input bit valid_candidate, hard_scene,
        input integer support_blocks, pixel_count,
        input [47:0] candidate_box,
        input bit should_find,
        input [47:0] should_box,
        input integer should_pixels
    );
        begin
            @(negedge clk);
            input_ready = 1;
            input_found = valid_candidate;
            scene_change = hard_scene;
            supported = support_blocks;
            input_pixels = pixel_count;
            input_box = candidate_box;
            expected_name[queue_tail] = name;
            expected_found[queue_tail] = should_find;
            expected_box[queue_tail] = should_box;
            expected_pixels[queue_tail] = should_pixels;
            queue_tail = queue_tail + 1;
            submitted = submitted + 1;
            @(posedge clk); #2;
        end
    endtask

    task automatic idle(input integer clocks);
        integer clock_index;
        begin
            for (clock_index=0; clock_index<clocks; clock_index=clock_index+1) begin
                @(negedge clk);
                input_ready = 0;
                // Invalid-cycle input values must not confirm or age a track.
                input_found = clock_index[0];
                scene_change = !clock_index[0];
                supported = 24'hffffff;
                input_pixels = 24'hffffff;
                input_box = 48'hffffffffffff;
                @(posedge clk); #2;
            end
        end
    endtask

    task automatic reset_dut;
        begin
            @(negedge clk);
            rst_n = 0;
            input_ready = 0;
            input_found = 0;
            scene_change = 0;
            canceled = canceled + queue_tail - queue_head;
            queue_tail = 0;
            queue_head = 0;
            repeat (3) @(negedge clk);
            rst_n = 1;
            resets = resets + 1;
        end
    endtask

    initial begin
        reset_dut();
        submit("empty warm-up",0,0,0,0,0,0,0,0);
        submit("reversed box is rejected",1,0,32,1536,box(100,99,160,279),0,0,0);
        submit("out-of-image box is rejected",1,0,32,1536,box(1120,1280,160,279),0,0,0);
        submit("insufficient supported blocks",1,0,7,1536,box(100,259,160,279),0,0,0);
        submit("sparse full-image union is rejected",1,0,8,1536,box(0,1279,0,719),0,0,0);
        // The 160x120 box has a 35-block span: 3*23 < 2*35,
        // whereas 24 supported blocks meet the density qualification.
        submit("density one block below threshold first",1,0,23,1536,box(100,259,160,279),0,0,0);
        submit("density one block below threshold second",1,0,23,1536,box(100,259,160,279),0,0,0);
        submit("density one block below threshold third",1,0,23,1536,box(100,259,160,279),0,0,0);
        submit("density threshold first confirmation",1,0,24,1536,box(100,259,160,279),0,0,0);
        submit("density threshold second confirmation",1,0,24,1536,box(100,259,160,279),0,0,0);
        submit("density threshold third confirms",1,0,24,1536,box(100,259,160,279),
            1,box(100,259,160,279),1536);
        submit("scene clears density threshold track",0,1,0,0,0,0,0,0);

        // One brightness flash creates an appearance and a disappearance
        // difference. Two consecutive candidate frames must remain unconfirmed.
        submit("single flash appearance",1,0,32,1536,box(100,259,160,279),0,0,0);
        submit("single flash disappearance",1,0,32,1536,box(100,259,160,279),0,0,0);
        submit("flash stops before third confirmation",0,0,0,0,0,0,0,0);
        idle(1024);

        submit("new scene first confirmation",1,0,32,1536,box(500,659,320,439),0,0,0);
        submit("new scene second confirmation",1,0,32,1536,box(500,659,320,439),0,0,0);
        submit("new scene third confirms",1,0,32,1536,box(500,659,320,439),
            1,box(500,659,320,439),1536);
        idle(1024);
        submit("eight-pixel deadband holds coordinates",1,0,32,1600,box(508,667,328,447),
            1,box(500,659,320,439),1600);
        submit("nine-pixel change rounds quarter step upward",1,0,32,1664,box(509,668,329,448),
            1,box(503,662,323,442),1664);
        submit("negative update also rounds toward target",1,0,32,1728,box(494,653,314,433),
            1,box(500,659,320,439),1728);

        submit("far proposal first miss holds old track",1,0,32,2048,box(900,1059,500,619),
            1,box(500,659,320,439),1728);
        submit("far proposal second miss holds old track",1,0,32,2048,box(900,1059,500,619),
            1,box(500,659,320,439),1728);
        submit("far proposal third miss releases and seeds",1,0,32,2048,box(900,1059,500,619),0,0,0);
        submit("far target second confirmation",1,0,32,2048,box(900,1059,500,619),0,0,0);
        submit("far target third confirmation starts directly",1,0,32,2048,box(900,1059,500,619),
            1,box(900,1059,500,619),2048);

        submit("huge nearby box first miss",1,0,96,8192,box(580,1279,500,619),
            1,box(900,1059,500,619),2048);
        submit("huge nearby box second miss",1,0,96,8192,box(580,1279,500,619),
            1,box(900,1059,500,619),2048);
        submit("huge nearby box third miss releases",1,0,96,8192,box(580,1279,500,619),0,0,0);
        submit("normal size resets huge candidate confirmation",1,0,32,2048,box(900,1059,500,619),0,0,0);
        submit("normal size second reconfirmation",1,0,32,2048,box(900,1059,500,619),0,0,0);
        submit("normal size third reconfirmation",1,0,32,2048,box(900,1059,500,619),
            1,box(900,1059,500,619),2048);
        submit("tiny nearby box is a size mismatch",1,0,8,512,box(976,983,552,559),
            1,box(900,1059,500,619),2048);
        submit("associated box resets miss counter",1,0,32,2112,box(900,1059,500,619),
            1,box(900,1059,500,619),2112);
        submit("ordinary first miss holds",0,0,0,0,0,1,box(900,1059,500,619),2112);
        submit("ordinary second miss holds",0,0,0,0,0,1,box(900,1059,500,619),2112);
        idle(1024);
        submit("ordinary third miss clears",0,0,0,0,0,0,0,0);

        submit("scene test first confirmation",1,0,32,1536,box(100,259,160,279),0,0,0);
        submit("scene test second confirmation",1,0,32,1536,box(100,259,160,279),0,0,0);
        submit("scene test third confirmation",1,0,32,1536,box(100,259,160,279),
            1,box(100,259,160,279),1536);
        submit("scene change clears immediately despite candidate",1,1,32,1536,box(100,259,160,279),0,0,0);
        submit("scene change resets first confirmation",1,0,32,1536,box(100,259,160,279),0,0,0);
        submit("scene change resets second confirmation",1,0,32,1536,box(100,259,160,279),0,0,0);
        submit("scene change permits fresh third confirmation",1,0,32,1536,box(100,259,160,279),
            1,box(100,259,160,279),1536);
        idle(4);

        // Reset during the intermediate publication stage cancels that token.
        submit("pending publication canceled by reset",1,0,32,1536,box(109,268,169,288),
            1,box(103,262,163,282),1536);
        reset_dut();
        idle(16);
        submit("top-left first confirmation after reset",1,0,32,2048,box(0,127,0,95),0,0,0);
        submit("top-left second confirmation after reset",1,0,32,2048,box(0,127,0,95),0,0,0);
        submit("top-left third confirmation after reset",1,0,32,2048,box(0,127,0,95),
            1,box(0,127,0,95),2048);
        submit("top-left smoothing preserves valid bounds",1,0,32,2112,box(9,136,9,104),
            1,box(3,130,3,98),2112);
        submit("scene clears top-left boundary track",0,1,0,0,0,0,0,0);
        submit("bottom-right first confirmation",1,0,32,2048,box(1152,1279,624,719),0,0,0);
        submit("bottom-right second confirmation",1,0,32,2048,box(1152,1279,624,719),0,0,0);
        submit("bottom-right third confirmation",1,0,32,2048,box(1152,1279,624,719),
            1,box(1152,1279,624,719),2048);
        submit("bottom-right negative smoothing preserves bounds",1,0,32,2112,box(1143,1270,615,710),
            1,box(1149,1276,621,716),2112);
        submit("exact center association limit is accepted",1,0,32,2176,box(1079,1206,551,646),
            1,box(1131,1258,603,698),2176);
        submit("one pixel beyond center limit is rejected",1,0,32,4096,box(1014,1141,486,581),
            1,box(1131,1258,603,698),2176);
        submit("scene clears before narrow box",0,1,0,0,0,0,0,0);
        submit("legal narrow box first confirmation",1,0,8,512,box(0,1,0,1),0,0,0);
        submit("legal narrow box second confirmation",1,0,8,512,box(0,1,0,1),0,0,0);
        submit("legal narrow box third confirms",1,0,8,512,box(0,1,0,1),
            1,box(0,1,0,1),512);
        // Independent endpoint smoothing would yield [3,1]. Both axes
        // must use the valid current interval instead of publishing a cross.
        submit("deadband crossing falls back to current box",1,0,8,576,box(9,9,9,9),
            1,box(9,9,9,9),576);
        submit("scene clears before one-axis crossing",0,1,0,0,0,0,0,0);
        submit("one narrow axis first confirmation",1,0,16,1024,box(100,227,0,1),0,0,0);
        submit("one narrow axis second confirmation",1,0,16,1024,box(100,227,0,1),0,0,0);
        submit("one narrow axis third confirms",1,0,16,1024,box(100,227,0,1),
            1,box(100,227,0,1),1024);
        submit("only crossed axis falls back",1,0,16,1088,box(109,236,9,9),
            1,box(103,230,9,9),1088);
        idle(64);
        if (queue_head != queue_tail || received+canceled != submitted ||
            canceled != 1 || confirmed < 20 || suppressed < 20 || resets != 2 ||
            idle_checks < 3000)
            $fatal(1, "Incomplete stabilizer coverage inputs=%0d outputs=%0d canceled=%0d found=%0d suppressed=%0d idle=%0d resets=%0d",
                submitted,received,canceled,confirmed,suppressed,idle_checks,resets);
        $display("MOTION_RESULT_STABILIZER_PASS inputs=%0d outputs=%0d canceled=%0d found=%0d suppressed=%0d idle_checks=%0d resets=%0d",
            submitted,received,canceled,confirmed,suppressed,idle_checks,resets);
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "Motion result stabilizer test timeout");
    end
endmodule
