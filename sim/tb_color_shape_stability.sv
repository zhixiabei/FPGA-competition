`timescale 1ns/1ps
module tb_color_shape_stability;
    localparam integer W=256,H=160,GROUPS=W/4;
    reg clk=0,rst_n=0,user=0,valid=0,last=0;
    reg [95:0] data=0;
    reg [9:0] frame_id=0;
    reg [1:0] requested_mode=0;
    reg [7:0] raw_shapes=0;
    wire ready,overflow,result_motion,active_motion;
    wire [1:0] result_color,active_color;
    wire [9:0] result_id;
    wire [3:0] found,held;
    wire [7:0] shapes;
    wire [191:0] boxes;
    always #5 clk=~clk;

    target_detect_switch_96 #(
        .IMG_WIDTH(W),.IMG_HEIGHT(H),.RED_MIN_PIXELS(128),
        .MOTION_STABLE_ENABLE(0),.RED_MULTI_ENABLE(1)
    ) dut (
        .I_clk(clk),.I_rst_n(rst_n),.I_motion_mode_async(requested_mode==3),
        .I_color_mode_async(requested_mode),.I_effect_config(12'd0),
        .I_tuser(user),.I_tlast(last),.I_tvalid(valid),.I_tdata(data),
        .I_frame_id(frame_id),.O_result_ready(ready),.O_found(),
        .O_xmin(),.O_xmax(),.O_ymin(),.O_ymax(),.O_center_x(),.O_center_y(),
        .O_pixels(),.O_frame_toggle(),.O_target_motion_mode(result_motion),
        .O_target_color_mode(result_color),.O_motion_mode_active(active_motion),
        .O_color_mode_active(active_color),.O_result_frame_id(result_id),
        .O_multi_valid(found),.O_multi_hold(held),.O_multi_boxes(boxes),
        .O_multi_shapes(shapes),.O_mask_pixels(),.O_multi_overflow(overflow)
    );

    // Use real RGB masks, geometry, candidate ranking, frame IDs and tracking.
    // Replace only the shared descriptor's final class to create repeatable
    // flicker. The spatial regression separately tests the real descriptor.
    wire [1:0] injected_object={
        dut.u_red.gen_multi.u_engine.top_ymin[dut.u_red.gen_multi.u_engine.class_index]>=H/2,
        dut.u_red.gen_multi.u_engine.top_xmin[dut.u_red.gen_multi.u_engine.class_index]>=W/2};
    wire [1:0] injected_shape=raw_shapes[injected_object*2+:2];
    initial force dut.u_red.gen_multi.u_engine.shape_result=injected_shape;

    reg [23:0] image [0:W*H-1];
    reg seen [0:1023];
    reg [3:0] seen_found [0:1023],seen_held [0:1023];
    reg [7:0] seen_shapes [0:1023];
    reg [191:0] seen_boxes [0:1023];
    reg seen_error [0:1023],seen_motion [0:1023];
    reg [1:0] seen_color [0:1023];
    integer next_id=700,results=0,checks=0,steps=0;
    integer n,s,obj,x0,y0,queued_id,abort_id,capacity_id=-1;
    integer previous_slots [0:3];
    reg [3:0] previous_valid=0;
    reg saw_capacity_error=0;
    integer mode_switches=0,explicit_clears=0,aborts=0,illegal_states=0,overflows=0;
    reg [7:0] idle_shapes;
    reg [3:0] idle_found,idle_held;
    integer idle_results;

    always @(posedge clk) begin
        #1;
        if(rst_n && capacity_id>=0 &&
           dut.u_red.gen_multi.u_engine.context_id==capacity_id &&
           dut.u_red.gen_multi.u_engine.context_bad &&
           dut.u_red.gen_multi.u_engine.fifo_count<62)
            saw_capacity_error=1;
        if(rst_n && ready) begin
            if(seen[result_id])
                $fatal(1,"Duplicate temporal result frame=%0d",result_id);
            seen[result_id]=1;
            seen_found[result_id]=found; seen_held[result_id]=held;
            seen_shapes[result_id]=shapes; seen_boxes[result_id]=boxes;
            seen_error[result_id]=overflow; seen_motion[result_id]=result_motion;
            seen_color[result_id]=result_color;
            results=results+1;
        end
    end

    task blank;
        input integer cycles;
        integer c;
        begin
            for(c=0;c<cycles;c=c+1) begin
                @(negedge clk); user=0; valid=0; last=0; data=0;
            end
        end
    endtask
    task rectangle;
        input integer left,right,top,bottom;
        input [23:0] rgb;
        integer x,y;
        begin
            for(y=top;y<=bottom;y=y+1)
                for(x=left;x<=right;x=x+1) image[y*W+x]=rgb;
        end
    endtask
    task draw;
        input [3:0] present;
        integer i,j,left,top;
        reg [23:0] rgb;
        begin
            for(j=0;j<W*H;j=j+1) image[j]=24'h101010;
            case(requested_mode)
                1: rgb=24'h50961e;
                2: rgb=24'h2020f0;
                default: rgb=24'hf02020;
            endcase
            for(i=0;i<4;i=i+1)
                if(present[i]) begin
                    left=i%2==0 ? 16 : 160;
                    top=i<2 ? 16 : 104;
                    rectangle(left,left+31,top,top+31,rgb);
                end
        end
    endtask
    task send_frame;
        input integer id,rows,line_blanking;
        integer y,g,l;
        begin
            @(negedge clk); user=1; valid=0; last=0; frame_id=id;
            @(negedge clk); user=0; valid=0; frame_id=10'd19;
            for(y=0;y<rows;y=y+1) begin
                for(g=0;g<GROUPS;g=g+1) begin
                    @(negedge clk); valid=1; user=0; last=g==GROUPS-1;
                    for(l=0;l<4;l=l+1)
                        data[95-l*24-:24]=image[y*W+g*4+l];
                end
                if(y!=rows-1) blank(line_blanking);
            end
            @(negedge clk); valid=0; user=0; last=0; data=0;
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
            if(!seen[id])
                $fatal(1,"Temporal result timeout frame=%0d state=%0d fifo=%0d",
                    id,dut.u_red.gen_multi.u_engine.state,
                    dut.u_red.gen_multi.u_engine.fifo_count);
        end
    endtask
    task check_result;
        input integer id;
        input [3:0] expected_valid,expected_held;
        input [7:0] expected_shapes;
        input integer expected_error;
        input [1:0] expected_mode;
        input [255:0] description;
        integer i,logical_object,left,top;
        integer object_slots [0:3];
        reg [3:0] actual_valid,actual_held;
        reg [7:0] actual_shapes;
        begin
            wait_result(id);
            actual_valid=0; actual_held=0; actual_shapes=0;
            for(i=0;i<4;i=i+1) object_slots[i]=-1;
            if(seen_error[id]!==expected_error[0] ||
               seen_motion[id]!==(expected_mode==3) ||
               seen_color[id]!==(expected_mode==3 ? 2'd0 : expected_mode))
                $fatal(1,"Temporal metadata mismatch frame=%0d mode=%0d motion/color/error=%b/%0d/%b %0s",
                    id,expected_mode,seen_motion[id],seen_color[id],seen_error[id],description);
            for(i=0;i<4;i=i+1) begin
                if(!seen_found[id][i]) begin
                    if(seen_shapes[id][i*2+:2]!==0 || seen_held[id][i]!==0)
                        $fatal(1,"Invalid slot retains temporal class/hold frame=%0d slot=%0d",id,i);
                end else begin
                    logical_object=(seen_boxes[id][i*48+24+:12]>=H/2 ? 2 : 0)+
                        (seen_boxes[id][i*48+:12]>=W/2 ? 1 : 0);
                    if(actual_valid[logical_object])
                        $fatal(1,"Duplicate temporal box quadrant frame=%0d object=%0d",id,logical_object);
                    actual_valid[logical_object]=1;
                    actual_held[logical_object]=seen_held[id][i];
                    actual_shapes[logical_object*2+:2]=seen_shapes[id][i*2+:2];
                    object_slots[logical_object]=i;
                    left=logical_object%2==0 ? 16 : 160;
                    top=logical_object<2 ? 16 : 104;
                    if(seen_boxes[id][i*48+:12]!==left ||
                       seen_boxes[id][i*48+12+:12]!==left+31 ||
                       seen_boxes[id][i*48+24+:12]!==top ||
                       seen_boxes[id][i*48+36+:12]!==top+31)
                        $fatal(1,"Temporal test did not preserve real RGB geometry frame=%0d object=%0d",id,logical_object);
                    if(previous_valid[logical_object] && previous_slots[logical_object]!=i)
                        $fatal(1,"Matched object changed slot frame=%0d object=%0d",id,logical_object);
                end
            end
            if(actual_valid!==expected_valid || actual_held!==expected_held ||
               actual_shapes!==expected_shapes)
                $fatal(1,"Temporal mismatch frame=%0d actual=%h/%h/%h expected=%h/%h/%h %0s",
                    id,actual_valid,actual_held,actual_shapes,
                    expected_valid,expected_held,expected_shapes,description);
            previous_valid=actual_valid;
            for(i=0;i<4;i=i+1) previous_slots[i]=object_slots[i];
            checks=checks+1;
        end
    endtask
    task step;
        input [3:0] present;
        input [7:0] injected;
        input [3:0] expected_valid,expected_held;
        input [7:0] expected_shapes;
        input [255:0] description;
        begin
            raw_shapes=injected;
            draw(present);
            send_frame(next_id,H,96);
            check_result(next_id,expected_valid,expected_held,expected_shapes,0,
                requested_mode,description);
            $display("COLOR_SHAPE_STABILITY_STEP frame=%0d raw=%h valid=%h held=%h shapes=%h %0s",
                next_id,raw_shapes,expected_valid,expected_held,expected_shapes,description);
            next_id=next_id+1; steps=steps+1;
        end
    endtask
    task assert_class_state_clear;
        integer i;
        begin
            for(i=0;i<4;i=i+1)
                if(dut.u_red.gen_multi.u_engine.track_shape[i]!==0 ||
                   dut.u_red.gen_multi.u_engine.track_pending_shape[i]!==0 ||
                   dut.u_red.gen_multi.u_engine.track_shape_hits[i]!==0 ||
                   dut.u_red.gen_multi.u_engine.track_shape_age[i]!==0)
                    $fatal(1,"Clear retained temporal state track=%0d",i);
            checks=checks+1; previous_valid=0;
        end
    endtask
    task explicit_clear;
        begin
            blank(3);
            force dut.u_red.I_multi_clear=1'b1;
            blank(2);
            release dut.u_red.I_multi_clear;
            blank(2);
            assert_class_state_clear();
            explicit_clears=explicit_clears+1;
        end
    endtask
    task select_mode;
        input [1:0] mode;
        begin
            requested_mode=mode;
            blank(8);
            previous_valid=0;
            mode_switches=mode_switches+1;
        end
    endtask
    task clock_gap;
        integer i;
        reg [7:0] saved_state [0:3];
        begin
            idle_shapes=shapes; idle_found=found; idle_held=held; idle_results=results;
            for(i=0;i<4;i=i+1)
                saved_state[i]={
                    dut.u_red.gen_multi.u_engine.track_shape[i],
                    dut.u_red.gen_multi.u_engine.track_pending_shape[i],
                    dut.u_red.gen_multi.u_engine.track_shape_hits[i],
                    dut.u_red.gen_multi.u_engine.track_shape_age[i]};
            blank(1000);
            if(shapes!==idle_shapes || found!==idle_found ||
               held!==idle_held || results!=idle_results)
                $fatal(1,"Idle clocks changed a published shape result");
            for(i=0;i<4;i=i+1)
                if(saved_state[i]!=={
                    dut.u_red.gen_multi.u_engine.track_shape[i],
                    dut.u_red.gen_multi.u_engine.track_pending_shape[i],
                    dut.u_red.gen_multi.u_engine.track_shape_hits[i],
                    dut.u_red.gen_multi.u_engine.track_shape_age[i]})
                    $fatal(1,"Idle clocks voted or aged a shape track=%0d",i);
            checks=checks+1;
        end
    endtask

    initial begin
        for(n=0;n<1024;n=n+1) begin
            seen[n]=0; seen_found[n]=0; seen_held[n]=0; seen_shapes[n]=0;
            seen_boxes[n]=0; seen_error[n]=0; seen_motion[n]=0; seen_color[n]=0;
        end
        for(n=0;n<4;n=n+1) previous_slots[n]=-1;
        blank(4); @(negedge clk); rst_n=1;

        step(4'hf,8'h55,0,0,0,"first detection seeds four labels");
        step(4'hf,8'h55,4'hf,0,8'h55,"second frame confirms immediately");
        raw_shapes=8'hff; clock_gap();
        step(4'hf,8'hff,4'hf,0,8'h55,"first different class retains SQR");
        // A pending CIR vote must stay pending across arbitrary idle clocks;
        // only the next actual completed detection can provide vote two.
        clock_gap();
        step(4'hf,8'hff,4'hf,0,8'hff,"second CIR confirms class change");
        step(4'hf,8'haa,4'hf,0,8'hff,"one-frame TRI spike stays CIR");
        step(4'hf,8'hff,4'hf,0,8'hff,"CIR support cancels pending TRI");
        step(4'hf,0,4'hf,0,8'hff,"first UNK retains CIR");
        step(4'hf,0,4'hf,0,8'hff,"second UNK retains CIR");
        step(4'hf,0,4'hf,0,0,"third UNK expires CIR");
        step(4'hf,8'h55,4'hf,0,0,"first new SQR stays unknown");
        step(4'hf,8'h55,4'hf,0,8'h55,"second SQR confirms after expiry");
        step(4'hf,8'haa,4'hf,0,8'h55,"TRI candidate starts");
        step(4'hf,0,4'hf,0,8'h55,"UNK interrupts TRI confirmation");
        step(4'hf,8'haa,4'hf,0,0,"TRI UNK TRI expires stale SQR");
        step(4'hf,8'haa,4'hf,0,8'haa,"consecutive TRI confirms");
        step(4'hf,8'h55,4'hf,0,8'haa,"alternating SQR first");
        step(4'hf,8'hff,4'hf,0,8'haa,"alternating CIR second");
        step(4'hf,8'h55,4'hf,0,0,"three alternatives expire TRI");
        step(4'hf,8'hff,4'hf,0,0,"alternation remains unknown");
        step(4'hf,8'h55,4'hf,0,0,"new consecutive SQR first");
        step(4'hf,8'h55,4'hf,0,8'h55,"new consecutive SQR second");

        step(4'hf,8'h4b,4'hf,0,8'h55,"four independent class votes");
        step(4'hd,8'h4b,4'hf,4'h2,8'h57,"miss interrupts only track one");
        step(4'hf,8'h4b,4'hf,0,8'h43,"mixed miss and UNK expire labels");
        step(4'hf,8'h4b,4'hf,0,8'h4b,"track one reconfirms TRI");
        step(4'hd,8'h4b,4'hf,4'h2,8'h4b,"first missed frame holds TRI");
        step(4'hd,8'h4b,4'hf,4'h2,8'h4b,"second missed frame holds TRI");
        step(4'hd,8'h4b,4'hd,0,8'h43,"third miss releases track one");
        step(4'hf,8'h4b,4'hd,0,8'h43,"reappearance starts fresh votes");
        step(4'hf,8'h4b,4'hf,0,8'h4b,"reappearance confirms in two");

        explicit_clear();
        step(4'hf,8'hff,0,0,0,"explicit clear restarts confirmation");
        step(4'hf,8'hff,4'hf,0,8'hff,"explicit clear cannot leak TRI");
        select_mode(1);
        step(4'hf,8'haa,0,0,0,"K2 green first frame is fresh");
        step(4'hf,8'haa,4'hf,0,8'haa,"K2 green confirms TRI");
        select_mode(2);
        step(4'hf,8'h55,0,0,0,"K2 blue first frame is fresh");
        step(4'hf,8'h55,4'hf,0,8'h55,"K2 blue confirms SQR");
        select_mode(3);
        step(4'hf,8'hff,0,0,0,"K2 motion hides all shape codes");
        step(4'hf,8'hff,0,0,0,"motion remains shape free");
        select_mode(0);
        step(4'hf,8'hff,0,0,0,"motion to red restarts class votes");
        step(4'hf,8'hff,4'hf,0,8'hff,"red confirms CIR after motion");

        // A real truncated RGB frame produces an abort token at the next SOF.
        raw_shapes=8'h55; draw(4'hf); abort_id=next_id;
        send_frame(next_id,H/2,96); next_id=next_id+1;
        previous_valid=0;
        step(4'hf,8'h55,0,0,0,"complete frame after abort seeds");
        check_result(abort_id,0,0,0,0,0,"truncated RGB frame abort");
        step(4'hf,8'h55,4'hf,0,8'h55,"abort cancels previous CIR state");
        aborts=aborts+1;

        // Eighteen live components with large blanking exhaust candidate
        // slots independently of FIFO backpressure.
        draw(0); raw_shapes=8'hff;
        for(n=0;n<18;n=n+1) rectangle(2+14*n,9+14*n,10,25,24'hf02020);
        capacity_id=next_id; previous_valid=0;
        send_frame(next_id,H,1024);
        check_result(next_id,0,0,0,1,0,"live-candidate capacity error");
        if(!saw_capacity_error)
            $fatal(1,"Expected live-candidate error was not exercised");
        assert_class_state_clear();
        next_id=next_id+1; overflows=overflows+1;
        step(4'hf,8'hff,0,0,0,"overflow restarts class confirmation");
        step(4'hf,8'hff,4'hf,0,8'hff,"overflow leaves no old SQR label");

        // Exercise the production FSM's illegal-state recovery branch.
        force dut.u_red.gen_multi.u_engine.state=5'd31;
        blank(2);
        release dut.u_red.gen_multi.u_engine.state;
        blank(2);
        assert_class_state_clear(); illegal_states=illegal_states+1;
        step(4'hf,8'haa,0,0,0,"illegal state resets pending labels");
        step(4'hf,8'haa,4'hf,0,8'haa,"illegal state recovers new TRI");

        // Clear immediately after source EOF, before queued classification
        // can publish, then verify new frames require fresh class votes.
        raw_shapes=8'h55; draw(1); queued_id=next_id;
        send_frame(next_id,H,0); next_id=next_id+1;
        explicit_clear(); blank(1000);
        if(seen[queued_id]) $fatal(1,"Cleared queued EOF published stale classes");
        step(4'hf,8'hff,0,0,0,"queued clear restarts class voting");
        step(4'hf,8'hff,4'hf,0,8'hff,"queued clear confirms fresh CIR");

        @(negedge clk); rst_n=0;
        blank(4); @(negedge clk); rst_n=1;
        blank(3); assert_class_state_clear();
        step(4'hf,8'h55,0,0,0,"reset restarts class voting");
        step(4'hf,8'h55,4'hf,0,8'h55,"reset confirms fresh SQR");
        if(mode_switches!=4 || explicit_clears!=2 || aborts!=1 ||
           overflows!=1 || illegal_states!=1)
            $fatal(1,"Incomplete temporal recovery coverage");
        $display("COLOR_SHAPE_STABILITY_PASS results=%0d checks=%0d steps=%0d tracks=4 mode_switches=%0d explicit_clears=%0d aborts=%0d overflows=%0d illegal_states=%0d",
            results,checks,steps,mode_switches,explicit_clears,aborts,overflows,illegal_states);
        $finish;
    end
    initial begin #200000000; $fatal(1,"Shape temporal regression watchdog"); end
endmodule
