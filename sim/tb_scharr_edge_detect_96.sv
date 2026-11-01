`timescale 1ns/1ps
// Independent centred-image convolution, then a (3,3) coordinate shift.
// Emboss uses its own two-dimensional image reference and (1,1) shift.
// Cartoon computes an independent color convolution at the Scharr position.
// Morphology scans nine source gray pixels at the separate (1,1) position.
// No DUT window, arithmetic helper or line-memory state is used by the oracle.
module tb_scharr_edge_detect_96 #(
    parameter integer WIDTH=64,HEIGHT=48,FAST=0,GAUSSIAN_ENABLE=1
);
    localparam integer W=WIDTH,H=HEIGHT,LAT=11,TH=20;
    reg clk=0;always #5 clk=~clk;
    reg rst=0,valid=0,user=0,last=0;
    reg [3:0] request=0;
    reg [95:0] data=0;
    wire ev,eu,el,sv,su,sl,mode;
    wire [95:0] edge_data,emboss_data,cartoon_data,morph_data,switch_data;
    wire [11:0] switch_config;
    scharr_edge_detect_96 #(.IMG_WIDTH(W),.IMG_HEIGHT(H),.EDGE_TH(TH),
        .GAUSSIAN_ENABLE(GAUSSIAN_ENABLE)) dut(
        .I_clk(clk),.I_rst_n(rst),.I_tvalid(valid),.I_tuser(user),.I_tlast(last),
        .I_tdata(data),.I_tready(1'b1),
        .O_tvalid(ev),.O_tuser(eu),.O_tlast(el),
        .O_tdata(edge_data),.O_emboss_data(emboss_data),
        .O_cartoon_data(cartoon_data),.O_morph_data(morph_data),.O_tready());
    rgb_edge_switch_96 #(.IMG_WIDTH(W),.IMG_HEIGHT(H),.EDGE_TH(TH),
        .DEFAULT_EDGE_MODE(0)) selector(
        .I_clk(clk),.I_rst_n(rst),.I_tvalid(valid),.I_tuser(user),.I_tlast(last),
        .I_tdata(data),.I_effect_config({request,8'd0}),.I_mask_pixels(4'd0),
        .O_tvalid(sv),.O_tuser(su),
        .O_tlast(sl),.O_tdata(switch_data),.O_edge_mode(mode),
        .O_effect_config(switch_config));

    reg [23:0] image[0:W*H-1],expected[0:W*H-1],switch_expected[0:W*H-1];
    reg [23:0] emboss_expected[0:W*H-1];
    reg [23:0] morph_expected[0:W*H-1];
    reg [23:0] cartoon_expected[0:W*H-1],cartoon_switch_expected[0:W*H-1];
    integer gray[0:W*H-1],smooth[0:W*H-1],mag[0:W*H-1],dir[0:W*H-1];
    integer whites[0:18];
    reg qv[0:LAT-1],qu[0:LAT-1],ql[0:LAT-1];
    reg [3:0] qm[0:LAT-1];
    reg [95:0] qe[0:LAT-1],qr[0:LAT-1],qs[0:LAT-1],qb[0:LAT-1];
    reg [95:0] qc[0:LAT-1],qcs[0:LAT-1];
    reg [95:0] qg[0:LAT-1];
    integer qf[0:LAT-1],qo[0:LAT-1];
    reg [3:0] ref_active=0;
    reg [8:0] modes_seen=0;
    integer checked=0,pixels=0,users=0,lines=0,frames=0,bubbles=0;
    integer sent_pixels=0,sent_users=0,sent_lines=0,mode_changes=0;
    integer emboss_dark=0,emboss_light=0,emboss_flat=0,emboss_pairs=0;
    reg [65535:0] pair_seen=0;
    integer preview_input=0,preview_output=0;
    integer cartoon_preview_input=0,cartoon_preview_output=0;
    integer morph_preview_output=0;
    integer cartoon_edges=0,cartoon_colored=0,cartoon_red=0,cartoon_green=0,cartoon_blue=0;
    integer morph_zero=0,morph_saturated=0,morph_unsaturated=0,morph_small_step=0;
    integer inverse_selector_pixels=0,morph_selector_pixels=0;
    reg [8:0] morph_max_positions=0,morph_min_positions=0;
    integer j;

    task reference(input integer gaussian_on,input integer selector_reference);
        integer x,y,i,dx,dy,sum,gx,gy,ax,ay,kx,ky,m,a,b,dir0;
        begin
            for(i=0;i<W*H;i=i+1)begin
                smooth[i]=0;mag[i]=0;dir[i]=0;
                if(selector_reference) switch_expected[i]=0;else expected[i]=0;
            end
            for(y=1;y<H-1;y=y+1)for(x=1;x<W-1;x=x+1)begin
                sum=0;
                for(dy=-1;dy<=1;dy=dy+1)for(dx=-1;dx<=1;dx=dx+1)
                    sum=sum+gray[(y+dy)*W+x+dx]*(dx==0?2:1)*(dy==0?2:1);
                smooth[y*W+x]=gaussian_on?sum/16:gray[y*W+x];
            end
            for(y=2;y<H-2;y=y+1)for(x=2;x<W-2;x=x+1)begin
                gx=0;gy=0;
                for(dy=-1;dy<=1;dy=dy+1)for(dx=-1;dx<=1;dx=dx+1)begin
                    kx=dx*(dy==0?10:3);ky=dy*(dx==0?10:3);
                    gx=gx+kx*smooth[(y+dy)*W+x+dx];
                    gy=gy+ky*smooth[(y+dy)*W+x+dx];
                end
                ax=gx<0?-gx:gx;ay=gy<0?-gy:gy;
                i=y*W+x;mag[i]=ax+ay;
                if(ay*256<=ax*106) dir[i]=0;
                else if(ax*256<=ay*106) dir[i]=2;
                else dir[i]=((gx<0)==(gy<0))?1:3;
            end
            for(y=3;y<H-3;y=y+1)for(x=3;x<W-3;x=x+1)begin
                i=y*W+x;m=mag[i];dir0=dir[i];
                case(dir0)
                    0:begin a=mag[i-1];b=mag[i+1];end
                    1:begin a=mag[i-W-1];b=mag[i+W+1];end
                    2:begin a=mag[i-W];b=mag[i+W];end
                    default:begin a=mag[i-W+1];b=mag[i+W-1];end
                endcase
                if(m>a&&m>=b&&m>=TH*16)begin
                    if(selector_reference) switch_expected[(y+3)*W+x+3]=24'hffffff;
                    else expected[(y+3)*W+x+3]=24'hffffff;
                end
            end
        end
    endtask

    task build(input integer kind);
        integer x,y,i,g,e,cx,cy,dx,dy,ch,sum,quantized,expanded,weight,texture;
        integer lo,hi,lo_position,hi_position,position,value;
        reg [23:0] cartoon_color;
        reg [31:0] noise;
        begin
            noise=32'h87654321;
            for(y=0;y<H;y=y+1)for(x=0;x<W;x=x+1)begin
                i=y*W+x;
                case(kind)
                    0:image[i]=24'h808080;
                    1:image[i]=x<W/2?24'h202020:24'h404040;
                    2:image[i]=y<H/2?24'h202020:24'h404040;
                    3:image[i]=x*H<y*W?24'h101010:24'hc0c0c0;
                    4:image[i]=(W-1-x)*H<y*W?24'h101010:24'hc0c0c0;
                    5:begin
                        noise=noise^(noise<<13);noise=noise^(noise>>17);
                        noise=noise^(noise<<5);image[i]=noise[23:0];
                    end
                    6:image[i]=0;
                    7:image[i]=24'hffffff;
                    8:image[i]=x<W/2?24'hc80000:24'h006400; // Exactly equal Y.
                    9:image[i]=x==W/2+1?24'hffffff:24'h101010;
                    10:image[i]=x==W/2+2?24'hffffff:24'h101010;
                    11:image[i]=(x>W/3&&x<2*W/3&&y>H/3&&y<2*H/3)?
                                    24'hd00000:24'h101010;
                    12:begin
                        noise=noise*32'd1664525+32'd1013904223;
                        g=80+(noise[3:0]%5)-2;image[i]={g[7:0],g[7:0],g[7:0]};
                    end
                    13:image[i]=x<W/2?24'h202020:24'h242424;
                    14:image[i]=(x<3||x>W-4||y<3||y>H-4)?24'hffffff:0;
                    16:begin
                        g=32+y*112/H;
                        image[i]={g[7:0],g[7:0],g[7:0]};
                        if(y>=2*H/3)begin
                            g=128+((x/8+y/8)%2)*24;
                            image[i]={g[7:0],g[7:0],g[7:0]};
                        end
                        if(x>=W/8&&x<5*W/8&&y>=H/6&&y<5*H/6)begin
                            g=112+(x-W/8)*80/W+(y-H/6)*24/H;
                            image[i]={g[7:0],g[7:0],g[7:0]};
                            if(x%((W/16)>0?W/16:1)<W/32&&
                               y%((H/8)>0?H/8:1)<H/16)
                                image[i]=24'h204050;
                            if(x<W/8+2||x>=5*W/8-2||y<H/6+2||y>=5*H/6-2)
                                image[i]=24'he0d8c8;
                        end
                        cx=x-13*W/16;cy=y-H/3;
                        if(cx*cx+cy*cy<(H/6)*(H/6))begin
                            g=200+cx*48/H+cy*48/H;
                            image[i]={g[7:0],8'd48,8'd32};
                        end
                    end
                    17:begin
                        g=128;
                        if(x%2==0&&y%2==0)g=(x/2)%256;
                        if(x%2==1&&y%2==1)g=(y/2)%256;
                        image[i]={g[7:0],g[7:0],g[7:0]};
                    end
                    18:begin
                        texture=((x*11+y*7)%17)-8;
                        if(x<W/3)
                            image[i]={8'(160+y*64/H+texture),8'(40+x*48/W),8'd32};
                        else if(x<2*W/3)
                            image[i]={8'd32,8'(144+y*80/H+texture),8'(48+x*32/W)};
                        else
                            image[i]={8'(40+y*40/H),8'd56,8'(144+y*80/H+texture)};
                        if(x>W/8&&x<7*W/8&&y>H/5&&y<4*H/5)begin
                            cx=x-W/2;cy=y-H/2;
                            if((cx*64/W)*(cx*64/W)+(cy*64/H)*(cy*64/H)<256)begin
                                g=176+(x*32/W)+(y*16/H)+texture;
                                image[i]={g[7:0],8'(112+texture),8'(32+texture)};
                            end
                        end
                        if((x>W/10&&x<W/5&&y>H/4&&y<3*H/4)||
                           (x>3*W/4&&x<7*W/8&&y>H/3&&y<2*H/3))
                            image[i]={8'(16+texture),8'(24+texture),8'(32+texture)};
                    end
                    default:begin
                        g=(x*13+y*7)&255;image[i]={g[7:0],g[7:0],g[7:0]};
                    end
                endcase
                gray[i]=(int'(image[i][23:16])+2*int'(image[i][15:8])+
                         int'(image[i][7:0]))/4;
            end
            for(y=0;y<H;y=y+1)for(x=0;x<W;x=x+1)begin
                e=128;
                if(x>=2&&y>=2)
                    e=128+2*(gray[(y-1)*W+x-1]-gray[(y-2)*W+x-2]);
                if(e<0)e=0;
                if(e>255)e=255;
                emboss_expected[y*W+x]={e[7:0],e[7:0],e[7:0]};
                // Scan a whole two-dimensional neighborhood independently of
                // the DUT's horizontal/vertical min/max register pipeline.
                e=0;
                if(x>=2&&y>=2)begin
                    lo=256;hi=-1;lo_position=0;hi_position=0;
                    for(dy=0;dy<3;dy=dy+1)for(dx=0;dx<3;dx=dx+1)begin
                        value=gray[(y-2+dy)*W+x-2+dx];
                        position=dy*3+dx;
                        if(value<lo)begin lo=value;lo_position=position;end
                        if(value>hi)begin hi=value;hi_position=position;end
                    end
                    morph_min_positions[lo_position]=1'b1;
                    morph_max_positions[hi_position]=1'b1;
                    e=(hi-lo)*4;
                    if(e>255)e=255;
                end
                morph_expected[y*W+x]={e[7:0],e[7:0],e[7:0]};
            end
            reference(GAUSSIAN_ENABLE,0);
            if(GAUSSIAN_ENABLE)begin
                for(i=0;i<W*H;i=i+1)switch_expected[i]=expected[i];
            end else reference(1,1);
            for(y=0;y<H;y=y+1)for(x=0;x<W;x=x+1)begin
                i=y*W+x;
                cartoon_expected[i]=0;cartoon_switch_expected[i]=0;
                if(x>=6&&y>=6)begin
                    cartoon_color=0;
                    for(ch=0;ch<3;ch=ch+1)begin
                        sum=0;
                        for(dy=-1;dy<=1;dy=dy+1)for(dx=-1;dx<=1;dx=dx+1)begin
                            weight=(dx==0?2:1)*(dy==0?2:1);
                            sum=sum+(image[(y-3+dy)*W+x-3+dx][23-ch*8 -:8]/8)*weight;
                        end
                        quantized=sum/64;
                        expanded=quantized*36+quantized/2;
                        cartoon_color[23-ch*8 -:8]=expanded[7:0];
                    end
                    cartoon_expected[i]=expected[i]==24'hffffff ? 24'd0:cartoon_color;
                    cartoon_switch_expected[i]=switch_expected[i]==24'hffffff ?
                        24'd0:cartoon_color;
                end
            end
        end
    endtask

    task cycle(input reg v,input reg u,input reg l,input reg [95:0] d,
               input reg [95:0] e,input reg [95:0] s,input reg [95:0] b,
               input reg [95:0] c,input reg [95:0] cs,
               input integer f,input integer offset);
        integer i,x,y,index,pair_index;
        reg [95:0] selected;
        reg [6:0] selector_meta;
        begin
            @(negedge clk);valid=v;user=u;last=l;data=d;
            selector_meta={qv[LAT-1],qu[LAT-1],ql[LAT-1],qm[LAT-1]};
            selected=(qm[LAT-1]==4'd2 || qm[LAT-1]==4'd7) ? qs[LAT-1] :
                     qm[LAT-1]==4'd4 ? qb[LAT-1] :
                     qm[LAT-1]==4'd6 ? qcs[LAT-1] :
                     qm[LAT-1]==4'd8 ? qg[LAT-1] : qr[LAT-1];
            for(i=LAT-1;i>0;i=i-1)begin
                qv[i]=qv[i-1];qu[i]=qu[i-1];ql[i]=ql[i-1];qm[i]=qm[i-1];
                qe[i]=qe[i-1];qr[i]=qr[i-1];qs[i]=qs[i-1];qb[i]=qb[i-1];
                qc[i]=qc[i-1];qcs[i]=qcs[i-1];
                qg[i]=qg[i-1];
                qf[i]=qf[i-1];qo[i]=qo[i-1];
            end
            qv[0]=v;qu[0]=u;ql[0]=l;qe[0]=v?e:0;qr[0]=v?d:0;
            qs[0]=v?s:0;qb[0]=v?b:0;qf[0]=f;qo[0]=offset;
            qc[0]=v?c:0;qcs[0]=v?cs:0;
            qg[0]=v ? {morph_expected[offset],morph_expected[offset+1],
                       morph_expected[offset+2],morph_expected[offset+3]} : 96'd0;
            qm[0]=u?request:ref_active;
            if(u)begin
                if(ref_active!=request)mode_changes=mode_changes+1;
                ref_active=request;
            end
            if(v)sent_pixels=sent_pixels+4;
            if(u)sent_users=sent_users+1;
            if(l)sent_lines=sent_lines+1;
            @(posedge clk);#1;
            if({ev,eu,el,sv,su,sl}!==
                {qv[LAT-1],qu[LAT-1],ql[LAT-1],selector_meta[6:4]})
                $fatal(1,"Marker mismatch cycle=%0d",checked);
            if(edge_data!==qe[LAT-1])
                $fatal(1,"Pixel mismatch frame=%0d endpoint=(%0d,%0d) expected=%h actual=%h",
                    qf[LAT-1],qo[LAT-1]%W,qo[LAT-1]/W,qe[LAT-1],edge_data);
            if(emboss_data!==qb[LAT-1])
                $fatal(1,"Emboss mismatch frame=%0d endpoint=(%0d,%0d) expected=%h actual=%h",
                    qf[LAT-1],qo[LAT-1]%W,qo[LAT-1]/W,qb[LAT-1],emboss_data);
            if(cartoon_data!==qc[LAT-1])
                $fatal(1,"Cartoon mismatch frame=%0d endpoint=(%0d,%0d) expected=%h actual=%h",
                    qf[LAT-1],qo[LAT-1]%W,qo[LAT-1]/W,qc[LAT-1],cartoon_data);
            if(morph_data!==qg[LAT-1])
                $fatal(1,"Morphology mismatch frame=%0d endpoint=(%0d,%0d) expected=%h actual=%h",
                    qf[LAT-1],qo[LAT-1]%W,qo[LAT-1]/W,qg[LAT-1],morph_data);
            if(mode!==(selector_meta[3:0]==4'd2) ||
                switch_config!=={selector_meta[3:0],8'd0} ||
                switch_data!==selected)
                $fatal(1,"RGB/mode mismatch cycle=%0d",checked);
            if(sv)begin
                modes_seen[selector_meta[3:0]]=1'b1;
                if(selector_meta[3:0]==4'd7)inverse_selector_pixels=inverse_selector_pixels+4;
                if(selector_meta[3:0]==4'd8)morph_selector_pixels=morph_selector_pixels+4;
            end
            if(ev)begin
                pixels=pixels+4;
                for(i=0;i<4;i=i+1)begin
                    if(edge_data[95-i*24 -:24]==24'hffffff)
                        whites[qf[LAT-1]]=whites[qf[LAT-1]]+1;
                    if(emboss_data[95-i*24 -:24]==24'd0)emboss_dark=emboss_dark+1;
                    if(emboss_data[95-i*24 -:24]==24'hffffff)emboss_light=emboss_light+1;
                    if(emboss_data[95-i*24 -:24]==24'h808080)emboss_flat=emboss_flat+1;
                    if(morph_data[95-i*24 -:8]==8'd0)morph_zero=morph_zero+1;
                    else if(morph_data[95-i*24 -:8]==8'd255)
                        morph_saturated=morph_saturated+1;
                    else morph_unsaturated=morph_unsaturated+1;
                    if(qf[LAT-1]==13 && morph_data[95-i*24 -:8]==8'd16)
                        morph_small_step=morph_small_step+1;
                    if(edge_data[95-i*24 -:24]==24'hffffff)begin
                        if(cartoon_data[95-i*24 -:24]!==24'd0)
                            $fatal(1,"Cartoon contour not black");
                        cartoon_edges=cartoon_edges+1;
                    end
                    if(cartoon_data[95-i*24 -:8]!=cartoon_data[87-i*24 -:8]||
                       cartoon_data[87-i*24 -:8]!=cartoon_data[79-i*24 -:8])
                        cartoon_colored=cartoon_colored+1;
                    if(cartoon_data[95-i*24 -:8]>cartoon_data[87-i*24 -:8]&&
                       cartoon_data[95-i*24 -:8]>cartoon_data[79-i*24 -:8])
                        cartoon_red=cartoon_red+1;
                    if(cartoon_data[87-i*24 -:8]>cartoon_data[95-i*24 -:8]&&
                       cartoon_data[87-i*24 -:8]>cartoon_data[79-i*24 -:8])
                        cartoon_green=cartoon_green+1;
                    if(cartoon_data[79-i*24 -:8]>cartoon_data[95-i*24 -:8]&&
                       cartoon_data[79-i*24 -:8]>cartoon_data[87-i*24 -:8])
                        cartoon_blue=cartoon_blue+1;
                    if(qf[LAT-1]==16&&preview_output!=0)
                        $fdisplay(preview_output,"%0d %0d %0d",
                            emboss_data[95-i*24 -:8],emboss_data[87-i*24 -:8],
                            emboss_data[79-i*24 -:8]);
                    if(qf[LAT-1]==16&&morph_preview_output!=0)
                        $fdisplay(morph_preview_output,"%0d %0d %0d",
                            morph_data[95-i*24 -:8],morph_data[87-i*24 -:8],
                            morph_data[79-i*24 -:8]);
                    if(qf[LAT-1]==18&&cartoon_preview_output!=0)
                        $fdisplay(cartoon_preview_output,"%0d %0d %0d",
                            cartoon_data[95-i*24 -:8],cartoon_data[87-i*24 -:8],
                            cartoon_data[79-i*24 -:8]);
                    if(qf[LAT-1]==17)begin
                        index=qo[LAT-1]+i;x=index%W;y=index/W;
                        if(x>=2&&x<=512&&y>=2&&y<=512&&x%2==0&&y%2==0)begin
                            pair_index=gray[(y-2)*W+x-2]*256+gray[(y-1)*W+x-1];
                            if(!pair_seen[pair_index])begin
                                pair_seen[pair_index]=1'b1;emboss_pairs=emboss_pairs+1;
                            end
                        end
                    end
                end
            end
            if(eu)users=users+1;if(el)lines=lines+1;
            checked=checked+1;
        end
    endtask
    task idle(input integer count);
        integer i;
        begin for(i=0;i<count;i=i+1)cycle(0,0,0,0,0,0,0,0,0,0,0);end
    endtask
    task reset_dut;
        integer i;
        begin
            @(negedge clk);rst=0;valid=0;user=0;last=0;data=0;request=0;
            ref_active=0;
            for(i=0;i<LAT;i=i+1)begin
                qv[i]=0;qu[i]=0;ql[i]=0;qm[i]=0;qe[i]=0;qr[i]=0;qs[i]=0;qb[i]=0;
                qc[i]=0;qcs[i]=0;
                qg[i]=0;
                qf[i]=0;qo[i]=0;
            end
            repeat(5)@(posedge clk);
            @(negedge clk);rst=1;
            // Start the next frame without first flushing the unreset pixel
            // memories. Valid masking must hide stale/unknown RAM contents.
        end
    endtask
    task frame(input integer kind,input reg early,input reg use_bubbles,
               input reg mid_request,input integer rows);
        integer x,y,i;reg [95:0] d,e,s,b,c,cs;
        begin
            build(kind);
            if(kind==16)begin
                preview_input=$fopen("synthetic_emboss_input.ppm","w");
                preview_output=$fopen("synthetic_emboss_rtl.ppm","w");
                morph_preview_output=$fopen("synthetic_morphology_rtl.ppm","w");
                if(preview_input==0||preview_output==0||morph_preview_output==0)
                    $fatal(1,"Preview output unavailable");
                $fdisplay(preview_input,"P3\n%0d %0d\n255",W,H);
                $fdisplay(preview_output,"P3\n%0d %0d\n255",W,H);
                $fdisplay(morph_preview_output,"P3\n%0d %0d\n255",W,H);
                for(i=0;i<W*H;i=i+1)
                    $fdisplay(preview_input,"%0d %0d %0d",
                        image[i][23:16],image[i][15:8],image[i][7:0]);
            end
            if(kind==18)begin
                cartoon_preview_input=$fopen("synthetic_cartoon_input.ppm","w");
                cartoon_preview_output=$fopen("synthetic_cartoon_rtl.ppm","w");
                if(cartoon_preview_input==0||cartoon_preview_output==0)
                    $fatal(1,"Cartoon preview output unavailable");
                $fdisplay(cartoon_preview_input,"P3\n%0d %0d\n255",W,H);
                $fdisplay(cartoon_preview_output,"P3\n%0d %0d\n255",W,H);
                for(i=0;i<W*H;i=i+1)
                    $fdisplay(cartoon_preview_input,"%0d %0d %0d",
                        image[i][23:16],image[i][15:8],image[i][7:0]);
            end
            if(early)begin cycle(0,1,0,0,0,0,0,0,0,kind,0);idle(2);end
            for(y=0;y<rows;y=y+1)for(x=0;x<W;x=x+4)begin
                i=y*W+x;
                if(use_bubbles&&((x/4+y)%7==0))begin idle(1);bubbles=bubbles+1;end
                if(mid_request&&y==H/2&&x==0)request=request==4'd2 ? 4'd3 : 4'd2;
                d={image[i],image[i+1],image[i+2],image[i+3]};
                e={expected[i],expected[i+1],expected[i+2],expected[i+3]};
                s={switch_expected[i],switch_expected[i+1],switch_expected[i+2],switch_expected[i+3]};
                b={emboss_expected[i],emboss_expected[i+1],
                   emboss_expected[i+2],emboss_expected[i+3]};
                c={cartoon_expected[i],cartoon_expected[i+1],
                   cartoon_expected[i+2],cartoon_expected[i+3]};
                cs={cartoon_switch_expected[i],cartoon_switch_expected[i+1],
                    cartoon_switch_expected[i+2],cartoon_switch_expected[i+3]};
                cycle(1,!early&&i==0,x==W-4,d,e,s,b,c,cs,kind,i);
            end
            frames=frames+1;
            $display("FRAME_SENT kind=%0d rows=%0d early=%0d bubbles=%0d",kind,rows,early,use_bubbles);
        end
    endtask
    initial begin
        if(W<16||H<16||W%4!=0)$fatal(1,"Invalid dimensions");
        for(j=0;j<19;j=j+1)whites[j]=0;
        reset_dut();
        frame(0,0,0,0,H);
        request=2;idle(4);
        frame(1,0,0,0,H);frame(2,1,1,1,H);
        frame(3,0,1,0,H);
        if(!FAST)begin
            frame(4,1,1,1,H);frame(5,0,1,0,H);
            idle(LAT+1);reset_dut(); // Keep old RAM contents, reset only control.
        end
        frame(6,1,0,0,H);request=1;frame(7,0,0,0,H);frame(8,1,1,0,H);
        request=2;idle(4);
        frame(9,0,0,1,H);frame(10,1,1,0,H);frame(11,0,0,1,H);
        if(!FAST)begin
            frame(12,0,1,0,H);frame(14,1,1,0,H);frame(15,0,1,0,H);
            frame(0,0,0,0,3); // Truncated frame, followed immediately by a new SOF.
        end
        frame(13,0,0,0,H);
        request=4;
        frame(16,1,1,1,H);idle(LAT+2);
        $fclose(preview_input);$fclose(preview_output);$fclose(morph_preview_output);
        preview_input=0;preview_output=0;morph_preview_output=0;
        request=4;
        frame(17,0,1,0,H);idle(LAT+2);
        request=5;
        frame(8,0,1,1,H);
        request=6;
        frame(0,0,0,0,3);
        frame(18,1,1,1,H);idle(LAT+2);
        $fclose(cartoon_preview_input);$fclose(cartoon_preview_output);
        cartoon_preview_input=0;cartoon_preview_output=0;
        request=7;
        frame(3,1,1,1,H);
        request=8;
        frame(13,1,1,1,H);
        request=8;
        frame(5,0,1,0,H);
        frame(0,0,0,0,3);
        frame(14,1,1,0,H);idle(LAT+2);
        reset_dut();request=8;
        frame(1,1,1,0,H);idle(LAT+2);
        if(whites[0]||whites[6]||whites[7]||whites[8]||whites[12]||whites[13])
            $fatal(1,"Uniform/equal-Y/small-noise image generated an edge");
        if(!whites[1]||!whites[2]||!whites[3]||!whites[9]||!whites[10]||!whites[11])
            $fatal(1,"Expected contour missing");
        if(whites[9]!=whites[10])$fatal(1,"One-pixel line depends on odd/even phase");
        if(pixels!=sent_pixels||users!=sent_users||lines!=sent_lines||
            mode_changes<8||modes_seen!=9'b111111111)
            $fatal(1,"Counts/mode coverage mismatch");
        if(emboss_dark==0||emboss_light==0||emboss_flat==0)
            $fatal(1,"Emboss saturation/neutral coverage missing");
        if(W>=516&&H>=514&&emboss_pairs!=65536)
            $fatal(1,"Emboss exhaustive pair coverage=%0d expected=65536",emboss_pairs);
        if(cartoon_edges==0||cartoon_colored==0||
           cartoon_red==0||cartoon_green==0||cartoon_blue==0)
            $fatal(1,"Cartoon contour/color coverage missing");
        if(morph_zero==0||morph_saturated==0||morph_unsaturated==0||
            morph_small_step==0||morph_selector_pixels==0||
            morph_min_positions!=9'b111111111||morph_max_positions!=9'b111111111)
            $fatal(1,"Morphology extrema/saturation/selector coverage missing");
        if(inverse_selector_pixels==0)
            $fatal(1,"Inverse Scharr selector coverage missing");
        $display("SCHARR_EDGE_TEST_PASS size=%0dx%0d gaussian=%0d frames=%0d pixels=%0d cycles=%0d bubbles=%0d modes=%0d",
            W,H,GAUSSIAN_ENABLE,frames,pixels,checked,bubbles,mode_changes);
        $display("SCHARR_CONTOURS dim_vertical=%0d dim_horizontal=%0d thin_odd=%0d thin_even=%0d red_object=%0d equal_Y=%0d noise=%0d",
            whites[1],whites[2],whites[9],whites[10],whites[11],whites[8],whites[12]);
        $display("EMBOSS_TEST_PASS pixels=%0d dark=%0d light=%0d neutral=%0d grayscale_pairs=%0d",
            pixels,emboss_dark,emboss_light,emboss_flat,emboss_pairs);
        $display("EMBOSS_SYNTHETIC_PREVIEW input=synthetic_emboss_input.ppm rtl=synthetic_emboss_rtl.ppm");
        $display("CARTOON_TEST_PASS pixels=%0d black_edges=%0d colored=%0d red=%0d green=%0d blue=%0d modes=%b",
            pixels,cartoon_edges,cartoon_colored,cartoon_red,cartoon_green,cartoon_blue,modes_seen);
        $display("CARTOON_SYNTHETIC_PREVIEW input=synthetic_cartoon_input.ppm rtl=synthetic_cartoon_rtl.ppm");
        $display("INVERSE_SCHARR_SELECTOR_TEST_PASS pixels=%0d isp_inversion=0",
            inverse_selector_pixels);
        $display("MORPHOLOGY_TEST_PASS pixels=%0d zero=%0d saturated=%0d unsaturated=%0d small_step=%0d selector_pixels=%0d min_positions=%b max_positions=%b modes=%b",
            pixels,morph_zero,morph_saturated,morph_unsaturated,morph_small_step,
            morph_selector_pixels,morph_min_positions,morph_max_positions,modes_seen);
        $display("MORPHOLOGY_SYNTHETIC_PREVIEW input=synthetic_emboss_input.ppm rtl=synthetic_morphology_rtl.ppm");
        $finish;
    end
    initial begin #1000000000;$fatal(1,"timeout");end
endmodule
