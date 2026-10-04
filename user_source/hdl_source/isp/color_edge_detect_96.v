// Streaming color-vector edge detector, four RGB888 pixels per clock.
//
// Hardware simplifications of the paper's second method:
//   adjacent-pixel averaging + Sobel's orthogonal 1:2:1 smoothing replace VTV;
//   signed (Y,R-G,B-G) integer components replace nonlinear CIE Lab;
//   dominant-component orientation replaces a color structure-tensor angle;
//   four-direction neighbour-gradient NMS is followed by dual thresholds;
//   weak NMS edges survive only next to a STRONG NMS edge in a 3x3 window.
// The last step is ONE local pass, not global iterative Canny hysteresis.
//
// LATENCY is 11 registered clocks; markers advance even during valid bubbles.
// There are two samples per beat, each replicated into two output pixels.
// Three causal 3x3 windows move the displayed contour right by 3 samples
// (6 original pixels) and down by 3 rows relative to the source RGB image.
// Full-support output is masked for endpoint x<6 samples or y<6 rows.
// Line memories have synchronous read ports and no reset/clear loop.
// This is the existing non-stallable camera stream: ready is informational.
module color_edge_detect_96 #(
    parameter integer IMG_WIDTH = 1280,
    parameter integer IMG_HEIGHT = 720,
    // Magnitudes below are divided by four. For an achromatic axis-aligned
    // edge, 20 here corresponds to the old unscaled Sobel threshold of 80.
    parameter integer EDGE_TH = 20,
    parameter integer LOW_TH = EDGE_TH / 2
)(
    input I_clk, input I_rst_n,
    input I_tlast, input I_tuser,
    input [95:0] I_tdata,
    input I_tvalid, input I_tready,
    output reg O_tlast, output reg O_tuser,
    output reg [95:0] O_tdata,
    output reg O_tvalid, output O_tready
);
    localparam integer LATENCY = 11;
    assign O_tready = I_tready;

    // 8-bit luminance and signed 9-bit chroma; adjacent averaging is the
    // first, low-cost noise filter and horizontal decimator.
    function [25:0] pair_vector;
        input [23:0] p, q;
        reg [9:0] yp, yq;
        reg [8:0] ysum;
        reg signed [8:0] cp1, cq1, cp2, cq2;
        reg signed [9:0] csum1, csum2;
        reg signed [8:0] cavg1, cavg2;
        begin
            yp = {2'b0,p[23:16]} + ({2'b0,p[15:8]} << 1) + {2'b0,p[7:0]};
            yq = {2'b0,q[23:16]} + ({2'b0,q[15:8]} << 1) + {2'b0,q[7:0]};
            ysum = {1'b0,yp[9:2]} + {1'b0,yq[9:2]};
            cp1 = $signed({1'b0,p[23:16]}) - $signed({1'b0,p[15:8]});
            cq1 = $signed({1'b0,q[23:16]}) - $signed({1'b0,q[15:8]});
            cp2 = $signed({1'b0,p[7:0]}) - $signed({1'b0,p[15:8]});
            cq2 = $signed({1'b0,q[7:0]}) - $signed({1'b0,q[15:8]});
            csum1 = $signed({cp1[8],cp1}) + $signed({cq1[8],cq1});
            csum2 = $signed({cp2[8],cp2}) + $signed({cq2[8],cq2});
            cavg1 = csum1 >>> 1;
            cavg2 = csum2 >>> 1;
            pair_vector = {ysum[8:1],cavg1,cavg2};
        end
    endfunction

    wire [51:0] vectors = {pair_vector(I_tdata[95:72],I_tdata[71:48]),
                           pair_vector(I_tdata[47:24],I_tdata[23:0])};
    wire cv_valid, cv_user, cv_last, cv_ok;
    wire [10:0] cv_x, cv_y;
    wire [233:0] cv_w0, cv_w1;
    color_edge_window_2 #(.DATA_WIDTH(26),.IMG_WIDTH(IMG_WIDTH),.IMG_HEIGHT(IMG_HEIGHT))
      u_vector_window (
        .I_clk(I_clk),.I_rst_n(I_rst_n),.I_valid(I_tvalid),
        .I_user(I_tuser),.I_last(I_tlast),.I_word(vectors),
        .O_valid(cv_valid),.O_user(cv_user),.O_last(cv_last),
        .O_ok(cv_ok),.O_x(cv_x),.O_y(cv_y),.O_w0(cv_w0),.O_w1(cv_w1)
    );

    function signed [12:0] component;
        input [25:0] p;
        input integer k;
        begin
            case(k)
                0: component = $signed({5'b0,p[25:18]});
                1: component = $signed({{4{p[17]}},p[17:9]});
                default: component = $signed({{4{p[8]}},p[8:0]});
            endcase
        end
    endfunction

    // Retain SIGNS of derivatives. Absolute color distances alone lose the
    // distinction between the two diagonal NMS directions.
    function [77:0] vector_gradient;
        input [233:0] w;
        reg signed [12:0] a00,a01,a02,a10,a12,a20,a21,a22;
        reg signed [12:0] gx,gy;
        integer k;
        begin
            vector_gradient = 78'd0;
            for(k=0;k<3;k=k+1) begin
                a00=component(w[233:208],k); a01=component(w[207:182],k);
                a02=component(w[181:156],k); a10=component(w[155:130],k);
                a12=component(w[103:78],k); a20=component(w[77:52],k);
                a21=component(w[51:26],k); a22=component(w[25:0],k);
                gx=(a02-a00)+((a12-a10) <<< 1)+(a22-a20);
                gy=(a20-a00)+((a21-a01) <<< 1)+(a22-a02);
                vector_gradient[77-k*26 -: 26]={gx,gy};
            end
        end
    endfunction

    reg [77:0] grad0,grad1;
    reg grad_valid,grad_user,grad_last;
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            grad0<=0; grad1<=0; grad_valid<=0; grad_user<=0; grad_last<=0;
        end else begin
            grad_valid<=cv_valid; grad_user<=cv_user; grad_last<=cv_last;
            grad0 <= (cv_valid && cv_ok) ? vector_gradient(cv_w0) : 78'd0;
            grad1 <= (cv_valid && cv_ok) ? vector_gradient(cv_w1) : 78'd0;
        end
    end

    function [12:0] abs13;
        input signed [12:0] n;
        begin abs13 = n[12] ? -n : n; end
    endfunction

    // Separate absolute-value carry chains from orientation/magnitude logic.
    // Each component stores {x_sign,abs_x[12:0],y_sign,abs_y[12:0]}.
    function [83:0] absolute_gradient;
        input [77:0] g;
        integer k;
        reg signed [12:0] gx,gy;
        begin
            for(k=0;k<3;k=k+1) begin
                gx=$signed(g[77-k*26 -: 13]);
                gy=$signed(g[64-k*26 -: 13]);
                absolute_gradient[83-k*28 -: 28]={gx[12],abs13(gx),gy[12],abs13(gy)};
            end
        end
    endfunction

    reg [83:0] abs_grad0,abs_grad1;
    reg abs_valid,abs_user,abs_last;
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            abs_grad0<=0; abs_grad1<=0; abs_valid<=0; abs_user<=0; abs_last<=0;
        end else begin
            abs_valid<=grad_valid; abs_user<=grad_user; abs_last<=grad_last;
            abs_grad0<=grad_valid ? absolute_gradient(grad0) : 84'd0;
            abs_grad1<=grad_valid ? absolute_gradient(grad1) : 84'd0;
        end
    end

    function [1:0] component_direction;
        input [12:0] ax,ay;
        input xs,ys;
        begin
            if({1'b0,ax} >= ({1'b0,ay} << 1)) component_direction=2'd0;
            else if({1'b0,ay} >= ({1'b0,ax} << 1)) component_direction=2'd2;
            else component_direction=(xs==ys) ? 2'd1 : 2'd3;
        end
    endfunction

    // Packed result: {magnitude[11:0], direction[1:0]}. Directions describe
    // the gradient, not the contour tangent: 0=E/W,1=NW/SE,2=N/S,3=NE/SW.
    function [13:0] magnitude_direction;
        input [83:0] g;
        reg [12:0] ax0,ay0,ax1,ay1,ax2,ay2;
        reg [13:0] norm0,norm1,norm2,cx,cy,mx,my;
        reg [14:0] chroma_x,chroma_y,total;
        reg [1:0] dir,dir0,dir1,dir2;
        begin
            ax0=g[82:70]; ay0=g[68:56]; ax1=g[54:42]; ay1=g[40:28];
            ax2=g[26:14]; ay2=g[12:0];
            norm0={1'b0,ax0}+{1'b0,ay0};
            norm1=({1'b0,ax1}+{1'b0,ay1}) >> 1;
            norm2=({1'b0,ax2}+{1'b0,ay2}) >> 1;
            // Compute the three orientations in parallel, then select the
            // dominant one. This avoids a wide derivative mux before angle
            // comparisons and preserves the previous tie/weight rules.
            dir0=component_direction(ax0,ay0,g[83],g[69]);
            dir1=component_direction(ax1,ay1,g[55],g[41]);
            dir2=component_direction(ax2,ay2,g[27],g[13]);
            dir=dir0;
            if(norm1>norm0 && norm1>=norm2) dir=dir1;
            else if(norm2>norm0 && norm2>norm1) dir=dir2;
            chroma_x={2'b0,ax1}+{2'b0,ax2};
            chroma_y={2'b0,ay1}+{2'b0,ay2};
            cx={1'b0,ax0}+(chroma_x >> 1);
            cy={1'b0,ay0}+(chroma_y >> 1);
            mx=(cx>=cy)?cx:cy; my=(cx>=cy)?cy:cx;
            total={1'b0,mx}+({1'b0,my} >> 1);
            // Normalise the 1:2:1 spatial weighting, so thresholds retain
            // a useful 8-bit-ish range despite the larger vector magnitude.
            magnitude_direction={total[13:2],dir};
        end
    endfunction

    reg [27:0] md_word;
    reg md_valid,md_user,md_last;
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin md_word<=0; md_valid<=0; md_user<=0; md_last<=0; end
        else begin
            md_valid<=abs_valid; md_user<=abs_user; md_last<=abs_last;
            md_word<=abs_valid ? {magnitude_direction(abs_grad0),magnitude_direction(abs_grad1)} : 28'd0;
        end
    end

    wire nm_valid,nm_user,nm_last,nm_ok;
    wire [10:0] nm_x,nm_y;
    wire [125:0] nm_w0,nm_w1;
    color_edge_window_2 #(.DATA_WIDTH(14),.IMG_WIDTH(IMG_WIDTH),.IMG_HEIGHT(IMG_HEIGHT))
      u_magnitude_window (
        .I_clk(I_clk),.I_rst_n(I_rst_n),.I_valid(md_valid),
        .I_user(md_user),.I_last(md_last),.I_word(md_word),
        .O_valid(nm_valid),.O_user(nm_user),.O_last(nm_last),
        .O_ok(nm_ok),.O_x(nm_x),.O_y(nm_y),.O_w0(nm_w0),.O_w1(nm_w1)
    );

    // TRUE neighbour-gradient NMS: compare the centre's gradient magnitude
    // with the two neighbouring gradient magnitudes along its direction.
    // Use an asymmetric tie rule to reduce a flat two-sample ridge to one.
    function [1:0] nms_class;
        input [125:0] w;
        reg [11:0] m,n0,n1;
        reg [1:0] dir;
        reg keep_edge;
        begin
            m=w[69:58]; dir=w[57:56];
            case(dir)
                2'd0: begin n0=w[83:72]; n1=w[55:44]; end
                2'd1: begin n0=w[125:114]; n1=w[13:2]; end
                2'd2: begin n0=w[111:100]; n1=w[27:16]; end
                default: begin n0=w[97:86]; n1=w[41:30]; end
            endcase
            keep_edge=(m>n0)&&(m>=n1);
            nms_class[1]=keep_edge && (m>=EDGE_TH);
            nms_class[0]=keep_edge && (m>=LOW_TH);
        end
    endfunction

    reg [3:0] class_word;
    reg cl_valid,cl_user,cl_last;
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin class_word<=0; cl_valid<=0; cl_user<=0; cl_last<=0; end
        else begin
            cl_valid<=nm_valid; cl_user<=nm_user; cl_last<=nm_last;
            class_word<=(nm_valid && nm_ok) ? {nms_class(nm_w0),nms_class(nm_w1)} : 4'd0;
        end
    end

    wire hy_valid,hy_user,hy_last,hy_ok;
    wire [10:0] hy_x,hy_y;
    wire [17:0] hy_w0,hy_w1;
    color_edge_window_2 #(.DATA_WIDTH(2),.IMG_WIDTH(IMG_WIDTH),.IMG_HEIGHT(IMG_HEIGHT))
      u_class_window (
        .I_clk(I_clk),.I_rst_n(I_rst_n),.I_valid(cl_valid),
        .I_user(cl_user),.I_last(cl_last),.I_word(class_word),
        .O_valid(hy_valid),.O_user(hy_user),.O_last(hy_last),
        .O_ok(hy_ok),.O_x(hy_x),.O_y(hy_y),.O_w0(hy_w0),.O_w1(hy_w1)
    );

    function local_hysteresis;
        input [17:0] w;
        reg strong_neighbour;
        begin
            strong_neighbour=w[17]|w[15]|w[13]|w[11]|w[7]|w[5]|w[3]|w[1];
            local_hysteresis=w[9] || (w[8] && strong_neighbour);
        end
    endfunction

    wire complete_support=hy_ok && (hy_x>=11'd3) && (hy_y>=11'd6);
    wire final0=complete_support && local_hysteresis(hy_w0);
    wire final1=complete_support && local_hysteresis(hy_w1);
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin O_tvalid<=0; O_tuser<=0; O_tlast<=0; O_tdata<=0; end
        else begin
            O_tvalid<=hy_valid; O_tuser<=hy_user; O_tlast<=hy_last;
            O_tdata<=hy_valid ? {{48{final0}},{48{final1}}} : 96'd0;
        end
    end
endmodule

// Reusable synchronous two-line, two-samples-per-clock 3x3 window.
// O_w0/O_w1 are row-major {a00,a01,a02,a10,a11,a12,a20,a21,a22}.
// Input SOF is honoured even before the first valid beat; no RAM clearing is
// needed because the first rows are masked. Input/output stream latency=2.
module color_edge_window_2 #(
    parameter integer DATA_WIDTH=26,
    parameter integer IMG_WIDTH=1280,
    parameter integer IMG_HEIGHT=720
)(
    input I_clk,input I_rst_n,input I_valid,input I_user,input I_last,
    input [2*DATA_WIDTH-1:0] I_word,
    output reg O_valid,output reg O_user,output reg O_last,output reg O_ok,
    output reg [10:0] O_x,output reg [10:0] O_y,
    output reg [9*DATA_WIDTH-1:0] O_w0,output reg [9*DATA_WIDTH-1:0] O_w1
);
    localparam integer GROUPS=IMG_WIDTH/4;
    // TD uses "bram" (see its RAM-Inference-Styles template), rather than
    // the Xilinx spelling "block".
    (* ram_style="bram" *) reg [2*DATA_WIDTH-1:0] even_rows[0:GROUPS-1];
    (* ram_style="bram" *) reg [2*DATA_WIDTH-1:0] odd_rows[0:GROUPS-1];
    reg [2*DATA_WIDTH-1:0] even_rd,odd_rd;
    reg [2*DATA_WIDTH-1:0] bot_d;
    reg valid_d,user_d,last_d;
    reg [10:0] x_pos,y_pos,x_d,y_d;
    wire [10:0] read_x=I_user ? 11'd0 : x_pos;
    wire [10:0] read_y=I_user ? 11'd0 : y_pos;

    // Read-before-write inferred RAM template. The bank being overwritten
    // holds row y-2; the other bank holds row y-1. Outputs are not reset.
    always @(posedge I_clk) begin
        if(I_rst_n && I_valid) begin
            even_rd<=even_rows[read_x];
            odd_rd<=odd_rows[read_x];
            if(read_y[0]) odd_rows[read_x]<=I_word;
            else even_rows[read_x]<=I_word;
        end
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            x_pos<=0; y_pos<=0; x_d<=0; y_d<=0; bot_d<=0;
            valid_d<=0; user_d<=0; last_d<=0;
        end else begin
            valid_d<=I_valid; user_d<=I_user; last_d<=I_last;
            if(I_user) begin x_pos<=0; y_pos<=0; end
            if(I_valid) begin
                x_d<=read_x; y_d<=read_y; bot_d<=I_word;
                if(read_x==GROUPS-1) begin
                    x_pos<=0;
                    y_pos<=(read_y==IMG_HEIGHT-1) ? 11'd0 : read_y+1'b1;
                end else begin x_pos<=read_x+1'b1; y_pos<=read_y; end
            end
        end
    end

    wire [2*DATA_WIDTH-1:0] top_word=y_d[0] ? odd_rd : even_rd;
    wire [2*DATA_WIDTH-1:0] mid_word=y_d[0] ? even_rd : odd_rd;
    wire [DATA_WIDTH-1:0] t0=top_word[2*DATA_WIDTH-1:DATA_WIDTH];
    wire [DATA_WIDTH-1:0] t1=top_word[DATA_WIDTH-1:0];
    wire [DATA_WIDTH-1:0] m0=mid_word[2*DATA_WIDTH-1:DATA_WIDTH];
    wire [DATA_WIDTH-1:0] m1=mid_word[DATA_WIDTH-1:0];
    wire [DATA_WIDTH-1:0] b0=bot_d[2*DATA_WIDTH-1:DATA_WIDTH];
    wire [DATA_WIDTH-1:0] b1=bot_d[DATA_WIDTH-1:0];
    reg [DATA_WIDTH-1:0] tp2,tp1,mp2,mp1,bp2,bp1;
    wire [DATA_WIDTH-1:0] tleft2=(x_d==0)?{DATA_WIDTH{1'b0}}:tp2;
    wire [DATA_WIDTH-1:0] tleft1=(x_d==0)?{DATA_WIDTH{1'b0}}:tp1;
    wire [DATA_WIDTH-1:0] mleft2=(x_d==0)?{DATA_WIDTH{1'b0}}:mp2;
    wire [DATA_WIDTH-1:0] mleft1=(x_d==0)?{DATA_WIDTH{1'b0}}:mp1;
    wire [DATA_WIDTH-1:0] bleft2=(x_d==0)?{DATA_WIDTH{1'b0}}:bp2;
    wire [DATA_WIDTH-1:0] bleft1=(x_d==0)?{DATA_WIDTH{1'b0}}:bp1;
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            O_valid<=0; O_user<=0; O_last<=0; O_ok<=0;
            O_x<=0; O_y<=0; O_w0<=0; O_w1<=0;
            tp2<=0; tp1<=0; mp2<=0; mp1<=0; bp2<=0; bp1<=0;
        end else begin
            O_valid<=valid_d; O_user<=user_d; O_last<=last_d;
            O_ok<=valid_d && (x_d!=0) && (y_d>=2);
            if(valid_d) begin
                O_x<=x_d; O_y<=y_d;
                O_w0<={tleft2,tleft1,t0,mleft2,mleft1,m0,bleft2,bleft1,b0};
                O_w1<={tleft1,t0,t1,mleft1,m0,m1,bleft1,b0,b1};
                tp2<=t0; tp1<=t1; mp2<=m0; mp1<=m1; bp2<=b0; bp1<=b1;
            end else begin O_w0<=0; O_w1<=0; end
        end
    end
endmodule
