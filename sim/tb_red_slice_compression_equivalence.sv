`timescale 1ns/1ps

// Full-width arithmetic probes and complete descriptor transactions complement
// the RGB miter below. Both descriptor input contracts run independently.
module red_slice_shape_equivalence #(
    parameter integer STABLE_INPUTS=0
)(output reg done=0);
    localparam integer MB=38, MOM=32;
    reg clk=0,rst_n=0,clear=0,start=0,bad=0;
    reg [19:0] area=0;
    reg [15:0] perimeter=0;
    reg [10:0] xmin=0,xmax=0;
    reg [9:0] ymin=0,ymax=0;
    reg [31:0] mx2=0,my2=0;
    reg [11:0] umin=0,umax=0,vmin=0,vmax=0;
    wire ready,ref_ready,circle,ref_circle;
    wire [1:0] shape,ref_shape;
    reg [63:0] random_bits=64'h6d1f9348a20c5b77;
    reg [MB-1:0] probe_moment,probe_product;
    reg [31:0] probe_mx,probe_my;
    integer probes=0,transactions=0,cancelled=0,cycles=0;
    integer i,j,t,w,h,x,y,timeout;
    reg [3:0] projections=0;
    reg [1:0] signs=0;
    always #5 clk=~clk;

    color_shape_descriptor #(.STABLE_INPUTS(STABLE_INPUTS)) dut(
        .I_clk(clk),.I_rst_n(rst_n),.I_clear(clear),.I_start(start),.I_bad(bad),
        .I_area(area),.I_perimeter(perimeter),.I_xmin(xmin),.I_xmax(xmax),
        .I_ymin(ymin),.I_ymax(ymax),.I_mx2(mx2),.I_my2(my2),
        .I_umin(umin),.I_umax(umax),.I_vmin(vmin),.I_vmax(vmax),
        .O_ready(ready),.O_shape(shape),.O_circle_support(circle));
    color_shape_descriptor_reference #(.STABLE_INPUTS(STABLE_INPUTS)) baseline(
        .I_clk(clk),.I_rst_n(rst_n),.I_clear(clear),.I_start(start),.I_bad(bad),
        .I_area(area),.I_perimeter(perimeter),.I_xmin(xmin),.I_xmax(xmax),
        .I_ymin(ymin),.I_ymax(ymax),.I_mx2(mx2),.I_my2(my2),
        .I_umin(umin),.I_umax(umax),.I_vmin(vmin),.I_vmax(vmax),
        .O_ready(ref_ready),.O_shape(ref_shape),.O_circle_support(ref_circle));

    task advance_random;
        begin
            random_bits=random_bits^(random_bits<<13);
            random_bits=random_bits^(random_bits>>7);
            random_bits=random_bits^(random_bits<<17);
        end
    endtask
    task reset_descriptor;
        begin
            @(negedge clk);rst_n=0;start=0;clear=0;
            repeat(3) @(negedge clk);
            rst_n=1;
        end
    endtask
    task check_arithmetic;
        begin
            if(dut.signed_difference !== baseline.signed_difference)
                $fatal(1,"Centroid arithmetic differs stable=%0d probe=%0d",STABLE_INPUTS,probes);
            if(dut.projection_moment !== baseline.projection_moment ||
               dut.projection_center !== baseline.projection_center)
                $fatal(1,"Projection arithmetic differs stable=%0d probe=%0d projection=%0d",
                    STABLE_INPUTS,probes,dut.projection);
        end
    endtask
    always @(posedge clk) begin
        #1;cycles=cycles+1;
        if(rst_n) begin
            if({ready,shape,circle} !== {ref_ready,ref_shape,ref_circle} ||
               dut.state !== baseline.state ||
               dut.multiply_count !== baseline.multiply_count ||
               dut.deviation !== baseline.deviation)
                $fatal(1,"Descriptor cycle mismatch stable=%0d cycle=%0d",STABLE_INPUTS,cycles);
            check_arithmetic();
        end
    end

    initial begin
        reset_descriptor();
        // Drive internal arithmetic operands only while IDLE. This covers
        // modular overflow, not merely physically reachable image moments.
        for(i=0;i<4096;i=i+1) begin
            @(negedge clk);
            advance_random();probe_moment=random_bits[MB-1:0];
            advance_random();probe_product=random_bits[MB-1:0];
            advance_random();probe_mx=random_bits[31:0];probe_my=random_bits[63:32];
            if(i<64) begin
                probe_moment=(38'd1<<(i%38))-1'b1;
                probe_product=(38'd1<<((i+1)%38));
                probe_mx=(32'd1<<(i%32))-1'b1;
                probe_my=(32'd1<<((i+1)%32));
            end
            dut.moment=probe_moment;baseline.moment=probe_moment;
            dut.product=probe_product;baseline.product=probe_product;
            dut.center_negative=i[0];baseline.center_negative=i[0];
            dut.projection=i[2:1];baseline.projection=i[2:1];
            mx2=probe_mx;my2=probe_my;
            dut.saved_mx2=probe_mx;baseline.saved_mx2=probe_mx;
            dut.saved_my2=probe_my;baseline.saved_my2=probe_my;
            projections[i[2:1]]=1;signs[i[0]]=1;
            #1;check_arithmetic();probes=probes+1;
        end
        reset_descriptor();
        for(t=0;t<128;t=t+1) begin
            @(negedge clk);
            advance_random();w=8+(random_bits[15:0]%184);
            h=8+(random_bits[31:16]%184);
            x=random_bits[47:32]%(1280-w);
            y=random_bits[63:48]%(720-h);
            if(t<8) begin
                w=24+4*t;h=28+3*t;
                x=1280-w-8;y=720-h-8;
            end
            xmin=x;xmax=x+w-1;ymin=y;ymax=y+h-1;
            area=w*h;perimeter=16*(w+h);
            mx2=area*(2*x+w-1);my2=area*(2*y+h-1);
            umin=x+y;umax=x+w-1+y+h-1;
            vmin=x+720-(y+h-1);vmax=x+w-1+720-y;
            bad=(t%29)==0;
            if(t%16==15) begin
                // Exercise positive/negative projected moments at full width.
                area=20'hfffff;perimeter=16'hffff;
                mx2=32'hffffffff;my2=t[4] ? 32'hffffffff : 0;
                xmin=0;xmax=2047;ymin=0;ymax=1023;
                umin=0;umax=4095;vmin=0;vmax=4095;
            end
            start=1;
            @(negedge clk);start=0;
            if(!STABLE_INPUTS) begin
                advance_random();
                area=random_bits[19:0];perimeter=random_bits[35:20];
                mx2=random_bits[31:0];my2=random_bits[63:32];
                xmin=0;xmax=1;ymin=0;ymax=1;umin=0;umax=1;vmin=0;vmax=1;
            end
            timeout=0;
            while(!ready && timeout<3000) begin
                @(negedge clk);timeout=timeout+1;
                if(t%31==30 && timeout==9) begin
                    clear=1;cancelled=cancelled+1;
                end else if(clear) begin clear=0;timeout=3000;end
            end
            if(timeout==3000 && t%31!=30)
                $fatal(1,"Descriptor timeout stable=%0d case=%0d",STABLE_INPUTS,t);
            transactions=transactions+1;
        end
        if(projections!==4'hf || signs!==2'b11 || cancelled!=4)
            $fatal(1,"Incomplete descriptor coverage");
        $display("RED_SLICE_SHAPE_EQUIVALENCE_PASS stable=%0d probes=%0d transactions=%0d cancelled=%0d cycles=%0d",
            STABLE_INPUTS,probes,transactions,cancelled,cycles);
        done=1;
    end
endmodule

module tb_red_slice_compression_equivalence #(
    parameter integer W=320,H=240,
    parameter integer HIGH_COORD_ONLY=0
);
    localparam integer FRAMES=HIGH_COORD_ONLY ? 4 : 18;
    reg clk=0,rst_n=0,clear=0,user=0,valid=0;
    reg [95:0] data=0;
    reg [9:0] frame_id=0;
    reg [1:0] color_mode=0;
    reg [3:0] mask_mode=0;
    wire [322:0] observed,reference;
    wire shape_done0,shape_done1;
    integer cycles=0,results=0,overflows=0,frame,row,group,lane,x,y,k;
    reg [20:0] states=0;
    reg [3:0] lane_hits=0;
    reg [12:0] views=0;
    reg [2:0] colors=0;
    reg high_box_seen=0;
    reg [23:0] foreground;
    always #5 clk=~clk;
    red_slice_shape_equivalence #(.STABLE_INPUTS(0)) shape_snapshots(shape_done0);
    red_slice_shape_equivalence #(.STABLE_INPUTS(1)) shape_stable(shape_done1);
    red_target_detect_96 #(.IMG_WIDTH(W),.IMG_HEIGHT(H),.MIN_PIXELS(32),
        .MIN_WIDTH(4),.MIN_HEIGHT(4),.MULTI_ENABLE(1)) dut(
        .I_clk(clk),.I_rst_n(rst_n),.I_tuser(user),.I_tvalid(valid),.I_tdata(data),
        .I_color_mode(color_mode),.I_mask_view_mode(mask_mode),
        .I_frame_id(frame_id),.I_multi_clear(clear),
        .O_mask_pixels(observed[322:319]),
        .O_result_ready(observed[318]),.O_found(observed[317]),
        .O_xmin(observed[316:305]),.O_xmax(observed[304:293]),
        .O_ymin(observed[292:281]),.O_ymax(observed[280:269]),
        .O_center_x(observed[268:257]),.O_center_y(observed[256:245]),
        .O_pixels(observed[244:221]),.O_frame_toggle(observed[220]),
        .O_multi_ready(observed[219]),.O_multi_valid(observed[218:215]),
        .O_multi_hold(observed[214:211]),.O_multi_boxes(observed[210:19]),
        .O_multi_shapes(observed[18:11]),.O_multi_frame_id(observed[10:1]),
        .O_multi_overflow(observed[0]));
    red_target_detect_96_reference #(.IMG_WIDTH(W),.IMG_HEIGHT(H),.MIN_PIXELS(32),
        .MIN_WIDTH(4),.MIN_HEIGHT(4),.MULTI_ENABLE(1)) baseline(
        .I_clk(clk),.I_rst_n(rst_n),.I_tuser(user),.I_tvalid(valid),.I_tdata(data),
        .I_color_mode(color_mode),.I_mask_view_mode(mask_mode),
        .I_frame_id(frame_id),.I_multi_clear(clear),
        .O_mask_pixels(reference[322:319]),
        .O_result_ready(reference[318]),.O_found(reference[317]),
        .O_xmin(reference[316:305]),.O_xmax(reference[304:293]),
        .O_ymin(reference[292:281]),.O_ymax(reference[280:269]),
        .O_center_x(reference[268:257]),.O_center_y(reference[256:245]),
        .O_pixels(reference[244:221]),.O_frame_toggle(reference[220]),
        .O_multi_ready(reference[219]),.O_multi_valid(reference[218:215]),
        .O_multi_hold(reference[214:211]),.O_multi_boxes(reference[210:19]),
        .O_multi_shapes(reference[18:11]),.O_multi_frame_id(reference[10:1]),
        .O_multi_overflow(reference[0]));

    function [23:0] pixel;
        input integer kind,px,py;
        integer dx,dy;
        reg hit;
        begin
            hit=0;
            case(kind)
                0,1: begin
                    hit=(px>=16+2*kind && px<44+2*kind && py>=20 && py<48) ||
                        (px>=112 && px<144 && py>=24 && py<52) ||
                        (px>=20 && px<48 && py>=100 && py<128) ||
                        (px>=W-64 && px<W-36 && py>=H-60 && py<H-32);
                end
                2: begin
                    dx=px-100;dy=py-90;
                    hit=dx*dx+dy*dy<=30*30 ||
                        (py>=130 && py<175 && px>=200-(py-130)/2 &&
                         px<=200+(py-130)/2);
                end
                3: hit=0;
                4: hit=py>=3 && py<H-3 && px>=3 && px<W-3 &&
                    (px%11==3) && (py%11==3);
                5: hit=py>=2 && py<H-2 && (px/8)%2==0;
            endcase
            pixel=hit ? foreground : 24'h182020;
        end
    endfunction
    task blank;
        input integer clocks;
        integer b;
        begin
            for(b=0;b<clocks;b=b+1) begin
                @(negedge clk);valid=0;user=0;data=0;
            end
        end
    endtask
    always @(posedge clk) begin
        #1;cycles=cycles+1;
        if(rst_n) begin
            if(observed !== reference)
                $fatal(1,"Red cycle mismatch frame=%0d row=%0d group=%0d cycle=%0d got=%h expected=%h",
                    frame,row,group,cycles,observed,reference);
            if(dut.gen_multi.u_engine.state !== baseline.gen_multi.u_engine.state ||
               dut.gen_multi.u_engine.shape_ready !== baseline.gen_multi.u_engine.shape_ready)
                $fatal(1,"Engine schedule mismatch at cycle=%0d",cycles);
            states[dut.gen_multi.u_engine.state]=1;
            lane_hits=lane_hits|observed[322:319];
            if(observed[219]) begin
                results=results+1;
                if(observed[0]) overflows=overflows+1;
                for(k=0;k<4;k=k+1)
                    if(observed[215+k] &&
                       observed[19+48*k+:12]>1023 &&
                       observed[19+48*k+24+:12]>511)
                        high_box_seen=1;
            end
        end
    end
    initial begin
        blank(5);rst_n=1;
        for(frame=0;frame<FRAMES;frame=frame+1) begin
            color_mode=HIGH_COORD_ONLY ? 0 : (frame/6)%3;
            mask_mode=HIGH_COORD_ONLY ? 9+frame : frame%13;
            foreground=color_mode==0 ? 24'hf02020 :
                color_mode==1 ? 24'h50961e : 24'h2020f0;
            colors[color_mode]=1;views[mask_mode]=1;
            @(negedge clk);frame_id=frame;user=1;valid=0;
            @(negedge clk);user=0;frame_id=999;
            for(row=0;row<(frame==6 ? H/2 : H);row=row+1) begin
                for(group=0;group<W/4;group=group+1) begin
                    @(negedge clk);valid=1;
                    for(lane=0;lane<4;lane=lane+1)
                        data[95-lane*24-:24]=pixel(HIGH_COORD_ONLY ? frame%2 : frame%6,
                            4*group+lane,row);
                    if(frame%4==1 && group%17==16) blank(2);
                end
                blank(32);
            end
            blank(8);
            if(frame==11) begin
                @(negedge clk);clear=1;
                @(negedge clk);clear=0;
            end
            blank(4000);
            if(frame==14) begin
                @(negedge clk);rst_n=0;
                blank(3);rst_n=1;
            end
        end
        blank(6000);
        wait(shape_done0 && shape_done1);
        if(results<(HIGH_COORD_ONLY ? 4 : 14) || lane_hits!==4'hf ||
           (!HIGH_COORD_ONLY && (views!==13'h1fff || colors!==3'b111)) ||
           (HIGH_COORD_ONLY && !high_box_seen) ||
           !states[18] || !states[19] || !states[11] || !states[12] ||
           !states[14] || !states[15])
            $fatal(1,"Incomplete RGB coverage results=%0d states=%h lanes=%h",results,states,lane_hits);
        $display("RED_SLICE_RGB_EQUIVALENCE_PASS W=%0d H=%0d frames=%0d results=%0d overflows=%0d cycles=%0d states=%h masks=%h high=%0d",
            W,H,FRAMES,results,overflows,cycles,states,views,high_box_seen);
        $display("RED_SLICE_COMPRESSION_EQUIVALENCE_PASS");
        $finish;
    end
    initial begin
        #100000000;
        $fatal(1,"Slice compression equivalence watchdog");
    end
endmodule
