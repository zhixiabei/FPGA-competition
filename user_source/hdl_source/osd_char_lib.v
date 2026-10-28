module osd_char_lib (
    input wire [7:0] I_char,
    input wire [3:0] I_row,
    output reg [15:0] O_row_bits
);

    localparam CHAR_AN    = 8'h80;
    localparam CHAR_LU    = 8'h81;
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

    always @(*) begin
        case(I_char)
            CHAR_AN: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0200;
                    4'd1: O_row_bits = 16'h7ff0;
                    4'd2: O_row_bits = 16'h4410;
                    4'd3: O_row_bits = 16'h0400;
                    4'd4: O_row_bits = 16'h7ff0;
                    4'd5: O_row_bits = 16'h0840;
                    4'd6: O_row_bits = 16'h1040;
                    4'd7: O_row_bits = 16'h1c80;
                    4'd8: O_row_bits = 16'h0300;
                    4'd9: O_row_bits = 16'h0cc0;
                    4'd10: O_row_bits = 16'h7020;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_LU: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h79e0;
                    4'd1: O_row_bits = 16'h4a20;
                    4'd2: O_row_bits = 16'h4d40;
                    4'd3: O_row_bits = 16'h7880;
                    4'd4: O_row_bits = 16'h1140;
                    4'd5: O_row_bits = 16'h1630;
                    4'd6: O_row_bits = 16'h5be0;
                    4'd7: O_row_bits = 16'h5220;
                    4'd8: O_row_bits = 16'h5220;
                    4'd9: O_row_bits = 16'h5be0;
                    4'd10: O_row_bits = 16'h6220;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_A: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h1c00;
                    4'd3: O_row_bits = 16'h1400;
                    4'd4: O_row_bits = 16'h1400;
                    4'd5: O_row_bits = 16'h1400;
                    4'd6: O_row_bits = 16'h3600;
                    4'd7: O_row_bits = 16'h3e00;
                    4'd8: O_row_bits = 16'h2200;
                    4'd9: O_row_bits = 16'h2200;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
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
                    4'd2: O_row_bits = 16'h3e00;
                    4'd3: O_row_bits = 16'h3300;
                    4'd4: O_row_bits = 16'h3300;
                    4'd5: O_row_bits = 16'h3e00;
                    4'd6: O_row_bits = 16'h3300;
                    4'd7: O_row_bits = 16'h3300;
                    4'd8: O_row_bits = 16'h3300;
                    4'd9: O_row_bits = 16'h3e00;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
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
                    4'd2: O_row_bits = 16'h03f0;
                    4'd3: O_row_bits = 16'h0c0c;
                    4'd4: O_row_bits = 16'h1800;
                    4'd5: O_row_bits = 16'h3000;
                    4'd6: O_row_bits = 16'h3000;
                    4'd7: O_row_bits = 16'h3000;
                    4'd8: O_row_bits = 16'h3000;
                    4'd9: O_row_bits = 16'h3000;
                    4'd10: O_row_bits = 16'h1800;
                    4'd11: O_row_bits = 16'h0c0c;
                    4'd12: O_row_bits = 16'h03f0;
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
                    4'd2: O_row_bits = 16'h3e00;
                    4'd3: O_row_bits = 16'h3300;
                    4'd4: O_row_bits = 16'h3300;
                    4'd5: O_row_bits = 16'h3300;
                    4'd6: O_row_bits = 16'h3300;
                    4'd7: O_row_bits = 16'h3300;
                    4'd8: O_row_bits = 16'h3600;
                    4'd9: O_row_bits = 16'h3c00;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
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
                    4'd2: O_row_bits = 16'h3e00;
                    4'd3: O_row_bits = 16'h3000;
                    4'd4: O_row_bits = 16'h3000;
                    4'd5: O_row_bits = 16'h3e00;
                    4'd6: O_row_bits = 16'h3000;
                    4'd7: O_row_bits = 16'h3000;
                    4'd8: O_row_bits = 16'h3000;
                    4'd9: O_row_bits = 16'h3e00;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
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
                    4'd2: O_row_bits = 16'h3e00;
                    4'd3: O_row_bits = 16'h3000;
                    4'd4: O_row_bits = 16'h3000;
                    4'd5: O_row_bits = 16'h3000;
                    4'd6: O_row_bits = 16'h3e00;
                    4'd7: O_row_bits = 16'h3000;
                    4'd8: O_row_bits = 16'h3000;
                    4'd9: O_row_bits = 16'h3000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
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
                    4'd2: O_row_bits = 16'h1c00;
                    4'd3: O_row_bits = 16'h3200;
                    4'd4: O_row_bits = 16'h6000;
                    4'd5: O_row_bits = 16'h6000;
                    4'd6: O_row_bits = 16'h6e00;
                    4'd7: O_row_bits = 16'h6600;
                    4'd8: O_row_bits = 16'h3600;
                    4'd9: O_row_bits = 16'h1e00;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
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
                    4'd2: O_row_bits = 16'h3300;
                    4'd3: O_row_bits = 16'h3300;
                    4'd4: O_row_bits = 16'h3300;
                    4'd5: O_row_bits = 16'h3f00;
                    4'd6: O_row_bits = 16'h3300;
                    4'd7: O_row_bits = 16'h3300;
                    4'd8: O_row_bits = 16'h3300;
                    4'd9: O_row_bits = 16'h3300;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
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
                    4'd2: O_row_bits = 16'h1e00;
                    4'd3: O_row_bits = 16'h0c00;
                    4'd4: O_row_bits = 16'h0c00;
                    4'd5: O_row_bits = 16'h0c00;
                    4'd6: O_row_bits = 16'h0c00;
                    4'd7: O_row_bits = 16'h0c00;
                    4'd8: O_row_bits = 16'h0c00;
                    4'd9: O_row_bits = 16'h1e00;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
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
                    4'd2: O_row_bits = 16'h3e00;
                    4'd3: O_row_bits = 16'h0600;
                    4'd4: O_row_bits = 16'h0600;
                    4'd5: O_row_bits = 16'h0600;
                    4'd6: O_row_bits = 16'h0600;
                    4'd7: O_row_bits = 16'h0600;
                    4'd8: O_row_bits = 16'h2600;
                    4'd9: O_row_bits = 16'h1c00;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
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
                    4'd2: O_row_bits = 16'h3300;
                    4'd3: O_row_bits = 16'h3600;
                    4'd4: O_row_bits = 16'h3400;
                    4'd5: O_row_bits = 16'h3c00;
                    4'd6: O_row_bits = 16'h3c00;
                    4'd7: O_row_bits = 16'h3400;
                    4'd8: O_row_bits = 16'h3600;
                    4'd9: O_row_bits = 16'h3300;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
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
                    4'd2: O_row_bits = 16'h3000;
                    4'd3: O_row_bits = 16'h3000;
                    4'd4: O_row_bits = 16'h3000;
                    4'd5: O_row_bits = 16'h3000;
                    4'd6: O_row_bits = 16'h3000;
                    4'd7: O_row_bits = 16'h3000;
                    4'd8: O_row_bits = 16'h3000;
                    4'd9: O_row_bits = 16'h3e00;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
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
                    4'd2: O_row_bits = 16'h3600;
                    4'd3: O_row_bits = 16'h3600;
                    4'd4: O_row_bits = 16'h3600;
                    4'd5: O_row_bits = 16'h3600;
                    4'd6: O_row_bits = 16'h2a00;
                    4'd7: O_row_bits = 16'h2a00;
                    4'd8: O_row_bits = 16'h2200;
                    4'd9: O_row_bits = 16'h2200;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
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
                    4'd2: O_row_bits = 16'h300c;
                    4'd3: O_row_bits = 16'h380c;
                    4'd4: O_row_bits = 16'h3c0c;
                    4'd5: O_row_bits = 16'h360c;
                    4'd6: O_row_bits = 16'h330c;
                    4'd7: O_row_bits = 16'h318c;
                    4'd8: O_row_bits = 16'h30cc;
                    4'd9: O_row_bits = 16'h306c;
                    4'd10: O_row_bits = 16'h303c;
                    4'd11: O_row_bits = 16'h301c;
                    4'd12: O_row_bits = 16'h300c;
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
                    4'd2: O_row_bits = 16'h1e00;
                    4'd3: O_row_bits = 16'h3200;
                    4'd4: O_row_bits = 16'h6300;
                    4'd5: O_row_bits = 16'h6300;
                    4'd6: O_row_bits = 16'h6300;
                    4'd7: O_row_bits = 16'h6300;
                    4'd8: O_row_bits = 16'h3600;
                    4'd9: O_row_bits = 16'h3c00;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
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
                    4'd2: O_row_bits = 16'h3e00;
                    4'd3: O_row_bits = 16'h3300;
                    4'd4: O_row_bits = 16'h3300;
                    4'd5: O_row_bits = 16'h3300;
                    4'd6: O_row_bits = 16'h3e00;
                    4'd7: O_row_bits = 16'h3000;
                    4'd8: O_row_bits = 16'h3000;
                    4'd9: O_row_bits = 16'h3000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
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
                    4'd2: O_row_bits = 16'h1e00;
                    4'd3: O_row_bits = 16'h3200;
                    4'd4: O_row_bits = 16'h6300;
                    4'd5: O_row_bits = 16'h6300;
                    4'd6: O_row_bits = 16'h6300;
                    4'd7: O_row_bits = 16'h6300;
                    4'd8: O_row_bits = 16'h7600;
                    4'd9: O_row_bits = 16'h3c00;
                    4'd10: O_row_bits = 16'h0c00;
                    4'd11: O_row_bits = 16'h0700;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_R: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h0000;
                    4'd2: O_row_bits = 16'h3e00;
                    4'd3: O_row_bits = 16'h3300;
                    4'd4: O_row_bits = 16'h3300;
                    4'd5: O_row_bits = 16'h3300;
                    4'd6: O_row_bits = 16'h3c00;
                    4'd7: O_row_bits = 16'h3600;
                    4'd8: O_row_bits = 16'h3600;
                    4'd9: O_row_bits = 16'h3200;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
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
                    4'd2: O_row_bits = 16'h1e00;
                    4'd3: O_row_bits = 16'h3000;
                    4'd4: O_row_bits = 16'h3000;
                    4'd5: O_row_bits = 16'h3c00;
                    4'd6: O_row_bits = 16'h0f00;
                    4'd7: O_row_bits = 16'h0300;
                    4'd8: O_row_bits = 16'h0300;
                    4'd9: O_row_bits = 16'h3e00;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
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
                    4'd2: O_row_bits = 16'h3ffc;
                    4'd3: O_row_bits = 16'h03c0;
                    4'd4: O_row_bits = 16'h03c0;
                    4'd5: O_row_bits = 16'h03c0;
                    4'd6: O_row_bits = 16'h03c0;
                    4'd7: O_row_bits = 16'h03c0;
                    4'd8: O_row_bits = 16'h03c0;
                    4'd9: O_row_bits = 16'h03c0;
                    4'd10: O_row_bits = 16'h03c0;
                    4'd11: O_row_bits = 16'h03c0;
                    4'd12: O_row_bits = 16'h03c0;
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
                    4'd2: O_row_bits = 16'h3300;
                    4'd3: O_row_bits = 16'h3300;
                    4'd4: O_row_bits = 16'h3300;
                    4'd5: O_row_bits = 16'h3300;
                    4'd6: O_row_bits = 16'h3300;
                    4'd7: O_row_bits = 16'h3300;
                    4'd8: O_row_bits = 16'h3300;
                    4'd9: O_row_bits = 16'h1e00;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
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
                    4'd2: O_row_bits = 16'h2200;
                    4'd3: O_row_bits = 16'h2200;
                    4'd4: O_row_bits = 16'h3600;
                    4'd5: O_row_bits = 16'h3600;
                    4'd6: O_row_bits = 16'h1400;
                    4'd7: O_row_bits = 16'h1400;
                    4'd8: O_row_bits = 16'h1c00;
                    4'd9: O_row_bits = 16'h1c00;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
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
                    4'd2: O_row_bits = 16'h2200;
                    4'd3: O_row_bits = 16'h2200;
                    4'd4: O_row_bits = 16'h2a00;
                    4'd5: O_row_bits = 16'h2a00;
                    4'd6: O_row_bits = 16'h3600;
                    4'd7: O_row_bits = 16'h3600;
                    4'd8: O_row_bits = 16'h3600;
                    4'd9: O_row_bits = 16'h3600;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
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
                    4'd2: O_row_bits = 16'h3e00;
                    4'd3: O_row_bits = 16'h1c00;
                    4'd4: O_row_bits = 16'h1c00;
                    4'd5: O_row_bits = 16'h0800;
                    4'd6: O_row_bits = 16'h1c00;
                    4'd7: O_row_bits = 16'h1400;
                    4'd8: O_row_bits = 16'h3600;
                    4'd9: O_row_bits = 16'h3200;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
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
                    4'd2: O_row_bits = 16'h3180;
                    4'd3: O_row_bits = 16'h1300;
                    4'd4: O_row_bits = 16'h1b00;
                    4'd5: O_row_bits = 16'h1e00;
                    4'd6: O_row_bits = 16'h0c00;
                    4'd7: O_row_bits = 16'h0c00;
                    4'd8: O_row_bits = 16'h0c00;
                    4'd9: O_row_bits = 16'h0c00;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
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
                    4'd2: O_row_bits = 16'h3e00;
                    4'd3: O_row_bits = 16'h0400;
                    4'd4: O_row_bits = 16'h0c00;
                    4'd5: O_row_bits = 16'h0800;
                    4'd6: O_row_bits = 16'h0800;
                    4'd7: O_row_bits = 16'h1800;
                    4'd8: O_row_bits = 16'h1000;
                    4'd9: O_row_bits = 16'h3e00;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_0: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h1ff8;
                    4'd2: O_row_bits = 16'h1ff8;
                    4'd3: O_row_bits = 16'h300c;
                    4'd4: O_row_bits = 16'h300c;
                    4'd5: O_row_bits = 16'h300c;
                    4'd6: O_row_bits = 16'h0000;
                    4'd7: O_row_bits = 16'h0000;
                    4'd8: O_row_bits = 16'h300c;
                    4'd9: O_row_bits = 16'h300c;
                    4'd10: O_row_bits = 16'h300c;
                    4'd11: O_row_bits = 16'h1ff8;
                    4'd12: O_row_bits = 16'h1ff8;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_1: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h000c;
                    4'd2: O_row_bits = 16'h000c;
                    4'd3: O_row_bits = 16'h000c;
                    4'd4: O_row_bits = 16'h000c;
                    4'd5: O_row_bits = 16'h000c;
                    4'd6: O_row_bits = 16'h0000;
                    4'd7: O_row_bits = 16'h0000;
                    4'd8: O_row_bits = 16'h000c;
                    4'd9: O_row_bits = 16'h000c;
                    4'd10: O_row_bits = 16'h000c;
                    4'd11: O_row_bits = 16'h000c;
                    4'd12: O_row_bits = 16'h000c;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_2: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h1ff8;
                    4'd2: O_row_bits = 16'h1ff8;
                    4'd3: O_row_bits = 16'h000c;
                    4'd4: O_row_bits = 16'h000c;
                    4'd5: O_row_bits = 16'h000c;
                    4'd6: O_row_bits = 16'h1ff8;
                    4'd7: O_row_bits = 16'h1ff8;
                    4'd8: O_row_bits = 16'h3000;
                    4'd9: O_row_bits = 16'h3000;
                    4'd10: O_row_bits = 16'h3000;
                    4'd11: O_row_bits = 16'h1ff8;
                    4'd12: O_row_bits = 16'h1ff8;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_3: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h1ff8;
                    4'd2: O_row_bits = 16'h1ff8;
                    4'd3: O_row_bits = 16'h000c;
                    4'd4: O_row_bits = 16'h000c;
                    4'd5: O_row_bits = 16'h000c;
                    4'd6: O_row_bits = 16'h1ff8;
                    4'd7: O_row_bits = 16'h1ff8;
                    4'd8: O_row_bits = 16'h000c;
                    4'd9: O_row_bits = 16'h000c;
                    4'd10: O_row_bits = 16'h000c;
                    4'd11: O_row_bits = 16'h1ff8;
                    4'd12: O_row_bits = 16'h1ff8;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_4: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h300c;
                    4'd2: O_row_bits = 16'h300c;
                    4'd3: O_row_bits = 16'h300c;
                    4'd4: O_row_bits = 16'h300c;
                    4'd5: O_row_bits = 16'h300c;
                    4'd6: O_row_bits = 16'h1ff8;
                    4'd7: O_row_bits = 16'h1ff8;
                    4'd8: O_row_bits = 16'h000c;
                    4'd9: O_row_bits = 16'h000c;
                    4'd10: O_row_bits = 16'h000c;
                    4'd11: O_row_bits = 16'h000c;
                    4'd12: O_row_bits = 16'h000c;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_5: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h1ff8;
                    4'd2: O_row_bits = 16'h1ff8;
                    4'd3: O_row_bits = 16'h3000;
                    4'd4: O_row_bits = 16'h3000;
                    4'd5: O_row_bits = 16'h3000;
                    4'd6: O_row_bits = 16'h1ff8;
                    4'd7: O_row_bits = 16'h1ff8;
                    4'd8: O_row_bits = 16'h000c;
                    4'd9: O_row_bits = 16'h000c;
                    4'd10: O_row_bits = 16'h000c;
                    4'd11: O_row_bits = 16'h1ff8;
                    4'd12: O_row_bits = 16'h1ff8;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_6: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h1ff8;
                    4'd2: O_row_bits = 16'h1ff8;
                    4'd3: O_row_bits = 16'h3000;
                    4'd4: O_row_bits = 16'h3000;
                    4'd5: O_row_bits = 16'h3000;
                    4'd6: O_row_bits = 16'h1ff8;
                    4'd7: O_row_bits = 16'h1ff8;
                    4'd8: O_row_bits = 16'h300c;
                    4'd9: O_row_bits = 16'h300c;
                    4'd10: O_row_bits = 16'h300c;
                    4'd11: O_row_bits = 16'h1ff8;
                    4'd12: O_row_bits = 16'h1ff8;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_7: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h1ff8;
                    4'd2: O_row_bits = 16'h1ff8;
                    4'd3: O_row_bits = 16'h000c;
                    4'd4: O_row_bits = 16'h000c;
                    4'd5: O_row_bits = 16'h000c;
                    4'd6: O_row_bits = 16'h0000;
                    4'd7: O_row_bits = 16'h0000;
                    4'd8: O_row_bits = 16'h000c;
                    4'd9: O_row_bits = 16'h000c;
                    4'd10: O_row_bits = 16'h000c;
                    4'd11: O_row_bits = 16'h000c;
                    4'd12: O_row_bits = 16'h000c;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_8: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h1ff8;
                    4'd2: O_row_bits = 16'h1ff8;
                    4'd3: O_row_bits = 16'h300c;
                    4'd4: O_row_bits = 16'h300c;
                    4'd5: O_row_bits = 16'h300c;
                    4'd6: O_row_bits = 16'h1ff8;
                    4'd7: O_row_bits = 16'h1ff8;
                    4'd8: O_row_bits = 16'h300c;
                    4'd9: O_row_bits = 16'h300c;
                    4'd10: O_row_bits = 16'h300c;
                    4'd11: O_row_bits = 16'h1ff8;
                    4'd12: O_row_bits = 16'h1ff8;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_9: begin
                case(I_row)
                    4'd0: O_row_bits = 16'h0000;
                    4'd1: O_row_bits = 16'h1ff8;
                    4'd2: O_row_bits = 16'h1ff8;
                    4'd3: O_row_bits = 16'h300c;
                    4'd4: O_row_bits = 16'h300c;
                    4'd5: O_row_bits = 16'h300c;
                    4'd6: O_row_bits = 16'h1ff8;
                    4'd7: O_row_bits = 16'h1ff8;
                    4'd8: O_row_bits = 16'h000c;
                    4'd9: O_row_bits = 16'h000c;
                    4'd10: O_row_bits = 16'h000c;
                    4'd11: O_row_bits = 16'h1ff8;
                    4'd12: O_row_bits = 16'h1ff8;
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
                    4'd4: O_row_bits = 16'h0000;
                    4'd5: O_row_bits = 16'h0000;
                    4'd6: O_row_bits = 16'h0180;
                    4'd7: O_row_bits = 16'h0180;
                    4'd8: O_row_bits = 16'h0000;
                    4'd9: O_row_bits = 16'h0000;
                    4'd10: O_row_bits = 16'h0180;
                    4'd11: O_row_bits = 16'h0180;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            default: O_row_bits = 16'h0000;
        endcase
    end

