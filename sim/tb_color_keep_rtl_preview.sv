`timescale 1ns/1ps
// Synthetic chart rendered through the production two-clock color-keep DUT.
module tb_color_keep_rtl_preview;
    localparam integer W=384,H=256;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0;
    reg [23:0] input_rgb=0;
    wire [23:0] output_rgb;
    integer input_file,output_file;
    integer input_pixels=0,output_pixels=0;
    integer red_pixels=0,green_pixels=0,gray_pixels=0;
    reg pending=0;
    reg [23:0] expected_previous=0;

    display_effects_rgb888 dut (
        .I_clk(clk),.I_rst_n(rst_n),.I_rgb(input_rgb),
        .I_mode(4'd5),.I_param(8'd0),.O_rgb(output_rgb)
    );

    function automatic [23:0] scene(input integer x,input integer y);
        integer r,g,b,shade,dx,dy;
        begin
            // The first row is red, green, blue, yellow, pink and neutral gray.
            if(y<64) begin
                shade=160+(x%64)*95/63;
                case(x/64)
                    0: begin r=shade;g=shade/6;b=shade/7;end
                    1: begin r=shade/7;g=shade;b=shade/6;end
                    2: begin r=shade/7;g=shade/6;b=shade;end
                    3: begin r=shade;g=shade;b=shade/8;end
                    4: begin r=shade;g=shade/2;b=shade*4/5;end
                    default: begin r=shade;g=shade;b=shade;end
                endcase
            end else begin
                shade=80+(x*3+y*5)%40;
                r=shade;g=shade+6;b=shade+14;
                // A textured warm wall and neutral ground exercise rejection.
                if(y<184) begin r=shade+50;g=shade+32;b=shade+12;end
                if((x/16+y/12)%2==0) begin r=r+12;g=g+12;b=b+12;end
                dx=x-75;dy=y-134;
                if(dx*dx+dy*dy<42*42) begin
                    shade=130+(x*3+y*7)%100;
                    r=shade;g=shade/5;b=shade/6;
                end
                if(x>=141 && x<222 && y>=94 && y<177) begin
                    shade=120+(x*5+y*3)%110;
                    r=shade/6;g=shade;b=shade/5;
                end
                dx=x-289;dy=y-134;
                if((dx<0?-dx:dx)+(dy<0?-dy:dy)<48) begin
                    shade=130+(x*7+y*5)%110;
                    r=shade/6;g=shade/5;b=shade;
                end
                if(x>=35 && x<116 && y>=200 && y<238) begin
                    r=230;g=210;b=30;
                end
                if(x>=151 && x<232 && y>=200 && y<238) begin
                    r=232;g=112;b=191;
                end
                if(x>=267 && x<348 && y>=200 && y<238) begin
                    shade=40+(x-267)*200/80;
                    r=shade;g=shade;b=shade;
                end
                // High-contrast texture remains visible after desaturation.
                if(y>=244 && x%12<3) begin r=35;g=35;b=35;end
            end
            scene={8'(r),8'(g),8'(b)};
        end
    endfunction

    function automatic [23:0] reference(input [23:0] value);
        integer r,g,b,luma;
        bit red,green;
        begin
            r=value[23:16];g=value[15:8];b=value[7:0];
            red=r>=24 && r-g>=6 && r-b>=6 && 2*r>=3*g && 2*r>=3*b &&
                3*g<=r+2*b && 3*b<=r+2*g;
            green=g>=24 && g-r>=6 && g-b>=6 && 2*g>=3*r && 2*g>=3*b &&
                  3*r<=g+2*b && 3*b<=g+2*r;
            luma=(77*r+150*g+29*b+128)/256;
            reference=red || green ? value : {3{8'(luma)}};
        end
    endfunction

    task automatic record_output;
        begin
            if(output_rgb!==expected_previous)
                $fatal(1,"Preview pixel%0d mismatch got=%h expected=%h",
                    output_pixels,output_rgb,expected_previous);
            $fdisplay(output_file,"%0d %0d %0d",
                output_rgb[23:16],output_rgb[15:8],output_rgb[7:0]);
            output_pixels=output_pixels+1;
            if(output_rgb[23:16]==output_rgb[15:8] &&
                output_rgb[15:8]==output_rgb[7:0]) gray_pixels=gray_pixels+1;
            else if(output_rgb[23:16]>output_rgb[15:8]) red_pixels=red_pixels+1;
            else green_pixels=green_pixels+1;
        end
    endtask

    initial begin
        input_file=$fopen("color_keep_input.ppm","w");
        output_file=$fopen("color_keep_output.ppm","w");
        if(!input_file || !output_file) $fatal(1,"Cannot create PPM preview");
        $fdisplay(input_file,"P3\n%0d %0d\n255",W,H);
        $fdisplay(output_file,"P3\n%0d %0d\n255",W,H);
        repeat(3) @(posedge clk);
        @(negedge clk);rst_n=1;
        for(integer y=0;y<H;y=y+1)
            for(integer x=0;x<W;x=x+1) begin
                @(negedge clk);
                input_rgb=scene(x,y);
                $fdisplay(input_file,"%0d %0d %0d",
                    input_rgb[23:16],input_rgb[15:8],input_rgb[7:0]);
                input_pixels=input_pixels+1;
                @(posedge clk);#1;
                if(pending) record_output();
                expected_previous=reference(input_rgb);
                pending=1;
            end
        @(posedge clk);#1;record_output();
        $fclose(input_file);$fclose(output_file);
        if(input_pixels!=W*H || output_pixels!=W*H ||
            red_pixels==0 || green_pixels==0 || gray_pixels==0)
            $fatal(1,"Preview coverage incomplete");
        $display("COLOR_KEEP_RTL_PREVIEW_PASS pixels=%0d red=%0d green=%0d gray=%0d latency=2 synthetic=1",
            output_pixels,red_pixels,green_pixels,gray_pixels);
        $finish;
    end
    initial begin
        #2000000;
        $fatal(1,"Color keep RTL preview timeout");
    end
endmodule
