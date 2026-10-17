`timescale 1ns/1ps
// Exercise the production RAW -> LSC -> demosaic -> AWB -> motion path.
// No forced RGB signals or replacement arithmetic/RAM modules are used.
module tb_isp_motion_camera #(
    parameter integer EXPECT_BROKEN_LAST=0,
    parameter integer LINE_BLANKING=32,
    parameter integer MOVE_PIXELS=4
);
    localparam integer W=1280, H=720, GROUPS=320, FRAMES=6;
    localparam integer FRAME_GROUPS=W*H/4, FRAME_WORDS=W*H*3/16;
    localparam integer BLOCK_COLS=W/8, BLOCK_ROWS=H/8, BLOCKS=BLOCK_COLS*BLOCK_ROWS;
    reg clk=0;
    always #4.830 clk=~clk;
    reg rst_n=0, raw_valid=0, raw_user=0, raw_last=0;
    reg [39:0] raw_data=0;
    wire [127:0] output_data;
    wire output_valid, output_user, output_last;
    wire target_ready, target_found, target_toggle, target_mode, active_mode;
    wire [11:0] xmin,xmax,ymin,ymax,cx,cy;
    wire [23:0] target_pixels;
    isp_top #(.ENABLE_EDGE(0)) dut (
        .axi4s_video_aclk(clk),.I_rst_n(rst_n),
        .I_effect_config({4'd0,8'd0}),.I_motion_mode_async(1'b1),
        .I_tlast(raw_last),.I_tuser(raw_user),.I_tdata(raw_data),
        .I_tvalid(raw_valid),.I_tdest(10'd0),.O_tready(1'b1),
        .O_tdata(output_data),.O_tlast(output_last),.O_tuser(output_user),
        .O_tvalid(output_valid),.I_tready(),
        .O_target_result_ready(target_ready),.O_target_found(target_found),
        .O_target_xmin(xmin),.O_target_xmax(xmax),
        .O_target_ymin(ymin),.O_target_ymax(ymax),
        .O_target_center_x(cx),.O_target_center_y(cy),
        .O_target_pixels(target_pixels),.O_target_frame_toggle(target_toggle),
        .O_target_motion_mode(target_mode),.O_motion_mode_active(active_mode),
        .O_edge_mode_active(),.O_ae_stats_valid(),.O_ae_sum_y(),
        .O_ae_sample_count(),.O_ae_bright_count()
    );

    integer raw_frame=-1,lsc_frame=-1,demosaic_frame=-1,awb_frame=-1,packed_frame=-1;
    integer raw_count[0:FRAMES-1],lsc_count[0:FRAMES-1];
    integer demosaic_count[0:FRAMES-1],awb_count[0:FRAMES-1];
    integer demosaic_last[0:FRAMES-1],awb_last[0:FRAMES-1];
    integer demosaic_marker_errors[0:FRAMES-1],awb_marker_errors[0:FRAMES-1];
    integer awb_first_bad_row[0:FRAMES-1],awb_max_burst[0:FRAMES-1];
    integer packed_count[0:FRAMES-1],motion_count[0:FRAMES-1];
    integer motion_bad_markers[0:FRAMES-1],reference_after[0:FRAMES-1];
    integer final_clean[0:FRAMES-1],compared[0:FRAMES-1];
    integer results[0:FRAMES-1],found[0:FRAMES-1],pixels[0:FRAMES-1];
    integer box_xmin[0:FRAMES-1],box_xmax[0:FRAMES-1];
    integer box_ymin[0:FRAMES-1],box_ymax[0:FRAMES-1];
    integer raw_results[0:FRAMES-1],raw_found[0:FRAMES-1],raw_pixels[0:FRAMES-1];
    integer raw_xmin[0:FRAMES-1],raw_xmax[0:FRAMES-1];
    integer raw_ymin[0:FRAMES-1],raw_ymax[0:FRAMES-1];
    integer raw_supported[0:FRAMES-1],raw_scene_change[0:FRAMES-1];
    integer raw_latency[0:FRAMES-1],target_latency[0:FRAMES-1];
    integer awb_final_cycle[0:FRAMES-1],cycle_number=0;
    integer target_results=0,raw_target_results=0,awb_burst=0,errors=0,unknown_groups=0;
    integer final_frame_sample=-1;
    reg final_beat_sample=0,previous_toggle=0,previous_raw_toggle=0;
    integer reference_columns[0:BLOCK_COLS-1];
    integer reference_means[0:BLOCKS-1];
    reg reference_masks[0:FRAMES-1][0:BLOCKS-1];
    integer reference_blocks[0:FRAMES-1],reference_rising[0:FRAMES-1];
    integer ref_row,ref_group,ref_column,ref_lane,ref_address,ref_mean,ref_difference;
    integer ref_red,ref_green,ref_blue;

    function automatic [39:0] scene_group(
        input integer frame_id,input integer group_id,input integer row_id
    );
        integer lane,px,left,value;
        begin
            left=frame_id>=3 ? 200+(frame_id==3 ? MOVE_PIXELS : 2*MOVE_PIXELS) : 200;
            for(lane=0;lane<4;lane=lane+1) begin
                px=group_id*4+lane;
                value=frame_id>=2 && px>=left && px<left+160 &&
                    row_id>=184 && row_id<304 ? 200 : 80;
                scene_group[lane*10 +:10]=value*4;
            end
        end
    endfunction

    always @(posedge clk) begin
        cycle_number=cycle_number+1;
        final_beat_sample=0;
        final_frame_sample=-1;
        if(rst_n) begin
            if(raw_user) raw_frame=raw_frame+1;
            if(dut.lsc_user) lsc_frame=lsc_frame+1;
            if(dut.m_aixs_tuser) demosaic_frame=demosaic_frame+1;
            if(dut.awb_O_tuser) begin
                awb_frame=awb_frame+1;
                awb_burst=0;
            end
            if(output_user) packed_frame=packed_frame+1;
            if(raw_valid) begin
                if(raw_frame<0 || raw_frame>=FRAMES)
                    $fatal(1,"Unexpected RAW frame marker");
                raw_count[raw_frame]=raw_count[raw_frame]+1;
            end
            if(dut.lsc_valid) begin
                if(lsc_frame<0 || lsc_frame>=FRAMES)
                    $fatal(1,"Unexpected LSC frame marker");
                lsc_count[lsc_frame]=lsc_count[lsc_frame]+1;
            end
            if(dut.m_aixs_tvalid) begin
                if(demosaic_frame<0 || demosaic_frame>=FRAMES)
                    $fatal(1,"Unexpected demosaic frame marker");
                if(dut.m_aixs_tlast !== (demosaic_count[demosaic_frame]%GROUPS==GROUPS-1))
                    demosaic_marker_errors[demosaic_frame]=
                        demosaic_marker_errors[demosaic_frame]+1;
                if(dut.m_aixs_tlast)
                    demosaic_last[demosaic_frame]=demosaic_last[demosaic_frame]+1;
                demosaic_count[demosaic_frame]=demosaic_count[demosaic_frame]+1;
            end
            if(dut.awb_O_tvalid) begin
                if(awb_frame<0 || awb_frame>=FRAMES)
                    $fatal(1,"Unexpected AWB frame marker");
                // Independent image-domain reference uses only public AWB
                // pixels and accepted-beat geometry, with integer arithmetic.
                ref_row=awb_count[awb_frame]/GROUPS;
                ref_group=awb_count[awb_frame]%GROUPS;
                ref_column=ref_group/2;
                if(ref_row%8==0 && ref_group%2==0)
                    reference_columns[ref_column]=0;
                for(ref_lane=0;ref_lane<4;ref_lane=ref_lane+1) begin
                    ref_red=dut.awb_O_tdata[95-ref_lane*24 -:8];
                    ref_green=dut.awb_O_tdata[87-ref_lane*24 -:8];
                    ref_blue=dut.awb_O_tdata[79-ref_lane*24 -:8];
                    reference_columns[ref_column]=reference_columns[ref_column]+
                        (ref_red+2*ref_green+ref_blue)/4;
                end
                if(ref_row%8==7 && ref_group%2==1) begin
                    ref_address=(ref_row/8)*BLOCK_COLS+ref_column;
                    ref_mean=reference_columns[ref_column]/64;
                    ref_difference=ref_mean-reference_means[ref_address];
                    if(ref_difference<0) ref_difference=-ref_difference;
                    reference_masks[awb_frame][ref_address]=
                        !EXPECT_BROKEN_LAST && awb_frame>0 && ref_difference>=10;
                    if(reference_masks[awb_frame][ref_address] &&
                        ref_mean>reference_means[ref_address])
                        reference_rising[awb_frame]=reference_rising[awb_frame]+1;
                    reference_means[ref_address]=ref_mean;
                    reference_blocks[awb_frame]=reference_blocks[awb_frame]+1;
                end
                if(dut.awb_O_tlast !== (awb_count[awb_frame]%GROUPS==GROUPS-1)) begin
                    awb_marker_errors[awb_frame]=awb_marker_errors[awb_frame]+1;
                    if(awb_first_bad_row[awb_frame]<0)
                        awb_first_bad_row[awb_frame]=awb_count[awb_frame]/GROUPS;
                end
                if(dut.awb_O_tlast) awb_last[awb_frame]=awb_last[awb_frame]+1;
                awb_count[awb_frame]=awb_count[awb_frame]+1;
                if(awb_count[awb_frame]==FRAME_GROUPS)
                    awb_final_cycle[awb_frame]=cycle_number;
                awb_burst=awb_burst+1;
                if(awb_burst>awb_max_burst[awb_frame])
                    awb_max_burst[awb_frame]=awb_burst;
                if((^dut.awb_O_tdata)===1'bx) unknown_groups=unknown_groups+1;
            end else awb_burst=0;
            if(dut.u_target_detect_switch.u_motion.accept_beat) begin
                if((^{dut.u_target_detect_switch.u_motion.frame_bad,
                    dut.u_target_detect_switch.u_motion.beat_clean,
                    dut.u_target_detect_switch.u_motion.beat_compare,
                    dut.u_target_detect_switch.u_motion.reference_valid})===1'bx)
                    $fatal(1,"Unknown motion parser/reference state");
                motion_count[awb_frame]=motion_count[awb_frame]+1;
                if(dut.u_target_detect_switch.u_motion.bad_line_marker)
                    motion_bad_markers[awb_frame]=motion_bad_markers[awb_frame]+1;
                if(dut.u_target_detect_switch.u_motion.final_beat) begin
                    final_beat_sample=1;
                    final_frame_sample=awb_frame;
                    final_clean[awb_frame]=dut.u_target_detect_switch.u_motion.beat_clean;
                    compared[awb_frame]=dut.u_target_detect_switch.u_motion.beat_compare;
                end
            end
            if(output_valid) begin
                if(packed_frame<0 || packed_frame>=FRAMES)
                    $fatal(1,"Unexpected packed frame marker");
                packed_count[packed_frame]=packed_count[packed_frame]+1;
                if((^output_data)===1'bx)
                    $fatal(1,"Unknown packed pixel data");
            end
            if(dut.u_target_detect_switch.raw_motion_ready) begin
                if((^{dut.u_target_detect_switch.raw_motion_found,
                    dut.u_target_detect_switch.raw_motion_pixels,
                    dut.u_target_detect_switch.raw_motion_xmin,
                    dut.u_target_detect_switch.raw_motion_xmax,
                    dut.u_target_detect_switch.raw_motion_ymin,
                    dut.u_target_detect_switch.raw_motion_ymax,
                    dut.u_target_detect_switch.raw_motion_cx,
                    dut.u_target_detect_switch.raw_motion_cy,
                    dut.u_target_detect_switch.raw_motion_toggle,
                    dut.u_target_detect_switch.u_motion.O_supported_blocks,
                    dut.u_target_detect_switch.u_motion.O_scene_change})===1'bx)
                    $fatal(1,"Unknown raw motion result metadata");
                if(raw_target_results>=FRAMES ||
                    dut.u_target_detect_switch.raw_motion_toggle===previous_raw_toggle)
                    $fatal(1,"Unexpected raw motion completion");
                if(dut.u_target_detect_switch.raw_motion_cx !==
                        (int'(dut.u_target_detect_switch.raw_motion_xmin)+
                         int'(dut.u_target_detect_switch.raw_motion_xmax))/2 ||
                    dut.u_target_detect_switch.raw_motion_cy !==
                        (int'(dut.u_target_detect_switch.raw_motion_ymin)+
                         int'(dut.u_target_detect_switch.raw_motion_ymax))/2)
                    $fatal(1,"Raw motion center disagrees with its bounding box");
                raw_results[raw_target_results]=raw_results[raw_target_results]+1;
                raw_found[raw_target_results]=dut.u_target_detect_switch.raw_motion_found;
                raw_pixels[raw_target_results]=dut.u_target_detect_switch.raw_motion_pixels;
                raw_xmin[raw_target_results]=dut.u_target_detect_switch.raw_motion_xmin;
                raw_xmax[raw_target_results]=dut.u_target_detect_switch.raw_motion_xmax;
                raw_ymin[raw_target_results]=dut.u_target_detect_switch.raw_motion_ymin;
                raw_ymax[raw_target_results]=dut.u_target_detect_switch.raw_motion_ymax;
                raw_supported[raw_target_results]=dut.u_target_detect_switch.u_motion.O_supported_blocks;
                raw_scene_change[raw_target_results]=dut.u_target_detect_switch.u_motion.O_scene_change;
                raw_latency[raw_target_results]=cycle_number-awb_final_cycle[raw_target_results];
                previous_raw_toggle=dut.u_target_detect_switch.raw_motion_toggle;
                raw_target_results=raw_target_results+1;
            end
            if(target_ready) begin
                if((^{target_found,target_pixels,xmin,xmax,ymin,ymax,cx,cy,
                    target_toggle,target_mode,active_mode})===1'bx)
                    $fatal(1,"Unknown motion result metadata");
                if(target_results>=FRAMES || target_mode!==1'b1 ||
                    target_toggle===previous_toggle)
                    $fatal(1,"Unexpected motion result/frame/mode");
                if(cx !== (int'(xmin)+int'(xmax))/2 ||
                    cy !== (int'(ymin)+int'(ymax))/2)
                    $fatal(1,"Stable motion center disagrees with its bounding box");
                results[target_results]=results[target_results]+1;
                found[target_results]=target_found;
                pixels[target_results]=target_pixels;
                box_xmin[target_results]=xmin;box_xmax[target_results]=xmax;
                box_ymin[target_results]=ymin;box_ymax[target_results]=ymax;
                target_latency[target_results]=cycle_number-awb_final_cycle[target_results];
                previous_toggle=target_toggle;
                target_results=target_results+1;
            end
        end
        #1;
        if(rst_n && final_beat_sample)
            reference_after[final_frame_sample]=dut.u_target_detect_switch.u_motion.reference_valid;
    end

    task automatic tick(input bit v,input bit u,input bit l,input [39:0] d);
        begin
            @(negedge clk);raw_valid=v;raw_user=u;raw_last=l;raw_data=d;
        end
    endtask
    task automatic check_frame(input integer id);
        integer expected_last,expected_bad,xx,yy,wx,wy,votes,hits,supported;
        integer expected_xmin,expected_xmax,expected_ymin,expected_ymax;
        integer expected_stable_found,expected_stable_pixels;
        integer expected_stable_xmin,expected_stable_xmax,expected_stable_ymin,expected_stable_ymax;
        reg expected_found,have_reference_box,expected_scene_change;
        begin
            expected_last=EXPECT_BROKEN_LAST ? H-1 : H;
            expected_bad=EXPECT_BROKEN_LAST ? 1 : 0;
            hits=0;supported=0;have_reference_box=0;
            expected_xmin=BLOCK_COLS;expected_xmax=0;
            expected_ymin=BLOCK_ROWS;expected_ymax=0;
            for(yy=0;yy<BLOCK_ROWS;yy=yy+1)
                for(xx=0;xx<BLOCK_COLS;xx=xx+1)
                    if(reference_masks[id][yy*BLOCK_COLS+xx]) hits=hits+1;
            for(yy=2;yy<BLOCK_ROWS;yy=yy+1)
                for(xx=2;xx<BLOCK_COLS;xx=xx+1) begin
                    votes=0;
                    for(wy=yy-2;wy<=yy;wy=wy+1)
                        for(wx=xx-2;wx<=xx;wx=wx+1)
                            if(reference_masks[id][wy*BLOCK_COLS+wx]) votes=votes+1;
                    if(votes>=3) begin
                        if(reference_masks[id][(yy-1)*BLOCK_COLS+xx-1])
                            supported=supported+1;
                        have_reference_box=1;
                        for(wy=yy-2;wy<=yy;wy=wy+1)
                            for(wx=xx-2;wx<=xx;wx=wx+1)
                                if(reference_masks[id][wy*BLOCK_COLS+wx]) begin
                                    if(wx<expected_xmin) expected_xmin=wx;
                                    if(wx>expected_xmax) expected_xmax=wx;
                                    if(wy<expected_ymin) expected_ymin=wy;
                                    if(wy>expected_ymax) expected_ymax=wy;
                                end
                    end
                end
            expected_found=have_reference_box && hits>=12 && hits<(BLOCKS*40+99)/100;
            expected_scene_change=EXPECT_BROKEN_LAST || id==0 ||
                hits>=(BLOCKS*40+99)/100 ||
                (hits>=(BLOCKS+7)/8 && (reference_rising[id]<=hits/8 ||
                    reference_rising[id]>=hits-hits/8));
            if(reference_blocks[id]!=BLOCKS || raw_pixels[id]!=hits*64 ||
                raw_found[id]!==expected_found || raw_supported[id]!=supported ||
                raw_scene_change[id]!==expected_scene_change ||
                (expected_found && (raw_xmin[id]!=expected_xmin*8 ||
                    raw_xmax[id]!=expected_xmax*8+7 ||
                    raw_ymin[id]!=expected_ymin*8 ||
                    raw_ymax[id]!=expected_ymax*8+7))) begin
                $display("ISP_MOTION_CAMERA_REFERENCE_MISMATCH frame=%0d blocks=%0d expected_found=%0d pixels=%0d box=%0d,%0d,%0d,%0d supported=%0d scene_change=%0d",
                    id,reference_blocks[id],expected_found,hits*64,
                    expected_xmin*8,expected_xmax*8+7,
                    expected_ymin*8,expected_ymax*8+7,supported,expected_scene_change);
                errors=errors+1;
            end
            // The first appearance and next translation are candidates.
            // The third compatible observation confirms frame4; frame5 is a
            // plain miss and retains that track for the short hold interval.
            expected_stable_found=!EXPECT_BROKEN_LAST && id>=4;
            expected_stable_pixels=expected_stable_found ? raw_pixels[4] : 0;
            expected_stable_xmin=expected_stable_found ? raw_xmin[4] : 0;
            expected_stable_xmax=expected_stable_found ? raw_xmax[4] : 0;
            expected_stable_ymin=expected_stable_found ? raw_ymin[4] : 0;
            expected_stable_ymax=expected_stable_found ? raw_ymax[4] : 0;
            if(found[id]!==expected_stable_found ||
                pixels[id]!==expected_stable_pixels ||
                box_xmin[id]!==expected_stable_xmin || box_xmax[id]!==expected_stable_xmax ||
                box_ymin[id]!==expected_stable_ymin || box_ymax[id]!==expected_stable_ymax) begin
                $display("ISP_MOTION_CAMERA_STABLE_MISMATCH frame=%0d expected_found=%0d pixels=%0d box=%0d,%0d,%0d,%0d",
                    id,expected_stable_found,expected_stable_pixels,
                    expected_stable_xmin,expected_stable_xmax,expected_stable_ymin,expected_stable_ymax);
                errors=errors+1;
            end
            $display("ISP_MOTION_CAMERA_FRAME frame=%0d raw=%0d lsc=%0d demosaic=%0d demosaic_last=%0d demosaic_bad=%0d awb=%0d awb_last=%0d awb_bad=%0d first_bad_row=%0d max_burst=%0d packed=%0d motion_beats=%0d motion_bad=%0d clean=%0d reference=%0d compare=%0d raw_ready=%0d raw_found=%0d raw_pixels=%0d raw_box=%0d,%0d,%0d,%0d raw_supported=%0d scene_change=%0d raw_latency=%0d ready=%0d found=%0d pixels=%0d box=%0d,%0d,%0d,%0d target_latency=%0d",
                id,raw_count[id],lsc_count[id],demosaic_count[id],
                demosaic_last[id],demosaic_marker_errors[id],awb_count[id],
                awb_last[id],awb_marker_errors[id],awb_first_bad_row[id],
                awb_max_burst[id],packed_count[id],motion_count[id],
                motion_bad_markers[id],final_clean[id],reference_after[id],
                compared[id],raw_results[id],raw_found[id],raw_pixels[id],
                raw_xmin[id],raw_xmax[id],raw_ymin[id],raw_ymax[id],raw_supported[id],
                raw_scene_change[id],raw_latency[id],
                results[id],found[id],pixels[id],
                box_xmin[id],box_xmax[id],box_ymin[id],box_ymax[id],target_latency[id]);
            if(raw_count[id]!=FRAME_GROUPS || lsc_count[id]!=FRAME_GROUPS ||
                demosaic_count[id]!=FRAME_GROUPS || awb_count[id]!=FRAME_GROUPS ||
                packed_count[id]!=FRAME_WORDS || motion_count[id]!=FRAME_GROUPS ||
                demosaic_last[id]!=H || demosaic_marker_errors[id]!=0 ||
                awb_last[id]!=expected_last || awb_marker_errors[id]!=expected_bad ||
                motion_bad_markers[id]!=expected_bad || results[id]!=1 ||
                raw_results[id]!=1 || raw_latency[id]!=11 || target_latency[id]!=13)
                errors=errors+1;
            if(EXPECT_BROKEN_LAST) begin
                if(awb_first_bad_row[id]!=H-2 || final_clean[id]!==0 ||
                    reference_after[id]!==0 || compared[id]!==0 || raw_found[id]!==0)
                    errors=errors+1;
            end else begin
                if(final_clean[id]!==1 || reference_after[id]!==1 ||
                    compared[id]!==int'(id!=0))
                    errors=errors+1;
                if(id<2 || id==5) begin
                    if(raw_found[id]!==0 || raw_pixels[id]!=0) errors=errors+1;
                end else begin
                    if(raw_found[id]!==1 ||
                        raw_xmin[id]<192 || raw_xmin[id]>208+2*MOVE_PIXELS ||
                        raw_xmax[id]<351 || raw_xmax[id]>367+2*MOVE_PIXELS ||
                        raw_ymin[id]<176 || raw_ymin[id]>192 ||
                        raw_ymax[id]<295 || raw_ymax[id]>311)
                        errors=errors+1;
                end
            end
        end
    endtask

    integer f,y,g;
    initial begin
        if(LINE_BLANKING<8) $fatal(1,"At least eight line blanking clocks are required");
        if(MOVE_PIXELS<1 || MOVE_PIXELS>128)
            $fatal(1,"Motion displacement must be 1..128 pixels");
        for(f=0;f<FRAMES;f=f+1) begin
            raw_count[f]=0;lsc_count[f]=0;demosaic_count[f]=0;awb_count[f]=0;
            demosaic_last[f]=0;awb_last[f]=0;demosaic_marker_errors[f]=0;
            awb_marker_errors[f]=0;awb_first_bad_row[f]=-1;awb_max_burst[f]=0;
            packed_count[f]=0;motion_count[f]=0;motion_bad_markers[f]=0;
            reference_blocks[f]=0;reference_rising[f]=0;
            reference_after[f]=-1;final_clean[f]=-1;compared[f]=-1;
            results[f]=0;found[f]=0;pixels[f]=0;
            box_xmin[f]=0;box_xmax[f]=0;box_ymin[f]=0;box_ymax[f]=0;
            raw_results[f]=0;raw_found[f]=0;raw_pixels[f]=0;
            raw_xmin[f]=0;raw_xmax[f]=0;raw_ymin[f]=0;raw_ymax[f]=0;
            raw_supported[f]=0;raw_scene_change[f]=0;
            raw_latency[f]=-1;target_latency[f]=-1;awb_final_cycle[f]=-1;
        end
        repeat(20) tick(0,0,0,0);
        rst_n=1;
        repeat(20) tick(0,0,0,0);
        for(f=0;f<FRAMES;f=f+1) begin
            // Test both SOF on the first valid beat and SOF in blanking.
            if(f%2) begin
                tick(0,1,0,0);
                repeat(16) tick(0,0,0,0);
            end
            for(y=0;y<H;y=y+1) begin
                for(g=0;g<GROUPS;g=g+1)
                    tick(1,f%2==0 && y==0 && g==0,g==GROUPS-1,scene_group(f,g,y));
                repeat(LINE_BLANKING) tick(0,0,0,0);
            end
            // Drain the reflected bottom row, AWB and both result pipelines.
            repeat(1000) tick(0,0,0,0);
            check_frame(f);
        end
        if(errors || unknown_groups || target_results!=FRAMES || raw_target_results!=FRAMES ||
            raw_frame!=FRAMES-1 || lsc_frame!=FRAMES-1 ||
            demosaic_frame!=FRAMES-1 || awb_frame!=FRAMES-1 || packed_frame!=FRAMES-1)
            $fatal(1,"ISP camera motion regression failed errors=%0d unknown=%0d results=%0d",
                errors,unknown_groups,target_results);
        if(EXPECT_BROKEN_LAST)
            $display("ISP_MOTION_CAMERA_BASELINE_PASS frames=%0d awb_groups=%0d awb_last_per_frame=719 bad_row=718 reference_valid=0 targets=0",
                FRAMES,FRAMES*FRAME_GROUPS);
        else
            $display("ISP_MOTION_CAMERA_PASS frames=%0d raw_groups=%0d awb_groups=%0d awb_last_per_frame=720 packed_words=%0d results=%0d targets=2 raw_targets=3 confirmed_frame=4 held_frame=5 target_latency=13 move_pixels=%0d line_blanking=%0d",
                FRAMES,FRAMES*FRAME_GROUPS,FRAMES*FRAME_GROUPS,FRAMES*FRAME_WORDS,target_results,
                MOVE_PIXELS,LINE_BLANKING);
        $finish;
    end
    initial begin
        #100000000;
        $fatal(1,"ISP camera motion regression timeout");
    end
endmodule
