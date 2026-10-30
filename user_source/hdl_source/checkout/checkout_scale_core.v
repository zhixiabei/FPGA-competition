// HX711 weighing, five-class pricing and HDMI decimal snapshot integration.
module checkout_scale_core #(
    parameter integer CLK_HZ=66666667,
    parameter integer KEY_CYCLES=(CLK_HZ+49)/50,
    parameter integer TIMEOUT_CYCLES=CLK_HZ,
    parameter integer CALIBRATION_GRAMS=227,
    parameter integer AUTO_TARE_CYCLES=2*CLK_HZ
)(
    input wire clk,rst_n,hx711_dout,tare_key_n,cal_key_n,
    input wire fruit_valid,
    input wire [2:0] fruit_class,
    output wire hx711_sck,
    output wire [13:0] weight_g,total_fen,
    output wire weight_valid,price_valid,
    output wire [15:0] weight_bcd,price_bcd,
    output wire weight_bcd_valid,price_bcd_valid,
    output reg [3:0] status,
    output reg [23:0] raw_adc,
    output reg [15:0] sample_count,
    output wire [7:0] seg_n,sel_n
);
    wire sample_valid,sensor_fault,tare,manual_tare,calibrate;
    localparam integer START_BITS=AUTO_TARE_CYCLES>1 ? $clog2(AUTO_TARE_CYCLES+1) : 1;
    reg [START_BITS-1:0] startup_count;
    reg auto_tare;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin startup_count<=0;auto_tare<=0;end
        else begin
            auto_tare<=0;
            if(AUTO_TARE_CYCLES!=0 && startup_count<AUTO_TARE_CYCLES) begin
                startup_count<=startup_count+1'b1;
                if(startup_count==AUTO_TARE_CYCLES-1) auto_tare<=1;
            end
        end
    end
    assign tare=manual_tare || auto_tare;
    wire signed [23:0] sample;
    wire scale_price_valid;
    wire measured_valid,overload,tared,calibrated,pending;
    reg have_sample,saturated,pending_d,cal_command,cal_failed;
    hx711_reader #(.CLK_HZ(CLK_HZ),.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) u_adc(
        .clk(clk),.rst_n(rst_n),.dout(hx711_dout),.sck(hx711_sck),
        .sample_valid(sample_valid),.sample(sample),.fault(sensor_fault));
    checkout_key #(.DEBOUNCE_CYCLES(KEY_CYCLES)) u_tare(
        .clk(clk),.rst_n(rst_n),.key_n(tare_key_n),.pressed(manual_tare));
    checkout_key #(.DEBOUNCE_CYCLES(KEY_CYCLES)) u_cal(
        .clk(clk),.rst_n(rst_n),.key_n(cal_key_n),.pressed(calibrate));
    fruit_checkout #(.CLK_HZ(CLK_HZ),.CALIBRATION_GRAMS(CALIBRATION_GRAMS)) u_scale(
        .clk(clk),.rst_n(rst_n),.sample_valid(sample_valid),.sensor_fault(sensor_fault),
        .sample(sample),.tare(tare),.calibrate(calibrate),.fruit_valid(fruit_valid),.fruit_class(fruit_class),
        .weight_g(weight_g),.total_fen(total_fen),.weight_valid(measured_valid),.price_valid(scale_price_valid),
        .overload(overload),.tared(tared),.calibrated(calibrated),.calibration_pending(pending));
    assign weight_valid=measured_valid && !sensor_fault && !saturated && !pending;
    assign price_valid=scale_price_valid && weight_valid;
    // Keep the board's active-low digit pins inactive; there is no scanner.
    assign seg_n=8'hff;
    assign sel_n=8'hff;
    checkout_display #(.UPDATE_CYCLES((CLK_HZ/2000)*8)) u_panel_digits(
        .clk(clk),.rst_n(rst_n),.weight_g(weight_g),.total_fen(total_fen),
        .weight_valid(weight_valid),.price_valid(price_valid),
        .weight_bcd(weight_bcd),.price_bcd(price_bcd),
        .weight_bcd_valid(weight_bcd_valid),.price_bcd_valid(price_bcd_valid));
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            raw_adc<=0;sample_count<=0;have_sample<=0;saturated<=0;
            pending_d<=0;cal_command<=0;cal_failed<=0;
        end else begin
            pending_d<=pending;
            if(sample_valid) begin
                raw_adc<=sample;sample_count<=sample_count+1'b1;have_sample<=1;
                saturated<=sample==24'h7fffff || sample==24'h800000;
            end
            if(pending_d && !pending && cal_command) cal_failed<=!calibrated;
            if(tare || calibrate) begin cal_command<=!tare;cal_failed<=0;end
        end
    end
    always @* begin
        if(!have_sample) status=0;
        else if(sensor_fault) status=1;
        else if(saturated) status=2;
        else if(pending) status=cal_command ? 4 : 3;
        else if(cal_failed) status=9;
        else if(!tared) status=5;
        else if(!calibrated) status=6;
        else if(overload) status=8;
        else if(weight_valid) status=7;
        else status=10;
    end
endmodule
