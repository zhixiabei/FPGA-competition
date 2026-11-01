`timescale 1ns/1ps
module tb_single_shape_contour #(parameter integer W=320,H=240,PRODUCTION_PROBE=0);
    localparam CX=W-160,CY=H-120;
    localparam MATH_BITS=$clog2(W>H ? W : H)+2;
    reg clk=0,rst_n=0,clear=0,user=0,valid=0;
    reg [1:0] color_mode=0;
    reg [95:0] data=0;
    reg [9:0] frame_id=0;
    wire ready,overflow;
    wire [3:0] found,held;
    wire [7:0] shapes;
    wire [191:0] boxes;
    wire [9:0] result_id;
    reg [23:0] pixels[0:W*H-1];
    reg seen[0:255];
    reg [1:0] raw_shape[0:255],saved_shape[0:255];
    reg saved_bad[0:255],saved_found[0:255],saved_hold[0:255];
    reg [47:0] saved_box[0:255];
    reg [63:0] saved_area[0:255],saved_perimeter[0:255];
    reg [63:0] saved_mx[0:255],saved_my[0:255];
    integer next_id=1,checks=0,cases=0,n,k,c,base_id,kind,expected;
    integer math_checks=0;
    always #5 clk=~clk;
    red_target_detect_96 #(.IMG_WIDTH(W),.IMG_HEIGHT(H),
        .MULTI_ENABLE(0),.SINGLE_SHAPE_ENABLE(1)) dut (
        .I_clk(clk),.I_rst_n(rst_n),.I_multi_clear(clear),
        .I_tuser(user),.I_tvalid(valid),.I_tdata(data),
        .I_color_mode(color_mode),.I_mask_view_mode(4'd0),.I_frame_id(frame_id),
        .O_mask_pixels(),.O_result_ready(),.O_found(),
        .O_xmin(),.O_xmax(),.O_ymin(),.O_ymax(),.O_center_x(),.O_center_y(),
        .O_pixels(),.O_frame_toggle(),.O_multi_ready(ready),
        .O_multi_valid(found),.O_multi_hold(held),.O_multi_shapes(shapes),
        .O_multi_boxes(boxes),.O_multi_frame_id(result_id),.O_multi_overflow(overflow));
    wire [MATH_BITS-1:0] reference_math=
        dut.gen_single_shape.u_engine.math_left+
        (dut.gen_single_shape.u_engine.math_right ^
            {MATH_BITS{dut.gen_single_shape.u_engine.math_subtract}})+
        (dut.gen_single_shape.u_engine.math_subtract || dut.gen_single_shape.u_engine.math_round);
    always @(posedge clk) begin
        if(rst_n && !clear && !dut.gen_single_shape.u_engine.abort_done &&
           !dut.gen_single_shape.u_engine.frame_done && dut.gen_single_shape.u_engine.math_execute) begin
            if(dut.gen_single_shape.u_engine.math_value !== reference_math)
                $fatal(1,"Registered ALU consumed stale operands");
            math_checks=math_checks+1;
        end
        if(rst_n && dut.gen_single_shape.u_engine.source_accept &&
           (dut.gen_single_shape.u_engine.I_row_end || dut.gen_single_shape.u_engine.I_final) &&
           dut.gen_single_shape.u_engine.next_row_hit &&
           dut.gen_single_shape.u_engine.next_row_connected !==
           (!dut.gen_single_shape.u_engine.previous_row ||
            ({1'b0,dut.gen_single_shape.u_engine.next_row_xmax}+1 >= {1'b0,dut.gen_single_shape.u_engine.r0_xmin} &&
             {1'b0,dut.gen_single_shape.u_engine.next_row_xmin} <= {1'b0,dut.gen_single_shape.u_engine.r0_xmax}+1)))
            $fatal(1,"Factored row connectivity changed semantics");
        if(rst_n && !clear && dut.gen_single_shape.u_engine.r1_valid &&
           dut.gen_single_shape.u_engine.linked_row !==
           (!dut.gen_single_shape.u_engine.r1_first && dut.gen_single_shape.u_engine.work_seen &&
            {1'b0,dut.gen_single_shape.u_engine.r1_y} == {1'b0,dut.gen_single_shape.u_engine.prev_y}+1 &&
            {1'b0,dut.gen_single_shape.u_engine.r1_xmin} <= {1'b0,dut.gen_single_shape.u_engine.prev_xmax}+1 &&
            {1'b0,dut.gen_single_shape.u_engine.r1_xmax}+1 >= {1'b0,dut.gen_single_shape.u_engine.prev_xmin}))
            $fatal(1,"Pipelined component connectivity changed semantics");
        if(rst_n && dut.gen_single_shape.u_engine.shape_ready &&
           dut.gen_single_shape.u_engine.class_state==2) begin
            raw_shape[dut.gen_single_shape.u_engine.job_id]=dut.gen_single_shape.u_engine.shape_result;
            saved_bad[dut.gen_single_shape.u_engine.job_id]=dut.gen_single_shape.u_engine.job_bad;
            saved_area[dut.gen_single_shape.u_engine.job_id]=dut.gen_single_shape.u_engine.job_area;
            saved_perimeter[dut.gen_single_shape.u_engine.job_id]=dut.gen_single_shape.u_engine.job_perimeter;
            saved_mx[dut.gen_single_shape.u_engine.job_id]=dut.gen_single_shape.u_engine.job_mx2;
            saved_my[dut.gen_single_shape.u_engine.job_id]=dut.gen_single_shape.u_engine.job_my2;
        end
        #1;
        if(rst_n && ready) begin
            if(overflow || result_id>=256 || seen[result_id] || found[3:1] ||
               held[3:1] || shapes[7:2] || boxes[191:48]) $fatal(1,"Invalid result transport");
            seen[result_id]=1;saved_shape[result_id]=shapes[1:0];
            saved_found[result_id]=found[0];saved_hold[result_id]=held[0];
            saved_box[result_id]=boxes[47:0];
        end
    end
    function integer abs_i;
        input integer a;
        begin abs_i=a<0 ? -a : a;end
    endfunction
    task blank;
        input integer cycles;
        integer t;
        begin for(t=0;t<cycles;t=t+1)begin @(negedge clk);valid=0;user=0;data=0;end end
    endtask
    task reset_track;
        begin blank(4);@(negedge clk);clear=1;@(negedge clk);clear=0;blank(4);end
    endtask
    task scene;
        input integer shape;
        integer x,y,dx,dy,u,v;
        reg hit;
        reg [23:0] rgb;
        begin
            rgb=color_mode==1 ? 24'h209620 : color_mode==2 ? 24'h2020f0 : 24'hf02020;
            for(y=0;y<H;y=y+1)for(x=0;x<W;x=x+1)begin
                dx=x-CX;dy=y-CY;u=dx*962+dy*350;v=-dx*350+dy*962;
                case(shape)
                    0:hit=abs_i(dx)<=40 && abs_i(dy)<=40;
                    1:hit=abs_i(u)<=40*1024 && abs_i(v)<=40*1024;
                    2:hit=dx*dx+dy*dy<=44*44;
                    3:hit=dy>=-48 && dy<=40 && abs_i(dx)*88<=(dy+48)*48;
                    4:hit=abs_i(dx)<=60 && abs_i(dy)<=24;
                    5:hit=abs_i(dx)<=58 && abs_i(dy)<=28 &&
                        dx*dx*28*28+dy*dy*58*58<=58*58*28*28;
                    6:hit=dx*dx+dy*dy<=44*44 && dx*dx+dy*dy>=23*23;
                    7:hit=abs_i(dx)<=40 && abs_i(dy)<=40 && (abs_i(dx)>=25 || dy>=25);
                    default:hit=0;
                endcase
                pixels[y*W+x]=hit ? rgb : 24'h101010;
            end
        end
    endtask
    task hole;
        input integer dx,dy,width,height;
        integer x,y;
        begin for(y=CY+dy;y<CY+dy+height;y=y+1)
            for(x=CX+dx;x<CX+dx+width;x=x+1)pixels[y*W+x]=24'hffffff;end
    endtask
    task frame;
        integer y,g,l,t;
        begin
            @(negedge clk);user=1;valid=0;frame_id=next_id;
            @(negedge clk);user=0;frame_id=999;
            for(y=0;y<H;y=y+1)begin
                for(g=0;g<W/4;g=g+1)begin
                    if((y*(W/4)+g)%37==0)blank(1);
                    @(negedge clk);valid=1;
                    for(l=0;l<4;l=l+1)data[95-l*24-:24]=pixels[y*W+4*g+l];
                end
                if(next_id%2)blank(2);
            end
            blank(1);t=0;
            while(!seen[next_id] && t<30000)begin blank(1);t=t+1;end
            if(!seen[next_id])$fatal(1,"Missing result id=%0d",next_id);
            next_id=next_id+1;
        end
    endtask
    task expect_raw;
        input integer shape;
        begin
            if(raw_shape[next_id-1]!==shape[1:0])
                $fatal(1,"Raw shape id=%0d kind=%0d expected=%0d got=%0d bad=%b",
                    next_id-1,kind,shape,raw_shape[next_id-1],saved_bad[next_id-1]);
            checks=checks+1;
        end
    endtask
    task expect_repaired;
        input integer reference_id,shape;
        begin
            expect_raw(shape);
            if(!saved_found[next_id-1] || saved_hold[next_id-1] || saved_bad[next_id-1] ||
               saved_shape[next_id-1]!==shape[1:0] || saved_box[next_id-1]!==saved_box[reference_id] ||
               saved_area[next_id-1]!==saved_area[reference_id] ||
               saved_perimeter[next_id-1]!==saved_perimeter[reference_id] ||
               saved_mx[next_id-1]!==saved_mx[reference_id] ||
               saved_my[next_id-1]!==saved_my[reference_id])
                $fatal(1,"Repaired descriptor differs from clean silhouette id=%0d reference=%0d",next_id-1,reference_id);
            checks=checks+1;
        end
    endtask
    initial begin
        for(n=0;n<256;n=n+1)begin seen[n]=0;raw_shape[n]=0;saved_bad[n]=0;end
        blank(8);@(negedge clk);rst_n=1;blank(8);
        if(PRODUCTION_PROBE)begin
            for(c=0;c<3;c=c+1)begin
                color_mode=c;
                for(kind=0;kind<(c==0 ? 4 : 1);kind=kind+1)begin
                    expected=kind==2 ? 3 : kind==3 ? 2 : 1;
                    reset_track();scene(kind);frame();expect_raw(expected);frame();base_id=next_id-1;
                    hole(-4,-4,9,9);frame();expect_repaired(base_id,expected);cases=cases+1;
                end
            end
            color_mode=0;kind=6;reset_track();scene(6);frame();frame();expect_raw(0);cases=cases+1;
            kind=0;reset_track();scene(0);hole(-12,-12,25,25);frame();frame();expect_raw(0);cases=cases+1;
        end else begin
        for(c=0;c<3;c=c+1)begin
            color_mode=c;
            for(kind=0;kind<4;kind=kind+1)begin
                expected=kind==2 ? 3 : kind==3 ? 2 : 1;
                reset_track();scene(kind);frame();expect_raw(expected);frame();base_id=next_id-1;
                scene(kind);hole(-4,-4,9,9);frame();expect_repaired(base_id,expected);
                frame();expect_repaired(base_id,expected);frame();expect_repaired(base_id,expected);
                // Acquisition must work without a previously confirmed shape.
                reset_track();frame();expect_raw(expected);frame();expect_repaired(base_id,expected);
                // Move the hole through all four input-lane alignments.
                for(k=0;k<4;k=k+1)begin scene(kind);hole(k-8,4,5,5);frame();expect_repaired(base_id,expected);end
                cases=cases+1;
            end
        end
        color_mode=0;kind=0;
        reset_track();scene(0);frame();frame();base_id=next_id-1;
        hole(-4,-8,9,16);frame();expect_repaired(base_id,1);cases=cases+1;
        reset_track();scene(0);hole(-4,-8,9,17);frame();frame();expect_raw(0);cases=cases+1;
        for(k=0;k<4;k=k+1)begin
            reset_track();scene(0);
            case(k)
                0:hole(-12,-12,25,25);
                1:hole(-3,-28,7,57);
                2:hole(-3,0,7,41);
                3:begin hole(-18,-18,9,9);hole(8,-18,9,9);hole(-18,8,9,9);hole(8,8,9,9);end
            endcase
            frame();expect_raw(0);frame();expect_raw(0);
            if(saved_shape[next_id-1]!=0)$fatal(1,"Invalid contour gained a known shape");
            cases=cases+1;
        end
        for(kind=4;kind<8;kind=kind+1)begin reset_track();scene(kind);frame();frame();expect_raw(0);cases=cases+1;end
        // The shape must recover after invalid input; no repair state may leak.
        scene(0);frame();frame();expect_raw(1);
        if(saved_shape[next_id-1]!=1)$fatal(1,"Shape did not recover");
        end
        if(math_checks != (next_id-1)*54)$fatal(1,"Missing or duplicate frame-rate ALU operations");
        $display("SINGLE_SHAPE_CONTOUR_PASS W=%0d H=%0d frames=%0d cases=%0d checks=%0d math_checks=%0d",W,H,next_id-1,cases,checks,math_checks);
        $finish;
    end
    initial begin #(64'd4000000000);$fatal(1,"Watchdog");end
endmodule
