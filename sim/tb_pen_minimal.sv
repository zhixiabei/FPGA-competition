`timescale 1ns/1ps
module tb_pen_minimal;
    parameter integer SHIFT=2;
    parameter integer SMOOTH=0;
    localparam integer JUMP=96>>SHIFT;
    localparam integer W=1280,H=720,CW=W>>SHIFT,CH=H>>SHIFT,DEPTH=CW*CH;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, frame_start=0, enable=0, pause=0, clear=0;
    reg pen_valid=0, pen_hold=0, de=0;
    reg [10:0] pen_x=0,x=0;
    reg [9:0] pen_y=0,y=0;
    wire ink,busy,clearing;
    pen_minimal #(.CANVAS_SHIFT(SHIFT),.SMOOTH_ENABLE(SMOOTH)) dut(
        .I_clk(clk),.I_rst_n(rst_n),.I_frame_start(frame_start),
        .I_enable(enable),.I_pause(pause),.I_clear(clear),
        .I_pen_valid(pen_valid),.I_pen_hold(pen_hold),
        .I_pen_x(pen_x),.I_pen_y(pen_y),.I_de(de),.I_x(x),.I_y(y),
        .O_ink(ink),.O_busy(busy),.O_clearing(clearing));
    reg expected[0:DEPTH-1];
    integer old_x=0,old_y=0,checks=0,frames=0;
    integer model_qx=0,model_qy=0,jitter_cells,previous_raw_x=0,previous_raw_y=0;
    reg old_valid=0,model_enable=0;
    integer i,j,seed=32'h31415926,rx,ry;
    task tick;
        begin @(posedge clk); #1; end
    endtask
    task idle;
        integer cycles;
        begin
            cycles=0;
            while(busy) begin
                tick(); cycles=cycles+1;
                if(cycles>DEPTH+CW+20) $fatal(1,"busy timeout");
            end
        end
    endtask
    task erase_model;
        integer q;
        begin for(q=0;q<DEPTH;q=q+1) expected[q]=0; old_valid=0; end
    endtask
    // Independent reference: direct rounded interpolation, no incremental
    // accumulator or DUT state. Both endpoints and all eight octants included.
    task draw_model(input integer tx,input integer ty);
        integer ax,ay,dx,dy,steps,k,px,py,sx,sy;
        begin
            ax=old_x;ay=old_y;dx=tx-ax;dy=ty-ay;
            if(!old_valid || dx>JUMP || dx< -JUMP || dy>JUMP || dy< -JUMP) begin
                ax=tx;ay=ty;dx=0;dy=0;
            end
            sx=dx<0 ? -1 : 1;sy=dy<0 ? -1 : 1;
            if(dx<0)dx=-dx;if(dy<0)dy=-dy;
            steps=dx>dy ? dx : dy;
            if(steps==0) expected[ty*CW+tx]=1;
            else for(k=0;k<=steps;k=k+1) begin
                px=ax+sx*((k*dx+steps/2)/steps);
                py=ay+sy*((k*dy+steps/2)/steps);
                if(px<0 || px>=CW || py<0 || py>=CH)
                    $fatal(1,"reference out of range");
                expected[py*CW+px]=1;
            end
            old_x=tx;old_y=ty;old_valid=1;
        end
    endtask
    task frame(input integer en,input integer pa,input integer valid,
               input integer held,input integer px,input integer py);
        begin
            @(negedge clk);
            enable=en;pause=pa;pen_valid=valid;pen_hold=held;
            pen_x=px;pen_y=py;frame_start=1;
            tick();
            if(model_enable && !en) erase_model();
            else if(en && !pa && valid && !held && px<W && py<H) begin
                if(SMOOTH) begin
                    if(old_valid && (px>>SHIFT)-previous_raw_x<=JUMP && previous_raw_x-(px>>SHIFT)<=JUMP &&
                       (py>>SHIFT)-previous_raw_y<=JUMP && previous_raw_y-(py>>SHIFT)<=JUMP) begin
                        model_qx=(model_qx+2*px+1)/2;
                        model_qy=(model_qy+2*py+1)/2;
                    end else begin
                        model_qx=2*px; model_qy=2*py; old_valid=0;
                    end
                    previous_raw_x=px>>SHIFT; previous_raw_y=py>>SHIFT;
                    draw_model(model_qx>>(SHIFT+1),model_qy>>(SHIFT+1));
                end else draw_model(px>>SHIFT,py>>SHIFT);
            end
            else old_valid=0;
            model_enable=en;
            @(negedge clk);frame_start=0;
            idle();frames=frames+1;
            if(en && !pa && valid && !held && px<W && py<H &&
               (dut.anchor_x!==old_x || dut.anchor_y!==old_y))
                $fatal(1,"Filtered endpoint mismatch frame=%0d",frames);
        end
    endtask
    task check_grid;
        integer cx,cy;
        reg want;
        begin
            for(cy=0;cy<CH;cy=cy+1) for(cx=0;cx<CW;cx=cx+1) begin
                @(negedge clk);de=1;x=cx<<SHIFT;y=cy<<SHIFT;
                tick();want=model_enable && expected[cy*CW+cx];
                if(ink!==want)
                    $fatal(1,"grid mismatch shift=%0d x=%0d y=%0d got=%b want=%b",SHIFT,cx,cy,ink,want);
                checks=checks+1;
            end
            @(negedge clk);de=0;tick();
            if(ink!==0)$fatal(1,"blanking leaks ink");
        end
    endtask
    task explicit_clear;
        begin
            @(negedge clk);clear=1;tick();
            if(!clearing || ink!==0)$fatal(1,"clear not immediate");
            @(negedge clk);clear=0;
            erase_model();idle();
        end
    endtask
    initial begin
        erase_model();repeat(3)tick();
        @(negedge clk);rst_n=1;idle();check_grid();
        // +/-2-pixel jitter crosses a raw 4x4 cell boundary; the light
        // filter should keep this stationary marker in one painted cell.
        frame(1,0,1,0,642,362);
        for(i=0;i<64;i=i+1) frame(1,0,1,0,i%2 ? 644:640,i%2 ? 364:360);
        check_grid();
        jitter_cells=0;for(i=0;i<DEPTH;i=i+1) if(expected[i]) jitter_cells++;
        if(SMOOTH && SHIFT==2 && jitter_cells!=1) $fatal(1,"Jitter not reduced");
        // Slow one-pixel motion must not stick; settling reaches the final cell.
        for(i=0;i<42;i=i+1) frame(1,0,1,0,643+i,362);
        repeat(20) frame(1,0,1,0,684,362);
        if(old_x!=(684>>SHIFT)) $fatal(1,"Filtered endpoint failed to settle");
        check_grid();
        // A 160-pixel jump must be rejected before averaging to 80 pixels.
        frame(1,0,1,0,844,362);check_grid();
        explicit_clear();
        // Fast but valid 80-pixel/frame motion stays continuous despite lag.
        frame(1,0,1,0,100,100);
        for(i=1;i<=12;i=i+1) frame(1,0,1,0,100+i*80,100);
        check_grid();
        for(i=100>>SHIFT;i<=old_x;i=i+1)
            if(!expected[(100>>SHIFT)*CW+i]) $fatal(1,"Fast stroke disconnected");
        // Reverse direction quickly, then stop at an exact cell boundary.
        for(i=11;i>=0;i=i-1) frame(1,0,1,0,100+i*80,100);
        repeat(20) frame(1,0,1,0,100,100);
        check_grid();
        explicit_clear();
        frame(1,0,1,0,320,320);
        // Horizontal, vertical, shallow/steep diagonals in every direction.
        frame(1,0,1,0,384,320);frame(1,0,1,0,384,384);
        frame(1,0,1,0,352,320);frame(1,0,1,0,320,352);
        frame(1,0,1,0,288,320);frame(1,0,1,0,320,288);
        frame(1,0,1,0,384,256);frame(1,0,1,0,352,288);
        check_grid();
        frame(1,1,1,0,400,400); // Pause and resume must not join.
        frame(1,0,1,0,416,416);check_grid();
        frame(1,0,0,0,432,432);frame(1,0,1,0,448,448);
        frame(1,0,1,1,464,464);frame(1,0,1,0,480,480);
        frame(1,0,1,0,2000,1000);frame(1,0,1,0,496,496);
        frame(1,0,1,0,1279,719); // Large jump draws only new endpoint.
        frame(1,0,1,0,0,0);check_grid();
        // Reproducible random strokes plus discontinuities.
        rx=640;ry=360;
        for(i=0;i<400;i=i+1)begin
            rx=rx+($random(seed)%31);ry=ry+($random(seed)%31);
            if(rx<0)rx=0;if(rx>=W)rx=W-1;
            if(ry<0)ry=0;if(ry>=H)ry=H-1;
            frame(1,i%31==0,i%37!=0,i%41==0,rx,ry);
        end
        check_grid();
        // Complete 720p read verifies every pixel, scaling and blanking.
        for(j=0;j<H;j=j+1)for(i=0;i<W;i=i+1)begin
            @(negedge clk);de=1;x=i;y=j;tick();
            if(ink!==expected[(j>>SHIFT)*CW+(i>>SHIFT)])
                $fatal(1,"720p mismatch x=%0d y=%0d",i,j);
            checks=checks+1;
        end
        @(negedge clk);de=0;tick();
        explicit_clear();check_grid();
        frame(1,0,1,0,0,0);frame(1,0,1,0,64,64);
        frame(0,0,0,0,0,0);check_grid();
        frame(1,0,0,0,0,0);check_grid();
        frame(1,0,1,0,1279,719);check_grid();
        // Invalid display coordinates must not wrap into a valid canvas cell.
        @(negedge clk);de=1;x=1280;y=0;tick();
        if(ink!==0)$fatal(1,"out-of-range display leaks ink");
        @(negedge clk);x=0;y=720;tick();
        if(ink!==0)$fatal(1,"out-of-range display y leaks ink");
        // Reset after real ink also sweeps memory and suppresses stale reads.
        @(negedge clk);rst_n=0;tick();
        if(ink!==0)$fatal(1,"reset leaks ink");
        @(negedge clk);rst_n=1;de=0;enable=0;model_enable=0;
        erase_model();idle();check_grid();
        $display("PEN_MINIMAL_PASS shift=%0d smooth=%0d frames=%0d pixel_checks=%0d jitter_cells=%0d",SHIFT,SMOOTH,frames,checks,jitter_cells);
        $finish;
    end
    initial begin #100000000; $fatal(1,"simulation timeout"); end
endmodule
