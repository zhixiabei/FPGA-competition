// Regular upright monochrome glyphs: SimSun 16px Chinese and Consolas 18px
// ASCII on a common 16x16 cell. Bitmap data is generated offline by
// verification/refresh_osd_font.py; FPGA builds have no font-file dependency.
// Row 0 is at the top; bit 15 is the leftmost pixel.
module osd_char_lib (
    input wire [7:0] I_char,
    input wire [3:0] I_row,
    output reg [15:0] O_row_bits
);

    localparam CHAR_AN    = 8'h80;
    localparam CHAR_LU    = 8'h81;
    localparam CHAR_PING  = 8'h82;
    localparam CHAR_GUO   = 8'h83;
    localparam CHAR_XIANG = 8'h84;
    localparam CHAR_JIAO  = 8'h85;
    localparam CHAR_PU    = 8'h86;
    localparam CHAR_TAO   = 8'h87;
    localparam CHAR_JU    = 8'h88;
    localparam CHAR_ZI    = 8'h89;
    localparam CHAR_CAO   = 8'h8a;
    localparam CHAR_MEI   = 8'h8b;
    localparam CHAR_A     = 8'h41;
    localparam CHAR_B     = 8'h42;
    localparam CHAR_C     = 8'h43;
    localparam CHAR_D     = 8'h44;
    localparam CHAR_E     = 8'h45;
    localparam CHAR_F     = 8'h46;
    localparam CHAR_G     = 8'h47;
    localparam CHAR_H     = 8'h48;
    localparam CHAR_I     = 8'h49;
    localparam CHAR_J     = 8'h4a;
    localparam CHAR_K     = 8'h4b;
    localparam CHAR_L     = 8'h4c;
    localparam CHAR_M     = 8'h4d;
    localparam CHAR_N     = 8'h4e;
    localparam CHAR_O     = 8'h4f;
    localparam CHAR_P     = 8'h50;
    localparam CHAR_Q     = 8'h51;
    localparam CHAR_R     = 8'h52;
    localparam CHAR_S     = 8'h53;
    localparam CHAR_T     = 8'h54;
    localparam CHAR_U     = 8'h55;
    localparam CHAR_V     = 8'h56;
    localparam CHAR_W     = 8'h57;
    localparam CHAR_X     = 8'h58;
    localparam CHAR_Y     = 8'h59;
    localparam CHAR_Z     = 8'h5a;
    localparam CHAR_0     = 8'h30;
    localparam CHAR_1     = 8'h31;
    localparam CHAR_2     = 8'h32;
    localparam CHAR_3     = 8'h33;
    localparam CHAR_4     = 8'h34;
    localparam CHAR_5     = 8'h35;
    localparam CHAR_6     = 8'h36;
    localparam CHAR_7     = 8'h37;
    localparam CHAR_8     = 8'h38;
    localparam CHAR_9     = 8'h39;
    localparam CHAR_COLON = 8'h3a;
    localparam CHAR_DOT   = 8'h2e;
    localparam CHAR_HYPHEN = 8'h2d;
    localparam CHAR_SLASH = 8'h2f;
    localparam CHAR_LOWER_G = 8'h67;
    localparam CHAR_LOWER_K = 8'h6b;

    localparam [255:0] GLYPH_PING = 256'h0100010001000100fffe010009200910111001007ffc00000820fffe08200820;
    localparam [255:0] GLYPH_GUO = 256'h0100c106311809200540fffe010011101ff0111011101ff0111011101ff00000;
    localparam [255:0] GLYPH_XIANG = 256'h10101ff0101010101ff010101010dff6311809200540fffe010001001f800070;
    localparam [255:0] GLYPH_JIAO = 256'h42442244248810001ffc10801ff810805ff830801ffc08800920fffe08200820;
    localparam [255:0] GLYPH_PU = 256'h204c22a422243fe422243fe422243fe482047ff442243ffc2440fffe04400440;
    localparam [255:0] GLYPH_TAO = 256'h001000283fe4222422240204fffc020422049fe448043ffc20000820fffe0820;
    localparam [255:0] GLYPH_JU = 256'h1206127212521376128a925253fe54203b5030941052fbfe1030104813fc1000;
    localparam [255:0] GLYPH_ZI = 256'h02000500010001000100010001000100fffe010001800040002000107ff80000;
    localparam [255:0] GLYPH_CAO = 256'h0100010001000100fffe01001ff010101ff010101ff000000440fffe04400440;
    localparam [255:0] GLYPH_MEI = 256'h006000103ffc21102210fffe111012109ff040003ffc10001440fffe04400440;
    localparam [255:0] GLYPH_DOT = 256'h0000000000000380038003800000000000000000000000000000000000000000;
    localparam [255:0] GLYPH_HYPHEN = 256'h000000000000000000000000000007c000000000000000000000000000000000;
    localparam [255:0] GLYPH_SLASH = 256'h00000c0004000400060002000300010001000180008000c00040004000600020;
    localparam [255:0] GLYPH_LOWER_G = 256'h07e00c380c180c1807f00c000c0007e0063006300630063003f8000000000000;
    localparam [255:0] GLYPH_LOWER_K = 256'h00000000000006180630066006c0078007c006e0067006380600060006000600;

    always @(*) begin
        case(I_char)
            CHAR_AN: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0200;
                    4'd1: O_row_bits = 16'h0100;
                    4'd2: O_row_bits = 16'h3ffc;
                    4'd3: O_row_bits = 16'h2004;
                    4'd4: O_row_bits = 16'h4208;
                    4'd5: O_row_bits = 16'h0200;
                    4'd6: O_row_bits = 16'h0200;
                    4'd7: O_row_bits = 16'hfffe;
                    4'd8: O_row_bits = 16'h0420;
                    4'd9: O_row_bits = 16'h0820;
                    4'd10: O_row_bits = 16'h1840;
                    4'd11: O_row_bits = 16'h0640;
                    4'd12: O_row_bits = 16'h0180;
                    4'd13: O_row_bits = 16'h0260;
                    4'd14: O_row_bits = 16'h0c10;
                    4'd15: O_row_bits = 16'h7008;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_LU: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0040;
                    4'd1: O_row_bits = 16'h7c40;
                    4'd2: O_row_bits = 16'h4478;
                    4'd3: O_row_bits = 16'h4488;
                    4'd4: O_row_bits = 16'h4550;
                    4'd5: O_row_bits = 16'h7c20;
                    4'd6: O_row_bits = 16'h1050;
                    4'd7: O_row_bits = 16'h1088;
                    4'd8: O_row_bits = 16'h1106;
                    4'd9: O_row_bits = 16'h5cf8;
                    4'd10: O_row_bits = 16'h5088;
                    4'd11: O_row_bits = 16'h5088;
                    4'd12: O_row_bits = 16'h5088;
                    4'd13: O_row_bits = 16'h5c88;
                    4'd14: O_row_bits = 16'he0f8;
                    4'd15: O_row_bits = 16'h0088;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_A: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h0380;
                    4'd3: O_row_bits = 16'h0280;
                    4'd4: O_row_bits = 16'h02c0;
                    4'd5: O_row_bits = 16'h06c0;
                    4'd6: O_row_bits = 16'h0440;
                    4'd7: O_row_bits = 16'h0c60;
                    4'd8: O_row_bits = 16'h0c60;
                    4'd9: O_row_bits = 16'h0fe0;
                    4'd10: O_row_bits = 16'h1830;
                    4'd11: O_row_bits = 16'h1830;
                    4'd12: O_row_bits = 16'h1010;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_B: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h0fe0;
                    4'd3: O_row_bits = 16'h0c70;
                    4'd4: O_row_bits = 16'h0c30;
                    4'd5: O_row_bits = 16'h0c30;
                    4'd6: O_row_bits = 16'h0c60;
                    4'd7: O_row_bits = 16'h0fc0;
                    4'd8: O_row_bits = 16'h0c70;
                    4'd9: O_row_bits = 16'h0c30;
                    4'd10: O_row_bits = 16'h0c30;
                    4'd11: O_row_bits = 16'h0c60;
                    4'd12: O_row_bits = 16'h0fc0;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_C: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h01e0;
                    4'd3: O_row_bits = 16'h0710;
                    4'd4: O_row_bits = 16'h0600;
                    4'd5: O_row_bits = 16'h0c00;
                    4'd6: O_row_bits = 16'h0c00;
                    4'd7: O_row_bits = 16'h0c00;
                    4'd8: O_row_bits = 16'h0c00;
                    4'd9: O_row_bits = 16'h0c00;
                    4'd10: O_row_bits = 16'h0600;
                    4'd11: O_row_bits = 16'h0710;
                    4'd12: O_row_bits = 16'h01e0;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_D: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h0fc0;
                    4'd3: O_row_bits = 16'h0c30;
                    4'd4: O_row_bits = 16'h0c30;
                    4'd5: O_row_bits = 16'h0c18;
                    4'd6: O_row_bits = 16'h0c18;
                    4'd7: O_row_bits = 16'h0c18;
                    4'd8: O_row_bits = 16'h0c18;
                    4'd9: O_row_bits = 16'h0c18;
                    4'd10: O_row_bits = 16'h0c30;
                    4'd11: O_row_bits = 16'h0c60;
                    4'd12: O_row_bits = 16'h0fc0;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_E: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h07f0;
                    4'd3: O_row_bits = 16'h0600;
                    4'd4: O_row_bits = 16'h0600;
                    4'd5: O_row_bits = 16'h0600;
                    4'd6: O_row_bits = 16'h0600;
                    4'd7: O_row_bits = 16'h07f0;
                    4'd8: O_row_bits = 16'h0600;
                    4'd9: O_row_bits = 16'h0600;
                    4'd10: O_row_bits = 16'h0600;
                    4'd11: O_row_bits = 16'h0600;
                    4'd12: O_row_bits = 16'h07f0;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_F: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h07e0;
                    4'd3: O_row_bits = 16'h0600;
                    4'd4: O_row_bits = 16'h0600;
                    4'd5: O_row_bits = 16'h0600;
                    4'd6: O_row_bits = 16'h0600;
                    4'd7: O_row_bits = 16'h07e0;
                    4'd8: O_row_bits = 16'h0600;
                    4'd9: O_row_bits = 16'h0600;
                    4'd10: O_row_bits = 16'h0600;
                    4'd11: O_row_bits = 16'h0600;
                    4'd12: O_row_bits = 16'h0600;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_G: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h01f0;
                    4'd3: O_row_bits = 16'h0308;
                    4'd4: O_row_bits = 16'h0600;
                    4'd5: O_row_bits = 16'h0c00;
                    4'd6: O_row_bits = 16'h0c00;
                    4'd7: O_row_bits = 16'h0c78;
                    4'd8: O_row_bits = 16'h0c18;
                    4'd9: O_row_bits = 16'h0c18;
                    4'd10: O_row_bits = 16'h0618;
                    4'd11: O_row_bits = 16'h0718;
                    4'd12: O_row_bits = 16'h01f8;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_H: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h0c30;
                    4'd3: O_row_bits = 16'h0c30;
                    4'd4: O_row_bits = 16'h0c30;
                    4'd5: O_row_bits = 16'h0c30;
                    4'd6: O_row_bits = 16'h0c30;
                    4'd7: O_row_bits = 16'h0ff0;
                    4'd8: O_row_bits = 16'h0c30;
                    4'd9: O_row_bits = 16'h0c30;
                    4'd10: O_row_bits = 16'h0c30;
                    4'd11: O_row_bits = 16'h0c30;
                    4'd12: O_row_bits = 16'h0c30;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_I: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h0ff0;
                    4'd3: O_row_bits = 16'h0180;
                    4'd4: O_row_bits = 16'h0180;
                    4'd5: O_row_bits = 16'h0180;
                    4'd6: O_row_bits = 16'h0180;
                    4'd7: O_row_bits = 16'h0180;
                    4'd8: O_row_bits = 16'h0180;
                    4'd9: O_row_bits = 16'h0180;
                    4'd10: O_row_bits = 16'h0180;
                    4'd11: O_row_bits = 16'h0180;
                    4'd12: O_row_bits = 16'h0ff0;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_J: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h07f0;
                    4'd3: O_row_bits = 16'h0030;
                    4'd4: O_row_bits = 16'h0030;
                    4'd5: O_row_bits = 16'h0030;
                    4'd6: O_row_bits = 16'h0030;
                    4'd7: O_row_bits = 16'h0030;
                    4'd8: O_row_bits = 16'h0030;
                    4'd9: O_row_bits = 16'h0030;
                    4'd10: O_row_bits = 16'h0030;
                    4'd11: O_row_bits = 16'h0460;
                    4'd12: O_row_bits = 16'h03c0;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_K: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h0c20;
                    4'd3: O_row_bits = 16'h0c60;
                    4'd4: O_row_bits = 16'h0cc0;
                    4'd5: O_row_bits = 16'h0c80;
                    4'd6: O_row_bits = 16'h0d00;
                    4'd7: O_row_bits = 16'h0f00;
                    4'd8: O_row_bits = 16'h0d00;
                    4'd9: O_row_bits = 16'h0d80;
                    4'd10: O_row_bits = 16'h0cc0;
                    4'd11: O_row_bits = 16'h0c60;
                    4'd12: O_row_bits = 16'h0c30;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_L: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h0600;
                    4'd3: O_row_bits = 16'h0600;
                    4'd4: O_row_bits = 16'h0600;
                    4'd5: O_row_bits = 16'h0600;
                    4'd6: O_row_bits = 16'h0600;
                    4'd7: O_row_bits = 16'h0600;
                    4'd8: O_row_bits = 16'h0600;
                    4'd9: O_row_bits = 16'h0600;
                    4'd10: O_row_bits = 16'h0600;
                    4'd11: O_row_bits = 16'h0600;
                    4'd12: O_row_bits = 16'h07f0;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_M: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h0c30;
                    4'd3: O_row_bits = 16'h0a50;
                    4'd4: O_row_bits = 16'h0a50;
                    4'd5: O_row_bits = 16'h0a50;
                    4'd6: O_row_bits = 16'h0990;
                    4'd7: O_row_bits = 16'h0990;
                    4'd8: O_row_bits = 16'h0990;
                    4'd9: O_row_bits = 16'h0810;
                    4'd10: O_row_bits = 16'h0810;
                    4'd11: O_row_bits = 16'h0810;
                    4'd12: O_row_bits = 16'h0810;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_N: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h0e30;
                    4'd3: O_row_bits = 16'h0e30;
                    4'd4: O_row_bits = 16'h0e30;
                    4'd5: O_row_bits = 16'h0d30;
                    4'd6: O_row_bits = 16'h0d30;
                    4'd7: O_row_bits = 16'h0d30;
                    4'd8: O_row_bits = 16'h0cb0;
                    4'd9: O_row_bits = 16'h0cb0;
                    4'd10: O_row_bits = 16'h0c70;
                    4'd11: O_row_bits = 16'h0c70;
                    4'd12: O_row_bits = 16'h0c70;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_O: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h03c0;
                    4'd3: O_row_bits = 16'h0660;
                    4'd4: O_row_bits = 16'h0430;
                    4'd5: O_row_bits = 16'h0c30;
                    4'd6: O_row_bits = 16'h0c30;
                    4'd7: O_row_bits = 16'h0c30;
                    4'd8: O_row_bits = 16'h0c30;
                    4'd9: O_row_bits = 16'h0c30;
                    4'd10: O_row_bits = 16'h0c20;
                    4'd11: O_row_bits = 16'h0660;
                    4'd12: O_row_bits = 16'h03c0;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_P: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h0fc0;
                    4'd3: O_row_bits = 16'h0c60;
                    4'd4: O_row_bits = 16'h0c30;
                    4'd5: O_row_bits = 16'h0c30;
                    4'd6: O_row_bits = 16'h0c30;
                    4'd7: O_row_bits = 16'h0c60;
                    4'd8: O_row_bits = 16'h0fc0;
                    4'd9: O_row_bits = 16'h0c00;
                    4'd10: O_row_bits = 16'h0c00;
                    4'd11: O_row_bits = 16'h0c00;
                    4'd12: O_row_bits = 16'h0c00;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_Q: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h03e0;
                    4'd3: O_row_bits = 16'h0630;
                    4'd4: O_row_bits = 16'h0618;
                    4'd5: O_row_bits = 16'h0c18;
                    4'd6: O_row_bits = 16'h0c18;
                    4'd7: O_row_bits = 16'h0c18;
                    4'd8: O_row_bits = 16'h0c18;
                    4'd9: O_row_bits = 16'h0c18;
                    4'd10: O_row_bits = 16'h0c30;
                    4'd11: O_row_bits = 16'h0630;
                    4'd12: O_row_bits = 16'h03e0;
                    4'd13: O_row_bits = 16'h00c0;
                    4'd14: O_row_bits = 16'h00c8;
                    4'd15: O_row_bits = 16'h0070;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_R: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h07e0;
                    4'd3: O_row_bits = 16'h0630;
                    4'd4: O_row_bits = 16'h0630;
                    4'd5: O_row_bits = 16'h0630;
                    4'd6: O_row_bits = 16'h0670;
                    4'd7: O_row_bits = 16'h07c0;
                    4'd8: O_row_bits = 16'h0660;
                    4'd9: O_row_bits = 16'h0660;
                    4'd10: O_row_bits = 16'h0630;
                    4'd11: O_row_bits = 16'h0630;
                    4'd12: O_row_bits = 16'h0618;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_S: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h03c0;
                    4'd3: O_row_bits = 16'h0e20;
                    4'd4: O_row_bits = 16'h0c00;
                    4'd5: O_row_bits = 16'h0c00;
                    4'd6: O_row_bits = 16'h0700;
                    4'd7: O_row_bits = 16'h03c0;
                    4'd8: O_row_bits = 16'h0070;
                    4'd9: O_row_bits = 16'h0030;
                    4'd10: O_row_bits = 16'h0030;
                    4'd11: O_row_bits = 16'h0870;
                    4'd12: O_row_bits = 16'h07c0;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_T: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h0ff0;
                    4'd3: O_row_bits = 16'h0180;
                    4'd4: O_row_bits = 16'h0180;
                    4'd5: O_row_bits = 16'h0180;
                    4'd6: O_row_bits = 16'h0180;
                    4'd7: O_row_bits = 16'h0180;
                    4'd8: O_row_bits = 16'h0180;
                    4'd9: O_row_bits = 16'h0180;
                    4'd10: O_row_bits = 16'h0180;
                    4'd11: O_row_bits = 16'h0180;
                    4'd12: O_row_bits = 16'h0180;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_U: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h0c30;
                    4'd3: O_row_bits = 16'h0c30;
                    4'd4: O_row_bits = 16'h0c30;
                    4'd5: O_row_bits = 16'h0c30;
                    4'd6: O_row_bits = 16'h0c30;
                    4'd7: O_row_bits = 16'h0c30;
                    4'd8: O_row_bits = 16'h0c30;
                    4'd9: O_row_bits = 16'h0c30;
                    4'd10: O_row_bits = 16'h0c30;
                    4'd11: O_row_bits = 16'h0660;
                    4'd12: O_row_bits = 16'h03c0;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_V: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h0808;
                    4'd3: O_row_bits = 16'h0c18;
                    4'd4: O_row_bits = 16'h0c18;
                    4'd5: O_row_bits = 16'h0410;
                    4'd6: O_row_bits = 16'h0630;
                    4'd7: O_row_bits = 16'h0620;
                    4'd8: O_row_bits = 16'h0220;
                    4'd9: O_row_bits = 16'h0360;
                    4'd10: O_row_bits = 16'h0340;
                    4'd11: O_row_bits = 16'h0140;
                    4'd12: O_row_bits = 16'h01c0;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_W: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h0c18;
                    4'd3: O_row_bits = 16'h0c18;
                    4'd4: O_row_bits = 16'h0c18;
                    4'd5: O_row_bits = 16'h0c18;
                    4'd6: O_row_bits = 16'h0c98;
                    4'd7: O_row_bits = 16'h0d98;
                    4'd8: O_row_bits = 16'h05d0;
                    4'd9: O_row_bits = 16'h0550;
                    4'd10: O_row_bits = 16'h0550;
                    4'd11: O_row_bits = 16'h0670;
                    4'd12: O_row_bits = 16'h0630;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_X: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h1830;
                    4'd3: O_row_bits = 16'h0c60;
                    4'd4: O_row_bits = 16'h0640;
                    4'd5: O_row_bits = 16'h03c0;
                    4'd6: O_row_bits = 16'h0380;
                    4'd7: O_row_bits = 16'h0180;
                    4'd8: O_row_bits = 16'h03c0;
                    4'd9: O_row_bits = 16'h06e0;
                    4'd10: O_row_bits = 16'h0660;
                    4'd11: O_row_bits = 16'h0c30;
                    4'd12: O_row_bits = 16'h1818;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_Y: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h1818;
                    4'd3: O_row_bits = 16'h0c30;
                    4'd4: O_row_bits = 16'h0c30;
                    4'd5: O_row_bits = 16'h0660;
                    4'd6: O_row_bits = 16'h0340;
                    4'd7: O_row_bits = 16'h03c0;
                    4'd8: O_row_bits = 16'h0180;
                    4'd9: O_row_bits = 16'h0180;
                    4'd10: O_row_bits = 16'h0180;
                    4'd11: O_row_bits = 16'h0180;
                    4'd12: O_row_bits = 16'h0180;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_Z: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h0ff0;
                    4'd3: O_row_bits = 16'h0020;
                    4'd4: O_row_bits = 16'h0060;
                    4'd5: O_row_bits = 16'h0040;
                    4'd6: O_row_bits = 16'h0080;
                    4'd7: O_row_bits = 16'h0180;
                    4'd8: O_row_bits = 16'h0100;
                    4'd9: O_row_bits = 16'h0300;
                    4'd10: O_row_bits = 16'h0600;
                    4'd11: O_row_bits = 16'h0400;
                    4'd12: O_row_bits = 16'h0ff0;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_0: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h03e0;
                    4'd3: O_row_bits = 16'h0630;
                    4'd4: O_row_bits = 16'h0430;
                    4'd5: O_row_bits = 16'h0c38;
                    4'd6: O_row_bits = 16'h0c58;
                    4'd7: O_row_bits = 16'h0c98;
                    4'd8: O_row_bits = 16'h0d18;
                    4'd9: O_row_bits = 16'h0e18;
                    4'd10: O_row_bits = 16'h0c10;
                    4'd11: O_row_bits = 16'h0630;
                    4'd12: O_row_bits = 16'h03e0;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_1: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h01c0;
                    4'd3: O_row_bits = 16'h02c0;
                    4'd4: O_row_bits = 16'h04c0;
                    4'd5: O_row_bits = 16'h00c0;
                    4'd6: O_row_bits = 16'h00c0;
                    4'd7: O_row_bits = 16'h00c0;
                    4'd8: O_row_bits = 16'h00c0;
                    4'd9: O_row_bits = 16'h00c0;
                    4'd10: O_row_bits = 16'h00c0;
                    4'd11: O_row_bits = 16'h00c0;
                    4'd12: O_row_bits = 16'h07f0;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_2: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h07c0;
                    4'd3: O_row_bits = 16'h08e0;
                    4'd4: O_row_bits = 16'h0060;
                    4'd5: O_row_bits = 16'h0060;
                    4'd6: O_row_bits = 16'h0060;
                    4'd7: O_row_bits = 16'h00c0;
                    4'd8: O_row_bits = 16'h01c0;
                    4'd9: O_row_bits = 16'h0380;
                    4'd10: O_row_bits = 16'h0700;
                    4'd11: O_row_bits = 16'h0600;
                    4'd12: O_row_bits = 16'h0ff0;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_3: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h0fc0;
                    4'd3: O_row_bits = 16'h00e0;
                    4'd4: O_row_bits = 16'h0060;
                    4'd5: O_row_bits = 16'h0060;
                    4'd6: O_row_bits = 16'h00c0;
                    4'd7: O_row_bits = 16'h03c0;
                    4'd8: O_row_bits = 16'h0070;
                    4'd9: O_row_bits = 16'h0030;
                    4'd10: O_row_bits = 16'h0030;
                    4'd11: O_row_bits = 16'h0060;
                    4'd12: O_row_bits = 16'h0fc0;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_4: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h00e0;
                    4'd3: O_row_bits = 16'h01e0;
                    4'd4: O_row_bits = 16'h0160;
                    4'd5: O_row_bits = 16'h0360;
                    4'd6: O_row_bits = 16'h0660;
                    4'd7: O_row_bits = 16'h0460;
                    4'd8: O_row_bits = 16'h0c60;
                    4'd9: O_row_bits = 16'h1860;
                    4'd10: O_row_bits = 16'h1ff0;
                    4'd11: O_row_bits = 16'h0060;
                    4'd12: O_row_bits = 16'h0060;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_5: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h07e0;
                    4'd3: O_row_bits = 16'h0600;
                    4'd4: O_row_bits = 16'h0600;
                    4'd5: O_row_bits = 16'h0600;
                    4'd6: O_row_bits = 16'h07c0;
                    4'd7: O_row_bits = 16'h0070;
                    4'd8: O_row_bits = 16'h0030;
                    4'd9: O_row_bits = 16'h0030;
                    4'd10: O_row_bits = 16'h0030;
                    4'd11: O_row_bits = 16'h0060;
                    4'd12: O_row_bits = 16'h07c0;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_6: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h01e0;
                    4'd3: O_row_bits = 16'h0700;
                    4'd4: O_row_bits = 16'h0600;
                    4'd5: O_row_bits = 16'h0c00;
                    4'd6: O_row_bits = 16'h0de0;
                    4'd7: O_row_bits = 16'h0e70;
                    4'd8: O_row_bits = 16'h0c30;
                    4'd9: O_row_bits = 16'h0c30;
                    4'd10: O_row_bits = 16'h0c30;
                    4'd11: O_row_bits = 16'h0660;
                    4'd12: O_row_bits = 16'h03c0;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_7: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h0ff0;
                    4'd3: O_row_bits = 16'h0030;
                    4'd4: O_row_bits = 16'h0020;
                    4'd5: O_row_bits = 16'h0060;
                    4'd6: O_row_bits = 16'h0040;
                    4'd7: O_row_bits = 16'h00c0;
                    4'd8: O_row_bits = 16'h0080;
                    4'd9: O_row_bits = 16'h0180;
                    4'd10: O_row_bits = 16'h0100;
                    4'd11: O_row_bits = 16'h0300;
                    4'd12: O_row_bits = 16'h0200;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_8: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h03e0;
                    4'd3: O_row_bits = 16'h0c30;
                    4'd4: O_row_bits = 16'h0c30;
                    4'd5: O_row_bits = 16'h0c30;
                    4'd6: O_row_bits = 16'h0660;
                    4'd7: O_row_bits = 16'h03c0;
                    4'd8: O_row_bits = 16'h0660;
                    4'd9: O_row_bits = 16'h0c30;
                    4'd10: O_row_bits = 16'h0c30;
                    4'd11: O_row_bits = 16'h0c30;
                    4'd12: O_row_bits = 16'h07c0;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_9: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h03c0;
                    4'd3: O_row_bits = 16'h0660;
                    4'd4: O_row_bits = 16'h0c30;
                    4'd5: O_row_bits = 16'h0c30;
                    4'd6: O_row_bits = 16'h0c30;
                    4'd7: O_row_bits = 16'h0e70;
                    4'd8: O_row_bits = 16'h07b0;
                    4'd9: O_row_bits = 16'h0030;
                    4'd10: O_row_bits = 16'h0060;
                    4'd11: O_row_bits = 16'h00e0;
                    4'd12: O_row_bits = 16'h0780;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_COLON: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h0000;
                    4'd3: O_row_bits = 16'h0000;
                    4'd4: O_row_bits = 16'h01c0;
                    4'd5: O_row_bits = 16'h01c0;
                    4'd6: O_row_bits = 16'h01c0;
                    4'd7: O_row_bits = 16'h0000;
                    4'd8: O_row_bits = 16'h0000;
                    4'd9: O_row_bits = 16'h0000;
                    4'd10: O_row_bits = 16'h01c0;
                    4'd11: O_row_bits = 16'h01c0;
                    4'd12: O_row_bits = 16'h01c0;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_DOT: O_row_bits = GLYPH_DOT[I_row*16 +: 16];
            CHAR_HYPHEN: O_row_bits = GLYPH_HYPHEN[I_row*16 +: 16];
            CHAR_SLASH: O_row_bits = GLYPH_SLASH[I_row*16 +: 16];
            CHAR_LOWER_G: O_row_bits = GLYPH_LOWER_G[I_row*16 +: 16];
            CHAR_LOWER_K: O_row_bits = GLYPH_LOWER_K[I_row*16 +: 16];
            CHAR_PING: O_row_bits = GLYPH_PING[I_row*16 +: 16];
            CHAR_GUO: O_row_bits = GLYPH_GUO[I_row*16 +: 16];
            CHAR_XIANG: O_row_bits = GLYPH_XIANG[I_row*16 +: 16];
            CHAR_JIAO: O_row_bits = GLYPH_JIAO[I_row*16 +: 16];
            CHAR_PU: O_row_bits = GLYPH_PU[I_row*16 +: 16];
            CHAR_TAO: O_row_bits = GLYPH_TAO[I_row*16 +: 16];
            CHAR_JU: O_row_bits = GLYPH_JU[I_row*16 +: 16];
            CHAR_ZI: O_row_bits = GLYPH_ZI[I_row*16 +: 16];
            CHAR_CAO: O_row_bits = GLYPH_CAO[I_row*16 +: 16];
            CHAR_MEI: O_row_bits = GLYPH_MEI[I_row*16 +: 16];
            default: O_row_bits = 16'h0000;
        endcase
    end

