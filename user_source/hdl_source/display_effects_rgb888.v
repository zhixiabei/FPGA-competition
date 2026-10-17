// Original Gamma, grayscale, ISP Scharr/emboss and negative; two-clock latency.
module display_effects_rgb888 (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire [23:0] I_rgb,
    input  wire [3:0]  I_mode,
    input  wire [7:0]  I_param,
    output reg  [23:0] O_rgb
);
    localparam [3:0] MODE_ORIGINAL  = 4'd0;
    localparam [3:0] MODE_GRAYSCALE = 4'd1;
    localparam [3:0] MODE_EDGE      = 4'd2;
    localparam [3:0] MODE_NEGATIVE  = 4'd3;
    localparam [3:0] MODE_EMBOSS    = 4'd4;

    reg [23:0] rgb_d;
    reg [7:0] luma_d;
    reg [3:0] mode_d;
    reg pixel_ready;
    reg [23:0] effect_comb;
    wire [23:0] gamma_rgb;

    // Rounded BT.601-style luma: (77R + 150G + 29B + 128) / 256.
    function [7:0] luma_rgb;
        input [23:0] value;
        reg [15:0] r16;
        reg [15:0] g16;
        reg [15:0] b16;
        reg [15:0] weighted_red;
        reg [15:0] weighted_green;
        reg [15:0] weighted_blue;
        reg [15:0] weighted;
        begin
            r16 = {8'd0, value[23:16]};
            g16 = {8'd0, value[15:8]};
            b16 = {8'd0, value[7:0]};
            weighted_red = ((r16 << 6) + (r16 << 3))
                         + ((r16 << 2) + r16);
            weighted_green = ((g16 << 7) + (g16 << 4))
                           + ((g16 << 2) + (g16 << 1));
            weighted_blue = ((b16 << 4) + (b16 << 3))
                          + ((b16 << 2) + b16);
            weighted = (weighted_red + weighted_green) + weighted_blue;
            luma_rgb = (weighted + 16'd128) >> 8;
        end
    endfunction

    always @* begin
        case (mode_d)
            MODE_GRAYSCALE: effect_comb = {luma_d, luma_d, luma_d};
            MODE_EDGE, MODE_EMBOSS: effect_comb = rgb_d;
            MODE_NEGATIVE: effect_comb = ~rgb_d;
            default: effect_comb = gamma_rgb;
        endcase
    end

    gamma_lut_rgb888 gamma_lut (
        .I_clk(I_clk),
        .I_rgb(I_rgb),
        .O_rgb(gamma_rgb)
    );

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            rgb_d <= 24'd0;
            luma_d <= 8'd0;
            mode_d <= MODE_ORIGINAL;
            pixel_ready <= 1'b0;
            O_rgb <= 24'd0;
        end else begin
            rgb_d <= I_rgb;
            luma_d <= luma_rgb(I_rgb);
            mode_d <= I_mode;
            pixel_ready <= 1'b1;
            O_rgb <= pixel_ready ? effect_comb : 24'd0;
        end
    end
endmodule
