`timescale 1ns/1ps
// The frozen implementation is an independent temporal reference. The new
// frontend must preserve every mask-preview clock and delay detector results
// by exactly one clock, including clears, frame IDs and interrupted frames.
module tb_color_frontend_pipeline_equivalence #(
    parameter integer DELTA = 6
);
    localparam integer W=64, H=48, GROUPS=W/4;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, user=0, valid=0, clear=0;
    reg [95:0] data=0;
    reg [1:0] color=0;
    reg [3:0] view=9;
    reg [9:0] frame_id=0;
    wire [3:0] mask_new,mask_old;
    wire [98:0] result_new,result_old;
    wire [219:0] multi_new,multi_old;
    wire ready_new,found_new,toggle_new,ready_old,found_old,toggle_old;
    wire [11:0] xmin_new,xmax_new,ymin_new,ymax_new,cx_new,cy_new;
    wire [11:0] xmin_old,xmax_old,ymin_old,ymax_old,cx_old,cy_old;
    wire [23:0] pixels_new,pixels_old;
    wire mready_new,mready_old,overflow_new,overflow_old;
    wire [3:0] mvalid_new,mvalid_old,hold_new,hold_old;
    wire [191:0] boxes_new,boxes_old;
    wire [7:0] shapes_new,shapes_old;
    wire [9:0] id_new,id_old;
    red_target_detect_96 #(
        .IMG_WIDTH(W),.IMG_HEIGHT(H),.RED_DELTA(DELTA),
        .MIN_PIXELS(8),.MIN_WIDTH(3),.MIN_HEIGHT(3),.MULTI_ENABLE(1)
    ) dut (
        .I_clk(clk),.I_rst_n(rst_n),.I_tuser(user),.I_tvalid(valid),.I_tdata(data),
        .I_color_mode(color),.I_mask_view_mode(view),.O_mask_pixels(mask_new),
        .O_result_ready(ready_new),.O_found(found_new),.O_xmin(xmin_new),.O_xmax(xmax_new),
        .O_ymin(ymin_new),.O_ymax(ymax_new),.O_center_x(cx_new),.O_center_y(cy_new),
        .O_pixels(pixels_new),.O_frame_toggle(toggle_new),.I_frame_id(frame_id),
        .I_multi_clear(clear),.O_multi_ready(mready_new),.O_multi_valid(mvalid_new),
        .O_multi_hold(hold_new),.O_multi_boxes(boxes_new),.O_multi_shapes(shapes_new),
        .O_multi_frame_id(id_new),.O_multi_overflow(overflow_new)
    );
    red_target_detect_96_frozen #(
        .IMG_WIDTH(W),.IMG_HEIGHT(H),.RED_DELTA(DELTA),
        .MIN_PIXELS(8),.MIN_WIDTH(3),.MIN_HEIGHT(3),.MULTI_ENABLE(1)
    ) reference_dut (
        .I_clk(clk),.I_rst_n(rst_n),.I_tuser(user),.I_tvalid(valid),.I_tdata(data),
        .I_color_mode(color),.I_mask_view_mode(view),.O_mask_pixels(mask_old),
        .O_result_ready(ready_old),.O_found(found_old),.O_xmin(xmin_old),.O_xmax(xmax_old),
        .O_ymin(ymin_old),.O_ymax(ymax_old),.O_center_x(cx_old),.O_center_y(cy_old),
        .O_pixels(pixels_old),.O_frame_toggle(toggle_old),.I_frame_id(frame_id),
        .I_multi_clear(clear),.O_multi_ready(mready_old),.O_multi_valid(mvalid_old),
        .O_multi_hold(hold_old),.O_multi_boxes(boxes_old),.O_multi_shapes(shapes_old),
        .O_multi_frame_id(id_old),.O_multi_overflow(overflow_old)
    );
    assign result_new={ready_new,found_new,xmin_new,xmax_new,ymin_new,ymax_new,
        cx_new,cy_new,pixels_new,toggle_new};
    assign result_old={ready_old,found_old,xmin_old,xmax_old,ymin_old,ymax_old,
        cx_old,cy_old,pixels_old,toggle_old};
    assign multi_new={mready_new,mvalid_new,hold_new,boxes_new,shapes_new,id_new,overflow_new};
    assign multi_old={mready_old,mvalid_old,hold_old,boxes_old,shapes_old,id_old,overflow_old};
    integer clocks=0,checks=0,results=0,mresults=0,objects=0,clears=0,beats=0;
    reg [31:0] random_state=32'h70697065;
    function automatic [31:0] step_random(input [31:0] value);
        reg [31:0] x;
        begin
            x=value^(value<<13);x=x^(x>>17);step_random=x^(x<<5);
        end
    endfunction
    function automatic [23:0] primary(input integer mode);
        case(mode)
            1: primary=24'h20f020;
            2: primary=24'h2020f0;
            default: primary=24'hf02020;
        endcase
    endfunction
    always @(posedge clk) begin : compare
        reg [98:0] previous_result;
        reg [219:0] previous_multi;
        previous_result=result_old;
        previous_multi=multi_old;
        clocks=clocks+1;
        #1;
        if(rst_n && clocks>5) begin
            if(mask_new !== mask_old)
                $fatal(1,"Preview changed clock=%0d delta=%0d new=%h old=%h",
                    clocks,DELTA,mask_new,mask_old);
            if(result_new !== previous_result)
                $fatal(1,"Result is not exactly one clock later clock=%0d delta=%0d",clocks,DELTA);
            if(multi_new !== previous_multi)
                $fatal(1,"Multi result/clear identity changed clock=%0d delta=%0d new=%h old=%h",
                    clocks,DELTA,multi_new,previous_multi);
            checks=checks+1;
            if(ready_new) results=results+1;
            if(mready_new) begin
                mresults=mresults+1;
                if(|mvalid_new) objects=objects+1;
            end
        end
    end
    task automatic tick(input bit v,input bit u,input bit c,input [95:0] d);
        begin
            @(negedge clk);valid=v;user=u;clear=c;data=d;
            if(v) beats=beats+1;
            if(c) clears=clears+1;
        end
    endtask
    task automatic image_frame(input integer index,input bit early,input bit gaps,
        input bit marker);
        integer y,g,lane,x;
        reg [95:0] pixels;
        begin
            color=index%3;view=9+index%4;frame_id=(1018+index)%1024;
            if(early && marker) begin
                tick(0,1,index>=8 && index%3==0,0);
                repeat(3) tick(0,0,0,0);
            end
            for(y=0;y<H;y=y+1) for(g=0;g<GROUPS;g=g+1) begin
                if(gaps && ((y+g)%7==0)) tick(0,0,0,0);
                pixels=0;
                for(lane=0;lane<4;lane=lane+1) begin
                    x=4*g+lane;
                    pixels[95-24*lane -:24]=
                        ((x>=8 && x<28 && y>=8 && y<38) ||
                         ((x-46)*(x-46)+(y-24)*(y-24)<81)) ?
                        primary(color) : 24'h101010;
                end
                tick(1,!early && marker && y==0 && g==0,
                    !early && marker && index>=8 && index%3==0 && y==0 && g==0,pixels);
            end
        end
    endtask
    integer frame_index,i,lane;
    reg [95:0] random_pixels;
    initial begin
        repeat(4) @(negedge clk);
        rst_n=1;
        // Immediate and early SOF, frame-ID wrap, gaps, implicit next frame,
        // and mode/clear changes while old descriptors are still in flight.
        for(frame_index=0;frame_index<16;frame_index=frame_index+1) begin
            image_frame(frame_index,frame_index%2,frame_index%3==1,frame_index!=5);
            if(frame_index<8) repeat(1500) tick(0,0,0,0);
            else if(frame_index%4==2) repeat(400) tick(0,0,0,0);
        end
        repeat(1200) tick(0,0,0,0);
        // Every clock changes all three channels and the color/view selector.
        // This also exercises the legacy nine-bit wrapped delta parameters.
        for(i=0;i<12000;i=i+1) begin
            random_pixels=0;
            for(lane=0;lane<4;lane=lane+1) begin
                random_state=step_random(random_state);
                random_pixels[95-24*lane -:24]=random_state[23:0];
            end
            color=i%4;view=9+i%4;frame_id=i%1024;
            tick(i%11!=0,i%811==0,i%1009==0,random_pixels);
        end
        repeat(1200) tick(0,0,0,0);
        if(results<16 || mresults<4 || checks<20000 ||
            (DELTA==6 && objects==0))
            $fatal(1,"Insufficient coverage results=%0d multi=%0d objects=%0d checks=%0d",
                results,mresults,objects,checks);
        $display("COLOR_FRONTEND_EQUIVALENCE_PASS delta=%0d clocks=%0d checks=%0d beats=%0d results=%0d multi=%0d objects=%0d clears=%0d preview_latency_unchanged=1 result_delay=1",
            DELTA,clocks,checks,beats,results,mresults,objects,clears);
        $finish;
    end
    initial begin #100000000;$fatal(1,"Timeout");end
endmodule
