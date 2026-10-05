`timescale 1ns/1ps
// Independent centred-image convolution, then a (3,3) coordinate shift.
// No DUT window, arithmetic helper or line-memory state is used by the oracle.
module tb_scharr_edge_detect_96 #(
    parameter integer WIDTH=64,HEIGHT=48,FAST=0,GAUSSIAN_ENABLE=1
);
    localparam integer W=WIDTH,H=HEIGHT,LAT=11,TH=20;
    reg clk=0;always #5 clk=~clk;
    reg rst=0,valid=0,user=0,last=0,request=0;
    reg [95:0] data=0;
    wire ev,eu,el,sv,su,sl,mode;
    wire [95:0] edge_data,switch_data;
    scharr_edge_detect_96 #(.IMG_WIDTH(W),.IMG_HEIGHT(H),.EDGE_TH(TH),
        .GAUSSIAN_ENABLE(GAUSSIAN_ENABLE)) dut(
        .I_clk(clk),.I_rst_n(rst),.I_tvalid(valid),.I_tuser(user),.I_tlast(last),
        .I_tdata(data),.I_tready(1'b1),.O_tvalid(ev),.O_tuser(eu),.O_tlast(el),
        .O_tdata(edge_data),.O_tready());
    rgb_edge_switch_96 #(.IMG_WIDTH(W),.IMG_HEIGHT(H),.EDGE_TH(TH),
        .DEFAULT_EDGE_MODE(0)) selector(
        .I_clk(clk),.I_rst_n(rst),.I_tvalid(valid),.I_tuser(user),.I_tlast(last),
        .I_tdata(data),.I_edge_mode_async(request),.O_tvalid(sv),.O_tuser(su),
        .O_tlast(sl),.O_tdata(switch_data),.O_edge_mode(mode));

    reg [23:0] image[0:W*H-1],expected[0:W*H-1],switch_expected[0:W*H-1];
    integer gray[0:W*H-1],smooth[0:W*H-1],mag[0:W*H-1],dir[0:W*H-1];
    integer whites[0:15];
    reg qv[0:LAT-1],qu[0:LAT-1],ql[0:LAT-1],qm[0:LAT-1];
    reg [95:0] qe[0:LAT-1],qr[0:LAT-1],qs[0:LAT-1];
    integer qf[0:LAT-1],qo[0:LAT-1];
    reg ref_meta=0,ref_sync=0,ref_active=0;
    integer checked=0,pixels=0,users=0,lines=0,frames=0,bubbles=0;
    integer sent_pixels=0,sent_users=0,sent_lines=0,mode_changes=0;
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
        integer x,y,i,g;
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
                    default:begin
                        g=(x*13+y*7)&255;image[i]={g[7:0],g[7:0],g[7:0]};
                    end
                endcase
                gray[i]=(int'(image[i][23:16])+2*int'(image[i][15:8])+
                         int'(image[i][7:0]))/4;
            end
            reference(GAUSSIAN_ENABLE,0);
            if(GAUSSIAN_ENABLE)begin
                for(i=0;i<W*H;i=i+1)switch_expected[i]=expected[i];
            end else reference(1,1);
        end
    endtask

    task cycle(input reg v,input reg u,input reg l,input reg [95:0] d,
               input reg [95:0] e,input reg [95:0] s,
               input integer f,input integer offset);
        integer i;reg old_meta,old_sync;
        begin
            @(negedge clk);valid=v;user=u;last=l;data=d;
            for(i=LAT-1;i>0;i=i-1)begin
                qv[i]=qv[i-1];qu[i]=qu[i-1];ql[i]=ql[i-1];qm[i]=qm[i-1];
                qe[i]=qe[i-1];qr[i]=qr[i-1];qs[i]=qs[i-1];qf[i]=qf[i-1];qo[i]=qo[i-1];
            end
            qv[0]=v;qu[0]=u;ql[0]=l;qe[0]=v?e:0;qr[0]=v?d:0;
            qs[0]=v?s:0;qf[0]=f;qo[0]=offset;
            qm[0]=u?ref_sync:ref_active;
            old_meta=ref_meta;old_sync=ref_sync;ref_meta=request;ref_sync=old_meta;
            if(u)begin
                if(ref_active!=old_sync)mode_changes=mode_changes+1;
                ref_active=old_sync;
            end
            if(v)sent_pixels=sent_pixels+4;
            if(u)sent_users=sent_users+1;
            if(l)sent_lines=sent_lines+1;
            @(posedge clk);#1;
            if({ev,eu,el,sv,su,sl}!==
                {qv[LAT-1],qu[LAT-1],ql[LAT-1],qv[LAT-1],qu[LAT-1],ql[LAT-1]})
                $fatal(1,"Marker mismatch cycle=%0d",checked);
            if(edge_data!==qe[LAT-1])
                $fatal(1,"Pixel mismatch frame=%0d endpoint=(%0d,%0d) expected=%h actual=%h",
                    qf[LAT-1],qo[LAT-1]%W,qo[LAT-1]/W,qe[LAT-1],edge_data);
            if(mode!==qm[LAT-1] ||
                switch_data!==(qm[LAT-1]?qs[LAT-1]:qr[LAT-1]))
                $fatal(1,"RGB/mode mismatch cycle=%0d",checked);
            if(ev)begin
                pixels=pixels+4;
                for(i=0;i<4;i=i+1)
                    if(edge_data[95-i*24 -:24]==24'hffffff)
                        whites[qf[LAT-1]]=whites[qf[LAT-1]]+1;
            end
            if(eu)users=users+1;if(el)lines=lines+1;
            checked=checked+1;
        end
    endtask
    task idle(input integer count);
        integer i;
        begin for(i=0;i<count;i=i+1)cycle(0,0,0,0,0,0,0,0);end
    endtask
    task reset_dut;
        integer i;
        begin
            @(negedge clk);rst=0;valid=0;user=0;last=0;data=0;request=0;
            ref_meta=0;ref_sync=0;ref_active=0;
            for(i=0;i<LAT;i=i+1)begin
                qv[i]=0;qu[i]=0;ql[i]=0;qm[i]=0;qe[i]=0;qr[i]=0;qs[i]=0;qf[i]=0;qo[i]=0;
            end
            repeat(5)@(posedge clk);
            @(negedge clk);rst=1;
            // Start the next frame without first flushing the unreset pixel
            // memories. Valid masking must hide stale/unknown RAM contents.
        end
    endtask
    task frame(input integer kind,input reg early,input reg use_bubbles,
               input reg mid_request,input integer rows);
        integer x,y,i;reg [95:0] d,e,s;
        begin
            build(kind);
            if(early)begin cycle(0,1,0,0,0,0,kind,0);idle(2);end
            for(y=0;y<rows;y=y+1)for(x=0;x<W;x=x+4)begin
                i=y*W+x;
                if(use_bubbles&&((x/4+y)%7==0))begin idle(1);bubbles=bubbles+1;end
                if(mid_request&&y==H/2&&x==0)request=~request;
                d={image[i],image[i+1],image[i+2],image[i+3]};
                e={expected[i],expected[i+1],expected[i+2],expected[i+3]};
                s={switch_expected[i],switch_expected[i+1],switch_expected[i+2],switch_expected[i+3]};
                cycle(1,!early&&i==0,x==W-4,d,e,s,kind,i);
            end
            frames=frames+1;
            $display("FRAME_SENT kind=%0d rows=%0d early=%0d bubbles=%0d",kind,rows,early,use_bubbles);
        end
    endtask
    initial begin
        if(W<16||H<16||W%4!=0)$fatal(1,"Invalid dimensions");
        for(j=0;j<16;j=j+1)whites[j]=0;
        reset_dut();
        frame(0,0,0,0,H);
        request=1;idle(4);
        frame(1,0,0,0,H);frame(2,1,1,1,H);
        frame(3,0,1,0,H);
        if(!FAST)begin
            frame(4,1,1,1,H);frame(5,0,1,0,H);
            idle(LAT+1);reset_dut(); // Keep old RAM contents, reset only control.
        end
        frame(6,1,0,0,H);frame(7,0,0,0,H);frame(8,1,1,0,H);
        request=1;idle(4);
        frame(9,0,0,1,H);frame(10,1,1,0,H);frame(11,0,0,1,H);
        if(!FAST)begin
            frame(12,0,1,0,H);frame(14,1,1,0,H);frame(15,0,1,0,H);
            frame(0,0,0,0,3); // Truncated frame, followed immediately by a new SOF.
        end
        frame(13,0,0,0,H);idle(LAT+2);
        if(whites[0]||whites[6]||whites[7]||whites[8]||whites[12]||whites[13])
            $fatal(1,"Uniform/equal-Y/small-noise image generated an edge");
        if(!whites[1]||!whites[2]||!whites[3]||!whites[9]||!whites[10]||!whites[11])
            $fatal(1,"Expected contour missing");
        if(whites[9]!=whites[10])$fatal(1,"One-pixel line depends on odd/even phase");
        if(pixels!=sent_pixels||users!=sent_users||lines!=sent_lines||mode_changes<3)
            $fatal(1,"Counts/mode coverage mismatch");
        $display("SCHARR_EDGE_TEST_PASS size=%0dx%0d gaussian=%0d frames=%0d pixels=%0d cycles=%0d bubbles=%0d modes=%0d",
            W,H,GAUSSIAN_ENABLE,frames,pixels,checked,bubbles,mode_changes);
        $display("SCHARR_CONTOURS dim_vertical=%0d dim_horizontal=%0d thin_odd=%0d thin_even=%0d red_object=%0d equal_Y=%0d noise=%0d",
            whites[1],whites[2],whites[9],whites[10],whites[11],whites[8],whites[12]);
        $finish;
    end
    initial begin #1000000000;$fatal(1,"timeout");end
endmodule
