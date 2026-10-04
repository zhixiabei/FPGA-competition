`timescale 1ns/1ps
// Standalone image-domain reference for the real color-vector pipeline and
// RGB selector. No vendor primitives are required. FAST=1 runs seven frames
// for a full 720p check; FAST=0 also covers diagonals, noise, horizontal
// chroma-only contours, blanking bubbles and requests in the middle of a frame.
module tb_color_edge_detect_96 #(
  parameter integer WIDTH=64, HEIGHT=48, FAST=0
);
  localparam integer W=WIDTH,H=HEIGHT,P=W/2,LAT=11,HIGH=20,LOW=10;
  reg clk=0; always #5 clk=~clk;
  reg rst=0,valid=0,user=0,last=0,request=1;
  reg [95:0] data=0;
  wire ev,eu,el,sv,su,sl,sm,baseline_valid;
  wire [95:0] edge_data,switch_data,baseline_data;
  color_edge_detect_96 #(.IMG_WIDTH(W),.IMG_HEIGHT(H),.EDGE_TH(HIGH),.LOW_TH(LOW)) edge_dut(
   .I_clk(clk),.I_rst_n(rst),.I_tvalid(valid),.I_tuser(user),.I_tlast(last),.I_tdata(data),.I_tready(1'b1),
   .O_tvalid(ev),.O_tuser(eu),.O_tlast(el),.O_tdata(edge_data),.O_tready());
  rgb_edge_switch_96 #(.IMG_WIDTH(W),.IMG_HEIGHT(H),.EDGE_TH(HIGH)) switch_dut(
   .I_clk(clk),.I_rst_n(rst),.I_tvalid(valid),.I_tuser(user),.I_tlast(last),.I_tdata(data),.I_edge_mode_async(request),
   .O_tvalid(sv),.O_tuser(su),.O_tlast(sl),.O_tdata(switch_data),.O_edge_mode(sm));
  // Reproduce the overly restrictive thresholds on the same input stream.
  // Regression frames must fail there and survive the calibrated thresholds.
  color_edge_detect_96 #(.IMG_WIDTH(W),.IMG_HEIGHT(H),.EDGE_TH(80),.LOW_TH(40)) baseline_dut(
   .I_clk(clk),.I_rst_n(rst),.I_tvalid(valid),.I_tuser(user),.I_tlast(last),.I_tdata(data),.I_tready(1'b1),
   .O_tvalid(baseline_valid),.O_tuser(),.O_tlast(),.O_tdata(baseline_data),.O_tready());
  reg [23:0] image[0:W*H-1];
  reg [23:0] expected[0:W*H-1];
  integer vy[0:P*H-1],c1[0:P*H-1],c2[0:P*H-1];
  integer mags[0:P*H-1],dirs[0:P*H-1],classes[0:P*H-1];
  reg qv[0:LAT-1],qu[0:LAT-1],ql[0:LAT-1],qm[0:LAT-1];
  reg [95:0] qe[0:LAT-1],qr[0:LAT-1];
  integer qframe[0:LAT-1];
  reg ref_meta=1,ref_sync=1,ref_active=1;
  integer whites[0:12],baseline_whites[0:12],frames=0,checked=0,pixels=0,users=0,lines=0;
  function integer ai(input integer a); ai=(a<0)?-a:a; endfunction
  function integer val(input integer comp,input integer i);
   case(comp) 0:val=vy[i];1:val=c1[i];default:val=c2[i];endcase
  endfunction
  task build(input integer kind);
    integer x,y,i,s,k,r0,g0,b0,r1,g1,b1,a[0:2],b[0:2];
    integer norm0,norm1,norm2,gx,gy,ax,ay,cx,cy,m,n0,n1,dir,strong_flag;
    reg [31:0] noise;
    begin
      noise=32'hdeadcafe;
      for(y=0;y<H;y=y+1) for(x=0;x<W;x=x+1) begin
        i=y*W+x;
        case(kind)
          0: image[i]=24'h808080;
          1: image[i]=(x<W/2)?24'hc80000:24'h006400; // Both Y=50.
          2: image[i]=24'h006400;
          3: image[i]=(x*H<W*y)?24'h0000e0:24'hb00000;
          4: begin
            image[i]=24'h101010;
            if(x>W/3 && x<W*2/3) image[i]=(y<H/2)?24'h808080:24'h444444;
          end
          5: begin
            noise=noise^(noise<<13);noise=noise^(noise>>17);noise=noise^(noise<<5);
            image[i]=noise[23:0];
          end
          6: image[i]=24'h000000;
          7: image[i]=(y<H/2)?24'hc80000:24'h006400;
          9: image[i]=(x<W/2)?24'h202020:24'h404040; // Dim, 32-level luminance step.
          10: image[i]=(y<H/2)?24'h202020:24'h404040;
          11: image[i]=(x<W/2)?24'h584040:24'h404c40; // Both Y=70, chroma step only.
          12: image[i]=(x<W/2)?24'h202020:24'h242424; // Four-level disturbance stays below LOW.
          default: image[i]=24'hffffff;
        endcase
        expected[i]=0;
      end
      for(y=0;y<H;y=y+1) for(s=0;s<P;s=s+1) begin
        i=y*W+2*s;
        r0=image[i][23:16];g0=image[i][15:8];b0=image[i][7:0];
        r1=image[i+1][23:16];g1=image[i+1][15:8];b1=image[i+1][7:0];
        vy[y*P+s]=(((r0+2*g0+b0)>>2)+((r1+2*g1+b1)>>2))>>1;
        c1[y*P+s]=((r0-g0)+(r1-g1))>>>1;
        c2[y*P+s]=((b0-g0)+(b1-g1))>>>1;
        mags[y*P+s]=0;dirs[y*P+s]=0;classes[y*P+s]=0;
      end
      // Image-domain reference: magnitudes stored at the endpoint of the
      // causal input window, independently of the DUT's RAM implementation.
      // A uniform image has zero derivatives. The shortcut only speeds
      // up the independent reference; every output pixel is still checked.
      if(kind!=0 && kind!=2 && kind!=6 && kind!=8) begin
      for(y=2;y<H;y=y+1) for(s=2;s<P;s=s+1) begin
        i=y*P+s;
        for(k=0;k<3;k=k+1) begin
          a[k]=(val(k,i-2*P)-val(k,i-2*P-2))+2*(val(k,i-P)-val(k,i-P-2))+(val(k,i)-val(k,i-2));
          b[k]=(val(k,i-2)-val(k,i-2*P-2))+2*(val(k,i-1)-val(k,i-2*P-1))+(val(k,i)-val(k,i-2*P));
        end
        norm0=ai(a[0])+ai(b[0]);norm1=(ai(a[1])+ai(b[1]))>>1;norm2=(ai(a[2])+ai(b[2]))>>1;
        gx=a[0];gy=b[0];
        if(norm1>norm0 && norm1>=norm2) begin gx=a[1];gy=b[1];end
        else if(norm2>norm0 && norm2>norm1) begin gx=a[2];gy=b[2];end
        ax=ai(gx);ay=ai(gy);
        if(ax>=2*ay)dir=0;else if(ay>=2*ax)dir=2;else dir=((gx<0)==(gy<0))?1:3;
        cx=ai(a[0])+((ai(a[1])+ai(a[2]))>>1);
        cy=ai(b[0])+((ai(b[1])+ai(b[2]))>>1);
        m=((cx>=cy)?cx+(cy>>1):cy+(cx>>1))>>2;
        mags[i]=m;dirs[i]=dir;
      end
      for(y=2;y<H;y=y+1)for(s=2;s<P;s=s+1)begin
        i=(y-1)*P+s-1;m=mags[i];
        case(dirs[i])
          0:begin n0=mags[i-1];n1=mags[i+1];end
          1:begin n0=mags[i-P-1];n1=mags[i+P+1];end
          2:begin n0=mags[i-P];n1=mags[i+P];end
          3:begin n0=mags[i-P+1];n1=mags[i+P-1];end
        endcase
        if(m>n0 && m>=n1) begin
          if(m>=HIGH)classes[y*P+s]=3;else if(m>=LOW)classes[y*P+s]=1;
        end
      end
      for(y=6;y<H;y=y+1)for(s=6;s<P;s=s+1)begin
        i=(y-1)*P+s-1;
        strong_flag=(classes[i-P-1]|classes[i-P]|classes[i-P+1]|classes[i-1]|classes[i+1]|classes[i+P-1]|classes[i+P]|classes[i+P+1])&2;
        if((classes[i]&2)!=0 || ((classes[i]&1)!=0 && strong_flag!=0))begin
          expected[y*W+2*s]=24'hffffff;expected[y*W+2*s+1]=24'hffffff;
        end
      end
      end
    end
  endtask
  task cycle(input reg v,input reg u,input reg l,input reg [95:0] d,input reg [95:0] e,input integer f);
    integer i,k;reg old_meta,old_sync;
    begin
      @(negedge clk);valid=v;user=u;last=l;data=d;
      for(i=LAT-1;i>0;i=i-1) begin qv[i]=qv[i-1];qu[i]=qu[i-1];ql[i]=ql[i-1];qm[i]=qm[i-1];qe[i]=qe[i-1];qr[i]=qr[i-1];qframe[i]=qframe[i-1];end
      qv[0]=v;qu[0]=u;ql[0]=l;qe[0]=v?e:0;qr[0]=v?d:0;qframe[0]=f;
      qm[0]=u?ref_sync:ref_active;
      old_meta=ref_meta;old_sync=ref_sync;ref_meta=request;ref_sync=old_meta;if(u)ref_active=old_sync;
      @(posedge clk);#1;
      if(rst)begin
        if({ev,eu,el} !== {qv[LAT-1],qu[LAT-1],ql[LAT-1]})$fatal(1,"Edge marker mismatch at cycle %0d",checked);
        if(baseline_valid !== ev)$fatal(1,"Baseline latency mismatch at cycle %0d",checked);
        if({sv,su,sl} !== {qv[LAT-1],qu[LAT-1],ql[LAT-1]})$fatal(1,"Switch marker mismatch at cycle %0d",checked);
        if(edge_data !== qe[LAT-1])$fatal(1,"Edge pixel mismatch cycle=%0d frame=%0d expected=%h actual=%h",checked,qframe[LAT-1],qe[LAT-1],edge_data);
        if(sm !== qm[LAT-1])$fatal(1,"Mode latency mismatch cycle=%0d",checked);
        if(switch_data !== (qm[LAT-1]?qe[LAT-1]:qr[LAT-1]))$fatal(1,"Switch pixel mismatch cycle=%0d",checked);
        if(ev)begin
          pixels=pixels+4;
          for(k=0;k<4;k=k+1)begin
            if(edge_data[95-k*24 -:24]==24'hffffff)whites[qframe[LAT-1]]=whites[qframe[LAT-1]]+1;
            if(baseline_data[95-k*24 -:24]==24'hffffff)baseline_whites[qframe[LAT-1]]=baseline_whites[qframe[LAT-1]]+1;
          end
        end
        if(eu)users=users+1;if(el)lines=lines+1;
        checked=checked+1;
      end
    end
  endtask
  task frame(input integer kind,input reg early,input reg bubbles,input reg middle_request);
    integer x,y,i;reg [95:0] d,e;
    begin
      build(kind);
      if(early)begin cycle(0,1,0,0,0,kind);cycle(0,0,0,0,0,kind);end
      for(y=0;y<H;y=y+1)for(x=0;x<W;x=x+4)begin
        i=y*W+x;
        if(bubbles && ((x/4+y)%7==0))cycle(0,0,0,0,0,kind);
        if(y==H/2 && x==0 && middle_request)request=~request;
        d={image[i],image[i+1],image[i+2],image[i+3]};
        e={expected[i],expected[i+1],expected[i+2],expected[i+3]};
        cycle(1,(!early && i==0),(x==W-4),d,e,kind);
      end
      frames=frames+1;$display("FRAME_SENT kind=%0d early=%0d bubbles=%0d",kind,early,bubbles);
    end
  endtask
  integer j;
  initial begin
    if(W%4!=0 || W<16 || H<8) $fatal(1,"Invalid frame dimensions");
    for(j=0;j<LAT;j=j+1)begin qv[j]=0;qu[j]=0;ql[j]=0;qm[j]=1;qe[j]=0;qr[j]=0;qframe[j]=0;end
    for(j=0;j<13;j=j+1)begin whites[j]=0;baseline_whites[j]=0;end
    repeat(5)@(posedge clk);@(negedge clk);rst=1;
    repeat(12)cycle(0,0,0,0,0,0);
    frame(0,0,0,0);frame(1,0,0,0); // Truly consecutive frames; no idle clocks.
    request=0;repeat(4)cycle(0,0,0,0,0,2);frame(2,1,1,0);
    if(!FAST) begin
      request=1;repeat(4)cycle(0,0,0,0,0,3);frame(3,0,1,0);
      frame(4,1,1,1);frame(5,0,1,0);frame(6,1,0,0);
      request=1;repeat(4)cycle(0,0,0,0,0,7);frame(7,0,1,0);
      frame(8,1,0,0);
    end
    request=1;repeat(4)cycle(0,0,0,0,0,9);
    frame(9,1,1,0);frame(10,0,0,0);frame(11,1,1,0);frame(12,0,0,0);
    repeat(15)cycle(0,0,0,0,0,12);
    if(whites[0]||whites[2]||whites[6]||whites[8])$fatal(1,"Uniform frame produced edges");
    if(whites[1]==0)$fatal(1,"Equal-luminance chroma edge missing");
    if(!FAST && (whites[3]==0||whites[5]==0||whites[7]==0))$fatal(1,"Color/diagonal edge missing");
    for(j=9;j<=11;j=j+1)begin
      if(whites[j]==0)$fatal(1,"Low-contrast edge missing frame=%0d",j);
      if(baseline_whites[j]!=0)$fatal(1,"Regression did not reproduce high-threshold loss frame=%0d",j);
    end
    if(whites[12]!=0)$fatal(1,"Four-level disturbance produced edges");
    if(users!=frames||lines!=frames*H||pixels!=frames*W*H)$fatal(1,"Counts mismatch: SOFs=%0d lines=%0d pixels=%0d",users,lines,pixels);
    $display("COLOR_EDGE_DETECT_TEST_PASS size=%0dx%0d frames=%0d cycles=%0d pixels=%0d equal_Y_vertical_white=%0d equal_Y_horizontal_white=%0d",W,H,frames,checked,pixels,whites[1],whites[7]);
    $display("LOW_CONTRAST_PASS thresholds=%0d/%0d gray_vertical=%0d gray_horizontal=%0d chroma_only=%0d old_80_40=%0d/%0d/%0d four_level_noise=%0d",
      HIGH,LOW,whites[9],whites[10],whites[11],baseline_whites[9],baseline_whites[10],baseline_whites[11],whites[12]);
    $finish;
  end
  initial begin #1000000000;$fatal(1,"timeout");end
endmodule
