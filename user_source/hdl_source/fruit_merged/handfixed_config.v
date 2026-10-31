// Generated; a matching model CRC is required before inference.
module handfixed_config(output wire [31:0] model_base,model_bytes,model_crc32,
output wire [15:0] roi_x,roi_y,roi_side);
assign model_base=32'h00c00000;
assign model_bytes=32'h00029b00;
assign model_crc32=32'h3a37bea7;
assign roi_x=16'd400;
assign roi_y=16'd120;
assign roi_side=16'd480;
endmodule
