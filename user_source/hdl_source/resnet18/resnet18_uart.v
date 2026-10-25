// 8N1 UART. Default clock is the existing 66.667 MHz DDR user clock.
module resnet18_uart #(
    parameter integer CLOCK_HZ=66666667, BAUD=921600
)(
    input wire clk,rst_n,rx,
    output wire tx,
    output reg rx_valid,rx_error,
    output reg [7:0] rx_data,
    input wire tx_valid,
    input wire [7:0] tx_data,
    output wire tx_ready
);
    localparam integer DIV=(CLOCK_HZ+BAUD/2)/BAUD;
    (* async_reg="true" *) reg rx_meta,rx_sync;
    reg [3:0] rbit,tbit;
    reg [15:0] rtick,ttick;
    reg rbusy,tbusy;
    reg [7:0] rshift;
    reg [9:0] tshift;
    assign tx=tbusy ? tshift[0] : 1'b1;
    assign tx_ready=!tbusy;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            rx_meta<=1;rx_sync<=1;rx_valid<=0;rx_error<=0;rx_data<=0;
            rbit<=0;rtick<=0;rbusy<=0;rshift<=0;
            tbit<=0;ttick<=0;tbusy<=0;tshift<=10'h3ff;
        end else begin
            rx_meta<=rx;rx_sync<=rx_meta;rx_valid<=0;rx_error<=0;
            if(!rbusy) begin
                if(!rx_sync) begin rbusy<=1;rtick<=DIV/2;rbit<=0;end
            end else if(rtick!=0) rtick<=rtick-1'b1;
            else begin
                rtick<=DIV-1;
                if(rbit==0) begin
                    if(rx_sync) rbusy<=0;else rbit<=1;
                end else if(rbit<=8) begin
                    rshift[rbit-1]<=rx_sync;rbit<=rbit+1'b1;
                end else begin
                    rbusy<=0;rx_data<=rshift;rx_valid<=rx_sync;rx_error<=!rx_sync;
                end
            end
            if(!tbusy) begin
                if(tx_valid) begin
                    tshift<={1'b1,tx_data,1'b0};ttick<=DIV-1;tbit<=0;tbusy<=1;
                end
            end else if(ttick!=0) ttick<=ttick-1'b1;
            else begin
                ttick<=DIV-1;tshift<={1'b1,tshift[9:1]};
                if(tbit==9) tbusy<=0;else tbit<=tbit+1'b1;
            end
        end
    end
endmodule
