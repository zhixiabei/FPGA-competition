`timescale 1ns/1ps
// Independent RGB-level checks for the resource-limited single target path.
// Stimulus constructs geometry directly; no DUT state or descriptor is forced.
module tb_single_color_track_robust #(
    parameter integer W=320,
    parameter integer H=240
);
    localparam integer GROUPS=W/4;
    localparam [1:0] SH_UNKNOWN=0, SH_SQUARE=1;
    localparam [63:0] WATCHDOG_NS=64'd1000000+
        64'd400*H*(GROUPS+32)*10;
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
    integer seen_order[0:255];
    integer checks=0, results=0, next_id=1, n, k;
    integer reference_id, reference_xsum, reference_ysum, moving_id;
    integer cancelled_id, abort_id;
    integer burst_cancelled_id=-1, burst_partial_id=-1, burst_complete_id;
    reg [47:0] reference_box;

    always @(posedge clk) begin
        #1;
        if(rst_n) begin
            if(found[3:1]!==0 || held[3:1]!==0 ||
               shapes[7:2]!==0 || boxes[191:48]!==0)
                $fatal(1,"Robust single detector exposed another lane frame=%0d",result_id);
            if(ready) begin
                if(result_id>=256 || seen[result_id])
                    $fatal(1,"Duplicate/unexpected robust result id=%0d",result_id);
                if(held[0] && !found[0])
                    $fatal(1,"Held robust target is invalid frame=%0d",result_id);
                if(!found[0] && (shapes!==0 || boxes!==0))
                    $fatal(1,"Invalid robust target retained payload frame=%0d",result_id);
                if(overflow!==0 && (result_id!=burst_cancelled_id || overflow!==1))
                    $fatal(1,"Unexpected robust overflow frame=%0d overflow=%b",result_id,overflow);
                seen[result_id]=1;
                seen_found[result_id]=found;
                seen_held[result_id]=held;
                seen_shapes[result_id]=shapes;
                seen_box[result_id]=boxes[47:0];
                seen_overflow[result_id]=overflow;
                seen_order[result_id]=results;
                results=results+1;
            end
        end
    end

    function integer abs_i;
        input integer value;
        begin abs_i=value<0 ? -value : value; end
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
    task rectangle;
        input integer left,top,right,bottom;
        input [23:0] rgb;
        integer x,y;
        begin
            for(y=top;y<=bottom;y=y+1)
                for(x=left;x<=right;x=x+1)
                    if(x>0 && x<W-1 && y>0 && y<H-1)
                        image[y*W+x]=rgb;
        end
    endtask
    task target;
        input integer cx,cy;
        input [23:0] rgb;
        begin rectangle(cx-24,cy-24,cx+24,cy+24,rgb); end
    endtask
    task hollow_target;
        begin
            background(); target(88,88,24'hf02020);
            rectangle(78,78,98,98,24'hffffff);
        end
    endtask
    task u_target;
        begin
            background();
            rectangle(48,48,62,127,24'hf02020);
            rectangle(113,48,127,127,24'hf02020);
            rectangle(48,113,127,127,24'hf02020);
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
            if(found!==0 || held!==0 || shapes!==0 || boxes!==0)
                $fatal(1,"Clear retained robust target");
            checks=checks+1;
        end
    endtask
    task send_frame;
        input integer id,rows,line_blanking,bubble_period;
        integer y,g,l;
        begin
            // Live ID is deliberately wrong throughout active pixels.
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
    task expect_result;
        input integer id,has_target,has_hold;
        integer cycles;
        begin
            cycles=0;
            while(!seen[id] && cycles<30000) begin
                @(negedge clk); cycles=cycles+1;
            end
            if(!seen[id]) $fatal(1,"Robust result timeout frame=%0d",id);
            if(seen_found[id]!=={3'b0,has_target[0]} ||
               seen_held[id]!=={3'b0,has_hold[0]} || seen_overflow[id]!==0)
                $fatal(1,"Robust mismatch id=%0d valid/hold=%b/%b expected=%0d/%0d box=%0d,%0d,%0d,%0d shape=%0d",
                    id,seen_found[id],seen_held[id],has_target,has_hold,
                    bxmin(id),bxmax(id),bymin(id),bymax(id),seen_shapes[id][1:0]);
            checks=checks+1;
        end
    endtask
    task expect_aborted_result;
        input integer id,expected_overflow;
        integer cycles;
        begin
            cycles=0;
            while(!seen[id] && cycles<30000) begin
                @(negedge clk); cycles=cycles+1;
            end
            if(!seen[id]) $fatal(1,"Aborted robust result timeout frame=%0d",id);
            if(seen_found[id]!==0 || seen_held[id]!==0 ||
               seen_shapes[id]!==0 || seen_box[id]!==0 ||
               seen_overflow[id]!==expected_overflow[0])
                $fatal(1,"Aborted result mismatch frame=%0d valid/hold/shape/box/overflow=%b/%b/%b/%h/%b expected_overflow=%0d",
                    id,seen_found[id],seen_held[id],seen_shapes[id],seen_box[id],
                    seen_overflow[id],expected_overflow);
            checks=checks+1;
        end
    endtask
    task full_result;
        input integer has_target,has_hold;
        begin
            send_frame(next_id,H,4,0);
            expect_result(next_id,has_target,has_hold);
            next_id=next_id+1;
        end
    endtask
    task expect_square;
        input integer id;
        begin
            if(seen_shapes[id][1:0]!==SH_SQUARE)
                $fatal(1,"Expected independently drawn square frame=%0d shape=%0d",
                    id,seen_shapes[id][1:0]);
            checks=checks+1;
        end
    endtask
    task expect_local_box;
        input integer id,cx,cy,tolerance;
        begin
            if(abs_i(bxmin(id)-(cx-24))>tolerance ||
               abs_i(bxmax(id)-(cx+24))>tolerance ||
               abs_i(bymin(id)-(cy-24))>tolerance ||
               abs_i(bymax(id)-(cy+24))>tolerance)
                $fatal(1,"Target box escaped independent geometry frame=%0d got=%0d,%0d,%0d,%0d target_center=%0d,%0d tol=%0d",
                    id,bxmin(id),bxmax(id),bymin(id),bymax(id),cx,cy,tolerance);
            checks=checks+1;
        end
    endtask
    task lock_square;
        input integer cx,cy;
        input [23:0] rgb;
        begin
            clear_tracking(); background(); target(cx,cy,rgb);
            full_result(0,0); full_result(1,0);
            expect_square(next_id-1);
            expect_local_box(next_id-1,cx,cy,2);
        end
    endtask
    task threshold_case;
        input integer selected,expected_found;
        input [23:0] rgb;
        begin
            clear_tracking(); color_mode=selected;
            background(); target(88,88,rgb);
            full_result(0,0); full_result(expected_found,0);
            if(expected_found) begin
                expect_square(next_id-1);
                expect_local_box(next_id-1,88,88,2);
            end
        end
    endtask

    initial begin
        if(W<320 || H<240 || W%4!=0)
            $fatal(1,"Robust test requires W>=320 H>=240 W divisible by four");
        for(n=0;n<256;n=n+1) begin
            seen[n]=0; seen_found[n]=0; seen_held[n]=0;
            seen_shapes[n]=0; seen_box[n]=0; seen_overflow[n]=0; seen_order[n]=-1;
        end
        blank(8); @(negedge clk); rst_n=1; blank(8);

        threshold_case(0,1,24'hf02020);
        threshold_case(0,0,24'hf05a1e); // Orange-red RGB=(240,90,30).
        threshold_case(0,1,24'h781010); // Dim but saturated red.
        threshold_case(0,0,24'hf0c0c0); // Low-saturation highlight.
        threshold_case(1,1,24'h50961e);
        threshold_case(1,1,24'h209678);
        threshold_case(1,0,24'hb4c814);
        threshold_case(2,1,24'h2020f0);
        threshold_case(2,0,24'hf02020);
        $display("SINGLE_COLOR_TRACK_THRESHOLD_PASS orange_rejected=1 red_accepted=1 green_blue_preserved=1");

        color_mode=0;
        lock_square(88,88,24'hf02020);
        reference_box=seen_box[next_id-1];
        // A larger remote object appears on the same rows, then below the
        // selected target. Neither may contaminate the one contour's shape.
        background(); target(88,88,24'hf02020);
        rectangle(218,52,300,124,24'hf02020);
        full_result(1,0); expect_square(next_id-1);
        expect_local_box(next_id-1,88,88,2);
        background(); target(88,88,24'hf02020);
        rectangle(50,172,126,226,24'hf02020);
        full_result(1,0); expect_square(next_id-1);
        expect_local_box(next_id-1,88,88,2);
        if(seen_box[next_id-1]!==reference_box)
            $fatal(1,"Remote selected-color object changed stationary tracked box");
        checks=checks+1;
        clear_tracking(); background();
        rectangle(12,12,17,17,24'hf02020);
        target(88,88,24'hf02020);
        full_result(0,0); full_result(1,0);
        expect_square(next_id-1); expect_local_box(next_id-1,88,88,2);
        $display("SINGLE_COLOR_TRACK_ISOLATION_PASS remote_same_row=1 remote_lower_rows=1 shape_unpolluted=1");

        lock_square(88,88,24'hf02020);
        reference_id=next_id-1;
        reference_xsum=bxmin(reference_id)+bxmax(reference_id);
        reference_ysum=bymin(reference_id)+bymax(reference_id);
        for(k=0;k<8;k=k+1) begin
            background();
            case(k%4)
                0: target(89,89,24'hf02020);
                1: target(87,87,24'hf02020);
                2: target(90,90,24'hf02020);
                default: target(86,86,24'hf02020);
            endcase
            full_result(1,0);
            if(abs_i(bxmin(next_id-1)+bxmax(next_id-1)-reference_xsum)>2 ||
               abs_i(bymin(next_id-1)+bymax(next_id-1)-reference_ysum)>2)
                $fatal(1,"Static one/two-pixel mask jitter moved display center frame=%0d",
                    next_id-1);
            checks=checks+1;
        end
        for(k=1;k<=8;k=k+1) begin
            background(); target(88+k*4,88,24'hf02020); full_result(1,0);
            expect_square(next_id-1);
        end
        moving_id=next_id-1;
        if(bxmin(moving_id)+bxmax(moving_id)<reference_xsum+40 ||
           bxmin(moving_id)+bxmax(moving_id)>reference_xsum+64)
            $fatal(1,"Smoothed display froze or ran ahead of moving target frame=%0d",
                moving_id);
        checks=checks+1;
        background(); target(140,88,24'hf02020); full_result(1,0);
        if(bxmin(next_id-1)+bxmax(next_id-1)<bxmin(moving_id)+bxmax(moving_id)+24)
            $fatal(1,"Fast motion did not increase display update speed");
        checks=checks+1;
        $display("SINGLE_COLOR_TRACK_SMOOTH_PASS static_jitter_px=2 slow_motion_px=32 fast_motion_px=20 raw_association=1");

        lock_square(88,88,24'hf02020);
        reference_box=seen_box[next_id-1];
        background(); target(266,190,24'hf02020);
        full_result(1,1);
        if(seen_box[next_id-1]!==reference_box)
            $fatal(1,"Distant new target stole first held track");
        full_result(1,1);
        if(seen_box[next_id-1]!==reference_box)
            $fatal(1,"Distant new target stole second held track");
        full_result(0,0);
        // A released search window must return to full-frame acquisition.
        full_result(0,0); full_result(1,0);
        expect_local_box(next_id-1,266,190,2);
        expect_square(next_id-1);
        checks=checks+2;
        $display("SINGLE_COLOR_TRACK_REACQUIRE_PASS hold_frames=2 release_frame=3 full_frame_reacquire=1");

        lock_square(88,88,24'hf02020);
        reference_box=seen_box[next_id-1];
        background(); rectangle(12,12,184,164,24'hf02020);
        full_result(1,1);
        if(seen_box[next_id-1]!==reference_box)
            $fatal(1,"Oversize/edge-truncated object stole first held track");
        full_result(1,1);
        if(seen_box[next_id-1]!==reference_box)
            $fatal(1,"Oversize/edge-truncated object stole second held track");
        full_result(0,0);
        checks=checks+2;
        $display("SINGLE_COLOR_TRACK_SIZE_GATE_PASS oversize_rejected=1 no_window_edge_lock=1");

        // A large highlight leaves two connected foreground runs on each
        // central row. It remains a target, but is not a reliable shape.
        clear_tracking(); hollow_target();
        full_result(0,0); full_result(1,0);
        if(seen_shapes[next_id-1][1:0]!==SH_UNKNOWN)
            $fatal(1,"Startup split/hollow contour was forced to a known shape");
        expect_local_box(next_id-1,88,88,2);
        lock_square(88,88,24'hf02020); hollow_target();
        for(k=0;k<3;k=k+1) begin
            full_result(1,0);
            if(seen_shapes[next_id-1][1:0]!==(k<2 ? SH_SQUARE : SH_UNKNOWN))
                $fatal(1,"Split/hollow contour violated finite shape hold frame=%0d step=%0d shape=%0d",
                    next_id-1,k,seen_shapes[next_id-1][1:0]);
            checks=checks+1;
        end
        background(); target(88,88,24'hf02020);
        full_result(1,0);
        if(seen_shapes[next_id-1][1:0]!==SH_UNKNOWN)
            $fatal(1,"Known shape returned before two confirmations");
        full_result(1,0); expect_square(next_id-1);
        checks=checks+2;
        $display("SINGLE_COLOR_TRACK_HOLE_PASS startup_unknown=1 split_contour=1 shape_hold_frames=2 unknown_on_frame=3 shape_reconfirm=2");

        // Two separate upper legs merge into one lower bridge. A scanline
        // selector must not classify only one leg plus the bridge as triangle.
        clear_tracking(); u_target();
        full_result(0,0); full_result(1,0);
        if(seen_shapes[next_id-1][1:0]!==SH_UNKNOWN)
            $fatal(1,"Startup U contour was forced to a known shape");
        lock_square(88,88,24'hf02020); u_target();
        for(k=0;k<3;k=k+1) begin
            full_result(1,0);
            if(seen_shapes[next_id-1][1:0]!==(k<2 ? SH_SQUARE : SH_UNKNOWN))
                $fatal(1,"Merged-leg U contour violated finite shape hold frame=%0d step=%0d shape=%0d",
                    next_id-1,k,seen_shapes[next_id-1][1:0]);
            checks=checks+1;
        end
        checks=checks+1;
        $display("SINGLE_COLOR_TRACK_U_SHAPE_PASS pixels=80x80 leg=15 bridge=15 startup_unknown=1 merged_split_unknown=1 shape_hold_frames=2");

        // K1 view selection cannot feed back into selected-color tracking.
        lock_square(88,88,24'hf02020);
        reference_box=seen_box[next_id-1];
        for(k=0;k<13;k=k+1) begin
            mask_view_mode=k;
            send_frame(next_id,H,k%2 ? 4 : 0,k%2 ? 17 : 0);
            expect_result(next_id,1,0); expect_square(next_id);
            if(seen_box[next_id]!==reference_box)
                $fatal(1,"Mask preview affected tracked geometry view=%0d",k);
            next_id=next_id+1; checks=checks+1;
        end
        clear_tracking(); color_mode=1;
        background(); target(88,88,24'hf02020);
        full_result(0,0); full_result(0,0);
        background(); target(88,88,24'h50961e);
        full_result(0,0); full_result(1,0);
        expect_square(next_id-1);

        clear_tracking(); color_mode=0;
        background(); target(88,88,24'hf02020);
        abort_id=next_id; send_frame(abort_id,H/2,0,17); next_id=next_id+1;
        send_frame(next_id,H,0,17); expect_result(next_id,0,0); next_id=next_id+1;
        send_frame(next_id,H,0,17); expect_result(next_id,1,0); next_id=next_id+1;
        if(seen[abort_id] && seen_found[abort_id]!==0)
            $fatal(1,"Partial frame confirmed robust target");

        clear_tracking(); background(); target(88,88,24'hf02020);
        cancelled_id=next_id; send_frame(cancelled_id,H,0,0); next_id=next_id+1;
        @(negedge clk); clear=1; color_mode=2;
        @(negedge clk); clear=0; blank(1500);
        if(seen[cancelled_id] || found!==0 || held!==0 || shapes!==0 || boxes!==0)
            $fatal(1,"Clear allowed stale queued robust target");
        background(); target(88,88,24'h2020f0);
        full_result(0,0); full_result(1,0); expect_square(next_id-1);
        send_frame(next_id,H/2,0,0); next_id=next_id+1;
        @(negedge clk); rst_n=0; blank(6);
        if(found!==0 || held!==0 || shapes!==0 || boxes!==0)
            $fatal(1,"Reset retained robust single-target state");
        @(negedge clk); rst_n=1; blank(8);
        color_mode=0; background(); target(88,88,24'hf02020);
        full_result(0,0); full_result(1,0); expect_square(next_id-1);
        reference_box=seen_box[next_id-1];
        for(n=0;n<W;n=n+1) image[n]=24'hf02020;
        send_frame(next_id,H,0,0); expect_result(next_id,1,0);
        expect_square(next_id);
        if(seen_box[next_id]!==reference_box)
            $fatal(1,"Nonzero first input row leaked cross-frame geometry");
        next_id=next_id+1;
        background(); target(88,88,24'hf02020);
        send_frame(next_id,H,0,0); expect_result(next_id,1,0);
        expect_square(next_id);
        if(seen_box[next_id]!==reference_box)
            $fatal(1,"Previous nonzero first row contaminated following frame");
        next_id=next_id+1;
        checks=checks+3;
        $display("SINGLE_COLOR_TRACK_RESYNC_PASS frame_id_latched=1 preview_modes=13 color_clear=1 partial_abort=1 clear_cancel=1 reset=1 first_row_nonzero=1");

        // Complete A is still being classified while short B is aborted by
        // C's SOF. A diagnostic invalid and B's invalid must keep their IDs
        // and order even when both are pending together.
        clear_tracking(); background(); target(88,88,24'hf02020);
        burst_cancelled_id=next_id;
        send_frame(next_id,H,0,0); next_id=next_id+1;
        burst_partial_id=next_id;
        send_frame(next_id,1,0,0); next_id=next_id+1;
        burst_complete_id=next_id;
        send_frame(next_id,H,0,0); next_id=next_id+1;
        expect_aborted_result(burst_cancelled_id,1);
        expect_aborted_result(burst_partial_id,0);
        if(seen_order[burst_cancelled_id]>=seen_order[burst_partial_id])
            $fatal(1,"Simultaneous cancelled/partial results lost order A=%0d B=%0d",
                seen_order[burst_cancelled_id],seen_order[burst_partial_id]);
        expect_result(burst_complete_id,0,0);
        send_frame(next_id,H,0,0); expect_result(next_id,1,0);
        expect_square(next_id); next_id=next_id+1;
        checks=checks+1;
        $display("SINGLE_COLOR_TRACK_ABORT_BURST_PASS classifier_cancel=1 partial_abort=1 unique_ids=1 ordered_invalids=1 no_stale_confirm=1");

        $display("SINGLE_COLOR_TRACK_ROBUST_PASS W=%0d H=%0d results=%0d checks=%0d last_frame=%0d lanes=1",
            W,H,results,checks,next_id-1);
        $finish;
    end
    initial begin #(WATCHDOG_NS); $fatal(1,"Robust single color tracker watchdog"); end
endmodule
