// Immutable RGB888 snapshot -> detector letterbox or square hand ROI -> CHW.
// Half-pixel, separable Q8 bilinear sampling; edge samples clamp to ROI edges,
// out-of-frame samples use the same RGB fill as training. 1280x720 camera.
module handfixed_preprocess(
    input wire clk,rst_n,start,classifier,
    input wire [31:0] snapshot_base,
    input wire signed [15:0] roi_x,roi_y,
    input wire [15:0] roi_side,
    // Cheap flat-region rejection, not semantic hand-presence detection.
    output wire has_texture,
    output wire [13:0] texture_edges,
    output wire [7:0] texture_range,
    // Unnormalized green stream for the optional background comparison.
    output wire green_valid,green_row_end,
    output wire [7:0] green_pixel,
    output wire busy,
    output reg done,
    output wire mem_valid,mem_write,
    output wire [31:0] mem_addr,
    output wire [127:0] mem_data,
    input wire mem_ready,mem_rsp_valid,
    input wire [127:0] mem_rsp_data
);
    localparam IDLE=0,PIXEL=1,SAMPLE=2,REQUEST=3,RESPONSE=4,INTERP=5,NORM=6,NORM_WAIT=7,STORE=8,WRITE=9,NEXT=10,VERTICAL=11;
    reg [7:0] green_min,green_max,previous_green;
    reg [13:0] edge_count;
    assign texture_edges=edge_count;
    assign texture_range=green_max-green_min;
    assign has_texture=texture_range>=16 && edge_count>=24;
    reg [3:0] state;
    reg mode;
    reg [7:0] ox,oy;
    reg [1:0] channel,sample_index;
    reg [7:0] samples[0:3];
    reg [7:0] pixel;
    assign green_valid=state==NORM && channel==1 && mode;
    assign green_row_end=ox==95;
    assign green_pixel=pixel;
    wire [7:0] green_delta=pixel>=previous_green ? pixel-previous_green : previous_green-pixel;
    reg [7:0] horizontal0,horizontal1;
    reg signed [31:0] xq,yq,xstart,ystart;
    reg [31:0] step;
    reg [15:0] side;
    reg signed [15:0] origin_x,origin_y;
    reg signed [15:0] x0,x1,y0,y1;
    reg [7:0] fx,fy;
    reg [3:0] byte_offset;
    reg [31:0] request_address;
    // Visit RGB at each output pixel before advancing spatially. Four cache
    // lines cover both bilinear rows, including RGB pixels crossing a beat.
    // This avoids rereading the snapshot for three separate channel passes.
    reg [127:0] store_red,store_green,store_blue;
    reg [127:0] cache_data[0:3];
    reg [31:0] cache_address[0:3];
    reg [31:0] store_address;
    reg [3:0] cache_valid;
    reg [1:0] cache_next;
    reg [2:0] pack_index;
    wire [7:0] width=mode ? 8'd96 : 8'd128;
    wire [7:0] height=8'd96;
    wire border=!mode && (oy<12 || oy>=84);
    wire signed [15:0] sample_x=sample_index[0] ? x1 : x0;
    wire signed [15:0] sample_y=sample_index[1] ? y1 : y0;
    wire sample_out=sample_x<0 || sample_y<0 || sample_x>=1280 || sample_y>=720;
    wire [31:0] ys={16'd0,sample_y};
    wire [31:0] xs={16'd0,sample_x};
    wire [31:0] sample_address=snapshot_base+(ys<<12)-(ys<<8)+(xs<<1)+xs+channel;
    wire [7:0] fill=channel==0 ? 8'd124 : channel==1 ? 8'd116 : 8'd104;
    wire [10:0] norm_address={mode,channel,pixel};
    wire [15:0] normalized;
    wire [15:0] plane_offset=mode ? (channel==0 ? 16'd0 : channel==1 ? 16'd18432 : 16'd36864) :
                                                 (channel==0 ? 16'd0 : channel==1 ? 16'd24576 : 16'd49152);
    wire [3:0] cache_hit={cache_valid[3] && cache_address[3]=={sample_address[31:4],4'd0},
                          cache_valid[2] && cache_address[2]=={sample_address[31:4],4'd0},
                          cache_valid[1] && cache_address[1]=={sample_address[31:4],4'd0},
                          cache_valid[0] && cache_address[0]=={sample_address[31:4],4'd0}};
    wire [127:0] cached_data=cache_hit[0] ? cache_data[0] : cache_hit[1] ? cache_data[1] :
                            cache_hit[2] ? cache_data[2] : cache_data[3];
    handcnn_normalize norm_rom(.clk(clk),.address(norm_address),.value(normalized));
    assign busy=state!=IDLE;
    assign mem_valid=state==REQUEST || state==WRITE;
    assign mem_write=state==WRITE;
    assign mem_addr=mem_write ? store_address+plane_offset : request_address;
    assign mem_data=channel==0 ? store_red : channel==1 ? store_green : store_blue;
    function [15:0] mul8;
        input [7:0] a,b;
        reg [15:0] p0,p1,p2,p3,p4,p5,p6,p7,s0,s1,s2,s3;
        begin
            p0=b[0] ? {8'd0,a} : 0;p1=b[1] ? ({8'd0,a}<<1) : 0;
            p2=b[2] ? ({8'd0,a}<<2) : 0;p3=b[3] ? ({8'd0,a}<<3) : 0;
            p4=b[4] ? ({8'd0,a}<<4) : 0;p5=b[5] ? ({8'd0,a}<<5) : 0;
            p6=b[6] ? ({8'd0,a}<<6) : 0;p7=b[7] ? ({8'd0,a}<<7) : 0;
            s0=p0+p1;s1=p2+p3;s2=p4+p5;s3=p6+p7;
            mul8=(s0+s1)+(s2+s3);
        end
    endfunction
    wire [16:0] h0=({9'd0,samples[0]}<<8)-mul8(samples[0],fx)+mul8(samples[1],fx)+128;
    wire [16:0] h1=({9'd0,samples[2]}<<8)-mul8(samples[2],fx)+mul8(samples[3],fx)+128;
    wire [16:0] v=({9'd0,horizontal0}<<8)-mul8(horizontal0,fy)+mul8(horizontal1,fy)+128;
    wire signed [31:0] low_x=$signed(origin_x)*32'sd65536;
    wire signed [31:0] low_y=$signed(origin_y)*32'sd65536;
    wire signed [31:0] high_x=low_x+((side-1)<<16);
    wire signed [31:0] high_y=low_y+((side-1)<<16);
    wire signed [31:0] cx=xq<low_x ? low_x : xq>high_x ? high_x : xq;
    wire signed [31:0] cy=yq<low_y ? low_y : yq>high_y ? high_y : yq;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            green_min<=255;green_max<=0;previous_green<=0;edge_count<=0;
            state<=IDLE;mode<=0;ox<=0;oy<=0;channel<=0;sample_index<=0;pixel<=0;
            xq<=0;yq<=0;xstart<=0;ystart<=0;step<=0;side<=0;origin_x<=0;origin_y<=0;
            x0<=0;x1<=0;y0<=0;y1<=0;fx<=0;fy<=0;byte_offset<=0;
            request_address<=0;store_red<=0;store_green<=0;store_blue<=0;store_address<=0;cache_valid<=0;
            cache_next<=0;pack_index<=0;done<=0;
            cache_address[0]<=0;cache_address[1]<=0;cache_address[2]<=0;cache_address[3]<=0;
            cache_data[0]<=0;cache_data[1]<=0;cache_data[2]<=0;cache_data[3]<=0;
            samples[0]<=0;samples[1]<=0;samples[2]<=0;samples[3]<=0;
            horizontal0<=0;horizontal1<=0;
        end else begin
            done<=0;
            case(state)
                IDLE:if(start) begin
                    green_min<=255;green_max<=0;previous_green<=0;edge_count<=0;
                    mode<=classifier;ox<=0;oy<=0;channel<=0;pack_index<=0;
                    store_red<=0;store_green<=0;store_blue<=0;store_address<=32'h00d00000;cache_valid<=0;cache_next<=0;
                    origin_x<=classifier ? roi_x : 0;origin_y<=classifier ? roi_y : 0;
                    side<=classifier ? roi_side : 1280;
                    step<=classifier ? ({16'd0,roi_side}<<16)/96 : 32'd655360;
                    xstart<=classifier ? ($signed(roi_x)*32'sd65536)+(({16'd0,roi_side}<<16)/192)-32768 : 32'd294912;
                    ystart<=classifier ? ($signed(roi_y)*32'sd65536)+(({16'd0,roi_side}<<16)/192)-32768 : 32'd294912;
                    xq<=classifier ? ($signed(roi_x)*32'sd65536)+(({16'd0,roi_side}<<16)/192)-32768 : 32'd294912;
                    yq<=classifier ? ($signed(roi_y)*32'sd65536)+(({16'd0,roi_side}<<16)/192)-32768 : 32'd294912;
                    state<=PIXEL;
                end
                PIXEL:begin
                    if(border) begin pixel<=fill;state<=NORM;end
                    else begin
                        x0<=cx>>>16;x1<=(cx>>>16)+(cx[15:0]!=0);
                        y0<=cy>>>16;y1<=(cy>>>16)+(cy[15:0]!=0);
                        fx<=cx[15:8];fy<=cy[15:8];sample_index<=0;state<=SAMPLE;
                    end
                end
                SAMPLE:begin
                    if(sample_out) begin
                        samples[sample_index]<=fill;
                        if(sample_index==3) state<=INTERP;else sample_index<=sample_index+1'b1;
                    end else if(|cache_hit) begin
                        samples[sample_index]<=cached_data[(15-sample_address[3:0])*8+:8];
                        if(sample_index==3) state<=INTERP;else sample_index<=sample_index+1'b1;
                    end else begin
                        request_address<={sample_address[31:4],4'd0};byte_offset<=sample_address[3:0];state<=REQUEST;
                    end
                end
                REQUEST:if(mem_ready) begin
                    if(mem_rsp_valid) begin
                        samples[sample_index]<=mem_rsp_data[(15-byte_offset)*8+:8];
                        cache_valid[cache_next]<=1;cache_address[cache_next]<=request_address;cache_data[cache_next]<=mem_rsp_data;cache_next<=cache_next+1'b1;
                        if(sample_index==3) state<=INTERP;else begin sample_index<=sample_index+1'b1;state<=SAMPLE;end
                    end else state<=RESPONSE;
                end
                RESPONSE:if(mem_rsp_valid) begin
                    samples[sample_index]<=mem_rsp_data[(15-byte_offset)*8+:8];
                    cache_valid[cache_next]<=1;cache_address[cache_next]<=request_address;cache_data[cache_next]<=mem_rsp_data;cache_next<=cache_next+1'b1;
                    if(sample_index==3) state<=INTERP;else begin sample_index<=sample_index+1'b1;state<=SAMPLE;end
                end
                INTERP:begin horizontal0<=h0[15:8];horizontal1<=h1[15:8];state<=VERTICAL;end
                VERTICAL:begin pixel<=v[15:8];state<=NORM;end
                NORM:begin
                    if(channel==1) begin
                        if(pixel<green_min) green_min<=pixel;
                        if(pixel>green_max) green_max<=pixel;
                        if(ox!=0 && green_delta>=12) edge_count<=edge_count+1'b1;
                        previous_green<=pixel;
                    end
                    state<=NORM_WAIT;
                end
                NORM_WAIT:state<=STORE;
                STORE:begin
                    case(channel)
                        0:store_red[pack_index*16+:16]<=normalized;
                        1:store_green[pack_index*16+:16]<=normalized;
                        2:store_blue[pack_index*16+:16]<=normalized;
                    endcase
                    if(pack_index==7) state<=WRITE;
                    else state<=NEXT;
                end
                WRITE:if(mem_ready) state<=NEXT;
                NEXT:begin
                    state<=PIXEL;
                    if(channel!=2) channel<=channel+1'b1;
                    else begin
                        channel<=0;
                        if(pack_index==7) begin pack_index<=0;store_address<=store_address+16;end
                        else pack_index<=pack_index+1'b1;
                        if(ox==width-1) begin
                            ox<=0;xq<=xstart;
                            if(oy==height-1) begin done<=1;state<=IDLE;end
                            else begin
                                oy<=oy+1'b1;
                                if(mode || (oy>=12 && oy<83)) yq<=yq+step;
                            end
                        end else begin ox<=ox+1'b1;xq<=xq+step;end
                    end
                end
            endcase
        end
    end
endmodule
