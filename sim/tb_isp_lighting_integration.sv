`timescale 1ns/1ps
// Real RAW AE tap plus the post-demosaic RGB path through AWB, mode/Scharr/emboss,
// selected target detection and the byte packer. Camera MIPI and demosaic
// arithmetic are deliberately outside this integration test.
module tb_isp_lighting_integration #(
    parameter integer MOTION_MODE=0,
    parameter integer EMBOSS_MODE=0
);
    localparam integer W=1280, H=720, GROUPS=320;
    localparam integer FRAME_GROUPS=230400, FRAME_WORDS=172800;
    localparam integer AWB_LATENCY=54;
    localparam integer TARGET_LATENCY=MOTION_MODE ? 13 : 6;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0;
    reg [3:0] request_mode=0;
    reg raw_valid=0, raw_user=0, raw_last=0;
    reg [39:0] raw_data=0;
    reg injected_valid=0, injected_user=0, injected_last=0;
    reg [95:0] injected_data=0;
    wire [127:0] output_data;
    wire output_valid, output_user, output_last, mode;
    wire [11:0] effect_config;
    wire target_ready, target_found, target_toggle;
    wire target_motion_mode, motion_mode;
    wire [11:0] xmin,xmax,ymin,ymax,cx,cy;
    wire [23:0] target_pixels;
    wire stats_valid;
    wire [31:0] sum_y;
    wire [15:0] sample_count, bright_count;
    isp_top #(.ENABLE_EDGE(0)) dut (
        .axi4s_video_aclk(clk),.I_rst_n(rst_n),
        .I_effect_config({request_mode,8'd0}),
        .I_motion_mode_async(MOTION_MODE!=0),
        .I_tlast(raw_last),.I_tuser(raw_user),.I_tdata(raw_data),.I_tvalid(raw_valid),
        .I_tdest(10'd0),.O_tready(1'b1),.O_tdata(output_data),
        .O_tlast(output_last),.O_tuser(output_user),.O_tvalid(output_valid),
        .I_tready(),.O_target_result_ready(target_ready),.O_target_found(target_found),
        .O_target_xmin(xmin),.O_target_xmax(xmax),.O_target_ymin(ymin),
        .O_target_ymax(ymax),.O_target_center_x(cx),.O_target_center_y(cy),
        .O_target_pixels(target_pixels),.O_target_frame_toggle(target_toggle),
        .O_target_motion_mode(target_motion_mode),.O_motion_mode_active(motion_mode),
        .O_edge_mode_active(mode),.O_effect_config(effect_config),
        .O_ae_stats_valid(stats_valid),
        .O_ae_sum_y(sum_y),.O_ae_sample_count(sample_count),
        .O_ae_bright_count(bright_count)
    );

    integer source_frame=-1, awb_frame=-1, edge_frame=-1, packed_frame=-1;
    integer awb_count[0:2], edge_count[0:2], packed_count[0:2];
    integer expected_sum[0:2], expected_count[0:2], expected_bright[0:2];
    integer ae_results=0, target_results=0, raw_motion_results=0, bytes_checked=0;
    integer cycle_number=0, awb_last_cycle[0:2], white_pixels=0;
    integer emboss_pixels=0,emboss_bright=0,emboss_dark=0,emboss_neutral=0;
    integer emboss_white=0,emboss_black=0;
    reg [7:0] byte_queue[0:127];
    integer byte_tag[0:127];
    integer byte_write=0, byte_read=0;
    reg [AWB_LATENCY-1:0] reference_valid=0;
    reg [95:0] reference_data[0:AWB_LATENCY-1];
    reg [95:0] sampled_edge_data;
    reg sampled_edge_valid,sampled_edge_user,sampled_edge_mode;
    reg [11:0] sampled_effect_config;
    integer sampled_frame,byte_index,lane;
    integer emboss_x,emboss_y,emboss_level;
    reg [23:0] expected_emboss;
    integer reference_stage;
    bit previous_toggle=0;

    function automatic [23:0] scene(
        input integer frame_id,input integer x,input integer y
    );
        if(MOTION_MODE)
            scene = frame_id>0 && x>=(frame_id==2?248:200) &&
                    x<=(frame_id==2?407:359) && y>=184 && y<=303 ?
                    24'hc8c8c8 : 24'h505050;
        else
            case (frame_id)
                0: scene = x>=200 && x<=359 && y>=180 && y<=299 ?
                           24'hc8231e : 24'h8c6e64;
                1: scene = x>=700 && x<=859 && y>=400 && y<=519 ?
                           24'h320f0c : 24'hffaaBE;
                default: scene = (x<128 && y<80) ||
                    (EMBOSS_MODE && x>=256 && x<384 && y>=160 && y<240) ?
                    24'hffffff : 24'h646e8c;
            endcase
    endfunction
    function automatic integer scene_luminance(
        input integer frame_id,input integer x,input integer y
    );
        reg [23:0] original;
        integer r,g,b,rg,bg;
        begin
            original=scene(frame_id,x,y);
            rg=!MOTION_MODE && frame_id==2 ? 249 : 256;
            bg=!MOTION_MODE && frame_id==2 ? 260 : 256;
            r=original[23:16]*rg/256;
            g=original[15:8];
            b=original[7:0]*bg/256;
            if(r>255) r=255;
            if(b>255) b=255;
            scene_luminance=(r+2*g+b)/4;
        end
    endfunction
    function automatic integer emboss_reference(
        input integer x,input integer y
    );
        integer level;
        begin
            // The causal 3x3 window's center is one pixel up and left.
            level=128;
            if(x>=2 && y>=2)
                level=128+2*(scene_luminance(2,x-1,y-1)-
                              scene_luminance(2,x-2,y-2));
            emboss_reference=level<0 ? 0 : level>255 ? 255 : level;
        end
    endfunction
    function automatic [95:0] scene_group(
        input integer frame_id,input integer group_id,input integer row_id
    );
        integer n;
        for(n=0;n<4;n=n+1)
            scene_group[95-n*24 -:24]=scene(frame_id,group_id*4+n,row_id);
    endfunction
    function automatic [39:0] raw_scene(input integer frame_id);
        case (frame_id)
            // Scaled lanes are 100,191,192,255. The last two are bright and
            // both contribute the capped value 192 to the full-frame sum.
            0: raw_scene={10'd1023,10'd768,10'd767,10'd400};
            // Scaled lanes are 0,1,128,200; only the final lane is bright.
            1: raw_scene={10'd800,10'd512,10'd4,10'd0};
            // Ordinary unsaturated values spanning the AE control thresholds.
            default: raw_scene={10'd576,10'd480,10'd384,10'd252};
        endcase
    endfunction
    function automatic [95:0] awb_reference(
        input [95:0] original,input integer frame_id
    );
        integer n,r,b,rg,bg;
        begin
            // Vertical blanking is 68 clocks, shorter than AWB division.
            // Its early SOF still precedes all of the new frame's pixels.
            // Division
            // from frame0 finishes during frame1, and commits at frame2 SOF.
            rg=!MOTION_MODE && frame_id==2 ? 249 : 256;
            bg=!MOTION_MODE && frame_id==2 ? 260 : 256;
            for(n=0;n<4;n=n+1) begin
                r=original[n*24+16 +:8]*rg/256;
                b=original[n*24 +:8]*bg/256;
                awb_reference[n*24+16 +:8]=r>255?255:r;
                awb_reference[n*24+8 +:8]=original[n*24+8 +:8];
                awb_reference[n*24 +:8]=b>255?255:b;
            end
        end
    endfunction

    always @(posedge clk) begin
        cycle_number=cycle_number+1;
        sampled_edge_valid=dut.edge_O_tvalid;
        sampled_edge_user=dut.edge_O_tuser;
        sampled_edge_data=dut.edge_O_tdata;
        sampled_edge_mode=mode;
        sampled_effect_config=effect_config;
        if(!rst_n) begin
            reference_valid=0;
            for(reference_stage=0;reference_stage<AWB_LATENCY;
                reference_stage=reference_stage+1)
                reference_data[reference_stage]=0;
        end else begin
            reference_valid={reference_valid[AWB_LATENCY-2:0],injected_valid};
            for(reference_stage=AWB_LATENCY-1;reference_stage>0;
                reference_stage=reference_stage-1)
                reference_data[reference_stage]=reference_data[reference_stage-1];
            reference_data[0]=awb_reference(injected_data,source_frame);
            if(injected_user) begin
                if(awb_frame>=0 && awb_count[awb_frame]!=FRAME_GROUPS)
                    $fatal(1,"AWB preceding frame lost groups");
                awb_frame=awb_frame+1;
            end
            if(sampled_edge_user) begin
                if(edge_frame>=0 && edge_count[edge_frame]!=FRAME_GROUPS)
                    $fatal(1,"Edge preceding frame lost groups");
                if(byte_write!=byte_read)
                    $fatal(1,"Packer retained bytes across frame boundary");
                edge_frame=edge_frame+1;
            end
            if(sampled_edge_valid) begin
                if(edge_frame<0 || edge_frame>2 ||
                    sampled_edge_mode !== (edge_frame==1))
                    $fatal(1,"Mode token did not follow its frame");
                if(sampled_effect_config !==
                    {edge_frame==1 ? 4'd2 :
                     (EMBOSS_MODE && edge_frame==2 ? 4'd4 : 4'd0),8'd0})
                    $fatal(1,"Effect config did not follow frame%0d: %h",
                        edge_frame,sampled_effect_config);
                if(EMBOSS_MODE && edge_frame==2)
                    for(lane=0;lane<4;lane=lane+1) begin
                        emboss_x=((edge_count[edge_frame]%GROUPS)*4)+lane;
                        emboss_y=edge_count[edge_frame]/GROUPS;
                        emboss_level=emboss_reference(emboss_x,emboss_y);
                        expected_emboss={3{8'(emboss_level)}};
                        if(sampled_edge_data[95-lane*24 -:24]!==expected_emboss)
                            $fatal(1,"Emboss ISP pixel mismatch at %0d,%0d got=%h expected=%h",
                                emboss_x,emboss_y,
                                sampled_edge_data[95-lane*24 -:24],expected_emboss);
                        emboss_pixels=emboss_pixels+1;
                        if(emboss_level>128) emboss_bright=emboss_bright+1;
                        else if(emboss_level<128) emboss_dark=emboss_dark+1;
                        else emboss_neutral=emboss_neutral+1;
                        if(emboss_level==255) emboss_white=emboss_white+1;
                        if(emboss_level==0) emboss_black=emboss_black+1;
                    end
                edge_count[edge_frame]=edge_count[edge_frame]+1;
                for(byte_index=0;byte_index<12;byte_index=byte_index+1) begin
                    byte_queue[byte_write%128]=sampled_edge_data[95-byte_index*8 -:8];
                    byte_tag[byte_write%128]=edge_frame;
                    byte_write=byte_write+1;
                end
                if(edge_frame==1) for(lane=0;lane<4;lane=lane+1) begin
                    if(sampled_edge_data[lane*24 +:24]!==24'd0 &&
                        sampled_edge_data[lane*24 +:24]!==24'hffffff)
                        $fatal(1,"Edge mode emitted a nonbinary pixel");
                    if(sampled_edge_data[lane*24 +:24]===24'hffffff)
                        white_pixels=white_pixels+1;
                end
            end
        end
        #1;
        if(rst_n) begin
            if(motion_mode !== (MOTION_MODE!=0 && awb_frame>=0) ||
                (!MOTION_MODE && target_motion_mode !== 1'b0))
                $fatal(1,"Fixed target-detection mode changed or became unknown");
            if(dut.awb_O_tvalid!==reference_valid[AWB_LATENCY-1] ||
                dut.awb_O_tdata!==(reference_valid[AWB_LATENCY-1] ?
                    reference_data[AWB_LATENCY-1] : 96'd0) ||
                dut.awb_O_tuser!==injected_user)
                $fatal(1,"Real ISP AWB stream/reference mismatch");
            if(dut.awb_O_tvalid) begin
                awb_count[awb_frame]=awb_count[awb_frame]+1;
                if(awb_count[awb_frame]==FRAME_GROUPS)
                    awb_last_cycle[awb_frame]=cycle_number;
            end
            if(stats_valid) begin
                if(ae_results>=3 || sample_count!=expected_count[ae_results] ||
                    sum_y!=expected_sum[ae_results] ||
                    bright_count!=expected_bright[ae_results])
                    $fatal(1,"AE stats wrong frame=%0d sum=%0d samples=%0d bright=%0d",
                        ae_results,sum_y,sample_count,bright_count);
                ae_results=ae_results+1;
            end
            if(MOTION_MODE && dut.u_target_detect_switch.raw_motion_ready) begin
                if(raw_motion_results>=3 ||
                    cycle_number-awb_last_cycle[raw_motion_results]!=11 ||
                    (^{dut.u_target_detect_switch.raw_motion_found,
                        dut.u_target_detect_switch.raw_motion_pixels,
                        dut.u_target_detect_switch.raw_motion_xmin,
                        dut.u_target_detect_switch.raw_motion_xmax,
                        dut.u_target_detect_switch.raw_motion_ymin,
                        dut.u_target_detect_switch.raw_motion_ymax})===1'bx)
                    $fatal(1,"Raw motion result timing/metadata mismatch frame=%0d",
                        raw_motion_results);
                if(raw_motion_results==0) begin
                    if(dut.u_target_detect_switch.raw_motion_found!==0 ||
                        dut.u_target_detect_switch.raw_motion_pixels!==0)
                        $fatal(1,"Raw motion warm-up produced a false target");
                end else if(dut.u_target_detect_switch.raw_motion_found!==1 ||
                    dut.u_target_detect_switch.raw_motion_pixels!==
                        (raw_motion_results==1 ? 19200 : 11520) ||
                    dut.u_target_detect_switch.raw_motion_xmin!==200 ||
                    dut.u_target_detect_switch.raw_motion_xmax!==
                        (raw_motion_results==1 ? 359 : 407) ||
                    dut.u_target_detect_switch.raw_motion_ymin!==184 ||
                    dut.u_target_detect_switch.raw_motion_ymax!==303 ||
                    dut.u_target_detect_switch.raw_motion_cx!==
                        (raw_motion_results==1 ? 279 : 303) ||
                    dut.u_target_detect_switch.raw_motion_cy!==243)
                    $fatal(1,"Raw motion rectangle result wrong frame=%0d",
                        raw_motion_results);
                raw_motion_results=raw_motion_results+1;
            end
            if(target_ready) begin
                if((^{target_found,target_pixels,xmin,xmax,ymin,ymax,cx,cy,
                    target_toggle,target_motion_mode})===1'bx)
                    $fatal(1,"Unknown target result metadata");
                if(target_results>=3 || target_toggle===previous_toggle ||
                    cycle_number-awb_last_cycle[target_results]!=TARGET_LATENCY ||
                    target_motion_mode !== (MOTION_MODE!=0))
                    $fatal(1,"Target result timing/frame/mode mismatch frame=%0d latency=%0d expected=%0d",
                        target_results,cycle_number-awb_last_cycle[target_results],TARGET_LATENCY);
                if(MOTION_MODE) begin
                    // Only two positive candidates have arrived. A stable
                    // track requires three compatible motion observations.
                    if(target_found!==0 || target_pixels!==0 ||
                        xmin!==0 || xmax!==0 || ymin!==0 || ymax!==0 || cx!==0 || cy!==0)
                        $fatal(1,"Unconfirmed motion candidate was displayed frame=%0d pixels=%0d box=%0d,%0d,%0d,%0d center=%0d,%0d",
                            target_results,target_pixels,xmin,xmax,ymin,ymax,cx,cy);
                end else if(target_results<2) begin
                    if(!target_found || target_pixels!=19196 ||
                        xmin!=(target_results==0?200:700) ||
                        xmax!=(target_results==0?359:859) ||
                        ymin!=(target_results==0?180:400) ||
                        ymax!=(target_results==0?299:519) ||
                        cx!=(target_results==0?279:779) ||
                        cy!=(target_results==0?239:459))
                        $fatal(1,"Red rectangle result wrong frame=%0d pixels=%0d box=%0d,%0d,%0d,%0d",
                            target_results,target_pixels,xmin,xmax,ymin,ymax);
                end else if(target_found || target_pixels!=0 ||
                    xmin!=0 || xmax!=0 || ymin!=0 || ymax!=0)
                    $fatal(1,"Pink/white/cool background produced a false target");
                previous_toggle=target_toggle;
                target_results=target_results+1;
            end
            if(output_user) begin
                if(!sampled_edge_user) $fatal(1,"Packed SOF changed latency");
                if(packed_frame>=0 && packed_count[packed_frame]!=FRAME_WORDS)
                    $fatal(1,"Packed preceding frame lost words");
                packed_frame=packed_frame+1;
            end
            if(output_valid) begin
                if(byte_write-byte_read<16)
                    $fatal(1,"Packer emitted bytes that were never accepted");
                sampled_frame=byte_tag[byte_read%128];
                if(sampled_frame!=packed_frame)
                    $fatal(1,"Packer data crossed a frame marker");
                for(byte_index=0;byte_index<16;byte_index=byte_index+1) begin
                    if(byte_tag[byte_read%128]!=sampled_frame ||
                        output_data[127-byte_index*8 -:8]!==byte_queue[byte_read%128])
                        $fatal(1,"128bit byte-order/packing mismatch");
                    byte_read=byte_read+1;
                    bytes_checked=bytes_checked+1;
                end
                packed_count[sampled_frame]=packed_count[sampled_frame]+1;
            end
        end
    end

    task automatic tick(input bit v,input bit u,input bit l,input [95:0] d);
        @(negedge clk);
        raw_valid=v;raw_user=u;raw_last=l;
        raw_data=v ? raw_scene(source_frame) : 40'd0;
        injected_valid=v;injected_user=u;injected_last=l;injected_data=d;
        @(posedge clk);#2;
    endtask
    integer f,y,g,i,raw_value,scaled;
    reg [39:0] metered_raw;
    initial begin
        force dut.m_aixs_tdata_96=injected_data;
        force dut.m_aixs_tvalid=injected_valid;
        force dut.m_aixs_tuser=injected_user;
        force dut.m_aixs_tlast=injected_last;
        for(f=0;f<3;f=f+1) begin
            awb_count[f]=0;edge_count[f]=0;packed_count[f]=0;
            awb_last_cycle[f]=-1;expected_sum[f]=0;
            expected_count[f]=0;expected_bright[f]=0;
            metered_raw=raw_scene(f);
            // Production RAW metering samples one four-pixel group per eight
            // groups on the two Bayer rows at row mod 8 = 0 and 1.
            for(y=0;y<H;y=y+1) for(g=0;g<GROUPS;g=g+1) begin
                if((y%8)<2 && (g%8)==0) for(i=0;i<4;i=i+1) begin
                    raw_value=metered_raw[i*10 +:10];
                    scaled=raw_value>>2;
                    expected_sum[f]=expected_sum[f]+(scaled>=192?192:scaled);
                    expected_count[f]=expected_count[f]+1;
                    if(scaled>=192)
                        expected_bright[f]=expected_bright[f]+1;
                end
            end
        end
        repeat(5) tick(0,0,0,0);
        @(negedge clk);rst_n=1;
        repeat(5) tick(0,0,0,0);
        for(f=0;f<3;f=f+1) begin
            source_frame=f;
            if(f==2) tick(0,1,0,0); // Early marker during blanking.
            for(y=0;y<H;y=y+1) begin
                for(g=0;g<GROUPS;g=g+1) begin
                    if(y==H/2 && g==0)
                        request_mode=f==0 ? 4'd2 :
                            (EMBOSS_MODE && f==1 ? 4'd4 : 4'd0);
                    tick(1,f!=2 && y==0 && g==0,g==GROUPS-1,scene_group(f,g,y));
                end
                repeat(4) tick(0,0,0,0); // Complete pack groups at every line.
            end
            // Allow the old frame's delayed pixels/results to drain before
            // the next early SOF can reset downstream frame state.
            repeat(64) tick(0,0,0,0);
        end
        repeat(100) tick(0,0,0,0);
        if(ae_results!=3 || target_results!=3 || (MOTION_MODE && raw_motion_results!=3) ||
            byte_write!=byte_read ||
            bytes_checked!=3*W*H*3 || white_pixels==0)
            $fatal(1,"ISP integration coverage/count mismatch");
        for(f=0;f<3;f=f+1)
            if(awb_count[f]!=FRAME_GROUPS || edge_count[f]!=FRAME_GROUPS ||
                packed_count[f]!=FRAME_WORDS)
                $fatal(1,"ISP frame%0d groups AWB=%0d edge=%0d packed=%0d",
                    f,awb_count[f],edge_count[f],packed_count[f]);
        if(EMBOSS_MODE && (emboss_pixels!=W*H ||
            emboss_bright==0 || emboss_dark==0 || emboss_neutral==0 ||
            (!MOTION_MODE && (emboss_white==0 || emboss_black==0))))
            $fatal(1,"Emboss ISP coverage incomplete pixels=%0d bright=%0d dark=%0d neutral=%0d white=%0d black=%0d",
                emboss_pixels,emboss_bright,emboss_dark,emboss_neutral,
                emboss_white,emboss_black);
        if(MOTION_MODE)
            $display("ISP_MOTION_INTEGRATION_PASS frames=3 awb_groups=%0d edge_groups=%0d packed_words=%0d bytes=%0d ae=%0d targets=%0d edge_white=%0d target_latency=%0d raw_results=%0d confirmed=0",
                3*FRAME_GROUPS,3*FRAME_GROUPS,3*FRAME_WORDS,bytes_checked,
                ae_results,target_results,white_pixels,TARGET_LATENCY,raw_motion_results);
        else
            $display("ISP_LIGHTING_INTEGRATION_PASS frames=3 awb_groups=%0d edge_groups=%0d packed_words=%0d bytes=%0d ae=%0d targets=%0d edge_white=%0d",
                3*FRAME_GROUPS,3*FRAME_GROUPS,3*FRAME_WORDS,bytes_checked,
                ae_results,target_results,white_pixels);
        if(EMBOSS_MODE)
            $display("ISP_EMBOSS_INTEGRATION_PASS frames=3 emboss_pixels=%0d bright=%0d dark=%0d neutral=%0d saturated_white=%0d saturated_black=%0d bytes=%0d ae=%0d targets=%0d motion=%0d",
                emboss_pixels,emboss_bright,emboss_dark,emboss_neutral,
                emboss_white,emboss_black,bytes_checked,ae_results,target_results,MOTION_MODE);
        $finish;
    end
    initial begin
        #15000000;
        $fatal(1,"ISP lighting integration timeout");
    end
endmodule

// A single inert boundary replaces sensor demosaic only; RAW AE still receives
// the real isp_top input, while forced RGB nets stimulate every later module.
module demosaic #(
    parameter IMG_HEIGHT=1080,IMG_WIDTH=1920,data_complete_delay=50,
    parameter BAYER_MODE="BGGR"
) (
    input wire I_clk,I_rst_n,
    input wire [39:0] axi4s_video_tdata,
    input wire [9:0] axi4s_video_tdest,
    input wire axi4s_video_tlast,axi4s_video_tvalid,axi4s_video_tuser,
    output wire axi4s_video_tready,
    output wire [9:0] O_frame_id,
    output wire O_tlast,O_tuser,O_tvalid,
    output wire [127:0] O_tdata,
    input wire O_tready
);
    assign axi4s_video_tready=O_tready;
    assign O_frame_id=axi4s_video_tdest;
    assign O_tlast=0;assign O_tuser=0;assign O_tvalid=0;assign O_tdata=0;
endmodule
