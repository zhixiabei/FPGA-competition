`timescale 1ns/1ps
module tb_iq_diagnostic_stats #(
    parameter integer WIDTH=64, HEIGHT=16, BLACK=64,
    parameter integer BAYER=0, MESH=0, LSC_ENABLE=1, FULL_SUITE=1
);
    localparam integer GROUPS=WIDTH/4, BEATS=GROUPS*HEIGHT;
    localparam BAYER_NAME=BAYER==0 ? "BGGR" : BAYER==1 ? "RGGB" :
        BAYER==2 ? "GBRG" : "GRBG";
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, valid=0, user=0, last=0, source_end=0;
    reg [39:0] raw_data=0;
    reg [95:0] rgb_data=0;
    reg [9:0] frame_id=0;
    wire lsc_valid,lsc_user,lsc_last;
    wire [39:0] lsc_data;
    wire [3:0] lsc_clip;
    wire [39:0] lsc_off_data;
    wire [3:0] lsc_off_clip;
    reg [9:0] id_pipe[0:2];
    reg [1:0] wb_valid=0, wb_user=0, wb_last=0;
    reg [95:0] wb_data0=0,wb_data1=0;
    reg [7:0] wb_clip0=0,wb_clip1=0;
    reg [9:0] wb_id0=0,wb_id1=0;
    reg [3:0] stats_delay=0;
    reg raw_user_d=0;
    reg [9:0] hist_frame_id=0;
    wire hist_valid;
    wire [31:0] hist_sum;
    wire [15:0] hist_count,hist_near,hist_clip;
    wire [4:0] hist_p5,hist_p50,hist_p95,hist_p99;
    wire diag_valid,disabled_valid;
    wire [127:0] diag_data,disabled_data;
    reg [39:0] expected_lsc[0:2];
    reg [3:0] expected_lsc_clip[0:2];
    reg [2:0] expected_valid=0;
    integer tag_driven=0, pattern_driven=0, beat_driven=0;
    integer pixel_checks=0,packet_checks=0;
    integer ref_count[0:15][0:3][0:3];
    integer ref_sum[0:15][0:3][0:3];
    integer ref_near[0:15][0:3][0:3];
    integer ref_clip[0:15][0:3][0:3];
    integer ref_black[0:15][0:3][0:3];
    reg [127:0] expected_packet[0:15][0:5][0:3];
    bit expected_present[0:15][0:5][0:3];
    bit seen[0:15][0:5][0:3];
    integer total_expected=0;
    integer histogram[0:31];
    integer q5,q50,q95,q99,hcount,hnear,hclip,cumulative;
    integer sampled_lane;

    lsc_raw10_4x #(
        .IMG_WIDTH(WIDTH),.IMG_HEIGHT(HEIGHT),.BAYER_MODE(BAYER_NAME),
        .ENABLE(LSC_ENABLE),.BLACK_LEVEL(BLACK),
        .EDGE_R_Q8(64),.EDGE_GR_Q8(32),.EDGE_GB_Q8(16),.EDGE_B_Q8(128),
        .EDGE_Y_GR_Q8(0),.EDGE_Y_GB_Q8(0),.MESH_ENABLE(MESH),
        .MESH_GR_Q8({9{8'd224}}),.MESH_GB_Q8({9{8'd192}}),
        .MESH_B_Q8({9{9'd288}}),.DIAGNOSTIC_ENABLE(1)
    ) lsc (
        .I_clk(clk),.I_rst_n(rst_n),.I_tdata(raw_data),.I_tvalid(valid),
        .I_tuser(user),.I_tlast(last),.I_tready(),.O_tdata(lsc_data),
        .O_tvalid(lsc_valid),.O_tuser(lsc_user),.O_tlast(lsc_last),
        .O_tready(1'b1),.O_diag_clip_new(lsc_clip)
    );
    lsc_raw10_4x #(
        .IMG_WIDTH(WIDTH),.IMG_HEIGHT(HEIGHT),.BAYER_MODE(BAYER_NAME),
        .ENABLE(LSC_ENABLE),.BLACK_LEVEL(BLACK),
        .EDGE_R_Q8(64),.EDGE_GR_Q8(32),.EDGE_GB_Q8(16),.EDGE_B_Q8(128),
        .EDGE_Y_GR_Q8(0),.EDGE_Y_GB_Q8(0),.MESH_ENABLE(MESH),
        .MESH_GR_Q8({9{8'd224}}),.MESH_GB_Q8({9{8'd192}}),
        .MESH_B_Q8({9{9'd288}})
    ) lsc_default_off (
        .I_clk(clk),.I_rst_n(rst_n),.I_tdata(raw_data),.I_tvalid(valid),
        .I_tuser(user),.I_tlast(last),.I_tready(),.O_tdata(lsc_off_data),
        .O_tvalid(),.O_tuser(),.O_tlast(),.O_tready(1'b1),
        .O_diag_clip_new(lsc_off_clip)
    );
    ae_frame_stats_raw10_4x #(
        .IMG_WIDTH(WIDTH),.IMG_HEIGHT(HEIGHT),.BLACK_LEVEL(BLACK),
        .BRIGHT_LEVEL(248),.HISTOGRAM_ENABLE(1),.HOLD_OUTPUTS(0)
    ) histogram_dut (
        .I_clk(clk),.I_rst_n(rst_n),.I_tuser(user),.I_tlast(last),
        .I_tvalid(valid),.I_tdata(raw_data),.O_stats_valid(hist_valid),
        .O_sum_y(hist_sum),.O_sample_count(hist_count),.O_bright_count(hist_near),
        .O_p5(hist_p5),.O_p50(hist_p50),.O_p95(hist_p95),.O_p99(hist_p99),
        .O_clip_count(hist_clip)
    );
    iq_diagnostic_stats #(
        .ENABLE(1),.IMG_WIDTH(WIDTH),.IMG_HEIGHT(HEIGHT),
        .BAYER_MODE(BAYER_NAME),.BLACK_LEVEL(BLACK)
    ) dut (
        .I_clk(clk),.I_rst_n(rst_n),
        .I_raw_valid(valid),.I_raw_user(user),.I_raw_last(last),
        .I_raw_data(raw_data),.I_raw_frame_id(frame_id),
        .I_lsc_valid(lsc_valid),.I_lsc_user(lsc_user),.I_lsc_last(lsc_last),
        .I_lsc_data(lsc_data),.I_lsc_clip_new(lsc_clip),.I_lsc_frame_id(id_pipe[2]),
        .I_rgb_valid(valid),.I_rgb_user(user),.I_rgb_last(last),
        .I_rgb_data(rgb_data),.I_rgb_frame_id(frame_id),
        .I_awb_valid(wb_valid[1]),.I_awb_user(wb_user[1]),.I_awb_last(wb_last[1]),
        .I_awb_data(wb_data1),.I_awb_clip_new(wb_clip1),.I_awb_frame_id(wb_id1),
        .I_awb_gain_r_q8(11'd512),.I_awb_gain_b_q8(11'd384),
        .I_awb_stats_valid(stats_delay[3]),.I_awb_candidate_valid(1'b1),
        .I_awb_sample_count((BEATS+15)/16),
        .I_hist_valid(hist_valid),.I_hist_frame_id(hist_frame_id),
        .I_hist_p5(hist_p5),.I_hist_p50(hist_p50),.I_hist_p95(hist_p95),
        .I_hist_p99(hist_p99),.I_hist_count(hist_count),
        .I_hist_near_count(hist_near),.I_hist_clip_count(hist_clip),
        .O_diag_valid(diag_valid),.O_diag_data(diag_data)
    );
    iq_diagnostic_stats #(.IMG_WIDTH(WIDTH),.IMG_HEIGHT(HEIGHT)) disabled (
        .I_clk(clk),.I_rst_n(rst_n),.I_raw_valid(valid),.I_raw_user(user),
        .I_raw_last(last),.I_raw_data(raw_data),.I_raw_frame_id(frame_id),
        .O_diag_valid(disabled_valid),.O_diag_data(disabled_data)
    );
    function automatic integer colour(input integer row,input integer lane);
        bit red_row,green_even;
        begin
            red_row=(BAYER==1 || BAYER==3) ^ (row&1);
            green_even=(BAYER==2 || BAYER==3) ^ (row&1);
            colour=(lane&1)==(green_even ? 0 : 1) ?
                (red_row ? 1 : 2) : (red_row ? 0 : 3);
        end
    endfunction
    function automatic integer raw_pixel(input integer pattern,input integer row,
                                          input integer group_no,input integer lane);
        case(pattern)
            1: raw_pixel=1023;
            2: raw_pixel=0;
            default: case((lane+row+group_no/8)%6)
                0:raw_pixel=1023; 1:raw_pixel=992; 2:raw_pixel=991;
                3:raw_pixel=BLACK>0 ? BLACK-1 : 0;
                4:raw_pixel=768; default:raw_pixel=400;
            endcase
        endcase
    endfunction
    function automatic integer corrected_raw(input integer p,input integer row,
                                              input integer group_no,input integer lane);
        integer channel,strength,gain,distance,total,signal_value;
        begin
            channel=colour(row,lane);
            signal_value=p>BLACK ? p-BLACK : 0;
            if (!LSC_ENABLE) total=p;
            else if (MESH) begin
                gain=channel==0 ? 256 : channel==1 ? 224 : channel==2 ? 192 : 288;
                total=((signal_value*gain+128)>>8)+(p>BLACK ? BLACK : p);
            end else begin
                strength=channel==0 ? 64 : channel==1 ? 32 : channel==2 ? 16 : 128;
                distance=GROUPS-1-2*group_no;
                gain=GROUPS>1 ? (strength*distance*distance+(GROUPS-1)*(GROUPS-1)/2)/
                    ((GROUPS-1)*(GROUPS-1)) : 0;
                total=p+((signal_value*gain+128)>>8);
            end
            corrected_raw=total;
        end
    endfunction
    function automatic [23:0] rgb_pixel(input integer pattern,input integer beat,
                                        input integer lane);
        integer r,g,b;
        begin
            r=pattern==1 ? 255 : (37*beat+51*lane+97)%256;
            g=pattern==1 ? 255 : (17*beat+11*lane+248)%256;
            b=pattern==1 ? 255 : (23*beat+73*lane+171)%256;
            rgb_pixel={r[7:0],g[7:0],b[7:0]};
        end
    endfunction
    function automatic [23:0] corrected_rgb(input [23:0] p);
        integer r,b;
        begin
            r=p[23:16]*2; b=p[7:0]*384/256;
            corrected_rgb={8'(r>255 ? 255 : r),p[15:8],8'(b>255 ? 255 : b)};
        end
    endfunction
    function automatic [127:0] channel_packet(input integer kind,input integer channel,
        input integer tag,input integer number,input integer total,
        input integer near_value,input integer clip_value,input integer black_value);
        channel_packet={4'(kind),2'(channel),10'(tag),16'(number),24'(total),
            16'(near_value),16'(clip_value),16'(black_value),24'd0};
    endfunction

    integer pl,pv,po,pr,pg,pc;
    integer lsc_ref_group=0;
    bit lsc_ref_odd=0;
    reg [23:0] rgb_component;
    reg [39:0] predicted;
    reg [3:0] predicted_clip;
    always @(posedge clk) begin
        if (!rst_n) begin
            for(pl=0;pl<3;pl=pl+1) begin
                id_pipe[pl]<=0; expected_lsc[pl]<=0; expected_lsc_clip[pl]<=0;
            end
            expected_valid<=0;
            wb_valid<=0;wb_user<=0;wb_last<=0;
            wb_data0<=0;wb_data1<=0;wb_clip0<=0;wb_clip1<=0;
            wb_id0<=0;wb_id1<=0;stats_delay<=0;
            raw_user_d<=0;hist_frame_id<=0;
            lsc_ref_group=0;lsc_ref_odd=0;
        end else begin
            id_pipe[0]<=frame_id; id_pipe[1]<=id_pipe[0]; id_pipe[2]<=id_pipe[1];
            raw_user_d<=user;
            if(user && !raw_user_d) hist_frame_id<=frame_id;
            wb_valid<={wb_valid[0],valid};wb_user<={wb_user[0],user};
            wb_last<={wb_last[0],last};wb_id0<=frame_id;wb_id1<=wb_id0;
            stats_delay<={stats_delay[2:0],source_end};
            for(pl=0;pl<4;pl=pl+1) begin
                wb_data0[24*pl+:24]<=corrected_rgb(rgb_data[24*pl+:24]);
                wb_clip0[2*pl+1]<=rgb_data[24*pl+16+:8]*2>255;
                wb_clip0[2*pl]<=rgb_data[24*pl+:8]*384/256>255;
            end
            wb_data1<=wb_data0;wb_clip1<=wb_clip0;
            // LSC follows the received SOF/TLAST even for malformed frames;
            // the diagnostic frame validators must independently reject them.
            if(user) begin lsc_ref_group=0;lsc_ref_odd=0; end
            predicted=0; predicted_clip=0;
            for(pl=0;pl<4;pl=pl+1) begin
                pv=corrected_raw(raw_data[10*pl+:10],
                    lsc_ref_odd,lsc_ref_group,pl);
                predicted[10*pl+:10]=pv>1023 ? 1023 : pv;
                predicted_clip[pl]=pv>1023;
            end
            expected_lsc[0]<=predicted;expected_lsc[1]<=expected_lsc[0];
            expected_lsc[2]<=expected_lsc[1];
            expected_lsc_clip[0]<=predicted_clip;
            expected_lsc_clip[1]<=expected_lsc_clip[0];
            expected_lsc_clip[2]<=expected_lsc_clip[1];
            expected_valid<={expected_valid[1:0],valid};
            if(valid) begin
                if(last || lsc_ref_group==GROUPS-1) begin
                    lsc_ref_group=0;lsc_ref_odd=!lsc_ref_odd;
                end else lsc_ref_group++;
            end
        end
        #1;
        if(disabled_valid!==0 || disabled_data!==0 || lsc_off_clip!==0)
            $fatal(1,"Default-off diagnostic outputs must remain zero");
        if(rst_n && lsc_data!==lsc_off_data)
            $fatal(1,"Diagnostic LSC changed the production pixel path");
        if(rst_n && lsc_valid) begin
            if(expected_valid[2]!==1 || lsc_data!==expected_lsc[2] ||
                lsc_clip!==expected_lsc_clip[2])
                $fatal(1,"LSC arithmetic flag alignment/data mismatch actual=%h/%h expected=%h/%h",
                    lsc_data,lsc_clip,expected_lsc[2],expected_lsc_clip[2]);
            pixel_checks=pixel_checks+4;
        end
        if(rst_n && diag_valid) begin
            pr=diag_data[127:124]; pg=diag_data[123:122]; pc=diag_data[121:112];
            if(pc>=16 || pr>=6 || !expected_present[pc][pr][pg] || seen[pc][pr][pg])
                $fatal(1,"Unexpected/duplicate/invalid-frame packet kind=%0d channel=%0d tag=%0d",pr,pg,pc);
            if(diag_data!==expected_packet[pc][pr][pg])
                $fatal(1,"Diagnostic packet mismatch kind=%0d channel=%0d tag=%0d got=%h expected=%h",
                    pr,pg,pc,diag_data,expected_packet[pc][pr][pg]);
            seen[pc][pr][pg]=1;
            packet_checks=packet_checks+1;
        end
    end
    task automatic prepare(input integer tag,input integer pattern);
        integer beat,row,group_no,lane,ch,raw,total,clipped,signal_value;
        integer kind,channel,value,clip_value;
        reg [23:0] rgb,wb;
        begin
            for(kind=0;kind<4;kind=kind+1) for(channel=0;channel<4;channel=channel+1) begin
                ref_count[tag][kind][channel]=0;ref_sum[tag][kind][channel]=0;
                ref_near[tag][kind][channel]=0;ref_clip[tag][kind][channel]=0;
                ref_black[tag][kind][channel]=0;
            end
            for(ch=0;ch<32;ch=ch+1) histogram[ch]=0;
            hcount=0;hnear=0;hclip=0;sampled_lane=0;
            for(beat=0;beat<BEATS;beat=beat+1) begin
                row=beat/GROUPS;group_no=beat%GROUPS;
                if(row%8<2 && group_no%8==0) for(lane=0;lane<4;lane=lane+1) begin
                    ch=colour(row,lane);raw=raw_pixel(pattern,row,group_no,lane);
                    total=corrected_raw(raw,row,group_no,lane);
                    clipped=total>1023 ? 1023 : total;
                    signal_value=raw>BLACK ? raw-BLACK : 0;
                    histogram[signal_value/32]=histogram[signal_value/32]+1;
                    hcount=hcount+1;hnear=hnear+(signal_value>=992);hclip=hclip+(raw==1023);
                    for(kind=0;kind<2;kind=kind+1) begin
                        value=kind==0 ? raw : clipped;
                        ref_count[tag][kind][ch]++;
                        ref_sum[tag][kind][ch]+=value;
                        ref_near[tag][kind][ch]+=(value>=992);
                        ref_clip[tag][kind][ch]+=(kind==0 ? raw==1023 : total>1023);
                        ref_black[tag][kind][ch]+=(kind==0 ? signal_value>=992 : value>=992);
                    end
                end
                if(beat%16==0) begin
                    rgb=rgb_pixel(pattern,beat,sampled_lane);
                    wb=corrected_rgb(rgb);
                    for(kind=2;kind<4;kind=kind+1) for(channel=0;channel<3;channel=channel+1) begin
                        ch=channel==2 ? 3 : channel;
                        value=kind==2 ? rgb[(2-channel)*8+:8] : wb[(2-channel)*8+:8];
                        clip_value=kind==2 ? value==255 : channel==0 ? rgb[23:16]*2>255 :
                            channel==2 ? rgb[7:0]*384/256>255 : 0;
                        ref_count[tag][kind][ch]++;
                        ref_sum[tag][kind][ch]+=value;
                        ref_near[tag][kind][ch]+=(value>=248);
                        ref_clip[tag][kind][ch]+=clip_value;
                    end
                    sampled_lane=(sampled_lane+1)%4;
                end
            end
            for(kind=0;kind<4;kind=kind+1) for(channel=0;channel<4;channel=channel+1)
                if(kind<2 || channel!=2) begin
                    expected_present[tag][kind][channel]=1;total_expected++;
                    expected_packet[tag][kind][channel]=channel_packet(kind,channel,tag,
                        ref_count[tag][kind][channel],ref_sum[tag][kind][channel],
                        ref_near[tag][kind][channel],ref_clip[tag][kind][channel],
                        ref_black[tag][kind][channel]);
                end
            q5=-1;q50=-1;q95=-1;q99=-1;cumulative=0;
            for(ch=0;ch<32;ch=ch+1) begin
                cumulative+=histogram[ch];
                if(q5<0 && cumulative>=(hcount*5+99)/100) q5=ch;
                if(q50<0 && cumulative>=(hcount+1)/2) q50=ch;
                if(q95<0 && cumulative>=(hcount*95+99)/100) q95=ch;
                if(q99<0 && cumulative>=(hcount*99+99)/100) q99=ch;
            end
            expected_present[tag][4][0]=1;total_expected++;
            expected_packet[tag][4][0]={4'd4,2'd0,10'(tag),5'(q5),5'(q50),5'(q95),5'(q99),
                16'(hcount),16'(hnear),16'(hclip),44'd0};
            expected_present[tag][5][0]=1;total_expected++;
            expected_packet[tag][5][0]={4'd5,2'd0,10'(tag),11'd512,11'd384,1'b1,
                16'((BEATS+15)/16),73'd0};
        end
    endtask
    task automatic tick(input bit v,input bit u,input bit l,input integer tag,
                         input integer beat,input integer pattern,input bit eof);
        integer lane;
        begin
            @(negedge clk);
            valid=v;user=u;last=l;frame_id=tag;source_end=eof;beat_driven=beat;
            for(lane=0;lane<4;lane=lane+1) begin
                raw_data[10*lane+:10]=raw_pixel(pattern,beat/GROUPS,beat%GROUPS,lane);
                rgb_data[24*lane+:24]=rgb_pixel(pattern,beat,lane);
            end
            @(posedge clk);#2;
        end
    endtask
    task automatic idle(input integer clocks);
        repeat(clocks) tick(0,0,0,15,0,0,0);
    endtask
    task automatic frame(input integer tag,input integer pattern,input bit early,
                          input integer bad_beat=-1,input integer length=BEATS,
                          input bit bubbles=0);
        integer beat;
        begin
            if(early) begin tick(0,1,0,tag,0,pattern,0);idle(2); end
            for(beat=0;beat<length;beat=beat+1) begin
                tick(1,!early && beat==0,(beat%GROUPS==GROUPS-1) ^ (beat==bad_beat),
                    tag,beat,pattern,beat==BEATS-1);
                if(bubbles && beat%19==7) idle(1);
            end
        end
    endtask
    integer t,k,c,guard;
    initial begin
        for(t=0;t<16;t=t+1) for(k=0;k<6;k=k+1) for(c=0;c<4;c=c+1) begin
            expected_present[t][k][c]=0;seen[t][k][c]=0;
        end
        idle(5);@(negedge clk);rst_n=1;idle(40);
        prepare(1,0);frame(1,0,0,-1,BEATS,1);idle(24);
        prepare(2,1);frame(2,1,1);idle(24);
        if(FULL_SUITE) begin
            frame(3,0,0,GROUPS+1);idle(24);
            frame(4,1,1,-1,BEATS/3);
            prepare(5,0);
            // The premature SOF restarts the histogram clear and discards
            // this recovery frame. Other diagnostic banks remain valid.
            expected_present[5][4][0]=0;total_expected--;
            frame(5,0,0);idle(24);
            frame(6,1,0,-1,BEATS/4);
            @(negedge clk);rst_n=0;
            idle(5);@(negedge clk);rst_n=1;idle(40);
            prepare(7,1);frame(7,1,0);idle(24);
            // Extra unmarked data must not create another complete frame.
            repeat(17) tick(1,0,0,15,0,0,0);
            idle(24);
            prepare(8,2);frame(8,2,1);idle(24);
            // The valid-only AE outputs are consumed on the same clock as
            // the following frame's first beat/SOF resets its accumulators.
            prepare(9,0);prepare(10,1);
            frame(9,0,0);frame(10,1,0);idle(24);
        end
        guard=0;
        while(packet_checks<total_expected && guard<200) begin idle(1);guard++; end
        for(t=0;t<16;t=t+1) for(k=0;k<6;k=k+1) for(c=0;c<4;c=c+1)
            if(expected_present[t][k][c] && !seen[t][k][c])
                $fatal(1,"Missing kind/channel/tag %0d/%0d/%0d",k,c,t);
        if(packet_checks!=total_expected)
            $fatal(1,"Missing diagnostic packets checked=%0d expected=%0d",packet_checks,total_expected);
        $display("IQ_DIAGNOSTIC_STATS_PASS width=%0d height=%0d bayer=%0d black=%0d mesh=%0d lsc=%0d packets=%0d pixels=%0d",
            WIDTH,HEIGHT,BAYER,BLACK,MESH,LSC_ENABLE,packet_checks,pixel_checks);
        $finish;
    end
    initial begin #100000000; $fatal(1,"Diagnostic simulation timeout"); end
endmodule
