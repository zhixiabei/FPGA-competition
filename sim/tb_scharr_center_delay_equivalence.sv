`timescale 1ns/1ps

// Compare the compact centre delay with the frozen full-window baseline and
// with an independent frame-pixel oracle. First-row pixels and x=0/lane=0
// have no in-frame centre and are masked by the production cartoon path.
module scharr_center_delay_equivalence_case #(
    parameter integer WIDTH=20,HEIGHT=17,DATA_WIDTH=9,SEED=1
)(
    output reg done=0
);
    localparam integer B=4*DATA_WIDTH;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,valid=0,user=0,last=0;
    reg [B-1:0] word=0;
    wire out_valid,out_user,out_last,ref_valid,ref_user,ref_last;
    wire [B-1:0] centers;
    wire [36*DATA_WIDTH-1:0] windows;
    scharr_center_delay_4 #(.DATA_WIDTH(DATA_WIDTH),.IMG_WIDTH(WIDTH)) dut(
        .clk(clk),.rst_n(rst_n),.valid(valid),.user(user),.last(last),
        .word(word),.out_valid(out_valid),.out_user(out_user),
        .out_last(out_last),.centers(centers)
    );
    scharr_window_4_reference #(
        .DATA_WIDTH(DATA_WIDTH),.IMG_WIDTH(WIDTH),.IMG_HEIGHT(HEIGHT),
        .TRACK_POSITION(0)
    ) reference(
        .clk(clk),.rst_n(rst_n),.valid(valid),.user(user),.last(last),
        .word(word),.out_valid(ref_valid),.out_user(ref_user),
        .out_last(ref_last),.ok(),.windows(windows),.out_x(),.out_y()
    );
    reg [DATA_WIDTH-1:0] frame_pixels[0:WIDTH*HEIGHT-1];
    reg [B-1:0] expected_pixels[0:1];
    reg [3:0] expected_mask[0:1];
    reg [1:0] expected_valid=0,expected_user=0,expected_last=0;
    reg [31:0] noise=SEED;
    integer px=0,py=0,cycles=0,checked=0,bubbles=0,early_sof=0,resets=0;
    reg [3:0] lanes_checked=0;

    // Both true-dual-port writes must stay on distinct halves of the same
    // group. This also checks the one-group and non-power-of-two cases.
    always @(posedge clk) if(rst_n && valid)begin
        if(dut.upper_address[0] !== 1'b0 ||
           dut.lower_address[0] !== 1'b1 ||
           dut.upper_address == dut.lower_address ||
           dut.upper_address >= WIDTH/2 || dut.lower_address >= WIDTH/2)
            $fatal(1,"Centre RAM address collision/range size=%0dx%0d bits=%0d",
                WIDTH,HEIGHT,DATA_WIDTH);
    end

    function [31:0] random_next(input [31:0] value);
        begin random_next=value*32'd1664525+32'd1013904223;end
    endfunction

    task cycle(input reg v,u,l,input reg [B-1:0] data);
        integer lane,pixel_x;
        begin
            @(negedge clk);
            valid=v;user=u;last=l;word=data;
            expected_valid={expected_valid[0],v};
            expected_user={expected_user[0],u};
            expected_last={expected_last[0],l};
            expected_pixels[1]=expected_pixels[0];
            expected_mask[1]=expected_mask[0];
            expected_pixels[0]=0;expected_mask[0]=0;
            if(u)begin px=0;py=0;end
            if(v)begin
                for(lane=0;lane<4;lane=lane+1)begin
                    pixel_x=px+lane;
                    if(py>0 && pixel_x>0)begin
                        expected_pixels[0][B-1-lane*DATA_WIDTH -:DATA_WIDTH]=
                            frame_pixels[(py-1)*WIDTH+pixel_x-1];
                        expected_mask[0][3-lane]=1'b1;
                    end
                    frame_pixels[py*WIDTH+pixel_x]=
                        data[B-1-lane*DATA_WIDTH -:DATA_WIDTH];
                end
                if(px==WIDTH-4)begin px=0;py=(py+1)%HEIGHT;end
                else px=px+4;
            end
            @(posedge clk);#1;
            if({out_valid,out_user,out_last} !==
               {ref_valid,ref_user,ref_last} ||
               {out_valid,out_user,out_last} !==
               {expected_valid[1],expected_user[1],expected_last[1]})
                $fatal(1,"Centre control mismatch size=%0dx%0d bits=%0d cycle=%0d",
                    WIDTH,HEIGHT,DATA_WIDTH,cycles);
            for(lane=0;lane<4;lane=lane+1)begin
                if(expected_valid[1] && expected_mask[1][3-lane])begin
                    if(centers[B-1-lane*DATA_WIDTH -:DATA_WIDTH] !==
                       windows[32*DATA_WIDTH-1-lane*9*DATA_WIDTH -:DATA_WIDTH] ||
                       centers[B-1-lane*DATA_WIDTH -:DATA_WIDTH] !==
                       expected_pixels[1][B-1-lane*DATA_WIDTH -:DATA_WIDTH])
                        $fatal(1,
                            "Centre pixel mismatch size=%0dx%0d bits=%0d cycle=%0d lane=%0d actual=%h reference=%h oracle=%h",
                            WIDTH,HEIGHT,DATA_WIDTH,cycles,lane,
                            centers[B-1-lane*DATA_WIDTH -:DATA_WIDTH],
                            windows[32*DATA_WIDTH-1-lane*9*DATA_WIDTH -:DATA_WIDTH],
                            expected_pixels[1][B-1-lane*DATA_WIDTH -:DATA_WIDTH]);
                    checked=checked+1;lanes_checked[3-lane]=1'b1;
                end
            end
            cycles=cycles+1;
            if(!v)bubbles=bubbles+1;
            if(u&&!v)early_sof=early_sof+1;
        end
    endtask

    task idle(input integer count);
        integer n;
        begin
            for(n=0;n<count;n=n+1)begin
                noise=random_next(noise);
                cycle(0,0,noise[0],{B{1'b1}});
            end
        end
    endtask

    task reset_dut;
        begin
            @(negedge clk);rst_n=0;valid=0;user=0;last=0;
            expected_valid=0;expected_user=0;expected_last=0;
            expected_mask[0]=0;expected_mask[1]=0;
            expected_pixels[0]=0;expected_pixels[1]=0;px=0;py=0;
            repeat(3)@(posedge clk);
            @(negedge clk);rst_n=1;
            resets=resets+1;
        end
    endtask

    task fragment(input integer words,input reg early,use_bubbles);
        integer n,lane;
        reg [B-1:0] data;
        begin
            if(early)begin
                cycle(0,1,0,{B{1'b0}});idle(2);
            end
            for(n=0;n<words;n=n+1)begin
                if(use_bubbles && n%11==0)idle(1+n%3);
                for(lane=0;lane<4;lane=lane+1)begin
                    noise=random_next(noise);
                    data[B-1-lane*DATA_WIDTH -:DATA_WIDTH]=noise[DATA_WIDTH-1:0];
                end
                cycle(1,!early&&n==0,(n%(WIDTH/4))==WIDTH/4-1,data);
            end
        end
    endtask

    initial begin
        reset_dut();
        fragment(WIDTH*HEIGHT/4,0,0);
        fragment(WIDTH*HEIGHT/4,1,1);
        // Restart during a line, then again while the two-cycle output
        // still contains the abandoned frame. No RAM clearing is assumed.
        fragment(WIDTH/4+1,0,1);
        fragment(WIDTH*HEIGHT/4,1,0);
        fragment(WIDTH/4+1,0,0);
        reset_dut();
        fragment(WIDTH*HEIGHT/4,1,1);
        idle(5);
        if(checked==0 || early_sof<3 || bubbles<5 || resets!=2 ||
           lanes_checked !== (WIDTH==4 ? 4'b0111 : 4'b1111))
            $fatal(1,"Centre coverage missing size=%0dx%0d bits=%0d lanes=%b",
                WIDTH,HEIGHT,DATA_WIDTH,lanes_checked);
        $display(
            "SCHARR_CENTER_CASE_PASS size=%0dx%0d bits=%0d cycles=%0d checked=%0d bubbles=%0d early_sof=%0d resets=%0d lanes=%b",
            WIDTH,HEIGHT,DATA_WIDTH,cycles,checked,bubbles,early_sof,resets,
            lanes_checked);
        done=1;
    end
endmodule

module tb_scharr_center_delay_equivalence;
    wire [5:0] done;
    scharr_center_delay_equivalence_case #(
        .WIDTH(4),.HEIGHT(3),.DATA_WIDTH(1),.SEED(1)
    ) minimum(done[0]);
    scharr_center_delay_equivalence_case #(
        .WIDTH(8),.HEIGHT(7),.DATA_WIDTH(9),.SEED(3)
    ) two_groups(done[1]);
    scharr_center_delay_equivalence_case #(
        .WIDTH(20),.HEIGHT(17),.DATA_WIDTH(9),.SEED(17)
    ) non_power_two(done[2]);
    scharr_center_delay_equivalence_case #(
        .WIDTH(64),.HEIGHT(49),.DATA_WIDTH(15),.SEED(29)
    ) wide_pixel(done[3]);
    scharr_center_delay_equivalence_case #(
        .WIDTH(1280),.HEIGHT(720),.DATA_WIDTH(9),.SEED(131)
    ) full_hdmi(done[4]);
    scharr_center_delay_equivalence_case #(
        .WIDTH(1920),.HEIGHT(9),.DATA_WIDTH(9),.SEED(211)
    ) full_hd_width(done[5]);
    initial begin
        wait(&done);
        $display("SCHARR_CENTER_EQUIVALENCE_PASS cases=6 latency=2");
        $finish;
    end
    initial begin #1000000000;$fatal(1,"Centre simulation timeout");end
endmodule
