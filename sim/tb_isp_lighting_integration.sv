`timescale 1ns/1ps
// Real ISP wiring from the post-demosaic RGB boundary through AE metering,
// AWB, mode/Scharr, red detection and the byte packer. Camera RAW/MIPI and
// demosaic arithmetic are deliberately outside this integration test.
module tb_isp_lighting_integration;
    localparam integer W=1280, H=720, GROUPS=320;
    localparam integer FRAME_GROUPS=230400, FRAME_WORDS=172800;
    localparam integer AWB_LATENCY=54;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, request_edge=0;
    reg injected_valid=0, injected_user=0, injected_last=0;
    reg [95:0] injected_data=0;
    wire [127:0] output_data;
    wire output_valid, output_user, output_last, mode;
    wire target_ready, target_found, target_toggle;
    wire [11:0] xmin,xmax,ymin,ymax,cx,cy;
    wire [23:0] target_pixels;
    wire stats_valid;
    wire [31:0] sum_y;
    wire [15:0] sample_count, bright_count;
    isp_top #(.ENABLE_EDGE(0)) dut (
        .axi4s_video_aclk(clk),.I_rst_n(rst_n),.I_edge_mode_async(request_edge),
        .I_tlast(1'b0),.I_tuser(1'b0),.I_tdata(40'd0),.I_tvalid(1'b0),
        .I_tdest(10'd0),.O_tready(1'b1),.O_tdata(output_data),
        .O_tlast(output_last),.O_tuser(output_user),.O_tvalid(output_valid),
        .I_tready(),.O_target_result_ready(target_ready),.O_target_found(target_found),
        .O_target_xmin(xmin),.O_target_xmax(xmax),.O_target_ymin(ymin),
        .O_target_ymax(ymax),.O_target_center_x(cx),.O_target_center_y(cy),
        .O_target_pixels(target_pixels),.O_target_frame_toggle(target_toggle),
        .O_edge_mode_active(mode),.O_ae_stats_valid(stats_valid),
        .O_ae_sum_y(sum_y),.O_ae_sample_count(sample_count),
        .O_ae_bright_count(bright_count)
    );

    integer source_frame=-1, awb_frame=-1, edge_frame=-1, packed_frame=-1;
    integer awb_count[0:2], edge_count[0:2], packed_count[0:2];
    integer expected_sum[0:2], expected_bright[0:2];
    integer ae_results=0, target_results=0, bytes_checked=0;
    integer cycle_number=0, awb_last_cycle[0:2], white_pixels=0;
    reg [7:0] byte_queue[0:127];
    integer byte_tag[0:127];
    integer byte_write=0, byte_read=0;
    reg [AWB_LATENCY-1:0] reference_valid=0;
    reg [95:0] reference_data[0:AWB_LATENCY-1];
    reg [95:0] sampled_edge_data;
    reg sampled_edge_valid,sampled_edge_user,sampled_edge_mode;
    integer sampled_frame,byte_index,lane;
    integer reference_stage;
    bit previous_toggle=0;

    function automatic [23:0] scene(
        input integer frame_id,input integer x,input integer y
    );
        case (frame_id)
            0: scene = x>=200 && x<=359 && y>=180 && y<=299 ?
                       24'hc8231e : 24'h8c6e64;
            1: scene = x>=700 && x<=859 && y>=400 && y<=519 ?
                       24'h320f0c : 24'hffaaBE;
            default: scene = x<128 && y<80 ? 24'hffffff : 24'h646e8c;
        endcase
    endfunction
    function automatic [95:0] scene_group(
        input integer frame_id,input integer group_id,input integer row_id
    );
        integer n;
        for(n=0;n<4;n=n+1)
            scene_group[95-n*24 -:24]=scene(frame_id,group_id*4+n,row_id);
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
            rg=frame_id==2 ? 249 : 256;
            bg=frame_id==2 ? 260 : 256;
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
                if(ae_results>=3 || sample_count!=7200 ||
                    sum_y!=expected_sum[ae_results] ||
                    bright_count!=expected_bright[ae_results])
                    $fatal(1,"AE stats wrong frame=%0d sum=%0d samples=%0d bright=%0d",
                        ae_results,sum_y,sample_count,bright_count);
                ae_results=ae_results+1;
            end
            if(target_ready) begin
                if(target_results>=3 || target_toggle===previous_toggle ||
                    cycle_number-awb_last_cycle[target_results]!=6)
                    $fatal(1,"Target result timing/frame mismatch");
                if(target_results<2) begin
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
        injected_valid=v;injected_user=u;injected_last=l;injected_data=d;
        @(posedge clk);#2;
    endtask
    integer f,y,g,i,r,b,green,lum;
    reg [23:0] metered;
    initial begin
        force dut.m_aixs_tdata_96=injected_data;
        force dut.m_aixs_tvalid=injected_valid;
        force dut.m_aixs_tuser=injected_user;
        force dut.m_aixs_tlast=injected_last;
        for(f=0;f<3;f=f+1) begin
            awb_count[f]=0;edge_count[f]=0;packed_count[f]=0;
            awb_last_cycle[f]=-1;expected_sum[f]=0;expected_bright[f]=0;
            for(y=0;y<H;y=y+4) for(g=0;g<GROUPS;g=g+8) begin
                metered=scene(f,g*4,y);
                r=metered[23:16];green=metered[15:8];b=metered[7:0];
                lum=(r+2*green+b)/4;
                // AE meters the surroundings independently of white lights.
                // A saturated single color remains a usable luma sample.
                if(lum>=232)
                    expected_bright[f]=expected_bright[f]+1;
                else
                    expected_sum[f]=expected_sum[f]+lum;
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
                        request_edge=(f==0); // Request changes mid-frame.
                    tick(1,f!=2 && y==0 && g==0,g==GROUPS-1,scene_group(f,g,y));
                end
                repeat(4) tick(0,0,0,0); // Complete pack groups at every line.
            end
            // Allow the old frame's delayed pixels/results to drain before
            // the next early SOF can reset downstream frame state.
            repeat(64) tick(0,0,0,0);
        end
        repeat(100) tick(0,0,0,0);
        if(ae_results!=3 || target_results!=3 || byte_write!=byte_read ||
            bytes_checked!=3*W*H*3 || white_pixels==0)
            $fatal(1,"ISP integration coverage/count mismatch");
        for(f=0;f<3;f=f+1)
            if(awb_count[f]!=FRAME_GROUPS || edge_count[f]!=FRAME_GROUPS ||
                packed_count[f]!=FRAME_WORDS)
                $fatal(1,"ISP frame%0d groups AWB=%0d edge=%0d packed=%0d",
                    f,awb_count[f],edge_count[f],packed_count[f]);
        $display("ISP_LIGHTING_INTEGRATION_PASS frames=3 awb_groups=%0d edge_groups=%0d packed_words=%0d bytes=%0d ae=%0d targets=%0d edge_white=%0d",
            3*FRAME_GROUPS,3*FRAME_GROUPS,3*FRAME_WORDS,bytes_checked,
            ae_results,target_results,white_pixels);
        $finish;
    end
    initial begin
        #15000000;
        $fatal(1,"ISP lighting integration timeout");
    end
endmodule

// A single inert boundary replaces sensor demosaic only; every subsequent
// processing module is its production RTL. Forced RGB nets supply stimulus.
module demosaic #(
    parameter IMG_HEIGHT=1080,IMG_WIDTH=1920,data_complete_delay=50,
    parameter BAYER_MODE="BGGR"
) (
    input wire I_clk,I_rst_n,
    input wire [39:0] axi4s_video_tdata,
    input wire [9:0] axi4s_video_tdest,
    input wire axi4s_video_tlast,axi4s_video_tvalid,axi4s_video_tuser,
    output wire axi4s_video_tready,
    output wire O_tlast,O_tuser,O_tvalid,
    output wire [127:0] O_tdata,
    input wire O_tready
);
    assign axi4s_video_tready=O_tready;
    assign O_tlast=0;assign O_tuser=0;assign O_tvalid=0;assign O_tdata=0;
endmodule
