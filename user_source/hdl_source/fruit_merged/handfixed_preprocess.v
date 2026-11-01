// RGB128 classifier preprocessing, Q9 normalization ROM.
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
    // Background-only RGB sideband, before normalization.
    output wire rgb_valid,rgb_row_end,
    output wire [23:0] rgb_pixel,
    output wire busy,
    output reg done,
    output wire mem_valid,mem_write,
    output wire [31:0] mem_addr,
    output wire [127:0] mem_data,
    input wire mem_ready,mem_rsp_valid,
    input wire [127:0] mem_rsp_data
);
    localparam IDLE=0,PIXEL=1,SAMPLE=2,REQUEST=3,RESPONSE=4,INTERP=5,
        INTERP_H0=6,INTERP_H1=7,INTERP_V_SETUP=8,INTERP_V=9,
        NORM=10,NORM_WAIT=11,STORE=12,WRITE=13,NEXT=14,CACHE_GET=15,
        PACK_READ=16;
    reg [7:0] green_min,green_max,previous_green;
    reg [13:0] edge_count;
    assign texture_edges=edge_count;
    assign texture_range=green_max-green_min;
    assign has_texture=texture_range>=16 && edge_count>=24;
    reg [4:0] state;
    reg mode;
    reg [7:0] ox,oy;
    reg [1:0] channel,sample_index;
    reg [7:0] samples[0:3];
    reg [7:0] pixel;
    assign green_valid=state==NORM && channel==1 && mode;
    assign green_row_end=ox==127;
    assign green_pixel=pixel;
    reg [7:0] background_red,background_green;
    assign rgb_valid=state==NORM && channel==2 && mode;
    assign rgb_row_end=ox==127;
    assign rgb_pixel={background_red,background_green,pixel};
    wire [7:0] green_delta=pixel>=previous_green ? pixel-previous_green : previous_green-pixel;
    reg [7:0] horizontal0,horizontal1;
    reg signed [8:0] interp_delta;
    reg [7:0] interp_factor;
    wire signed [17:0] interp_product =
        interp_delta * $signed({1'b0,interp_factor});
    wire signed [18:0] interp_rounded =
        $signed({interp_product[17],interp_product}) + 19'sd128;
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
    reg [31:0] cache_address[0:3];
    reg [31:0] store_address;
    reg [3:0] cache_valid;
    reg [1:0] cache_next;
    reg [2:0] pack_index;
    wire [7:0] width=8'd128;
    wire [7:0] height=mode ? 8'd128 : 8'd96;
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
    wire [16:0] plane_offset=mode ? (channel==0 ? 16'd0 : channel==1 ? 17'd32768 : 17'd65536) :
                                                 (channel==0 ? 16'd0 : channel==1 ? 16'd24576 : 16'd49152);
    wire [3:0] cache_hit={cache_valid[3] && cache_address[3]=={sample_address[31:4],4'd0},
                          cache_valid[2] && cache_address[2]=={sample_address[31:4],4'd0},
                          cache_valid[1] && cache_address[1]=={sample_address[31:4],4'd0},
                          cache_valid[0] && cache_address[0]=={sample_address[31:4],4'd0}};
    wire [1:0] cache_hit_line=cache_hit[0] ? 2'd0 : cache_hit[1] ? 2'd1 :
                               cache_hit[2] ? 2'd2 : 2'd3;
    wire [7:0] cached_byte;
    wire cache_fill=(state==REQUEST || state==RESPONSE) && mem_rsp_valid;
    // Four DDR beats use block RAM to release distributed-memory sites near
    // the DDR bridge. NOREG bypasses the optional output stage; the memory
    // read itself remains synchronous, matching CACHE_GET's existing cycle.
    PH1P_LOGIC_ERAM #(
        .DATA_WIDTH_A(128),.DATA_WIDTH_B(8),
        .ADDR_WIDTH_A(2),.ADDR_WIDTH_B(6),
        .DATA_DEPTH_A(4),.DATA_DEPTH_B(64),
        .MODE("PDPW"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
        .WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),
        .IMPLEMENT("20K(FAST)"),.CLKMODE("SYNC"),
        .RESETMODE_B("ASYNC"),.OREGSET_B("RESET"),
        .ASYNC_RESET_RELEASE_B("ASYNC"),
        .ECC_ENCODE("DISABLE"),.ECC_DECODE("DISABLE"),
        .INIT_FILE("NONE"),.FILL_ALL("NONE")
    ) cache_memory(
        .clka(clk),.clkb(clk),.cea(cache_fill),.ceb(1'b1),
        .ocea(1'b0),.oceb(1'b0),.wea(cache_fill),.web(1'b0),
        .rsta(1'b0),.rstb(!rst_n),.bea(1'b0),.beb(1'b0),
        .addra(cache_next),.addrb({cache_hit_line,4'd15-sample_address[3:0]}),
        .dia(mem_rsp_data),.dib(8'd0),.doa(),.dob(cached_byte),
        .ecc_sbiterr(),.ecc_dbiterr(),.ecc_sbiterrinj(1'b0),.ecc_dbiterrinj(1'b0)
    );
    wire [127:0] store_word;
    // The three 128-bit DDR write beats are assembled from 24 normalized
    // samples. Asymmetric distributed RAM avoids 384 resettable flip-flops;
    // PACK_READ supplies the synchronous read cycle after the final sample.
    PH1P_LOGIC_DRAM #(
        .DATA_WIDTH_W(16),.DATA_WIDTH_R(128),
        .ADDR_WIDTH_W(5),.ADDR_WIDTH_R(2),
        .DATA_DEPTH_W(24),.DATA_DEPTH_R(3),
        .READREG("ENABLE"),.RESETMODE("ASYNC"),
        .INIT_FILE("NONE"),.FILL_ALL("NONE")
    ) store_memory(
        .di(normalized),.waddr({channel,pack_index}),.we(state==STORE),.wclk(clk),
        .raddr(channel),.rclk(clk),.rrst(!rst_n),.rce(1'b1),
        .rdo(),.rdoq(store_word)
    );
    handcnn_normalize norm_rom(.clk(clk),.address(norm_address),.value(normalized));
    assign busy=state!=IDLE;
    assign mem_valid=state==REQUEST || state==WRITE;
    assign mem_write=state==WRITE;
    assign mem_addr=mem_write ? store_address+plane_offset : request_address;
    assign mem_data=store_word;
    wire signed [31:0] low_x=$signed(origin_x)*32'sd65536;
    wire signed [31:0] low_y=$signed(origin_y)*32'sd65536;
    wire signed [31:0] high_x=low_x+((side-1)<<16);
    wire signed [31:0] high_y=low_y+((side-1)<<16);
    wire signed [31:0] cx=xq<low_x ? low_x : xq>high_x ? high_x : xq;
    wire signed [31:0] cy=yq<low_y ? low_y : yq>high_y ? high_y : yq;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            background_red<=0;background_green<=0;
            green_min<=255;green_max<=0;previous_green<=0;edge_count<=0;
            state<=IDLE;mode<=0;ox<=0;oy<=0;channel<=0;sample_index<=0;pixel<=0;
            xq<=0;yq<=0;xstart<=0;ystart<=0;step<=0;side<=0;origin_x<=0;origin_y<=0;
            x0<=0;x1<=0;y0<=0;y1<=0;fx<=0;fy<=0;byte_offset<=0;
            request_address<=0;store_address<=0;cache_valid<=0;
            cache_next<=0;pack_index<=0;done<=0;
            cache_address[0]<=0;cache_address[1]<=0;cache_address[2]<=0;cache_address[3]<=0;
            samples[0]<=0;samples[1]<=0;samples[2]<=0;samples[3]<=0;
            horizontal0<=0;horizontal1<=0;
            interp_delta<=0;interp_factor<=0;
        end else begin
            done<=0;
            case(state)
                IDLE:if(start) begin
                    green_min<=255;green_max<=0;previous_green<=0;edge_count<=0;
                    mode<=classifier;ox<=0;oy<=0;channel<=0;pack_index<=0;
                    store_address<=32'h00d00000;cache_valid<=0;cache_next<=0;
                    origin_x<=classifier ? roi_x : 0;origin_y<=classifier ? roi_y : 0;
                    side<=classifier ? roi_side : 1280;
                    step<=classifier ? ({16'd0,roi_side}<<16)/128 : 32'd655360;
                    xstart<=classifier ? ($signed(roi_x)*32'sd65536)+(({16'd0,roi_side}<<16)/256)-32768 : 32'd294912;
                    ystart<=classifier ? ($signed(roi_y)*32'sd65536)+(({16'd0,roi_side}<<16)/256)-32768 : 32'd294912;
                    xq<=classifier ? ($signed(roi_x)*32'sd65536)+(({16'd0,roi_side}<<16)/256)-32768 : 32'd294912;
                    yq<=classifier ? ($signed(roi_y)*32'sd65536)+(({16'd0,roi_side}<<16)/256)-32768 : 32'd294912;
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
                        state<=CACHE_GET;
                    end else begin
                        request_address<={sample_address[31:4],4'd0};byte_offset<=sample_address[3:0];state<=REQUEST;
                    end
                end
                REQUEST:if(mem_ready) begin
                    if(mem_rsp_valid) begin
                        samples[sample_index]<=mem_rsp_data[(15-byte_offset)*8+:8];
                        cache_valid[cache_next]<=1;cache_address[cache_next]<=request_address;cache_next<=cache_next+1'b1;
                        if(sample_index==3) state<=INTERP;else begin sample_index<=sample_index+1'b1;state<=SAMPLE;end
                    end else state<=RESPONSE;
                end
                RESPONSE:if(mem_rsp_valid) begin
                    samples[sample_index]<=mem_rsp_data[(15-byte_offset)*8+:8];
                    cache_valid[cache_next]<=1;cache_address[cache_next]<=request_address;cache_next<=cache_next+1'b1;
                    if(sample_index==3) state<=INTERP;else begin sample_index<=sample_index+1'b1;state<=SAMPLE;end
                end
                CACHE_GET:begin
                    samples[sample_index]<=cached_byte;
                    if(sample_index==3) state<=INTERP;
                    else begin sample_index<=sample_index+1'b1;state<=SAMPLE;end
                end
                INTERP:begin
                    interp_delta <= $signed({1'b0,samples[1]}) -
                                    $signed({1'b0,samples[0]});
                    interp_factor <= fx;
                    state <= INTERP_H0;
                end
                INTERP_H0:begin
                    horizontal0 <= $signed({1'b0,samples[0]}) +
                                   (interp_rounded >>> 8);
                    interp_delta <= $signed({1'b0,samples[3]}) -
                                    $signed({1'b0,samples[2]});
                    state <= INTERP_H1;
                end
                INTERP_H1:begin
                    horizontal1 <= $signed({1'b0,samples[2]}) +
                                   (interp_rounded >>> 8);
                    state <= INTERP_V_SETUP;
                end
                INTERP_V_SETUP:begin
                    interp_delta <= $signed({1'b0,horizontal1}) -
                                    $signed({1'b0,horizontal0});
                    interp_factor <= fy;
                    state <= INTERP_V;
                end
                INTERP_V:begin
                    pixel <= $signed({1'b0,horizontal0}) +
                             (interp_rounded >>> 8);
                    state <= NORM;
                end
                NORM:begin
                    if(channel==0) background_red<=pixel;
                    if(channel==1) background_green<=pixel;
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
                    if(pack_index==7) state<=PACK_READ;
                    else state<=NEXT;
                end
                PACK_READ:state<=WRITE;
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
