// Low-cost horizontal colour-shading correction, four RAW10 pixels/clock.
// This is a manually tunable 1-D profile, NOT a calibrated 2-D lens model.
// Pixel 0 is I_tdata[9:0]. All markers and pixels have the same three-stage
// latency, including bubbles and an early SOF. The camera cannot be stalled.
//
// For group j, N=IMG_WIDTH/4-1:
//   delta_c = round(EDGE_c_Q8 * ((2*j-N)/N)^2)
//   output = saturate10(input + round(max(input-BLACK_LEVEL,0)*delta_c/256))
// Four neighbouring pixels share the horizontal coefficient. The mirrored
// half-profile is computed at elaboration: no runtime square or division.
// Two green pixels share a coefficient; the other two share R or B. When
// R/B strengths are zero, their two multipliers are eliminated at synthesis.
module lsc_raw10_4x #(
    parameter integer IMG_WIDTH = 1280,
    parameter BAYER_MODE = "BGGR",
    parameter integer ENABLE = 1,
    parameter integer EDGE_R_Q8 = 0,
    parameter integer EDGE_GR_Q8 = 48,
    parameter integer EDGE_GB_Q8 = 48,
    parameter integer EDGE_B_Q8 = 0,
    parameter integer BLACK_LEVEL = 0
) (
    input wire I_clk,
    input wire I_rst_n,
    input wire [39:0] I_tdata,
    input wire I_tvalid,
    input wire I_tuser,
    input wire I_tlast,
    output wire I_tready,
    output wire [39:0] O_tdata,
    output wire O_tvalid,
    output wire O_tuser,
    output wire O_tlast,
    input wire O_tready
);
    localparam integer GROUPS = IMG_WIDTH / 4;
    localparam integer HALF_GROUPS = (GROUPS + 1) / 2;
    localparam integer X_BITS = GROUPS > 1 ? $clog2(GROUPS) : 1;
    localparam integer ROM_BITS = HALF_GROUPS > 1 ? $clog2(HALF_GROUPS) : 1;
    localparam TOP_RED = BAYER_MODE == "RGGB" || BAYER_MODE == "GRBG";
    localparam TOP_GREEN_EVEN = BAYER_MODE == "GBRG" || BAYER_MODE == "GRBG";

    reg [2:0] valid_pipe, user_pipe, last_pipe;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            valid_pipe <= 0;
            user_pipe <= 0;
            last_pipe <= 0;
        end else begin
            valid_pipe <= {valid_pipe[1:0], I_tvalid};
            user_pipe <= {user_pipe[1:0], I_tuser};
            last_pipe <= {last_pipe[1:0], I_tlast};
        end
    end
    assign O_tvalid = valid_pipe[2];
    assign O_tuser = user_pipe[2];
    assign O_tlast = last_pipe[2];
    assign I_tready = O_tready;

    generate if (!ENABLE) begin: bypass
        reg [39:0] d0, d1, d2;
        always @(posedge I_clk or negedge I_rst_n) begin
            if (!I_rst_n) begin d0 <= 0; d1 <= 0; d2 <= 0; end
            else begin d0 <= I_tdata; d1 <= d0; d2 <= d1; end
        end
        assign O_tdata = O_tvalid ? d2 : 40'd0;
    end else begin: correct
        reg [X_BITS-1:0] x_group;
        reg row_odd;
        wire [X_BITS-1:0] current_x = I_tuser ? {X_BITS{1'b0}} : x_group;
        wire current_row = I_tuser ? 1'b0 : row_odd;
        wire [X_BITS-1:0] mirrored_x = GROUPS-1-current_x;
        wire [ROM_BITS-1:0] rom_address =
            current_x < HALF_GROUPS ? current_x : mirrored_x;
        always @(posedge I_clk or negedge I_rst_n) begin
            if (!I_rst_n) begin x_group <= 0; row_odd <= 0; end
            else begin
                if (I_tuser) begin x_group <= 0; row_odd <= 0; end
                if (I_tvalid) begin
                    if (I_tlast || current_x == GROUPS-1) begin
                        x_group <= 0;
                        row_odd <= !current_row;
                    end else begin
                        x_group <= current_x + 1'b1;
                        row_odd <= current_row;
                    end
                end
            end
        end

        function [7:0] profile;
            input integer strength, address;
            reg [63:0] distance_squared, denominator, numerator;
            begin
                distance_squared = (GROUPS-1-2*address)*(GROUPS-1-2*address);
                denominator = (GROUPS-1)*(GROUPS-1);
                numerator = strength*distance_squared + denominator/2;
                profile = GROUPS > 1 ? numerator/denominator : 0;
            end
        endfunction
        reg [31:0] coefficient_rom [0:HALF_GROUPS-1];
        integer address;
        initial begin
            for (address=0; address<HALF_GROUPS; address=address+1)
                coefficient_rom[address] = {
                    profile(EDGE_R_Q8,address), profile(EDGE_GR_Q8,address),
                    profile(EDGE_GB_Q8,address), profile(EDGE_B_Q8,address)};
        end
        reg [31:0] coefficient_d0;
        // No reset on ROM output, to allow synchronous ROM inference.
        always @(posedge I_clk) coefficient_d0 <= coefficient_rom[rom_address];
        reg [39:0] raw_d0;
        reg green_even_d0, red_row_d0, green_even_d1;
        wire [7:0] green_delta = red_row_d0 ? coefficient_d0[23:16] : coefficient_d0[15:8];
        wire [7:0] other_delta = red_row_d0 ? coefficient_d0[31:24] : coefficient_d0[7:0];
        wire [9:0] green0 = green_even_d0 ? raw_d0[9:0] : raw_d0[19:10];
        wire [9:0] green1 = green_even_d0 ? raw_d0[29:20] : raw_d0[39:30];
        wire [9:0] other0 = green_even_d0 ? raw_d0[19:10] : raw_d0[9:0];
        wire [9:0] other1 = green_even_d0 ? raw_d0[39:30] : raw_d0[29:20];
        reg [9:0] green0_d1, green1_d1, other0_d1, other1_d1;
        wire [17:0] green_product0, green_product1, other_product0, other_product1;
        function [9:0] signal_above_black;
            input [9:0] pixel;
            begin signal_above_black = pixel > BLACK_LEVEL ? pixel-BLACK_LEVEL : 10'd0; end
        endfunction
        if (EDGE_GR_Q8 != 0 || EDGE_GB_Q8 != 0) begin: green_multiply
            reg [17:0] p0, p1;
            always @(posedge I_clk or negedge I_rst_n) begin
                if (!I_rst_n) begin p0 <= 0; p1 <= 0; end
                else begin
                    p0 <= signal_above_black(green0) * green_delta;
                    p1 <= signal_above_black(green1) * green_delta;
                end
            end
            assign green_product0=p0;
            assign green_product1=p1;
        end else begin: green_unity
            assign green_product0=0;
            assign green_product1=0;
        end
        if (EDGE_R_Q8 != 0 || EDGE_B_Q8 != 0) begin: other_multiply
            reg [17:0] p0, p1;
            always @(posedge I_clk or negedge I_rst_n) begin
                if (!I_rst_n) begin p0 <= 0; p1 <= 0; end
                else begin
                    p0 <= signal_above_black(other0) * other_delta;
                    p1 <= signal_above_black(other1) * other_delta;
                end
            end
            assign other_product0=p0;
            assign other_product1=p1;
        end else begin: other_unity
            assign other_product0=0;
            assign other_product1=0;
        end
        function [9:0] corrected_pixel;
            input [9:0] pixel;
            input [17:0] product;
            reg [18:0] rounded;
            reg [10:0] result;
            begin
                rounded = {1'b0, product} + 19'd128;
                result = {1'b0,pixel} + rounded[18:8];
                corrected_pixel = result[10] ? 10'd1023 : result[9:0];
            end
        endfunction
        wire [9:0] corrected_green0=corrected_pixel(green0_d1,green_product0);
        wire [9:0] corrected_green1=corrected_pixel(green1_d1,green_product1);
        wire [9:0] corrected_other0=corrected_pixel(other0_d1,other_product0);
        wire [9:0] corrected_other1=corrected_pixel(other1_d1,other_product1);
        reg [39:0] corrected_data;
        always @(posedge I_clk or negedge I_rst_n) begin
            if (!I_rst_n) begin
                raw_d0 <= 0;
                green_even_d0 <= 0; red_row_d0 <= 0; green_even_d1 <= 0;
                green0_d1 <= 0; green1_d1 <= 0; other0_d1 <= 0; other1_d1 <= 0;
                corrected_data <= 0;
            end else begin
                raw_d0 <= I_tdata;
                green_even_d0 <= TOP_GREEN_EVEN ^ current_row;
                red_row_d0 <= TOP_RED ^ current_row;
                green_even_d1 <= green_even_d0;
                green0_d1 <= green0; green1_d1 <= green1;
                other0_d1 <= other0; other1_d1 <= other1;
                corrected_data <= green_even_d1 ?
                    {corrected_other1,corrected_green1,corrected_other0,corrected_green0} :
                    {corrected_green1,corrected_other1,corrected_green0,corrected_other0};
            end
        end
        assign O_tdata = O_tvalid ? corrected_data : 40'd0;
    end endgenerate

    // synthesis translate_off
    initial begin
        if (IMG_WIDTH < 4 || IMG_WIDTH % 4 != 0 ||
            BLACK_LEVEL < 0 || BLACK_LEVEL > 1023 ||
            EDGE_R_Q8 < 0 || EDGE_R_Q8 > 255 || EDGE_GR_Q8 < 0 || EDGE_GR_Q8 > 255 ||
            EDGE_GB_Q8 < 0 || EDGE_GB_Q8 > 255 || EDGE_B_Q8 < 0 || EDGE_B_Q8 > 255 ||
            (BAYER_MODE != "BGGR" && BAYER_MODE != "RGGB" &&
             BAYER_MODE != "GBRG" && BAYER_MODE != "GRBG"))
            $fatal(1,"Unsupported LSC parameters");
    end
    // synthesis translate_on
endmodule
