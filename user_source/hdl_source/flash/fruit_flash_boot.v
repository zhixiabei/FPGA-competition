// Read a fixed model from the independent user Flash, then verify DDR readback.
// model_ready is never asserted until BOTH CRCs match the generated model.
module fruit_flash_boot #(
    parameter [23:0] FLASH_ADDRESS=24'hf00000,
    parameter integer HALF_PERIOD=8,
    parameter integer TIMEOUT_CYCLES=66666667
)(
    input wire clk,rst_n,calibrated,memory_error,
    input wire [31:0] model_base,model_bytes,model_crc32,
    output reg model_ready,
    output wire mem_valid,mem_write,
    output wire [31:0] mem_addr,
    output wire [127:0] mem_data,
    input wire mem_ready,mem_rsp_valid,
    input wire [127:0] mem_rsp_data,
    output wire flash_cs_n,flash_sck,flash_mosi,
    input wire flash_miso,
    output wire [255:0] diagnostics
);
    localparam WAIT_CAL=0,READ_FLASH=1,WRITE_DDR=2,CHECK_FLASH=3,
        READ_DDR=4,WAIT_DDR=5,CRC_DDR=6,CHECK_DDR=7,COMPLETE=8,FAILED=9;
    reg [3:0] state;
    reg start;
    reg [31:0] offset,crc,timer,flash_crc,ddr_crc;
    reg [3:0] lane,crc_steps;
    reg [127:0] word_q;
    reg [7:0] error;
    wire stream_valid,stream_done;
    wire [7:0] stream_data;
    wire stream_ready=state==READ_FLASH && crc_steps==0;
    spi_flash_reader #(.HALF_PERIOD(HALF_PERIOD)) reader(
        .clk(clk),.rst_n(rst_n && state!=FAILED),.start(start),.address(FLASH_ADDRESS),.length(model_bytes[23:0]),
        .valid(stream_valid),.done(stream_done),.data(stream_data),.ready(stream_ready),
        .cs_n(flash_cs_n),.sck(flash_sck),.mosi(flash_mosi),.miso(flash_miso));
    assign mem_valid=state==WRITE_DDR || state==READ_DDR;
    assign mem_write=state==WRITE_DDR;
    assign mem_addr=model_base+offset;
    assign mem_data=word_q;
    // FBT1, version, state, error, ready, byte offset, flash CRC, DDR CRC,
    // model size, expected CRC, Flash address. All multi-byte fields little-endian.
    assign diagnostics={8'd0,FLASH_ADDRESS,model_crc32,model_bytes,ddr_crc,flash_crc,offset,
                        7'd0,model_ready,error,4'd0,state,8'd1,32'h31544246};
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=WAIT_CAL;start<=0;offset<=0;crc<=32'hffffffff;timer<=0;
            lane<=0;crc_steps<=0;word_q<=0;error<=0;model_ready<=0;flash_crc<=0;ddr_crc<=0;
        end else begin
            start<=0;
            if(state==WAIT_CAL || state==COMPLETE || state==FAILED ||
               (stream_valid && stream_ready) || (mem_valid && mem_ready) || mem_rsp_valid) timer<=0;
            else if(timer<TIMEOUT_CYCLES) timer<=timer+1'b1;
            if(crc_steps!=0) begin
                crc_steps<=crc_steps-1'b1;
                crc<=(crc>>1)^(crc[0] ? 32'hedb88320 : 0);
            end
            if(memory_error || (state!=WAIT_CAL && state!=FAILED && state!=COMPLETE &&
                              (!calibrated || timer==TIMEOUT_CYCLES))) begin
                state<=FAILED;model_ready<=0;error<=memory_error ? 4 : !calibrated ? 5 : 3;
            end else case(state)
                WAIT_CAL: if(calibrated) begin
                    if(model_bytes==0 || model_bytes[3:0]!=0 || model_bytes[31:24]!=0 ||
                       {1'b0,FLASH_ADDRESS}+{1'b0,model_bytes[23:0]}>25'h1000000) begin
                        state<=FAILED;error<=6;
                    end else begin start<=1;state<=READ_FLASH;end
                end
                READ_FLASH: if(stream_valid && stream_ready) begin
                    word_q<={stream_data,word_q[127:8]};
                    crc<=crc^{24'd0,stream_data};crc_steps<=8;
                    lane<=lane+1'b1;
                    if(lane==15) state<=WRITE_DDR;
                end
                WRITE_DDR: if(mem_ready) begin
                    if(offset+16==model_bytes) state<=CHECK_FLASH;
                    else begin offset<=offset+16;state<=READ_FLASH;end
                end
                CHECK_FLASH: if(crc_steps==0) begin
                    flash_crc<=~crc;
                    if(~crc!=model_crc32) begin error<=1;state<=FAILED;end
                    else begin crc<=32'hffffffff;offset<=0;state<=READ_DDR;end
                end
                READ_DDR: if(mem_ready) state<=WAIT_DDR;
                WAIT_DDR: if(mem_rsp_valid) begin word_q<=mem_rsp_data;lane<=0;state<=CRC_DDR;end
                CRC_DDR: if(crc_steps==0) begin
                    crc<=crc^{24'd0,word_q[7:0]};crc_steps<=8;word_q<=word_q>>8;
                    if(lane==15) begin
                        if(offset+16==model_bytes) state<=CHECK_DDR;
                        else begin offset<=offset+16;state<=READ_DDR;end
                    end else lane<=lane+1'b1;
                end
                CHECK_DDR: if(crc_steps==0) begin
                    ddr_crc<=~crc;
                    if(~crc==model_crc32) begin model_ready<=1;state<=COMPLETE;end
                    else begin error<=2;state<=FAILED;end
                end
                COMPLETE: if(!calibrated) begin model_ready<=0;error<=5;state<=FAILED;end
                default: begin end
            endcase
        end
    end
endmodule
