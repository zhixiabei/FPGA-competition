// Say digits individually: 1250 g / 1250 fen -> 1.250 kg / 12.50 yuan.
// Files: 01..10 = zero..nine, 11 = kg, 12 = yuan, 13 = decimal point.
// Add /ZH/13.mp3 saying "dian" before testing decimal announcements.
module scale_voice_phrase #(
    parameter [7:0] CLIP_KG=8'd11,CLIP_YUAN=8'd12,CLIP_POINT=8'd13,
    parameter integer VALUE_WIDTH=24,
    // Five digits cover every 14-bit input (0..16383), including all valid quotes.
    parameter integer DECIMAL_DIGITS=8
)(
    input wire clk,rst_n,start,
    input wire [VALUE_WIDTH-1:0] weight_g,amount_fen,
    output wire ready,
    output reg done,
    output reg [4:0] clip_count,
    output wire [199:0] clips
);
    localparam IDLE=0,CONVERT=1,DIGIT=2,POINT=3,UNIT=4;
    reg [2:0] state;
    localparam integer BCD_BITS=DECIMAL_DIGITS*4;
    localparam integer MAX_CLIPS=2*DECIMAL_DIGITS+4;
    localparam integer CLIP_BITS=(CLIP_KG>15 || CLIP_YUAN>15 || CLIP_POINT>15) ? 8:4;
    reg [VALUE_WIDTH-1:0] weight_shift,amount_shift;
    reg [BCD_BITS-1:0] weight_bcd,amount_bcd;
    reg [MAX_CLIPS*CLIP_BITS-1:0] clip_storage;
    reg [4:0] bit_count;
    reg [2:0] digit_index;
    reg amount_phase,started;
    reg [BCD_BITS-1:0] weight_adjusted,amount_adjusted;
    integer k;
    wire [3:0] digit=digit_index>=DECIMAL_DIGITS ? 4'd0:
        amount_phase ? amount_bcd[digit_index*4+:4]:weight_bcd[digit_index*4+:4];
    wire [2:0] boundary=amount_phase ? 3'd2:3'd3;
    assign ready=state==IDLE;
    genvar clip_index;
    generate for(clip_index=0;clip_index<25;clip_index=clip_index+1) begin: expand_clips
        if(clip_index<MAX_CLIPS)
            assign clips[clip_index*8+:8]=clip_storage[clip_index*CLIP_BITS+:CLIP_BITS];
        else assign clips[clip_index*8+:8]=8'd0;
    end endgenerate
    always @* begin
        weight_adjusted=weight_bcd;amount_adjusted=amount_bcd;
        for(k=0;k<DECIMAL_DIGITS;k=k+1) begin
            if(weight_bcd[k*4+:4]>=5) weight_adjusted[k*4+:4]=weight_bcd[k*4+:4]+4'd3;
            if(amount_bcd[k*4+:4]>=5) amount_adjusted[k*4+:4]=amount_bcd[k*4+:4]+4'd3;
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;weight_shift<=0;amount_shift<=0;weight_bcd<=0;amount_bcd<=0;
            bit_count<=0;digit_index<=0;amount_phase<=0;started<=0;
            done<=0;clip_count<=0;clip_storage<=0;
        end else begin
            done<=0;
            case(state)
                IDLE: if(start) begin
                    weight_shift<=weight_g;amount_shift<=amount_fen;
                    weight_bcd<=0;amount_bcd<=0;bit_count<=0;
                    clip_count<=0;clip_storage<=0;amount_phase<=0;started<=0;state<=CONVERT;
                end
                CONVERT: begin
                    // Keep the original 24-cycle schedule and leading zero scans.
                    // This makes the optimized controller UART-cycle equivalent.
                    if(bit_count>=24-VALUE_WIDTH) begin
                        weight_bcd<={weight_adjusted[BCD_BITS-2:0],weight_shift[VALUE_WIDTH-1]};
                        amount_bcd<={amount_adjusted[BCD_BITS-2:0],amount_shift[VALUE_WIDTH-1]};
                        weight_shift<=weight_shift<<1;
                        amount_shift<=amount_shift<<1;
                    end
                    if(bit_count==23) begin digit_index<=7;state<=DIGIT;end
                    else bit_count<=bit_count+1'b1;
                end
                DIGIT: begin
                    if(started || digit!=0 || digit_index<=boundary) begin
                        clip_storage[clip_count*CLIP_BITS+:CLIP_BITS]<={4'd0,digit}+8'd1;
                        clip_count<=clip_count+1'b1;started<=1;
                    end
                    if(digit_index==0) state<=UNIT;
                    else begin
                        digit_index<=digit_index-1'b1;
                        if(digit_index==boundary) state<=POINT;
                    end
                end
                POINT: begin
                    clip_storage[clip_count*CLIP_BITS+:CLIP_BITS]<=CLIP_POINT;clip_count<=clip_count+1'b1;state<=DIGIT;
                end
                UNIT: begin
                    clip_storage[clip_count*CLIP_BITS+:CLIP_BITS]<=amount_phase ? CLIP_YUAN:CLIP_KG;
                    clip_count<=clip_count+1'b1;
                    if(amount_phase) begin done<=1;state<=IDLE;end
                    else begin amount_phase<=1;started<=0;digit_index<=7;state<=DIGIT;end
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
