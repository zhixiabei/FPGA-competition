// Five-class counterpart of the existing result filter.
// UNKNOWN=1; apple, banana, grape, orange, pear=2..6.
module fruitfixed_result_filter(
    input wire clk,rst_n,clear,in_valid,
    input wire [2:0] in_class,
    output wire [2:0] decision_class,
    output reg [2:0] stable_class
);
    reg [2:0] candidate,candidate_next,stable_next;
    reg [1:0] count,count_next;
    wire [2:0] raw_class=(in_class>=2 && in_class<=6) ? in_class : 3'd1;
    wire [1:0] required_prior=(stable_class==1 && raw_class!=1) ? 2'd1 : 2'd2;
    always @* begin
        stable_next=stable_class;candidate_next=candidate;count_next=count;
        if(clear) begin stable_next=1;candidate_next=1;count_next=0;end
        else if(in_valid) begin
            if(raw_class==stable_class) begin candidate_next=1;count_next=0;end
            else if(candidate==raw_class && count>=required_prior) begin
                stable_next=raw_class;candidate_next=1;count_next=0;
            end else if(candidate==raw_class) count_next=count+1'b1;
            else begin candidate_next=raw_class;count_next=1;end
        end
    end
    assign decision_class=stable_next;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin stable_class<=1;candidate<=1;count<=0;end
        else begin stable_class<=stable_next;candidate<=candidate_next;count<=count_next;end
    end
endmodule
