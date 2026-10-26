`timescale 1ns/1ps

// Call the actual RTL functions rather than a copied implementation.
// Every 12-bit absolute-value pair is checked with equal/opposite signs.
module tb_scharr_direction_exhaustive;
    scharr_edge_detect_96 #(.IMG_WIDTH(8),.IMG_HEIGHT(3)) dut (
        .I_clk(1'b0),.I_rst_n(1'b0),.I_tvalid(1'b0),.I_tuser(1'b0),
        .I_tlast(1'b0),.I_tdata(96'd0),.I_tready(1'b1),
        .O_tvalid(),.O_tuser(),.O_tlast(),.O_tready(),
        .O_tdata(),.O_emboss_data(),.O_cartoon_data(),.O_morph_data()
    );
    scharr_edge_detect_96_reference #(.IMG_WIDTH(8),.IMG_HEIGHT(3)) reference (
        .I_clk(1'b0),.I_rst_n(1'b0),.I_tvalid(1'b0),.I_tuser(1'b0),
        .I_tlast(1'b0),.I_tdata(96'd0),.I_tready(1'b1),
        .O_tvalid(),.O_tuser(),.O_tlast(),.O_tready(),
        .O_tdata(),.O_emboss_data(),.O_cartoon_data(),.O_morph_data()
    );
    integer ax, ay, different_sign;
    integer checks=0, boundary_checks=0, zero_checks=0;
    integer axis_x=0, axis_y=0, diagonal_equal=0, diagonal_opposite=0;
    reg [25:0] gradient;
    reg [14:0] actual, expected;
    initial begin
        for (ax=0;ax<4096;ax=ax+1) begin
            for (ay=0;ay<4096;ay=ay+1) begin
                for (different_sign=0;different_sign<2;different_sign=different_sign+1) begin
                    gradient={1'b0,ax[11:0],different_sign[0],ay[11:0]};
                    actual=dut.magnitude_direction(gradient);
                    expected=reference.magnitude_direction(gradient);
                    if (actual !== expected || actual[14:2] != ax+ay)
                        $fatal(1,"Scharr actual-function mismatch ax=%0d ay=%0d different_sign=%0d actual=%h expected=%h",
                               ax,ay,different_sign,actual,expected);
                    if (ax==0 && ay==0) begin
                        if (actual !== 15'd0)
                            $fatal(1,"Scharr zero must retain x-axis tie priority");
                        zero_checks=zero_checks+1;
                    end
                    if (ay*256==ax*106 || ax*256==ay*106) begin
                        if (actual[1:0] != (ax>=ay ? 0 : 2))
                            $fatal(1,"Scharr axis boundary must retain <= priority");
                        boundary_checks=boundary_checks+1;
                    end
                    case (actual[1:0])
                        0: axis_x=axis_x+1;
                        1: diagonal_equal=diagonal_equal+1;
                        2: axis_y=axis_y+1;
                        3: diagonal_opposite=diagonal_opposite+1;
                    endcase
                    checks=checks+1;
                end
            end
            if (ax%512==511)
                $display("SCHARR_DIRECTION_PROGRESS ax_through=%0d checks=%0d",ax,checks);
        end
        if (checks!=33554432 || zero_checks!=2 || boundary_checks!=126 ||
            axis_x==0 || axis_y==0 || diagonal_equal==0 || diagonal_opposite==0)
            $fatal(1,"Scharr exhaustive coverage incomplete checks=%0d zero=%0d boundary=%0d",
                   checks,zero_checks,boundary_checks);
        $display("SCHARR_DIRECTION_EXHAUSTIVE_PASS checks=%0d abs_x_values=4096 abs_y_values=4096 sign_relations=2 zero=%0d exact_threshold=%0d axis_x=%0d axis_y=%0d diagonal_equal=%0d diagonal_opposite=%0d frozen_baseline=1 actual_rtl_function=1",
                 checks,zero_checks,boundary_checks,axis_x,axis_y,
                 diagonal_equal,diagonal_opposite);
        $finish;
    end
endmodule
