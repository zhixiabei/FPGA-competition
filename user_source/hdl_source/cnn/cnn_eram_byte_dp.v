// Explicit PH1P embedded-RAM wrapper for a byte-wide dual-port store.
// Both ports are synchronous to I_clk. NOREG bypasses only the optional
// output register; port B still returns its addressed byte after a clock.
module cnn_eram_byte_dp #(
    parameter integer ADDR_WIDTH = 11,
    parameter integer DATA_DEPTH = 2048
) (
    input  wire                  I_clk,
    input  wire                  I_wr_en,
    input  wire [ADDR_WIDTH-1:0] I_wr_addr,
    input  wire [7:0]            I_wr_data,
    input  wire [ADDR_WIDTH-1:0] I_rd_addr,
    output wire [7:0]            O_rd_data
);
    PH1P_LOGIC_ERAM #(
        .DATA_WIDTH_A(8), .DATA_WIDTH_B(8),
        .ADDR_WIDTH_A(ADDR_WIDTH), .ADDR_WIDTH_B(ADDR_WIDTH),
        .DATA_DEPTH_A(DATA_DEPTH), .DATA_DEPTH_B(DATA_DEPTH),
        .MODE("DP"),
        .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
        .IMPLEMENT("20K(FAST)"), .CLKMODE("ASYNC"),
        .ECC_ENCODE("DISABLE"), .ECC_DECODE("DISABLE"),
        .INIT_FILE("NONE"), .FILL_ALL("NONE")
    ) u_eram (
        .clka(I_clk), .clkb(I_clk),
        .cea(I_wr_en), .ceb(1'b1),
        .ocea(1'b0), .oceb(1'b0),
        .wea(I_wr_en), .web(1'b0),
        .rsta(1'b0), .rstb(1'b0),
        .bea(1'b0), .beb(1'b0),
        .addra(I_wr_addr), .addrb(I_rd_addr),
        .dia(I_wr_data), .dib(8'd0),
        .doa(), .dob(O_rd_data),
        .ecc_sbiterr(), .ecc_dbiterr(),
        .ecc_sbiterrinj(1'b0), .ecc_dbiterrinj(1'b0)
    );
endmodule
