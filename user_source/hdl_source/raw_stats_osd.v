// Serial packet -> decimal table. One shared 11-cycle double-dabble unit.
// Two small BCD banks prevent mixed-frame numbers; only committed complete
// snapshots switch at display frame start. Input coordinates are one stage
// before the mixer output selection; outputs have exactly one clock latency.
module raw_stats_osd #(
    parameter integer PANEL_X = 496,
    parameter integer PANEL_Y = 176,
    parameter integer UPDATE_FRAMES = 16,
    parameter integer STALE_FRAMES = 120
) (
    input wire I_clk, I_rst_n,
    input wire I_stats_valid,
    input wire [44:0] I_stats_data,
    // {meter_seen, frame_sequence[7:0], completed_exposure[10:0], gain[7:0]}
    input wire I_ae_valid,
    input wire [27:0] I_ae_data,
    input wire I_frame_start,
    input wire I_de,
    input wire [11:0] I_x, I_y,
    output reg O_panel,
    output wire O_text,
    output reg O_alert
);
    reg [15:0] bcd_memory [0:127];
    reg display_bank, write_bank, display_valid, pending_ready;
    reg [8:0] write_clip, display_clip;
    reg [7:0] refresh_count, age;
    reg [3:0] expected_region, convert_region;
    reg [1:0] channel;
    reg busy;
    reg [3:0] step;
    reg [39:0] raw_work;
    reg [26:0] bcd_work;
    reg [26:0] adjusted;
    reg convert_ae, ae_pending_valid, ae_ready, ae_display_valid;
    reg [18:0] ae_pending_data;
    reg [15:0] ae_write_e, ae_write_g, ae_display_e, ae_display_g;
    reg meter_seen;
    reg [7:0] meter_sequence, meter_age;
    wire [3:0] packet_region = I_stats_data[44:41];
    integer digit;
    always @(*) begin
        adjusted = bcd_work;
        for (digit=0; digit<4; digit=digit+1)
            if (bcd_work[11+4*digit +: 4] >= 5)
                adjusted[11+4*digit +: 4] = bcd_work[11+4*digit +: 4]+4'd3;
    end
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            display_bank<=0; write_bank<=1; display_valid<=0; pending_ready<=0;
            write_clip<=0; display_clip<=0; refresh_count<=0; age<=STALE_FRAMES;
            expected_region<=0; convert_region<=0; channel<=0; busy<=0;
            step<=0; raw_work<=0; bcd_work<=0;
            convert_ae<=0; ae_pending_valid<=0; ae_ready<=0; ae_display_valid<=0;
            ae_pending_data<=0; ae_write_e<=0; ae_write_g<=0;
            ae_display_e<=0; ae_display_g<=0;
            meter_seen<=0; meter_sequence<=0; meter_age<=STALE_FRAMES;
        end else begin
            if (I_frame_start) begin
                if (refresh_count != 0) refresh_count<=refresh_count-1'b1;
                if (age < STALE_FRAMES) age<=age+1'b1;
                if (meter_age < STALE_FRAMES) meter_age<=meter_age+1'b1;
                if (ae_ready) begin
                    ae_display_e<=ae_write_e; ae_display_g<=ae_write_g;
                    ae_display_valid<=1; ae_ready<=0;
                end
                if (pending_ready && (refresh_count == 0 || !display_valid)) begin
                    display_bank<=write_bank;
                    write_bank<=display_bank;
                    display_clip<=write_clip;
                    display_valid<=1;
                    pending_ready<=0;
                    expected_region<=0;
                    refresh_count<=UPDATE_FRAMES-1;
                    age<=0;
                end
            end
            if (busy) begin
                bcd_work<=adjusted<<1;
                step<=step+1'b1;
                if (step == 10) begin
                    step<=0;
                    if (convert_ae) begin
                        if (channel == 0) begin
                            ae_write_e<=adjusted[25:10]; channel<=1;
                            bcd_work<={16'd0,raw_work[21:11]};
                        end else begin
                            ae_write_g<=adjusted[25:10]; busy<=0; ae_ready<=1;
                        end
                    end else if (channel == 3) begin
                        busy<=0;
                        expected_region<=convert_region+1'b1;
                    end else begin
                        channel<=channel+1'b1;
                        raw_work<=raw_work>>10;
                        bcd_work<={17'd0,raw_work[19:10]};
                    end
                end
            end
            if (!busy && ae_pending_valid && !ae_ready && !I_stats_valid) begin
                convert_ae<=1; busy<=1; channel<=0; step<=0;
                raw_work<={18'd0,3'd0,ae_pending_data[7:0],ae_pending_data[18:8]};
                bcd_work<={16'd0,ae_pending_data[18:8]};
                ae_pending_valid<=0;
            end
            if (I_ae_valid) begin
                ae_pending_data<=I_ae_data[18:0]; ae_pending_valid<=1;
                if (I_ae_data[27] && (!meter_seen || I_ae_data[26:19]!=meter_sequence))
                    meter_age<=0;
                meter_seen<=I_ae_data[27]; meter_sequence<=I_ae_data[26:19];
            end
            // Ignore new frames while a completed bank awaits display. A
            // fresh region zero restarts collection after reset/drop/recovery.
            if (I_stats_valid && !pending_ready) begin
                if (packet_region < 9 &&
                    (packet_region == 0 || ((!busy || convert_ae) && packet_region == expected_region))) begin
                    // RAW packets have priority; retry a preempted AE pair.
                    if (busy && convert_ae) ae_pending_valid<=1;
                    convert_ae<=0;
                    convert_region<=packet_region;
                    raw_work<=I_stats_data[39:0];
                    bcd_work<={17'd0,I_stats_data[9:0]};
                    step<=0; channel<=0; busy<=1;
                    if (packet_region == 0) begin
                        write_clip<={8'd0,I_stats_data[40]};
                        expected_region<=0;
                    end else write_clip[packet_region]<=I_stats_data[40];
                end else if (packet_region == 15 && expected_region == 9 && (!busy || convert_ae)) begin
                    pending_ready<=1;
                end else begin
                    busy<=0;
                    expected_region<=0;
                end
            end
        end
    end
    // No reset on the RAM itself. The visible bank is masked until valid.
    always @(posedge I_clk)
        if (I_rst_n && busy && !convert_ae && step == 10)
            bcd_memory[{write_bank,convert_region,channel}]<=adjusted[25:10];

    wire [11:0] px = I_x-PANEL_X;
    wire [11:0] py = I_y-PANEL_Y;
    wire panel = I_de && I_x>=PANEL_X && I_x<PANEL_X+768 &&
                 I_y>=PANEL_Y && I_y<PANEL_Y+352;
    wire [4:0] col = px[9:5];
    wire [3:0] row = py[8:5];
    wire [3:0] region_index = row-4'd2;
    reg [7:0] label_char;
    reg numeric, numeric_ae;
    reg [1:0] read_channel, read_digit;
    always @(*) begin
        label_char=" "; numeric=0; numeric_ae=0; read_channel=0; read_digit=0;
        if (row == 0) begin
            case (col)
                0: label_char="R"; 1: label_char="A"; 2: label_char="W";
                3: label_char="1"; 4: label_char="0";
                6: label_char=!display_valid ? "W" : age>=STALE_FRAMES ? "S" : "L";
                7: label_char=!display_valid ? "A" : age>=STALE_FRAMES ? "T" : "I";
                8: label_char=!display_valid ? "I" : age>=STALE_FRAMES ? "A" : "V";
                9: label_char=!display_valid ? "T" : age>=STALE_FRAMES ? "L" : "E";
                10: label_char=display_valid && age>=STALE_FRAMES ? "E" : " ";
                12: label_char="E";
                18: label_char="G";
                22: label_char="A";
                23: label_char=!meter_seen ? "W" : meter_age>=STALE_FRAMES ? "S" : "L";
                default: label_char=" ";
            endcase
            if (col>=13 && col<=16) begin
                numeric=1; numeric_ae=1; read_channel=0; read_digit=col-13;
            end
            if (col>=19 && col<=21) begin
                numeric=1; numeric_ae=1; read_channel=1; read_digit=col-18;
            end
        end else if (row == 1) begin
            case (col)
                0: label_char="I"; 1: label_char="D";
                4: label_char="R"; 9: label_char="G"; 10: label_char="R";
                14: label_char="G"; 15: label_char="B"; 19: label_char="B";
                23: label_char="S";
                default: label_char=" ";
            endcase
        end else if (row <= 10) begin
            if (col == 0) label_char="0";
            if (col == 1) label_char=8'h30+{4'd0,region_index}+8'd1;
            if (col >= 4 && col <= 7) begin numeric=1; read_channel=0; read_digit=col-4; end
            if (col >= 9 && col <= 12) begin numeric=1; read_channel=1; read_digit=col-9; end
            if (col >= 14 && col <= 17) begin numeric=1; read_channel=2; read_digit=col-14; end
            if (col >= 19 && col <= 22) begin numeric=1; read_channel=3; read_digit=col-19; end
            if (col == 23 && display_valid && display_clip[region_index]) label_char="S";
        end
    end
    reg [15:0] read_raw_bcd, read_ae_bcd;
    reg numeric_ae_d;
    wire [15:0] read_bcd=numeric_ae_d ? read_ae_bcd : read_raw_bcd;
    reg [7:0] char_d;
    reg numeric_d, valid_d;
    reg [1:0] digit_d;
    reg [3:0] glyph_row, glyph_col;
    always @(posedge I_clk) begin
        // Keep the existing synchronous RAM read separate from the AE mux.
        read_raw_bcd<=bcd_memory[{display_bank,region_index,read_channel}];
        read_ae_bcd<=read_channel==0 ? ae_display_e : ae_display_g;
        numeric_ae_d<=numeric_ae;
        char_d<=label_char; numeric_d<=numeric;
        valid_d<=numeric_ae ? ae_display_valid : display_valid;
        digit_d<=read_digit;
        glyph_row<=py[4:1]; glyph_col<=px[4:1];
    end
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin O_panel<=0; O_alert<=0; end
        else begin
            O_panel<=panel;
            O_alert<=display_valid && (age>=STALE_FRAMES ||
                (row>=2 && row<=10 && display_clip[region_index]));
        end
    end
    wire [3:0] decimal_digit = read_bcd >> ((3-digit_d)*4);
    wire [7:0] character = numeric_d ? (valid_d ? 8'h30+{4'd0,decimal_digit} : 8'h20) : char_d;
    wire [15:0] glyph;
    osd_char_lib u_font (.I_char(character), .I_row(glyph_row), .O_row_bits(glyph));
    assign O_text = O_panel && glyph[15-glyph_col];
endmodule
