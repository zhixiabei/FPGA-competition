`timescale 1ns/1ps
module tb_rgb_selector_local_control;
    localparam integer LAT=11,W=64,H=16;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,valid=0,user=0,last=0;
    reg [95:0] data=0;
    reg [11:0] effect_config=12'h200;
    reg [3:0] mask=0;
    wire out_valid,out_user,out_last,edge_mode;
    wire [95:0] output_data;
    wire [11:0] output_config;
    wire [95:0] edge_data,emboss_data,cartoon_data,morph_data;
    rgb_edge_switch_96 #(.IMG_WIDTH(W),.IMG_HEIGHT(H)) dut(
        .I_clk(clk),.I_rst_n(rst_n),.I_effect_config(effect_config),
        .I_tlast(last),.I_tuser(user),.I_tdata(data),.I_tvalid(valid),
        .I_mask_pixels(mask),.O_tlast(out_last),.O_tuser(out_user),
        .O_tdata(output_data),.O_tvalid(out_valid),.O_edge_mode(edge_mode),
        .O_effect_config(output_config));
    scharr_edge_detect_96 #(.IMG_WIDTH(W),.IMG_HEIGHT(H)) effects(
        .I_clk(clk),.I_rst_n(rst_n),.I_tlast(last),.I_tuser(user),
        .I_tdata(data),.I_tvalid(valid),.I_tready(1'b1),
        .O_tlast(),.O_tuser(),.O_tvalid(),.O_tready(),
        .O_tdata(edge_data),.O_emboss_data(emboss_data),
        .O_cartoon_data(cartoon_data),.O_morph_data(morph_data));
    reg [11:0] active=12'h200,configs[0:LAT-1];
    reg [95:0] rgb[0:LAT-1],expected_data=0;
    reg [15:0] expected_controls={3'b000,12'h200,1'b1};
    reg [LAT-1:0] valids=0,users=0,lasts=0;
    reg [15:0] seen=0;
    integer i,cycles=0,mask_words=0,invalid_words=0;
    always @(posedge clk) begin
        if(!rst_n) begin
            active=12'h200;valids=0;users=0;lasts=0;
            expected_data=0;
            expected_controls={3'b000,12'h200,1'b1};
            for(i=0;i<LAT;i=i+1) begin configs[i]=12'h200;rgb[i]=0;end
        end else begin
            // Sample the original eleven-cycle selector before this edge,
            // then compare its complete tuple after the added output stage.
            expected_controls={valids[LAT-1],users[LAT-1],lasts[LAT-1],configs[LAT-1],
                               (configs[LAT-1][11:8]==4'd2)};
            case(configs[LAT-1][11:8])
                2,7: expected_data=edge_data;
                4: expected_data=emboss_data;
                6: expected_data=cartoon_data;
                8: expected_data=morph_data;
                9,10,11,12: expected_data={{24{mask[0]}},{24{mask[1]}},
                                          {24{mask[2]}},{24{mask[3]}}};
                default: expected_data=rgb[LAT-1];
            endcase
            if(!valids[LAT-1]) begin expected_data=0;invalid_words=invalid_words+1;end
            else begin
                seen[configs[LAT-1][11:8]]=1;
                if(configs[LAT-1][11:8]>=9 && configs[LAT-1][11:8]<=12)
                    mask_words=mask_words+1;
            end
            if(user) active=effect_config;
            for(i=LAT-1;i>0;i=i-1) begin configs[i]=configs[i-1];rgb[i]=rgb[i-1];end
            configs[0]=active;rgb[0]=data;
            valids={valids[LAT-2:0],valid};users={users[LAT-2:0],user};
            lasts={lasts[LAT-2:0],last};
            #1;
            if({out_valid,out_user,out_last,output_config,edge_mode} !==
               expected_controls) $fatal(1,"Selector output stage misaligned metadata");
            if(output_data!==expected_data)
                $fatal(1,"Selector registered pixel mismatch cycle=%0d",cycles);
            cycles=cycles+1;
        end
    end
    integer mode,beat,lane;
    reg [31:0] noise=32'h87124ac3;
    initial begin
        repeat(4) @(negedge clk);
        rst_n=1;
        for(mode=0;mode<16;mode=mode+1) begin
            effect_config={mode[3:0],8'h5a};user=1;valid=0;last=0;
            @(negedge clk);user=0;
            if(mode[0]) repeat(3) @(negedge clk);
            for(beat=0;beat<W*H/4;beat=beat+1) begin
                valid=1;last=(beat%16==15);
                for(lane=0;lane<3;lane=lane+1) begin
                    noise=noise*32'd1664525+32'd1013904223;
                    data[lane*32 +:32]=noise;
                end
                mask=noise[3:0];
                // A new request mid-frame must wait for the next SOF.
                if(beat==12) effect_config={~mode[3:0],8'ha5};
                @(negedge clk);
                if(beat%5==3) begin valid=0;last=0;@(negedge clk);end
            end
            valid=0;last=0;repeat(16) @(negedge clk);
        end
        if(seen!==16'hffff || mask_words!=1024 || invalid_words==0)
            $fatal(1,"Missing selector mode or bubble coverage");
        $display("RGB_SELECTOR_LOCAL_CONTROL_PASS modes=16 mask_words=%0d invalid_words=%0d latency=12 added_clocks=1",mask_words,invalid_words);
        $finish;
    end
    initial begin #1000000;$fatal(1,"Selector test timeout");end
endmodule
