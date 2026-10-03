`timescale 1ns/1ps
// Independent image-space reference: classify a whole generated image,
// then evaluate centered 3x3 neighborhoods and derive its bounding box.
module tb_color_target_detect;
    parameter integer W = 64;
    parameter integer H = 48;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0, valid = 0;
    reg [11:0] x = 0, y = 0;
    reg [23:0] rgb = 0;
    wire raw_red, ready, found, mask_valid, mask_hit;
    wire [11:0] xmin, xmax, ymin, ymax, cx, cy, mx, my;
    wire [23:0] pixels;
    reg [23:0] image [0:H-1][0:W-1];
    bit golden_raw [0:H-1][0:W-1];
    bit golden_mask [0:H-1][0:W-1];
    integer expected_count, expected_xmin, expected_xmax, expected_ymin, expected_ymax;
    integer frames = 0, checked_masks = 0;
    bit expected_found;

    color_target_detect #(.IMG_WIDTH(W), .IMG_HEIGHT(H)) dut (
        .I_clk(clk), .I_rst_n(rst_n), .I_valid(valid), .I_x(x), .I_y(y), .I_rgb(rgb),
        .O_pixel_red(raw_red), .O_result_ready(ready), .O_found(found),
        .O_xmin(xmin), .O_xmax(xmax), .O_ymin(ymin), .O_ymax(ymax),
        .O_center_x(cx), .O_center_y(cy), .O_pixels(pixels),
        .O_mask_valid(mask_valid), .O_mask_hit(mask_hit), .O_mask_x(mx), .O_mask_y(my)
    );

    function automatic bit classify(input reg [23:0] p);
        integer r, g, b;
        begin
            r = p[23:16]; g = p[15:8]; b = p[7:0];
            classify = r >= 80 && r-g >= 30 && r-b >= 30;
        end
    endfunction

    task automatic background(input reg [23:0] p);
        for (integer yy=0; yy<H; yy=yy+1)
            for (integer xx=0; xx<W; xx=xx+1) image[yy][xx] = p;
    endtask

    task automatic rectangle(input integer x0, y0, x1, y1, input reg [23:0] p);
        for (integer yy=y0; yy<=y1; yy=yy+1)
            for (integer xx=x0; xx<=x1; xx=xx+1) image[yy][xx] = p;
    endtask

    task automatic reference_image;
        integer total;
        begin
            expected_count = 0;
            expected_xmin = W-1; expected_xmax = 0;
            expected_ymin = H-1; expected_ymax = 0;
            for (integer yy=0; yy<H; yy=yy+1)
                for (integer xx=0; xx<W; xx=xx+1) begin
                    golden_raw[yy][xx] = classify(image[yy][xx]);
                    golden_mask[yy][xx] = 0;
                end
            for (integer yy=1; yy<H-1; yy=yy+1)
                for (integer xx=1; xx<W-1; xx=xx+1) begin
                    total = 0;
                    for (integer dy=-1; dy<=1; dy=dy+1)
                        for (integer dx=-1; dx<=1; dx=dx+1)
                            total = total + golden_raw[yy+dy][xx+dx];
                    golden_mask[yy][xx] = total >= 5;
                    if (total >= 5) begin
                        expected_count = expected_count+1;
                        if (xx < expected_xmin) expected_xmin = xx;
                        if (xx > expected_xmax) expected_xmax = xx;
                        if (yy < expected_ymin) expected_ymin = yy;
                        if (yy > expected_ymax) expected_ymax = yy;
                    end
                end
            expected_found = expected_count >= 128 &&
                expected_xmax-expected_xmin+1 >= 8 && expected_ymax-expected_ymin+1 >= 8;
        end
    endtask

    task automatic idle(input integer cycles);
        begin
            @(negedge clk); valid=0; rgb=0;
            repeat(cycles) @(negedge clk);
        end
    endtask

    task automatic run_frame(input bit add_gaps, input bit drop_pixel);
        begin
            reference_image();
            for (integer yy=0; yy<H; yy=yy+1) begin
                for (integer xx=0; xx<W; xx=xx+1) begin
                    @(negedge clk); valid=!(drop_pixel && yy==H/2 && xx==W/2);
                    x=xx; y=yy; rgb=image[yy][xx];
                    #1;
                    if (raw_red !== (valid && golden_raw[yy][xx]))
                        $fatal(1,"Raw classification mismatch x=%0d y=%0d rgb=%h",xx,yy,rgb);
                    @(posedge clk); #1;
                    if (valid && !drop_pixel && xx>=2 && yy>=2) begin
                        if (mask_valid !== 1 || mx !== xx-1 || my !== yy-1 ||
                            mask_hit !== golden_mask[yy-1][xx-1])
                            $fatal(1,"Mask mismatch input=%0d,%0d center=%0d,%0d",xx,yy,mx,my);
                        checked_masks=checked_masks+1;
                    end
                    if (add_gaps && (xx%11==7)) idle(2);
                end
                idle(3);
            end
            idle(4);
            if (drop_pixel) begin
                if (ready !== 0 || found !== 0) $fatal(1,"Incomplete frame accepted");
            end else begin
                if (ready !== 1 || found !== expected_found || pixels !== expected_count)
                    $fatal(1,"Result mismatch frame=%0d ready=%b found=%b/%b count=%0d/%0d",
                        frames,ready,found,expected_found,pixels,expected_count);
                if (expected_found) begin
                    if (xmin !== expected_xmin || xmax !== expected_xmax ||
                        ymin !== expected_ymin || ymax !== expected_ymax ||
                        cx !== (expected_xmin+expected_xmax)/2 ||
                        cy !== (expected_ymin+expected_ymax)/2)
                        $fatal(1,"Bounding box/center mismatch frame=%0d",frames);
                end else if ({xmin,xmax,ymin,ymax,cx,cy} !== 72'd0)
                    $fatal(1,"No-target coordinates not cleared");
            end
            frames=frames+1;
        end
    endtask

    initial begin
        idle(4); rst_n=1;
        background(24'h202020); run_frame(0,0);
        background(24'hfafafa); run_frame(0,0); // overflow trap, white
        background(24'hf0fa10); run_frame(0,0); // G+30 > 255
        background(24'hf010fa); run_frame(0,0); // B+30 > 255
        background(24'h501010); run_frame(0,0); // R==80, complete red field
        background(24'h4f1010); run_frame(0,0); // R==79, rejected
        background(24'hb49696); run_frame(0,0); // exact R-G/B==30
        background(24'hb49796); run_frame(0,0); // difference 29, rejected
        background(24'h202020);
        rectangle(10,10,25,25,24'hc02020);
        image[4][W-5]=24'hff0000; image[H-5][4]=24'hff0000;
        run_frame(1,0); // disconnected isolated noise cannot stretch box
        background(24'h202020);
        rectangle(W-22,H-22,W-4,H-4,24'hc02020); run_frame(0,0); // movement
        background(24'h202020); run_frame(0,0); // disappearance
        background(24'h202020); rectangle(5,5,9,9,24'hc02020); run_frame(0,0); // too small
        background(24'h202020); rectangle(0,0,16,16,24'hc02020); run_frame(0,0); // image border
        background(24'h202020); rectangle(10,10,25,25,24'hc02020); run_frame(0,1);
        background(24'h202020); run_frame(0,0); // recovery after incomplete frame
        background(24'h202020); rectangle(10,10,25,25,24'hc02020); run_frame(0,0);
        rst_n=0; idle(4);
        if (ready !== 0 || found !== 0) $fatal(1,"Reset did not clear result");
        rst_n=1; background(24'h202020); run_frame(0,0); // stale RAM must not leak
        $display("COLOR_TARGET_TEST_PASS W=%0d H=%0d frames=%0d masks=%0d",
            W,H,frames,checked_masks);
        $finish;
    end
    initial begin #300000000; $fatal(1,"Detector test timeout"); end
endmodule
