// Say digits individually: 1250 g / 1250 fen -> 1.250 kg / 12.50 yuan.
// Files: 01..10 = zero..nine, 11 = kg, 12 = yuan, 13 = decimal point.
// Add /ZH/13.mp3 saying "dian" before testing decimal announcements.
module scale_voice_phrase #(
    parameter [7:0] CLIP_KG=8'd11,CLIP_YUAN=8'd12,CLIP_POINT=8'd13,
    parameter integer VALUE_WIDTH=24
)(
    input wire clk,rst_n,start,
    input wire [23:0] weight_g,amount_fen,
    output wire ready,
    output reg done,
    output reg [4:0] clip_count,
    output wire [199:0] clips
);
    localparam integer DECIMAL_DIGITS=((VALUE_WIDTH*30103)/100000+1)>4 ?
        (VALUE_WIDTH*30103)/100000+1 : 4;
    localparam integer BCD_WIDTH=DECIMAL_DIGITS*4;
    localparam integer MAX_CLIPS=2*DECIMAL_DIGITS+4;
    localparam integer MAX_UNIT=CLIP_KG>CLIP_YUAN ? CLIP_KG:CLIP_YUAN;
    localparam integer MAX_CLIP=MAX_UNIT>CLIP_POINT ? MAX_UNIT:CLIP_POINT;
    localparam integer CLIP_BITS=MAX_CLIP>10 ? $clog2(MAX_CLIP+1):4;
    localparam integer COUNT_LIMIT=VALUE_WIDTH>MAX_CLIPS ? VALUE_WIDTH:MAX_CLIPS+1;
    localparam integer COUNT_BITS=COUNT_LIMIT>1 ? $clog2(COUNT_LIMIT):1;
    localparam IDLE=0,CONVERT=1,DIGIT=2,POINT=3,UNIT=4,ALIGN=5;
    reg [2:0] state;
    reg [VALUE_WIDTH-1:0] value_shift,amount_saved;
    reg [BCD_WIDTH-1:0] bcd,adjusted;
    reg [CLIP_BITS*MAX_CLIPS-1:0] clip_buffer;
    reg [COUNT_BITS-1:0] bit_count;
    reg [2:0] digit_index;
    reg amount_phase,started;
    integer k;
    wire [3:0] digit=bcd[BCD_WIDTH-1:BCD_WIDTH-4];
    wire [2:0] boundary=amount_phase ? 3'd2:3'd3;
    wire [7:0] digit_clip={4'd0,digit}+8'd1;
    wire [7:0] unit_clip=amount_phase ? CLIP_YUAN:CLIP_KG;
    assign ready=state==IDLE;
    genvar g;
    generate for(g=0;g<25;g=g+1) begin: expand_clips
        if(g<MAX_CLIPS) begin: used
            assign clips[g*8+:8]={{(8-CLIP_BITS){1'b0}},clip_buffer[g*CLIP_BITS+:CLIP_BITS]};
        end else begin: unused
            assign clips[g*8+:8]=8'd0;
        end
    end endgenerate
    always @* begin
        adjusted=bcd;
        for(k=0;k<DECIMAL_DIGITS;k=k+1) begin
            if(bcd[k*4+:4]>=5) adjusted[k*4+:4]=bcd[k*4+:4]+4'd3;
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;value_shift<=0;amount_saved<=0;bcd<=0;clip_buffer<=0;
            bit_count<=0;digit_index<=0;amount_phase<=0;started<=0;
            done<=0;clip_count<=0;
        end else begin
            done<=0;
            case(state)
                IDLE: if(start) begin
                    value_shift<=weight_g[VALUE_WIDTH-1:0];
                    amount_saved<=amount_fen[VALUE_WIDTH-1:0];
                    bcd<=0;bit_count<=0;clip_buffer<=0;
                    clip_count<=0;amount_phase<=0;started<=0;state<=CONVERT;
                end
                CONVERT: begin
                    bcd<={adjusted[BCD_WIDTH-2:0],value_shift[VALUE_WIDTH-1]};
                    value_shift<=value_shift<<1;
                    if(bit_count==VALUE_WIDTH-1) begin digit_index<=DECIMAL_DIGITS-1;state<=DIGIT;end
                    else bit_count<=bit_count+1'b1;
                end
                DIGIT: begin
                    bcd<=bcd<<4;
                    if(started || digit!=0 || digit_index<=boundary) begin
                        clip_buffer<={digit_clip[CLIP_BITS-1:0],
                            clip_buffer[CLIP_BITS*MAX_CLIPS-1:CLIP_BITS]};
                        clip_count<=clip_count+1'b1;started<=1;
                    end
                    if(digit_index==0) state<=UNIT;
                    else begin
                        digit_index<=digit_index-1'b1;
                        if(digit_index==boundary) state<=POINT;
                    end
                end
                POINT: begin
                    clip_buffer<={CLIP_POINT[CLIP_BITS-1:0],
                        clip_buffer[CLIP_BITS*MAX_CLIPS-1:CLIP_BITS]};
                    clip_count<=clip_count+1'b1;state<=DIGIT;
                end
                UNIT: begin
                    clip_buffer<={unit_clip[CLIP_BITS-1:0],
                        clip_buffer[CLIP_BITS*MAX_CLIPS-1:CLIP_BITS]};
                    clip_count<=clip_count+1'b1;
                    if(amount_phase) begin bit_count<=clip_count+1'b1;state<=ALIGN;end
                    else begin
                        amount_phase<=1;started<=0;value_shift<=amount_saved;
                        bcd<=0;bit_count<=0;state<=CONVERT;
                    end
                end
                // Fixed shifts avoid a wide variable-indexed write decoder.
                ALIGN: begin
                    if(bit_count==MAX_CLIPS) begin done<=1;state<=IDLE;end
                    else begin
                        clip_buffer<=clip_buffer>>CLIP_BITS;
                        bit_count<=bit_count+1'b1;
                    end
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
