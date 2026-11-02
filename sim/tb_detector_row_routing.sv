`timescale 1ns/1ps
module tb_detector_row_routing;
    wire small_done, production_done;
    detector_row_routing_case #(.W(64),.H(32)) small_case (.done(small_done));
    detector_row_routing_case #(.W(1280),.H(720)) production_case (.done(production_done));
    initial begin
        wait(small_done && production_done);
        $display("DETECTOR_ROW_ROUTING_EQUIVALENCE_PASS configurations=2");
        $finish;
    end
    initial begin #20000000; $fatal(1,"Detector routing watchdog"); end
endmodule

module detector_row_routing_case #(
    parameter integer W=1280,H=720,
    parameter integer XB=$clog2(W),YB=$clog2(H),CB=$clog2(W*H+1)
) (output reg done=0);
    reg clk=0,rst_n=0,clear=0,valid=0,start=0,final_row=0,row_end=0,hit=0;
    reg [2:0] pixels=0;
    reg [XB-1:0] xmin=0,xmax=0;
    reg [YB-1:0] y=0;
    reg [9:0] id=0;
    wire ready,overflow,ref_ready,ref_overflow;
    wire [3:0] found,held,ref_found,ref_held;
    wire [191:0] boxes,ref_boxes;
    wire [7:0] shapes,ref_shapes;
    wire [9:0] result_id,ref_result_id;
    reg [31:0] random_state=32'h12ab3456;
    integer checks=0,snapshots=0,rows=0,clear_rows=0,clear_finals=0;
    integer cancels=0,aborts=0,results=0,bubbles=0,async_resets=0;
    integer frame_index,row_index,beat_index,delay_index,n;
    always #5 clk=~clk;
    red_single_shape_engine #(.IMG_WIDTH(W),.IMG_HEIGHT(H),.X_BITS(XB),
        .Y_BITS(YB),.COUNT_BITS(CB),.MIN_PIXELS(32),.MIN_WIDTH(4),.MIN_HEIGHT(4)) dut (
        .I_clk(clk),.I_rst_n(rst_n),.I_clear(clear),.I_valid(valid),.I_start(start),
        .I_final(final_row),.I_row_end(row_end),.I_hit(hit),.I_pixels(pixels),
        .I_xmin(xmin),.I_xmax(xmax),.I_y(y),.I_id(id),.O_ready(ready),
        .O_valid(found),.O_hold(held),.O_boxes(boxes),.O_shapes(shapes),
        .O_frame_id(result_id),.O_overflow(overflow)
    );
    red_single_shape_engine_reference #(.IMG_WIDTH(W),.IMG_HEIGHT(H),.X_BITS(XB),
        .Y_BITS(YB),.COUNT_BITS(CB),.MIN_PIXELS(32),.MIN_WIDTH(4),.MIN_HEIGHT(4)) reference (
        .I_clk(clk),.I_rst_n(rst_n),.I_clear(clear),.I_valid(valid),.I_start(start),
        .I_final(final_row),.I_row_end(row_end),.I_hit(hit),.I_pixels(pixels),
        .I_xmin(xmin),.I_xmax(xmax),.I_y(y),.I_id(id),.O_ready(ref_ready),
        .O_valid(ref_found),.O_hold(ref_held),.O_boxes(ref_boxes),.O_shapes(ref_shapes),
        .O_frame_id(ref_result_id),.O_overflow(ref_overflow)
    );
    always @(posedge clk) begin
        if (rst_n) begin
            if (dut.r1_valid) rows=rows+1;
            if (clear && dut.r1_valid) clear_rows=clear_rows+1;
            if (clear && dut.r1_valid && dut.r1_last) clear_finals=clear_finals+1;
            if (!valid) bubbles=bubbles+1;
            if (dut.frame_done && dut.class_state!=0) cancels=cancels+1;
            if (dut.abort_done) aborts=aborts+1;
        end
        #1;
        if ({ready,overflow,found,held,boxes,shapes,result_id} !==
            {ref_ready,ref_overflow,ref_found,ref_held,ref_boxes,ref_shapes,ref_result_id})
            $fatal(1,"Detector outputs differ W=%0d t=%0t",W,$time);
        if ({dut.work_seen,dut.work_bad,dut.work_clipped,dut.work_complete,
             dut.work_area,dut.work_missing,dut.work_repair_rows,dut.work_perimeter,
             dut.work_xmin,dut.work_xmax,dut.work_ymin,dut.work_ymax,
             dut.prev_xmin,dut.prev_xmax,dut.prev_y,dut.work_mx2,dut.work_my2,
             dut.work_umin,dut.work_umax,dut.work_vmin,dut.work_vmax} !==
            {reference.work_seen,reference.work_bad,reference.work_clipped,reference.work_complete,
             reference.work_area,reference.work_missing,reference.work_repair_rows,reference.work_perimeter,
             reference.work_xmin,reference.work_xmax,reference.work_ymin,reference.work_ymax,
             reference.prev_xmin,reference.prev_xmax,reference.prev_y,reference.work_mx2,reference.work_my2,
             reference.work_umin,reference.work_umax,reference.work_vmin,reference.work_vmax})
            $fatal(1,"Detector accumulation bank differs W=%0d t=%0t",W,$time);
        if ({dut.frame_done,dut.snap_id,dut.snap_bad,dut.snap_seen,dut.snap_clipped,
             dut.snap_area,dut.snap_missing,dut.snap_perimeter,dut.snap_xmin,dut.snap_xmax,
             dut.snap_ymin,dut.snap_ymax,dut.snap_mx2,dut.snap_my2,
             dut.snap_umin,dut.snap_umax,dut.snap_vmin,dut.snap_vmax} !==
            {reference.frame_done,reference.snap_id,reference.snap_bad,reference.snap_seen,reference.snap_clipped,
             reference.snap_area,reference.snap_missing,reference.snap_perimeter,reference.snap_xmin,reference.snap_xmax,
             reference.snap_ymin,reference.snap_ymax,reference.snap_mx2,reference.snap_my2,
             reference.snap_umin,reference.snap_umax,reference.snap_vmin,reference.snap_vmax})
            $fatal(1,"Detector snapshot bank differs W=%0d t=%0t",W,$time);
        if (dut.row_bank_valid !== {5{dut.r1_valid}} ||
            dut.row_bank_final !== {5{dut.r1_valid && dut.r1_last}})
            $fatal(1,"Detector row enable cycle differs W=%0d t=%0t",W,$time);
        checks=checks+1;
        if (ready) results=results+1;
        if (dut.frame_done) snapshots=snapshots+1;
    end
    task idle;
        input integer cycles;
        integer i;
        begin
            for(i=0;i<cycles;i=i+1) begin
                @(negedge clk); valid=0;start=0;final_row=0;row_end=0;
            end
        end
    endtask
    task single_row_frame;
        begin
            @(negedge clk);
            valid=1;start=1;final_row=1;row_end=1;hit=1;pixels=4;
            xmin=W-24;xmax=W-21;y=H-8;id=id+1'b1;
        end
    endtask
    initial begin
        idle(4);@(negedge clk);rst_n=1;
        // Complete contours, high production coordinates, bubbles and misses.
        for(frame_index=0;frame_index<8;frame_index=frame_index+1) begin
            for(row_index=0;row_index<8;row_index=row_index+1) begin
                for(beat_index=0;beat_index<4;beat_index=beat_index+1) begin
                    @(negedge clk);
                    valid=1;start=row_index==0 && beat_index==0;
                    if(start)id=id+1'b1;
                    final_row=row_index==7 && beat_index==3;row_end=beat_index==3;
                    hit=frame_index<5;pixels=hit ? 4 : 0;
                    xmin=W-24+beat_index*4;xmax=W-21+beat_index*4;y=H-12+row_index;
                    if(beat_index==1)idle(1);
                end
                idle(8);
            end
            idle(3000);
        end
        // Overlapping classifications and a new SOF truncating an open frame.
        for(n=0;n<12;n=n+1)begin single_row_frame();idle(3);end
        @(negedge clk);valid=1;start=1;final_row=0;row_end=0;id=id+1'b1;
        @(negedge clk);start=1;row_end=1;id=id+1'b1;
        idle(20);
        // Clear before row capture, during EOF capture and after dispatch.
        for(delay_index=0;delay_index<6;delay_index=delay_index+1)begin
            single_row_frame();idle(delay_index+1);
            @(negedge clk);clear=1;valid=0;start=0;row_end=0;final_row=0;
            @(negedge clk);clear=0;idle(8);
        end
        // Deterministic malformed traffic exercises every control combination.
        for(n=0;n<20000;n=n+1)begin
            @(negedge clk);
            random_state=random_state ^ (random_state<<13);
            random_state=random_state ^ (random_state>>17);
            random_state=random_state ^ (random_state<<5);
            valid=random_state[0] || random_state[1];
            start=random_state[6:2]==0;final_row=random_state[10:7]==0;
            row_end=random_state[12:11]==0;hit=random_state[13];
            clear=random_state[20:14]==0;
            pixels=random_state[23:21];xmin=random_state%W;
            xmax=xmin+random_state[25:24];y=(random_state>>4)%H;
            if(start)id=id+1'b1;
            if(n%997==996)begin
                #2;rst_n=0;async_resets=async_resets+1;
                #1;
                if ({ready,found,held,boxes,shapes} !== {ref_ready,ref_found,ref_held,ref_boxes,ref_shapes})
                    $fatal(1,"Asynchronous reset differs W=%0d",W);
                @(negedge clk);rst_n=1;
            end
        end
        @(negedge clk);clear=0;idle(4000);
        if(checks<40000 || snapshots<20 || rows<500 || clear_rows==0 || clear_finals==0 ||
           cancels==0 || aborts==0 || results==0 || bubbles==0 || async_resets==0)
            $fatal(1,"Detector routing coverage incomplete W=%0d clear_rows=%0d clear_finals=%0d cancels=%0d",
                W,clear_rows,clear_finals,cancels);
        $display("DETECTOR_ROW_ROUTING_CASE_PASS W=%0d H=%0d cycles=%0d rows=%0d snapshots=%0d clear_rows=%0d clear_finals=%0d cancels=%0d aborts=%0d results=%0d async_resets=%0d",
            W,H,checks,rows,snapshots,clear_rows,clear_finals,cancels,aborts,results,async_resets);
        done=1;
    end
endmodule
