// Active-low, 20 ms press/release debounce; one event per complete press.
module checkout_key #(
    parameter integer DEBOUNCE_CYCLES=1333334
)(input wire clk,rst_n,key_n,output reg pressed);
    (* async_reg="true" *) reg key_meta,key_sync;
    reg stable;
    localparam integer COUNT_BITS=DEBOUNCE_CYCLES>1 ? $clog2(DEBOUNCE_CYCLES) : 1;
    reg [COUNT_BITS-1:0] count;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin key_meta<=1;key_sync<=1;stable<=1;count<=0;pressed<=0;end
        else begin
            key_meta<=key_n;key_sync<=key_meta;pressed<=0;
            if(key_sync==stable) count<=0;
            else if(count==DEBOUNCE_CYCLES-1) begin
                stable<=key_sync;count<=0;pressed<=!key_sync;
            end else count<=count+1'b1;
        end
    end
endmodule
