// Board P04_DIG_LED: active-low PNP selects S[0..7], active-low a..g,dp D[0..7].
// S0..3: x.xxx kg; S4..7: xx.xx yuan. Invalid fields show ----.
module checkout_display #(
    parameter integer SLOT_CYCLES=33333
)(
    input wire clk,rst_n,
    input wire [13:0] weight_g,total_fen,
    input wire weight_valid,price_valid,
    output reg [15:0] weight_bcd,price_bcd,
    output wire weight_bcd_valid,price_bcd_valid,
    output reg [7:0] seg_n,sel_n
);
    localparam integer SLOT_BITS=SLOT_CYCLES>1 ? $clog2(SLOT_CYCLES) : 1;
    reg [SLOT_BITS-1:0] slot_count;
    reg [2:0] digit;
    reg shown_weight_valid,shown_price_valid;
    reg [31:0] conversion;
    reg [27:0] binary;
    reg [4:0] bit_count;
    reg converting,pending_weight_valid,pending_price_valid;
    reg [31:0] corrected;
    reg [3:0] nibble;
    reg [7:0] encoded;
    reg valid_digit;
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
            slot_count<=0;digit<=7;sel_n<=8'hff;seg_n<=8'hff;
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
            if(slot_count==SLOT_CYCLES-1) begin
                slot_count<=0;sel_n<=8'hff;seg_n<=8'hff;digit<=digit+1'b1;
                if(digit==7) begin
                    conversion<=0;binary<={weight_g,total_fen};bit_count<=0;converting<=1;
                    pending_weight_valid<=weight_valid;pending_price_valid<=price_valid;
                end
            end else begin
                slot_count<=slot_count+1'b1;
                if(slot_count==32) seg_n<=encoded;
                if(slot_count==33) sel_n<=~(8'b1<<digit);
            end
        end
    end
    always @* begin
        valid_digit=digit<4 ? shown_weight_valid : shown_price_valid;
        case(digit)
            0:nibble=weight_bcd[15:12];1:nibble=weight_bcd[11:8];
            2:nibble=weight_bcd[7:4];3:nibble=weight_bcd[3:0];
            4:nibble=price_bcd[15:12];5:nibble=price_bcd[11:8];
            6:nibble=price_bcd[7:4];default:nibble=price_bcd[3:0];
        endcase
        case(nibble)
            0:encoded=8'hc0;1:encoded=8'hf9;2:encoded=8'ha4;3:encoded=8'hb0;
            4:encoded=8'h99;5:encoded=8'h92;6:encoded=8'h82;7:encoded=8'hf8;
            8:encoded=8'h80;9:encoded=8'h90;default:encoded=8'hbf;
        endcase
        if(!valid_digit) encoded=8'hbf;
        else if(digit==0 || digit==5) encoded[7]=0;
    end
endmodule
