// Five-class weighing and checkout arithmetic.
// Class IDs: 1 unknown, 2 apple, 3 banana, 4 grape, 5 orange, 6 strawberry.
// Prices are in fen/kg; total_fen is rounded to the nearest fen.
module fruit_checkout #(
    parameter integer CLK_HZ=66666667,
    parameter integer FRUIT_TIMEOUT_CYCLES=3*CLK_HZ,
    parameter integer APPLE_FEN_KG=800,
    parameter integer BANANA_FEN_KG=600,
    parameter integer GRAPE_FEN_KG=1200,
    parameter integer ORANGE_FEN_KG=500,
    parameter integer STRAWBERRY_FEN_KG=2000,
    parameter integer CALIBRATION_GRAMS=1000
)(
    input wire clk,rst_n,
    input wire sample_valid,sensor_fault,
    input wire signed [23:0] sample,
    input wire tare,calibrate,
    input wire fruit_valid,
    input wire [2:0] fruit_class,
    output reg [13:0] weight_g,
    output reg [13:0] total_fen,
    output reg weight_valid,price_valid,overload,
    output reg tared,calibrated,
    output wire calibration_pending
);
    reg [2:0] current_class;
    localparam integer AGE_BITS=FRUIT_TIMEOUT_CYCLES>1 ? $clog2(FRUIT_TIMEOUT_CYCLES) : 1;
    reg [AGE_BITS-1:0] fruit_age;
    reg fruit_fresh;
    reg [11:0] unit_price;
    always @* begin
        case(current_class)
            2:unit_price=APPLE_FEN_KG;
            3:unit_price=BANANA_FEN_KG;
            4:unit_price=GRAPE_FEN_KG;
            5:unit_price=ORANGE_FEN_KG;
            6:unit_price=STRAWBERRY_FEN_KG;
            default:unit_price=0;
        endcase
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin current_class<=1;fruit_age<=0;fruit_fresh<=0;end
        else if(fruit_valid) begin
            current_class<=fruit_class;fruit_age<=0;
            fruit_fresh<=fruit_class>=2 && fruit_class<=6;
        end else if(fruit_age<FRUIT_TIMEOUT_CYCLES-1) fruit_age<=fruit_age+1'b1;
        else fruit_fresh<=0;
    end

    reg signed [26:0] sum;
    reg [2:0] sample_count;
    reg signed [23:0] zero_raw,average;
    reg [24:0] span;
    reg reverse_load;
    reg [1:0] command;
    reg average_valid,average_ready;
    wire signed [26:0] sum_next=sum+{{3{sample[23]}},sample};
    wire signed [24:0] delta=$signed({average[23],average})-$signed({zero_raw[23],zero_raw});
    wire [24:0] abs_delta=delta[24] ? -delta : delta;
    wire signed [24:0] load_delta=reverse_load ? -delta : delta;
    assign calibration_pending=command!=0;

    reg [2:0] state;
    localparam IDLE=0,WEIGH=1,PRICE_START=2,PRICE=3;
    reg div_start;
    reg [34:0] div_numerator;
    reg [24:0] div_denominator;
    wire div_busy,div_done;
    wire [34:0] quotient;
    checkout_divider u_div(.clk(clk),.rst_n(rst_n),.start(div_start),
        .numerator(div_numerator),.denominator(div_denominator),
        .busy(div_busy),.done(div_done),.quotient(quotient));

    function [34:0] reference_product;
        input [24:0] value;
        integer k;
        begin
            reference_product=0;
            for(k=0;k<10;k=k+1)
                if((CALIBRATION_GRAMS>>k)&1) reference_product=reference_product+({10'd0,value}<<k);
        end
    endfunction
    wire [34:0] weight_numerator=reference_product(load_delta);

    reg [13:0] price_weight;
    reg [11:0] price_unit;
    reg [2:0] priced_class;
    reg price_signature_valid;
    wire [25:0] price_product=price_weight*price_unit;
    reg sample_bad;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            sum<=0;sample_count<=0;zero_raw<=0;average<=0;average_valid<=0;average_ready<=0;
            span<=1;reverse_load<=0;command<=0;tared<=0;calibrated<=0;
            weight_g<=0;total_fen<=0;weight_valid<=0;price_valid<=0;overload<=0;
            state<=IDLE;div_start<=0;div_numerator<=0;div_denominator<=1;
            price_weight<=0;price_unit<=0;priced_class<=1;price_signature_valid<=0;sample_bad<=1;
        end else begin
            average_valid<=0;div_start<=0;
            if(average_valid) average_ready<=1;
            if(sample_valid) begin
                if(sample==24'sh7fffff || sample==24'sh800000) begin
                    sample_bad<=1;sum<=0;sample_count<=0;
                end else begin
                    if(sample_count==7) begin
                        average<=sum_next>>>3;average_valid<=1;sum<=0;sample_count<=0;sample_bad<=0;
                    end else begin sum<=sum_next;sample_count<=sample_count+1'b1;end
                end
            end
            if(tare || calibrate) begin
                command<=tare ? 1 : 2;sum<=0;sample_count<=0;average_valid<=0;average_ready<=0;
                weight_valid<=0;price_valid<=0;price_signature_valid<=0;
            end
            if(average_ready && state==IDLE && !div_busy && !div_start && !tare && !calibrate) begin
                average_ready<=0;
                if(command==1) begin
                    zero_raw<=average;tared<=1;command<=0;weight_valid<=0;price_signature_valid<=0;
                end else if(command==2) begin
                    calibrated<=tared && abs_delta>=1000;
                    if(tared && abs_delta>=1000) begin span<=abs_delta;reverse_load<=delta[24];end
                    command<=0;weight_valid<=0;price_signature_valid<=0;
                end else if(tared && calibrated && !sample_bad && !sensor_fault) begin
                    price_valid<=0;price_signature_valid<=0;weight_valid<=0;
                    if(load_delta<=0) begin weight_g<=0;weight_valid<=1;overload<=0;end
                    else begin
                        div_numerator<=weight_numerator+{10'd0,(span>>1)};
                        div_denominator<=span;div_start<=1;state<=WEIGH;
                    end
                end
            end
            case(state)
                WEIGH:if(div_done) begin
                    overload<=quotient>9999;weight_valid<=quotient<=9999;
                    weight_g<=quotient>9999 ? 14'd9999 : quotient<=2 ? 14'd0 : quotient[13:0];
                    state<=IDLE;
                end
                PRICE_START:begin
                    // total_fen = round(weight_g * fen_per_kg / 1000).
                    div_numerator<={9'd0,price_product}+35'd500;
                    div_denominator<=1000;div_start<=1;state<=PRICE;
                end
                PRICE:if(div_done) begin
                    total_fen<=quotient>9999 ? 14'd9999 : quotient[13:0];
                    price_valid<=quotient<=9999 && price_signature_valid &&
                        priced_class==current_class && price_weight==weight_g &&
                        fruit_fresh && weight_valid;
                    state<=IDLE;
                end
            endcase
            if(state==IDLE && !average_ready && !average_valid && !div_busy && !div_start &&
               weight_valid && fruit_fresh && !price_signature_valid) begin
                price_weight<=weight_g;price_unit<=unit_price;priced_class<=current_class;
                price_signature_valid<=1;state<=PRICE_START;
            end
            if(!fruit_fresh || (fruit_valid && (fruit_class!=current_class || fruit_class<2 || fruit_class>6)) || !weight_valid) begin
                price_valid<=0;
                if(!weight_valid || !fruit_fresh || (fruit_valid && fruit_class!=current_class))
                    price_signature_valid<=0;
            end
            if(sensor_fault || sample_bad || command!=0 || tare || calibrate) begin
                weight_valid<=0;price_valid<=0;price_signature_valid<=0;
            end
        end
    end
endmodule
