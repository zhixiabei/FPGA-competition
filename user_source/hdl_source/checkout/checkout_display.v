// Periodic decimal snapshots for the HDMI weight/price panel.
// Physical seven-segment scanning and segment encoding have been removed.
module checkout_display #(
    parameter integer UPDATE_CYCLES=266664
)(
    input wire clk,rst_n,
    input wire [13:0] weight_g,total_fen,
    input wire weight_valid,price_valid,
    output reg [15:0] weight_bcd,price_bcd,
    output wire weight_bcd_valid,price_bcd_valid
);
    localparam integer UPDATE_BITS=UPDATE_CYCLES>1 ? $clog2(UPDATE_CYCLES) : 1;
    reg [UPDATE_BITS-1:0] update_count;
    reg shown_weight_valid,shown_price_valid;
    reg [31:0] conversion;
    reg [27:0] binary;
    reg [4:0] bit_count;
    reg converting,pending_weight_valid,pending_price_valid;
    reg [31:0] corrected;
    integer j;
    assign weight_bcd_valid=shown_weight_valid;
    assign price_bcd_valid=shown_price_valid;
    always @* begin
        corrected=conversion;
        for(j=0;j<8;j=j+1)
            if(conversion[j*4+:4]>=5) corrected[j*4+:4]=conversion[j*4+:4]+4'd3;
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            update_count<=0;
            weight_bcd<=0;price_bcd<=0;shown_weight_valid<=0;shown_price_valid<=0;
            conversion<=0;binary<=0;bit_count<=0;converting<=0;
            pending_weight_valid<=0;pending_price_valid<=0;
        end else begin
            if(converting) begin
                conversion<={corrected[30:16],binary[27],corrected[14:0],binary[13]};
                binary<={binary[26:14],1'b0,binary[12:0],1'b0};
                if(bit_count==13) begin
                    weight_bcd<={corrected[30:16],binary[27]};price_bcd<={corrected[14:0],binary[13]};
                    shown_weight_valid<=pending_weight_valid;shown_price_valid<=pending_price_valid;converting<=0;
                end else bit_count<=bit_count+1'b1;
            end
            if(update_count==UPDATE_CYCLES-1) update_count<=0;
            else update_count<=update_count+1'b1;
            if(update_count==0 && !converting) begin
                conversion<=0;binary<={weight_g,total_fen};bit_count<=0;converting<=1;
                pending_weight_valid<=weight_valid;pending_price_valid<=price_valid;
            end
        end
    end
endmodule
