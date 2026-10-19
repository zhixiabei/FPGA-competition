`timescale 1ns/1ps
module tb_red_multi_target #(
    parameter integer W=256,
    parameter integer H=128
);
    localparam integer GROUPS=W/4;
    reg clk=0, rst_n=0, clear=0, user=0, valid=0;
    reg [95:0] data=0;
    reg [9:0] frame_id=0;
    wire ready, overflow;
    wire [3:0] found, hold;
    wire [191:0] boxes;
    wire [9:0] result_id;
    always #5 clk=~clk;

    red_target_detect_96 #(
        .IMG_WIDTH(W), .IMG_HEIGHT(H), .MIN_PIXELS(32),
        .MIN_WIDTH(4), .MIN_HEIGHT(4), .MULTI_ENABLE(1)
    ) dut (
        .I_clk(clk), .I_rst_n(rst_n), .I_tuser(user), .I_tvalid(valid), .I_tdata(data),
        .I_color_mode(2'd0),
        .I_frame_id(frame_id), .I_multi_clear(clear),
        .O_result_ready(), .O_found(), .O_xmin(), .O_xmax(), .O_ymin(), .O_ymax(),
        .O_center_x(), .O_center_y(), .O_pixels(), .O_frame_toggle(),
        .O_multi_ready(ready), .O_multi_valid(found), .O_multi_hold(hold),
        .O_multi_boxes(boxes), .O_multi_frame_id(result_id), .O_multi_overflow(overflow)
    );

    reg [23:0] image [0:W*H-1];
    reg seen [0:127];
    reg [3:0] seen_found [0:127], seen_hold [0:127];
    reg [191:0] seen_boxes [0:127];
    reg seen_overflow [0:127];
    integer result_count=0, checks=0, i, a_slot, b_slot, n;
    integer fifo_high_water=0;
    reg capacity_limit_seen=0;
    always @(posedge clk) begin
        #1;
        if (rst_n && dut.gen_multi.u_engine.fifo_count > fifo_high_water)
            fifo_high_water=dut.gen_multi.u_engine.fifo_count;
        if (rst_n && dut.gen_multi.u_engine.context_id == 65 &&
            dut.gen_multi.u_engine.context_bad && dut.gen_multi.u_engine.fifo_count < 62)
            capacity_limit_seen=1;
        if (rst_n && ready) begin
            if (result_id >= 128 || seen[result_id])
                $fatal(1,"Duplicate/unexpected result id=%0d",result_id);
            seen[result_id]=1;
            seen_found[result_id]=found; seen_hold[result_id]=hold;
            seen_boxes[result_id]=boxes; seen_overflow[result_id]=overflow;
            result_count=result_count+1;
        end
    end
    function integer pop4;
        input [3:0] bits;
        begin pop4=bits[0]+bits[1]+bits[2]+bits[3]; end
    endfunction
    function integer bxmin;
        input integer id, slot;
        begin bxmin=seen_boxes[id][slot*48+:12]; end
    endfunction
    function integer bxmax;
        input integer id, slot;
        begin bxmax=seen_boxes[id][slot*48+12+:12]; end
    endfunction
    function integer bymin;
        input integer id, slot;
        begin bymin=seen_boxes[id][slot*48+24+:12]; end
    endfunction
    function integer bymax;
        input integer id, slot;
        begin bymax=seen_boxes[id][slot*48+36+:12]; end
    endfunction
    task rectangle;
        input integer x0,x1,y0,y1;
        integer x,y;
        begin
            for(y=y0;y<=y1;y=y+1)
                for(x=x0;x<=x1;x=x+1) image[y*W+x]=24'hd00806;
        end
    endtask
    task pattern;
        input integer kind, offset;
        integer x,y;
        begin
            for(i=0;i<W*H;i=i+1) image[i]=24'h182020;
            case(kind)
                0: begin
                    rectangle(20+offset,43+offset,24,43);
                    rectangle(120-offset,143-offset,24,43);
                end
                1: begin
                    rectangle(16+offset,39+offset,16,35);
                    rectangle(96+offset,119+offset,16,35);
                    rectangle(16+offset,39+offset,80,99);
                    rectangle(176+offset,199+offset,80,99);
                end
                2: begin end
                3: begin
                    for(y=3;y<H-3;y=y+11)
                        for(x=3;x<W-3;x=x+11) image[y*W+x]=24'hff0000;
                end
                4: begin rectangle(0,23,0,23); rectangle(W-24,W-1,H-24,H-1); end
                5: begin
                    for(y=2;y<H-2;y=y+1)
                        for(x=0;x<W;x=x+1)
                            if ((x/8)%2 == 0) image[y*W+x]=24'hff0000;
                end
                6: begin
                    rectangle(16,39,16,35);
                    rectangle(16,39,70,89);
                end
                7: begin
                    for(x=0;x<18;x=x+1) rectangle(2+14*x,9+14*x,10,25);
                end
                8: begin
                    rectangle(10,17,10,17); rectangle(50,61,10,21);
                    rectangle(100,115,10,25); rectangle(10,29,70,89);
                    rectangle(60,83,70,93); rectangle(130,157,70,97);
                end
                9: begin
                    rectangle(16,39,10,H-11); rectangle(80,103,10,H-11);
                    rectangle(144,167,10,H-11); rectangle(208,231,10,H-11);
                end
                default: $fatal(1,"Unknown pattern");
            endcase
        end
    endtask
    task blank;
        input integer cycles;
        integer cycle;
        begin
            for(cycle=0;cycle<cycles;cycle=cycle+1) begin
                @(negedge clk); user=0; valid=0; data=0;
            end
        end
    endtask
    task clear_tracking;
        begin
            blank(5);
            @(negedge clk); clear=1;
            @(negedge clk); clear=0;
        end
    endtask
    // Real pixels drive the majority filter. IDs change after the early SOF
    // to check that a result uses the captured ID, including queued frames.
    task send_frame;
        input integer id, rows, line_blanking;
        integer y,g,l;
        begin
            @(negedge clk); user=1; valid=0; frame_id=id;
            @(negedge clk); user=0; valid=0; frame_id=10'd999;
            for(y=0;y<rows;y=y+1) begin
                for(g=0;g<GROUPS;g=g+1) begin
                    @(negedge clk); valid=1; user=0;
                    for(l=0;l<4;l=l+1) data[95-l*24-:24]=image[y*W+g*4+l];
                end
                if(y != rows-1) blank(line_blanking);
            end
            @(negedge clk); valid=0; data=0; user=0;
        end
    endtask
    task wait_result;
        input integer id;
        integer cycles;
        begin
            cycles=0;
            while(!seen[id] && cycles<20000) begin @(negedge clk); cycles=cycles+1; end
            if(!seen[id]) $fatal(1,"Timed out waiting for result %0d state=%0d count=%0d",
                id,dut.gen_multi.u_engine.state,dut.gen_multi.u_engine.fifo_count);
            checks=checks+1;
        end
    endtask
    task count_is;
        input integer id,count,held;
        begin
            wait_result(id);
            if(pop4(seen_found[id]) != count || pop4(seen_hold[id]) != held || seen_overflow[id])
                $fatal(1,"Result %0d count/held/error got=%b/%b/%b expected=%0d/%0d",
                    id,seen_found[id],seen_hold[id],seen_overflow[id],count,held);
        end
    endtask
    task find_box;
        input integer id,x0,x1,y0,y1;
        output integer located_slot;
        integer s;
        begin
            located_slot=-1;
            for(s=0;s<4;s=s+1)
                if(seen_found[id][s] && bxmin(id,s)==x0 && bxmax(id,s)==x1 &&
                   bymin(id,s)==y0 && bymax(id,s)==y1) located_slot=s;
            if(located_slot<0) begin
                $display("Expected box [%0d,%0d,%0d,%0d] in %0d",x0,x1,y0,y1,id);
                for(s=0;s<4;s=s+1) $display("slot %0d valid=%b [%0d,%0d,%0d,%0d]",
                    s,seen_found[id][s],bxmin(id,s),bxmax(id,s),bymin(id,s),bymax(id,s));
                $fatal(1,"Missing full-resolution box");
            end
            checks=checks+1;
        end
    endtask

    initial begin
        for(n=0;n<128;n=n+1) begin
            seen[n]=0; seen_found[n]=0; seen_hold[n]=0; seen_boxes[n]=0; seen_overflow[n]=0;
        end
        blank(4); @(negedge clk); rst_n=1;
        pattern(0,0);
        send_frame(1,H,96); count_is(1,0,0);
        send_frame(2,H,96); count_is(2,2,0);
        find_box(2,20,43,24,43,a_slot);
        find_box(2,120,143,24,43,b_slot);
        pattern(0,4);
        send_frame(3,H,96); count_is(3,2,0);
        find_box(3,24,47,24,43,n);
        if(n != a_slot) $fatal(1,"First object's ID moved");
        find_box(3,116,139,24,43,n);
        if(n != b_slot) $fatal(1,"Second object's ID moved");
        pattern(2,0);
        send_frame(4,H,96); count_is(4,2,2);
        send_frame(5,H,96); count_is(5,2,2);
        send_frame(6,H,96); count_is(6,0,0);

        clear_tracking();
        pattern(1,0);
        send_frame(10,H,96); count_is(10,0,0);
        send_frame(11,H,96); count_is(11,4,0);
        find_box(11,16,39,16,35,n); find_box(11,96,119,16,35,n);
        find_box(11,16,39,80,99,n); find_box(11,176,199,80,99,n);
        pattern(1,2);
        send_frame(12,H,96); count_is(12,4,0);
        for(n=0;n<4;n=n+1)
            if(bxmin(12,n) != bxmin(11,n)+2 || bymin(12,n) != bymin(11,n))
                $fatal(1,"Four-object tracking changed slot %0d",n);

        clear_tracking();
        pattern(3,0);
        send_frame(20,H,0); count_is(20,0,0);
        send_frame(21,H,0); count_is(21,0,0);
        pattern(4,0);
        send_frame(22,H,96); count_is(22,0,0);
        send_frame(23,H,96); count_is(23,2,0);
        find_box(23,1,23,1,23,n); find_box(23,W-24,W-2,H-24,H-2,n);

        clear_tracking();
        pattern(0,0);
        send_frame(30,H/2,96);
        send_frame(31,H,96); count_is(30,0,0); count_is(31,0,0);
        send_frame(32,H,96); count_is(32,2,0);

        // End-of-frame processing deliberately overlaps the next SOF.
        clear_tracking();
        pattern(6,0);
        send_frame(40,H,0);
        send_frame(41,H,0);
        count_is(40,0,0); count_is(41,2,0);
        find_box(41,16,39,16,35,n); find_box(41,16,39,70,89,n);

        // FIFO overload invalidates the full frame and clears prior tracks.
        pattern(5,0);
        send_frame(50,H,0); wait_result(50);
        if(!seen_overflow[50] || seen_found[50] != 0 || seen_hold[50] != 0)
            $fatal(1,"Overload published partial or stale detections");
        if(fifo_high_water < 62) $fatal(1,"FIFO overload case was not reached");
        pattern(0,0);
        send_frame(51,H,96); count_is(51,0,0);
        send_frame(52,H,96); count_is(52,2,0);

        // Reset/clear cancel queued work and force a fresh confirmation.
        pattern(1,0);
        send_frame(60,H,0);
        @(negedge clk); rst_n=0;
        blank(4); @(negedge clk); rst_n=1;
        blank(300);
        if(seen[60] || found != 0) $fatal(1,"Reset retained queued work");
        pattern(0,0);
        send_frame(61,H,96); count_is(61,0,0);
        send_frame(62,H,96); count_is(62,2,0);
        clear_tracking();
        if(found != 0 || hold != 0) $fatal(1,"Mode clear retained boxes");
        send_frame(63,H,96); count_is(63,0,0);
        send_frame(64,H,96); count_is(64,2,0);

        // The sixteen-live-candidate limit is distinct from FIFO pressure.
        clear_tracking();
        pattern(7,0);
        send_frame(65,H,1024); wait_result(65);
        if(!capacity_limit_seen || !seen_overflow[65] || seen_found[65] != 0)
            $fatal(1,"Candidate-capacity overflow was not rejected");
        pattern(1,0);
        send_frame(66,H,0);
        @(negedge clk); clear=1;
        @(negedge clk); clear=0;
        blank(300);
        if(seen[66] || found != 0) $fatal(1,"Mode clear retained queued work");

        // Completed regions retire, so more than four objects in one frame
        // are ranked by actual filtered-pixel support rather than scan order.
        pattern(8,0);
        send_frame(70,H,96); count_is(70,0,0);
        send_frame(71,H,96); count_is(71,4,0);
        find_box(71,100,115,10,25,n); find_box(71,10,29,70,89,n);
        find_box(71,60,83,70,93,n); find_box(71,130,157,70,97,n);

        // Four runs on every active row must sustain production beat rate.
        clear_tracking();
        pattern(9,0);
        send_frame(72,H,W >= 1280 ? 0 : 96); count_is(72,0,0);
        send_frame(73,H,W >= 1280 ? 0 : 96); count_is(73,4,0);
        find_box(73,16,39,10,H-11,n); find_box(73,80,103,10,H-11,n);
        find_box(73,144,167,10,H-11,n); find_box(73,208,231,10,H-11,n);

        $display("RED_MULTI_TARGET_PASS W=%0d H=%0d results=%0d checks=%0d fifo_high_water=%0d",
            W,H,result_count,checks,fifo_high_water);
        $finish;
    end
    initial begin #500000000; $fatal(1,"Simulation watchdog"); end
endmodule
