`timescale 1ns/1ps
module raw_stats_case #(parameter W=64,H=48,L=3,MODE="BGGR",M=0)(output reg done=0);
    localparam P=1<<L;
    reg clk=0; always #5 clk=~clk;
    reg rst=0, valid=0, user=0, last=0;
    reg [39:0] raw=0;
    wire ov; wire [44:0] od;
    integer frame=0, seen=0, commits=0, checked=0;
    integer sums[0:35], counts[0:35];
    bit clips[0:8];
    raw_region_stats #(.IMG_WIDTH(W),.IMG_HEIGHT(H),.PATCH_LOG2(L),.BAYER_MODE(MODE)) dut
        (.I_clk(clk),.I_rst_n(rst),.I_tdata(raw),.I_tvalid(valid),.I_tuser(user),.I_tlast(last),.O_valid(ov),.O_data(od));

    // Independent Bayer lookup: 0=R, 1=Gr, 2=Gb, 3=B.
    function automatic integer colour(input integer xx,yy);
        integer phase;
        begin
            phase=(yy%2)*2+xx%2;
            case (M)
                0: case(phase) 0:colour=3;1:colour=2;2:colour=1;3:colour=0;endcase
                1: case(phase) 0:colour=0;1:colour=1;2:colour=2;3:colour=3;endcase
                2: case(phase) 0:colour=2;1:colour=3;2:colour=0;3:colour=1;endcase
                3: case(phase) 0:colour=1;1:colour=0;2:colour=3;3:colour=2;endcase
            endcase
        end
    endfunction
    function automatic integer value_at(input integer xx,yy,f);
        if (f==1) value_at=1023;
        else if(f==2) value_at=0;
        else value_at=(xx*13+yy*17+colour(xx,yy)*199+f*29)%1024;
    endfunction
    function automatic integer region_at(input integer xx,yy);
        integer cx,cy,x0,y0;
        begin
            region_at=-1;
            for(cy=0;cy<3;cy=cy+1) for(cx=0;cx<3;cx=cx+1) begin
                x0=cx==0 ? P/2 : cx==1 ? ((W-P)/8)*4 : W-P-P/2;
                y0=cy==0 ? P/2 : cy==1 ? ((H-P)/4)*2 : H-P-P/2;
                if(xx>=x0 && xx<x0+P && yy>=y0 && yy<y0+P) region_at=cy*3+cx;
            end
        end
    endfunction
    task automatic prepare(input integer f);
        integer xx,yy,r,c,v;
        begin
            frame=f; seen=0;
            for(c=0;c<36;c=c+1) begin sums[c]=0; counts[c]=0; end
            for(c=0;c<9;c=c+1) clips[c]=0;
            for(yy=0;yy<H;yy=yy+1) for(xx=0;xx<W;xx=xx+1) begin
                r=region_at(xx,yy); c=colour(xx,yy); v=value_at(xx,yy,f);
                if(r>=0) begin sums[r*4+c]+=v; counts[r*4+c]++; if(v==1023) clips[r]=1; end
            end
        end
    endtask
    always @(posedge clk) begin
        integer r,c,want;
        #1;
        if(rst && ov) begin
            r=od[44:41];
            if(r==15) begin
                if(seen!=9) $fatal(1,"Partial frame committed mode=%s count=%0d",MODE,seen);
                commits++;
            end else begin
                if(r!=seen || r>8) $fatal(1,"Region order mode=%s got=%0d expected=%0d",MODE,r,seen);
                for(c=0;c<4;c=c+1) begin
                    if(counts[r*4+c]!=P*P/4) $fatal(1,"Bad test geometry");
                    want=(sums[r*4+c]+counts[r*4+c]/2)/counts[r*4+c];
                    if(od[c*10+:10] !== 10'(want)) $fatal(1,"Mean mode=%s f=%0d region=%0d c=%0d want=%0d got=%0d",MODE,frame,r,c,want,od[c*10+:10]);
                    checked++;
                end
                if(od[40]!==clips[r]) $fatal(1,"Clip flag mismatch");
                seen++;
            end
        end
    end
    task automatic drive(input integer f,rows,bad_eol,early);
        integer yy,g,k;
        begin
            prepare(f);
            if(early) begin
                @(negedge clk); valid=0; user=1; last=0;
                repeat(3) @(negedge clk);
            end
            for(yy=0;yy<rows;yy=yy+1) for(g=0;g<W/4;g=g+1) begin
                @(negedge clk);
                valid=1; user=yy==0 && (g==0 || (early && g==1));
                last=g==W/4-1;
                if(bad_eol && yy==H-1 && g==W/4-1) last=0;
                for(k=0;k<4;k=k+1) raw[k*10+:10]=10'(value_at(g*4+k,yy,f));
                if((g+yy)%13==7) begin
                    @(negedge clk); valid=0; user=0; last=0;
                    repeat(2) @(negedge clk);
                end
            end
            @(negedge clk); valid=0; user=0; last=0;
            repeat(3) @(negedge clk);
        end
    endtask
    initial begin
        repeat(4) @(negedge clk); rst=1;
        // Orphan data before SOF must not publish.
        repeat(20) begin @(negedge clk); valid=1; raw=40'hffffffffff; end
        @(negedge clk); valid=0;
        drive(0,H,0,1);
        drive(1,H,0,0);
        drive(2,H,0,0);
        if(commits!=3) $fatal(1,"Missing complete frames");
        drive(3,H/2,0,0); // restart must discard these partial-frame packets
        drive(4,H,0,1);
        if(commits!=4) $fatal(1,"Truncated-frame recovery failed");
        drive(5,H,1,0); // all nine ROIs present, but no commit with bad EOL
        if(commits!=4) $fatal(1,"Malformed frame committed");
        @(negedge clk); rst=0;
        repeat(3) @(negedge clk); rst=1;
        drive(6,H,0,0);
        if(commits!=5) $fatal(1,"Reset recovery failed");
        $display("RAW_REGION_STATS_PASS mode=%s size=%0dx%0d means=%0d commits=%0d",MODE,W,H,checked,commits);
        done=1;
    end
endmodule
module tb_raw_region_stats #(parameter W=64,H=48,L=3);
    wire [3:0] done;
    raw_stats_case #(.W(W),.H(H),.L(L),.MODE("BGGR"),.M(0)) a(done[0]);
    raw_stats_case #(.W(W),.H(H),.L(L),.MODE("RGGB"),.M(1)) b(done[1]);
    raw_stats_case #(.W(W),.H(H),.L(L),.MODE("GBRG"),.M(2)) c(done[2]);
    raw_stats_case #(.W(W),.H(H),.L(L),.MODE("GRBG"),.M(3)) d(done[3]);
    initial begin wait(&done); $finish; end
    initial begin #200000000; $fatal(1,"Timeout"); end
endmodule
