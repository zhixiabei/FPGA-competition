// Display-frame latency samples. Decimal conversion is shared across all five
// fields and finishes during the first scan line, ahead of the visible panel.
module video_latency_osd #(
    parameter integer PANEL_X = 864,
    parameter integer PANEL_Y = 16
) (
    input wire I_clk, I_rst_n,
    input wire I_sample_strobe, I_sample_valid,
    input wire [19:0] I_total_us, I_isp_us, I_buffer_us,
    input wire I_de,
    input wire [11:0] I_x, I_y,
    output reg O_panel, O_text, O_graph, O_alert
);
    reg have_valid, display_valid, extrema_ready, current_overflow;
    reg [19:0] min_us, max_us;
    reg [19:0] convert_isp, convert_buffer;
    reg [23:0] bcd_total, bcd_isp, bcd_buffer, bcd_min, bcd_max;
    reg busy;
    reg [2:0] field;
    reg [4:0] step;
    reg [43:0] bcd_work, bcd_adjusted;
    wire [43:0] bcd_shifted = bcd_adjusted << 1;
    integer digit;

    reg [5:0] write_pointer, sample_slot;
    reg [6:0] history_count;
    reg sample_overflow;
    // {valid, above_128ms, height[7:0]}. Unwritten entries are masked by count.
    (* ram_style = "distributed", syn_ramstyle = "registers" *)
    reg [9:0] history [0:63];

    function [19:0] text_value;
        input [19:0] value_us;
        begin
            text_value = value_us > 20'd999999 ? 20'd999999 : value_us;
        end
    endfunction

    function [7:0] history_height;
        input [23:0] value_bcd;
        reg [8:0] hundreds, tens, units, milliseconds;
        begin
            hundreds = {5'd0,value_bcd[23:20]};
            tens = {5'd0,value_bcd[19:16]};
            units = {5'd0,value_bcd[15:12]};
            milliseconds = (hundreds << 6) + (hundreds << 5) +
                (hundreds << 2) + (tens << 3) + (tens << 1) + units;
            history_height = milliseconds[7:0];
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
            have_valid<=0; display_valid<=0; extrema_ready<=0;
            current_overflow<=0; min_us<=0; max_us<=0;
            convert_isp<=0; convert_buffer<=0;
            bcd_total<=0; bcd_isp<=0; bcd_buffer<=0; bcd_min<=0; bcd_max<=0;
            busy<=0; field<=0; step<=0; bcd_work<=0;
            write_pointer<=0; sample_slot<=0; history_count<=0; sample_overflow<=0;
        end else if (I_sample_strobe) begin
            sample_slot<=write_pointer;
            write_pointer<=write_pointer+1'b1;
            if (history_count < 64) history_count<=history_count+1'b1;
            display_valid<=0;
            busy<=I_sample_valid;
            field<=0; step<=0;
            sample_overflow<=I_total_us > 20'd128000;
            current_overflow<=I_total_us > 20'd128000 ||
                I_isp_us > 20'd999999 || I_buffer_us > 20'd999999;
            if (I_sample_valid) begin
                have_valid<=1;
                min_us<=(!have_valid || I_total_us<min_us) ? I_total_us : min_us;
                max_us<=(!have_valid || I_total_us>max_us) ? I_total_us : max_us;
                convert_isp<=I_isp_us; convert_buffer<=I_buffer_us;
                bcd_work<={24'd0,text_value(I_total_us)};
            end
        end else if (busy) begin
            bcd_work<=bcd_shifted;
            step<=step+1'b1;
            if (step == 19) begin
                step<=0;
                field<=field+1'b1;
                case (field)
                    0: begin
                        bcd_total<=bcd_shifted[43:20];
                        bcd_work<={24'd0,text_value(convert_isp)};
                    end
                    1: begin
                        bcd_isp<=bcd_shifted[43:20];
                        bcd_work<={24'd0,text_value(convert_buffer)};
                    end
                    2: begin
                        bcd_buffer<=bcd_shifted[43:20];
                        bcd_work<={24'd0,text_value(min_us)};
                    end
                    3: begin
                        bcd_min<=bcd_shifted[43:20];
                        bcd_work<={24'd0,text_value(max_us)};
                    end
                    default: begin
                        bcd_max<=bcd_shifted[43:20];
                        busy<=0; display_valid<=1; extrema_ready<=1;
                    end
                endcase
            end
        end
    end

    // Invalid display samples consume a slot but never contribute a zero.
    always @(posedge I_clk) begin
        if (I_rst_n) begin
            if (I_sample_strobe)
                history[write_pointer]<=10'd0;
            else if (busy && field==0 && step==19)
                history[sample_slot]<={1'b1,sample_overflow,
                    sample_overflow ? 8'd128 : history_height(bcd_shifted[43:20])};
        end
    end

    wire [11:0] px = I_x-PANEL_X;
    wire [11:0] py = I_y-PANEL_Y;
    wire panel = I_de && I_x>=PANEL_X && I_x<PANEL_X+400 &&
        I_y>=PANEL_Y && I_y<PANEL_Y+216;
    wire text_area = panel && px>=8 && px<392 && py>=4 && py<68;
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
        if (text_row < 3) begin
            case (text_row)
                0: case (text_col)
                    0: character="T"; 1: character="O"; 2: character="T";
                    3: character="A"; 4: character="L"; 5: character=":";
                    default: character=" ";
                endcase
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
        end else begin
            numeric_valid=extrema_ready;
            case (text_col)
                0: character="M"; 1: character="I"; 2: character="N"; 3: character=":";
                12: character="M"; 13: character="A"; 14: character="X"; 15: character=":";
                default: character=" ";
            endcase
            if (text_col>=4 && text_col<=10) begin
                numeric=1; numeric_col=text_col-4; numeric_bcd=bcd_min;
            end
            if (text_col>=16 && text_col<=22) begin
                numeric=1; numeric_col=text_col-16; numeric_bcd=bcd_max;
            end
        end
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

    // 64 slots x 4 pixels. Adding the next write address places the newest
    // sample at the right edge before and after the circular buffer wraps.
    wire graph_area = panel && px>=112 && px<368 && py>=80 && py<=208;
    wire [11:0] graph_x = px-12'd112;
    wire [5:0] graph_index = graph_x[7:2];
    wire [5:0] history_address = write_pointer+graph_index;
    wire [5:0] previous_address = history_address-1'b1;
    wire [9:0] graph_sample = history[history_address];
    wire [9:0] previous_sample = history[previous_address];
    wire [6:0] first_slot = 7'd64-history_count;
    wire slot_present = {1'b0,graph_index}>=first_slot;
    wire previous_present = {1'b0,graph_index}>first_slot;
    wire [7:0] graph_height = 8'd208-py[7:0];
    wire point_on = graph_area && slot_present && graph_sample[9] &&
        graph_height==graph_sample[7:0];
    wire connector_on = graph_area && graph_x[1:0]==0 && previous_present &&
        graph_sample[9] && previous_sample[9] &&
        ((graph_height>=graph_sample[7:0] && graph_height<=previous_sample[7:0]) ||
         (graph_height<=graph_sample[7:0] && graph_height>=previous_sample[7:0]));
    wire axes_on = graph_area && (graph_x==0 || py==208 ||
        ((py==80 || py==144) && graph_x[2:0]==0));

    wire scale_area = panel && px>=8 && px<104 &&
        ((py>=72 && py<88) || (py>=136 && py<152) || (py>=200 && py<216));
    wire [11:0] scale_x = px-12'd8;
    wire [2:0] scale_col = scale_x[6:4];
    reg [7:0] scale_character;
    always @(*) begin
        scale_character=" ";
        if (py<88) begin
            case (scale_col)
                0: scale_character="1"; 1: scale_character="2"; 2: scale_character="8";
                3: scale_character="M"; 4: scale_character="S";
                default: scale_character=" ";
            endcase
        end else if (py<152) begin
            case (scale_col)
                1: scale_character="6"; 2: scale_character="4";
                3: scale_character="M"; 4: scale_character="S";
                default: scale_character=" ";
            endcase
        end else begin
            case (scale_col)
                2: scale_character="0"; 3: scale_character="M"; 4: scale_character="S";
                default: scale_character=" ";
            endcase
        end
    end
    wire [7:0] font_character = scale_area ? scale_character : character;
    wire [3:0] font_row = scale_area ? (py[3:0]-4'd8) : text_y[3:0];
    wire [3:0] font_col = scale_area ? scale_x[3:0] : text_x[3:0];
    wire [15:0] glyph;
    osd_char_lib u_font (.I_char(font_character), .I_row(font_row), .O_row_bits(glyph));
    wire glyph_on = font_character=="." ?
        ((font_row==11 || font_row==12) && (font_col==6 || font_col==7)) :
        font_character=="/" ?
        (font_row>=2 && font_row<=11 && font_col==13-font_row) :
        glyph[15-font_col];

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_panel<=0; O_text<=0; O_graph<=0; O_alert<=0;
        end else begin
            O_panel<=panel;
            O_text<=(text_area || scale_area) && glyph_on;
            O_graph<=point_on || connector_on || axes_on;
            O_alert<=((point_on || connector_on) && graph_sample[8]) ||
                (text_area && text_row==0 && numeric && display_valid && current_overflow);
        end
    end
endmodule
