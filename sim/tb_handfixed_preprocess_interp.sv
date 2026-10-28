`timescale 1ns/1ps

module tb_handfixed_preprocess_interp;
    reg clk = 0;
    always #5 clk = ~clk;

    reg rst_n = 0;
    wire mem_valid;
    wire mem_write;
    wire [31:0] mem_addr;
    wire [127:0] mem_data;

    handfixed_preprocess dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(1'b0),
        .classifier(1'b0),
        .snapshot_base(32'b0),
        .roi_x(16'sd0),
        .roi_y(16'sd0),
        .roi_side(16'd1),
        .has_texture(),
        .texture_edges(),
        .texture_range(),
        .green_valid(),
        .green_row_end(),
        .green_pixel(),
        .busy(),
        .done(),
        .mem_valid(mem_valid),
        .mem_write(mem_write),
        .mem_addr(mem_addr),
        .mem_data(mem_data),
        .mem_ready(1'b0),
        .mem_rsp_valid(1'b0),
        .mem_rsp_data(128'b0)
    );

    integer i;
    integer s0;
    integer s1;
    integer s2;
    integer s3;
    integer fx;
    integer fy;
    integer h0;
    integer h1;
    integer expected;

    task check_interp;
        input integer in_s0;
        input integer in_s1;
        input integer in_s2;
        input integer in_s3;
        input integer in_fx;
        input integer in_fy;
        begin
            h0 = ((in_s0 << 8) - in_s0 * in_fx + in_s1 * in_fx + 128) >> 8;
            h1 = ((in_s2 << 8) - in_s2 * in_fx + in_s3 * in_fx + 128) >> 8;
            expected = ((h0 << 8) - h0 * in_fy + h1 * in_fy + 128) >> 8;

            @(negedge clk);
            dut.samples[0] = in_s0;
            dut.samples[1] = in_s1;
            dut.samples[2] = in_s2;
            dut.samples[3] = in_s3;
            dut.fx = in_fx;
            dut.fy = in_fy;
            dut.state = 4'd5;

            repeat (5) @(posedge clk);
            #1;
            if (dut.pixel !== expected[7:0]) begin
                $fatal(1,
                    "interpolation mismatch samples=%0d,%0d,%0d,%0d fx=%0d fy=%0d expected=%0d actual=%0d",
                    in_s0, in_s1, in_s2, in_s3, in_fx, in_fy, expected, dut.pixel);
            end
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;

        check_interp(0, 255, 255, 0, 0, 0);
        check_interp(0, 255, 255, 0, 255, 255);
        check_interp(255, 0, 0, 255, 127, 191);
        check_interp(1, 254, 17, 239, 1, 254);

        for (i = 0; i < 10000; i = i + 1) begin
            s0 = $urandom_range(255, 0);
            s1 = $urandom_range(255, 0);
            s2 = $urandom_range(255, 0);
            s3 = $urandom_range(255, 0);
            fx = $urandom_range(255, 0);
            fy = $urandom_range(255, 0);
            check_interp(s0, s1, s2, s3, fx, fy);
        end

        $display("HANDFIXED_PREPROCESS_INTERP_PASS vectors=%0d", i + 4);
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "interpolation test timeout");
    end
endmodule
