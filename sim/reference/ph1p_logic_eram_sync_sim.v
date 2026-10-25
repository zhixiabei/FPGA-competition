// Simulation-only byte RAM for the CNN's DP/NOREG/NORMAL configuration.
// Its synchronous read was checked against the PH1P vendor model in ModelSim.
// CLKMODE describes the relation between the two clocks, not read latency.
// It is never synthesised and never enters the TD project.
module PH1P_LOGIC_ERAM #(
    parameter DATA_WIDTH_A = 8,
    parameter DATA_WIDTH_B = 8,
    parameter ADDR_WIDTH_A = 11,
    parameter ADDR_WIDTH_B = 11,
    parameter DATA_DEPTH_A = 2048,
    parameter DATA_DEPTH_B = 2048,
    parameter MODE         = "DP",
    parameter REGMODE_A    = "NOREG",
    parameter REGMODE_B    = "NOREG",
    parameter WRITEMODE_A  = "NORMAL",
    parameter WRITEMODE_B  = "NORMAL",
    parameter IMPLEMENT    = "20K(FAST)",
    parameter CLKMODE      = "ASYNC",
    parameter ECC_ENCODE   = "DISABLE",
    parameter ECC_DECODE   = "DISABLE",
    parameter INIT_FILE    = "NONE",
    parameter FILL_ALL     = "NONE"
) (
    input  wire                     clka,
    input  wire                     clkb,
    input  wire                     cea,
    input  wire                     ceb,
    input  wire                     ocea,
    input  wire                     oceb,
    input  wire                     wea,
    input  wire                     web,
    input  wire                     rsta,
    input  wire                     rstb,
    input  wire                     bea,
    input  wire                     beb,
    input  wire [ADDR_WIDTH_A-1:0]  addra,
    input  wire [ADDR_WIDTH_B-1:0]  addrb,
    input  wire [DATA_WIDTH_A-1:0]  dia,
    input  wire [DATA_WIDTH_B-1:0]  dib,
    output reg  [DATA_WIDTH_A-1:0]  doa,
    output reg  [DATA_WIDTH_B-1:0]  dob,
    output reg                      ecc_sbiterr,
    output reg                      ecc_dbiterr,
    input  wire                     ecc_sbiterrinj,
    input  wire                     ecc_dbiterrinj
);
    localparam integer DEPTH = (DATA_DEPTH_A > DATA_DEPTH_B) ? DATA_DEPTH_A : DATA_DEPTH_B;

    reg [DATA_WIDTH_A-1:0] mem [0:DEPTH-1];
    integer i;

    initial begin
        doa = {DATA_WIDTH_A{1'b0}};
        dob = {DATA_WIDTH_B{1'b0}};
        ecc_sbiterr = 1'b0;
        ecc_dbiterr = 1'b0;
        if (INIT_FILE != "NONE") $readmemh(INIT_FILE, mem);
    end

    always @(posedge clka) begin
        if (cea && wea) mem[addra] <= dia;
    end

    always @(posedge clkb) begin
        if (rstb) dob <= {DATA_WIDTH_B{1'b0}};
        else if (ceb) dob <= mem[addrb];
    end

    always @(posedge clka) begin
        if (rsta) doa <= {DATA_WIDTH_A{1'b0}};
        else if (cea && !wea) doa <= mem[addra];
    end
endmodule
