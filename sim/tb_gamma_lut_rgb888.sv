`timescale 1ns/1ps

module tb_gamma_lut_rgb888;
    reg clk = 0;
    always #5 clk = ~clk;

    reg [23:0] rgb = 0;
    wire [23:0] corrected_rgb;
    wire [23:0] bypass_rgb;

    gamma_lut_rgb888 enabled (
        .I_clk(clk), .I_rgb(rgb), .O_rgb(corrected_rgb)
    );
    gamma_lut_rgb888 #(.ENABLE(0)) bypass (
        .I_clk(clk), .I_rgb(rgb), .O_rgb(bypass_rgb)
    );

    integer vectors = 0;
    integer hold_checks = 0;
    integer monotonic_checks = 0;
    integer index;
    integer previous_gray;
    reg primed = 0;
    reg [23:0] previous_corrected;
    reg [23:0] previous_bypass;
    reg [7:0] sweep;
    reg [7:0] mixed_green;
    reg [7:0] mixed_blue;

    // Compute the specified segments independently of the DUT's lookup table.
    function automatic [7:0] reference_channel(input [7:0] value);
        integer x0, x1, y0, y1;
        integer width;
        begin
            if (value <= 16) begin
                x0 = 0; x1 = 16; y0 = 0; y1 = 23;
            end else if (value <= 32) begin
                x0 = 16; x1 = 32; y0 = 23; y1 = 44;
            end else if (value <= 64) begin
                x0 = 32; x1 = 64; y0 = 44; y1 = 80;
            end else if (value <= 96) begin
                x0 = 64; x1 = 96; y0 = 80; y1 = 104;
            end else if (value <= 128) begin
                x0 = 96; x1 = 128; y0 = 104; y1 = 128;
            end else if (value <= 160) begin
                x0 = 128; x1 = 160; y0 = 128; y1 = 152;
            end else if (value <= 192) begin
                x0 = 160; x1 = 192; y0 = 152; y1 = 180;
            end else if (value <= 224) begin
                x0 = 192; x1 = 224; y0 = 180; y1 = 210;
            end else if (value <= 240) begin
                x0 = 224; x1 = 240; y0 = 210; y1 = 232;
            end else begin
                x0 = 240; x1 = 255; y0 = 232; y1 = 255;
            end
            width = x1 - x0;
            reference_channel =
                (y0 * width + (value - x0) * (y1 - y0) + width / 2) / width;
        end
    endfunction

    function automatic [23:0] reference_rgb(input [23:0] value);
        reference_rgb = {
            reference_channel(value[23:16]),
            reference_channel(value[15:8]),
            reference_channel(value[7:0])
        };
    endfunction

    task automatic check_hold;
        begin
            if (primed) begin
                if (corrected_rgb !== previous_corrected ||
                    bypass_rgb !== previous_bypass)
                    $fatal(1, "Output changed without a rising clock edge: corrected=%h/%h bypass=%h/%h",
                           corrected_rgb, previous_corrected,
                           bypass_rgb, previous_bypass);
                hold_checks = hold_checks + 1;
            end
        end
    endtask

    task automatic apply_vector(input [23:0] value);
        reg [23:0] expected;
        begin
            @(negedge clk);
            rgb = value ^ 24'h5aa55a;
            #1;
            check_hold();
            rgb = value;
            #1;
            check_hold();
            @(posedge clk);
            #1;
            expected = reference_rgb(value);
            if (corrected_rgb !== expected)
                $fatal(1, "Tone curve mismatch vector=%0d input=%h output=%h expected=%h",
                       vectors, value, corrected_rgb, expected);
            if (bypass_rgb !== value)
                $fatal(1, "Disabled curve must retain one clock of latency: input=%h output=%h",
                       value, bypass_rgb);
            previous_corrected = expected;
            previous_bypass = value;
            primed = 1;
            vectors = vectors + 1;
        end
    endtask

    initial begin
        apply_vector(24'h000000);
        if (corrected_rgb !== 24'h000000)
            $fatal(1, "Black endpoint changed");

        previous_gray = 0;
        for (index = 0; index < 256; index = index + 1) begin
            sweep = index;
            apply_vector({sweep, sweep, sweep});
            if (index > 0 && corrected_rgb[23:16] < previous_gray)
                $fatal(1, "Curve is not monotonic at input=%0d", index);
            if (corrected_rgb[23:16] !== corrected_rgb[15:8] ||
                corrected_rgb[15:8] !== corrected_rgb[7:0])
                $fatal(1, "Neutral gray acquired a color cast at input=%0d", index);
            previous_gray = corrected_rgb[23:16];
            if (index > 0)
                monotonic_checks = monotonic_checks + 1;
        end
        if (corrected_rgb !== 24'hffffff)
            $fatal(1, "White endpoint changed");

        for (index = 0; index < 256; index = index + 1) begin
            sweep = index;
            mixed_green = 255 - index;
            mixed_blue = (index * 73 + 19) & 255;
            apply_vector({sweep, mixed_green, mixed_blue});
        end

        for (index = 0; index < 256; index = index + 1) begin
            sweep = index;
            apply_vector({sweep, 8'd32, 8'd224});
            apply_vector({8'd224, sweep, 8'd64});
            apply_vector({8'd16, 8'd192, sweep});
        end

        if (vectors != 1281 || hold_checks != 2560 ||
            monotonic_checks != 255)
            $fatal(1, "Tone curve coverage is incomplete");
        $display("GAMMA_LUT_RGB888_PASS vectors=%0d hold_checks=%0d monotonic_checks=%0d exhaustive_gray=256 mixed=256 isolated_channels=768",
                 vectors, hold_checks, monotonic_checks);
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "Tone curve regression timed out");
    end
endmodule
