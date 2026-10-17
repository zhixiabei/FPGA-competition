// Four independent pixels/clock. Y -> Gaussian -> Scharr -> NMS -> threshold.
// LATENCY=11 clocks including bubbles; Scharr spatial shift=(3,3) pixels.
// The shared first window also produces emboss with spatial shift=(1,1).
// Cartoon has a separate low-bit RGB Gaussian path aligned to Scharr.
// Morphological gradient shares the raw-gray window with spatial shift=(1,1).
// No adaptive threshold, chroma gradient or Canny hysteresis in this version.
module scharr_edge_detect_96 #(
    parameter integer IMG_WIDTH=1280,
    parameter integer IMG_HEIGHT=720,
    parameter integer EDGE_TH=20,
    parameter integer GAUSSIAN_ENABLE=1
)(
    input I_clk,I_rst_n,I_tlast,I_tuser,
    input [95:0] I_tdata,input I_tvalid,I_tready,
    output reg O_tlast,O_tuser,output reg [95:0] O_tdata,
    output reg [95:0] O_emboss_data,
    output reg [95:0] O_cartoon_data,
    output reg [95:0] O_morph_data,
    output reg O_tvalid,output O_tready
);
    assign O_tready=I_tready; // The camera path does not support backpressure.
    function [7:0] luminance;
        input [23:0] rgb;
        reg [9:0] sum;
        begin
            sum={2'd0,rgb[23:16]}+({2'd0,rgb[15:8]}<<1)+{2'd0,rgb[7:0]};
            luminance=sum[9:2];
        end
    endfunction
    wire [31:0] gray={
        luminance(I_tdata[95:72]),luminance(I_tdata[71:48]),
        luminance(I_tdata[47:24]),luminance(I_tdata[23:0])};
    wire gv,gu,gl;
    wire [287:0] gw;
    scharr_window_4 #(.DATA_WIDTH(8),.IMG_WIDTH(IMG_WIDTH),.IMG_HEIGHT(IMG_HEIGHT),
        .TRACK_POSITION(0))
    u_gaussian_window(
        .clk(I_clk),.rst_n(I_rst_n),.valid(I_tvalid),.user(I_tuser),.last(I_tlast),
        .word(gray),.out_valid(gv),.out_user(gu),.out_last(gl),.ok(),
        .windows(gw),.out_x(),.out_y());

    function [7:0] gaussian;
        input [71:0] w;
        reg [9:0] left,middle,right;
        reg [11:0] sum;
        begin
            // Filter columns first: neighbouring lanes share these sums.
            left={2'd0,w[71:64]}+({2'd0,w[47:40]}<<1)+{2'd0,w[23:16]};
            middle={2'd0,w[63:56]}+({2'd0,w[39:32]}<<1)+{2'd0,w[15:8]};
            right={2'd0,w[55:48]}+({2'd0,w[31:24]}<<1)+{2'd0,w[7:0]};
            sum={2'd0,left}+({2'd0,middle}<<1)+{2'd0,right};
            gaussian=GAUSSIAN_ENABLE ? sum[11:4] : w[39:32];
        end
    endfunction
    reg pv,pu,pl;
    reg [31:0] filtered;
    integer lane;
    // Intermediate pixels outside the valid neighbourhood are discarded by
    // the final six-row/column border mask. Do not clear wide, overlapping
    // windows on every bubble. Data/control use the same reset for packing.
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin pv<=0;pu<=0;pl<=0;end
        else begin pv<=gv;pu<=gu;pl<=gl;end
    end
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) filtered<=0;
        else for(lane=0;lane<4;lane=lane+1)
            filtered[31-lane*8 -:8]<=gaussian(gw[287-lane*72 -:72]);
    end
    function [7:0] emboss;
        input [71:0] w;
        reg signed [8:0] difference;
        reg signed [10:0] level;
        begin
            difference=$signed({1'b0,w[39:32]})-$signed({1'b0,w[71:64]});
            level=11'sd128+($signed({{2{difference[8]}},difference})<<<1);
            if(level<11'sd0) emboss=8'd0;
            else if(level>11'sd255) emboss=8'd255;
            else emboss=level[7:0];
        end
    endfunction
    // Compute at clock three, then share the final Scharr coordinate mask at
    // clock eleven. Store only four grayscale bytes until the RGB output.
    reg [31:0] emboss_pipe[0:7];
    integer emboss_stage;
    always @(posedge I_clk) begin
        for(emboss_stage=0;emboss_stage<4;emboss_stage=emboss_stage+1)
            emboss_pipe[0][31-emboss_stage*8 -:8]<=
                emboss(gw[287-emboss_stage*72 -:72]);
        for(emboss_stage=1;emboss_stage<8;emboss_stage=emboss_stage+1)
            emboss_pipe[emboss_stage]<=emboss_pipe[emboss_stage-1];
    end

    function [7:0] minimum3;
        input [7:0] a,b,c;
        reg [7:0] ab;
        begin
            ab=a<b ? a : b;
            minimum3=ab<c ? ab : c;
        end
    endfunction
    function [7:0] maximum3;
        input [7:0] a,b,c;
        reg [7:0] ab;
        begin
            ab=a>b ? a : b;
            maximum3=ab>c ? ab : c;
        end
    endfunction
    function [7:0] morphology_level;
        input [7:0] maximum,minimum;
        reg [7:0] difference;
        begin
            difference=maximum-minimum;
            morphology_level=|difference[7:6] ? 8'hff : {difference[5:0],2'b00};
        end
    endfunction
    // Separate horizontal/vertical extrema at clocks three/four. The gradient
    // is reduced to four bytes at clock five and reaches the output at eleven.
    reg [95:0] morph_row_min,morph_row_max;
    reg [31:0] morph_min,morph_max;
    reg [31:0] morph_pipe[0:5];
    integer morph_lane,morph_row,morph_stage;
    always @(posedge I_clk) begin
        for(morph_lane=0;morph_lane<4;morph_lane=morph_lane+1) begin
            for(morph_row=0;morph_row<3;morph_row=morph_row+1) begin
                morph_row_min[95-morph_lane*24-morph_row*8 -:8]<=minimum3(
                    gw[287-morph_lane*72-morph_row*24 -:8],
                    gw[279-morph_lane*72-morph_row*24 -:8],
                    gw[271-morph_lane*72-morph_row*24 -:8]);
                morph_row_max[95-morph_lane*24-morph_row*8 -:8]<=maximum3(
                    gw[287-morph_lane*72-morph_row*24 -:8],
                    gw[279-morph_lane*72-morph_row*24 -:8],
                    gw[271-morph_lane*72-morph_row*24 -:8]);
            end
            morph_min[31-morph_lane*8 -:8]<=minimum3(
                morph_row_min[95-morph_lane*24 -:8],
                morph_row_min[87-morph_lane*24 -:8],
                morph_row_min[79-morph_lane*24 -:8]);
            morph_max[31-morph_lane*8 -:8]<=maximum3(
                morph_row_max[95-morph_lane*24 -:8],
                morph_row_max[87-morph_lane*24 -:8],
                morph_row_max[79-morph_lane*24 -:8]);
            morph_pipe[0][31-morph_lane*8 -:8]<=morphology_level(
                morph_max[31-morph_lane*8 -:8],
                morph_min[31-morph_lane*8 -:8]);
        end
        for(morph_stage=1;morph_stage<6;morph_stage=morph_stage+1)
            morph_pipe[morph_stage]<=morph_pipe[morph_stage-1];
    end

    wire sv,su,sl;
    wire [287:0] sw;
    scharr_window_4 #(.DATA_WIDTH(8),.IMG_WIDTH(IMG_WIDTH),.IMG_HEIGHT(IMG_HEIGHT),
        .TRACK_POSITION(0))
    u_scharr_window(
        .clk(I_clk),.rst_n(I_rst_n),.valid(pv),.user(pu),.last(pl),.word(filtered),
        .out_valid(sv),.out_user(su),.out_last(sl),.ok(),
        .windows(sw),.out_x(),.out_y());

    // 3*(corner differences) + 10*(middle difference), with explicit widths.
    function [25:0] scharr;
        input [71:0] w;
        reg signed [8:0] diagonal_a,diagonal_b;
        reg signed [12:0] xouter,xmiddle,youter,ymiddle,gx,gy;
        begin
            // Share the two diagonal differences between Gx and Gy.
            diagonal_a=$signed({1'b0,w[7:0]})-$signed({1'b0,w[71:64]});
            diagonal_b=$signed({1'b0,w[55:48]})-$signed({1'b0,w[23:16]});
            xouter={{4{diagonal_a[8]}},diagonal_a}+
                   {{4{diagonal_b[8]}},diagonal_b};
            xmiddle=$signed({5'd0,w[31:24]})-$signed({5'd0,w[47:40]});
            youter={{4{diagonal_a[8]}},diagonal_a}-
                   {{4{diagonal_b[8]}},diagonal_b};
            ymiddle=$signed({5'd0,w[15:8]})-$signed({5'd0,w[63:56]});
            gx=((xouter<<<1)+xouter)+((xmiddle<<<3)+(xmiddle<<<1));
            gy=((youter<<<1)+youter)+((ymiddle<<<3)+(ymiddle<<<1));
            scharr={gx,gy};
        end
    endfunction
    function [25:0] absolute_gradient;
        input [25:0] g;
        reg signed [12:0] gx,gy;
        reg [12:0] ax,ay;
        begin
            gx=$signed(g[25:13]);gy=$signed(g[12:0]);
            ax=gx[12] ? -gx : gx;ay=gy[12] ? -gy : gy;
            // Each derivative lies in [-4080,4080].
            absolute_gradient={gx[12],ax[11:0],gy[12],ay[11:0]};
        end
    endfunction
    function [14:0] magnitude_direction;
        input [25:0] g;
        reg [11:0] ax,ay;
        reg [19:0] ax106,ay106;
        reg [12:0] magnitude;
        reg [1:0] direction;
        begin
            ax=g[24:13];ay=g[11:0];
            // 106/256 approximates tan(22.5 degrees), without division.
            ax106=({8'd0,ax}<<6)+({8'd0,ax}<<5)+
                  ({8'd0,ax}<<3)+({8'd0,ax}<<1);
            ay106=({8'd0,ay}<<6)+({8'd0,ay}<<5)+
                  ({8'd0,ay}<<3)+({8'd0,ay}<<1);
            if({ay,8'd0}<=ax106) direction=0;
            else if({ax,8'd0}<=ay106) direction=2;
            else direction=(g[25]==g[12]) ? 1 : 3;
            magnitude={1'b0,ax}+{1'b0,ay};
            magnitude_direction={magnitude,direction};
        end
    endfunction
    reg [103:0] gradients,abs_gradients;
    reg [59:0] magnitude_word;
    reg [2:0] vp,up,lp;
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin vp<=0;up<=0;lp<=0;end
        else begin
            vp<={vp[1:0],sv};up<={up[1:0],su};lp<={lp[1:0],sl};
        end
    end
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin gradients<=0;abs_gradients<=0;magnitude_word<=0;end
        else for(lane=0;lane<4;lane=lane+1) begin
            gradients[103-lane*26 -:26]<=scharr(sw[287-lane*72 -:72]);
            abs_gradients[103-lane*26 -:26]<=
                absolute_gradient(gradients[103-lane*26 -:26]);
            magnitude_word[59-lane*15 -:15]<=
                magnitude_direction(abs_gradients[103-lane*26 -:26]);
        end
    end

    wire nv,nu,nl;
    wire [3:0] nok;
    wire [539:0] nw;
    wire [10:0] nx,ny;
    scharr_window_4 #(.DATA_WIDTH(15),.IMG_WIDTH(IMG_WIDTH),.IMG_HEIGHT(IMG_HEIGHT))
    u_nms_window(
        .clk(I_clk),.rst_n(I_rst_n),.valid(vp[2]),.user(up[2]),.last(lp[2]),
        .word(magnitude_word),.out_valid(nv),.out_user(nu),.out_last(nl),
        .ok(nok),.windows(nw),.out_x(nx),.out_y(ny));

    wire [59:0] cartoon_rgb5={
        I_tdata[95:91],I_tdata[87:83],I_tdata[79:75],
        I_tdata[71:67],I_tdata[63:59],I_tdata[55:51],
        I_tdata[47:43],I_tdata[39:35],I_tdata[31:27],
        I_tdata[23:19],I_tdata[15:11],I_tdata[7:3]};
    wire [539:0] cartoon_rgb_window;
    scharr_window_4 #(.DATA_WIDTH(15),.IMG_WIDTH(IMG_WIDTH),
        .IMG_HEIGHT(IMG_HEIGHT),.TRACK_POSITION(0))
    u_cartoon_gaussian_window(
        .clk(I_clk),.rst_n(I_rst_n),.valid(I_tvalid),.user(I_tuser),.last(I_tlast),
        .word(cartoon_rgb5),.out_valid(),.out_user(),.out_last(),.ok(),
        .windows(cartoon_rgb_window),.out_x(),.out_y());
    function [2:0] cartoon_channel;
        input [134:0] w;
        input integer channel;
        reg [6:0] left,middle,right;
        reg [8:0] sum;
        begin
            left={2'd0,w[134-channel*5 -:5]}+
                 ({2'd0,w[89-channel*5 -:5]}<<1)+
                 {2'd0,w[44-channel*5 -:5]};
            middle={2'd0,w[119-channel*5 -:5]}+
                   ({2'd0,w[74-channel*5 -:5]}<<1)+
                   {2'd0,w[29-channel*5 -:5]};
            right={2'd0,w[104-channel*5 -:5]}+
                  ({2'd0,w[59-channel*5 -:5]}<<1)+
                  {2'd0,w[14-channel*5 -:5]};
            sum={2'd0,left}+({2'd0,middle}<<1)+{2'd0,right};
            // /16 Gaussian normalisation, then /4 gives eight levels/channel.
            cartoon_channel=sum[8:6];
        end
    endfunction
    reg [35:0] cartoon_quantized;
    integer cartoon_lane;
    always @(posedge I_clk) begin
        for(cartoon_lane=0;cartoon_lane<4;cartoon_lane=cartoon_lane+1)
            cartoon_quantized[35-cartoon_lane*9 -:9]<={
                cartoon_channel(cartoon_rgb_window[539-cartoon_lane*135 -:135],0),
                cartoon_channel(cartoon_rgb_window[539-cartoon_lane*135 -:135],1),
                cartoon_channel(cartoon_rgb_window[539-cartoon_lane*135 -:135],2)};
    end
    // Centre taps add one row/column each. Together with the Gaussian centre,
    // the color now represents the same (+3,+3) position as the NMS contour.
    wire [323:0] cartoon_center_window;
    scharr_window_4 #(.DATA_WIDTH(9),.IMG_WIDTH(IMG_WIDTH),
        .IMG_HEIGHT(IMG_HEIGHT),.TRACK_POSITION(0))
    u_cartoon_center_window(
        .clk(I_clk),.rst_n(I_rst_n),.valid(pv),.user(pu),.last(pl),
        .word(cartoon_quantized),.out_valid(),.out_user(),.out_last(),.ok(),
        .windows(cartoon_center_window),.out_x(),.out_y());
    reg [35:0] cartoon_delay[0:2];
    integer cartoon_stage;
    always @(posedge I_clk) begin
        for(cartoon_lane=0;cartoon_lane<4;cartoon_lane=cartoon_lane+1)
            cartoon_delay[0][35-cartoon_lane*9 -:9]<=
                cartoon_center_window[287-cartoon_lane*81 -:9];
        for(cartoon_stage=1;cartoon_stage<3;cartoon_stage=cartoon_stage+1)
            cartoon_delay[cartoon_stage]<=cartoon_delay[cartoon_stage-1];
    end
    wire [323:0] cartoon_final_window;
    scharr_window_4 #(.DATA_WIDTH(9),.IMG_WIDTH(IMG_WIDTH),
        .IMG_HEIGHT(IMG_HEIGHT),.TRACK_POSITION(0))
    u_cartoon_final_window(
        .clk(I_clk),.rst_n(I_rst_n),.valid(vp[2]),.user(up[2]),.last(lp[2]),
        .word(cartoon_delay[2]),.out_valid(),.out_user(),.out_last(),.ok(),
        .windows(cartoon_final_window),.out_x(),.out_y());
    function [23:0] cartoon_expand;
        input [8:0] rgb;
        begin
            cartoon_expand={
                rgb[8:6],rgb[8:6],rgb[8:7],
                rgb[5:3],rgb[5:3],rgb[5:4],
                rgb[2:0],rgb[2:0],rgb[2:1]};
        end
    endfunction
    wire [3:0] edge_present;
    genvar edge_lane;
    generate for(edge_lane=0;edge_lane<4;edge_lane=edge_lane+1) begin: g_edge_present
        assign edge_present[3-edge_lane]=nms(nw[539-edge_lane*135 -:135]);
    end endgenerate
    function nms;
        input [134:0] w;
        reg [12:0] m,a,b;
        reg [1:0] direction;
        begin
            m=w[74:62];direction=w[61:60];
            case(direction)
                0:begin a=w[89:77];b=w[59:47];end
                1:begin a=w[134:122];b=w[14:2];end
                2:begin a=w[119:107];b=w[29:17];end
                default:begin a=w[104:92];b=w[44:32];end
            endcase
            // Compare unrounded magnitudes; normalise only the threshold.
            // Asymmetric ties select one side of a flat two-pixel ridge.
            nms=(m>a)&&(m>=b)&&(m>=EDGE_TH*16);
        end
    endfunction
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            O_tvalid<=0;O_tuser<=0;O_tlast<=0;O_tdata<=0;O_emboss_data<=0;
            O_cartoon_data<=0;O_morph_data<=0;
        end
        else begin
            O_tvalid<=nv;O_tuser<=nu;O_tlast<=nl;
            for(lane=0;lane<4;lane=lane+1) begin
                O_tdata[95-lane*24 -:24]<=nv&&nok[3-lane]&&
                    ny>=6&&((nx<<2)+lane>=6)&&
                    edge_present[3-lane] ? 24'hffffff : 24'd0;
                O_emboss_data[95-lane*24 -:24]<=!nv ? 24'd0 :
                    ny>=2&&((nx<<2)+lane>=2) ?
                    {3{emboss_pipe[7][31-lane*8 -:8]}} : 24'h808080;
                O_cartoon_data[95-lane*24 -:24]<=nv&&nok[3-lane]&&
                    ny>=6&&((nx<<2)+lane>=6)&&!edge_present[3-lane] ?
                    cartoon_expand(cartoon_final_window[287-lane*81 -:9]) : 24'd0;
                O_morph_data[95-lane*24 -:24]<=nv&&ny>=2&&((nx<<2)+lane>=2) ?
                    {3{morph_pipe[5][31-lane*8 -:8]}} : 24'd0;
            end
        end
    end
endmodule

// Row-major 3x3 windows, lane 0 in the most significant bits. Two clocks.
// SOF is accepted even before valid; addresses advance only on valid.
// Two row parities share a true dual-port ERAM. A reads y-2 before writing y;
// B reads y-1 at the opposite parity, so the ports never collide.
// Use ERAM output registers for the second clock, saving fabric registers.
// The first two callers need only row parity; the final caller tracks position.
module scharr_window_4 #(
    parameter integer DATA_WIDTH=8,IMG_WIDTH=1280,IMG_HEIGHT=720,TRACK_POSITION=1
)(
    input clk,rst_n,valid,user,last,input [4*DATA_WIDTH-1:0] word,
    output reg out_valid,out_user,out_last,output reg [3:0] ok,
    output wire [36*DATA_WIDTH-1:0] windows,
    output reg [10:0] out_x,out_y
);
    function integer address_width;
        input integer depth;integer n;
        begin
            address_width=0;
            for(n=depth-1;n>0;n=n>>1) address_width=address_width+1;
            if(address_width<1) address_width=1;
        end
    endfunction
    localparam integer GROUPS=IMG_WIDTH/4;
    localparam integer A=address_width(GROUPS),B=4*DATA_WIDTH;
    localparam integer DEPTH=1<<(A+1);
    reg [10:0] x,y,xd,yd;
    wire [10:0] rx=user?11'd0:x,ry=user?11'd0:y;
    wire [A:0] current_address={ry[0],rx[A-1:0]};
    wire [A:0] previous_address={!ry[0],rx[A-1:0]};
    wire enable=rst_n&&valid;
    wire [B-1:0] top,middle;
    reg vd,ud,ld;
`ifdef SCHARR_PORTABLE_RAM
    reg [B-1:0] rows[0:DEPTH-1];
    reg [B-1:0] top_read,middle_read;
    reg [B-1:0] top_output,middle_output;
    always @(posedge clk) if(enable) begin
        top_read<=rows[current_address];
        middle_read<=rows[previous_address];
        rows[current_address]<=word;
    end
    always @(posedge clk) if(vd) begin
        top_output<=top_read;
        middle_output<=middle_read;
    end
    assign top=top_output;
    assign middle=middle_output;
`else
    PH1P_LOGIC_ERAM #(
        .DATA_WIDTH_A(B),.DATA_WIDTH_B(B),.ADDR_WIDTH_A(A+1),.ADDR_WIDTH_B(A+1),
        .DATA_DEPTH_A(DEPTH),.DATA_DEPTH_B(DEPTH),.MODE("DP"),
        .REGMODE_A("OUTREG"),.REGMODE_B("OUTREG"),
        .WRITEMODE_A("READBEFOREWRITE"),.WRITEMODE_B("NORMAL"),
        .IMPLEMENT("20K(FAST)"),.CLKMODE("SYNC"),
        .ECC_ENCODE("DISABLE"),.ECC_DECODE("DISABLE"),
        .INIT_FILE("NONE"),.FILL_ALL("NONE")
    ) u_rows(
        .clka(clk),.clkb(clk),.cea(enable),.ceb(enable),
        .ocea(vd),.oceb(vd),.wea(enable),.web(1'b0),
        .rsta(1'b0),.rstb(1'b0),.bea(1'b0),.beb(1'b0),
        .addra(current_address),.addrb(previous_address),.dia(word),.dib({B{1'b0}}),
        .doa(top),.dob(middle),.ecc_sbiterr(),.ecc_dbiterr(),
        .ecc_sbiterrinj(1'b0),.ecc_dbiterrinj(1'b0));
`endif
    reg [B-1:0] bottom,bottom_output;
    reg [2*DATA_WIDTH-1:0] top_tail,middle_tail,bottom_tail;
    function [3*DATA_WIDTH-1:0] row;
        input [B-1:0] pixels;
        input [2*DATA_WIDTH-1:0] previous;
        input integer index;
        begin
            case(index)
                0:row={previous,pixels[B-1 -:DATA_WIDTH]};
                1:row={previous[DATA_WIDTH-1:0],pixels[B-1 -:2*DATA_WIDTH]};
                2:row=pixels[B-1 -:3*DATA_WIDTH];
                default:row=pixels[3*DATA_WIDTH-1:0];
            endcase
        end
    endfunction
    integer k;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            x<=0;y<=0;xd<=0;yd<=0;vd<=0;ud<=0;ld<=0;bottom<=0;
            bottom_output<=0;
            out_valid<=0;out_user<=0;out_last<=0;ok<=0;
            out_x<=0;out_y<=0;top_tail<=0;middle_tail<=0;bottom_tail<=0;
        end else begin
            vd<=valid;ud<=user;ld<=last;
            if(user) begin x<=0;y<=0;end
            if(valid) begin
                xd<=rx;yd<=ry;bottom<=word;
                if(rx==GROUPS-1) begin
                    x<=0;
                    // With no coordinate consumer, natural row parity is
                    // sufficient, including odd-height frames (SOF resets it).
                    if(TRACK_POSITION) y<=ry==IMG_HEIGHT-1?11'd0:ry+1'b1;
                    else y<={10'd0,!ry[0]};
                end
                else begin x<=rx+1'b1;y<=ry;end
            end
            out_valid<=vd;out_user<=ud;out_last<=ld;ok<=0;
            if(vd) begin
                out_x<=xd;out_y<=yd;
                bottom_output<=bottom;
                // These capture the OLD registered RAM outputs while the
                // RAM outputs advance to the current group at this edge.
                top_tail<=top[2*DATA_WIDTH-1:0];
                middle_tail<=middle[2*DATA_WIDTH-1:0];
                bottom_tail<=bottom_output[2*DATA_WIDTH-1:0];
                for(k=0;k<4;k=k+1) if(yd>=2&&(xd!=0||k>=2))
                    ok[3-k]<=1'b1;
            end
        end
    end
    // Row-start tails are intentionally unspecified; the final six-column
    // border mask excludes all windows that would consume a previous row.
    genvar sample_lane;
    generate for(sample_lane=0;sample_lane<4;sample_lane=sample_lane+1) begin: g_window
        assign windows[36*DATA_WIDTH-1-sample_lane*9*DATA_WIDTH -:9*DATA_WIDTH]=
            {row(top,top_tail,sample_lane),row(middle,middle_tail,sample_lane),
             row(bottom_output,bottom_tail,sample_lane)};
    end endgenerate
endmodule
