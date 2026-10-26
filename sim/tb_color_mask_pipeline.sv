`timescale 1ns/1ps
// Real color/target switch and spatial RGB selector. The oracle computes
// centred two-dimensional binary images without using any DUT tap or helper.
module tb_color_mask_pipeline #(
    parameter integer W=64, H=48, COLOR_COUNT=4
);
    localparam integer GROUPS=W/4, LAT=11;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, user=0, valid=0, last=0;
    reg [95:0] data=0;
    reg [11:0] requested_config=0;
    reg [1:0] requested_color=0;
    reg [9:0] frame_id=0;
    wire [3:0] mask_pixels;
    wire [95:0] out_data;
    wire out_user,out_valid,out_last,out_edge,active_motion;
    wire [1:0] active_color;
    wire [11:0] out_config;
    target_detect_switch_96 #(
        .IMG_WIDTH(W),.IMG_HEIGHT(H),.RED_MIN_PIXELS(8),
        .MOTION_STABLE_ENABLE(0),.RED_MULTI_ENABLE(0)
    ) target (
        .I_clk(clk),.I_rst_n(rst_n),.I_motion_mode_async(requested_color==3),
        .I_color_mode_async(requested_color),.I_effect_config(requested_config),
        .I_tuser(user),.I_tlast(last),.I_tvalid(valid),.I_tdata(data),
        .I_frame_id(frame_id),.O_mask_pixels(mask_pixels),
        .O_motion_mode_active(active_motion),.O_color_mode_active(active_color),
        .O_result_ready(),.O_found(),.O_xmin(),.O_xmax(),.O_ymin(),.O_ymax(),
        .O_center_x(),.O_center_y(),.O_pixels(),.O_frame_toggle(),
        .O_target_motion_mode(),.O_target_color_mode(),.O_result_frame_id(),
        .O_multi_valid(),.O_multi_hold(),.O_multi_boxes(),.O_multi_shapes(),
        .O_multi_overflow()
    );
    rgb_edge_switch_96 #(
        .IMG_WIDTH(W),.IMG_HEIGHT(H),.DEFAULT_EDGE_MODE(0)
    ) selector (
        .I_clk(clk),.I_rst_n(rst_n),.I_effect_config(requested_config),
        .I_tuser(user),.I_tlast(last),.I_tvalid(valid),.I_tdata(data),
        .I_mask_pixels(mask_pixels),.O_tdata(out_data),.O_tuser(out_user),
        .O_tlast(out_last),.O_tvalid(out_valid),.O_edge_mode(out_edge),
        .O_effect_config(out_config)
    );

    reg [23:0] image [0:W*H-1];
    reg raw_mask [0:W*H-1],majority_mask [0:W*H-1];
    reg raw_eroded [0:W*H-1],raw_dilated [0:W*H-1];
    reg smooth_dilated [0:W*H-1],clean_mask [0:W*H-1];
    reg [95:0] expected_data [0:LAT-1];
    reg [11:0] expected_config [0:LAT-1];
    reg expected_valid [0:LAT-1],expected_user [0:LAT-1];
    reg expected_last [0:LAT-1];
    reg [3:0] input_mask=0;
    reg [3:0] frame_mode=0;
    reg [11:0] reference_active_config=0;
    integer checks=0,pixels=0,frames=0,bubbles=0,early_markers=0;
    integer live_changes=0,white_pixels=0,black_pixels=0,filtered_changes=0;
    integer mode_pixels [9:12];
    reg [3:0] colors_seen=0;
    integer iteration,mode_index,color_index,phase;

    function automatic bit reference_color(input [23:0] value,input integer color);
        integer r,g,b,d,a,c;
        begin
            r=value[23:16];g=value[15:8];b=value[7:0];
            case(color)
                1: begin d=g;a=r;c=b; end
                2: begin d=b;a=r;c=g; end
                default: begin d=r;a=g;c=b; end
            endcase
            reference_color=d>=24 && d-a>=6 && d-c>=6 &&
                (color==1 ? (4*d>=5*a && 4*d>=5*c) :
                (2*d>=3*a && 2*d>=3*c && 3*a<=d+2*c && 3*c<=d+2*a));
        end
    endfunction
    function automatic [23:0] primary(input integer color,input bit dim);
        begin
            case(color)
                1: primary=dim ? 24'h203c0c : 24'h50961e;
                2: primary=dim ? 24'h0c0f32 : 24'h2020f0;
                default: primary=dim ? 24'h320f0c : 24'hf02020;
            endcase
        end
    endfunction
    task automatic build_reference(input integer color,input integer seed);
        integer x,y,dx,dy,votes,index;
        reg [23:0] foreground;
        begin
            foreground=primary(color,seed%2);
            for(y=0;y<H;y=y+1) for(x=0;x<W;x=x+1) begin
                index=y*W+x;
                // Every lane sees both outcomes. The frame edges, small
                // holes, narrow gaps and isolated specks stress all windows.
                image[index]=(x>=8 && x<W/2-3 && y>=8 && y<H-8) ||
                    ((x-3*W/4)*(x-3*W/4)+(y-H/2)*(y-H/2)<(H/4)*(H/4)) ?
                    foreground : 24'h101010;
                if(y==H/2 && x>=12 && x<=13) image[index]=24'hffffff;
                if(y==H/2+1 && x>=12 && x<=13) image[index]=24'he0e0e0;
                if((x+seed)%13==0 && (y+2*seed)%11==0)
                    image[index]=primary((color+1)%3,0);
                if((x+seed)%17==0 && (y+seed)%7==0)
                    image[index]=foreground;
                if(y<3 && x<11) image[index]=foreground;
                if(y>=H-3 && x>=W-11) image[index]=foreground;
                raw_mask[index]=reference_color(image[index],color);
                raw_eroded[index]=0;raw_dilated[index]=0;
                majority_mask[index]=0;smooth_dilated[index]=0;clean_mask[index]=0;
            end
            // Centred operators with a complete support window. Their output
            // is shifted only when converting to the causal video position.
            for(y=1;y<H-1;y=y+1) for(x=1;x<W-1;x=x+1) begin
                votes=0;
                for(dy=-1;dy<=1;dy=dy+1) for(dx=-1;dx<=1;dx=dx+1)
                    votes=votes+raw_mask[(y+dy)*W+x+dx];
                raw_eroded[y*W+x]=votes==9;
                raw_dilated[y*W+x]=votes!=0;
                majority_mask[y*W+x]=votes>=5;
            end
            for(y=2;y<H-2;y=y+1) for(x=2;x<W-2;x=x+1) begin
                votes=0;
                for(dy=-1;dy<=1;dy=dy+1) for(dx=-1;dx<=1;dx=dx+1)
                    votes=votes+majority_mask[(y+dy)*W+x+dx];
                smooth_dilated[y*W+x]=votes!=0;
            end
            for(y=3;y<H-3;y=y+1) for(x=3;x<W-3;x=x+1) begin
                votes=0;
                for(dy=-1;dy<=1;dy=dy+1) for(dx=-1;dx<=1;dx=dx+1)
                    votes=votes+smooth_dilated[(y+dy)*W+x+dx];
                clean_mask[y*W+x]=votes==9;
            end
            for(y=3;y<H-3;y=y+1) for(x=3;x<W-3;x=x+1)
                if(clean_mask[y*W+x]!=raw_mask[y*W+x])
                    filtered_changes=filtered_changes+1;
        end
    endtask
    function automatic bit preview(input integer x,input integer y,input integer mode);
        begin
            case(mode)
                10: preview=x>=2 && y>=2 ? raw_eroded[(y-1)*W+x-1] : 0;
                11: preview=x>=2 && y>=2 ? raw_dilated[(y-1)*W+x-1] : 0;
                12: preview=x>=6 && y>=6 ? clean_mask[(y-3)*W+x-3] : 0;
                default: preview=raw_mask[y*W+x];
            endcase
        end
    endfunction
    always @(posedge clk) begin : check_pipeline
        integer stage,lane;
        if(!rst_n) begin
            reference_active_config=0;
            for(stage=0;stage<LAT;stage=stage+1) begin
                expected_valid[stage]=0;expected_user[stage]=0;expected_last[stage]=0;
                expected_config[stage]=0;expected_data[stage]=0;
            end
        end else begin
            for(stage=LAT-1;stage>0;stage=stage-1) begin
                expected_valid[stage]=expected_valid[stage-1];
                expected_user[stage]=expected_user[stage-1];
                expected_last[stage]=expected_last[stage-1];
                expected_data[stage]=expected_data[stage-1];
                expected_config[stage]=expected_config[stage-1];
            end
            if(user) reference_active_config=requested_config;
            expected_valid[0]=valid;expected_user[0]=user;expected_last[0]=last;
            expected_config[0]=reference_active_config;
            for(lane=0;lane<4;lane=lane+1)
                expected_data[0][95-lane*24-:24]={24{input_mask[lane]}};
            #1;
            if(out_valid!==expected_valid[LAT-1] || out_user!==expected_user[LAT-1] ||
                out_last!==expected_last[LAT-1] || out_config!==expected_config[LAT-1] ||
                out_edge!==0 || out_data!==(expected_valid[LAT-1] ? expected_data[LAT-1] : 96'd0))
                $fatal(1,"Mask pipeline mismatch mode=%0d expected_mode=%0d v/u/l=%b%b%b expected=%b%b%b data=%h expected=%h",
                    out_config[11:8],expected_config[LAT-1][11:8],
                    out_valid,out_user,out_last,expected_valid[LAT-1],
                    expected_user[LAT-1],expected_last[LAT-1],out_data,
                    expected_valid[LAT-1] ? expected_data[LAT-1] : 96'd0);
            checks=checks+1;
            if(out_valid) begin
                pixels=pixels+4;
                mode_pixels[out_config[11:8]]=mode_pixels[out_config[11:8]]+4;
                for(lane=0;lane<4;lane=lane+1)
                    if(out_data[95-lane*24-:24]==24'hffffff) white_pixels=white_pixels+1;
                    else black_pixels=black_pixels+1;
            end else bubbles=bubbles+1;
        end
    end
    task automatic tick(input bit v,input bit u,input bit l);
        begin
            @(negedge clk);valid=v;user=u;last=l;
        end
    endtask
    task automatic idle(input integer count);
        integer cycle;
        begin
            for(cycle=0;cycle<count;cycle=cycle+1) begin
                tick(0,0,0);data=96'hfedcba123456000001ffffff;input_mask=0;
            end
        end
    endtask
    task automatic stream_frame(input integer mode,input integer color,input bit early);
        integer y,g,lane;
        begin
            requested_config={4'(mode),8'(frames*29)};
            requested_color=2'(color);
            frame_mode=mode;
            idle(9);
            if(early) begin
                tick(0,1,0);
                idle(3);
                early_markers=early_markers+1;
            end
            frame_id=frames;
            for(y=0;y<H;y=y+1) begin
                for(g=0;g<GROUPS;g=g+1) begin
                    if((g+3*y+frames)%11==4) idle(1);
                    tick(1,!early && y==0 && g==0,g==GROUPS-1);
                    for(lane=0;lane<4;lane=lane+1) begin
                        data[95-lane*24-:24]=image[y*W+4*g+lane];
                        input_mask[lane]=preview(4*g+lane,y,mode);
                    end
                    if(y==H/2 && g==0) begin
                        requested_config={4'(mode==12?9:mode+1),8'hfd};
                        requested_color=2'((color+1)%4);
                        live_changes=live_changes+1;
                    end
                end
                idle((y+frames)%4);
            end
            idle(16);
            if(active_motion!==(color==3) ||
                active_color!==(color==3 ? 2'd0 : 2'(color)))
                $fatal(1,"Midframe K2 request changed active detector color=%0d",color);
            colors_seen[color]=1;
            frames=frames+1;
            $display("COLOR_MASK_FRAME_PASS W=%0d H=%0d frame=%0d color=%0d mode=%0d pixels=%0d",
                W,H,frames,color,mode,W*H);
        end
    endtask
    initial begin
        if(W<48 || H<32 || W%4!=0 || COLOR_COUNT<1 || COLOR_COUNT>4)
            $fatal(1,"Invalid mask pipeline dimensions or color count");
        for(mode_index=9;mode_index<=12;mode_index=mode_index+1)
            mode_pixels[mode_index]=0;
        idle(5);@(negedge clk);rst_n=1;
        for(color_index=0;color_index<COLOR_COUNT;color_index=color_index+1)
            for(mode_index=9;mode_index<=12;mode_index=mode_index+1) begin
                // Motion continues its existing grayscale detector; its mask
                // preview uses red, the color selected when entering motion.
                build_reference(color_index==3 ? 0 : color_index,frames);
                stream_frame(mode_index,color_index,(color_index+mode_index)%2);
            end
        for(mode_index=9;mode_index<=12;mode_index=mode_index+1)
            if(mode_pixels[mode_index]!=COLOR_COUNT*W*H)
                $fatal(1,"Incomplete mask mode coverage mode=%0d pixels=%0d",
                    mode_index,mode_pixels[mode_index]);
        if(frames!=4*COLOR_COUNT || pixels!=4*COLOR_COUNT*W*H ||
            early_markers!=2*COLOR_COUNT || live_changes!=4*COLOR_COUNT ||
            colors_seen!==((1<<COLOR_COUNT)-1) ||
            white_pixels==0 || black_pixels==0 || bubbles<50*COLOR_COUNT ||
            filtered_changes<25*COLOR_COUNT)
            $fatal(1,"Incomplete color mask pipeline coverage");
        $display("COLOR_MASK_PIPELINE_PASS W=%0d H=%0d frames=%0d pixels=%0d checks=%0d color_count=%0d colors_seen=%h modes=9..12 latency=11 early_sof=%0d midframe_changes=%0d bubbles=%0d white=%0d black=%0d cleaned=%0d",
            W,H,frames,pixels,checks,COLOR_COUNT,colors_seen,early_markers,live_changes,bubbles,
            white_pixels,black_pixels,filtered_changes);
        $finish;
    end
    initial begin
        #(64'd10000000+64'd20*H*(W/4+4)*10);
        $fatal(1,"Color mask pipeline watchdog");
    end
endmodule
