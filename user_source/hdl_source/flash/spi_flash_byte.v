// SPI mode 0, one byte per request. The caller owns chip select.
module spi_flash_byte #(parameter integer HALF_PERIOD=8)(
    input wire clk,rst_n,start,
    input wire [7:0] tx_data,
    input wire miso,
    output reg sck,mosi,busy,done,
    output reg [7:0] rx_data
);
    reg [7:0] tx_shift,rx_shift;
    reg [2:0] bit_index;
    reg [7:0] divider;
    // HALF_PERIOD >= 4: board-returned data settles through two registers
    // before the next SPI rising-edge sample. Production uses eight clocks.
    (* async_reg="true" *) reg miso_meta,miso_sync;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            sck<=0;mosi<=0;busy<=0;done<=0;rx_data<=0;
            tx_shift<=0;rx_shift<=0;bit_index<=0;divider<=0;miso_meta<=1;miso_sync<=1;
        end else begin
            done<=0;
            miso_meta<=miso;miso_sync<=miso_meta;
            if(!busy) begin
                sck<=0;
                if(start) begin
                    tx_shift<=tx_data;mosi<=tx_data[7];rx_shift<=0;
                    bit_index<=7;divider<=HALF_PERIOD-1;busy<=1;
                end
            end else if(divider!=0) divider<=divider-1'b1;
            else begin
                divider<=HALF_PERIOD-1;
                if(!sck) begin sck<=1;rx_shift<={rx_shift[6:0],miso_sync};end
                else begin
                    sck<=0;
                    if(bit_index==0) begin busy<=0;done<=1;rx_data<=rx_shift;end
                    else begin
                        bit_index<=bit_index-1'b1;
                        tx_shift<={tx_shift[6:0],1'b0};mosi<=tx_shift[6];
                    end
                end
            end
        end
    end
endmodule
