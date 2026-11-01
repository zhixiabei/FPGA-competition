// Simulation-only DP/PDPW NOREG RAM with a common bit-addressed backing store.
// Coefficients use both write ports; the activation cache writes eight A12
// samples and reads one. Each enabled read has one synchronous cycle.
module PH1P_LOGIC_ERAM #(
    parameter DATA_WIDTH_A=46, DATA_WIDTH_B=46,
    parameter ADDR_WIDTH_A=5, ADDR_WIDTH_B=5,
    parameter DATA_DEPTH_A=32, DATA_DEPTH_B=32,
    parameter MODE="DP", REGMODE_A="NOREG", REGMODE_B="NOREG",
    parameter WRITEMODE_A="NORMAL", WRITEMODE_B="NORMAL",
    parameter IMPLEMENT="20K(FAST)", CLKMODE="SYNC",
    parameter ECC_ENCODE="DISABLE", ECC_DECODE="DISABLE",
    parameter INIT_FILE="NONE", FILL_ALL="NONE"
)(
    input wire clka,clkb,cea,ceb,ocea,oceb,wea,web,rsta,rstb,bea,beb,
    input wire [ADDR_WIDTH_A-1:0] addra,
    input wire [ADDR_WIDTH_B-1:0] addrb,
    input wire [DATA_WIDTH_A-1:0] dia,
    input wire [DATA_WIDTH_B-1:0] dib,
    output reg [DATA_WIDTH_A-1:0] doa,
    output reg [DATA_WIDTH_B-1:0] dob,
    output wire ecc_sbiterr,ecc_dbiterr,
    input wire ecc_sbiterrinj,ecc_dbiterrinj
);
    reg [DATA_WIDTH_A*DATA_DEPTH_A-1:0] mem;
    initial begin
        if(DATA_WIDTH_A*DATA_DEPTH_A != DATA_WIDTH_B*DATA_DEPTH_B)
            $fatal(1,"RAM port capacities differ");
        if((MODE!="DP" && MODE!="PDPW") || REGMODE_A!="NOREG" || REGMODE_B!="NOREG")
            $fatal(1,"Unsupported reference RAM mode");
    end
    assign ecc_sbiterr=0;
    assign ecc_dbiterr=0;
    always @(posedge clka) begin
        if(cea && wea) mem[addra*DATA_WIDTH_A+:DATA_WIDTH_A]<=dia;
        if(rsta) doa<=0;
        else if(cea && !wea) doa<=mem[addra*DATA_WIDTH_A+:DATA_WIDTH_A];
    end
    always @(posedge clkb) begin
        if(ceb && web) mem[addrb*DATA_WIDTH_B+:DATA_WIDTH_B]<=dib;
        if(rstb) dob<=0;
        else if(ceb && !web) dob<=mem[addrb*DATA_WIDTH_B+:DATA_WIDTH_B];
    end
endmodule
