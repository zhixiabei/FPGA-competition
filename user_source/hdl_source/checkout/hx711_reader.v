// HX711 channel A, gain 128: 24 MSB-first data clocks + one gain clock.
// DOUT is sampled late in each 1 us high phase, after its input synchronizer.
module hx711_reader #(
    parameter integer CLK_HZ=66666667,
    parameter integer HALF_CYCLES=(CLK_HZ+999999)/1000000,
    parameter integer TIMEOUT_CYCLES=CLK_HZ
)(
    input wire clk,rst_n,dout,
    output reg sck,
    output reg sample_valid,
    output reg signed [23:0] sample,
    output reg fault
);
    (* async_reg="true" *) reg dout_meta,dout_sync;
    localparam integer PHASE_BITS=HALF_CYCLES>1 ? $clog2(HALF_CYCLES) : 1;
    localparam integer WAIT_BITS=TIMEOUT_CYCLES>1 ? $clog2(TIMEOUT_CYCLES) : 1;
    reg [PHASE_BITS-1:0] phase_count;
    reg [WAIT_BITS-1:0] wait_count;
    reg [5:0] pulse_count;
    reg [23:0] shift;
    reg active;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin dout_meta<=1;dout_sync<=1;end
        else begin dout_meta<=dout;dout_sync<=dout_meta;end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            sck<=0;sample_valid<=0;sample<=0;fault<=1;
            phase_count<=0;wait_count<=0;pulse_count<=0;shift<=0;active<=0;
        end else begin
            sample_valid<=0;
            if(!active) begin
                sck<=0;
                if(!dout_sync) begin
                    active<=1;phase_count<=0;pulse_count<=0;shift<=0;wait_count<=0;
                end else if(wait_count<TIMEOUT_CYCLES-1) wait_count<=wait_count+1'b1;
                else fault<=1;
            end else if(phase_count==HALF_CYCLES-1) begin
                phase_count<=0;
                if(!sck) sck<=1;
                else begin
                    sck<=0;
                    if(pulse_count<24) begin
                        shift<={shift[22:0],dout_sync};pulse_count<=pulse_count+1'b1;
                    end else begin
                        sample<=shift;sample_valid<=1;fault<=0;active<=0;wait_count<=0;
                    end
                end
            end else phase_count<=phase_count+1'b1;
        end
    end
endmodule
