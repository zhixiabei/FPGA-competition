`timescale 1ns/1ps

module scharr_morphology_equivalence_case #(
    parameter integer WIDTH=32,HEIGHT=17,GAUSSIAN_ENABLE=1,EDGE_TH=20,SEED=1
) (
    output reg done=0
);
    localparam integer LATENCY=11;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,valid=0,user=0,last=0,ready=0;
    reg [95:0] data=0;
    wire dut_valid,dut_user,dut_last,dut_ready;
    wire ref_valid,ref_user,ref_last,ref_ready;
    wire [95:0] dut_edge,dut_emboss,dut_cartoon,dut_morph;
    wire [95:0] ref_edge,ref_emboss,ref_cartoon,ref_morph;
    scharr_edge_detect_96 #(
        .IMG_WIDTH(WIDTH),.IMG_HEIGHT(HEIGHT),.EDGE_TH(EDGE_TH),
        .GAUSSIAN_ENABLE(GAUSSIAN_ENABLE)
    ) dut(
        .I_clk(clk),.I_rst_n(rst_n),.I_tvalid(valid),.I_tuser(user),
        .I_tlast(last),.I_tdata(data),.I_tready(ready),
        .O_tvalid(dut_valid),.O_tuser(dut_user),.O_tlast(dut_last),
        .O_tready(dut_ready),.O_tdata(dut_edge),.O_emboss_data(dut_emboss),
        .O_cartoon_data(dut_cartoon),.O_morph_data(dut_morph)
    );
    scharr_edge_detect_96_reference #(
        .IMG_WIDTH(WIDTH),.IMG_HEIGHT(HEIGHT),.EDGE_TH(EDGE_TH),
        .GAUSSIAN_ENABLE(GAUSSIAN_ENABLE)
    ) reference(
        .I_clk(clk),.I_rst_n(rst_n),.I_tvalid(valid),.I_tuser(user),
        .I_tlast(last),.I_tdata(data),.I_tready(ready),
        .O_tvalid(ref_valid),.O_tuser(ref_user),.O_tlast(ref_last),
        .O_tready(ref_ready),.O_tdata(ref_edge),.O_emboss_data(ref_emboss),
        .O_cartoon_data(ref_cartoon),.O_morph_data(ref_morph)
    );
    reg [LATENCY-1:0] expected_valid=0,expected_user=0,expected_last=0;
    reg [31:0] noise=SEED;
    integer cycles=0,input_words=0,output_words=0,bubbles=0;
    integer early_sof=0,frames=0,resets=0,nonzero_morph=0;

    function [31:0] random_next(input [31:0] value);
        begin random_next=value*32'd1664525+32'd1013904223;end
    endfunction

    task cycle(input reg v,u,l,input reg [95:0] word);
        begin
            @(negedge clk);
            valid=v;user=u;last=l;data=word;
            noise=random_next(noise);ready=noise[7];
            expected_valid={expected_valid[LATENCY-2:0],v};
            expected_user={expected_user[LATENCY-2:0],u};
            expected_last={expected_last[LATENCY-2:0],l};
            @(posedge clk);#1;
            if ({dut_valid,dut_user,dut_last,dut_ready} !==
                {ref_valid,ref_user,ref_last,ref_ready})
                $fatal(1,"Control mismatch size=%0dx%0d cycle=%0d",WIDTH,HEIGHT,cycles);
            if ({dut_valid,dut_user,dut_last} !==
                {expected_valid[LATENCY-1],expected_user[LATENCY-1],
                 expected_last[LATENCY-1]} || dut_ready !== ready)
                $fatal(1,"Latency/ready mismatch size=%0dx%0d cycle=%0d",
                    WIDTH,HEIGHT,cycles);
            if (dut_edge !== ref_edge || dut_emboss !== ref_emboss ||
                dut_cartoon !== ref_cartoon || dut_morph !== ref_morph)
                $fatal(1,
                    "Data mismatch size=%0dx%0d cycle=%0d morph=%h reference=%h",
                    WIDTH,HEIGHT,cycles,dut_morph,ref_morph);
            cycles=cycles+1;
            if(v)input_words=input_words+1;else bubbles=bubbles+1;
            if(u&&!v)early_sof=early_sof+1;
            if(dut_valid)begin
                output_words=output_words+1;
                if(dut_morph!==96'd0)nonzero_morph=nonzero_morph+1;
            end
        end
    endtask

    task idle(input integer count);
        integer n;
        begin
            for(n=0;n<count;n=n+1)begin
                noise=random_next(noise);
                cycle(0,0,0,{noise,noise^32'h12345678,~noise});
            end
        end
    endtask

    task reset_dut;
        begin
            @(negedge clk);rst_n=0;valid=0;user=0;last=0;data=0;
            expected_valid=0;expected_user=0;expected_last=0;
            repeat(4)@(posedge clk);
            @(negedge clk);rst_n=1;
            resets=resets+1;
        end
    endtask

    task frame(input integer pattern,rows,input reg early,use_bubbles);
        integer x,y,lane,level;
        reg [95:0] word;
        begin
            if(early)begin cycle(0,1,0,96'h0123456789abcdef01234567);idle(2);end
            for(y=0;y<rows;y=y+1)for(x=0;x<WIDTH;x=x+4)begin
                if(use_bubbles&&((x/4+y)%5==0))idle(1+(x/4+y)%3);
                for(lane=0;lane<4;lane=lane+1)begin
                    noise=random_next(noise);
                    case(pattern)
                        0:word[95-lane*24 -:24]=24'd0;
                        1:word[95-lane*24 -:24]=24'hffffff;
                        2:begin
                            level=(x+lane+y*7)%16+112;
                            word[95-lane*24 -:24]={3{level[7:0]}};
                        end
                        3:word[95-lane*24 -:24]=
                            ((x+lane+y)%3==0)?24'hffffff:24'd0;
                        default:word[95-lane*24 -:24]=noise[23:0];
                    endcase
                end
                cycle(1,!early&&x==0&&y==0,x==WIDTH-4,word);
            end
            frames=frames+1;
        end
    endtask

    initial begin
        reset_dut();
        frame(4,HEIGHT,0,0);
        frame(2,HEIGHT,1,1);
        frame(0,HEIGHT,0,1);
        frame(1,HEIGHT,1,0);
        frame(3,3,0,1);
        frame(4,HEIGHT,1,1);
        frame(2,3,0,0);
        reset_dut();
        frame(3,HEIGHT,1,1);
        frame(4,HEIGHT,0,1);
        idle(LATENCY+4);
        if(output_words==0||nonzero_morph==0||early_sof<4||resets!=2)
            $fatal(1,"Coverage missing size=%0dx%0d",WIDTH,HEIGHT);
        $display(
            "SCHARR_MORPHOLOGY_CASE_PASS size=%0dx%0d gaussian=%0d threshold=%0d frames=%0d cycles=%0d input_words=%0d output_words=%0d bubbles=%0d early_sof=%0d resets=%0d nonzero_morph=%0d",
            WIDTH,HEIGHT,GAUSSIAN_ENABLE,EDGE_TH,frames,cycles,input_words,
            output_words,bubbles,early_sof,resets,nonzero_morph);
        done=1;
    end
endmodule

module tb_scharr_morphology_equivalence;
    wire [3:0] done;
    scharr_morphology_equivalence_case #(
        .WIDTH(16),.HEIGHT(16),.GAUSSIAN_ENABLE(1),.EDGE_TH(20),.SEED(1)
    ) square(done[0]);
    scharr_morphology_equivalence_case #(
        .WIDTH(20),.HEIGHT(17),.GAUSSIAN_ENABLE(0),.EDGE_TH(0),.SEED(17)
    ) odd_height(done[1]);
    scharr_morphology_equivalence_case #(
        .WIDTH(64),.HEIGHT(49),.GAUSSIAN_ENABLE(1),.EDGE_TH(255),.SEED(29)
    ) rectangular(done[2]);
    scharr_morphology_equivalence_case #(
        .WIDTH(1280),.HEIGHT(9),.GAUSSIAN_ENABLE(0),.EDGE_TH(21),.SEED(131)
    ) full_width(done[3]);
    initial begin
        wait(&done);
        $display("SCHARR_MORPHOLOGY_EQUIVALENCE_PASS cases=4 latency=11");
        $finish;
    end
    initial begin #1000000000;$fatal(1,"timeout");end
endmodule
