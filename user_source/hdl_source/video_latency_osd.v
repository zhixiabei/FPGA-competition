// Latency readout with shared decimal conversion for three values.
module video_latency_osd #(
    parameter integer PANEL_X = 984,
    parameter integer PANEL_Y = 16,
    parameter integer LARGE_TEXT = 0,
    parameter integer NARROW_TEXT = 0
) (
    input wire I_clk, I_rst_n,
    input wire I_sample_strobe, I_sample_valid,
    input wire [19:0] I_total_us, I_isp_us, I_buffer_us,
    input wire I_de,
    input wire [11:0] I_x, I_y,
    output reg O_panel, O_text, O_alert
);
    reg display_valid, current_overflow;
    reg [23:0] bcd_total, bcd_isp, bcd_buffer;
    reg busy;
    reg [1:0] field;
    reg [4:0] step;
    reg [43:0] bcd_work, bcd_adjusted;
    wire [43:0] bcd_shifted = bcd_adjusted << 1;
    integer digit;

    function [19:0] text_value;
        input [19:0] value;
        begin
            text_value = value > 20'd999999 ? 20'd999999 : value;
        end
    endfunction

    always @(*) begin
        bcd_adjusted = bcd_work;
        for (digit=0; digit<6; digit=digit+1)
            if (bcd_work[20+4*digit +: 4] >= 5)
                bcd_adjusted[20+4*digit +: 4] =
                    bcd_work[20+4*digit +: 4] + 4'd3;
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            display_valid<=0; current_overflow<=0;
            bcd_total<=0; bcd_isp<=0; bcd_buffer<=0;
            busy<=0; field<=0; step<=0; bcd_work<=0;
        end else if (I_sample_strobe) begin
            display_valid<=0;
            current_overflow<=I_total_us > 20'd128000 ||
                I_isp_us > 20'd999999 || I_buffer_us > 20'd999999;
            busy<=I_sample_valid;
            field<=0; step<=0;
            if (I_sample_valid) begin
                bcd_work<={24'd0,text_value(I_total_us)};
            end
        end else if (busy) begin
            bcd_work<=bcd_shifted;
            step<=step+1'b1;
            if (step == 19) begin
                step<=0;
                case (field)
                    0: begin
                        bcd_total<=bcd_shifted[43:20];
                        bcd_work<={24'd0,text_value(I_isp_us)};
                        field<=1;
                    end
                    1: begin
                        bcd_isp<=bcd_shifted[43:20];
                        bcd_work<={24'd0,text_value(I_buffer_us)};
                        field<=2;
                    end
                    default: begin
                        bcd_buffer<=bcd_shifted[43:20];
                        busy<=0; display_valid<=1; field<=0;
                    end
                endcase
            end
        end
    end

    wire [11:0] px = I_x-PANEL_X;
    wire [11:0] py = I_y-PANEL_Y;
    localparam integer NARROW_LAYOUT = LARGE_TEXT != 0 && NARROW_TEXT != 0;
    localparam integer PANEL_WIDTH = LARGE_TEXT != 0 ?
        (NARROW_LAYOUT ? 320 : 400) : 280;
    localparam integer PANEL_HEIGHT = LARGE_TEXT != 0 ? 112 : 64;
    localparam integer TEXT_LEFT = NARROW_LAYOUT ? 4 : 8;
    localparam integer TEXT_TOP = LARGE_TEXT != 0 ? 8 : 4;
    localparam integer TEXT_WIDTH = LARGE_TEXT != 0 ?
        (NARROW_LAYOUT ? 312 : 384) : 256;
    localparam integer TEXT_HEIGHT = LARGE_TEXT != 0 ? 96 : 48;
    localparam integer NUMERIC_LEFT = NARROW_LAYOUT ? 4 : 6;
    localparam integer MS_COLUMN = NARROW_LAYOUT ? 11 : 14;
    wire panel = I_de && I_x>=PANEL_X && I_x<PANEL_X+PANEL_WIDTH &&
        I_y>=PANEL_Y && I_y<PANEL_Y+PANEL_HEIGHT;
    wire text_area = panel && px>=TEXT_LEFT && px<TEXT_LEFT+TEXT_WIDTH &&
        py>=TEXT_TOP && py<TEXT_TOP+TEXT_HEIGHT;
    wire [11:0] text_x = px-TEXT_LEFT;
    wire [11:0] text_y = py-TEXT_TOP;
    wire [4:0] text_col;
    wire [1:0] text_row;
    wire [3:0] font_row, font_col;
    generate if (LARGE_TEXT != 0) begin: large_font
        reg [7:0] cell_remainder;
        reg [3:0] cell_index;
        // All ASCII ink lies in source columns 2..13. Remove only the
        // empty side bearings, then double both axes: 24x32-pixel cells.
        // Divide the half-size x coordinate by twelve using four fixed
        // compare/subtract steps so the new pitch needs no DSP arithmetic.
        always @(*) begin
            cell_remainder=text_x[8:1];
            cell_index=4'd0;
            if (cell_remainder>=8'd96) begin
                cell_remainder=cell_remainder-8'd96;
                cell_index[3]=1'b1;
            end
            if (cell_remainder>=8'd48) begin
                cell_remainder=cell_remainder-8'd48;
                cell_index[2]=1'b1;
            end
            if (cell_remainder>=8'd24) begin
                cell_remainder=cell_remainder-8'd24;
                cell_index[1]=1'b1;
            end
            if (cell_remainder>=8'd12) begin
                cell_remainder=cell_remainder-8'd12;
                cell_index[0]=1'b1;
            end
        end
        assign text_col={1'b0,cell_index};
        assign text_row=text_y[6:5];
        assign font_row=text_y[4:1];
        assign font_col=4'd2+cell_remainder[3:0];
    end else begin: compact_font
        assign text_col=text_x[8:4];
        assign text_row=text_y[5:4];
        assign font_row=text_y[3:0];
        assign font_col=text_x[3:0];
    end endgenerate
    reg [7:0] character;
    reg numeric, numeric_valid;
    reg [23:0] numeric_bcd;
    reg [3:0] decimal_digit;

    always @(*) begin
        character=" "; numeric=0;
        numeric_bcd=bcd_total; numeric_valid=display_valid;
        case (text_row)
            0: begin
                numeric_bcd=bcd_total;
                if (NARROW_LAYOUT) begin
                    case (text_col)
                        0: character="T"; 1: character="O";
                        2: character="T"; 3: character=":";
                        default: character=" ";
                    endcase
                end else begin
                    case (text_col)
                        0: character="T"; 1: character="O"; 2: character="T";
                        3: character="A"; 4: character="L"; 5: character=":";
                        default: character=" ";
                    endcase
                end
            end
            1: begin
                numeric_bcd=bcd_isp;
                case (text_col)
                    0: character="I"; 1: character="S";
                    2: character="P"; 3: character=":";
                    default: character=" ";
                endcase
            end
            default: begin
                numeric_bcd=bcd_buffer;
                case (text_col)
                    0: character="B"; 1: character="U";
                    2: character="F"; 3: character=":";
                    default: character=" ";
                endcase
            end
        endcase
        if (text_col>=NUMERIC_LEFT && text_col<=NUMERIC_LEFT+6)
            numeric=1;
        if (text_col==MS_COLUMN) character="M";
        if (text_col==MS_COLUMN+1) character="S";
        // Decode the fixed screen columns in parallel. A column subtraction
        // before the digit mux extends the coordinate-to-font timing path.
        decimal_digit=
            (numeric_bcd[23:20] & {4{text_col==NUMERIC_LEFT}}) |
            (numeric_bcd[19:16] & {4{text_col==NUMERIC_LEFT+1}}) |
            (numeric_bcd[15:12] & {4{text_col==NUMERIC_LEFT+2}}) |
            (numeric_bcd[11:8]  & {4{text_col==NUMERIC_LEFT+4}}) |
            (numeric_bcd[7:4]   & {4{text_col==NUMERIC_LEFT+5}}) |
            (numeric_bcd[3:0]   & {4{text_col==NUMERIC_LEFT+6}});
        if (numeric) begin
            if (numeric_valid)
                character=text_col==NUMERIC_LEFT+3 ? "." : {4'h3,decimal_digit};
            else case (text_col)
                NUMERIC_LEFT: character="N";
                NUMERIC_LEFT+1: character="/";
                NUMERIC_LEFT+2: character="A";
                default: character=" ";
            endcase
        end
    end

    wire [15:0] glyph;
    osd_char_lib u_font (.I_char(character), .I_row(font_row), .O_row_bits(glyph));
    wire glyph_on = glyph[15-font_col];

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_panel<=0; O_text<=0; O_alert<=0;
        end else begin
            O_panel<=panel;
            O_text<=text_area && glyph_on;
            O_alert<=text_area && text_row==0 && numeric &&
                display_valid && current_overflow;
        end
    end
endmodule
