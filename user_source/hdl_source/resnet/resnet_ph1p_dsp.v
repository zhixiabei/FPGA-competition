// PH1P35 native DSP datapath. Controls are shared across output-channel lanes.
// MULT and TADD connect through SIOU's dedicated internal ports so TD can pack
// multiplication, addition, feedback and output register into one DSP block.
module resnet_ph1p_dsp #(
    parameter integer ACTIVATION_WIDTH = 8,
    parameter integer WEIGHT_WIDTH = 8
) (
    input wire clk, rst_n, enable,
    input wire signed [ACTIVATION_WIDTH-1:0] activation,
    input wire signed [WEIGHT_WIDTH-1:0] weight,
    input wire [10:0] opctrl,
    input wire [6:0] muxctrl,
    output wire [53:0] result
);
    wire [26:0] mult_x;
    wire [17:0] mult_y;
    wire mult_opctrl, mul9_mode, mul9_signed;
    wire [44:0] mult_p;
    wire [53:0] ta,tb,tc,ts;
    wire tci,tco,tover,tunder;
    wire [6:0] top;
    wire [5:0] toversel;
    wire signed [26:0] extended_activation=activation;
    wire signed [17:0] extended_weight=weight;
    PH1P_PHY_DSPSIOU_V2 #(
        .XAREG("0"),.XBREG("0"),.YREG("0"),.ZREG("0"),
        .INCTRLREG("0"),.MUXCTRLREG("0"),.OPCTRLREG("0"),.CINCTRLREG("0"),
        .CXAREG("0"),.CXBREG("0"),.CYREG("0"),
        .XABREG("0"),.MREG("0"),.POUWREG("1"),.CCOREG("0"),
        .USER_GSRN("DISABLE"),.MULT_MODE("NORMAL")
    ) u_siou (
        .clk(clk),.ce({4{enable}}),.rst({4{!rst_n}}),
        .xa(extended_activation),.xb(27'd0),
        .y(extended_weight),.z(54'd0),
        .inctrl(7'b1011111),.muxctrl(muxctrl),.opctrl(opctrl),.cinctrl(3'd0),
        .cxai(27'd0),.cxbi(27'd0),.cxabi(27'd0),.cyi(18'd0),.cpi(54'd0),.cci(1'b0),
        // Dedicated hardware return ports must be dangling when unused, not
        // tied to fabric constants (TD SYN-8134). These paths are unselected.
        .add_sum(),.logic_p(),.logic_wxor(),
        .mult_x(mult_x),.mult_y(mult_y),.mult_opctrl(mult_opctrl),
        .mul9_mode(mul9_mode),.mul9_signed(mul9_signed),.mult_p(mult_p),
        .tadd_a(ta),.tadd_b(tb),.tadd_c(tc),.tadd_ci(tci),
        .tadd_opctrl(top),.tadd_oversel(toversel),
        .tadd_sum(ts),.tadd_co(tco),.tadd_overflow(tover),.tadd_underflow(tunder),
        .p(result),.cxao(),.cxbo(),.cxabo(),.cyo(),.cpo(),.cco(),
        .overflow(),.underflow(),.wxor(),
        .add_a(),.add_b(),.add_opctrl(),
        .logic_a(),.logic_b(),.logic_c(),.logic_opctrl()
    );
    PH1P_PHY_DSPMULT_V2 u_mult (
        .x(mult_x),.y(mult_y),.opctrl(mult_opctrl),
        .mul9_mode(mul9_mode),.mul9_signed(mul9_signed),.p(mult_p)
    );
    PH1P_PHY_DSPTADD u_tadd (
        .a(ta),.b(tb),.c(tc),.ci(tci),.opctrl(top),.oversel(toversel),
        .sum(ts),.co(tco),.overflow(tover),.underflow(tunder)
    );
endmodule
