// Keep K1's display request while SW3 selects camera handwriting.
// The existing frame configuration mailbox carries both switch levels.
module signature_control #(parameter integer DEBOUNCE_CYCLES=1000000)(
    input wire I_clk,I_rst_n,I_write_switch,I_pause_switch,
    input wire [3:0] I_effect_mode,
    input wire [7:0] I_effect_param,
    output wire [11:0] O_effect_config
);
    wire writing,paused;
    signature_switch_level #(.CYCLES(DEBOUNCE_CYCLES)) sw3 (
        .clk(I_clk),.rst_n(I_rst_n),.switch_in(I_write_switch),.level(writing));
    signature_switch_level #(.CYCLES(DEBOUNCE_CYCLES)) sw4 (
        .clk(I_clk),.rst_n(I_rst_n),.switch_in(I_pause_switch),.level(paused));
    assign O_effect_config=writing ? {4'd13,7'd0,paused} :
        {I_effect_mode,I_effect_param};
endmodule

module signature_switch_level #(parameter integer CYCLES=1000000)(
    input wire clk,rst_n,switch_in,output reg level
);
    localparam integer CW=CYCLES>1 ? $clog2(CYCLES) : 1;
    (* async_reg="true" *) reg meta,sync;
    reg [CW-1:0] count;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin meta<=0;sync<=0;level<=0;count<=0;end
        else begin
            meta<=switch_in;sync<=meta;
            if(sync==level) count<=0;
            else if(count==CYCLES-1) begin count<=0;level<=sync;end
            else count<=count+1'b1;
        end
    end
endmodule
