// Simulation-only DP/NOREG coefficient RAM. Unlike the general byte-RAM
// reference this implements both writes, as the core loads even/odd lanes
// through ports A/B on the same clock. Reads have one synchronous cycle.
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
    reg [DATA_WIDTH_A-1:0] mem [0:DATA_DEPTH_A-1];
    assign ecc_sbiterr=0;
    assign ecc_dbiterr=0;
    always @(posedge clka) begin
        if(cea && wea) mem[addra]<=dia;
        if(rsta) doa<=0;
        else if(cea && !wea) doa<=mem[addra];
    end
    always @(posedge clkb) begin
        if(ceb && web) mem[addrb]<=dib;
        if(rstb) dob<=0;
        else if(ceb && !web) dob<=mem[addrb];
    end
endmodule
