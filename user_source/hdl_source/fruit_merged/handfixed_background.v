// RGB128: 32x16 RGB555 samples in the SAME 2048-byte ERAM as before.
// Two atomic reference banks. Ignore bounded neutral offsets / proportional
// RGB illumination changes; NEVER learn a stationary fruit while running.
// Two complete scans confirm entry/exit. Serial shift/add uses no DSP.
module handfixed_background #(
    parameter integer PIXEL_DELTA=3, // RGB555 units, approximately 24/255
    parameter integer ENTER_PIXELS=32,
    parameter integer EXIT_PIXELS=32
)(
    input wire clk,rst_n,run_enabled,
    input wire start,scan_background,done,
    input wire pixel_valid,row_end,
    input wire [23:0] rgb,
    output reg reference_ready,
    output wire foreground,
    output reg [10:0] changed_pixels
);
    localparam IDLE=0,READ_LOW=1,READ_HIGH=2,PREPARE=3,
               MUL_START=4,MUL_STEP=5,MUL_RESULT=6,COUNT=7;
    reg [2:0] state;
    reg reference_bank,write_bank,training,aborted,scan_fault;
    reg present,enter_seen,exit_seen;
    reg [1:0] sx;
    reg [2:0] sy;
    reg [9:0] samples;
    reg [8:0] address,active_address;
    reg [14:0] current_rgb,reference_rgb;
    reg [7:0] reference_low;
    wire selected=pixel_valid && sx==1 && sy==3;
    wire [14:0] packed_rgb={rgb[23:19],rgb[15:11],rgb[7:3]};
    wire write_reference=training && !aborted && !run_enabled &&
                         ((selected && state==IDLE) || state==READ_LOW);
    wire [8:0] memory_address=state==IDLE ? address : active_address;
    wire memory_high=state==READ_LOW;
    wire [7:0] reference_byte;
    cnn_eram_byte_dp #(.ADDR_WIDTH(11),.DATA_DEPTH(2048)) reference_memory(
        .I_clk(clk),.I_wr_en(write_reference),
        .I_wr_addr({write_bank,memory_address,memory_high}),
        .I_wr_data(memory_high ? {1'b0,current_rgb[14:8]} : packed_rgb[7:0]),
        .I_rd_addr({reference_bank,memory_address,memory_high}),.O_rd_data(reference_byte));
    wire [4:0] cr=current_rgb[14:10],cg=current_rgb[9:5],cb=current_rgb[4:0];
    wire [4:0] rr=reference_rgb[14:10],rg=reference_rgb[9:5],rb=reference_rgb[4:0];
    wire [4:0] cm=(cr>=cg && cr>=cb) ? cr : cg>=cb ? cg : cb;
    wire [4:0] rm=(rr>=rg && rr>=rb) ? rr : rg>=rb ? rg : rb;
    wire [4:0] dr=cr>=rr ? cr-rr : rr-cr;
    wire [4:0] dg=cg>=rg ? cg-rg : rg-cg;
    wire [4:0] db=cb>=rb ? cb-rb : rb-cb;
    wire raw_change=dr>=PIXEL_DELTA || dg>=PIXEL_DELTA || db>=PIXEL_DELTA;
    wire signed [5:0] red_shift=$signed({1'b0,cr})-$signed({1'b0,rr});
    wire signed [5:0] green_shift=$signed({1'b0,cg})-$signed({1'b0,rg});
    wire signed [5:0] blue_shift=$signed({1'b0,cb})-$signed({1'b0,rb});
    wire signed [6:0] red_residual={red_shift[5],red_shift}-{green_shift[5],green_shift};
    wire signed [6:0] blue_residual={blue_shift[5],blue_shift}-{green_shift[5],green_shift};
    wire neutral_offset=red_residual>=-7'sd2 && red_residual<=7'sd2 &&
                        blue_residual>=-7'sd2 && blue_residual<=7'sd2;
    // Do not automatically explain deep black or extreme exposure as lighting.
    wire lighting_range=cm>=4 && rm>=4 && {cm,2'b00}>={2'b00,rm} &&
                        {1'b0,cm}<={rm,1'b0};
    reg chroma_match;
    reg [2:0] product_index,mul_bit;
    reg [9:0] multiplicand,accumulator,pair_product;
    reg [4:0] multiplier,mul_a,mul_b;
    reg [10:0] tolerance;
    always @* begin
        mul_a=cm;mul_b=rm;
        case(product_index)
            1:begin mul_a=cr;mul_b=rm;end
            2:begin mul_a=rr;mul_b=cm;end
            3:begin mul_a=cg;mul_b=rm;end
            4:begin mul_a=rg;mul_b=cm;end
            5:begin mul_a=cb;mul_b=rm;end
            6:begin mul_a=rb;mul_b=cm;end
        endcase
    end
    wire [9:0] product_difference=accumulator>=pair_product ?
                                 accumulator-pair_product : pair_product-accumulator;
    wire complete_scan=samples==512 && state==IDLE && !scan_fault && !aborted;
    wire raw_foreground=changed_pixels >= (present ? EXIT_PIXELS : ENTER_PIXELS);
    assign foreground=reference_ready && !training && complete_scan &&
                      ((raw_foreground && (present || enter_seen)) || (present && !exit_seen));
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            reference_ready<=0;reference_bank<=0;write_bank<=1;training<=0;aborted<=0;scan_fault<=0;
            present<=0;enter_seen<=0;exit_seen<=0;sx<=0;sy<=0;samples<=0;address<=0;
            active_address<=0;current_rgb<=0;reference_rgb<=0;reference_low<=0;changed_pixels<=0;
            state<=IDLE;chroma_match<=0;product_index<=0;mul_bit<=0;
            multiplicand<=0;multiplier<=0;accumulator<=0;pair_product<=0;tolerance<=0;
        end else begin
            if(pixel_valid) begin
                if(row_end) begin sx<=0;sy<=sy+1'b1;end
                else sx<=sx+1'b1;
            end
            if(selected) begin
                if(state!=IDLE || samples>=512) scan_fault<=1;
                else begin
                    active_address<=address;address<=address+1'b1;samples<=samples+1'b1;
                    current_rgb<=packed_rgb;state<=READ_LOW;
                end
            end
            case(state)
                READ_LOW:begin reference_low<=reference_byte;state<=READ_HIGH;end
                READ_HIGH:begin
                    reference_rgb<={reference_byte[6:0],reference_low};
                    state<=(training || !run_enabled || !reference_ready) ? IDLE : PREPARE;
                end
                PREPARE:begin
                    if(!raw_change) state<=IDLE;
                    else if(lighting_range && neutral_offset) state<=IDLE;
                    else if(!lighting_range) begin changed_pixels<=changed_pixels+1'b1;state<=IDLE;end
                    else begin chroma_match<=1;product_index<=0;state<=MUL_START;end
                end
                MUL_START:begin
                    multiplicand<={5'd0,mul_a};multiplier<=mul_b;accumulator<=0;mul_bit<=0;state<=MUL_STEP;
                end
                MUL_STEP:begin
                    if(multiplier[0]) accumulator<=accumulator+multiplicand;
                    multiplicand<=multiplicand<<1;multiplier<=multiplier>>1;
                    if(mul_bit==4) state<=MUL_RESULT;else mul_bit<=mul_bit+1'b1;
                end
                MUL_RESULT:begin
                    if(product_index==0) tolerance<={4'd0,accumulator[9:3]}+{6'd0,cm}+{6'd0,rm};
                    else if(product_index[0]) pair_product<=accumulator;
                    else if({1'b0,product_difference}>tolerance) chroma_match<=0;
                    if(product_index==6) state<=COUNT;
                    else begin product_index<=product_index+1'b1;state<=MUL_START;end
                end
                COUNT:begin
                    if(!chroma_match) changed_pixels<=changed_pixels+1'b1;
                    state<=IDLE;
                end
            endcase
            if(training && run_enabled) aborted<=1;
            if(!run_enabled) begin present<=0;enter_seen<=0;exit_seen<=0;end
            if(done) begin
                if(training && !run_enabled && complete_scan) begin
                    reference_bank<=write_bank;reference_ready<=1;
                end else if(!training && run_enabled) begin
                    present<=foreground;
                    enter_seen<=complete_scan && raw_foreground;
                    exit_seen<=complete_scan && !raw_foreground;
                end
            end
            if(start) begin
                sx<=0;sy<=0;samples<=0;address<=0;changed_pixels<=0;state<=IDLE;
                training<=scan_background;aborted<=0;scan_fault<=0;write_bank<=!reference_bank;
            end
        end
    end
endmodule
