`timescale 1ns/1ps
// The input contract matches motion_target_detect_96: found bounds are
// inclusive 8x8 block bounds; invalid results contain zero coordinates.
// Compare every cycle, including bubbles and outputs without a ready pulse.
module motion_block_alignment_case #(
    parameter integer CASE_ID=0, DEAD=8, CONFIRM=3, RELEASE=3
)(output reg done=0);
    reg clk=0,rst_n=0,ready=0,found=0,scene=0;
    reg [23:0] support=0,pixels=0;
    reg [11:0] x0=0,x1=0,y0=0,y1=0;
    wire [98:0] generic_value,aligned_value;
    always #5 clk=~clk;
    motion_result_stabilizer #(
        .DEADBAND(DEAD),.CONFIRM_FRAMES(CONFIRM),.RELEASE_FRAMES(RELEASE),
        .INPUT_BLOCK_ALIGNED(0)
    ) generic_dut (
        .I_clk(clk),.I_rst_n(rst_n),.I_result_ready(ready),.I_found(found),
        .I_scene_change(scene),.I_supported_blocks(support),.I_pixels(pixels),
        .I_xmin(x0),.I_xmax(x1),.I_ymin(y0),.I_ymax(y1),
        .O_result_ready(generic_value[98]),.O_found(generic_value[97]),
        .O_xmin(generic_value[96:85]),.O_xmax(generic_value[84:73]),
        .O_ymin(generic_value[72:61]),.O_ymax(generic_value[60:49]),
        .O_center_x(generic_value[48:37]),.O_center_y(generic_value[36:25]),
        .O_pixels(generic_value[24:1]),.O_frame_toggle(generic_value[0])
    );
    motion_result_stabilizer #(
        .DEADBAND(DEAD),.CONFIRM_FRAMES(CONFIRM),.RELEASE_FRAMES(RELEASE),
        .INPUT_BLOCK_ALIGNED(1)
    ) aligned_dut (
        .I_clk(clk),.I_rst_n(rst_n),.I_result_ready(ready),.I_found(found),
        .I_scene_change(scene),.I_supported_blocks(support),.I_pixels(pixels),
        .I_xmin(x0),.I_xmax(x1),.I_ymin(y0),.I_ymax(y1),
        .O_result_ready(aligned_value[98]),.O_found(aligned_value[97]),
        .O_xmin(aligned_value[96:85]),.O_xmax(aligned_value[84:73]),
        .O_ymin(aligned_value[72:61]),.O_ymax(aligned_value[60:49]),
        .O_center_x(aligned_value[48:37]),.O_center_y(aligned_value[36:25]),
        .O_pixels(aligned_value[24:1]),.O_frame_toggle(aligned_value[0])
    );
    integer comparisons=0,tokens=0,bubbles=0,publications=0,confirms=0;
    integer held=0,releases=0,scenes=0,resets=0,subblock_tracks=0;
    integer plus8=0,minus8=0,plus9=0,minus9=0,rounding=0,ordering_fallbacks=0;
    integer i,j,selector,bx,by,bw,bh,previous_active,difference;
    reg prior_ready=0,prior_active=0,prior_candidate=0,prior_associated=0;
    reg [98:0] previous_payload=0;
    reg [31:0] random_state=32'hb7a19c05+CASE_ID;
    function [31:0] random_next(input [31:0] value);
        reg [31:0] t;
        begin t=value^(value<<13);t=t^(t>>17);random_next=t^(t<<5);end
    endfunction
    function [11:0] smooth_reference(input [11:0] previous,input [11:0] current);
        integer distance,weighted;
        begin
            distance=current>=previous ? current-previous : previous-current;
            weighted=3*previous+current+(current>=previous ? 3 : 0);
            smooth_reference=distance<=DEAD ? previous : weighted/4;
        end
    endfunction
    always @(posedge clk) begin
        previous_active=generic_dut.active;
        prior_active=generic_dut.active;
        prior_candidate=generic_dut.candidate;
        prior_associated=generic_dut.associated;
        if(rst_n && ready) begin
            if(found && (x0[2:0]!==0 || y0[2:0]!==0 ||
                         x1[2:0]!==7 || y1[2:0]!==7 || x0>x1 || y0>y1))
                $fatal(1,"Input raw-block contract violated case=%0d",CASE_ID);
            if(!found && {x0,x1,y0,y1}!==48'd0)
                $fatal(1,"Invalid raw result did not contain zero bounds case=%0d",CASE_ID);
            if(prior_active && prior_candidate && prior_associated && !scene) begin
                if(generic_dut.smooth_x0!==smooth_reference(generic_dut.track_x0,x0) ||
                   generic_dut.smooth_x1!==smooth_reference(generic_dut.track_x1,x1) ||
                   generic_dut.smooth_y0!==smooth_reference(generic_dut.track_y0,y0) ||
                   generic_dut.smooth_y1!==smooth_reference(generic_dut.track_y1,y1))
                    $fatal(1,"Independent smoothing/rounding reference failed case=%0d",CASE_ID);
                difference=$signed({1'b0,x1})-$signed({1'b0,generic_dut.track_x1});
                case(difference)
                    8:plus8=plus8+1;
                    -8:minus8=minus8+1;
                    9:plus9=plus9+1;
                    -9:minus9=minus9+1;
                endcase
                if(difference>DEAD || difference< -DEAD) rounding=rounding+1;
                if(generic_dut.smooth_x0>generic_dut.smooth_x1 ||
                   generic_dut.smooth_y0>generic_dut.smooth_y1)
                    ordering_fallbacks=ordering_fallbacks+1;
            end
            if(scene) scenes=scenes+1;
        end
        #1;
        if(generic_value!==aligned_value)
            $fatal(1,"Block-aligned output mismatch case=%0d sample=%0d ready=%0d found=%0d scene=%0d input=%0d,%0d,%0d,%0d generic=%h aligned=%h",
                CASE_ID,comparisons,ready,found,scene,x0,x1,y0,y1,generic_value,aligned_value);
        if({generic_dut.active,generic_dut.confirmations,generic_dut.misses,
            generic_dut.anchor_x0,generic_dut.anchor_x1,generic_dut.anchor_y0,generic_dut.anchor_y1,
            generic_dut.anchor_width,generic_dut.anchor_height,
            generic_dut.anchor_center_x,generic_dut.anchor_center_y,
            generic_dut.track_x0,generic_dut.track_x1,generic_dut.track_y0,generic_dut.track_y1,
            generic_dut.track_pixels,generic_dut.publish_valid,generic_dut.publish_found,
            generic_dut.publish_x0,generic_dut.publish_x1,generic_dut.publish_y0,generic_dut.publish_y1,
            generic_dut.publish_pixels} !==
           {aligned_dut.active,aligned_dut.confirmations,aligned_dut.misses,
            aligned_dut.anchor_x0,aligned_dut.anchor_x1,aligned_dut.anchor_y0,aligned_dut.anchor_y1,
            aligned_dut.anchor_width,aligned_dut.anchor_height,
            aligned_dut.anchor_center_x,aligned_dut.anchor_center_y,
            aligned_dut.track_x0,aligned_dut.track_x1,aligned_dut.track_y0,aligned_dut.track_y1,
            aligned_dut.track_pixels,aligned_dut.publish_valid,aligned_dut.publish_found,
            aligned_dut.publish_x0,aligned_dut.publish_x1,aligned_dut.publish_y0,aligned_dut.publish_y1,
            aligned_dut.publish_pixels})
            $fatal(1,"Block-aligned track/pipeline state mismatch case=%0d sample=%0d",CASE_ID,comparisons);
        if(rst_n) begin
            if(generic_value[98]!==prior_ready)
                $fatal(1,"Publication cycle changed case=%0d",CASE_ID);
            prior_ready=ready;
            if(ready) tokens=tokens+1;else bubbles=bubbles+1;
            if(generic_value[98]) publications=publications+1;
            if(!previous_active && generic_dut.active) confirms=confirms+1;
            if(previous_active && !generic_dut.active) releases=releases+1;
            if(generic_dut.active && generic_dut.misses!=0) held=held+1;
            if(generic_dut.active && (generic_dut.track_x1[2:0]!=7 ||
                                     generic_dut.track_y1[2:0]!=7))
                subblock_tracks=subblock_tracks+1;
            if(!generic_value[98] && generic_value[97:0]!==previous_payload[97:0])
                $fatal(1,"Payload changed without result token case=%0d",CASE_ID);
        end else prior_ready=0;
        previous_payload=generic_value;
        comparisons=comparisons+1;
    end
    task send(input integer is_ready,input integer is_found,input integer is_scene,
              input integer supported,input integer ax0,input integer ax1,
              input integer ay0,input integer ay1);
        begin
            @(negedge clk);ready=is_ready;found=is_found;scene=is_scene;support=supported;
            pixels=found ? ((ax1-ax0+1)*(ay1-ay0+1)) : 0;
            x0=is_found ? ax0 : 0;x1=is_found ? ax1 : 0;
            y0=is_found ? ay0 : 0;y1=is_found ? ay1 : 0;
        end
    endtask
    task establish(input integer ax0,input integer ax1);
        integer k;
        begin
            send(1,0,1,0,0,0,0,0);
            for(k=0;k<CONFIRM+1;k=k+1) send(1,1,0,10000,ax0,ax1,ax0,ax1);
        end
    endtask
    task reset_between_edges;
        begin
            @(negedge clk);ready=0;found=0;scene=0;x0=0;x1=0;y0=0;y1=0;
            #2;rst_n=0;
            #1;
            if(generic_value!==99'd0 || aligned_value!==99'd0)
                $fatal(1,"Asynchronous reset differs case=%0d",CASE_ID);
            @(negedge clk);rst_n=1;
            resets=resets+1;
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        establish(64,111);
        send(1,1,0,10000,72,119,72,119);
        send(1,1,0,10000,56,103,56,103);
        send(1,1,0,10000,80,127,80,127);
        send(1,1,0,10000,80,127,80,127);
        send(1,1,0,10000,80,127,80,127);
        establish(64,111);
        send(1,1,0,10000,96,143,96,143);
        send(1,1,0,10000,88,135,88,135);
        send(1,1,0,10000,64,111,64,111);
        send(1,1,0,10000,64,111,64,111);
        for(j=0;j<RELEASE+2;j=j+1) send(1,0,0,0,0,0,0,0);
        // DEAD=32 yields track [40,48], then independently smoothed bounds
        // [40,39]. The ordering guard must restore the raw [8,15] pair.
        establish(40,71);
        send(1,1,0,10000,8,15,8,15);
        send(1,1,0,10000,8,23,8,23);
        send(1,1,0,10000,8,15,8,15);
        for(i=0;i<30000;i=i+1) begin
            random_state=random_next(random_state);
            selector=random_state%12;
            bx=64+8*(random_state[7:4]%12);
            by=64+8*(random_state[11:8]%12);
            bw=8*(1+random_state[14:12]);bh=8*(1+random_state[17:15]);
            case(selector)
                0,1,2,3:send(1,1,0,10000,bx,bx+bw-1,by,by+bh-1);
                4:send(1,0,0,0,0,0,0,0);
                5:send(0,random_state[18],random_state[19],10000,bx,bx+bw-1,by,by+bh-1);
                6:send(1,1,(i%7)==0,10000,64,111,64,111);
                7:send(1,1,0,i%10,64,111,64,111);
                8:send(0,0,0,0,0,0,0,0);
                9:send(1,0,1,0,0,0,0,0);
                10:send(1,1,0,10000,1272,1279,712,719);
                default:send(0,1,0,10000,bx,bx+bw-1,by,by+bh-1);
            endcase
            if(i==511 || i==4095 || i==17000) reset_between_edges();
        end
        send(0,0,0,0,0,0,0,0);
        repeat(4) @(negedge clk);
        if(tokens<1000 || bubbles<1000 || publications<1000 || confirms==0 ||
           releases==0 || scenes==0 || rounding==0 || subblock_tracks==0 ||
           (RELEASE>1 && held==0))
            $fatal(1,"Insufficient aligned-motion state coverage case=%0d",CASE_ID);
        if(DEAD==8 && (plus8==0 || minus8==0 || plus9==0 || minus9==0))
            $fatal(1,"Deadband boundary coverage missing +8=%0d -8=%0d +9=%0d -9=%0d",
                plus8,minus8,plus9,minus9);
        if(DEAD==32 && ordering_fallbacks==0)
            $fatal(1,"Ordering fallback was not exercised");
        $display("MOTION_BLOCK_ALIGNMENT_CASE_PASS case=%0d dead=%0d confirm=%0d release=%0d cycles=%0d tokens=%0d bubbles=%0d publications=%0d confirms=%0d holds=%0d releases=%0d scenes=%0d subblock=%0d plus8=%0d minus8=%0d plus9=%0d minus9=%0d rounding=%0d ordering=%0d resets=%0d",
            CASE_ID,DEAD,CONFIRM,RELEASE,comparisons,tokens,bubbles,publications,
            confirms,held,releases,scenes,subblock_tracks,plus8,minus8,plus9,minus9,
            rounding,ordering_fallbacks,resets);
        done=1;
    end
endmodule

module tb_motion_block_alignment_equivalence;
    wire [2:0] done;
    motion_block_alignment_case #(.CASE_ID(0),.DEAD(8),.CONFIRM(3),.RELEASE(3)) c0(done[0]);
    motion_block_alignment_case #(.CASE_ID(1),.DEAD(0),.CONFIRM(1),.RELEASE(1)) c1(done[1]);
    motion_block_alignment_case #(.CASE_ID(2),.DEAD(32),.CONFIRM(2),.RELEASE(5)) c2(done[2]);
    initial begin
        wait(&done);
        $display("MOTION_BLOCK_ALIGNMENT_EQUIVALENCE_PASS cases=3 exact_cycle_latency=1 aligned_valid=1 invalid_zero=1 previous_subblock_precision=1");
        $finish;
    end
    initial begin #1000000;$fatal(1,"Motion block alignment equivalence watchdog");end
endmodule
