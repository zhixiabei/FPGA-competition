// Standard 03h read. No write, erase, status-register or mode-changing commands.
module spi_flash_reader #(parameter integer HALF_PERIOD=8)(
    input wire clk,rst_n,start,
    input wire [23:0] address,length,
    output reg valid,done,
    output reg [7:0] data,
    input wire ready,
    output reg cs_n,
    output wire sck,mosi,
    input wire miso
);
    localparam IDLE=0,SEND=1,WAIT_BYTE=2,DELIVER=3,FINISH=4;
    reg [2:0] state,header;
    reg [23:0] addr_q,remaining;
    wire byte_done,byte_busy;
    wire [7:0] rx_byte;
    wire [7:0] tx_byte=header==0 ? 8'h03 : header==1 ? addr_q[23:16] :
        header==2 ? addr_q[15:8] : header==3 ? addr_q[7:0] : 8'hff;
    spi_flash_byte #(.HALF_PERIOD(HALF_PERIOD)) bus(
        .clk(clk),.rst_n(rst_n),.start(state==SEND),.tx_data(tx_byte),
        .miso(miso),.sck(sck),.mosi(mosi),.busy(byte_busy),.done(byte_done),.rx_data(rx_byte));
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin state<=IDLE;header<=0;addr_q<=0;remaining<=0;valid<=0;done<=0;data<=0;cs_n<=1;end
        else begin
            done<=0;
            case(state)
                IDLE: if(start && length!=0) begin
                    addr_q<=address;remaining<=length;header<=0;cs_n<=0;state<=SEND;
                end
                SEND: state<=WAIT_BYTE;
                WAIT_BYTE: if(byte_done) begin
                    if(header<4) begin header<=header+1'b1;state<=SEND;end
                    else begin data<=rx_byte;valid<=1;state<=DELIVER;end
                end
                DELIVER: if(ready) begin
                    valid<=0;remaining<=remaining-1'b1;
                    if(remaining==1) begin cs_n<=1;state<=FINISH;end
                    else state<=SEND;
                end
                FINISH: begin done<=1;state<=IDLE;end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