endmodule

// Same glyphs as osd_char_lib, read synchronously from one 1024x16 ROM.
// Uppercase ASCII keeps its low six bits; digits/colon keep 48..58.
// The two Chinese glyphs use otherwise empty entries 32 and 33.
module osd_char_rom_sync (
    input wire I_clk,
    input wire [7:0] I_char,
    input wire [3:0] I_row,
    output reg [15:0] O_row_bits
);
    wire [5:0] font_index =
        I_char[7:1]==7'h40 ? {5'b10000,I_char[0]} :
        I_char[7:5]==3'b010 ? {1'b0,I_char[4:0]} :
        I_char[7:4]==4'h3 ? {2'b11,I_char[3:0]} : 6'd63;
    (* rom_style = "bram" *) reg [15:0] font_rom [0:1023];
    localparam [255:0] GLYPH_AN = 256'h0000000000000000000070200cc003001c80104008407ff0040044107ff00200;
    localparam [255:0] GLYPH_LU = 256'h0000000000000000000062205be0522052205be01630114078804d404a2079e0;
    localparam [255:0] GLYPH_A = 256'h000000000000000000000000220022003e0036001400140014001c0000000000;
    localparam [255:0] GLYPH_B = 256'h0000000000000000000000003e003300330033003e00330033003e0000000000;
    localparam [255:0] GLYPH_C = 256'h00000000000003f00c0c18003000300030003000300018000c0c03f000000000;
    localparam [255:0] GLYPH_D = 256'h0000000000000000000000003c003600330033003300330033003e0000000000;
    localparam [255:0] GLYPH_E = 256'h0000000000000000000000003e003000300030003e00300030003e0000000000;
    localparam [255:0] GLYPH_F = 256'h0000000000000000000000003000300030003e003000300030003e0000000000;
    localparam [255:0] GLYPH_G = 256'h0000000000000000000000001e00360066006e006000600032001c0000000000;
    localparam [255:0] GLYPH_H = 256'h00000000000000000000000033003300330033003f0033003300330000000000;
    localparam [255:0] GLYPH_I = 256'h0000000000000000000000001e000c000c000c000c000c000c001e0000000000;
    localparam [255:0] GLYPH_J = 256'h0000000000000000000000001c002600060006000600060006003e0000000000;
    localparam [255:0] GLYPH_K = 256'h0000000000000000000000003300360034003c003c0034003600330000000000;
    localparam [255:0] GLYPH_L = 256'h0000000000000000000000003e00300030003000300030003000300000000000;
    localparam [255:0] GLYPH_M = 256'h000000000000000000000000220022002a002a00360036003600360000000000;
    localparam [255:0] GLYPH_N = 256'h000000000000300c301c303c306c30cc318c330c360c3c0c380c300c00000000;
    localparam [255:0] GLYPH_O = 256'h0000000000000000000000003c003600630063006300630032001e0000000000;
    localparam [255:0] GLYPH_P = 256'h0000000000000000000000003000300030003e003300330033003e0000000000;
    localparam [255:0] GLYPH_Q = 256'h000000000000000007000c003c007600630063006300630032001e0000000000;
    localparam [255:0] GLYPH_R = 256'h0000000000000000000000003200360036003c003300330033003e0000000000;
    localparam [255:0] GLYPH_S = 256'h0000000000000000000000003e00030003000f003c00300030001e0000000000;
    localparam [255:0] GLYPH_T = 256'h00000000000003c003c003c003c003c003c003c003c003c003c03ffc00000000;
    localparam [255:0] GLYPH_U = 256'h0000000000000000000000001e00330033003300330033003300330000000000;
    localparam [255:0] GLYPH_V = 256'h0000000000000000000000001c001c0014001400360036002200220000000000;
    localparam [255:0] GLYPH_W = 256'h00000000000000000000000036003600360036002a002a002200220000000000;
    localparam [255:0] GLYPH_X = 256'h0000000000000000000000003200360014001c0008001c001c003e0000000000;
    localparam [255:0] GLYPH_Y = 256'h0000000000000000000000000c000c000c000c001e001b001300318000000000;
    localparam [255:0] GLYPH_Z = 256'h0000000000000000000000003e0010001800080008000c0004003e0000000000;
    localparam [255:0] GLYPH_0 = 256'h0000000000001ff81ff8300c300c300c00000000300c300c300c1ff81ff80000;
    localparam [255:0] GLYPH_1 = 256'h000000000000000c000c000c000c000c00000000000c000c000c000c000c0000;
    localparam [255:0] GLYPH_2 = 256'h0000000000001ff81ff83000300030001ff81ff8000c000c000c1ff81ff80000;
    localparam [255:0] GLYPH_3 = 256'h0000000000001ff81ff8000c000c000c1ff81ff8000c000c000c1ff81ff80000;
    localparam [255:0] GLYPH_4 = 256'h000000000000000c000c000c000c000c1ff81ff8300c300c300c300c300c0000;
    localparam [255:0] GLYPH_5 = 256'h0000000000001ff81ff8000c000c000c1ff81ff83000300030001ff81ff80000;
    localparam [255:0] GLYPH_6 = 256'h0000000000001ff81ff8300c300c300c1ff81ff83000300030001ff81ff80000;
    localparam [255:0] GLYPH_7 = 256'h000000000000000c000c000c000c000c00000000000c000c000c1ff81ff80000;
    localparam [255:0] GLYPH_8 = 256'h0000000000001ff81ff8300c300c300c1ff81ff8300c300c300c1ff81ff80000;
    localparam [255:0] GLYPH_9 = 256'h0000000000001ff81ff8000c000c000c1ff81ff8300c300c300c1ff81ff80000;
    localparam [255:0] GLYPH_COLON = 256'h0000000000000000018001800000000001800180000000000000000000000000;
    integer init_address, init_row;
    initial begin
        for(init_address=0;init_address<1024;init_address=init_address+1)
            font_rom[init_address]=16'd0;
        for(init_row=0;init_row<16;init_row=init_row+1) begin
            font_rom[32*16+init_row]=GLYPH_AN[16*init_row+:16];
            font_rom[33*16+init_row]=GLYPH_LU[16*init_row+:16];
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
        end
    end
    always @(posedge I_clk)
        O_row_bits<=font_rom[{font_index,I_row}];
endmodule

