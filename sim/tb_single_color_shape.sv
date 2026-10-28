`timescale 1ns/1ps
// Real RGB -> cleanup -> single contour -> descriptor -> stable slot-zero result.
// No internal signal or classification result is forced by this test.
module tb_single_color_shape #(
    parameter integer W=320,
    parameter integer H=240
);
    localparam integer GROUPS=W/4;
    localparam [1:0] SH_UNKNOWN=0, SH_SQUARE=1, SH_TRIANGLE=2, SH_CIRCLE=3;
    localparam [63:0] WATCHDOG_NS=64'd1000000+
        64'd500*H*(GROUPS+96)*10;
    reg clk=0, rst_n=0, clear=0, user=0, valid=0;
    reg [1:0] color_mode=0;
    reg [3:0] mask_view_mode=0;
    reg [95:0] data=0;
    reg [9:0] frame_id=0;
    wire ready, overflow;
    wire [3:0] found, held;
    wire [7:0] shapes;
    wire [191:0] boxes;
    wire [9:0] result_id;
    always #5 clk=~clk;

    red_target_detect_96 #(
        .IMG_WIDTH(W), .IMG_HEIGHT(H), .MIN_PIXELS(64),
        .MIN_WIDTH(8), .MIN_HEIGHT(8), .MULTI_ENABLE(0),
        .SINGLE_SHAPE_ENABLE(1)
    ) dut (
        .I_clk(clk), .I_rst_n(rst_n), .I_tuser(user), .I_tvalid(valid),
        .I_tdata(data), .I_color_mode(color_mode),
        .I_mask_view_mode(mask_view_mode), .O_mask_pixels(),
        .I_frame_id(frame_id), .I_multi_clear(clear),
        .O_result_ready(), .O_found(), .O_xmin(), .O_xmax(), .O_ymin(), .O_ymax(),
        .O_center_x(), .O_center_y(), .O_pixels(), .O_frame_toggle(),
        .O_multi_ready(ready), .O_multi_valid(found), .O_multi_hold(held),
        .O_multi_boxes(boxes), .O_multi_shapes(shapes),
        .O_multi_frame_id(result_id), .O_multi_overflow(overflow)
    );

    reg [23:0] image[0:W*H-1];
    reg seen[0:255];
    reg [3:0] seen_found[0:255], seen_held[0:255];
    reg [7:0] seen_shapes[0:255];
    reg [47:0] seen_box[0:255];
    reg seen_overflow[0:255];
    reg [23:0] foreground=24'hf02020;
    integer checks=0, results=0, cases=0, next_id=1, n;
    integer abort_id, cancelled_id, confirmed_id, miss_id;
    reg [47:0] confirmed_box;

    always @(posedge clk) begin
        #1;
        if(rst_n) begin
            // The external four-lane transport remains ABI-compatible, but
            // a single detector must never expose another target lane.
            if(found[3:1]!==0 || held[3:1]!==0 ||
               shapes[7:2]!==0 || boxes[191:48]!==0)
                $fatal(1,"Unused single-target lanes are not zero frame=%0d",result_id);
            if(overflow!==0)
                $fatal(1,"Single contour reported candidate overflow frame=%0d",result_id);
            if(ready) begin
                if(result_id>=256 || seen[result_id])
                    $fatal(1,"Duplicate/unexpected single result id=%0d",result_id);
                if(held[0] && !found[0])
                    $fatal(1,"Held result is invalid frame=%0d",result_id);
                if(!found[0] && shapes[1:0]!==SH_UNKNOWN)
                    $fatal(1,"Invalid single result retained shape frame=%0d",result_id);
                seen[result_id]=1;
                seen_found[result_id]=found;
                seen_held[result_id]=held;
                seen_shapes[result_id]=shapes;
                seen_box[result_id]=boxes[47:0];
                seen_overflow[result_id]=overflow;
                results=results+1;
            end
        end
    end

    function integer abs_i;
        input integer value;
        begin abs_i=value<0 ? -value : value; end
    endfunction
    function integer in_triangle;
        input integer x,y,ax,ay,bx,by,cx,cy;
        integer ab,bc,ca;
        begin
            ab=(x-ax)*(by-ay)-(y-ay)*(bx-ax);
            bc=(x-bx)*(cy-by)-(y-by)*(cx-bx);
            ca=(x-cx)*(ay-cy)-(y-cy)*(ax-cx);
            in_triangle=(ab>=0 && bc>=0 && ca>=0) ||
                        (ab<=0 && bc<=0 && ca<=0);
        end
    endfunction
    function integer bxmin;
        input integer id;
        begin bxmin=seen_box[id][11:0]; end
    endfunction
    function integer bxmax;
        input integer id;
        begin bxmax=seen_box[id][23:12]; end
    endfunction
    function integer bymin;
        input integer id;
        begin bymin=seen_box[id][35:24]; end
    endfunction
    function integer bymax;
        input integer id;
        begin bymax=seen_box[id][47:36]; end
    endfunction
    task background;
        integer i;
        begin
            for(i=0;i<W*H;i=i+1) image[i]=24'h101010;
        end
    endtask
    task square;
        input integer cx,cy,half_side,cosine,sine;
        integer x,y,dx,dy,u,v;
        begin
            for(y=1;y<H-1;y=y+1)
                for(x=1;x<W-1;x=x+1) begin
                    dx=x-cx; dy=y-cy;
                    u=dx*cosine+dy*sine;
                    v=-dx*sine+dy*cosine;
                    if(abs_i(u)<=half_side*1024 && abs_i(v)<=half_side*1024)
                        image[y*W+x]=foreground;
                end
        end
    endtask
    task disk;
        input integer cx,cy,radius;
        integer x,y;
        begin
            for(y=1;y<H-1;y=y+1)
                for(x=1;x<W-1;x=x+1)
                    if((x-cx)*(x-cx)+(y-cy)*(y-cy)<=radius*radius)
                        image[y*W+x]=foreground;
        end
    endtask
    task triangle;
        input integer ax,ay,bx,by,cx,cy;
        integer x,y;
        begin
            for(y=1;y<H-1;y=y+1)
                for(x=1;x<W-1;x=x+1)
                    if(in_triangle(x,y,ax,ay,bx,by,cx,cy))
                        image[y*W+x]=foreground;
        end
    endtask
    task pattern;
        input integer kind;
        integer x,y,dx,dy,ax,ay,bx,by,cx,cy;
        begin
            background();
            case(kind)
                0: square(96,96,32,1024,0);
                1: square(96,96,32,962,350);
                2: square(96,96,32,724,724);
                3: disk(96,96,32);
                4: triangle(61,129,131,129,78,59);
                5: begin
                    ax=96+((-35*921)-(33*449))/1024;
                    ay=96+((-35*449)+(33*921))/1024;
                    bx=96+((35*921)-(33*449))/1024;
                    by=96+((35*449)+(33*921))/1024;
                    cx=96+((-18*921)-(-37*449))/1024;
                    cy=96+((-18*449)+(-37*921))/1024;
                    triangle(ax,ay,bx,by,cx,cy);
                end
                6: begin
                    for(y=80;y<=111;y=y+1)
                        for(x=40;x<=151;x=x+1) image[y*W+x]=foreground;
                end
                7: begin
                    for(y=1;y<H-1;y=y+1)
                        for(x=1;x<W-1;x=x+1) begin
                            dx=x-96; dy=y-96;
                            if(dx*dx*20*20+dy*dy*56*56<=56*56*20*20)
                                image[y*W+x]=foreground;
                        end
                end
                8: begin
                    disk(96,96,34);
                    for(y=1;y<H-1;y=y+1)
                        for(x=1;x<W-1;x=x+1)
                            if((x-96)*(x-96)+(y-96)*(y-96)<18*18)
                                image[y*W+x]=24'h101010;
                end
                9: begin
                    for(y=60;y<=132;y=y+1)
                        for(x=60;x<=132;x=x+1)
                            if(abs_i(x-96)<=10 || abs_i(y-96)<=10)
                                image[y*W+x]=foreground;
                end
                10: begin
                    // Deliberately disconnected same-color components.
                    // The new mode combines their geometry into ONE contour,
                    // not a largest-component detector or two result lanes.
                    square(61,96,21,1024,0);
                    square(135,96,21,1024,0);
                end
                11: begin end
                12: begin
                    square(96,96,32,1024,0);
                    image[96*W+96]=24'hffffff;
                    image[95*W+96]=24'hffffff;
                    image[97*W+96]=24'hffffff;
                    image[96*W+95]=24'hffffff;
                    image[96*W+97]=24'hffffff;
                end
                13: begin
                    // Isolated thresholded pixels must be removed before
                    // the contour accumulator, without expanding its box.
                    square(96,96,32,1024,0);
                    image[20*W+20]=foreground;
                    image[40*W+180]=foreground;
                    image[180*W+50]=foreground;
                end
                14: begin
                    image[20*W+20]=foreground;
                    image[40*W+180]=foreground;
                    image[180*W+50]=foreground;
                end
                15: begin
                    square(96,50,21,1024,0);
                    square(96,130,21,1024,0);
                end
                16: square(W-34,H-34,32,1024,0);
                17: disk(1000,520,32);
                18: square(1160,520,32,962,350);
                19: triangle(968,670,1040,670,984,594);
                default: $fatal(1,"Unknown single shape pattern %0d",kind);
            endcase
        end
    endtask
    task blank;
        input integer cycles;
        integer c;
        begin
            for(c=0;c<cycles;c=c+1) begin
                @(negedge clk); user=0; valid=0; data=0;
            end
        end
    endtask
    task clear_tracking;
        begin
            blank(5);
            @(negedge clk); clear=1;
            @(negedge clk); clear=0;
            blank(2);
            if(found!==0 || held!==0 || shapes!==0)
                $fatal(1,"Clear retained confirmed shape/hold");
            checks=checks+1;
        end
    endtask
    task send_frame;
        input integer id,rows,line_blanking,bubble_period;
        integer y,g,l;
        begin
            // The ID exists only at the early SOF. A detector which samples
            // live I_frame_id at EOF must fail with the sentinel 999.
            @(negedge clk); user=1; valid=0; frame_id=id;
            @(negedge clk); user=0; valid=0; frame_id=10'd999;
            for(y=0;y<rows;y=y+1) begin
                for(g=0;g<GROUPS;g=g+1) begin
                    if(bubble_period>0 && (y*GROUPS+g)%bubble_period==0)
                        blank(1);
                    @(negedge clk); valid=1; user=0;
                    for(l=0;l<4;l=l+1)
                        data[95-l*24-:24]=image[y*W+4*g+l];
                end
                if(y!=rows-1) blank(line_blanking);
            end
            @(negedge clk); valid=0; user=0; data=0;
        end
    endtask
    task wait_result;
        input integer id;
        integer cycles;
        begin
            cycles=0;
            while(!seen[id] && cycles<30000) begin
                @(negedge clk); cycles=cycles+1;
            end
            if(!seen[id]) $fatal(1,"Single result timeout frame=%0d",id);
            checks=checks+1;
        end
    endtask
    task expect_result;
        input integer id,has_target,has_hold;
        input [1:0] shape;
        begin
            wait_result(id);
            if(seen_found[id]!=={3'b0,has_target[0]} ||
               seen_held[id]!=={3'b0,has_hold[0]} ||
               seen_shapes[id]!=={6'b0,shape} || seen_overflow[id])
                $fatal(1,"Single mismatch id=%0d valid/hold/shape=%b/%b/%0d expected=%0d/%0d/%0d box=%0d,%0d,%0d,%0d",
                    id,seen_found[id],seen_held[id],seen_shapes[id][1:0],
                    has_target,has_hold,shape,bxmin(id),bxmax(id),bymin(id),bymax(id));
            checks=checks+1;
        end
    endtask
    task pair_case;
        input integer kind,color;
        input [23:0] rgb;
        input [1:0] shape;
        input integer line_blanking,bubble_period;
        begin
            clear_tracking();
            color_mode=color; foreground=rgb; mask_view_mode=cases%13;
            pattern(kind);
            send_frame(next_id,H,line_blanking,bubble_period);
            expect_result(next_id,0,0,SH_UNKNOWN);
            send_frame(next_id+1,H,line_blanking,bubble_period);
            expect_result(next_id+1,1,0,shape);
            $display("SINGLE_COLOR_SHAPE_CASE_PASS case=%0d pattern=%0d color=%0d frame=%0d shape=%0d box=%0d,%0d,%0d,%0d",
                cases,kind,color,next_id+1,shape,bxmin(next_id+1),bxmax(next_id+1),
                bymin(next_id+1),bymax(next_id+1));
            next_id=next_id+2; cases=cases+1;
        end
    endtask

    initial begin
        if(W<288 || H<224 || W%4!=0)
            $fatal(1,"Single shape patterns require W>=288 H>=224 W divisible by four");
        for(n=0;n<256;n=n+1) begin
            seen[n]=0; seen_found[n]=0; seen_held[n]=0;
            seen_shapes[n]=0; seen_box[n]=0; seen_overflow[n]=0;
        end
        blank(8); @(negedge clk); rst_n=1; blank(8);

        // Geometry and rotations are reused from independent coordinate
        // construction, rather than calculated from descriptor thresholds.
        pair_case(0,0,24'hf02020,SH_SQUARE,96,0);
        pair_case(1,0,24'hf02020,SH_SQUARE,96,0);
        pair_case(2,0,24'hf02020,SH_SQUARE,96,0);
        pair_case(3,0,24'hf02020,SH_CIRCLE,96,0);
        pair_case(4,0,24'hf02020,SH_TRIANGLE,96,0);
        pair_case(5,0,24'hf02020,SH_TRIANGLE,96,0);
        pair_case(6,0,24'hf02020,SH_UNKNOWN,96,0);
        pair_case(7,0,24'hf02020,SH_UNKNOWN,96,0);
        pair_case(8,0,24'hf02020,SH_UNKNOWN,96,0);
        pair_case(9,0,24'hf02020,SH_UNKNOWN,96,0);
        pair_case(0,1,24'h50961e,SH_SQUARE,96,0);
        pair_case(3,1,24'h209678,SH_CIRCLE,96,0);
        pair_case(4,1,24'h50961e,SH_TRIANGLE,96,0);
        pair_case(0,2,24'h2020f0,SH_SQUARE,96,0);
        pair_case(3,2,24'h2020f0,SH_CIRCLE,96,0);
        pair_case(4,2,24'h2020f0,SH_TRIANGLE,96,0);
        pair_case(12,0,24'hf02020,SH_SQUARE,96,0);
        pair_case(13,0,24'hf02020,SH_SQUARE,0,17);
        if(bxmin(next_id-1)<60 || bxmax(next_id-1)>132 ||
           bymin(next_id-1)<60 || bymax(next_id-1)>132)
            $fatal(1,"Removed isolated noise expanded single-target box");
        pair_case(16,0,24'hf02020,SH_UNKNOWN,96,0);
        if(bxmax(next_id-1)!=W-4 || bymax(next_id-1)!=H-4)
            $fatal(1,"Final interior row/column lost in single collector");
        pair_case(10,0,24'hf02020,SH_UNKNOWN,96,0);
        if(bxmin(next_id-1)>44 || bxmax(next_id-1)<152)
            $fatal(1,"Single contour failed to include BOTH same-row objects");
        pair_case(15,0,24'hf02020,SH_UNKNOWN,96,0);
        if(bymin(next_id-1)>33 || bymax(next_id-1)<147)
            $fatal(1,"Single contour failed to include BOTH separated objects");
        $display("SINGLE_COLOR_SHAPE_MULTIOBJECT_PASS lanes=1 union_box=1 shape=UNKNOWN");
        if(W>=1280 && H>=720) begin
            // A passing low-coordinate shape cannot expose truncated first
            // moments or diagonal projections at production coordinates.
            pair_case(17,0,24'hf02020,SH_CIRCLE,0,0);
            if(abs_i(bxmin(next_id-1)+bxmax(next_id-1)-2000)>2 ||
               abs_i(bymin(next_id-1)+bymax(next_id-1)-1040)>2)
                $fatal(1,"Translated circle box was truncated");
            pair_case(18,1,24'h50961e,SH_SQUARE,0,0);
            if(abs_i(bxmin(next_id-1)+bxmax(next_id-1)-2320)>2 ||
               abs_i(bymin(next_id-1)+bymax(next_id-1)-1040)>2)
                $fatal(1,"Translated rotated-square box was truncated");
            pair_case(19,2,24'h2020f0,SH_TRIANGLE,0,0);
            if(bxmin(next_id-1)<965 || bxmax(next_id-1)>1043 ||
               bymin(next_id-1)<591 || bymax(next_id-1)>673)
                $fatal(1,"Translated triangle box was truncated");
            $display("SINGLE_COLOR_SHAPE_PRODUCTION_COORDS_PASS W=%0d H=%0d coordinates_over_1024=1 continuous_rows=1",
                W,H);
        end

        // Current one-track temporal contract: two confirmations, two missed
        // frames held, then invalidate; a label change also needs two frames.
        pair_case(0,0,24'hf02020,SH_SQUARE,96,0);
        pattern(3);
        send_frame(next_id,H,96,0); expect_result(next_id,1,0,SH_SQUARE);
        next_id=next_id+1;
        send_frame(next_id,H,96,0); expect_result(next_id,1,0,SH_CIRCLE);
        confirmed_id=next_id; confirmed_box=seen_box[next_id]; next_id=next_id+1;
        pattern(11);
        for(miss_id=0;miss_id<2;miss_id=miss_id+1) begin
            send_frame(next_id,H,96,0); expect_result(next_id,1,1,SH_CIRCLE);
            if(seen_box[next_id]!==confirmed_box)
                $fatal(1,"Missing-frame hold changed confirmed box");
            next_id=next_id+1;
        end
        send_frame(next_id,H,96,0); expect_result(next_id,0,0,SH_UNKNOWN);
        next_id=next_id+1;
        $display("SINGLE_COLOR_SHAPE_TEMPORAL_PASS confirm=2 shape_confirm=2 miss_hold=2");

        // Low support and wrong selected hue do not confirm a target.
        clear_tracking(); pattern(14);
        send_frame(next_id,H,96,0); expect_result(next_id,0,0,SH_UNKNOWN);
        next_id=next_id+1;
        send_frame(next_id,H,96,0); expect_result(next_id,0,0,SH_UNKNOWN);
        next_id=next_id+1;
        clear_tracking(); color_mode=1; foreground=24'h209690; pattern(0);
        send_frame(next_id,H,96,0); expect_result(next_id,0,0,SH_UNKNOWN);
        next_id=next_id+1;
        send_frame(next_id,H,96,0); expect_result(next_id,0,0,SH_UNKNOWN);
        next_id=next_id+1;

        // A new SOF abandons an incomplete frame. Its optional invalid
        // completion cannot help confirm the following complete frame.
        clear_tracking(); color_mode=0; foreground=24'hf02020; pattern(3);
        abort_id=next_id; send_frame(abort_id,H/2,0,17); next_id=next_id+1;
        send_frame(next_id,H,0,17); expect_result(next_id,0,0,SH_UNKNOWN);
        next_id=next_id+1;
        send_frame(next_id,H,0,17); expect_result(next_id,1,0,SH_CIRCLE);
        next_id=next_id+1;
        if(seen[abort_id] && (seen_found[abort_id]!==0 ||
           seen_held[abort_id]!==0 || seen_shapes[abort_id]!==0))
            $fatal(1,"Aborted partial frame published a valid shape");

        // Clear during queued EOF work must cancel the stale transaction,
        // not merely blank the currently displayed label.
        clear_tracking(); pattern(0);
        cancelled_id=next_id; send_frame(cancelled_id,H,0,0); next_id=next_id+1;
        @(negedge clk); clear=1; color_mode=2;
        @(negedge clk); clear=0; blank(1500);
        if(seen[cancelled_id] || found!==0 || held!==0 || shapes!==0)
            $fatal(1,"Clear published stale queued single-shape result");
        foreground=24'h2020f0; pattern(4);
        send_frame(next_id,H,96,0); expect_result(next_id,0,0,SH_UNKNOWN);
        next_id=next_id+1;
        send_frame(next_id,H,96,0); expect_result(next_id,1,0,SH_TRIANGLE);
        next_id=next_id+1;

        // Reset clears a previously confirmed label and partial image state.
        send_frame(next_id,H/2,0,0); next_id=next_id+1;
        @(negedge clk); rst_n=0; blank(6);
        if(found!==0 || held!==0 || shapes!==0)
            $fatal(1,"Reset retained single-target state");
        @(negedge clk); rst_n=1; blank(8);
        color_mode=0; foreground=24'hf02020; pattern(2);
        send_frame(next_id,H,0,0); expect_result(next_id,0,0,SH_UNKNOWN);
        next_id=next_id+1;
        send_frame(next_id,H,0,0); expect_result(next_id,1,0,SH_SQUARE);
        next_id=next_id+1;
        $display("SINGLE_COLOR_SHAPE_RESYNC_PASS partial_abort=1 clear_cancel=1 reset=1 bubbles=1 continuous_rows=1");
        $display("SINGLE_COLOR_SHAPE_PASS W=%0d H=%0d results=%0d checks=%0d cases=%0d last_frame=%0d colors=RED,GRN,BLU shapes=SQR,TRI,CIR,UNK lanes=1",
            W,H,results,checks,cases,next_id-1);
        $finish;
    end
    initial begin #(WATCHDOG_NS); $fatal(1,"Single color/shape watchdog"); end
endmodule
