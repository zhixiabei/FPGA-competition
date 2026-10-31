// Inputs are one coherent sample in this clock domain: grams and total fen.
// Stability uses the entire candidate window's min/max, not adjacent samples.
module scale_voice_stable #(
    parameter integer CLOCK_HZ=50000000,
    parameter integer STABLE_MS=1000,
    parameter integer SAMPLE_TIMEOUT_MS=500,
    parameter integer MIN_SAMPLES=3,
    parameter integer WEIGHT_TOLERANCE_G=2,
    parameter integer AMOUNT_TOLERANCE_FEN=1,
    parameter integer MIN_WEIGHT_G=20,
    parameter integer VALUE_WIDTH=24,
    parameter integer EXTERNAL_TICK=0
)(
    input wire clk,rst_n,enable,sample_valid,
    input wire [VALUE_WIDTH-1:0] weight_g,amount_fen,
    input wire quote_ready,
    output reg quote_valid,
    output reg [VALUE_WIDTH-1:0] quote_weight_g,quote_amount_fen,
    // Optional shared divider; ignored when EXTERNAL_TICK is zero.
    input wire ms_tick_in
);
    localparam integer MS_CYCLES=(CLOCK_HZ/1000)>0 ? CLOCK_HZ/1000 : 1;
    localparam integer DIV_BITS=MS_CYCLES>1 ? $clog2(MS_CYCLES):1;
    localparam integer AGE_BITS=STABLE_MS>0 ? $clog2(STABLE_MS+1):1;
    localparam integer FRESH_BITS=SAMPLE_TIMEOUT_MS>0 ? $clog2(SAMPLE_TIMEOUT_MS+1):1;
    localparam integer SAMPLE_BITS=MIN_SAMPLES>1 ? $clog2(MIN_SAMPLES+1):1;
    wire ms_tick;
    generate if(EXTERNAL_TICK) begin: shared_tick
        assign ms_tick=ms_tick_in;
    end else begin: local_tick
        reg [DIV_BITS-1:0] ms_div;
        assign ms_tick=ms_div==MS_CYCLES-1;
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n) ms_div<=0;
            else if(ms_tick) ms_div<=0;
            else ms_div<=ms_div+1'b1;
        end
    end endgenerate
    reg window_valid,announced;
    reg [VALUE_WIDTH-1:0] min_weight,max_weight,min_amount,max_amount;
    reg [VALUE_WIDTH-1:0] last_weight,last_amount;
    reg [AGE_BITS-1:0] age_ms;
    reg [FRESH_BITS-1:0] fresh_ms;
    reg [SAMPLE_BITS-1:0] samples;
    wire [VALUE_WIDTH-1:0] next_min_weight=weight_g<min_weight ? weight_g:min_weight;
    wire [VALUE_WIDTH-1:0] next_max_weight=weight_g>max_weight ? weight_g:max_weight;
    wire [VALUE_WIDTH-1:0] next_min_amount=amount_fen<min_amount ? amount_fen:min_amount;
    wire [VALUE_WIDTH-1:0] next_max_amount=amount_fen>max_amount ? amount_fen:max_amount;
    wire in_window=(next_max_weight-next_min_weight<=WEIGHT_TOLERANCE_G) &&
                   (next_max_amount-next_min_amount<=AMOUNT_TOLERANCE_FEN);
    wire [VALUE_WIDTH-1:0] weight_delta=weight_g>last_weight ? weight_g-last_weight:last_weight-weight_g;
    wire [VALUE_WIDTH-1:0] amount_delta=amount_fen>last_amount ? amount_fen-last_amount:last_amount-amount_fen;
    wire different=!announced || weight_delta>WEIGHT_TOLERANCE_G || amount_delta>AMOUNT_TOLERANCE_FEN;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            window_valid<=0;announced<=0;
            min_weight<=0;max_weight<=0;min_amount<=0;max_amount<=0;
            last_weight<=0;last_amount<=0;age_ms<=0;fresh_ms<=0;samples<=0;
            quote_valid<=0;quote_weight_g<=0;quote_amount_fen<=0;
        end else begin
            quote_valid<=0;
            if(!enable) begin window_valid<=0;announced<=0;age_ms<=0;fresh_ms<=0;samples<=0;end
            else begin
                if(ms_tick) begin
                    if(window_valid && age_ms<STABLE_MS) age_ms<=age_ms+1'b1;
                    if(fresh_ms<SAMPLE_TIMEOUT_MS) fresh_ms<=fresh_ms+1'b1;
                    else begin window_valid<=0;age_ms<=0;samples<=0;end
                end
                if(sample_valid) begin
                    fresh_ms<=0;
                    if(!window_valid || fresh_ms>=SAMPLE_TIMEOUT_MS || !in_window) begin
                        window_valid<=1;age_ms<=0;samples<=1;
                        min_weight<=weight_g;max_weight<=weight_g;
                        min_amount<=amount_fen;max_amount<=amount_fen;
                    end else begin
                        min_weight<=next_min_weight;max_weight<=next_max_weight;
                        min_amount<=next_min_amount;max_amount<=next_max_amount;
                        if(samples<MIN_SAMPLES) samples<=samples+1'b1;
                        if(age_ms>=STABLE_MS && samples>=MIN_SAMPLES-1) begin
                            if(weight_g<MIN_WEIGHT_G) announced<=0;
                            else if(quote_ready && different) begin
                                quote_valid<=1;quote_weight_g<=weight_g;quote_amount_fen<=amount_fen;
                                last_weight<=weight_g;last_amount<=amount_fen;announced<=1;
                            end
                        end
                    end
                end
            end
        end
    end
endmodule
