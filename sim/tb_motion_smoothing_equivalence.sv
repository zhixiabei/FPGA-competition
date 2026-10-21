`timescale 1ns/1ps

module motion_smoothing_case #(
    parameter integer DEADBAND = 8,
    parameter integer EXHAUSTIVE = 0
) (
    output reg done = 0
);
    motion_result_stabilizer #(.DEADBAND(DEADBAND)) dut (
        .I_clk(1'b0), .I_rst_n(1'b0), .I_result_ready(1'b0),
        .I_found(1'b0), .I_scene_change(1'b0),
        .I_supported_blocks(24'd0), .I_pixels(24'd0),
        .I_xmin(12'd0), .I_xmax(12'd0), .I_ymin(12'd0), .I_ymax(12'd0),
        .O_result_ready(), .O_found(), .O_xmin(), .O_xmax(),
        .O_ymin(), .O_ymax(), .O_center_x(), .O_center_y(),
        .O_pixels(), .O_frame_toggle()
    );

    integer previous_value, current_value, offset;
    integer comparisons = 0;

    task automatic check_pair(input integer previous, current);
        integer distance, weighted, expected;
        reg [11:0] observed;
        begin
            if (current >= 0 && current <= 4095) begin
                distance = current >= previous ?
                    current - previous : previous - current;
                // Independent weighted-average reference. Round toward the
                // current coordinate, including changes smaller than four.
                weighted = 3 * previous + current;
                expected = distance <= DEADBAND ? previous :
                    (weighted + (current >= previous ? 3 : 0)) / 4;
                observed = dut.smooth_coordinate(previous[11:0],current[11:0]);
                if (observed !== expected[11:0])
                    $fatal(1,
                        "Smoothing mismatch deadband=%0d previous=%0d current=%0d actual=%0d expected=%0d",
                        DEADBAND,previous,current,observed,expected);
                comparisons = comparisons + 1;
            end
        end
    endtask

    initial begin
        if (EXHAUSTIVE) begin
            for (previous_value = 0; previous_value < 4096; previous_value = previous_value + 1)
                for (current_value = 0; current_value < 4096; current_value = current_value + 1)
                    check_pair(previous_value,current_value);
        end else begin
            for (previous_value = 0; previous_value < 4096; previous_value = previous_value + 1) begin
                check_pair(previous_value,0);
                check_pair(previous_value,4095);
                for (offset = -4; offset <= 4; offset = offset + 1) begin
                    check_pair(previous_value,previous_value + offset);
                    check_pair(previous_value,previous_value + DEADBAND + offset);
                    check_pair(previous_value,previous_value - DEADBAND + offset);
                end
            end
        end
        $display("MOTION_SMOOTHING_CASE_PASS deadband=%0d exhaustive=%0d comparisons=%0d",
            DEADBAND,EXHAUSTIVE,comparisons);
        done = 1;
    end
endmodule

module tb_motion_smoothing_equivalence;
    wire [7:0] done;
    function integer case_deadband(input integer index);
        begin
            case (index)
                0: case_deadband = 0;
                1: case_deadband = 1;
                2: case_deadband = 7;
                3: case_deadband = 8;
                4: case_deadband = 16;
                5: case_deadband = 64;
                6: case_deadband = 4095;
                default: case_deadband = 4096;
            endcase
        end
    endfunction
    genvar case_index;
    generate
        for (case_index = 0; case_index < 8; case_index = case_index + 1) begin : gen_case
            motion_smoothing_case #(
                .DEADBAND(case_deadband(case_index)), .EXHAUSTIVE(case_index == 3)
            ) check_case (.done(done[case_index]));
        end
    endgenerate
    initial begin
        wait (&done);
        $display("MOTION_SMOOTHING_EQUIVALENCE_PASS coordinate_pairs=16777216 deadbands=0,1,7,8,16,64,4095,4096");
        $finish;
    end
endmodule
