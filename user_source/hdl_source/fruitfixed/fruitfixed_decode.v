// Five-class fruit candidate. Class IDs: UNKNOWN=1; apple..pear=2..6.
// Compile with the exponential ROM generated for the fruit checkpoint.
module fruitfixed_decode(
    input wire clk,rst_n,start,
    output reg done,
    output reg [2:0] result_class,
    output wire mem_valid,
    output wire [31:0] mem_addr,
    input wire mem_ready,mem_rsp_valid,
    input wire [127:0] mem_rsp_data,
    output wire [79:0] debug_logits
);
    // Replaced in the exported model bundle to match its confidence threshold.
    localparam [22:0] ACCEPT_EXP_SUM_MAX = 23'd564617;
    localparam IDLE=0,REQ=1,RSP=2,LOGIT=3,WIN_INIT=4,WIN_SCAN=5,
               EXP_ADDR=6,EXP_WAIT=7,EXP_SUM=8,DECIDE=9;
    reg [3:0] state;
    reg [2:0] component,index,winner;
    reg [127:0] data;
    reg signed [15:0] logits[0:4];
    reg signed [15:0] maximum;
    reg [22:0] exp_sum;
    wire [16:0] delta=$signed({maximum[15],maximum})-
                          $signed({logits[index][15],logits[index]});
    wire [8:0] exp_address=delta>=16384 ? 9'd511 : delta[13:5];
    wire [20:0] exp_upper;
    handcnn_confidence exp_rom(.clk(clk),.address(exp_address),.value(exp_upper));
    assign mem_valid=state==REQ;
    assign mem_addr=32'h00d20000+{25'd0,component,4'd0};
    assign debug_logits={logits[4],logits[3],logits[2],logits[1],logits[0]};
    integer k;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;component<=0;index<=0;winner<=0;data<=0;maximum<=0;exp_sum<=0;
            for(k=0;k<5;k=k+1) logits[k]<=0;
            done<=0;result_class<=1;
        end else begin
            done<=0;
            case(state)
                IDLE:if(start) begin component<=0;state<=REQ;end
                REQ:if(mem_ready) begin
                    if(mem_rsp_valid) begin data<=mem_rsp_data;state<=LOGIT;end
                    else state<=RSP;
                end
                RSP:if(mem_rsp_valid) begin data<=mem_rsp_data;state<=LOGIT;end
                LOGIT:begin
                    logits[component]<=data[15:0];
                    if(component==4) state<=WIN_INIT;
                    else begin component<=component+1'b1;state<=REQ;end
                end
                WIN_INIT:begin maximum<=logits[0];winner<=0;index<=1;state<=WIN_SCAN;end
                WIN_SCAN:begin
                    // Strict comparison gives the earliest class on ties.
                    if(logits[index]>maximum) begin maximum<=logits[index];winner<=index;end
                    if(index==4) begin index<=0;exp_sum<=0;state<=EXP_ADDR;end
                    else index<=index+1'b1;
                end
                EXP_ADDR:state<=EXP_WAIT;
                EXP_WAIT:state<=EXP_SUM;
                EXP_SUM:begin
                    if(index!=winner) exp_sum<=exp_sum+exp_upper;
                    if(index==4) state<=DECIDE;
                    else begin index<=index+1'b1;state<=EXP_ADDR;end
                end
                DECIDE:begin result_class<=exp_sum<=ACCEPT_EXP_SUM_MAX ? winner+3'd2 : 3'd1;done<=1;state<=IDLE;end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
