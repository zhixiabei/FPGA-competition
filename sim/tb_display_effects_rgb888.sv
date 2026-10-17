`timescale 1ns/1ps

module tb_display_effects_rgb888;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg [23:0] rgb = 0;
    reg [3:0] effect_mode = 0;
    reg [7:0] effect_param = 0;
    wire [23:0] output_rgb;

    display_effects_rgb888 dut (
        .I_clk(clk), .I_rst_n(rst_n), .I_rgb(rgb),
        .I_mode(effect_mode), .I_param(effect_param), .O_rgb(output_rgb)
    );

    integer vectors = 0;
    integer comparisons = 0;
    integer hold_checks = 0;
    integer mode_index;
    integer param_index;
    integer color_index;
    integer rapid_index;
    integer boundary_vectors = 0;
    integer preserved_red = 0, preserved_green = 0, rejected_color = 0;
    integer bound_green, bound_blue, bound_red, bound_offset, bound_candidate;
    reg expected_valid = 0;
    reg [23:0] expected_previous = 0;
    reg [7:0] sweep_red;
    reg [7:0] sweep_green;
    reg [7:0] mixed_blue;

    function automatic [7:0] reference_luma(input [23:0] value);
        integer weighted;
        begin
            weighted = value[23:16] * 77 + value[15:8] * 150
                     + value[7:0] * 29 + 128;
            reference_luma = weighted >> 8;
        end
    endfunction

    function automatic bit reference_keep_color(input [23:0] value);
        integer r,g,b;
        bit red,green;
        begin
            r=value[23:16]; g=value[15:8]; b=value[7:0];
            red=r>=24 && r-g>=6 && r-b>=6 && r*2>=g*3 && r*2>=b*3 &&
                g*3-r<=b*2 && b*3-r<=g*2;
            green=g>=24 && g-r>=6 && g-b>=6 && g*2>=r*3 && g*2>=b*3 &&
                  r*3-g<=b*2 && b*3-g<=r*2;
            reference_keep_color=red || green;
        end
    endfunction

    function automatic integer minimum_red(input integer g,input integer b);
        integer threshold;
        begin
            // Solve each red condition for its minimum accepted R. These
            // boundaries exercise inclusive limits and rejection one below.
            threshold=24;
            if(threshold<g+6) threshold=g+6;
            if(threshold<b+6) threshold=b+6;
            if(threshold<(3*g+1)/2) threshold=(3*g+1)/2;
            if(threshold<(3*b+1)/2) threshold=(3*b+1)/2;
            if(threshold<3*g-2*b) threshold=3*g-2*b;
            if(threshold<3*b-2*g) threshold=3*b-2*g;
            minimum_red=threshold;
        end
    endfunction

    function automatic [7:0] reference_gamma_channel(input [7:0] value);
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
            reference_gamma_channel =
                (y0 * width + (value - x0) * (y1 - y0) + width / 2) / width;
        end
    endfunction

    function automatic [23:0] reference_rgb(
        input [23:0] value,
        input [3:0] mode_value
    );
        reg [7:0] luma;
        begin
            luma = reference_luma(value);
            case (mode_value)
                4'd1: reference_rgb = {luma, luma, luma};
                4'd2, 4'd4, 4'd6, 4'd8: reference_rgb = value;
                4'd3, 4'd7: reference_rgb = ~value;
                4'd5: reference_rgb = reference_keep_color(value) ? value :
                                      {luma, luma, luma};
                default: reference_rgb = {
                    reference_gamma_channel(value[23:16]),
                    reference_gamma_channel(value[15:8]),
                    reference_gamma_channel(value[7:0])
                };
            endcase
        end
    endfunction

    task automatic apply_vector(
        input [23:0] value,
        input [3:0] mode_value,
        input [7:0] param_value
    );
        reg [23:0] held_output;
        reg [23:0] expected_now;
        begin
            @(negedge clk);
            held_output = output_rgb;
            rgb = value ^ 24'h5aa55a;
            effect_mode = mode_value ^ 4'hf;
            effect_param = param_value ^ 8'hff;
            #1;
            if (output_rgb !== held_output)
                $fatal(1, "Output changed without a rising edge");
            hold_checks = hold_checks + 1;
            rgb = value;
            effect_mode = mode_value;
            effect_param = param_value;
            expected_now = reference_rgb(value, mode_value);
            #1;
            if (output_rgb !== held_output)
                $fatal(1, "Output changed while settling an input vector");
            hold_checks = hold_checks + 1;
            @(posedge clk);
            #1;
            if (expected_valid) begin
                if (output_rgb !== expected_previous)
                    $fatal(1,
                           "Effect mismatch vector=%0d mode=%0d param=%0d input=%h output=%h expected=%h",
                           vectors, mode_value, param_value, value,
                           output_rgb, expected_previous);
                comparisons = comparisons + 1;
            end
            expected_previous = expected_now;
            expected_valid = 1;
            vectors = vectors + 1;
            if(mode_value==5) begin
                if(!reference_keep_color(value)) rejected_color=rejected_color+1;
                else if(value[23:16]>value[15:8]) preserved_red=preserved_red+1;
                else preserved_green=preserved_green+1;
            end
        end
    endtask

    task automatic flush_pipeline;
        begin
            @(negedge clk);
            rgb = 24'h123456;
            effect_mode = 4'd0;
            effect_param = 8'd0;
            @(posedge clk);
            #1;
            if (!expected_valid || output_rgb !== expected_previous)
                $fatal(1, "Final pipeline value was not emitted");
            comparisons = comparisons + 1;
            expected_valid = 0;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        #1;
        if (output_rgb !== 24'd0)
            $fatal(1, "Reset output must be black");
        @(negedge clk);
        rst_n = 1;
        apply_vector(24'h000000, 4'd0, 8'd0);
        apply_vector(24'hffffff, 4'd0, 8'd255);
        apply_vector(24'h123456, 4'd2, 8'd5);

        // Primary colors and neutral endpoints cover luma and Gamma bounds.
        for (mode_index = 0; mode_index < 16; mode_index = mode_index + 1) begin
            apply_vector(24'h000000, mode_index[3:0], 8'd0);
            apply_vector(24'hffffff, mode_index[3:0], 8'd255);
            apply_vector(24'hff0000, mode_index[3:0], 8'd17);
            apply_vector(24'h00ff00, mode_index[3:0], 8'd93);
            apply_vector(24'h0000ff, mode_index[3:0], 8'd170);
            apply_vector(24'h808080, mode_index[3:0], 8'd128);
        end

        // The removed parameter path must have no effect in any legal or
        // invalid mode. Invalid modes use the original Gamma image.
        for (mode_index = 0; mode_index < 16; mode_index = mode_index + 1)
            for (param_index = 0; param_index < 256; param_index = param_index + 1)
                apply_vector(24'h804020, mode_index[3:0], param_index[7:0]);

        // Spatial effects are computed before DDR and bypass Gamma.
        // Cover every R/G combination and all blue values for all nine modes.
        for (mode_index = 0; mode_index < 9; mode_index = mode_index + 1) begin
            for (color_index = 0; color_index < 65536; color_index = color_index + 1) begin
                sweep_red = color_index >> 8;
                sweep_green = color_index;
                mixed_blue = (sweep_red * 73 + sweep_green * 19) & 255;
                apply_vector({sweep_red, sweep_green, mixed_blue},
                             mode_index[3:0], color_index[7:0]);
            end
            for (color_index = 0; color_index < 256; color_index = color_index + 1) begin
                sweep_red = color_index;
                apply_vector({sweep_red, sweep_red, sweep_red},
                             mode_index[3:0], 8'd0);
            end
        end

        // For every G/B pair, straddle the exact red hue/saturation/brightness
        // boundary. Exchanging R/G repeats the same coverage for green.
        for(bound_green=0;bound_green<256;bound_green=bound_green+1)
            for(bound_blue=0;bound_blue<256;bound_blue=bound_blue+1) begin
                bound_red=minimum_red(bound_green,bound_blue);
                for(bound_offset=-1;bound_offset<=1;bound_offset=bound_offset+1) begin
                    bound_candidate=bound_red+bound_offset;
                    if(bound_candidate>=0 && bound_candidate<=255) begin
                        apply_vector({8'(bound_candidate),8'(bound_green),8'(bound_blue)},
                                     4'd5,8'd0);
                        apply_vector({8'(bound_green),8'(bound_candidate),8'(bound_blue)},
                                     4'd5,8'd255);
                        boundary_vectors=boundary_vectors+2;
                    end
                end
            end

        // Rapid controls and invalid values must follow the correct pixel.
        for (rapid_index = 0; rapid_index < 4096; rapid_index = rapid_index + 1)
            apply_vector((rapid_index * 24'h51931d) ^ 24'h2ad575,
                         rapid_index[3:0], rapid_index[11:4]);
        flush_pipeline();
        if (vectors != 600419 + boundary_vectors || comparisons != vectors ||
            hold_checks != vectors * 2 || boundary_vectors<60000 ||
            preserved_red==0 || preserved_green==0 || rejected_color==0)
            $fatal(1, "Display effect coverage counters are incomplete");

        // Reset suppresses the unreset Gamma ROM and clears both stages.
        for (mode_index = 0; mode_index < 9; mode_index = mode_index + 1) begin
            @(negedge clk);
            effect_mode = mode_index[3:0];
            rgb = 24'h4a6b8c;
            repeat (2) @(posedge clk);
            #1;
            rst_n = 0;
            #1;
            if (output_rgb !== 24'd0)
                $fatal(1, "Asynchronous reset did not suppress output");
            @(negedge clk);
            rst_n = 1;
            rgb = 24'h804020;
            @(posedge clk);
            #1;
            if (output_rgb !== 24'd0)
                $fatal(1, "Pipeline was not empty after reset release");
            @(posedge clk);
            #1;
            if (output_rgb !== reference_rgb(24'h804020, mode_index[3:0]))
                $fatal(1, "Post-reset pixel was not delayed by two clocks");
        end

        $display("DISPLAY_EFFECTS_RGB888_PASS vectors=%0d comparisons=%0d hold_checks=%0d modes=9 invalid_modes=7 params_ignored=256 rg_combinations=65536 latency_clocks=2 gamma_original_curve=1 emboss_precomputed=1 cartoon_precomputed=1 scharr_inverse=1 morph_precomputed=1 color_boundaries=%0d preserved_red=%0d preserved_green=%0d rejected=%0d",
                 vectors, comparisons, hold_checks,boundary_vectors,
                 preserved_red,preserved_green,rejected_color);
        $finish;
    end

    initial begin
        #15000000;
        $fatal(1, "Display effect regression timed out");
    end
endmodule
