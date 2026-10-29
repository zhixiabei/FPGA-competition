// Read-only UART status. R18S returns the caller's 32 bytes followed by CRC32.
// R18F returns Flash diagnostics. This module accepts no weight/write commands.
module flash_status_uart #(parameter integer CLOCK_HZ=66666667)(
    input wire clk,rst_n,rx,
    output wire tx,
    input wire [255:0] runtime_status,flash_status
);
    wire rx_valid,rx_error,tx_ready;
    wire [7:0] rx_data;
    reg tx_valid;
    reg [7:0] tx_data;
    resnet18_uart #(.CLOCK_HZ(CLOCK_HZ)) uart(
        .clk(clk),.rst_n(rst_n),.rx(rx),.tx(tx),.rx_valid(rx_valid),.rx_error(rx_error),
        .rx_data(rx_data),.tx_valid(tx_valid),.tx_data(tx_data),.tx_ready(tx_ready));
    reg [2:0] magic;
    reg sending;
    reg [5:0] index;
    reg [255:0] shift;
    reg [31:0] crc;
    reg [3:0] crc_steps;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin magic<=0;sending<=0;index<=0;shift<=0;crc<=32'hffffffff;crc_steps<=0;tx_valid<=0;tx_data<=0;end
        else begin
            tx_valid<=0;
            if(crc_steps!=0) begin
                crc_steps<=crc_steps-1'b1;crc<=(crc>>1)^(crc[0] ? 32'hedb88320 : 0);
            end
            if(!sending) begin
                if(rx_error) magic<=0;
                else if(rx_valid) case(magic)
                    0:magic<=rx_data=="R" ? 1 : 0;
                    1:magic<=rx_data=="1" ? 2 : 0;
                    2:magic<=rx_data=="8" ? 3 : 0;
                    3:begin
                        magic<=0;
                        if(rx_data=="S" || rx_data=="F") begin
                            shift<=rx_data=="S" ? runtime_status : flash_status;
                            sending<=1;index<=0;crc<=32'hffffffff;crc_steps<=0;
                        end
                    end
                endcase
            end else if(tx_ready && !tx_valid && crc_steps==0) begin
                tx_valid<=1;
                if(index<32) begin
                    tx_data<=shift[7:0];shift<=shift>>8;crc<=crc^{24'd0,shift[7:0]};crc_steps<=8;
                end else begin tx_data<=~crc[7:0];crc<=crc>>8;end
                if(index==35) sending<=0;else index<=index+1'b1;
            end
        end
    end
endmodule
