// Say digits individually: 1250 g / 1250 fen -> 1.250 kg / 12.50 yuan.
// Files: 01..10 = zero..nine, 11 = kg, 12 = yuan, 13 = decimal point.
// Add /ZH/13.mp3 saying "dian" before testing decimal announcements.
module scale_voice_phrase #(
    parameter [7:0] CLIP_KG=8'd11,CLIP_YUAN=8'd12,CLIP_POINT=8'd13
)(
    input wire clk,rst_n,start,
    input wire [23:0] weight_g,amount_fen,
    output wire ready,
    output reg done,
    output reg [4:0] clip_count,
    output reg [199:0] clips
);
    localparam IDLE=0,CONVERT=1,DIGIT=2,POINT=3,UNIT=4;
    reg [2:0] state;
    reg [23:0] weight_shift,amount_shift;
    reg [31:0] weight_bcd,amount_bcd;
    reg [4:0] bit_count;
    reg [2:0] digit_index;
    reg amount_phase,started;
    reg [31:0] weight_adjusted,amount_adjusted;
    integer k;
    wire [3:0] digit=amount_phase ? amount_bcd[digit_index*4+:4]:weight_bcd[digit_index*4+:4];
    wire [2:0] boundary=amount_phase ? 3'd2:3'd3;
    assign ready=state==IDLE;
    always @* begin
        weight_adjusted=weight_bcd;amount_adjusted=amount_bcd;
        for(k=0;k<8;k=k+1) begin
            if(weight_bcd[k*4+:4]>=5) weight_adjusted[k*4+:4]=weight_bcd[k*4+:4]+4'd3;
            if(amount_bcd[k*4+:4]>=5) amount_adjusted[k*4+:4]=amount_bcd[k*4+:4]+4'd3;
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;weight_shift<=0;amount_shift<=0;weight_bcd<=0;amount_bcd<=0;
            bit_count<=0;digit_index<=0;amount_phase<=0;started<=0;
            done<=0;clip_count<=0;clips<=0;
        end else begin
            done<=0;
            case(state)
                IDLE: if(start) begin
                    weight_shift<=weight_g;amount_shift<=amount_fen;
                    weight_bcd<=0;amount_bcd<=0;bit_count<=0;
                    clip_count<=0;clips<=0;amount_phase<=0;started<=0;state<=CONVERT;
                end
                CONVERT: begin
                    weight_bcd<={weight_adjusted[30:0],weight_shift[23]};
                    amount_bcd<={amount_adjusted[30:0],amount_shift[23]};
                    weight_shift<={weight_shift[22:0],1'b0};
                    amount_shift<={amount_shift[22:0],1'b0};
                    if(bit_count==23) begin digit_index<=7;state<=DIGIT;end
                    else bit_count<=bit_count+1'b1;
                end
                DIGIT: begin
                    if(started || digit!=0 || digit_index<=boundary) begin
                        clips[clip_count*8+:8]<={4'd0,digit}+8'd1;
                        clip_count<=clip_count+1'b1;started<=1;
                    end
                    if(digit_index==0) state<=UNIT;
                    else begin
                        digit_index<=digit_index-1'b1;
                        if(digit_index==boundary) state<=POINT;
                    end
                end
                POINT: begin
                    clips[clip_count*8+:8]<=CLIP_POINT;clip_count<=clip_count+1'b1;state<=DIGIT;
                end
                UNIT: begin
                    clips[clip_count*8+:8]<=amount_phase ? CLIP_YUAN:CLIP_KG;
                    clip_count<=clip_count+1'b1;
                    if(amount_phase) begin done<=1;state<=IDLE;end
                    else begin amount_phase<=1;started<=0;digit_index<=7;state<=DIGIT;end
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
