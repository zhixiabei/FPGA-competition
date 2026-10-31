// Temporary JTAG-loaded programmer. The model is embedded in its ERAM image.
// Programs only a completely blank range, or accepts an exact existing copy.
// There is deliberately NO erase command and NO access to configuration Flash.
module fruit_flash_programmer #(
    parameter [23:0] FLASH_ADDRESS=24'hf00000,
    parameter integer MODEL_BYTES=170752,
    parameter [31:0] MODEL_CRC32=32'h3a37bea7,
    parameter integer HALF_PERIOD=8,
    parameter integer POWERUP_CYCLES=1000000
)(
    input wire clk,rst_n,
    output wire [17:0] rom_address,
    input wire [7:0] rom_data,
    output reg cs_n,
    output wire sck,mosi,
    input wire miso,
    output wire [255:0] diagnostics,
    output wire finished,
    output wire [7:0] error_code
);
    localparam POWERUP=0,ID_COMMAND=1,ID_READ=2,ID_RESULT=3,
        SCAN_BEGIN=4,ADDRESS=5,SCAN_BYTE=6,SCAN_RESULT=7,SCAN_END=8,
        WREN=9,WREN_END=10,WEL_COMMAND=11,WEL_BYTE=12,WEL_RESULT=13,
        PROGRAM_BEGIN=14,PROGRAM_BYTE=15,PROGRAM_NEXT=16,PROGRAM_END=17,
        POLL_COMMAND=18,POLL_BYTE=19,POLL_RESULT=20,
        DONE=21,FAILED=22,PROGRAM_FETCH=23,BYTE_WAIT=30,GAP=31;
    reg [4:0] state,resume_state,gap_next,address_next;
    reg [31:0] offset;
    reg [23:0] addr_q,jedec;
    reg [1:0] index;
    reg [7:0] error,tx_data;
    reg [20:0] delay_count;
    reg [15:0] polls;
    reg start,all_blank,all_match,verify_pass;
    localparam [31:0] MODEL_SIZE=MODEL_BYTES;
    wire bus_done,bus_busy;
    wire [7:0] rx_data;
    assign rom_address=offset[17:0];
    assign finished=state==DONE;
    assign error_code=error;
    assign diagnostics={32'd0,8'd0,FLASH_ADDRESS,MODEL_CRC32,MODEL_SIZE,offset,8'd0,jedec,
                        7'd0,finished,error,3'd0,state,8'd1,32'h31475046};
    spi_flash_byte #(.HALF_PERIOD(HALF_PERIOD)) bus(
        .clk(clk),.rst_n(rst_n),.start(start),.tx_data(tx_data),
        .miso(miso),.sck(sck),.mosi(mosi),.busy(bus_busy),.done(bus_done),.rx_data(rx_data));
    task transfer;
        input [7:0] value;
        input [4:0] next_state;
        begin tx_data<=value;start<=1;resume_state<=next_state;state<=BYTE_WAIT;end
    endtask
    task pause_bus;
        input [4:0] next_state;
        begin cs_n<=1;delay_count<=16;gap_next<=next_state;state<=GAP;end
    endtask
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=POWERUP;resume_state<=0;gap_next<=0;address_next<=0;
            offset<=0;addr_q<=0;jedec<=0;index<=0;error<=0;tx_data<=0;
            delay_count<=POWERUP_CYCLES;polls<=0;start<=0;cs_n<=1;
            all_blank<=1;all_match<=1;verify_pass<=0;
        end else begin
            start<=0;
            case(state)
                POWERUP: if(delay_count==0) state<=ID_COMMAND;else delay_count<=delay_count-1'b1;
                ID_COMMAND: begin cs_n<=0;index<=0;transfer(8'h9f,ID_READ);end
                ID_READ: transfer(8'hff,ID_RESULT);
                ID_RESULT: begin
                    jedec<={jedec[15:0],rx_data};
                    if(index==2) begin
                        // N25Q128A 3.3 V, as fitted to U30 on the board schematic.
                        if({jedec[15:0],rx_data}!=24'h20ba18) begin error<=1;pause_bus(FAILED);end
                        else pause_bus(SCAN_BEGIN);
                    end else begin index<=index+1'b1;state<=ID_READ;end
                end
                SCAN_BEGIN: begin
                    cs_n<=0;offset<=0;addr_q<=FLASH_ADDRESS;index<=0;
                    all_blank<=1;all_match<=1;address_next<=SCAN_BYTE;transfer(8'h03,ADDRESS);
                end
                ADDRESS: begin
                    addr_q<={addr_q[15:0],8'd0};index<=index+1'b1;
                    transfer(addr_q[23:16],index==2 ? address_next : ADDRESS);
                end
                SCAN_BYTE: transfer(8'hff,SCAN_RESULT);
                SCAN_RESULT: begin
                    if(rx_data!=8'hff) all_blank<=0;
                    if(rx_data!=rom_data) all_match<=0;
                    if(offset+1==MODEL_BYTES) pause_bus(SCAN_END);
                    else begin offset<=offset+1'b1;state<=SCAN_BYTE;end
                end
                SCAN_END: begin
                    if(all_match) state<=DONE;
                    else if(verify_pass) begin error<=4;state<=FAILED;end
                    else if(!all_blank) begin error<=2;state<=FAILED;end
                    else begin offset<=0;state<=WREN;end
                end
                WREN: begin cs_n<=0;transfer(8'h06,WREN_END);end
                WREN_END: pause_bus(WEL_COMMAND);
                WEL_COMMAND: begin cs_n<=0;transfer(8'h05,WEL_BYTE);end
                WEL_BYTE: transfer(8'hff,WEL_RESULT);
                WEL_RESULT: begin
                    if(!rx_data[1] || rx_data[0]) begin error<=3;pause_bus(FAILED);end
                    else pause_bus(PROGRAM_BEGIN);
                end
                PROGRAM_BEGIN: begin
                    cs_n<=0;addr_q<=FLASH_ADDRESS+offset[23:0];index<=0;
                    address_next<=PROGRAM_BYTE;transfer(8'h02,ADDRESS);
                end
                PROGRAM_BYTE: transfer(rom_data,PROGRAM_NEXT);
                PROGRAM_NEXT: begin
                    offset<=offset+1'b1;
                    if(offset[7:0]==8'hff || offset+1==MODEL_BYTES) state<=PROGRAM_END;
                    else state<=PROGRAM_FETCH;
                end
                PROGRAM_FETCH: state<=PROGRAM_BYTE;
                PROGRAM_END: begin polls<=0;pause_bus(POLL_COMMAND);end
                POLL_COMMAND: begin cs_n<=0;transfer(8'h05,POLL_BYTE);end
                POLL_BYTE: transfer(8'hff,POLL_RESULT);
                POLL_RESULT: begin
                    polls<=polls+1'b1;
                    if(!rx_data[0]) begin
                        if(offset==MODEL_BYTES) begin verify_pass<=1;pause_bus(SCAN_BEGIN);end
                        else pause_bus(WREN);
                    end else if(polls==16'hffff) begin error<=5;pause_bus(FAILED);end
                    else pause_bus(POLL_COMMAND);
                end
                BYTE_WAIT: if(bus_done) state<=resume_state;
                GAP: if(delay_count==0) state<=gap_next;else delay_count<=delay_count-1'b1;
                default: cs_n<=1;
            endcase
        end
    end
endmodule
