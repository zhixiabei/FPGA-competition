// Simulation-only model for the asymmetric PH1P distributed RAM modes used
// by the fruit preprocessor. Bit address zero maps to the low write/read lane.
module PH1P_LOGIC_DRAM #(
    parameter DATA_WIDTH_W = 8,
    parameter DATA_WIDTH_R = DATA_WIDTH_W,
    parameter ADDR_WIDTH_W = 6,
    parameter ADDR_WIDTH_R = ADDR_WIDTH_W,
    parameter DATA_DEPTH_W = 2 ** ADDR_WIDTH_W,
    parameter DATA_DEPTH_R = 2 ** ADDR_WIDTH_R,
    parameter INIT_FILE = "NONE",
    parameter FILL_ALL = "NONE",
    parameter READREG = "DISABLE",
    parameter RESETMODE = "SYNC"
) (
    input wire [DATA_WIDTH_W-1:0] di,
    input wire we,wclk,rclk,rrst,rce,
    input wire [ADDR_WIDTH_W-1:0] waddr,
    input wire [ADDR_WIDTH_R-1:0] raddr,
    output wire [DATA_WIDTH_R-1:0] rdo,
    output reg [DATA_WIDTH_R-1:0] rdoq
);
    localparam TOTAL_BITS = DATA_WIDTH_W*DATA_DEPTH_W;
    reg [TOTAL_BITS-1:0] bits;

    assign rdo = bits[raddr*DATA_WIDTH_R +: DATA_WIDTH_R];

    always @(posedge wclk)
        if(we) bits[waddr*DATA_WIDTH_W +: DATA_WIDTH_W] <= di;

    always @(posedge rclk or posedge rrst) begin
        if(rrst) rdoq <= 0;
        else if(rce) rdoq <= bits[raddr*DATA_WIDTH_R +: DATA_WIDTH_R];
    end
endmodule
