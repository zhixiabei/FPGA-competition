// Compact latency readout with shared decimal conversion for three values.
module video_latency_osd #(
    parameter integer PANEL_X = 984,
    parameter integer PANEL_Y = 16
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
    wire panel = I_de && I_x>=PANEL_X && I_x<PANEL_X+280 &&
        I_y>=PANEL_Y && I_y<PANEL_Y+64;
    wire text_area = panel && px>=8 && px<264 && py>=4 && py<52;
    wire [11:0] text_x = px-12'd8;
    wire [11:0] text_y = py-12'd4;
    wire [4:0] text_col = text_x[8:4];
    wire [1:0] text_row = text_y[5:4];
    reg [7:0] character;
    reg numeric, numeric_valid;
    reg [2:0] numeric_col;
    reg [23:0] numeric_bcd;
    reg [3:0] decimal_digit;

    always @(*) begin
        character=" "; numeric=0; numeric_col=0;
        numeric_bcd=bcd_total; numeric_valid=display_valid;
        case (text_row)
            0: begin
                numeric_bcd=bcd_total;
                case (text_col)
                    0: character="T"; 1: character="O"; 2: character="T";
                    3: character="A"; 4: character="L"; 5: character=":";
                    default: character=" ";
                endcase
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
        if (text_col>=6 && text_col<=12) begin
            numeric=1; numeric_col=text_col-6;
        end
        if (text_col==14) character="M";
        if (text_col==15) character="S";
        decimal_digit=0;
        case (numeric_col)
            0: decimal_digit=numeric_bcd[23:20];
            1: decimal_digit=numeric_bcd[19:16];
            2: decimal_digit=numeric_bcd[15:12];
            4: decimal_digit=numeric_bcd[11:8];
            5: decimal_digit=numeric_bcd[7:4];
            6: decimal_digit=numeric_bcd[3:0];
            default: decimal_digit=0;
        endcase
        if (numeric) begin
            if (numeric_valid)
                character=numeric_col==3 ? "." : 8'h30+{4'd0,decimal_digit};
            else case (numeric_col)
                0: character="N"; 1: character="/"; 2: character="A";
                default: character=" ";
            endcase
        end
    end

    wire [15:0] glyph;
    osd_char_lib u_font (.I_char(character), .I_row(text_y[3:0]), .O_row_bits(glyph));
    wire glyph_on = character=="." ?
        ((text_y[3:0]==11 || text_y[3:0]==12) && (text_x[3:0]==6 || text_x[3:0]==7)) :
        character=="/" ?
        (text_y[3:0]>=2 && text_y[3:0]<=11 && text_x[3:0]==13-text_y[3:0]) :
        glyph[15-text_x[3:0]];

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
