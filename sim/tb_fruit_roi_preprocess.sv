`timescale 1ns/1ps

// Actual preprocessor, RAM caches, normalizer and background-reference store.
// Every coordinate, interpolation result and Q9 output is computed from
// literal display geometry and arithmetic, without using a DUT ROM as oracle.
module fruit_roi_preprocess_case #(
    parameter integer CASE_INDEX=0
)(output reg finished=0);
    localparam integer ROI_X=CASE_INDEX==0 ? 240 : CASE_INDEX==1 ? 400 : -160;
    localparam integer ROI_Y=CASE_INDEX==2 ? -80 : 120;
    localparam integer PIXELS=128*128, WRITE_BEATS=PIXELS*3/8;
    localparam [31:0] SNAPSHOT_BASE=32'h00e00000+CASE_INDEX*32'h00300000;
    localparam [31:0] OUTPUT_BASE=32'h00d00000;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,start=0;
    wire busy,done,mem_valid,mem_write;
    wire [31:0] mem_addr;
    wire [127:0] mem_data;
    reg mem_ready=0,mem_rsp_valid=0;
    reg [127:0] mem_rsp_data=0;
    wire green_valid,green_row_end;
    wire [7:0] green_pixel;
    wire background_ready,foreground;
    wire [10:0] changed;

    handfixed_preprocess dut (
        .clk(clk),.rst_n(rst_n),.start(start),.classifier(1'b1),
        .snapshot_base(SNAPSHOT_BASE),.roi_x(16'(ROI_X)),.roi_y(16'(ROI_Y)),
        .roi_side(16'd480),.has_texture(),.texture_edges(),.texture_range(),
        .green_valid(green_valid),.green_row_end(green_row_end),.green_pixel(green_pixel),
        .busy(busy),.done(done),.mem_valid(mem_valid),.mem_write(mem_write),
        .mem_addr(mem_addr),.mem_data(mem_data),.mem_ready(mem_ready),
        .mem_rsp_valid(mem_rsp_valid),.mem_rsp_data(mem_rsp_data)
    );
    handfixed_background background (
        .clk(clk),.rst_n(rst_n),.run_enabled(1'b0),.start(start),
        .scan_background(1'b1),.done(done),.pixel_valid(green_valid),
        .row_end(green_row_end),.green(green_pixel),
        .reference_ready(background_ready),.foreground(foreground),.changed_pixels(changed)
    );

    function automatic integer fill_value(input integer channel);
        case(channel)
            0: fill_value=124;
            1: fill_value=116;
            default: fill_value=104;
        endcase
    endfunction
    function automatic integer source_pixel(input integer x,y,channel);
        case(channel)
            0: source_pixel=(x*17+y*3+(x/13)*11+27)%256;
            1: source_pixel=(x*5+y*29+(y/11)*37+91)%256;
            default: source_pixel=(x*11+y*7+(x*y)%193+53)%256;
        endcase
    endfunction
    function automatic integer source_sample(input integer x,y,channel);
        source_sample=x<0 || y<0 || x>=1280 || y>=720 ?
            fill_value(channel) : source_pixel(x,y,channel);
    endfunction

    // Both visible ROIs use the historical Q16 480/128 step and full 128x128
    // output. The negative-origin case exercises fill before each separable,
    // rounded Q8 bilinear stage, including interpolation across frame edges.
    function automatic integer expected_pixel(input integer x,y,channel);
        integer xq,yq,x0,x1,y0,y1,fx,fy,top,bottom;
        begin
            xq=(ROI_X<<16)+((480<<16)/256)-32768+x*((480<<16)/128);
            yq=(ROI_Y<<16)+((480<<16)/256)-32768+y*((480<<16)/128);
            x0=xq>>>16;y0=yq>>>16;
            x1=x0+((xq&65535)!=0);y1=y0+((yq&65535)!=0);
            fx=(xq>>8)&255;fy=(yq>>8)&255;
            top=(source_sample(x0,y0,channel)*(256-fx)+
                 source_sample(x1,y0,channel)*fx+128)>>8;
            bottom=(source_sample(x0,y1,channel)*(256-fx)+
                    source_sample(x1,y1,channel)*fx+128)>>8;
            expected_pixel=(top*(256-fy)+bottom*fy+128)>>8;
        end
    endfunction

    // Integer form of ImageNet RGB normalization followed by Q9 rounding:
    // round_even(512 * (pixel/255 - mean) / std). Mean/std use their exact
    // decimal constants; all 768 results match the separately retained table.
    function automatic [15:0] normalized_pixel(input integer channel,pixel);
        integer mean_milli,std_milli,numerator,denominator,magnitude,quotient,remainder;
        begin
            case(channel)
                0: begin mean_milli=485;std_milli=229;end
                1: begin mean_milli=456;std_milli=224;end
                default: begin mean_milli=406;std_milli=225;end
            endcase
            numerator=512*(pixel*1000-255*mean_milli);
            denominator=255*std_milli;
            magnitude=numerator<0 ? -numerator : numerator;
            quotient=magnitude/denominator;remainder=magnitude%denominator;
            if(2*remainder>denominator ||
               (2*remainder==denominator && (quotient&1)!=0))
                quotient=quotient+1;
            if(numerator<0) quotient=-quotient;
            if(quotient>2047) quotient=2047;
            if(quotient< -2048) quotient=-2048;
            normalized_pixel=16'(quotient);
        end
    endfunction
    function automatic [127:0] snapshot_beat(input [31:0] address);
        integer offset,pixel_index,x,y,channel;
        begin
            snapshot_beat=0;
            for(integer lane=0;lane<16;lane=lane+1) begin
                offset=address-SNAPSHOT_BASE+lane;
                pixel_index=offset/3;
                x=pixel_index%1280;y=pixel_index/1280;channel=offset%3;
                snapshot_beat[(15-lane)*8 +:8]=8'(source_pixel(x,y,channel));
            end
        end
    endfunction

    integer green_count=0,background_samples=0;
    integer write_count=0,normalized_checks=0,out_of_frame_sample_checks=0;
    integer coordinate_checks=0,read_count=0,stall_cycles=0;
    integer immediate_reads=0,delayed_reads=0,cycles=0;
    reg [15:0] sampled_byte_offsets=0;
    reg pending=0;
    reg [31:0] pending_address=0;
    integer pending_delay=0;
    reg [31:0] random_state=32'h1f52a6e9+CASE_INDEX;
    reg previous_stall=0,held_write=0;
    reg [31:0] held_address=0;
    reg [127:0] held_data=0;

    // Respond on acceptance or after a separate delayed response. Reads and
    // writes both see independent backpressure, including held requests.
    always @(negedge clk) begin
        mem_ready=0;mem_rsp_valid=0;mem_rsp_data=0;
        if(rst_n) begin
            random_state={random_state[30:0],
                random_state[31]^random_state[21]^random_state[1]^random_state[0]};
            mem_ready=random_state[2:0]!=0 && random_state[4:3]!=0;
            if(pending && pending_delay==0) begin
                mem_rsp_valid=1;mem_rsp_data=snapshot_beat(pending_address);
            end else if(!pending && mem_valid && !mem_write && mem_ready &&
                        random_state[6]) begin
                mem_rsp_valid=1;mem_rsp_data=snapshot_beat(mem_addr);
            end
        end
    end

    // Coordinates here are DUT observations; the expected positions use only
    // the independently counted output pixel and literal ROI arithmetic.
    task automatic check_sample_coordinates;
        integer pixel_index,x,y,channel,xq,yq,sx,sy,fx,fy;
        reg expected_out;
        reg [31:0] expected_address;
        begin
            channel=dut.channel;
            if(channel>2) $fatal(1,"Invalid source channel case=%0d",CASE_INDEX);
            pixel_index=channel==2 ? green_count-1 : green_count;
            x=pixel_index%128;y=pixel_index/128;
            if(pixel_index<0 || pixel_index>=PIXELS)
                $fatal(1,"DDR sampling occurred outside output case=%0d pixel=%0d",
                    CASE_INDEX,pixel_index);
            if(dut.ox!==8'(x) || dut.oy!==8'(y))
                $fatal(1,"Source/output cursor mismatch case=%0d expected=%0d,%0d got=%0d,%0d",
                    CASE_INDEX,x,y,dut.ox,dut.oy);
            xq=(ROI_X<<16)+((480<<16)/256)-32768+x*((480<<16)/128);
            yq=(ROI_Y<<16)+((480<<16)/256)-32768+y*((480<<16)/128);
            sx=xq>>>16;sy=yq>>>16;
            if(dut.sample_index[0] && (xq&65535)!=0) sx=sx+1;
            if(dut.sample_index[1] && (yq&65535)!=0) sy=sy+1;
            fx=(xq>>8)&255;fy=(yq>>8)&255;
            expected_out=sx<0 || sy<0 || sx>=1280 || sy>=720;
            expected_address=SNAPSHOT_BASE+(sy*1280+sx)*3+channel;
            if($signed(dut.sample_x)!=sx || $signed(dut.sample_y)!=sy ||
                dut.fx!==8'(fx) || dut.fy!==8'(fy) ||
                dut.sample_out!==expected_out ||
                (!expected_out && dut.sample_address!==expected_address))
                $fatal(1,"ROI sample address mismatch case=%0d out=%0d,%0d sample=%0d channel=%0d expected=%0d,%0d addr=%h got=%0d,%0d addr=%h",
                    CASE_INDEX,x,y,dut.sample_index,channel,sx,sy,expected_address,
                    $signed(dut.sample_x),$signed(dut.sample_y),dut.sample_address);
            if(mem_valid && !mem_write &&
                (expected_out || mem_addr!==(expected_address&32'hfffffff0)))
                $fatal(1,"DDR request does not address expected ROI beat case=%0d",
                    CASE_INDEX);
            if(!expected_out) sampled_byte_offsets[expected_address[3:0]]=1'b1;
        end
    endtask

    always @(posedge clk) begin: verify
        integer x,y,group_index,channel,pixel_index,expected_green;
        reg selected;
        reg [31:0] expected_address;
        reg [127:0] expected_word;
        if(!rst_n) begin
            previous_stall=0;pending=0;pending_delay=0;
        end else begin
            cycles=cycles+1;
            if(previous_stall &&
               (!mem_valid || mem_write!==held_write || mem_addr!==held_address ||
                (held_write && mem_data!==held_data)))
                $fatal(1,"DDR request changed under backpressure case=%0d",CASE_INDEX);
            previous_stall=mem_valid && !mem_ready;
            if(previous_stall) begin
                held_write=mem_write;held_address=mem_addr;held_data=mem_data;
                stall_cycles=stall_cycles+1;
            end
            if(dut.state==2) begin
                check_sample_coordinates();
                coordinate_checks=coordinate_checks+1;
                if(dut.sample_out) out_of_frame_sample_checks=out_of_frame_sample_checks+1;
            end
            if(pending) begin
                if(mem_rsp_valid) pending=0;
                else if(pending_delay>0) pending_delay=pending_delay-1;
            end
            if(mem_valid && mem_ready) begin
                if(mem_addr[3:0]!=0)
                    $fatal(1,"Unaligned DDR request case=%0d addr=%h",CASE_INDEX,mem_addr);
                if(mem_write) begin
                    if(write_count>=WRITE_BEATS)
                        $fatal(1,"Too many CHW writes case=%0d",CASE_INDEX);
                    group_index=write_count/3;channel=write_count%3;
                    expected_address=OUTPUT_BASE+channel*32768+group_index*16;
                    if(mem_addr!==expected_address)
                        $fatal(1,"CHW plane/write address mismatch case=%0d beat=%0d got=%h expected=%h",
                            CASE_INDEX,write_count,mem_addr,expected_address);
                    for(integer lane=0;lane<8;lane=lane+1) begin
                        pixel_index=group_index*8+lane;
                        x=pixel_index%128;y=pixel_index/128;
                        expected_word[lane*16 +:16]=
                            normalized_pixel(channel,expected_pixel(x,y,channel));
                        normalized_checks=normalized_checks+1;
                    end
                    if(mem_data!==expected_word)
                        $fatal(1,"CHW normalized pixels mismatch case=%0d beat=%0d channel=%0d got=%h expected=%h",
                            CASE_INDEX,write_count,channel,mem_data,expected_word);
                    write_count=write_count+1;
                end else begin
                    check_sample_coordinates();
                    if(pending || mem_addr<SNAPSHOT_BASE ||
                       mem_addr>=SNAPSHOT_BASE+1280*720*3)
                        $fatal(1,"Invalid/overlapping snapshot read case=%0d addr=%h",
                            CASE_INDEX,mem_addr);
                    read_count=read_count+1;
                    if(mem_rsp_valid) immediate_reads=immediate_reads+1;
                    else begin
                        pending=1;pending_address=mem_addr;
                        pending_delay=1+random_state[8:7];delayed_reads=delayed_reads+1;
                    end
                end
            end
            x=green_count%128;y=green_count/128;
            selected=green_valid && (x%4==1) && (y%4==1);
            if(background.reference_memory.I_wr_en!==selected)
                $fatal(1,"Background 32x32 selector mismatch case=%0d pixel=%0d",
                    CASE_INDEX,green_count);
            if(selected) begin
                expected_green=expected_pixel(x,y,1);
                if(background.reference_memory.I_wr_addr!==11'(1024+background_samples) ||
                   background.reference_memory.I_wr_data!==8'(expected_green))
                    $fatal(1,"Background reference write mismatch case=%0d sample=%0d",
                        CASE_INDEX,background_samples);
                background_samples=background_samples+1;
            end
            if(green_valid) begin
                if(green_count>=PIXELS || green_pixel!==8'(expected_pixel(x,y,1)) ||
                    green_row_end!==(x==127))
                    $fatal(1,"Green pixel/row-end mismatch case=%0d pixel=%0d x=%0d y=%0d got=%0d expected=%0d",
                        CASE_INDEX,green_count,x,y,green_pixel,expected_pixel(x,y,1));
                green_count=green_count+1;
            end
        end
    end

    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        repeat(2) @(negedge clk);start=1;
        @(negedge clk);start=0;
        wait(done);
        repeat(3) @(negedge clk);
        if(busy || pending || previous_stall || write_count!=WRITE_BEATS ||
            normalized_checks!=PIXELS*3 || green_count!=PIXELS ||
            coordinate_checks!=196608 ||
            (CASE_INDEX!=2 && out_of_frame_sample_checks!=0) ||
            (CASE_INDEX==2 &&
             (out_of_frame_sample_checks==0 || out_of_frame_sample_checks>=coordinate_checks)) ||
            sampled_byte_offsets!==16'hffff || read_count<1000 ||
            immediate_reads<100 || delayed_reads<100 || stall_cycles<100 ||
            background_samples!=1024 ||
            !background_ready || foreground || background.samples!=1024)
            $fatal(1,"Incomplete ROI/background coverage case=%0d green=%0d writes=%0d normalized=%0d coords=%0d offsets=%h reads=%0d immediate=%0d delayed=%0d stalls=%0d bg=%0d outside_samples=%0d ready=%b",
                CASE_INDEX,green_count,write_count,normalized_checks,
                coordinate_checks,sampled_byte_offsets,read_count,immediate_reads,delayed_reads,
                stall_cycles,background_samples,out_of_frame_sample_checks,background_ready);
        $display("FRUIT_ROI_PREPROCESS_CASE_PASS case=%0d source_x=%0d source_y=%0d source_width=480 source_height=480 green=%0d normalized=%0d writes=%0d coordinates=%0d reads=%0d immediate=%0d delayed=%0d stalls=%0d background_samples=%0d outside_samples=%0d cycles=%0d",
            CASE_INDEX,ROI_X,ROI_Y,green_count,normalized_checks,write_count,coordinate_checks,
            read_count,immediate_reads,delayed_reads,stall_cycles,background_samples,
            out_of_frame_sample_checks,cycles);
        finished=1;
    end
endmodule

module tb_fruit_roi_preprocess;
    wire [2:0] finished;
    fruit_roi_preprocess_case centered_square_case(finished[0]);
    fruit_roi_preprocess_case #(.CASE_INDEX(1)) legacy_square_case(finished[1]);
    fruit_roi_preprocess_case #(.CASE_INDEX(2)) off_frame_square_case(finished[2]);
    initial begin
        wait(&finished);
        $display("FRUIT_ROI_PREPROCESS_PASS cases=3 centered_square_240_120_480=1 legacy_square_400_120_480=1 negative_origin_fill=1 full_rgb128_square=1 independent_q9_oracle=1 complete_background_reference=1");
        $finish;
    end
    initial begin #100000000;$fatal(1,"Fruit ROI preprocessing timeout");end
endmodule