endmodule

// Same glyphs as osd_char_lib, read synchronously from one 1024x16 ROM.
// Uppercase ASCII keeps its low six bits; digits/colon keep 48..58.
// The Chinese glyphs use otherwise empty entries 32 through 43.
// Lowercase g/k use entries 59/60, leaving unsupported characters blank.
module osd_char_rom_sync (
    input wire I_clk,
    input wire [7:0] I_char,
    input wire [3:0] I_row,
    output reg [15:0] O_row_bits
);
    wire [5:0] font_index =
        I_char[7:4]==4'h8 && I_char[3:0]<=4'hb ? {2'b10,I_char[3:0]} :
        I_char==8'h2e ? 6'd44 :
        I_char==8'h2d ? 6'd45 :
        I_char==8'h2f ? 6'd46 :
        I_char==8'h67 ? 6'd59 :
        I_char==8'h6b ? 6'd60 :
        I_char[7:5]==3'b010 ? {1'b0,I_char[4:0]} :
        I_char[7:4]==4'h3 && I_char[3:0]<=4'ha ? {2'b11,I_char[3:0]} : 6'd63;
    (* rom_style = "bram" *) reg [15:0] font_rom [0:1023];
    localparam [255:0] GLYPH_AN = 256'h70080c10026001800640184008200420fffe02000200420820043ffc01000200;
    localparam [255:0] GLYPH_LU = 256'h0088e0f85c885088508850885cf81106108810507c204550448844787c400040;
    localparam [255:0] GLYPH_PING = 256'h0100010001000100fffe010009200910111001007ffc00000820fffe08200820;
    localparam [255:0] GLYPH_GUO = 256'h0100c106311809200540fffe010011101ff0111011101ff0111011101ff00000;
    localparam [255:0] GLYPH_XIANG = 256'h10101ff0101010101ff010101010dff6311809200540fffe010001001f800070;
    localparam [255:0] GLYPH_JIAO = 256'h42442244248810001ffc10801ff810805ff830801ffc08800920fffe08200820;
    localparam [255:0] GLYPH_PU = 256'h204c22a422243fe422243fe422243fe482047ff442243ffc2440fffe04400440;
    localparam [255:0] GLYPH_TAO = 256'h001000283fe4222422240204fffc020422049fe448043ffc20000820fffe0820;
    localparam [255:0] GLYPH_JU = 256'h1206127212521376128a925253fe54203b5030941052fbfe1030104813fc1000;
    localparam [255:0] GLYPH_ZI = 256'h02000500010001000100010001000100fffe010001800040002000107ff80000;
    localparam [255:0] GLYPH_CAO = 256'h0100010001000100fffe01001ff010101ff010101ff000000440fffe04400440;
    localparam [255:0] GLYPH_MEI = 256'h006000103ffc21102210fffe111012109ff040003ffc10001440fffe04400440;
    localparam [255:0] GLYPH_A = 256'h0000000000001010183018300fe00c600c60044006c002c00280038000000000;
    localparam [255:0] GLYPH_B = 256'h0000000000000fc00c600c300c300c700fc00c600c300c300c700fe000000000;
    localparam [255:0] GLYPH_C = 256'h00000000000001e0071006000c000c000c000c000c000600071001e000000000;
    localparam [255:0] GLYPH_D = 256'h0000000000000fc00c600c300c180c180c180c180c180c300c300fc000000000;
    localparam [255:0] GLYPH_E = 256'h00000000000007f0060006000600060007f0060006000600060007f000000000;
    localparam [255:0] GLYPH_F = 256'h0000000000000600060006000600060007e0060006000600060007e000000000;
    localparam [255:0] GLYPH_G = 256'h00000000000001f8071806180c180c180c780c000c000600030801f000000000;
    localparam [255:0] GLYPH_H = 256'h0000000000000c300c300c300c300c300ff00c300c300c300c300c3000000000;
    localparam [255:0] GLYPH_I = 256'h0000000000000ff00180018001800180018001800180018001800ff000000000;
    localparam [255:0] GLYPH_J = 256'h00000000000003c004600030003000300030003000300030003007f000000000;
    localparam [255:0] GLYPH_K = 256'h0000000000000c300c600cc00d800d000f000d000c800cc00c600c2000000000;
    localparam [255:0] GLYPH_L = 256'h00000000000007f0060006000600060006000600060006000600060000000000;
    localparam [255:0] GLYPH_M = 256'h00000000000008100810081008100990099009900a500a500a500c3000000000;
    localparam [255:0] GLYPH_N = 256'h0000000000000c700c700c700cb00cb00d300d300d300e300e300e3000000000;
    localparam [255:0] GLYPH_O = 256'h00000000000003c006600c200c300c300c300c300c300430066003c000000000;
    localparam [255:0] GLYPH_P = 256'h0000000000000c000c000c000c000fc00c600c300c300c300c600fc000000000;
    localparam [255:0] GLYPH_Q = 256'h007000c800c003e006300c300c180c180c180c180c180618063003e000000000;
    localparam [255:0] GLYPH_R = 256'h0000000000000618063006300660066007c0067006300630063007e000000000;
    localparam [255:0] GLYPH_S = 256'h00000000000007c0087000300030007003c007000c000c000e2003c000000000;
    localparam [255:0] GLYPH_T = 256'h00000000000001800180018001800180018001800180018001800ff000000000;
    localparam [255:0] GLYPH_U = 256'h00000000000003c006600c300c300c300c300c300c300c300c300c3000000000;
    localparam [255:0] GLYPH_V = 256'h00000000000001c001400340036002200620063004100c180c18080800000000;
    localparam [255:0] GLYPH_W = 256'h000000000000063006700550055005d00d980c980c180c180c180c1800000000;
    localparam [255:0] GLYPH_X = 256'h00000000000018180c30066006e003c00180038003c006400c60183000000000;
    localparam [255:0] GLYPH_Y = 256'h0000000000000180018001800180018003c0034006600c300c30181800000000;
    localparam [255:0] GLYPH_Z = 256'h0000000000000ff00400060003000100018000800040006000200ff000000000;
    localparam [255:0] GLYPH_0 = 256'h00000000000003e006300c100e180d180c980c580c380430063003e000000000;
    localparam [255:0] GLYPH_1 = 256'h00000000000007f000c000c000c000c000c000c000c004c002c001c000000000;
    localparam [255:0] GLYPH_2 = 256'h0000000000000ff006000700038001c000c000600060006008e007c000000000;
    localparam [255:0] GLYPH_3 = 256'h0000000000000fc0006000300030007003c000c00060006000e00fc000000000;
    localparam [255:0] GLYPH_4 = 256'h000000000000006000601ff018600c60046006600360016001e000e000000000;
    localparam [255:0] GLYPH_5 = 256'h00000000000007c00060003000300030007007c006000600060007e000000000;
    localparam [255:0] GLYPH_6 = 256'h00000000000003c006600c300c300c300e700de00c000600070001e000000000;
    localparam [255:0] GLYPH_7 = 256'h0000000000000200030001000180008000c000400060002000300ff000000000;
    localparam [255:0] GLYPH_8 = 256'h00000000000007c00c300c300c30066003c006600c300c300c3003e000000000;
    localparam [255:0] GLYPH_9 = 256'h000000000000078000e00060003007b00e700c300c300c30066003c000000000;
    localparam [255:0] GLYPH_COLON = 256'h00000000000001c001c001c000000000000001c001c001c00000000000000000;
    localparam [255:0] GLYPH_DOT = 256'h0000000000000380038003800000000000000000000000000000000000000000;
    localparam [255:0] GLYPH_HYPHEN = 256'h000000000000000000000000000007c000000000000000000000000000000000;
    localparam [255:0] GLYPH_SLASH = 256'h00000c0004000400060002000300010001000180008000c00040004000600020;
    localparam [255:0] GLYPH_LOWER_G = 256'h07e00c380c180c1807f00c000c0007e0063006300630063003f8000000000000;
    localparam [255:0] GLYPH_LOWER_K = 256'h00000000000006180630066006c0078007c006e0067006380600060006000600;
    integer init_address, init_row;
    initial begin
        for(init_address=0;init_address<1024;init_address=init_address+1)
            font_rom[init_address]=16'd0;
        for(init_row=0;init_row<16;init_row=init_row+1) begin
            font_rom[32*16+init_row]=GLYPH_AN[16*init_row+:16];
            font_rom[33*16+init_row]=GLYPH_LU[16*init_row+:16];
            font_rom[34*16+init_row]=GLYPH_PING[16*init_row+:16];
            font_rom[35*16+init_row]=GLYPH_GUO[16*init_row+:16];
            font_rom[36*16+init_row]=GLYPH_XIANG[16*init_row+:16];
            font_rom[37*16+init_row]=GLYPH_JIAO[16*init_row+:16];
            font_rom[38*16+init_row]=GLYPH_PU[16*init_row+:16];
            font_rom[39*16+init_row]=GLYPH_TAO[16*init_row+:16];
            font_rom[40*16+init_row]=GLYPH_JU[16*init_row+:16];
            font_rom[41*16+init_row]=GLYPH_ZI[16*init_row+:16];
            font_rom[42*16+init_row]=GLYPH_CAO[16*init_row+:16];
            font_rom[43*16+init_row]=GLYPH_MEI[16*init_row+:16];
            font_rom[44*16+init_row]=GLYPH_DOT[16*init_row+:16];
            font_rom[45*16+init_row]=GLYPH_HYPHEN[16*init_row+:16];
            font_rom[46*16+init_row]=GLYPH_SLASH[16*init_row+:16];
            font_rom[1*16+init_row]=GLYPH_A[16*init_row+:16];
            font_rom[2*16+init_row]=GLYPH_B[16*init_row+:16];
            font_rom[3*16+init_row]=GLYPH_C[16*init_row+:16];
            font_rom[4*16+init_row]=GLYPH_D[16*init_row+:16];
            font_rom[5*16+init_row]=GLYPH_E[16*init_row+:16];
            font_rom[6*16+init_row]=GLYPH_F[16*init_row+:16];
            font_rom[7*16+init_row]=GLYPH_G[16*init_row+:16];
            font_rom[8*16+init_row]=GLYPH_H[16*init_row+:16];
            font_rom[9*16+init_row]=GLYPH_I[16*init_row+:16];
            font_rom[10*16+init_row]=GLYPH_J[16*init_row+:16];
            font_rom[11*16+init_row]=GLYPH_K[16*init_row+:16];
            font_rom[12*16+init_row]=GLYPH_L[16*init_row+:16];
            font_rom[13*16+init_row]=GLYPH_M[16*init_row+:16];
            font_rom[14*16+init_row]=GLYPH_N[16*init_row+:16];
            font_rom[15*16+init_row]=GLYPH_O[16*init_row+:16];
            font_rom[16*16+init_row]=GLYPH_P[16*init_row+:16];
            font_rom[17*16+init_row]=GLYPH_Q[16*init_row+:16];
            font_rom[18*16+init_row]=GLYPH_R[16*init_row+:16];
            font_rom[19*16+init_row]=GLYPH_S[16*init_row+:16];
            font_rom[20*16+init_row]=GLYPH_T[16*init_row+:16];
            font_rom[21*16+init_row]=GLYPH_U[16*init_row+:16];
            font_rom[22*16+init_row]=GLYPH_V[16*init_row+:16];
            font_rom[23*16+init_row]=GLYPH_W[16*init_row+:16];
            font_rom[24*16+init_row]=GLYPH_X[16*init_row+:16];
            font_rom[25*16+init_row]=GLYPH_Y[16*init_row+:16];
            font_rom[26*16+init_row]=GLYPH_Z[16*init_row+:16];
            font_rom[48*16+init_row]=GLYPH_0[16*init_row+:16];
            font_rom[49*16+init_row]=GLYPH_1[16*init_row+:16];
            font_rom[50*16+init_row]=GLYPH_2[16*init_row+:16];
            font_rom[51*16+init_row]=GLYPH_3[16*init_row+:16];
            font_rom[52*16+init_row]=GLYPH_4[16*init_row+:16];
            font_rom[53*16+init_row]=GLYPH_5[16*init_row+:16];
            font_rom[54*16+init_row]=GLYPH_6[16*init_row+:16];
            font_rom[55*16+init_row]=GLYPH_7[16*init_row+:16];
            font_rom[56*16+init_row]=GLYPH_8[16*init_row+:16];
            font_rom[57*16+init_row]=GLYPH_9[16*init_row+:16];
            font_rom[58*16+init_row]=GLYPH_COLON[16*init_row+:16];
            font_rom[59*16+init_row]=GLYPH_LOWER_G[16*init_row+:16];
            font_rom[60*16+init_row]=GLYPH_LOWER_K[16*init_row+:16];
        end
    end
    always @(posedge I_clk)
        O_row_bits<=font_rom[{font_index,I_row}];
endmodule

