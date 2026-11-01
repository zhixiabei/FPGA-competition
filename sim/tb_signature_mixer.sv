`timescale 1ns/1ps
module tb_signature_mixer;
    localparam W=320,H=180;
    reg clk=0; always #5 clk=~clk;
    reg rst=0,de=0,user=0,last=0,hs=0,vs=0,ready=1,overflow=0;
    reg [3:0] mode=0,valid=0,hold=0;
    reg [7:0] command=0;
    reg [191:0] boxes=0;
    reg [23:0] rgb=0;
    reg [11:0] center_x=0;
    wire ode,ohs,ovs,rd;
    wire [23:0] orgb;
    integer f,xx=0,yy=0,j,tx,slot,checks=0,pixels=0,restored_pixels=0;
    reg cells[0:79];
    reg [2:0] ed=0,eh=0,ev=0;
    reg [23:0] ec0=0,ec1=0,ec2=0;
    function [7:0] channel(input integer index,input bit corrected);
        case(index%6)
            0: channel=0;
            1: channel=corrected ? 23 : 16;
            2: channel=corrected ? 80 : 64;
            3: channel=128;
            4: channel=corrected ? 210 : 224;
            default: channel=255;
        endcase
    endfunction
    function [23:0] camera(input integer x,y,input bit corrected);
        camera={channel(x,corrected),channel(y,corrected),channel(x+y,corrected)};
    endfunction
    hdmi_mixer #(.IMG_WIDTH(W),.IMG_HEIGHT(H),.SIGNATURE_ENABLE(1),
        .SHOW_COLOR_TARGET(1),.MULTI_TARGET_ENABLE(1),.TARGET_SLOTS(1),
        .SHOW_EFFECT_LABEL(1),.SHOW_CNN(1),.FRUIT_CNN(1)) dut (
        .I_clk(clk),.I_rst_n(rst),.I_video_vsync(vs),.I_video_hsync(hs),
        .I_video_de(de),.I_video_user(user),.I_video_last(last),
        .I_video_rd_data(rgb),.I_effect_mode(mode),.I_effect_param(command),
        .I_target_result_ready(ready),.I_target_multi_valid(valid),
        .I_target_found(|valid),.I_target_motion_mode(1'b0),.I_target_color_mode(2'd0),
        .I_target_center_x(center_x),.I_target_center_y(12'd80),
        .I_target_xmin(boxes[11:0]),.I_target_xmax(boxes[23:12]),
        .I_target_ymin(boxes[35:24]),.I_target_ymax(boxes[47:36]),
        .I_target_multi_shapes(8'd0),.I_cnn_enable(1'b1),
        .I_cnn_result_valid(1'b1),.I_cnn_class(3'd2),
        .I_checkout_weight_bcd(16'd0),.I_checkout_price_bcd(16'd0),
        .I_checkout_weight_valid(1'b0),.I_checkout_price_valid(1'b0),
        .I_hand_box_valid(1'b0),.I_hand_box(48'd0),
        .I_target_multi_hold(hold),.I_target_multi_boxes(boxes),
        .I_target_multi_overflow(overflow),.O_video_rd_en(rd),
        .O_hdmi_de(ode),.O_hdmi_hsync(ohs),.O_hdmi_vsync(ovs),.O_hdmi_data(orgb));
    always @(posedge clk) begin
        if(!rst) begin ed=0;eh=0;ev=0;ec0=0;ec1=0;ec2=0;end
        else begin
            ec2=ec1;ec1=ec0;
            ec0=!de ? 0 : (yy>=80 && yy<84 && cells[xx/4]) ? 24'hff3030 : camera(xx,yy,1);
            ed={ed[1:0],de};eh={eh[1:0],hs};ev={ev[1:0],vs};
            #1;
            if(rd!==de || ode!==ed[2] || ohs!==eh[2] || ovs!==ev[2])
                $fatal(1,"Sync or read enable mismatch frame=%0d",f);
            if(ode && f!=12 && orgb!==ec2) $fatal(1,"RGB/ink alignment frame=%0d input=%0d,%0d expected=%h actual=%h",f,xx,yy,ec2,orgb);
            if(f==12 && ode && orgb!==ec2) restored_pixels++;
            checks++; if(ode) pixels++;
        end
    end
    initial begin
        for(j=0;j<80;j++) cells[j]=0;
        repeat(4) @(negedge clk);rst=1;
        repeat(4000) @(negedge clk);
        for(f=0;f<15;f++) begin
            mode=f==12 ? 0 : 13;
            command=f==3 ? 1 : 0;
            ready=f!=13;hold=0;overflow=f==11;valid=f==0 ? 0 : 1;boxes=0;
            tx=80;slot=0;
            case(f)
                1: begin tx=80;cells[20]=1;end
                2: begin tx=112;for(j=20;j<=24;j++) cells[j]=1;end
                3: tx=144;
                4: begin tx=176;cells[44]=1;end
                5: begin tx=208;hold=1;end
                6: begin tx=224;cells[56]=1;end
                7: valid=0;
                8: begin tx=256;cells[64]=1;end
                9: tx=288;
                10: begin tx=288;valid=3;end
                11: tx=288;
                12: for(j=0;j<80;j++) cells[j]=0;
                14: begin tx=40;cells[10]=1;end
            endcase
            if(f==2 || f==4 || f==14) valid=1<<slot;
            boxes[slot*48+:48]={12'd82,12'd78,12'(W-1-tx+2),12'(W-1-tx-2)};
            center_x=W-1-tx;
            if(f==9) begin boxes[47:0]={12'd82,12'd78,12'd4095,12'd4090};center_x=4092;end
            for(yy=0;yy<H;yy++) begin
                for(xx=0;xx<W;xx++) begin
                    de=1;user=xx==0 && yy==0;last=xx==W-1;
                    hs=(xx%17)==0;vs=user;rgb=camera(xx,yy,0);
                    if(f==2 && yy==90 && xx==100) begin mode=0;command=1;end
                    if(f==2 && yy==90 && xx==110) begin mode=13;command=0;end
                    @(negedge clk);
                end
                de=0;user=0;last=0;hs=0;vs=0;repeat(4) @(negedge clk);
            end
            repeat(20) @(negedge clk);
        end
        repeat(5) @(negedge clk);
        if(pixels!=15*W*H) $fatal(1,"Pixel coverage incomplete %0d",pixels);
        if(restored_pixels==0) $fatal(1,"Original overlays were not restored on exit");
        $display("SIGNATURE_MIXER_PASS frames=15 pixels=%0d checks=%0d de_latency=3 primary_center=1 pause_hold_loss_bounds_ambiguity_overflow_clear=PASS restored_overlay_pixels=%0d",pixels,checks,restored_pixels);
        $finish;
    end
    initial begin #30000000;$fatal(1,"Mixer timeout");end
endmodule
