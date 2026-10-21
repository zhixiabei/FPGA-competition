`timescale 1ns/1ps

// The instances contain the actual candidate/frozen RTL clip functions.
// Pixel/CDC logic is idle because this test isolates combinational clipping.
module tb_bridge_clip_equivalence;
    target_frame_bridge dut (
        .I_csi_clk(1'b0),.I_ddr_clk(1'b0),.I_hdmi_clk(1'b0),.I_rst_n(1'b0),
        .I_frame_start(1'b0),.I_frame_id(10'd0),.I_effect_config(12'd0),
        .I_motion_mode(1'b0),.I_color_mode(2'd0),.I_result_ready(1'b0),
        .I_result_frame_id(10'd0),.I_result_found(1'b0),
        .I_result_motion_mode(1'b0),.I_result_color_mode(2'd0),
        .I_result_xmin(12'd0),.I_result_xmax(12'd0),
        .I_result_ymin(12'd0),.I_result_ymax(12'd0),
        .I_result_center_x(12'd0),.I_result_center_y(12'd0),
        .I_multi_valid(4'd0),.I_multi_hold(4'd0),.I_multi_boxes(192'd0),
        .I_multi_shapes(8'd0),.I_multi_overflow(1'b0),.I_write_start(1'b0),
        .I_write_slot(2'd0),.I_write_word(1'b0),.I_read_start(1'b0),.I_read_slot(2'd0)
    );
    target_frame_bridge_reference reference (
        .I_csi_clk(1'b0),.I_ddr_clk(1'b0),.I_hdmi_clk(1'b0),.I_rst_n(1'b0),
        .I_frame_start(1'b0),.I_frame_id(10'd0),.I_effect_config(12'd0),
        .I_motion_mode(1'b0),.I_color_mode(2'd0),.I_result_ready(1'b0),
        .I_result_frame_id(10'd0),.I_result_found(1'b0),
        .I_result_motion_mode(1'b0),.I_result_color_mode(2'd0),
        .I_result_xmin(12'd0),.I_result_xmax(12'd0),
        .I_result_ymin(12'd0),.I_result_ymax(12'd0),
        .I_result_center_x(12'd0),.I_result_center_y(12'd0),
        .I_multi_valid(4'd0),.I_multi_hold(4'd0),.I_multi_boxes(192'd0),
        .I_multi_shapes(8'd0),.I_multi_overflow(1'b0),.I_write_start(1'b0),
        .I_write_slot(2'd0),.I_write_word(1'b0),.I_read_start(1'b0),.I_read_slot(2'd0)
    );
    integer value, offset, shifted;
    integer checks=0, x_exact_limit=0, y_exact_limit=0, high_inputs=0;
    reg [11:0] actual_x, actual_y, baseline_x, baseline_y, expected_x, expected_y;
    initial begin
        for (value=0;value<4096;value=value+1) begin
            for (offset=0;offset<4;offset=offset+1) begin
                actual_x=dut.F_clip_x(value[11:0],offset[1:0]);
                actual_y=dut.F_clip_y(value[11:0],offset[1:0]);
                baseline_x=reference.F_clip_x(value[11:0],offset[1:0]);
                baseline_y=reference.F_clip_y(value[11:0],offset[1:0]);
                shifted=value+offset;
                expected_x=shifted>1279 ? 1279 : shifted;
                expected_y=shifted>719 ? 719 : shifted;
                if (actual_x !== baseline_x || actual_y !== baseline_y ||
                    actual_x !== expected_x || actual_y !== expected_y)
                    $fatal(1,"Bridge clip mismatch value=%0d offset=%0d x=%0d/%0d/%0d y=%0d/%0d/%0d",
                           value,offset,actual_x,baseline_x,expected_x,
                           actual_y,baseline_y,expected_y);
                if (shifted==1279) x_exact_limit=x_exact_limit+1;
                if (shifted==719) y_exact_limit=y_exact_limit+1;
                if (value>=2048) high_inputs=high_inputs+1;
                checks=checks+2;
            end
        end
        if (checks!=32768 || x_exact_limit!=4 || y_exact_limit!=4 || high_inputs!=8192)
            $fatal(1,"Bridge clip coverage incomplete");
        $display("BRIDGE_CLIP_EQUIVALENCE_PASS checks=%0d input_values=4096 offsets=4 axes=2 x_exact_limit=%0d y_exact_limit=%0d high_inputs=%0d frozen_baseline=1 actual_rtl_function=1 independent_saturation_oracle=1",
                 checks,x_exact_limit,y_exact_limit,high_inputs);
        $finish;
    end
endmodule
