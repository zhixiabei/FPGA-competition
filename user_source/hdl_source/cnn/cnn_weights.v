// Quantized weights exported from fpga_artifacts/model.pt.
// Weights have seven fractional bits. All exported biases retain their
// original fourteen fractional bits; the inference engine rescales B2 and BF
// to the actual activation / GAP accumulator scales before adding them.
module cnn_weights (
    input  wire [6:0]  I_w1_addr,
    input  wire [10:0] I_w2_addr,
    input  wire [6:0]  I_wf_addr,
    input  wire [3:0]  I_b1_addr,
    input  wire [4:0]  I_b2_addr,
    input  wire [2:0]  I_bf_addr,
    output wire signed [7:0] O_w1,
    output wire signed [7:0] O_w2,
    output wire signed [7:0] O_wf,
    output reg  signed [31:0] O_b1,
    output reg  signed [31:0] O_b2,
    output reg  signed [31:0] O_bf
);
    localparam [8*72-1:0] W1 = 576'h0d2be6e3e922f30eef0ce705df28020d1a1221d7e6cdde0a0c1ceb2e372a0b1d0d1b352129ea1c28cd39ccefecd5d0bdffd5ddccefcc1f36162c1a3b1f3a00241ce403f71fef2219;
    // Export address 0 is the LSB byte. Match all 1152 bytes of w2.mem:
    // the former literal inserted 0xee at address 162 and lost the final 0x19.
    localparam [8*1152-1:0] W2 = 9216'h191f0e19282109210e131801081d0d17200520190a211b2116170fef0adfeef4e1eaefd61a35353e4d37524b49f8ebf1ece5f4f9f1fdfb05ed0501e7e9f5da030f0318061817150e07ec0805f9f401020af1fe08f1fafdfef60ae1edd2d802eddfefe0ff0cf80908160bf717d327d3d2f4e702fdd3f90efcf0fc09fd08060cf816fb08fd0f0b19f5fe0e03f10907f3fd0d121208f9ff05030cbeddbbe1d9dbd6e5d018171c0010061f1c20d6f4d9e504def700e6b6d9ace7d9d8b9ccc71523121316171f2822b8f0c4ebfbd0d60eecc0c4b2bec8cecdd9bd14fc0f0af00910f5ff10e9fb15eceb1de915082ef6101e05112f1415cbf012c3a71fd6e24bfd4a1c076652db39f1f1f1f0f8f0f2e3c510c7f51ed58008ece11cf6f319f4e80708ebfbfa00f2fa0607fa00fffdfe01160c001209acc5afa9baa3a2b0af0b0a23161c22040916c9c3d1eee3f9d8d1c009d6f380b94380de321204131c1e201b141f0b0314070e0504091132231823282f311e1f250c1a26281d2220101a05121d2522181b18efe5dbe1f3dcf1ebd86e5e6a3b555d637469f1e4dce3dcf0f3f1e0fdfae0f7f4e7efe4d6201b14060e1904180e0bf2f9f5eb07ef0205fb0efb0a09f8fb0507e3f0ddf4f4e1ddebd508141b200306181808f6e6f1d3deccf3e7d70afdf4010206f4f2050b0524140d1a22180df8100c0df4f60efbf5f30405fb080507f9fbfbf107120ff70a0501e9dce405eef6c2dbc71216041513150f18121ae6fad7cfd108e3faff060904f4fb060ff612181405f9130d1112080af406f60f00f901231c19230f241118161709051b1f04160f080b09130f221c131222ecfef3edf3e8e9f1eb5a48492a2e2e4e443ef7fdf8ede4dfeee6db01eef5ffe6eee8e8ee051e16141110061412180bfd170306180c0defedb8ccdac2a7dead07070f101c22241a1f03f4fa02fa02c7f3f7d9d6cbf9d1d4eac5d70d1e1b1926351d172bfd01ff01f307c0f4efe3e9d3cef2c4a0ccba182925221f1c2f35351d1317141a28211d1b1618201e272a1a2216e8f3dce9f6e7e7e2da706271586365777c6cdcdce9e0ebe9eadee7fdece6f1f1d6dcead42122090c241f14201010010a0b11fc22fc0d1907ea06f6ff2710050c12fdff170509302517e51610d3e109d4d04bf235efe91c14d4f4ee0f20d8e70bf2d6de16ed2f0cd1e309f3d11400f612fa0c260fecf3010105fff0f5f80cf7fd0801f0080b080402f4f70df6f1f1f6fbfffef907fef508f4f50309faf4f0f6f4f60709fbf401fb0c08020c06f3070e01fb04fa0df4f8f9fd00fbfbfef61f301c1824272637380d1a1b1420161a122a1f0c18292624102313e8eee0faf4dcf6e2ee6b746362575e5f6b66e8efdcf4ddd8ecdedfe2f3d2dfe3e3eef4ee1d230d060e1e22220af5f006eff001f7fc0cf8f1f0030405f7eef6f701070bf9f30304ff100b161d1a14101417b5b6b9cfadc0c9b9b029271a17182026201e0913270a0e1f0715200af5050305f70cf401f603f103fffcf4ebe106f002080bfbe2dae743183b13f205d3e3eeebf0faf805fe02dcfe442a3f1f1a2cf110b0e7e1f9e4ecf3f2f309ef07f30e2a2c0aeeecf3f005000d00f5dfe7;
    localparam [8*80-1:0] WF = 640'h50f4ce80e443f4d541d34ae4f461da62121d11cd04fd1f00ee13eace10eb03e12b0ded2bfb3304fef70d2ee0ef14e5f496183a3e3e80180a9d2a80ac118042190ae6fd7fd33512f445d82f51df30ea83;

    localparam signed [31:0] B1_0 = 32'h00003379;
    localparam signed [31:0] B1_1 = 32'hffffe985;
    localparam signed [31:0] B1_2 = 32'hfffff0c0;
    localparam signed [31:0] B1_3 = 32'h0000016c;
    localparam signed [31:0] B1_4 = 32'hffffea3e;
    localparam signed [31:0] B1_5 = 32'h000029ea;
    localparam signed [31:0] B1_6 = 32'h00001bae;
    localparam signed [31:0] B1_7 = 32'h00002759;

    localparam signed [31:0] B2_0  = 32'h00000105;
    localparam signed [31:0] B2_1  = 32'hffffff14;
    localparam signed [31:0] B2_2  = 32'h000017c8;
    localparam signed [31:0] B2_3  = 32'hfffffbdb;
    localparam signed [31:0] B2_4  = 32'h00000673;
    localparam signed [31:0] B2_5  = 32'h0000132d;
    localparam signed [31:0] B2_6  = 32'h000004f8;
    localparam signed [31:0] B2_7  = 32'h00001099;
    localparam signed [31:0] B2_8  = 32'hfffffba5;
    localparam signed [31:0] B2_9  = 32'hfffffe81;
    localparam signed [31:0] B2_10 = 32'h000010ac;
    localparam signed [31:0] B2_11 = 32'hfffffd61;
    localparam signed [31:0] B2_12 = 32'h00000bb6;
    localparam signed [31:0] B2_13 = 32'h000002b4;
    localparam signed [31:0] B2_14 = 32'hfffff59d;
    localparam signed [31:0] B2_15 = 32'h00000877;

    localparam signed [31:0] BF_0 = 32'hfffff3eb;
    localparam signed [31:0] BF_1 = 32'hfffffda6;
    localparam signed [31:0] BF_2 = 32'hfffff3d8;
    localparam signed [31:0] BF_3 = 32'h0000039f;
    localparam signed [31:0] BF_4 = 32'h000011a3;

    assign O_w1 = W1[I_w1_addr*8 +: 8];
    assign O_w2 = W2[I_w2_addr*8 +: 8];
    assign O_wf = WF[I_wf_addr*8 +: 8];

    always @(*) begin
        case (I_b1_addr)
            4'd0: O_b1 = B1_0; 4'd1: O_b1 = B1_1;
            4'd2: O_b1 = B1_2; 4'd3: O_b1 = B1_3;
            4'd4: O_b1 = B1_4; 4'd5: O_b1 = B1_5;
            4'd6: O_b1 = B1_6; default: O_b1 = B1_7;
        endcase
        case (I_b2_addr)
            5'd0: O_b2 = B2_0; 5'd1: O_b2 = B2_1;
            5'd2: O_b2 = B2_2; 5'd3: O_b2 = B2_3;
            5'd4: O_b2 = B2_4; 5'd5: O_b2 = B2_5;
            5'd6: O_b2 = B2_6; 5'd7: O_b2 = B2_7;
            5'd8: O_b2 = B2_8; 5'd9: O_b2 = B2_9;
            5'd10: O_b2 = B2_10; 5'd11: O_b2 = B2_11;
            5'd12: O_b2 = B2_12; 5'd13: O_b2 = B2_13;
            5'd14: O_b2 = B2_14; default: O_b2 = B2_15;
        endcase
        case (I_bf_addr)
            3'd0: O_bf = BF_0; 3'd1: O_bf = BF_1;
            3'd2: O_bf = BF_2; 3'd3: O_bf = BF_3;
            default: O_bf = BF_4;
        endcase
    end
endmodule
