`timescale 1ns/1ps
module tb_color_shape_target #(
    parameter integer W=320,
    parameter integer H=240,
    parameter integer GEOMETRY_PROBE_ONLY=0
);
    localparam integer GROUPS=W/4;
    localparam [1:0] SH_UNKNOWN=0, SH_SQUARE=1, SH_TRIANGLE=2, SH_CIRCLE=3;
    reg clk=0, rst_n=0, clear=0, user=0, valid=0;
    reg [1:0] color_mode=0;
    reg [3:0] mask_view_mode=0;
    reg [95:0] data=0;
    reg [9:0] frame_id=0;
    wire ready, overflow;
    wire [3:0] found, held;
    wire [7:0] shapes;
    wire [191:0] boxes;
    wire [9:0] result_id;
    always #5 clk=~clk;

    red_target_detect_96 #(
        .IMG_WIDTH(W), .IMG_HEIGHT(H), .MIN_PIXELS(64),
        .MIN_WIDTH(8), .MIN_HEIGHT(8), .MULTI_ENABLE(1)
    ) dut (
        .I_clk(clk), .I_rst_n(rst_n), .I_tuser(user), .I_tvalid(valid),
        .I_tdata(data), .I_color_mode(color_mode),
        .I_mask_view_mode(mask_view_mode), .O_mask_pixels(),
        .I_frame_id(frame_id), .I_multi_clear(clear),
        .O_result_ready(), .O_found(), .O_xmin(), .O_xmax(), .O_ymin(), .O_ymax(),
        .O_center_x(), .O_center_y(), .O_pixels(), .O_frame_toggle(),
        .O_multi_ready(ready), .O_multi_valid(found), .O_multi_hold(held),
        .O_multi_boxes(boxes), .O_multi_shapes(shapes),
        .O_multi_frame_id(result_id), .O_multi_overflow(overflow)
    );

    reg [23:0] image [0:W*H-1];
    reg seen [0:127];
    reg [3:0] seen_found [0:127], seen_held [0:127];
    reg [7:0] seen_shapes [0:127];
    reg [191:0] seen_boxes [0:127];
    reg seen_overflow [0:127];
    reg [23:0] foreground=24'hf02020;
    integer checks=0, results=0, n, slot, previous_slot;
    integer noisy_id=64, noisy_cases=0, noisy_phase;
    reg [12:0] noisy_view_modes=0;
    integer multi_slots [0:3];
    integer raw_unknown=0, raw_hard_bad=0, raw_size_border=0;
    integer raw_geometry=0, raw_centroid=0, raw_metric=0, geometry_probes=0;
    integer current_probe=-1;

    // Observe the classifier before track smoothing. A passing held label
    // must not conceal a persistent contour or geometry rejection.
    always @(negedge clk) begin
        if(GEOMETRY_PROBE_ONLY && rst_n &&
           dut.gen_multi.u_engine.shape_ready && current_probe>=0)
            $display("COLOR_SHAPE_GEOMETRY_RAW pattern=%0d frame=%0d shape=%0d hard_bad=%b iso=%b centered=%b circle_metric=%b square_metric=%b triangle_metric=%b circle_fill=%b skew=%b",
                current_probe,dut.gen_multi.u_engine.context_id,
                dut.gen_multi.u_engine.shape_result,
                dut.gen_multi.u_engine.class_bad,
                dut.gen_multi.u_engine.u_shape.isotropic,
                dut.gen_multi.u_engine.u_shape.centered,
                dut.gen_multi.u_engine.u_shape.circle_metric,
                dut.gen_multi.u_engine.u_shape.square_metric,
                dut.gen_multi.u_engine.u_shape.triangle_metric,
                dut.gen_multi.u_engine.u_shape.circle_fill,
                dut.gen_multi.u_engine.u_shape.skew);
        if(rst_n && dut.gen_multi.u_engine.shape_ready &&
           dut.gen_multi.u_engine.shape_result==SH_UNKNOWN) begin
            raw_unknown=raw_unknown+1;
            if(dut.gen_multi.u_engine.class_bad)
                raw_hard_bad=raw_hard_bad+1;
            else if(dut.gen_multi.u_engine.top_xmin[dut.gen_multi.u_engine.class_index]<=3 ||
                    dut.gen_multi.u_engine.top_ymin[dut.gen_multi.u_engine.class_index]<=3 ||
                    dut.gen_multi.u_engine.top_xmax[dut.gen_multi.u_engine.class_index]>=W-4 ||
                    dut.gen_multi.u_engine.top_ymax[dut.gen_multi.u_engine.class_index]>=H-4 ||
                    dut.gen_multi.u_engine.top_xmax[dut.gen_multi.u_engine.class_index]-
                        dut.gen_multi.u_engine.top_xmin[dut.gen_multi.u_engine.class_index]<11 ||
                    dut.gen_multi.u_engine.top_ymax[dut.gen_multi.u_engine.class_index]-
                        dut.gen_multi.u_engine.top_ymin[dut.gen_multi.u_engine.class_index]<11)
                raw_size_border=raw_size_border+1;
            else begin
                if(!dut.gen_multi.u_engine.u_shape.isotropic)
                    raw_geometry=raw_geometry+1;
                if(!dut.gen_multi.u_engine.u_shape.centered ||
                   (dut.gen_multi.u_engine.u_shape.triangle_metric &&
                    !dut.gen_multi.u_engine.u_shape.skew))
                    raw_centroid=raw_centroid+1;
                if(!(dut.gen_multi.u_engine.u_shape.circle_metric &&
                     dut.gen_multi.u_engine.u_shape.circle_fill) &&
                   !(dut.gen_multi.u_engine.u_shape.square_metric &&
                     !dut.gen_multi.u_engine.u_shape.circle_fill) &&
                   !dut.gen_multi.u_engine.u_shape.triangle_metric)
                    raw_metric=raw_metric+1;
            end
            $display("COLOR_SHAPE_RAW_UNKNOWN frame=%0d candidate=%0d hard_bad=%b iso=%b centered=%b circle_metric=%b square_metric=%b triangle_metric=%b circle_fill=%b skew=%b",
                dut.gen_multi.u_engine.context_id,dut.gen_multi.u_engine.class_index,
                dut.gen_multi.u_engine.class_bad,
                dut.gen_multi.u_engine.u_shape.isotropic,
                dut.gen_multi.u_engine.u_shape.centered,
                dut.gen_multi.u_engine.u_shape.circle_metric,
                dut.gen_multi.u_engine.u_shape.square_metric,
                dut.gen_multi.u_engine.u_shape.triangle_metric,
                dut.gen_multi.u_engine.u_shape.circle_fill,
                dut.gen_multi.u_engine.u_shape.skew);
        end
    end

    always @(posedge clk) begin
        #1;
        if (rst_n && ready) begin
            if (result_id >= 128 || seen[result_id])
                $fatal(1,"Duplicate/unexpected shape result id=%0d",result_id);
            seen[result_id]=1;
            seen_found[result_id]=found; seen_held[result_id]=held;
            seen_shapes[result_id]=shapes; seen_boxes[result_id]=boxes;
            seen_overflow[result_id]=overflow;
            results=results+1;
        end
    end

    function integer abs_i;
        input integer value;
        begin abs_i=value < 0 ? -value : value; end
    endfunction
    function integer pop4;
        input [3:0] bits;
        begin pop4=bits[0]+bits[1]+bits[2]+bits[3]; end
    endfunction
    function integer reference_color;
        input [23:0] value;
        input integer color;
        integer r,g,b,d,a,c;
        begin
            r=value[23:16]; g=value[15:8]; b=value[7:0];
            case(color)
                1: begin d=g; a=r; c=b; end
                2: begin d=b; a=r; c=g; end
                default: begin d=r; a=g; c=b; end
            endcase
            reference_color=d>=24 && d-a>=6 && d-c>=6 &&
                (color==1 ? (4*d>=5*a && 4*d>=5*c) :
                (2*d>=3*a && 2*d>=3*c && 3*a<=d+2*c && 3*c<=d+2*a));
        end
    endfunction
    function integer bxmin;
        input integer id, s;
        begin bxmin=seen_boxes[id][s*48+:12]; end
    endfunction
    function integer bxmax;
        input integer id, s;
        begin bxmax=seen_boxes[id][s*48+12+:12]; end
    endfunction
    function integer bymin;
        input integer id, s;
        begin bymin=seen_boxes[id][s*48+24+:12]; end
    endfunction
    function integer bymax;
        input integer id, s;
        begin bymax=seen_boxes[id][s*48+36+:12]; end
    endfunction
    function [1:0] result_shape;
        input integer id, s;
        begin result_shape=seen_shapes[id][s*2+:2]; end
    endfunction

    // Patterns are constructed from geometry, independently of the detector's
    // area/perimeter implementation and classification thresholds.
    function integer in_triangle;
        input integer x,y,ax,ay,bx,by,cx,cy;
        integer ab,bc,ca;
        begin
            ab=(x-ax)*(by-ay)-(y-ay)*(bx-ax);
            bc=(x-bx)*(cy-by)-(y-by)*(cx-bx);
            ca=(x-cx)*(ay-cy)-(y-cy)*(ax-cx);
            in_triangle=(ab>=0 && bc>=0 && ca>=0) ||
                        (ab<=0 && bc<=0 && ca<=0);
        end
    endfunction
    task background;
        integer index;
        begin
            for(index=0;index<W*H;index=index+1) image[index]=24'h101010;
        end
    endtask
    task square;
        input integer cx,cy,half_side,cosine,sine;
        integer x,y,dx,dy,u,v;
        begin
            for(y=1;y<H-1;y=y+1)
                for(x=1;x<W-1;x=x+1) begin
                    dx=x-cx; dy=y-cy;
                    u=dx*cosine+dy*sine;
                    v=-dx*sine+dy*cosine;
                    if(abs_i(u)<=half_side*1024 && abs_i(v)<=half_side*1024)
                        image[y*W+x]=foreground;
                end
        end
    endtask
    task square_quarter;
        input integer cx_q4,cy_q4,half_side_q4,cosine,sine;
        integer x,y,u,v;
        begin
            for(y=1;y<H-1;y=y+1)
                for(x=1;x<W-1;x=x+1) begin
                    u=(4*x-cx_q4)*cosine+(4*y-cy_q4)*sine;
                    v=-(4*x-cx_q4)*sine+(4*y-cy_q4)*cosine;
                    if(abs_i(u)<=half_side_q4*1024 &&
                       abs_i(v)<=half_side_q4*1024)
                        image[y*W+x]=foreground;
                end
        end
    endtask
    task disk;
        input integer cx,cy,radius;
        integer x,y;
        begin
            for(y=1;y<H-1;y=y+1)
                for(x=1;x<W-1;x=x+1)
                    if((x-cx)*(x-cx)+(y-cy)*(y-cy)<=radius*radius)
                        image[y*W+x]=foreground;
        end
    endtask
    task disk_quarter;
        input integer cx_q4,cy_q4,radius_q4;
        integer x,y;
        begin
            for(y=1;y<H-1;y=y+1)
                for(x=1;x<W-1;x=x+1)
                    if((4*x-cx_q4)*(4*x-cx_q4)+(4*y-cy_q4)*(4*y-cy_q4)
                        <=radius_q4*radius_q4)
                        image[y*W+x]=foreground;
        end
    endtask
    task triangle;
        input integer ax,ay,bx,by,cx,cy;
        integer x,y;
        begin
            for(y=1;y<H-1;y=y+1)
                for(x=1;x<W-1;x=x+1)
                    if(in_triangle(x,y,ax,ay,bx,by,cx,cy))
                        image[y*W+x]=foreground;
        end
    endtask
    task pattern;
        input integer kind,offset;
        integer x,y,dx,dy,ax,ay,bx,by,cx,cy,edge_index,row_shift;
        integer notch_depth,notch_width,notch_start;
        begin
            background();
            case(kind)
                0: square(96+offset,96,32,1024,0);
                1: square(96+offset,96,32,962,350);
                2: square(96+offset,96,32,724,724);
                3: disk(96+offset,96,32);
                4: triangle(61+offset,129,131+offset,129,78+offset,59);
                5: begin
                    // Rotate the same scalene triangle through 26 degrees.
                    ax=96+((-35*921)-(33*449))/1024;
                    ay=96+((-35*449)+(33*921))/1024;
                    bx=96+((35*921)-(33*449))/1024;
                    by=96+((35*449)+(33*921))/1024;
                    cx=96+((-18*921)-(-37*449))/1024;
                    cy=96+((-18*449)+(-37*921))/1024;
                    triangle(ax+offset,ay,bx+offset,by,cx+offset,cy);
                end
                6: begin
                    for(y=80;y<=111;y=y+1)
                        for(x=40+offset;x<=151+offset;x=x+1)
                            image[y*W+x]=foreground;
                end
                7: begin
                    for(y=1;y<H-1;y=y+1)
                        for(x=1;x<W-1;x=x+1) begin
                            dx=x-(96+offset); dy=y-96;
                            if(dx*dx*20*20+dy*dy*56*56<=56*56*20*20)
                                image[y*W+x]=foreground;
                        end
                end
                8: begin
                    disk(96+offset,96,34);
                    for(y=1;y<H-1;y=y+1)
                        for(x=1;x<W-1;x=x+1) begin
                            dx=x-(96+offset); dy=y-96;
                            if(dx*dx+dy*dy<18*18) image[y*W+x]=24'h101010;
                        end
                end
                9: begin
                    for(y=60;y<=132;y=y+1)
                        for(x=60+offset;x<=132+offset;x=x+1)
                            if(abs_i(x-(96+offset))<=10 || abs_i(y-96)<=10)
                                image[y*W+x]=foreground;
                end
                10: begin
                    square(48+offset,48,21,1024,0);
                    disk(140+offset,48,24);
                    triangle(216+offset,72,264+offset,72,226+offset,24);
                    square(130+offset,158,23,724,724);
                end
                11: begin end
                12: begin
                    // Last permitted interior rows must reach finalization.
                    square(W-34,H-34,32,1024,0);
                end
                13: begin
                    // Large translated coordinates exercise moment widths
                    // and diagonal projections at production resolution.
                    disk(1000,520,32);
                    square(1160,520,32,962,350);
                    triangle(968,670,1040,670,984,594);
                end
                14,15,16: begin
                    square(96+offset,96,32,1024,0);
                    if(kind==14) begin
                        // A five-pixel white highlight leaves a real hole
                        // after the previous majority-only cleanup.
                        image[96*W+96+offset]=24'hffffff;
                        image[95*W+96+offset]=24'hffffff;
                        image[97*W+96+offset]=24'hffffff;
                        image[96*W+95+offset]=24'hffffff;
                        image[96*W+97+offset]=24'hffffff;
                    end else begin
                        // Both orientations cross a four-pixel beat boundary.
                        for(y=95;y<=(kind==15 ? 96 : 97);y=y+1)
                            for(x=95+offset;
                                x<=(kind==15 ? 97+offset : 96+offset);x=x+1)
                                image[y*W+x]=24'he0e0e0;
                    end
                end
                17: begin
                    // Same 60x60 area as an axis-aligned square, but opposite
                    // sides move by one pixel every three image rows.
                    for(y=66;y<=125;y=y+1) begin
                        row_shift=((y-66)/3)%2==0 ? -1 : 1;
                        for(x=66+offset+row_shift;x<=125+offset+row_shift;x=x+1)
                            image[y*W+x]=foreground;
                    end
                end
                18,24,25,26,27: begin
                    square(96+offset,96,32,1024,0);
                    // Width-three notches model threshold flicker on an edge.
                    // Sparse width-two/depth-one dents are a positive case.
                    // Width-two/depth-two and dense width-three repeated
                    // dents stay UNKNOWN: closing does not reconstruct every
                    // missing edge, even when an interior hole is repairable.
                    notch_depth=(kind==24 || kind==26) ? 1 :
                                (kind==25 || kind==27) ? 2 : 3;
                    notch_width=kind>=26 ? 2 : 3;
                    notch_start=kind>=26 ? 95 : 68;
                    for(edge_index=0;edge_index<(kind>=26 ? 1 : 8);
                        edge_index=edge_index+1)
                        for(y=0;y<notch_depth;y=y+1)
                            for(x=0;x<notch_width;x=x+1) begin
                                image[(64+y)*W+notch_start+7*edge_index+x+offset]=24'h101010;
                                image[(128-y)*W+notch_start+7*edge_index+x+offset]=24'h101010;
                                image[(notch_start+7*edge_index+x)*W+64+y+offset]=24'h101010;
                                image[(notch_start+7*edge_index+x)*W+128-y+offset]=24'h101010;
                            end
                end
                19,20: begin
                    triangle(61+offset,129,131+offset,129,78+offset,59);
                    if(kind==19) begin
                        image[96*W+88+offset]=24'hffffff;
                        image[95*W+88+offset]=24'hffffff;
                        image[97*W+88+offset]=24'hffffff;
                        image[96*W+87+offset]=24'hffffff;
                        image[96*W+89+offset]=24'hffffff;
                    end else begin
                        for(y=95;y<=97;y=y+1)
                            for(x=87+offset;x<=88+offset;x=x+1)
                                image[y*W+x]=24'he0e0e0;
                    end
                end
                21: begin
                    disk(96+offset,96,32);
                    image[96*W+96+offset]=24'hffffff;
                    image[95*W+96+offset]=24'hffffff;
                    image[97*W+96+offset]=24'hffffff;
                    image[96*W+95+offset]=24'hffffff;
                    image[96*W+97+offset]=24'hffffff;
                end
                22,23: begin
                    for(y=1;y<H-1;y=y+1) begin
                        row_shift=(y/3)%2==0 ? -1 : 1;
                        for(x=1;x<W-1;x=x+1) begin
                            dx=x-offset-row_shift;
                            if((kind==22 && in_triangle(dx,y,61,129,131,129,78,59)) ||
                               (kind==23 && (dx-96)*(dx-96)+(y-96)*(y-96)<=32*32))
                                image[y*W+x]=foreground;
                        end
                    end
                end
                28: disk(96+offset,96,7);
                29: disk_quarter((96+offset)*4+2,96*4+2,9*4);
                30: square_quarter((96+offset)*4+2,96*4+2,7*4,1024,0);
                31: square_quarter((96+offset)*4+2,96*4+2,7*4,724,724);
                // Dense orientation/subpixel sweeps found these two small
                // square boundaries: high dual-box fill and low raster Q.
                32: square_quarter((96+offset)*4,96*4,26,980,295);
                33: square_quarter((96+offset)*4+2,96*4+2,24,779,665);
                34: begin
                    // Deliberate ambiguity probe: a 65x55 rectangle is not a
                    // true square, but resembles a mildly foreshortened one.
                    for(y=69;y<=123;y=y+1)
                        for(x=64+offset;x<=128+offset;x=x+1)
                            image[y*W+x]=foreground;
                end
                35: begin
                    // Deliberate ambiguity probe, not a circular positive.
                    for(y=1;y<H-1;y=y+1)
                        for(x=1;x<W-1;x=x+1) begin
                            dx=x-(96+offset); dy=y-96;
                            if(dx*dx*30*30+dy*dy*35*35<=35*35*30*30)
                                image[y*W+x]=foreground;
                        end
                end
                36: begin
                    // A convex, mildly skewed trapezoid models a projected
                    // square. It has no holes or scanline topology defect.
                    for(y=64;y<=128;y=y+1)
                        for(x=64+offset;x<=116+offset+(y-64)*3/16;x=x+1)
                            image[y*W+x]=foreground;
                end
                37: begin
                    // Large asymmetric boundary loss is deliberately beyond
                    // the conservative diagonal-span guard.
                    square(96+offset,96,32,1024,0);
                    for(y=64;y<=87;y=y+1)
                        for(x=112+offset;x<=128+offset;x=x+1)
                            image[y*W+x]=24'h101010;
                end
                38: begin
                    // Missing a nine-pixel cap must not turn a circle into
                    // a square when only centroid tolerance is relaxed.
                    disk(96+offset,96,32);
                    for(y=1;y<H-1;y=y+1)
                        for(x=120+offset;x<W-1;x=x+1)
                            image[y*W+x]=24'h101010;
                end
                39: begin
                    // Centered trapezoid: 35-pixel top, 65-pixel bottom,
                    // 65 rows. It exercises centroid tolerance without
                    // introducing holes or disconnected scanline runs.
                    for(y=64;y<=128;y=y+1) begin
                        row_shift=17+(y-64)*15/64;
                        for(x=96+offset-row_shift;x<=96+offset+row_shift;x=x+1)
                            image[y*W+x]=foreground;
                    end
                end
                default: $fatal(1,"Unknown shape pattern kind=%0d",kind);
            endcase
        end
    endtask
    task blank;
        input integer cycles;
        integer cycle;
        begin
            for(cycle=0;cycle<cycles;cycle=cycle+1) begin
                @(negedge clk); user=0; valid=0; data=0;
            end
        end
    endtask
    task clear_tracking;
        begin
            blank(5);
            @(negedge clk); clear=1;
            @(negedge clk); clear=0;
            blank(2);
            if(found !== 0 || held !== 0 || shapes !== 0)
                $fatal(1,"Clear retained boxes or shape codes");
            checks=checks+1;
        end
    endtask
    task send_frame;
        input integer id,rows,line_blanking;
        integer y,g,l;
        begin
            @(negedge clk); user=1; valid=0; frame_id=id;
            @(negedge clk); user=0; valid=0; frame_id=10'd999;
            for(y=0;y<rows;y=y+1) begin
                for(g=0;g<GROUPS;g=g+1) begin
                    @(negedge clk); valid=1; user=0;
                    for(l=0;l<4;l=l+1)
                        data[95-l*24-:24]=image[y*W+g*4+l];
                end
                if(y != rows-1) blank(line_blanking);
            end
            @(negedge clk); valid=0; user=0; data=0;
        end
    endtask
    task wait_result;
        input integer id;
        integer cycles;
        begin
            cycles=0;
            while(!seen[id] && cycles<30000) begin
                @(negedge clk); cycles=cycles+1;
            end
            if(!seen[id]) $fatal(1,"Timed out waiting for shape result id=%0d",id);
            checks=checks+1;
        end
    endtask
    task count_is;
        input integer id,count,hold_count;
        integer s;
        begin
            wait_result(id);
            if(pop4(seen_found[id]) != count || pop4(seen_held[id]) != hold_count ||
               seen_overflow[id])
                $fatal(1,"Shape result id=%0d valid/hold/overflow=%b/%b/%b expected=%0d/%0d",
                    id,seen_found[id],seen_held[id],seen_overflow[id],count,hold_count);
            for(s=0;s<4;s=s+1)
                if(!seen_found[id][s] && result_shape(id,s) !== SH_UNKNOWN)
                    $fatal(1,"Invalid shape slot retained stale code id=%0d slot=%0d code=%0d",
                        id,s,result_shape(id,s));
        end
    endtask
    task single_shape_is;
        input integer id;
        input [1:0] expected;
        integer s;
        begin
            count_is(id,1,0);
            for(s=0;s<4;s=s+1)
                if(seen_found[id][s] && result_shape(id,s) !== expected)
                    $fatal(1,"Shape mismatch id=%0d expected=%0d got=%0d box=[%0d,%0d,%0d,%0d]",
                        id,expected,result_shape(id,s),bxmin(id,s),bxmax(id,s),
                        bymin(id,s),bymax(id,s));
            checks=checks+1;
        end
    endtask
    task locate_shape;
        input integer id,cx,cy;
        input [1:0] expected;
        output integer located_slot;
        integer s;
        begin
            located_slot=-1;
            for(s=0;s<4;s=s+1)
                if(seen_found[id][s] &&
                   abs_i(bxmin(id,s)+bxmax(id,s)-2*cx)<=8 &&
                   abs_i(bymin(id,s)+bymax(id,s)-2*cy)<=8)
                    located_slot=s;
            if(located_slot<0)
                $fatal(1,"Missing shape near center id=%0d cx=%0d cy=%0d",id,cx,cy);
            if(result_shape(id,located_slot) !== expected)
                $fatal(1,"Spatial shape mismatch id=%0d slot=%0d expected=%0d got=%0d",
                    id,located_slot,expected,result_shape(id,located_slot));
            checks=checks+1;
        end
    endtask
    task isolated_case;
        input integer id,kind;
        input [1:0] expected;
        begin
            clear_tracking();
            pattern(kind,0);
            send_frame(id,H,96); count_is(id,0,0);
            send_frame(id+1,H,96); single_shape_is(id+1,expected);
        end
    endtask
    task noisy_case;
        input integer kind,offset;
        input [1:0] expected;
        begin
            if(!reference_color(foreground,color_mode))
                $fatal(1,"Invalid positive RGB stimulus color=%0d value=%h",
                    color_mode,foreground);
            clear_tracking();
            mask_view_mode=noisy_cases%13;
            noisy_view_modes[mask_view_mode]=1;
            pattern(kind,offset);
            send_frame(noisy_id,H,96); count_is(noisy_id,0,0);
            send_frame(noisy_id+1,H,96); single_shape_is(noisy_id+1,expected);
            $display("COLOR_SHAPE_NOISY_CASE_PASS id=%0d color=%0d pattern=%0d phase=%0d shape=%0d",
                noisy_id+1,color_mode,kind,(96+offset)%4,expected);
            noisy_id=noisy_id+2;
            noisy_cases=noisy_cases+1;
        end
    endtask
    task geometry_probe;
        input integer id,kind;
        integer s;
        reg [1:0] expected;
        begin
            clear_tracking();
            current_probe=kind;
            pattern(kind,0);
            send_frame(id,H,96); count_is(id,0,0);
            send_frame(id+1,H,96); count_is(id+1,1,0);
            // The diagnostic-only mode compares deliberately different RTL
            // variants. The normal regression locks down the final policy.
            expected=(kind==36 || kind==39) ? SH_SQUARE : SH_UNKNOWN;
            for(s=0;s<4;s=s+1)
                if(seen_found[id+1][s]) begin
                    $display("COLOR_SHAPE_GEOMETRY_PROBE pattern=%0d shape=%0d box=%0d,%0d,%0d,%0d",
                        kind,result_shape(id+1,s),bxmin(id+1,s),bxmax(id+1,s),
                        bymin(id+1,s),bymax(id+1,s));
                    if(!GEOMETRY_PROBE_ONLY && result_shape(id+1,s)!==expected)
                        $fatal(1,"Conservative geometry policy changed pattern=%0d expected=%0d got=%0d",
                            kind,expected,result_shape(id+1,s));
                end
            geometry_probes=geometry_probes+1;
            current_probe=-1;
        end
    endtask

    initial begin
        if(W<288 || H<224 || W%4 != 0)
            $fatal(1,"Shape regression requires W>=288 H>=224 W divisible by four");
        if(!reference_color(24'hf02020,0) ||
           !reference_color(24'h50961e,1) ||
           !reference_color(24'h2020f0,2) ||
           !reference_color(24'h209678,1) ||
           reference_color(24'h209690,1))
            $fatal(1,"Shape RGB positive/negative threshold assumptions are invalid");
        for(n=0;n<128;n=n+1) begin
            seen[n]=0; seen_found[n]=0; seen_held[n]=0;
            seen_shapes[n]=0; seen_boxes[n]=0; seen_overflow[n]=0;
        end
        blank(4); @(negedge clk); rst_n=1;

        if(GEOMETRY_PROBE_ONLY) begin
            geometry_probe(1,34);
            geometry_probe(3,35);
            geometry_probe(5,36);
            geometry_probe(7,37);
            geometry_probe(9,38);
            geometry_probe(11,39);
            $display("COLOR_SHAPE_GEOMETRY_PROBE_PASS probes=%0d raw_unknown=%0d hard_bad=%0d size_border=%0d geometry=%0d centroid=%0d metric=%0d",
                geometry_probes,raw_unknown,raw_hard_bad,raw_size_border,
                raw_geometry,raw_centroid,raw_metric);
            $finish;
        end

        pattern(0,0);
        send_frame(1,H,96); count_is(1,0,0);
        send_frame(2,H,96); single_shape_is(2,SH_SQUARE);
        locate_shape(2,96,96,SH_SQUARE,previous_slot);
        pattern(3,0);
        send_frame(3,H,96); single_shape_is(3,SH_SQUARE);
        send_frame(4,H,96); single_shape_is(4,SH_CIRCLE);
        locate_shape(4,96,96,SH_CIRCLE,slot);
        if(slot != previous_slot) $fatal(1,"Shape change unnecessarily changed track identity");
        pattern(11,0);
        send_frame(5,H,96); count_is(5,1,1);
        send_frame(6,H,96); count_is(6,1,1);
        if(result_shape(5,slot) !== SH_CIRCLE || result_shape(6,slot) !== SH_CIRCLE)
            $fatal(1,"Hold lost the confirmed shape");
        send_frame(7,H,96); count_is(7,0,0);

        isolated_case(8,36,SH_SQUARE);
        isolated_case(10,1,SH_SQUARE);
        isolated_case(12,2,SH_SQUARE);
        isolated_case(14,4,SH_TRIANGLE);
        isolated_case(16,5,SH_TRIANGLE);
        isolated_case(18,6,SH_UNKNOWN);
        isolated_case(20,7,SH_UNKNOWN);
        isolated_case(22,8,SH_UNKNOWN);
        isolated_case(24,9,SH_UNKNOWN);
        isolated_case(26,37,SH_UNKNOWN);
        // Keep the conservative span guard on these deliberate ambiguity
        // cases. Reopening it would newly accept all three as shape codes.
        geometry_probe(28,34);
        geometry_probe(56,35);
        geometry_probe(58,38);
        isolated_case(62,39,SH_SQUARE);

        // Exercise the same shared feature pipeline in all selected colors,
        // including the yellow-green camera color from the green regression.
        clear_tracking(); color_mode=1; foreground=24'h50961e;
        pattern(10,0);
        send_frame(30,H,96); count_is(30,0,0);
        send_frame(31,H,96); count_is(31,4,0);
        locate_shape(31,48,48,SH_SQUARE,multi_slots[0]);
        locate_shape(31,140,48,SH_CIRCLE,multi_slots[1]);
        locate_shape(31,240,48,SH_TRIANGLE,multi_slots[2]);
        locate_shape(31,130,158,SH_SQUARE,multi_slots[3]);
        pattern(10,4);
        send_frame(32,H,96); count_is(32,4,0);
        locate_shape(32,52,48,SH_SQUARE,slot);
        if(slot != multi_slots[0]) $fatal(1,"Moving square changed slot");
        locate_shape(32,144,48,SH_CIRCLE,slot);
        if(slot != multi_slots[1]) $fatal(1,"Moving circle changed slot");
        locate_shape(32,244,48,SH_TRIANGLE,slot);
        if(slot != multi_slots[2]) $fatal(1,"Moving triangle changed slot");
        locate_shape(32,134,158,SH_SQUARE,slot);
        if(slot != multi_slots[3]) $fatal(1,"Moving rotated square changed slot");

        clear_tracking(); color_mode=2; foreground=24'h2020f0;
        pattern(4,0);
        send_frame(40,H,96); count_is(40,0,0);
        send_frame(41,H,96); single_shape_is(41,SH_TRIANGLE);
        clear_tracking(); color_mode=0;
        send_frame(42,H,96); count_is(42,0,0);
        send_frame(43,H,96); count_is(43,0,0);

        // A clear cancels an EOF classification queued just before a mode
        // switch; no color or shape metadata may leak into the next mode.
        foreground=24'hf02020; pattern(0,0);
        send_frame(44,H,0);
        @(negedge clk); clear=1; color_mode=1;
        @(negedge clk); clear=0;
        blank(500);
        if(seen[44] || found !== 0 || held !== 0 || shapes !== 0)
            $fatal(1,"Clear published stale queued shape result");
        color_mode=0;
        // Border-touching masks retain geometry but conservatively report
        // unknown because a target clipped outside the frame is ambiguous.
        isolated_case(46,12,SH_UNKNOWN);
        locate_shape(47,W-34,H-34,SH_UNKNOWN,slot);
        if(bxmax(47,slot) != W-4 || bymax(47,slot) != H-4)
            $fatal(1,"Final interior row/column was lost while classifying shape");

        // A truncated frame is aborted; confirmation restarts on complete
        // frames and the early SOF frame id, rather than the bus id, is used.
        clear_tracking(); pattern(3,0);
        send_frame(50,H/2,96);
        send_frame(51,H,96);
        count_is(50,0,0); count_is(51,0,0);
        send_frame(52,H,96); single_shape_is(52,SH_CIRCLE);

        if(W>=1280 && H>=720) begin
            clear_tracking();
            pattern(13,0);
            send_frame(60,H,96); count_is(60,0,0);
            send_frame(61,H,96); count_is(61,3,0);
            locate_shape(61,1000,520,SH_CIRCLE,slot);
            locate_shape(61,1160,520,SH_SQUARE,slot);
            locate_shape(61,1004,632,SH_TRIANGLE,slot);
        end
        // G=150, B=144 falls outside the supported green saturation range.
        // Keep the rejected original cyan stimulus as a real RGB negative;
        // the cyan-green positive below uses the inclusive B=120 boundary.
        clear_tracking(); color_mode=1; foreground=24'h209690;
        pattern(17,1);
        send_frame(54,H,96); count_is(54,0,0);
        send_frame(55,H,96); count_is(55,0,0);

        // These positives enter as RGB pixels, so color thresholding, line
        // buffering and binary cleanup are exercised before shape decisions.
        // White/gray highlights must not turn a solid target into UNKNOWN.
        color_mode=0; foreground=24'hf02020;
        for(noisy_phase=0;noisy_phase<4;noisy_phase=noisy_phase+1)
            noisy_case(14,noisy_phase,SH_SQUARE);
        noisy_case(15,0,SH_SQUARE);
        noisy_case(16,0,SH_SQUARE);
        noisy_case(17,0,SH_SQUARE);
        noisy_case(18,0,SH_UNKNOWN);
        noisy_case(24,0,SH_UNKNOWN);
        noisy_case(25,0,SH_UNKNOWN);
        noisy_case(26,0,SH_SQUARE);
        noisy_case(27,0,SH_UNKNOWN);
        noisy_case(19,0,SH_TRIANGLE);
        noisy_case(20,0,SH_TRIANGLE);
        noisy_case(21,0,SH_CIRCLE);
        noisy_case(22,0,SH_TRIANGLE);
        noisy_case(23,0,SH_CIRCLE);
        color_mode=1; foreground=24'h50961e;
        noisy_case(14,2,SH_SQUARE);
        noisy_case(19,1,SH_TRIANGLE);
        noisy_case(21,3,SH_CIRCLE);
        // Cyan-green exercises the broad green camera hue threshold too.
        foreground=24'h209678;
        noisy_case(17,1,SH_SQUARE);
        color_mode=2; foreground=24'h2020f0;
        noisy_case(15,1,SH_SQUARE);
        noisy_case(22,2,SH_TRIANGLE);
        noisy_case(23,3,SH_CIRCLE);
        // Small rasterized shapes straddle the dual-orientation circle-fill
        // decision. Half-pixel centers prevent integer-only tests
        // from concealing rounded-corner small-square misclassification.
        color_mode=0; foreground=24'hf02020;
        noisy_case(28,0,SH_CIRCLE);
        noisy_case(29,1,SH_CIRCLE);
        noisy_case(30,2,SH_SQUARE);
        noisy_case(31,3,SH_SQUARE);
        noisy_case(32,0,SH_SQUARE);
        noisy_case(33,1,SH_SQUARE);
        if(noisy_cases!=30 || noisy_view_modes!==13'h1fff)
            $fatal(1,"Incomplete real-mask robustness coverage: %0d views=%h",
                noisy_cases,noisy_view_modes);

        $display("COLOR_SHAPE_TARGET_PASS W=%0d H=%0d results=%0d checks=%0d colors=RED,GRN,BLU shapes=SQR,TRI,CIR,UNK noisy_cases=%0d probes=%0d raw_unknown=%0d hard_bad=%0d size_border=%0d geometry=%0d centroid=%0d metric=%0d",
            W,H,results,checks,noisy_cases,geometry_probes,raw_unknown,
            raw_hard_bad,raw_size_border,raw_geometry,raw_centroid,raw_metric);
        $finish;
    end
    initial begin
        #(64'd100000000+64'd116*H*(W/4+96)*10);
        $fatal(1,"Shape regression watchdog");
    end
endmodule
