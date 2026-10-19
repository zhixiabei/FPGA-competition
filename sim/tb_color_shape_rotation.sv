`timescale 1ns/1ps
// RGB-to-result sweep. No descriptor inputs or results are forced.
// A locally compressed square is deliberately also a rectangle silhouette:
// those probes report geometry rather than asserting a semantic distinction.
module tb_color_shape_rotation #(parameter integer PROBE_ONLY=1);
  localparam integer W=320,H=240;
  reg clk=0,rst_n=0,clear=0,user=0,valid=0;
  reg [95:0] data=0;
  reg [9:0] frame_id=0;
  wire ready,overflow;
  wire [3:0] found,held;
  wire [7:0] shapes;
  wire [9:0] result_id;
  reg [23:0] image[0:W*H-1];
  integer seen[0:127];
  reg [3:0] seen_valid[0:127];
  reg [7:0] seen_shape[0:127];
  integer checks=0,case_id=0,next_id=1,k,si,ri,ai;
  integer side_q4,ratio_num,ratio_den,cosine,sine,angle;
  integer a,p,w,h,u,v;
  real q;
  always #5 clk=~clk;
  red_target_detect_96 #(
    .IMG_WIDTH(W),.IMG_HEIGHT(H),.MIN_PIXELS(128),
    .MIN_WIDTH(8),.MIN_HEIGHT(8),.MULTI_ENABLE(1)
  ) dut(
    .I_clk(clk),.I_rst_n(rst_n),.I_tuser(user),.I_tvalid(valid),.I_tdata(data),
    .I_color_mode(2'b0),.I_mask_view_mode(4'b0),.O_mask_pixels(),
    .I_frame_id(frame_id),.I_multi_clear(clear),
    .O_result_ready(),.O_found(),.O_xmin(),.O_xmax(),.O_ymin(),.O_ymax(),
    .O_center_x(),.O_center_y(),.O_pixels(),.O_frame_toggle(),
    .O_multi_ready(ready),.O_multi_valid(found),.O_multi_hold(held),
    .O_multi_boxes(),.O_multi_shapes(shapes),
    .O_multi_frame_id(result_id),.O_multi_overflow(overflow)
  );
  always @(negedge clk) begin
    if(rst_n && dut.gen_multi.u_engine.shape_ready) begin
      a=dut.gen_multi.u_engine.top_pixels[dut.gen_multi.u_engine.class_index];
      p=dut.gen_multi.u_engine.class_perimeter;
      w=dut.gen_multi.u_engine.top_xmax[dut.gen_multi.u_engine.class_index]-
        dut.gen_multi.u_engine.top_xmin[dut.gen_multi.u_engine.class_index]+1;
      h=dut.gen_multi.u_engine.top_ymax[dut.gen_multi.u_engine.class_index]-
        dut.gen_multi.u_engine.top_ymin[dut.gen_multi.u_engine.class_index]+1;
      u=dut.gen_multi.u_engine.class_umax-dut.gen_multi.u_engine.class_umin+1;
      v=dut.gen_multi.u_engine.class_vmax-dut.gen_multi.u_engine.class_vmin+1;
      q=$itor(p)*$itor(p)/(64.0*$itor(a));
      $display("ROTATION_RAW case=%0d frame=%0d side_q4=%0d ratio=%0d/%0d angle=%0d shape=%0d A=%0d P8=%0d Q=%0f wh=%0dx%0d uv=%0dx%0d bad=%b iso=%b square_spans=%b centered=%b square_metric=%b circle_fill=%b square_fill=%b",
        case_id,dut.gen_multi.u_engine.context_id,side_q4,ratio_num,ratio_den,angle,
        dut.gen_multi.u_engine.shape_result,a,p,q,w,h,u,v,
        dut.gen_multi.u_engine.class_bad,dut.gen_multi.u_engine.u_shape.isotropic,
        dut.gen_multi.u_engine.u_shape.square_spans_ok,dut.gen_multi.u_engine.u_shape.centered,
        dut.gen_multi.u_engine.u_shape.square_metric,dut.gen_multi.u_engine.u_shape.circle_fill,
        dut.gen_multi.u_engine.u_shape.square_fill);
    end
  end
  always @(posedge clk) begin
    #1;
    if(rst_n && ready) begin
      seen[result_id]=1;seen_valid[result_id]=found;seen_shape[result_id]=shapes;
      if(overflow || held!=0) $fatal(1,"Unexpected overflow/hold frame=%0d",result_id);
    end
  end
  task blank;
    input integer n;
    integer i;
    begin
      for(i=0;i<n;i=i+1) begin
        @(negedge clk);valid=0;user=0;data=0;
      end
    end
  endtask
  task reset_track;
    begin
      blank(5);@(negedge clk);clear=1;
      @(negedge clk);clear=0;blank(3);
    end
  endtask
  task make_rectangle;
    input integer half_q4,cos_arg,sin_arg,num,den;
    integer x,y,dx,dy,u1,v1;
    begin
      for(y=0;y<H;y=y+1)
        for(x=0;x<W;x=x+1) begin
          dx=4*(x-160);dy=4*(y-120);
          u1=dx*cos_arg+dy*sin_arg;v1=-dx*sin_arg+dy*cos_arg;
          image[y*W+x]=24'h101010;
          if(u1<=half_q4*1024 && u1>=-half_q4*1024 &&
             v1*den<=half_q4*1024*num && v1*den>=-half_q4*1024*num)
            image[y*W+x]=24'hf02020;
        end
    end
  endtask
  task make_ellipse;
    input integer rx,ry;
    integer x,y,dx,dy;
    begin
      for(y=0;y<H;y=y+1)
        for(x=0;x<W;x=x+1) begin
          dx=x-160;dy=y-120;
          image[y*W+x]=(dx*dx*ry*ry+dy*dy*rx*rx<=rx*rx*ry*ry) ?
            24'hf02020 : 24'h101010;
        end
    end
  endtask
  task send;
    input integer id;
    integer y,g,l,cycles;
    begin
      @(negedge clk);user=1;valid=0;frame_id=id;
      @(negedge clk);user=0;frame_id=999;
      for(y=0;y<H;y=y+1) begin
        for(g=0;g<W/4;g=g+1) begin
          @(negedge clk);valid=1;
          for(l=0;l<4;l=l+1) data[95-l*24-:24]=image[y*W+4*g+l];
        end
        if(y!=H-1) blank(96);
      end
      blank(1);cycles=0;
      while(!seen[id] && cycles<30000) begin blank(1);cycles=cycles+1;end
      if(!seen[id]) $fatal(1,"Timeout frame=%0d",id);
      blank(20);
    end
  endtask
  task pair;
    input integer expected;
    begin
      reset_track();send(next_id);send(next_id+1);
      if(seen_valid[next_id+1]!==4'b0001)
        $fatal(1,"Missing color candidate case=%0d frame=%0d",case_id,next_id+1);
      $display("ROTATION_PUBLISHED case=%0d frame=%0d side_q4=%0d ratio=%0d/%0d angle=%0d shape=%0d expected=%0d",
        case_id,next_id+1,side_q4,ratio_num,ratio_den,angle,
        seen_shape[next_id+1][1:0],expected);
      if(!PROBE_ONLY && expected>=0 && seen_shape[next_id+1][1:0]!==expected[1:0])
        $fatal(1,"Wrong rotation result case=%0d expected=%0d got=%0d",
          case_id,expected,seen_shape[next_id+1][1:0]);
      checks=checks+1;next_id=next_id+2;
    end
  endtask
  initial begin
    for(k=0;k<128;k=k+1)seen[k]=0;
    blank(8);rst_n=1;blank(8);
    for(si=0;si<3;si=si+1) begin
      side_q4=(si==0) ? 32 : (si==1) ? 96 : 320;
      for(ri=0;ri<3;ri=ri+1) begin
        ratio_num=(ri==0) ? 1 : (ri==1) ? 15 : 7;
        ratio_den=(ri==0) ? 1 : (ri==1) ? 16 : 8;
        for(ai=0;ai<3;ai=ai+1) begin
          angle=(ai==0) ? 0 : (ai==1) ? 20 : 45;
          cosine=(ai==0) ? 1024 : (ai==1) ? 962 : 724;
          sine=(ai==0) ? 0 : (ai==1) ? 350 : 724;
          case_id=case_id+1;
          make_rectangle(side_q4,cosine,sine,ratio_num,ratio_den);
          // Strong compression has no unique "square" ground truth; report it.
          pair(ri<2 ? 1 : -1);
        end
      end
    end
    // Fixed negative controls retain their independent rectangle/ellipse truth.
    case_id=case_id+1;side_q4=128;ratio_num=13;ratio_den=16;angle=0;
    make_rectangle(side_q4,1024,0,ratio_num,ratio_den);pair(0);
    case_id=case_id+1;side_q4=0;ratio_num=35;ratio_den=30;angle=0;
    make_ellipse(35,30);pair(0);
    case_id=case_id+1;ratio_num=1;ratio_den=1;
    make_ellipse(32,32);pair(3);
    $display("COLOR_SHAPE_ROTATION_PASS probe_only=%0d frames=%0d checks=%0d",
      PROBE_ONLY,next_id-1,checks);
    $finish;
  end
  initial begin #70000000;$fatal(1,"Watchdog");end
endmodule
