`timescale 1ns/1ps
// Independent public-RGB stimuli. Expected geometry comes from rasterized
// objects, not the detector's measurements. No internal state is forced.
module tb_single_color_repair #(parameter integer TEST_GROUP=0);
    localparam W=640,H=480,GROUPS=W/4;
    reg clk=0,rst_n=0,clear=0,user=0,valid=0;
    reg [1:0] mode=0;
    reg [95:0] data=0;
    reg [9:0] frame_id=0;
    wire ready,overflow;
    wire [3:0] found,held;
    wire [7:0] shapes;
    wire [191:0] boxes;
    wire [9:0] result_id;
    always #5 clk=~clk;
    red_target_detect_96 #(.IMG_WIDTH(W),.IMG_HEIGHT(H),.MIN_PIXELS(128),
        .MULTI_ENABLE(0),.SINGLE_SHAPE_ENABLE(1)) dut (
        .I_clk(clk),.I_rst_n(rst_n),.I_tuser(user),.I_tvalid(valid),.I_tdata(data),
        .I_color_mode(mode),.I_mask_view_mode(4'd0),.O_mask_pixels(),
        .I_frame_id(frame_id),.I_multi_clear(clear),
        .O_result_ready(),.O_found(),.O_xmin(),.O_xmax(),.O_ymin(),.O_ymax(),
        .O_center_x(),.O_center_y(),.O_pixels(),.O_frame_toggle(),
        .O_multi_ready(ready),.O_multi_valid(found),.O_multi_hold(held),
        .O_multi_boxes(boxes),.O_multi_shapes(shapes),.O_multi_frame_id(result_id),
        .O_multi_overflow(overflow));
    reg [23:0] pixels[0:W*H-1];
    reg [47:0] seen_box[0:255];
    reg [1:0] seen_shape[0:255];
    reg seen[0:255],seen_valid[0:255],seen_hold[0:255];
    integer next_id=1,checks=0,n,x,y,g,l,k,c,s;
    integer exmin,exmax,eymin,eymax;
    reg [47:0] reference_box;
    always @(posedge clk) begin
        #1;
        if(rst_n && ready) begin
            if(overflow || found[3:1] || held[3:1] || shapes[7:2] || boxes[191:48])
                $fatal(1,"Invalid single-target transport id=%0d",result_id);
            if(result_id>=256 || seen[result_id]) $fatal(1,"Duplicate result");
            seen[result_id]=1;seen_box[result_id]=boxes[47:0];
            seen_shape[result_id]=shapes[1:0];seen_valid[result_id]=found[0];
            seen_hold[result_id]=held[0];
        end
    end
    task blank;
        input integer cycles;
        integer t;
        begin for(t=0;t<cycles;t=t+1) begin
            @(negedge clk);valid=0;user=0;data=0;
        end end
    endtask
    task reset_track;
        begin blank(4);@(negedge clk);clear=1;@(negedge clk);clear=0;blank(4);end
    endtask
    task background;
        integer i;
        begin for(i=0;i<W*H;i=i+1) pixels[i]=24'h101010;end
    endtask
    function integer abs_i;
        input integer a;
        begin abs_i=a<0 ? -a : a;end
    endfunction
    task square;
        input integer cx,cy,half_side,co,si;
        input [23:0] rgb;
        integer xx,yy,dx,dy,u,v;
        begin
            exmin=W;exmax=0;eymin=H;eymax=0;
            for(yy=0;yy<H;yy=yy+1) for(xx=0;xx<W;xx=xx+1) begin
                dx=xx-cx;dy=yy-cy;u=dx*co+dy*si;v=-dx*si+dy*co;
                if(abs_i(u)<=half_side*1024 && abs_i(v)<=half_side*1024) begin
                    pixels[yy*W+xx]=rgb;
                    if(xx<exmin)exmin=xx;if(xx>exmax)exmax=xx;
                    if(yy<eymin)eymin=yy;if(yy>eymax)eymax=yy;
                end
            end
        end
    endtask
    task disk;
        input integer radius;
        integer xx,yy;
        begin
            exmin=320-radius;exmax=320+radius;eymin=240-radius;eymax=240+radius;
            for(yy=0;yy<H;yy=yy+1) for(xx=0;xx<W;xx=xx+1)
                if((xx-320)*(xx-320)+(yy-240)*(yy-240)<=radius*radius)
                    pixels[yy*W+xx]=24'hf02020;
        end
    endtask
    task frame;
        integer yy,gg,ll,waits;
        begin
            @(negedge clk);user=1;valid=0;frame_id=next_id;
            @(negedge clk);user=0;frame_id=999;
            for(yy=0;yy<H;yy=yy+1) begin
                for(gg=0;gg<GROUPS;gg=gg+1) begin
                    @(negedge clk);valid=1;
                    for(ll=0;ll<4;ll=ll+1)data[95-ll*24-:24]=pixels[yy*W+4*gg+ll];
                end
                blank(2);
            end
            blank(1);waits=0;
            while(!seen[next_id] && waits<30000) begin blank(1);waits=waits+1;end
            if(!seen[next_id])$fatal(1,"Missing frame %0d",next_id);
            next_id=next_id+1;
        end
    endtask
    task expect_shape;
        input integer expected;
        begin
            if(!seen_valid[next_id-1] || seen_hold[next_id-1] || seen_shape[next_id-1]!==expected[1:0])
                $fatal(1,"SHAPE id=%0d expected=%0d valid/hold/shape=%b/%b/%0d raw_bad=%b",
                    next_id-1,expected,seen_valid[next_id-1],seen_hold[next_id-1],
                    seen_shape[next_id-1],dut.gen_single_shape.u_engine.snap_bad);
            checks=checks+1;
        end
    endtask
    task expect_bounds;
        input integer tolerance;
        integer a,b,d,e;
        begin
            a=seen_box[next_id-1][11:0];b=seen_box[next_id-1][23:12];
            d=seen_box[next_id-1][35:24];e=seen_box[next_id-1][47:36];
            if(abs_i(a-exmin)>tolerance || abs_i(b-exmax)>tolerance ||
                abs_i(d-eymin)>tolerance || abs_i(e-eymax)>tolerance)
                $fatal(1,"BOUNDS id=%0d got=%0d,%0d,%0d,%0d expected=%0d,%0d,%0d,%0d",
                    next_id-1,a,b,d,e,exmin,exmax,eymin,eymax);
            checks=checks+1;
        end
    endtask
    task color_case;
        input [23:0] rgb;
        input integer accepted;
        begin
            reset_track();background();square(320,240,40,1024,0,rgb);frame();frame();
            if(seen_valid[next_id-1]!==accepted[0])
                $fatal(1,"COLOR rgb=%h expected=%0d got=%b",rgb,accepted,seen_valid[next_id-1]);
            if(accepted)begin expect_shape(1);expect_bounds(2);end
            checks=checks+1;
        end
    endtask
    initial begin
        for(n=0;n<256;n=n+1)begin seen[n]=0;seen_box[n]=0;seen_shape[n]=0;seen_valid[n]=0;seen_hold[n]=0;end
        blank(8);@(negedge clk);rst_n=1;blank(8);
        if(TEST_GROUP==0 || TEST_GROUP==1) begin
            color_case(24'hdc5028,1);color_case(24'hdc2850,1);
            color_case(24'hdca0a0,1);color_case(24'h781010,1);
            color_case(24'hf05a1e,0);color_case(24'hf08c14,0);
            color_case(24'hf0c0c0,0);color_case(24'hf0f0f0,0);
            mode=1;color_case(24'h50961e,1);mode=2;color_case(24'h2020f0,1);mode=0;
            $display("SINGLE_COLOR_REPAIR_COLOR_PASS");
        end
        if(TEST_GROUP==0 || TEST_GROUP==2) begin
            for(k=0;k<11;k=k+1) begin
                case(k)
                    0:begin c=1024;s=0;end
                    1:begin c=1024;s=18;end
                    2:begin c=1023;s=36;end
                    3:begin c=1020;s=89;end
                    4:begin c=1008;s=178;end
                    5:begin c=962;s=350;end
                    6:begin c=887;s=512;end
                    7:begin c=724;s=724;end
                    8:begin c=1024;s=-18;end
                    9:begin c=1023;s=-36;end
                    10:begin c=1020;s=-89;end
                endcase
                reset_track();background();square(320,240,96,c,s,24'hf02020);
                frame();frame();expect_shape(1);expect_bounds(4);
            end
            reset_track();background();disk(180);frame();frame();expect_shape(3);expect_bounds(4);
            // Continuous rotation must expand the displayed box immediately.
            reset_track();background();square(320,240,72,1024,0,24'hf02020);frame();frame();
            background();square(320,240,72,962,350,24'hf02020);frame();expect_shape(1);expect_bounds(4);
            background();square(320,240,72,724,724,24'hf02020);frame();expect_shape(1);expect_bounds(4);
            // A moderately pale highlight stripe is still red evidence.
            reset_track();background();square(320,240,72,1024,0,24'hf02020);
            for(y=200;y<=280;y=y+1)for(x=310;x<=330;x=x+1)pixels[y*W+x]=24'hdca0a0;
            frame();frame();expect_shape(1);expect_bounds(2);
            $display("SINGLE_COLOR_REPAIR_GEOMETRY_PASS");
        end
        if(TEST_GROUP==0 || TEST_GROUP==3) begin
            reset_track();background();square(320,240,48,1024,0,24'hf02020);frame();frame();
            expect_shape(1);reference_box=seen_box[next_id-1];
            // An earlier unrelated run on the SAME row must be discarded as
            // a whole, then the existing connected contour can still be read.
            for(y=216;y<=264;y=y+1)for(x=230;x<=250;x=x+1)pixels[y*W+x]=24'hf02020;
            frame();expect_shape(1);expect_bounds(2);
            if(seen_box[next_id-1]!==reference_box)$fatal(1,"Same-row distractor changed box");
            background();square(320,240,48,1024,0,24'hf02020);
            // An earlier qualified region inside the search window is not the track.
            for(y=150;y<=174;y=y+1)for(x=302;x<=326;x=x+1)pixels[y*W+x]=24'hf02020;
            frame();expect_shape(1);
            if(seen_box[next_id-1]!==reference_box)$fatal(1,"Earlier distractor changed box");
            background();square(320,240,48,1024,0,24'hf02020);
            for(y=192;y<=288;y=y+1)for(x=340;x<=368;x=x+1)pixels[y*W+x]=24'h101010;
            frame();
            if(!seen_valid[next_id-1] || !seen_hold[next_id-1] || seen_box[next_id-1]!==reference_box)
                $fatal(1,"Transient missing edge moved box");
            background();square(320,240,48,1024,0,24'hf02020);frame();expect_shape(1);
            if(seen_box[next_id-1]!==reference_box)$fatal(1,"Recovery changed stable box");
            checks=checks+3;
            $display("SINGLE_COLOR_REPAIR_TRACK_PASS");
        end
        $display("SINGLE_COLOR_REPAIR_PASS group=%0d frames=%0d checks=%0d",TEST_GROUP,next_id-1,checks);
        $finish;
    end
    initial begin #2000000000;$fatal(1,"Watchdog");end
endmodule
