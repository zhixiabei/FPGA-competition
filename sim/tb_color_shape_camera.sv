`timescale 1ns/1ps
module tb_color_shape_camera #(parameter integer BASELINE=0);
  localparam W=320,H=240;
  reg clk=0,rst_n=0,clear=0,user=0,valid=0;
  reg [95:0] data=0;
  reg [9:0] frame_id=0;
  wire ready,overflow;
  wire [3:0] found,held;
  wire [7:0] shapes;
  wire [191:0] boxes;
  wire [9:0] result_id;
  reg [23:0] image[0:W*H-1];
  integer seen[0:63];
  reg [3:0] seen_valid[0:63];
  reg [7:0] seen_shape[0:63];
  reg [191:0] seen_boxes[0:63];
  integer checks=0;
  integer case_id=0,k,hole_x,hole_y;
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
    .O_multi_boxes(boxes),.O_multi_shapes(shapes),
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
      $display("PROBE_RAW case=%0d frame=%0d shape=%0d A=%0d P8=%0d Q=%0f wh=%0dx%0d uv=%0dx%0d bad=%b iso=%b centered=%b circle_metric=%b square_metric=%b fill=%b margin_xy=%0d margin_uv=%0d mx2=%0d my2=%0d",
        case_id,dut.gen_multi.u_engine.context_id,
        dut.gen_multi.u_engine.shape_result,a,p,q,w,h,u,v,
        dut.gen_multi.u_engine.class_bad,dut.gen_multi.u_engine.u_shape.isotropic,
        dut.gen_multi.u_engine.u_shape.centered,dut.gen_multi.u_engine.u_shape.circle_metric,
        dut.gen_multi.u_engine.u_shape.square_metric,dut.gen_multi.u_engine.u_shape.circle_fill,
        25*a-18*w*h,50*a-18*u*v,dut.gen_multi.u_engine.class_mx2,dut.gen_multi.u_engine.class_my2);
    end
    if(rst_n && dut.gen_multi.u_engine.u_shape.state==6)
      $display("PROBE_CENTER frame=%0d proj=%0d deviation=%0d Aspan=%0d",
        dut.gen_multi.u_engine.context_id,dut.gen_multi.u_engine.u_shape.projection,
        dut.gen_multi.u_engine.u_shape.deviation,dut.gen_multi.u_engine.u_shape.product);
  end
  always @(posedge clk) begin
    #1;
    if(rst_n && ready) begin
      seen[result_id]=1;
      seen_valid[result_id]=found;
      seen_shape[result_id]=shapes;
      seen_boxes[result_id]=boxes;
      if(overflow || held!=0) $fatal(1,"Unexpected overflow/held result frame %0d",result_id);
      $display("PROBE_PUBLISHED case=%0d frame=%0d valid=%b held=%b shapes=%b overflow=%b boxes=%h",
        case_id,result_id,found,held,shapes,overflow,boxes);
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
  task expect_shape;
    input integer id, expected;
    begin
      if(seen_valid[id]!==4'b0001 || seen_shape[id][1:0]!==expected[1:0])
        $fatal(1,"Camera regression frame=%0d expected=%0d got=%0d valid=%b",
          id,expected,seen_shape[id][1:0],seen_valid[id]);
      checks=checks+1;
    end
  endtask
  task expect_at;
    input integer id,cx,cy,expected;
    integer s,hits;
    begin
      hits=0;
      for(s=0;s<4;s=s+1)
        if(seen_valid[id][s] &&
           seen_boxes[id][48*s+:12]<=cx && seen_boxes[id][48*s+12+:12]>=cx &&
           seen_boxes[id][48*s+24+:12]<=cy && seen_boxes[id][48*s+36+:12]>=cy) begin
          if(seen_shape[id][2*s+:2]!==expected[1:0])
            $fatal(1,"Cross-track support leak frame=%0d center=%0d,%0d expected=%0d got=%0d",
              id,cx,cy,expected,seen_shape[id][2*s+:2]);
          hits=hits+1;
        end
      if(hits!=1) $fatal(1,"Missing/duplicate track frame=%0d center=%0d,%0d",id,cx,cy);
      checks=checks+1;
    end
  endtask
  task reset_track;
    begin
      blank(5);@(negedge clk);clear=1;
      @(negedge clk);clear=0;blank(3);
    end
  endtask
  task make_square;
    input integer half_q4,cosine,sine,vertical_num,vertical_den;
    integer x,y,dx,dy,u1,v1;
    begin
      for(y=0;y<H;y=y+1)
        for(x=0;x<W;x=x+1) begin
          dx=4*(x-96);dy=4*(y-96);
          u1=dx*cosine+dy*sine;v1=-dx*sine+dy*cosine;
          image[y*W+x]=24'h101010;
          if(u1<=half_q4*1024 && u1>=-half_q4*1024 &&
             v1*vertical_den<=half_q4*1024*vertical_num &&
             v1*vertical_den>=-half_q4*1024*vertical_num)
            image[y*W+x]=24'hf02020;
        end
    end
  endtask
  task make_circle;
    input real radius,amplitude;
    integer x,y;
    real dx,dy,theta,boundary;
    begin
      for(y=0;y<H;y=y+1)
        for(x=0;x<W;x=x+1) begin
          dx=x-96;dy=y-96;theta=$atan2(dy,dx);
          boundary=radius+amplitude*$cos(8.0*theta);
          image[y*W+x]=(dx*dx+dy*dy<=boundary*boundary) ? 24'hf02020 : 24'h101010;
        end
    end
  endtask
  task make_four;
    input integer perturbed;
    integer x,y,s,cx,cy,dx,dy;
    real theta,boundary;
    begin
      for(y=0;y<H;y=y+1)
        for(x=0;x<W;x=x+1) image[y*W+x]=24'h101010;
      for(s=0;s<4;s=s+1) begin
        cx=(s%2==0) ? 56 : 216;cy=(s<2) ? 56 : 176;
        for(y=cy-12;y<=cy+12;y=y+1)
          for(x=cx-12;x<=cx+12;x=x+1) begin
            dx=x-cx;dy=y-cy;theta=$atan2($itor(dy),$itor(dx));
            boundary=10.0+((perturbed && s==0) ? 0.5*$cos(8.0*theta) : 0.0);
            if(perturbed && s==2) begin
              if(dx>=-10 && dx<=10 && dy>=-10 && dy<=10) image[y*W+x]=24'hf02020;
            end else if(dx*dx+dy*dy<=boundary*boundary) image[y*W+x]=24'hf02020;
            if(perturbed && s==1 && dx>=-3 && dx<=3 && dy>=-3 && dy<=3)
              image[y*W+x]=24'h101010;
          end
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
          @(negedge clk);user=0;valid=1;
          for(l=0;l<4;l=l+1) data[95-l*24-:24]=image[y*W+4*g+l];
        end
        if(y!=H-1) blank(96);
      end
      blank(1);cycles=0;
      while(!seen[id] && cycles<30000) begin blank(1);cycles=cycles+1;end
      if(!seen[id]) $fatal(1,"timeout frame %0d",id);
      blank(20);
    end
  endtask
  initial begin
    for(k=0;k<64;k=k+1)seen[k]=0;
    blank(8);rst_n=1;blank(8);
    case_id=1;reset_track();make_square(23,1024,0,1,1);send(1);send(2);
    if(seen_valid[2]!=0) $fatal(1,"Sub-minimum target was accepted");
    case_id=2;reset_track();make_square(23,962,350,1,1);send(3);send(4);
    expect_shape(4,1);
    case_id=3;reset_track();make_square(32,1024,0,1,1);send(5);send(6);
    expect_shape(6,1);
    case_id=4;reset_track();make_square(32,962,350,1,1);send(7);send(8);
    expect_shape(8,1);
    case_id=5;reset_track();make_circle(10.0,0.0);send(9);send(10);
    expect_shape(10,3);
    case_id=6;make_circle(10.0,0.5);send(11);send(12);
    expect_shape(11,3);expect_shape(12,BASELINE ? 1 : 3);
    case_id=7;make_circle(10.0,0.0);send(13);send(14);
    expect_shape(14,3);
    case_id=8;reset_track();make_square(32,1024,0,7,8);send(15);send(16);
    expect_shape(16,BASELINE ? 0 : 1);
    case_id=9;reset_track();make_square(32,962,350,7,8);send(17);send(18);
    expect_shape(18,1);
    // After confirmation, persistent weak circle evidence remains current
    // support beyond the old three-frame expiry, not just a held old label.
    case_id=10;reset_track();make_circle(10.0,0.0);send(19);send(20);
    make_circle(10.0,0.5);send(21);send(22);send(23);send(24);
    expect_shape(20,3);expect_shape(22,BASELINE ? 1 : 3);expect_shape(24,BASELINE ? 1 : 3);
    // Pixel tolerance must not scale into arbitrary rectangle acceptance.
    case_id=11;reset_track();make_square(128,1024,0,13,16);send(25);send(26);
    expect_shape(26,0);
    // A larger centered square and a larger perturbed circle remain positive.
    case_id=12;reset_track();make_square(128,1024,0,15,16);send(27);send(28);
    expect_shape(28,1);
    case_id=13;reset_track();make_circle(32.0,0.5);send(29);send(30);
    expect_shape(30,3);
    // A real shape change must still replace the confirmed circle.
    case_id=14;make_square(128,1024,0,1,1);send(31);send(32);
    expect_shape(31,3);expect_shape(32,1);
    case_id=15;make_circle(32.0,0.0);send(33);send(34);expect_shape(34,3);
    // Invalid contours cannot inherit the preceding weak-circle support.
    for(hole_y=88;hole_y<=104;hole_y=hole_y+1)
      for(hole_x=88;hole_x<=104;hole_x=hole_x+1) image[hole_y*W+hole_x]=24'h101010;
    case_id=16;send(35);send(36);send(37);
    expect_shape(35,3);expect_shape(37,0);
    // Candidate sorting changes with area: support must follow association,
    // independently for a noisy circle, holed circle, new square and circle.
    case_id=17;reset_track();make_four(0);send(38);send(39);
    expect_at(39,56,56,3);expect_at(39,216,56,3);
    expect_at(39,56,176,3);expect_at(39,216,176,3);
    case_id=18;make_four(1);send(40);send(41);send(42);
    expect_at(42,56,56,BASELINE ? 1 : 3);expect_at(42,216,56,0);
    expect_at(42,56,176,1);expect_at(42,216,176,3);
    // Clear resets eligibility for circle hysteresis; a weak circle cannot
    // become a new confirmed circle using the preceding tracks' support.
    case_id=19;reset_track();make_circle(10.0,0.5);send(43);send(44);
    expect_shape(44,1);
    $display("COLOR_SHAPE_CAMERA_PASS baseline=%0d frames=44 checks=%0d",BASELINE,checks);$finish;
  end
  initial begin #50000000;$fatal(1,"watchdog");end
endmodule
