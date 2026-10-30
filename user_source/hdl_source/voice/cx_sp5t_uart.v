// CX-SP5T command transport. Data byte 0 occupies data_bytes[7:0].
// done means that the final UART stop bit was sent, not that audio finished.
module cx_sp5t_uart #(
    parameter integer CLOCK_HZ = 50000000,
    parameter integer BAUD = 9600,
    parameter [15:0] DEVICE_ADDRESS = 16'hffff
)(
    input wire clk, rst_n,
    input wire rx,
    output wire tx,
    input wire start,
    input wire [7:0] command,
    input wire [4:0] data_count,
    input wire [199:0] data_bytes,
    output wire ready,
    output reg done, invalid_command,
    output reg status_valid,
    output reg [1:0] playback_status
);
    localparam IDLE=0, SEND=1, DRAIN=2;
    reg [1:0] state;
    reg [7:0] opcode, checksum;
    reg [4:0] count;
    reg [5:0] position;
    reg [199:0] payload;
    wire uart_ready, rx_valid, rx_error;
    wire [7:0] rx_byte;
    reg [7:0] tx_byte;
    wire tx_valid = state==SEND && uart_ready;
    assign ready = state==IDLE;

    resnet18_uart #(.CLOCK_HZ(CLOCK_HZ),.BAUD(BAUD)) u_uart(
        .clk(clk),.rst_n(rst_n),.rx(rx),.tx(tx),
        .rx_valid(rx_valid),.rx_error(rx_error),.rx_data(rx_byte),
        .tx_valid(tx_valid),.tx_data(tx_byte),.tx_ready(uart_ready));

    always @* begin
        case(position)
            0: tx_byte=8'hfe;
            1: tx_byte=8'd7+count;
            2: tx_byte=DEVICE_ADDRESS[15:8];
            3: tx_byte=DEVICE_ADDRESS[7:0];
            4: tx_byte=opcode;
            default: begin
                if(position==5+count) tx_byte=checksum;
                else if(position==6+count) tx_byte=8'hbe;
                else tx_byte=payload[(position-5)*8+:8];
            end
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;opcode<=0;checksum<=0;count<=0;
            position<=0;payload<=0;done<=0;invalid_command<=0;
        end else begin
            done<=0;invalid_command<=0;
            case(state)
                IDLE: if(start) begin
                    if(data_count>25 || (command==8'h1b && data_count==0))
                        invalid_command<=1;
                    else begin
                        opcode<=command;count<=data_count;payload<=data_bytes;
                        position<=0;checksum<=0;state<=SEND;
                    end
                end
                SEND: if(tx_valid) begin
                    if(position<5+count) checksum<=checksum+tx_byte;
                    if(position==6+count) state<=DRAIN;
                    else position<=position+1'b1;
                end
                DRAIN: if(uart_ready) begin done<=1;state<=IDLE;end
                default: state<=IDLE;
            endcase
        end
    end

    // Only the fixed eight-byte 0x01 status response is needed here.
    // Check the returned device address when using a unicast command address.
    reg [3:0] rx_position;
    reg [7:0] rx_sum, returned_status;
    reg rx_good;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            rx_position<=0;rx_sum<=0;returned_status<=0;
            rx_good<=0;status_valid<=0;playback_status<=0;
        end else begin
            status_valid<=0;
            if(rx_error) rx_position<=0;
            else if(rx_valid) begin
                if(rx_position==0) begin
                    if(rx_byte==8'hfe) begin
                        rx_position<=1;rx_sum<=8'hfe;rx_good<=1;
                    end
                end else begin
                    if(rx_position<6) rx_sum<=rx_sum+rx_byte;
                    case(rx_position)
                        1: if(rx_byte!=8'd8) begin
                            rx_position<=0;rx_good<=0;
                        end
                        2: if(DEVICE_ADDRESS!=16'hffff && rx_byte!=DEVICE_ADDRESS[15:8]) rx_good<=0;
                        3: if(DEVICE_ADDRESS!=16'hffff && rx_byte!=DEVICE_ADDRESS[7:0]) rx_good<=0;
                        4: if(rx_byte!=8'h01) rx_good<=0;
                        5: begin returned_status<=rx_byte;if(rx_byte>2) rx_good<=0;end
                        6: if(rx_byte!=rx_sum) rx_good<=0;
                        7: begin
                            rx_position<=0;
                            if(rx_byte==8'hbe && rx_good) begin
                                playback_status<=returned_status[1:0];status_valid<=1;
                            end
                        end
                    endcase
                    if(rx_position!=7 && !(rx_position==1 && rx_byte!=8'd8))
                        rx_position<=rx_position+1'b1;
                end
            end
        end
    end
endmodule
