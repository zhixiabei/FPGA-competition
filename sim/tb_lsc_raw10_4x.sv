`timescale 1ns/1ps
module lsc_checker #(
    parameter integer W=64, ENABLE=1, R=0, GR=48, GB=48, B=0, BLACK=0,
    parameter BAYER="BGGR"
) (
    input clk,rst_n,v,u,l,ready,
    input [39:0] data,
    input integer x,y,
    output integer pixels_checked=0
);
    wire [39:0] result;
    wire ov,ou,ol,ir;
    lsc_raw10_4x #(.IMG_WIDTH(W),.BAYER_MODE(BAYER),.ENABLE(ENABLE),
        .EDGE_R_Q8(R),.EDGE_GR_Q8(GR),.EDGE_GB_Q8(GB),.EDGE_B_Q8(B),
        .BLACK_LEVEL(BLACK)) dut (
        .I_clk(clk),.I_rst_n(rst_n),.I_tdata(data),.I_tvalid(v),
        .I_tuser(u),.I_tlast(l),.I_tready(ir),.O_tdata(result),
        .O_tvalid(ov),.O_tuser(ou),.O_tlast(ol),.O_tready(ready));
    reg [39:0] expected_data[0:2];
    reg [2:0] ev=0,eu=0,el=0;
    integer j,p,phase,strength,value,delta,signal_value;
    real radius;
    function automatic integer strength_at(input integer px,py);
        integer position;
        begin
            position=2*(py%2)+px%2;
            case(BAYER)
                "BGGR": case(position) 0:strength_at=B;1:strength_at=GB;2:strength_at=GR;3:strength_at=R;endcase
                "RGGB": case(position) 0:strength_at=R;1:strength_at=GR;2:strength_at=GB;3:strength_at=B;endcase
                "GBRG": case(position) 0:strength_at=GB;1:strength_at=B;2:strength_at=R;3:strength_at=GR;endcase
                "GRBG": case(position) 0:strength_at=GR;1:strength_at=R;2:strength_at=B;3:strength_at=GB;endcase
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
                strength=strength_at(x+p,y);
                // Floating-point image-coordinate reference; no DUT ROM,
                // mirrored address, row parity register or crossbar reused.
                radius=W>4 ? (2.0*(x/4)-(W/4-1))/(W/4-1) : 0.0;
                delta=$rtoi(strength*radius*radius+0.5);
                signal_value=value>BLACK?value-BLACK:0;
                if(ENABLE) value=value+(signal_value*delta+128)/256;
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
    lsc_checker #(.W(W)) production(clk,rst_n,v,u,l,ready,data,x,y,default_pixels);
    generate if(W<=64) begin: configurations
        genvar k;
        for(k=0;k<4;k=k+1) begin: bayer_patterns
            localparam PATTERN=k==0?"BGGR":k==1?"RGGB":k==2?"GBRG":"GRBG";
            wire [31:0] count;
            lsc_checker #(.W(W),.BAYER(PATTERN),.R(17),.GR(48),.GB(81),.B(129),.BLACK(64))
                four_colour(clk,rst_n,v,u,l,ready,data,x,y,count);
        end
        wire [31:0] bypass_count,unity_count,maximum_count;
        lsc_checker #(.W(W),.ENABLE(0),.R(255),.GR(255),.GB(255),.B(255))
            bypass(clk,rst_n,v,u,l,ready,data,x,y,bypass_count);
        lsc_checker #(.W(W),.R(0),.GR(0),.GB(0),.B(0))
            unity(clk,rst_n,v,u,l,ready,data,x,y,unity_count);
        lsc_checker #(.W(W),.R(255),.GR(255),.GB(255),.B(255),.BLACK(16))
            maximum(clk,rst_n,v,u,l,ready,data,x,y,maximum_count);
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
        // Abort mid-row, then begin a new frame without flushing the pipe.
        beat(0,0,5,1);
        frame(5,0);
        // Reset with valid pixels in flight. They must not escape reset.
        beat(0,0,6,1);
        @(negedge clk);rst_n=0;v=0;u=0;l=0;
        repeat(4)idle(0);
        rst_n=1;
        frame(6,1);
        repeat(6)idle(0);
        if(default_pixels<7*W*H) $fatal(1,"LSC coverage incomplete");
        $display("LSC_RAW10_PASS width=%0d height=%0d pixels=%0d",W,H,default_pixels);
        $finish;
    end
    initial begin #200000000;$fatal(1,"LSC timeout");end
endmodule
