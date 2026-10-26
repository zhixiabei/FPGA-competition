// KEY4 is active low. One debounced press toggles continuous recognition;
// release and long holds never produce additional toggles. Reset is stopped.
// LEVEL_CONTROL follows the debounced active-low input instead of toggling.
module handfixed_key_control #(
    parameter integer DEBOUNCE_CYCLES=1333334,
    parameter integer LEVEL_CONTROL=0
)(
    input wire clk,rst_n,key_n,
    output reg enabled
);
    localparam integer WIDTH=DEBOUNCE_CYCLES>1 ? $clog2(DEBOUNCE_CYCLES) : 1;
    (* keep="true", async_reg="true" *) reg key_meta;
    (* keep="true", async_reg="true" *) reg key_sync;
    reg stable;
    reg [WIDTH-1:0] count;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin key_meta<=1;key_sync<=1;end
        else begin key_meta<=key_n;key_sync<=key_meta;end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin enabled<=0;stable<=1;count<=0;end
        else if(key_sync==stable) count<=0;
        else if(count==DEBOUNCE_CYCLES-1) begin
            count<=0;stable<=key_sync;
            if(LEVEL_CONTROL!=0) enabled<=!key_sync;
            else if(!key_sync) enabled<=!enabled;
        end else count<=count+1'b1;
    end
endmodule
