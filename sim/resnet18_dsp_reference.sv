// Fast arithmetic model for long scheduler simulations only. Hardware uses
// resnet_ph1p_dsp.v and is checked separately against the vendor primitives.
module resnet_ph1p_dsp #(parameter integer ACTIVATION_WIDTH=8,WEIGHT_WIDTH=8)(
    input wire clk,rst_n,enable,
    input wire signed [ACTIVATION_WIDTH-1:0] activation,
    input wire signed [WEIGHT_WIDTH-1:0] weight,
    input wire [10:0] opctrl,input wire [6:0] muxctrl,
    output reg signed [53:0] result);
    wire signed [53:0] product=activation*weight;
    always @(posedge clk) begin
        if(!rst_n) result<=0;
        else if(enable) result<=opctrl==11'h404 ? product : result+product;
    end
endmodule
