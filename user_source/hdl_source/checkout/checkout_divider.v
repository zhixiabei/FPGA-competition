// Unsigned restoring divider. No combinational division or reciprocal DSP.
module checkout_divider(
    input wire clk,rst_n,start,
    input wire [34:0] numerator,
    input wire [24:0] denominator,
    output reg busy,done,
    output reg [34:0] quotient
);
    reg [34:0] bits;
    reg [24:0] divisor,remainder;
    reg [5:0] count;
    wire [25:0] trial={remainder,bits[34]};
    wire take=trial>={1'b0,divisor};
    wire [25:0] difference=trial-{1'b0,divisor};
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin busy<=0;done<=0;quotient<=0;bits<=0;divisor<=1;remainder<=0;count<=0;end
        else begin
            done<=0;
            if(start && !busy) begin
                bits<=numerator;divisor<=denominator;remainder<=0;quotient<=0;count<=0;busy<=1;
            end else if(busy) begin
                remainder<=take ? difference[24:0] : trial[24:0];
                bits<={bits[33:0],1'b0};quotient<={quotient[33:0],take};
                if(count==34) begin busy<=0;done<=1;end
                else count<=count+1'b1;
            end
        end
    end
endmodule
