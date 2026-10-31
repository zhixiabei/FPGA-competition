// RGB128 Q9 normalization, signed 12-bit operands in INT16 DDR.
// Exact original table, one synchronous ERAM read per accepted clock.
module handcnn_normalize(
    input wire clk,
    input wire [10:0] address,
    output wire [15:0] value
);
    // Entry zero is at the least significant end. These are the original
    // 768 RGB table values with redundant sign-extension bits removed.
    localparam [9215:0] NORMALIZE_LUT = {
        192'h54853f53652d52451b5125095004f74ee4e64dd4d44cb4c2,
        192'h4b94b04a749e49548c48347a47246946045744e44543c433,
        192'h42a42141840f4063fe3f53ec3e33da3d13c83bf3b63ad3a4,
        192'h39b39238938137836f36635d35434b34233933032731e315,
        192'h30d3042fb2f22e92e02d72ce2c52bc2b32aa2a1299290287,
        192'h27e27526c26325a25124823f23622d22521c21320a2011f8,
        192'h1ef1e61dd1d41cb1c21b91b11a819f19618d18417b172169,
        192'h16015714e14513d13412b1221191101070fe0f50ec0e30da,
        192'h0d10c90c00b70ae0a509c09308a08107806f06605d05504c,
        192'h04303a03102801f01600d004ffbff2fe9fe0fd8fcffc6fbd,
        192'hfb4fabfa2f99f90f87f7ef75f6cf64f5bf52f49f40f37f2e,
        192'hf25f1cf13f0af01ef8ef0ee7edeed5eccec3ebaeb1ea8e9f,
        192'he96e8de84e7ce73e6ae61e58e4fe46e3de34e2be22e19e10,
        192'he08dffdf6dedde4ddbdd2dc9dc0db7daeda5d9cd94d8bd82,
        192'hd79d70d67d5ed55d4cd43d3ad31d28d20d17d0ed05cfccf3,
        192'hceace1cd8ccfcc6cbdcb4cacca3c9ac91c88c7fc76c6dc64,
        192'h4db4d24ca4c14b84af4a649d49448b48247947046745e455,
        192'h44c44343a43142841f41640d4043fb3f23e93e03d73cf3c6,
        192'h3bd3b43ab3a239939038737e37536c36335a35134833f336,
        192'h32d32431b3123093002f72ee2e52dd2d42cb2c22b92b02a7,
        192'h29e29528c28327a27126825f25624d24423b232229220217,
        192'h20e2051fc1f31ea1e21d91d01c71be1b51ac1a319a191188,
        192'h17f17616d16415b15214914013712e12511c11310a1010f8,
        192'h0f00e70de0d50cc0c30ba0b10a809f09608d08407b072069,
        192'h06005704e04503c03302a02101800f006ffdff5fecfe3fda,
        192'hfd1fc8fbffb6fadfa4f9bf92f89f80f77f6ef65f5cf53f4a,
        192'hf41f38f2ff26f1df14f0bf03efaef1ee8edfed6ecdec4ebb,
        192'heb2ea9ea0e97e8ee85e7ce73e6ae61e58e4fe46e3de34e2b,
        192'he22e19e10e08dffdf6dedde4ddbdd2dc9dc0db7daeda5d9c,
        192'hd93d8ad81d78d6fd66d5dd54d4bd42d39d30d27d1ed16d0d,
        192'hd04cfbcf2ce9ce0cd7ccecc5cbccb3caaca1c98c8fc86c7d,
        192'hc74c6bc62c59c50c47c3ec35c2cc23c1bc12c09c00bf7bee,
        192'h47f47746e46545c45444b44243943142841f41640d4053fc,
        192'h3f33ea3e23d93d03c73bf3b63ad3a439b39338a381378370,
        192'h36735e35534d34433b33232932131830f3062fe2f52ec2e3,
        192'h2db2d22c92c02b82af2a629d29428c28327a271269260257,
        192'h24e24623d23422b22221a2112081ff1f71ee1e51dc1d41cb,
        192'h1c21b91b01a819f19618d18517c17316a16215915014713e,
        192'h13612d12411b11310a1010f80f00e70de0d50cd0c40bb0b2,
        192'h0a90a109808f08607e07506c06305b05204904003702f026,
        192'h01d01400c003ffaff1fe9fe0fd7fcefc5fbdfb4fabfa2f9a,
        192'hf91f88f7ff77f6ef65f5cf53f4bf42f39f30f28f1ff16f0d,
        192'hf05efcef3eeaee2ed9ed0ec7ebeeb6eadea4e9be93e8ae81,
        192'he78e70e67e5ee55e4ce44e3be32e29e21e18e0fe06dfedf5,
        192'hdecde3ddadd2dc9dc0db7dafda6d9dd94d8cd83d7ad71d68,
        192'hd60d57d4ed45d3dd34d2bd22d1ad11d08cffcf7ceece5cdc,
        192'hcd3ccbcc2cb9cb0ca8c9fc96c8dc85c7cc73c6ac61c59c50,
        192'hc47c3ec36c2dc24c1bc13c0ac01bf8befbe7bdebd5bccbc4
    };
    (* rom_style = "bram" *) reg [11:0] normalization_rom [0:1023];
    integer table_index;
    initial begin
        for (table_index=0; table_index<1024; table_index=table_index+1) begin
            if (table_index<768)
                normalization_rom[table_index]=NORMALIZE_LUT[table_index*12 +: 12];
            else
                normalization_rom[table_index]=12'd0;
        end
    end

    // Only addresses 1024..1791 had nonzero case entries. Redirect the
    // unused low half to the zero fourth channel before the RAM register,
    // preserving the original zero/default behavior without an output mux.
    wire [9:0] read_address=address[10] ? address[9:0] : 10'd768;
    reg [11:0] table_value;
    always @(posedge clk) table_value<=normalization_rom[read_address];
    assign value={{4{table_value[11]}},table_value};
endmodule
