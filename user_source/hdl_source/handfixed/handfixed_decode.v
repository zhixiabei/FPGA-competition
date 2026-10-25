// Frozen three-class softmax rejection. This is not a hand detector.
// Identical conservative LUT decision to the production handcnn decoder.
module handfixed_decode(
    input wire clk,rst_n,start,
    output reg done,
    output reg [2:0] result_class,
    output wire mem_valid,
    output wire [31:0] mem_addr,
    input wire mem_ready,mem_rsp_valid,
    input wire [127:0] mem_rsp_data,
    output wire [47:0] debug_logits
);
    localparam IDLE=0,REQ=1,RSP=2,LOGIT=3,WIN=4,EXP_ADDR=5,EXP_WAIT=6,EXP_SUM=7,DECIDE=8;
    reg [3:0] state;
    reg [1:0] component,index,winner;
    reg [127:0] data;
    reg signed [15:0] logits[0:2];
    reg signed [15:0] maximum;
    reg [22:0] exp_sum;
    wire [16:0] delta=$signed(maximum)-$signed(logits[index]);
    wire [8:0] exp_address=delta>=16384 ? 9'd511 : delta[13:5];
    wire [20:0] exp_upper;
    handcnn_confidence exp_rom(.clk(clk),.address(exp_address),.value(exp_upper));
    assign mem_valid=state==REQ;
    assign mem_addr=32'h00d20000+{26'd0,component,4'd0};
    assign debug_logits={logits[2],logits[1],logits[0]};
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;component<=0;index<=0;winner<=0;data<=0;maximum<=0;exp_sum<=0;
            logits[0]<=0;logits[1]<=0;logits[2]<=0;done<=0;result_class<=1;
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
                    if(component==2) state<=WIN;
                    else begin component<=component+1'b1;state<=REQ;end
                end
                WIN:begin
                    if(logits[0]>=logits[1] && logits[0]>=logits[2]) begin winner<=0;maximum<=logits[0];end
                    else if(logits[1]>=logits[2]) begin winner<=1;maximum<=logits[1];end
                    else begin winner<=2;maximum<=logits[2];end
                    index<=0;exp_sum<=0;state<=EXP_ADDR;
                end
                EXP_ADDR:state<=EXP_WAIT;
                EXP_WAIT:state<=EXP_SUM;
                EXP_SUM:begin
                    if(index!=winner) exp_sum<=exp_sum+exp_upper;
                    if(index==2) state<=DECIDE;
                    else begin index<=index+1'b1;state<=EXP_ADDR;end
                end
                DECIDE:begin result_class<=exp_sum<=564617 ? winner+2 : 1;done<=1;state<=IDLE;end
            endcase
        end
    end
endmodule
