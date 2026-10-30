// Inputs are one coherent sample in this clock domain: grams and total fen.
// Stability uses the entire candidate window's min/max, not adjacent samples.
module scale_voice_stable #(
    parameter integer CLOCK_HZ=50000000,
    parameter integer STABLE_MS=1000,
    parameter integer SAMPLE_TIMEOUT_MS=500,
    parameter integer MIN_SAMPLES=3,
    parameter integer WEIGHT_TOLERANCE_G=2,
    parameter integer AMOUNT_TOLERANCE_FEN=1,
    parameter integer MIN_WEIGHT_G=20
)(
    input wire clk,rst_n,enable,sample_valid,
    input wire [23:0] weight_g,amount_fen,
    input wire quote_ready,
    output reg quote_valid,
    output reg [23:0] quote_weight_g,quote_amount_fen
);
    localparam integer MS_CYCLES=(CLOCK_HZ/1000)>0 ? CLOCK_HZ/1000 : 1;
    reg [31:0] ms_div;
    wire ms_tick=ms_div==MS_CYCLES-1;
    reg window_valid,announced;
    reg [23:0] min_weight,max_weight,min_amount,max_amount;
    reg [23:0] last_weight,last_amount;
    reg [31:0] age_ms,fresh_ms,samples;
    wire [23:0] next_min_weight=weight_g<min_weight ? weight_g:min_weight;
    wire [23:0] next_max_weight=weight_g>max_weight ? weight_g:max_weight;
    wire [23:0] next_min_amount=amount_fen<min_amount ? amount_fen:min_amount;
    wire [23:0] next_max_amount=amount_fen>max_amount ? amount_fen:max_amount;
    wire in_window=(next_max_weight-next_min_weight<=WEIGHT_TOLERANCE_G) &&
                   (next_max_amount-next_min_amount<=AMOUNT_TOLERANCE_FEN);
    wire [23:0] weight_delta=weight_g>last_weight ? weight_g-last_weight:last_weight-weight_g;
    wire [23:0] amount_delta=amount_fen>last_amount ? amount_fen-last_amount:last_amount-amount_fen;
    wire different=!announced || weight_delta>WEIGHT_TOLERANCE_G || amount_delta>AMOUNT_TOLERANCE_FEN;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            ms_div<=0;window_valid<=0;announced<=0;
            min_weight<=0;max_weight<=0;min_amount<=0;max_amount<=0;
            last_weight<=0;last_amount<=0;age_ms<=0;fresh_ms<=0;samples<=0;
            quote_valid<=0;quote_weight_g<=0;quote_amount_fen<=0;
        end else begin
            quote_valid<=0;
            if(ms_tick) ms_div<=0;else ms_div<=ms_div+1'b1;
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
