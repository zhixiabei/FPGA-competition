`timescale 1ns/1ps
module lsc_checker #(
    parameter integer W=64, H=17, ENABLE=1, R=0, GR=48, GB=48, B=0, BLACK=0,
    parameter integer YR=0, YGR=48, YGB=48, YB=0,
    parameter integer MR=255, MGR=255, MGB=255, MB=255, MESH=0, CURVE=1,
    parameter BAYER="BGGR"
) (
    input clk,rst_n,v,u,l,ready,
    input [39:0] data,
    input integer x,y,
    output integer pixels_checked=0
);
    `include "lsc_mesh_reference.vh"
    wire [39:0] result;
    wire ov,ou,ol,ir;
    lsc_raw10_4x #(.IMG_WIDTH(W),.IMG_HEIGHT(H),.BAYER_MODE(BAYER),.ENABLE(ENABLE),
        .EDGE_R_Q8(R),.EDGE_GR_Q8(GR),.EDGE_GB_Q8(GB),.EDGE_B_Q8(B),
        .EDGE_Y_R_Q8(YR),.EDGE_Y_GR_Q8(YGR),.EDGE_Y_GB_Q8(YGB),.EDGE_Y_B_Q8(YB),
        .MAX_R_Q8(MR),.MAX_GR_Q8(MGR),.MAX_GB_Q8(MGB),.MAX_B_Q8(MB),
        .BLACK_LEVEL(BLACK),.MESH_ENABLE(MESH),.MESH_CURVE_ENABLE(CURVE),
        .MESH_GR_Q8(REF_GR),.MESH_GB_Q8(REF_GB),.MESH_B_Q8(REF_B)) dut (
        .I_clk(clk),.I_rst_n(rst_n),.I_tdata(data),.I_tvalid(v),
        .I_tuser(u),.I_tlast(l),.I_tready(ir),.O_tdata(result),
        .O_tvalid(ov),.O_tuser(ou),.O_tlast(ol),.O_tready(ready));
    reg [39:0] expected_data[0:2];
    reg [2:0] ev=0,eu=0,el=0;
    integer j,p,phase,strength,value,delta,signal_value,limit;
    real radius,vertical_radius;
    // Direct weighted interpolation in image coordinates. No running
    // remainder, accumulator, ROM content or DUT state is used as a reference.
    function automatic integer mesh_gain(input integer px,py);
        integer position,c,band,column,q,a,b,amplitude,shape;
        integer knots[0:2];
        real ty,tx;
        begin
            position=2*(py%2)+px%2;
            case(BAYER)
                "BGGR": case(position) 0:c=2;1:c=1;2:c=0;3:c=3;endcase
                "RGGB": case(position) 0:c=3;1:c=0;2:c=1;3:c=2;endcase
                "GBRG": case(position) 0:c=1;1:c=2;2:c=3;3:c=0;endcase
                "GRBG": case(position) 0:c=0;1:c=3;2:c=2;3:c=1;endcase
            endcase
            band=py<359.5 ? 0 : 1;
            ty=(py-(31.5+328*band))/328.0;
            if(ty<0)ty=0;if(ty>1)ty=1;
            for(column=0;column<3;column=column+1) begin
                q=3*band+column;
                case(c)
                    0:begin a=(REF_GR>>(8*(8-q)))&255;b=(REF_GR>>(8*(5-q)))&255;end
                    1:begin a=(REF_GB>>(8*(8-q)))&255;b=(REF_GB>>(8*(5-q)))&255;end
                    2:begin a=(REF_B>>(9*(8-q)))&511;b=(REF_B>>(9*(5-q)))&511;end
                    default:begin a=256;b=256;end
                endcase
                knots[column]=CURVE ? $rtoi(a*b/(b*(1.0-ty)+a*ty)+0.50000001) :
                    $rtoi(a*(1.0-ty)+b*ty+0.50000001);
            end
            q=px/4;
            column=q<160 ? 0 : 1;
            tx=(q-(8+152*column))/152.0;
            if(tx<0)tx=0;if(tx>1)tx=1;
            mesh_gain=$rtoi(knots[column]*(1.0-tx)+knots[column+1]*tx+0.50000001);
            if(CURVE) begin
                a=knots[column];b=knots[column+1];
                amplitude=$rtoi((a-b)*(a-b)/(2.0*(a+b))+0.50000001);
                shape=$rtoi(64.0*tx*(1.0-tx)+0.50000001);
                mesh_gain=mesh_gain-(amplitude*shape+8)/16;
            end
        end
    endfunction
    function automatic integer strength_at(input integer px,py,input bit vertical);
        integer position,rs,grs,gbs,bs;
        begin
            rs=vertical?YR:R;grs=vertical?YGR:GR;gbs=vertical?YGB:GB;bs=vertical?YB:B;
            position=2*(py%2)+px%2;
            case(BAYER)
                "BGGR": case(position) 0:strength_at=bs;1:strength_at=gbs;2:strength_at=grs;3:strength_at=rs;endcase
                "RGGB": case(position) 0:strength_at=rs;1:strength_at=grs;2:strength_at=gbs;3:strength_at=bs;endcase
                "GBRG": case(position) 0:strength_at=gbs;1:strength_at=bs;2:strength_at=rs;3:strength_at=grs;endcase
                "GRBG": case(position) 0:strength_at=grs;1:strength_at=rs;2:strength_at=bs;3:strength_at=gbs;endcase
            endcase
        end
    endfunction
    function automatic integer limit_at(input integer px,py);
        integer position;
        begin
            position=2*(py%2)+px%2;
            case(BAYER)
                "BGGR": case(position) 0:limit_at=MB;1:limit_at=MGB;2:limit_at=MGR;3:limit_at=MR;endcase
                "RGGB": case(position) 0:limit_at=MR;1:limit_at=MGR;2:limit_at=MGB;3:limit_at=MB;endcase
                "GBRG": case(position) 0:limit_at=MGB;1:limit_at=MB;2:limit_at=MR;3:limit_at=MGR;endcase
                "GRBG": case(position) 0:limit_at=MGR;1:limit_at=MR;2:limit_at=MB;3:limit_at=MGB;endcase
            endcase
        end
    endfunction
    always @(posedge clk) begin
        if(!rst_n) begin
            ev=0;eu=0;el=0;
            for(j=0;j<3;j=j+1) expected_data[j]=0;
        end else begin
            ev={ev[1:0],v};eu={eu[1:0],u};el={el[1:0],l};
            expected_data[2]=expected_data[1];expected_data[1]=expected_data[0];
            for(p=0;p<4;p=p+1) begin
                value=data[p*10 +:10];
                strength=strength_at(x+p,y,0);
                // Floating-point image-coordinate reference; no DUT ROM,
                // mirrored address, row parity register or crossbar reused.
                radius=W>4 ? (2.0*(x/4)-(W/4-1))/(W/4-1) : 0.0;
                vertical_radius=H>1 ? (2.0*y-(H-1))/(H-1) : 0.0;
                delta=$rtoi(strength*radius*radius+0.5)+
                      $rtoi(strength_at(x+p,y,1)*vertical_radius*vertical_radius+0.5);
                limit=limit_at(x+p,y);
                if(delta>limit)delta=limit;
                signal_value=value>BLACK?value-BLACK:0;
                if(ENABLE) begin
                    if(MESH) value=(value>BLACK?BLACK:value)+(signal_value*mesh_gain(x+p,y)+128)/256;
                    else value=value+(signal_value*delta+128)/256;
                end
                if(value>1023)value=1023;
                expected_data[0][p*10 +:10]=value;
            end
        end
        #1;
        if({ov,ou,ol}!=={ev[2],eu[2],el[2]} || ir!==ready)
            $fatal(1,"LSC control/latency mismatch W=%0d Bayer=%s",W,BAYER);
        if(ov) begin
            if(result!==expected_data[2])
                $fatal(1,"LSC arithmetic/order mismatch W=%0d Bayer=%s enable=%0d black=%0d got=%h expected=%h",
                    W,BAYER,ENABLE,BLACK,result,expected_data[2]);
            pixels_checked=pixels_checked+4;
        end else if(result!==40'd0) $fatal(1,"Invalid output was not zero");
    end
endmodule

module tb_lsc_raw10_4x #(parameter integer W=64,H=17);
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,v=0,u=0,l=0,ready=1;
    reg [39:0] data=0;
    integer x=0,y=0,frame_id,lane,row,col,extra,default_pixels;
    lsc_checker #(.W(W),.H(H)) production(clk,rst_n,v,u,l,ready,data,x,y,default_pixels);
    wire [31:0] fitted_pixels;
    lsc_checker #(.W(W),.H(H),.R(0),.GR(135),.GB(106),.B(45),
        .YR(0),.YGR(51),.YGB(59),.YB(21),.MR(0),.MGR(122),.MGB(103),.MB(43))
        measured_fit(clk,rst_n,v,u,l,ready,data,x,y,fitted_pixels);
    generate if(W==1280 && H==720) begin: mesh_profiles
        wire [31:0] linear_count;
        lsc_checker #(.W(W),.H(H),.MESH(1),.CURVE(0))
            linear_reference(clk,rst_n,v,u,l,ready,data,x,y,linear_count);
        genvar m;
        for(m=0;m<4;m=m+1) begin: patterns
            localparam PATTERN=m==0?"BGGR":m==1?"RGGB":m==2?"GBRG":"GRBG";
            wire [31:0] count;
            lsc_checker #(.W(W),.H(H),.MESH(1),.BAYER(PATTERN),.BLACK(m==0?0:64))
                calibrated(clk,rst_n,v,u,l,ready,data,x,y,count);
        end
    end endgenerate
    generate if(W<=64) begin: configurations
        genvar k;
        for(k=0;k<4;k=k+1) begin: bayer_patterns
            localparam PATTERN=k==0?"BGGR":k==1?"RGGB":k==2?"GBRG":"GRBG";
            wire [31:0] count;
            lsc_checker #(.W(W),.H(H),.BAYER(PATTERN),.R(17),.GR(48),.GB(81),.B(129),
                .YR(51),.YGR(92),.YGB(23),.YB(163),.BLACK(64))
                four_colour(clk,rst_n,v,u,l,ready,data,x,y,count);
        end
        wire [31:0] bypass_count,unity_count,maximum_count,horizontal_count,vertical_count,limited_count;
        lsc_checker #(.W(W),.H(H),.R(255),.GR(255),.GB(255),.B(255),
            .YR(255),.YGR(255),.YGB(255),.YB(255),.MR(0),.MGR(1),.MGB(37),.MB(254),.BLACK(64))
            limited(clk,rst_n,v,u,l,ready,data,x,y,limited_count);
        lsc_checker #(.W(W),.H(H),.ENABLE(0),.R(255),.GR(255),.GB(255),.B(255),
            .YR(255),.YGR(255),.YGB(255),.YB(255))
            bypass(clk,rst_n,v,u,l,ready,data,x,y,bypass_count);
        lsc_checker #(.W(W),.H(H),.R(0),.GR(0),.GB(0),.B(0),.YR(0),.YGR(0),.YGB(0),.YB(0))
            unity(clk,rst_n,v,u,l,ready,data,x,y,unity_count);
        lsc_checker #(.W(W),.H(H),.R(255),.GR(255),.GB(255),.B(255),
            .YR(255),.YGR(255),.YGB(255),.YB(255),.BLACK(16))
            maximum(clk,rst_n,v,u,l,ready,data,x,y,maximum_count);
        lsc_checker #(.W(W),.H(H),.YR(0),.YGR(0),.YGB(0),.YB(0))
            horizontal_only(clk,rst_n,v,u,l,ready,data,x,y,horizontal_count);
        lsc_checker #(.W(W),.H(H),.R(0),.GR(0),.GB(0),.B(0),
            .YR(53),.YGR(71),.YGB(113),.YB(29))
            vertical_only(clk,rst_n,v,u,l,ready,data,x,y,vertical_count);
    end endgenerate
    task automatic idle(input bit sof);
        begin @(negedge clk);v=0;u=sof;l=0;data=0;end
    endtask
    task automatic beat(input integer px,py,id,input bit sof);
        integer n,pixel;
        begin
            @(negedge clk);
            x=px;y=py;v=1;u=sof;l=px==W-4;ready=(px/4+py)%3!=0;
            for(n=0;n<4;n=n+1) begin
                case(id)
                    0:pixel=(py*W+px+n)%1024;
                    1:pixel=1023;
                    2:pixel=0;
                    3:pixel=64;
                    7:pixel=384;
                    default:pixel=((py*W+px+n)*37+id*103)%1024;
                endcase
                data[n*10 +:10]=pixel;
            end
        end
    endtask
    task automatic frame(input integer id,input bit early);
        integer xx,yy;
        begin
            if(early) begin idle(1);idle(1);idle(0);end
            for(yy=0;yy<H;yy=yy+1) begin
                for(xx=0;xx<W;xx=xx+4) begin
                    beat(xx,yy,id,!early && xx==0 && yy==0);
                    if(id%2==0 && (xx/4+yy)%7==0) idle(0);
                end
                if(id%2==0) begin idle(0);idle(0);end
            end
        end
    endtask
    initial begin
        repeat(5)idle(0);
        rst_n=1;
        frame(0,0);frame(1,0);frame(2,1);frame(3,0);frame(4,1);
        // Abort beyond the first row, then restart without flushing the pipe.
        // The new SOF must reset the vertical profile as well as Bayer phase.
        for(col=0;col<W;col=col+4)beat(col,0,5,col==0);
        if(H>1)beat(0,1,5,0);
        frame(5,0);
        // Reset with valid pixels in flight. They must not escape reset.
        beat(0,0,6,1);
        @(negedge clk);rst_n=0;v=0;u=0;l=0;
        repeat(4)idle(0);
        rst_n=1;
        frame(6,1);
        // Uniform input exercises center, four sides and corners at the same level.
        frame(7,0);
        repeat(6)idle(0);
        if(default_pixels<8*W*H) $fatal(1,"LSC coverage incomplete");
        $display("LSC_RAW10_PASS width=%0d height=%0d pixels=%0d",W,H,default_pixels);
        $finish;
    end
    initial begin #200000000;$fatal(1,"LSC timeout");end
endmodule
