module hdmi_mixer #(
    parameter H_OFFSET = 128,
    parameter V_OFFSET = 60,
    parameter IMG_WIDTH = 1280,
    parameter IMG_HEIGHT = 720,
    parameter integer DEBUG_MODE = 0,
    parameter integer SHOW_CAMERA_STATUS = 0,
    parameter integer SHOW_COLOR_TARGET = 0,
    parameter integer SHOW_RED_MASK = 0, // Reserved; front-end mask is not sent over DDR.
    parameter integer TARGET_RED_MIN = 80,
    parameter integer TARGET_RED_DELTA = 30,
    parameter integer TARGET_MIN_PIXELS = 128,
    parameter integer SHOW_RAW_STATS = 0,
    parameter integer SHOW_LATENCY = 0,
    parameter integer LATENCY_SWITCH_ENABLE = 0,
    parameter integer SHOW_EFFECT_LABEL = 0,
    parameter integer SHOW_CNN = 0,
    parameter integer CNN_FULL_FRAME_INPUT = 0,
    parameter integer HANDCNN_DYNAMIC_ROI = 0,
    parameter integer FRUIT_CNN = 0,
    parameter integer SHOW_RESNET_PROBE = 0,
    parameter integer SHOW_RESNET_RUNTIME = 0,
    parameter integer CNN_RESULT_TIMEOUT_FRAMES = 60,
    parameter integer MULTI_TARGET_ENABLE = 0,
    // Limit retained target state and replicated box/label rendering.
    parameter integer TARGET_SLOTS = 4
)(
    input wire        I_clk,
    input wire        I_rst_n,

    input wire        I_video_vsync,
    input wire        I_video_hsync,
    input wire        I_video_de,
    input wire        I_video_user,
    input wire        I_video_last,
    input wire [3:0]  I_effect_mode,
    input wire [7:0]  I_effect_param,

    input wire[3:0]   I_debug_status,
    input wire[7:0]   I_cam_fail_index,
    input wire        I_raw_stats_valid,
    input wire [44:0] I_raw_stats_data,
    input wire        I_ae_readout_valid,
    input wire [27:0] I_ae_readout_data,
    input wire        I_latency_sample_strobe,
    input wire        I_latency_show,
    input wire        I_latency_sample_valid,
    input wire [19:0] I_latency_total_us,
    input wire [19:0] I_latency_isp_us,
    input wire [19:0] I_latency_buffer_us,

    input wire I_cnn_enable,
    input wire I_cnn_result_valid,
    input wire [2:0] I_cnn_class,
    input wire [15:0] I_checkout_weight_bcd,
    input wire [15:0] I_checkout_price_bcd,
    input wire I_checkout_weight_valid,
    input wire I_checkout_price_valid,
    input wire I_hand_box_valid,
    input wire [47:0] I_hand_box,
    input wire [31:0] I_resnet_probe_status,

    output wire       O_video_rd_en,
    output wire       O_display_frame_start,
    input wire[23:0]  I_video_rd_data,

    // Target result is computed from the AWB RGB stream in the camera clock
    // domain and transferred here once per frame.
    input wire        I_target_result_ready,
    input wire        I_target_found,
    input wire        I_target_motion_mode,
    input wire [1:0]  I_target_color_mode,
    input wire [11:0] I_target_xmin,
    input wire [11:0] I_target_xmax,
    input wire [11:0] I_target_ymin,
    input wire [11:0] I_target_ymax,
    input wire [11:0] I_target_center_x,
    input wire [11:0] I_target_center_y,
    input wire [3:0]  I_target_multi_valid,
    input wire [3:0]  I_target_multi_hold,
    // Slot i occupies i*48+:48, with {ymax,ymin,xmax,xmin}.
    input wire [191:0] I_target_multi_boxes,
    input wire [7:0] I_target_multi_shapes,
    input wire        I_target_multi_overflow,

    output reg        O_hdmi_vsync,
    output reg        O_hdmi_hsync,
    output reg        O_hdmi_de,
    output reg[23:0]  O_hdmi_data
);

    reg        S_video_vsync_1d;
    reg        S_video_vsync_2d;
    reg        S_video_hsync_1d;
    reg        S_video_hsync_2d;
    reg        S_video_de_1d;
    reg        S_video_de_2d;
    wire [23:0] S_video_data_2d;
    reg [11:0] S_x;
    reg [11:0] S_y;
    reg [11:0] S_x_1d;
    reg [11:0] S_x_2d;
    reg [11:0] S_y_1d;
    reg [11:0] S_y_2d;

    reg [2:0] S_cnn_class;
    reg [3:0] S_effect_mode;
    wire S_cnn_visible;
    generate if (SHOW_CNN != 0) begin: cnn_visibility
        (* async_reg = "true" *) reg enable_meta, enable_sync;
        reg enable_active;
        always @(posedge I_clk or negedge I_rst_n) begin
            if (!I_rst_n) begin
                enable_meta<=0;enable_sync<=0;enable_active<=0;
            end else begin
                enable_meta<=I_cnn_enable;enable_sync<=enable_meta;
                if(I_video_user) enable_active<=enable_sync;
            end
        end
        assign S_cnn_visible=enable_active;
    end else begin: no_cnn_visibility
        assign S_cnn_visible=1'b0;
    end endgenerate

    wire S_latency_visible;
    generate if (LATENCY_SWITCH_ENABLE != 0) begin: latency_switch
        (* async_reg = "true" *) reg show_meta, show_sync;
        reg show_active;
        always @(posedge I_clk or negedge I_rst_n) begin
            if (!I_rst_n) begin
                show_meta <= 1'b0;
                show_sync <= 1'b0;
                show_active <= 1'b0;
            end else begin
                show_meta <= I_latency_show;
                show_sync <= show_meta;
                if (I_video_user)
                    show_active <= show_sync;
            end
        end
        assign S_latency_visible = show_active;
    end else begin: latency_always_visible
        assign S_latency_visible = 1'b1;
    end endgenerate

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            S_effect_mode <= 4'd0;
        end else if (I_video_user) begin
            S_effect_mode <= I_effect_mode;
        end
    end

    // USER accompanies the first pixel: bypass the active registers on that
    // edge so the whole frame uses one coherent configuration, including SOF.
    // Two pixel stages preserve the existing coordinates and overlay timing.
    display_effects_rgb888 u_display_effects (
        .I_clk(I_clk),
        .I_rst_n(I_rst_n),
        .I_rgb(I_video_rd_data),
        .I_mode(I_video_user ? I_effect_mode : S_effect_mode),
        .I_param(8'd0),
        .O_rgb(S_video_data_2d)
    );

    reg        S_osd_hit;
    reg [23:0] S_osd_color;
    reg [11:0] S_logo_x;
    reg [11:0] S_logo_y;
    reg [3:0]  S_char_idx;
    reg [2:0]  S_char_row;
    reg [2:0]  S_char_col;
    reg [4:0]  S_char_bits;
    reg        S_char_on;
    reg        S_logo_blue_on;
    reg        S_logo_red_on;
    reg [11:0] S_logo_tmp_y;
    reg [3:0]  S_logo_red_band;
    reg [11:0] S_logo_red_x_start;
    reg [11:0] S_logo_red_x_end;
    wire [11:0] S_logo_input_x = I_video_user ? 12'd0 : S_x;
    wire [11:0] S_logo_input_y = I_video_user ? 12'd0 : S_y;
    // The index and palette ROMs each take one clock. Read from the input
    // coordinates so their result still matches S_x_2d/S_y_2d.
    wire [14:0] S_logo_addr;
    wire[24:0] S_logo_pixel;
    reg [31:0] S_frame_cnt;
    reg [11:0] S_dyn_x;
    reg [11:0] S_dyn_y;
    reg [3:0]  S_dyn_char;
    reg [2:0]  S_dyn_col;
    reg [2:0]  S_dyn_row;
    reg [4:0]  S_dyn_bits;
    reg        S_dyn_on;
    reg [3:0]  S_dyn_digit_idx;
    reg [11:0] S_dyn_digit_x;
    reg [6:0]  S_dyn_seg;
    reg [3:0]  S_cnt_d0;
    reg [3:0]  S_cnt_d1;
    reg [3:0]  S_cnt_d2;
    reg [3:0]  S_cnt_d3;
    reg [3:0]  S_cnt_d4;
    reg [3:0]  S_cnt_d5;
    reg [2:0]  S_lbl_row;
    reg [2:0]  S_lbl_col;
    reg [1:0]  S_lbl_idx;
    reg [4:0]  S_lbl_bits;
    reg [6:0]  S_lbl_local_x;
    reg [3:0]  S_dyn_dec_digit;
    reg [4:0]  S_cn_local_x;
    reg [4:0]  S_cn_local_y;
    reg [3:0]  S_cn_col;
    reg [3:0]  S_cn_row;
    reg [15:0] S_cn_row_bits;
    reg        S_cn_on;
    reg [9:0]  S_cn_scale_x;
    reg [9:0]  S_cn_scale_y;
    reg [7:0]  S_pf_char;
    reg [4:0]  S_pf_local_x;
    reg [4:0]  S_pf_local_y;
    reg [3:0]  S_pf_col;
    reg [3:0]  S_pf_row;
    wire [15:0] S_pf_row_bits;
    reg        S_pf_on;
    reg        S_pf_valid;
    reg [7:0]  S_pf_next_char;
    reg [3:0]  S_pf_next_col;
    reg [3:0]  S_pf_next_row;
    reg        S_pf_next_valid;

    localparam LOGO_X = 12'd0;
    localparam LOGO_Y = 12'd0;
    localparam LOGO_W = 12'd160;
    localparam LOGO_H = 12'd160;

    localparam COLOR_LOGO_BLUE   = 24'h1f315c;
    localparam COLOR_LOGO_RED    = 24'hec1c2d;
    localparam COLOR_TEXT        = 24'h00e6ff;
    localparam DYN_OSD_X         = 12'd375;
    localparam DYN_OSD_Y         = 12'd120;
    localparam DYN_OSD_W         = 12'd200;
    localparam DYN_OSD_H         = 12'd24;
    localparam CN_Y_OFFSET       = 12'd2;
    localparam COLOR_DYN_TEXT    = 24'hfff200;
    localparam CHAR_AN           = 8'h80;
    localparam CHAR_LU           = 8'h81;
    localparam CHAR_C            = 8'h43;
    localparam CHAR_N            = 8'h4e;
    localparam CHAR_T            = 8'h54;
    localparam CHAR_0            = 8'h30;
    localparam CHAR_COLON        = 8'h3a;

    // The old HDMI-domain per-pixel detector was removed from the display
    // path.  It saw the already-processed DDR image and therefore stopped
    // working in edge mode.  These signals now come from the front-end
    // detector. Geometry is latched once at the display frame boundary.
    wire S_target_result_ready = I_target_result_ready;
    wire S_target_result_found = I_target_found;
    wire [11:0] S_result_xmin = I_target_xmin;
    wire [11:0] S_result_xmax = I_target_xmax;
    wire [11:0] S_result_ymin = I_target_ymin;
    wire [11:0] S_result_ymax = I_target_ymax;
    wire [11:0] S_result_center_x = I_target_center_x;
    wire [11:0] S_result_center_y = I_target_center_y;
    reg S_target_found;
    reg S_target_motion_mode;
    reg [1:0] S_target_color_mode;
    reg [11:0] S_target_xmin, S_target_xmax, S_target_ymin, S_target_ymax;
    reg [11:0] S_target_center_x, S_target_center_y;
    // Double-dabble conversion runs once per frame, during the first scan
    // line, rather than putting decimal dividers in the pixel critical path.
    reg [27:0] S_target_bcd_work_x, S_target_bcd_work_y;
    reg [15:0] S_target_bcd_x, S_target_bcd_y;
    reg [3:0] S_target_bcd_count;
    reg S_target_bcd_busy;
    reg [27:0] S_target_bcd_adjust_x, S_target_bcd_adjust_y;
    integer S_target_digit;
    wire S_display_frame_start = S_video_de_2d &&
                                 (S_x_2d == 0) && (S_y_2d == 0);
    assign O_display_frame_start = S_display_frame_start;

    localparam integer CNN_AGE_WIDTH = CNN_RESULT_TIMEOUT_FRAMES < 2 ?
        1 : $clog2(CNN_RESULT_TIMEOUT_FRAMES+1);
    reg [CNN_AGE_WIDTH-1:0] S_cnn_result_age;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            S_cnn_class <= 3'd1;
            S_cnn_result_age <= {CNN_AGE_WIDTH{1'b0}};
        end else if (SHOW_CNN != 0 && !S_cnn_visible) begin
            S_cnn_class <= 3'd1;
            S_cnn_result_age <= {CNN_AGE_WIDTH{1'b0}};
        end else if (I_cnn_result_valid) begin
            if(!HANDCNN_DYNAMIC_ROI || I_video_user)
                S_cnn_class <= (I_cnn_class >= 3'd1 && I_cnn_class <= (FRUIT_CNN != 0 ? 3'd6 : 3'd4)) ? I_cnn_class : 3'd1;
            S_cnn_result_age <= {CNN_AGE_WIDTH{1'b0}};
        end else if(HANDCNN_DYNAMIC_ROI && I_video_user) begin
            S_cnn_class <= ((CNN_RESULT_TIMEOUT_FRAMES != 0) && S_cnn_result_age>=CNN_RESULT_TIMEOUT_FRAMES-1) ?
                3'd1 : (I_cnn_class>=1 && I_cnn_class<=(FRUIT_CNN != 0 ? 6 : 4) ? I_cnn_class : 3'd1);
            if(CNN_RESULT_TIMEOUT_FRAMES != 0 && S_cnn_result_age<CNN_RESULT_TIMEOUT_FRAMES)
                S_cnn_result_age<=S_cnn_result_age+1'b1;
        end else if (!HANDCNN_DYNAMIC_ROI && (CNN_RESULT_TIMEOUT_FRAMES != 0) &&
                     S_display_frame_start) begin
            if (S_cnn_result_age < CNN_RESULT_TIMEOUT_FRAMES)
                S_cnn_result_age <= S_cnn_result_age + 1'b1;
            if (S_cnn_result_age >= CNN_RESULT_TIMEOUT_FRAMES-1)
                S_cnn_class <= 3'd1;
        end
    end

    always @(*) begin
        S_target_bcd_adjust_x = S_target_bcd_work_x;
        S_target_bcd_adjust_y = S_target_bcd_work_y;
        for (S_target_digit = 0; S_target_digit < 4; S_target_digit = S_target_digit+1) begin
            if (S_target_bcd_work_x[12+4*S_target_digit +: 4] >= 5)
                S_target_bcd_adjust_x[12+4*S_target_digit +: 4] =
                    S_target_bcd_work_x[12+4*S_target_digit +: 4] + 4'd3;
            if (S_target_bcd_work_y[12+4*S_target_digit +: 4] >= 5)
                S_target_bcd_adjust_y[12+4*S_target_digit +: 4] =
                    S_target_bcd_work_y[12+4*S_target_digit +: 4] + 4'd3;
        end
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            S_target_found <= 1'b0;
            S_target_motion_mode <= 1'b0;
            S_target_color_mode <= 2'd0;
            S_target_xmin <= 12'd0; S_target_xmax <= 12'd0;
            S_target_ymin <= 12'd0; S_target_ymax <= 12'd0;
            S_target_center_x <= 12'd0; S_target_center_y <= 12'd0;
            S_target_bcd_work_x <= 28'd0; S_target_bcd_work_y <= 28'd0;
            S_target_bcd_x <= 16'd0; S_target_bcd_y <= 16'd0;
            S_target_bcd_count <= 4'd0;
            S_target_bcd_busy <= 1'b0;
        end else if (((MULTI_TARGET_ENABLE == 0) && S_display_frame_start) ||
                     ((MULTI_TARGET_ENABLE != 0) && I_video_user)) begin
            S_target_found <= S_target_result_ready && S_target_result_found;
            S_target_motion_mode <= I_target_motion_mode;
            S_target_color_mode <= I_target_color_mode;
            S_target_xmin <= S_result_xmin; S_target_xmax <= S_result_xmax;
            S_target_ymin <= S_result_ymin; S_target_ymax <= S_result_ymax;
            S_target_center_x <= S_result_center_x;
            S_target_center_y <= S_result_center_y;
            S_target_bcd_work_x <= {16'd0, S_result_center_x};
            S_target_bcd_work_y <= {16'd0, S_result_center_y};
            S_target_bcd_count <= 4'd0;
            S_target_bcd_busy <= MULTI_TARGET_ENABLE == 0;
        end else if (S_target_bcd_busy) begin
            S_target_bcd_work_x <= S_target_bcd_adjust_x << 1;
            S_target_bcd_work_y <= S_target_bcd_adjust_y << 1;
            S_target_bcd_count <= S_target_bcd_count + 1'b1;
            if (S_target_bcd_count == 11) begin
                S_target_bcd_x <= S_target_bcd_adjust_x[26:11];
                S_target_bcd_y <= S_target_bcd_adjust_y[26:11];
                S_target_bcd_busy <= 1'b0;
            end
        end
    end

    // Frame-latched geometry. Widen sums so a box near the right/bottom
    // edge cannot overflow. Existing Logo/text has priority over this box.
    wire [12:0] S_target_dx = (S_x_2d >= S_target_center_x) ?
        {1'b0,S_x_2d} - {1'b0,S_target_center_x} :
        {1'b0,S_target_center_x} - {1'b0,S_x_2d};
    wire [12:0] S_target_dy = (S_y_2d >= S_target_center_y) ?
        {1'b0,S_y_2d} - {1'b0,S_target_center_y} :
        {1'b0,S_target_center_y} - {1'b0,S_y_2d};
    wire S_target_box_on = S_target_found &&
        (S_x_2d >= S_target_xmin) && (S_x_2d <= S_target_xmax) &&
        (S_y_2d >= S_target_ymin) && (S_y_2d <= S_target_ymax) &&
        (({1'b0,S_x_2d} < {1'b0,S_target_xmin}+13'd2) ||
         ({1'b0,S_x_2d}+13'd2 > {1'b0,S_target_xmax}) ||
         ({1'b0,S_y_2d} < {1'b0,S_target_ymin}+13'd2) ||
         ({1'b0,S_y_2d}+13'd2 > {1'b0,S_target_ymax}));
    wire S_target_cross_on = S_target_found &&
        (((S_target_dx <= 1) && (S_target_dy <= 6)) ||
         ((S_target_dy <= 1) && (S_target_dx <= 6)));

    wire [2:0] S_multi_count;
    wire S_multi_overflow;
    wire S_multi_box_on;
    wire [23:0] S_multi_box_color;
    wire S_follow_panel_on;
    wire [23:0] S_follow_color;
    wire [7:0] S_follow_char;
    wire [3:0] S_follow_row;
    wire [3:0] S_follow_col;
    wire [1:0] S_target_primary_shape;
    // Detection and algorithm occupy two rows at the lower left. Latency
    // independently occupies the free area below the right fruit sidebar.
    // Large viewports double strokes and remove only empty ASCII cell sides.
    localparam integer HUD_VIEW_WIDTH =
        (SHOW_CNN != 0 && FRUIT_CNN != 0 &&
         SHOW_RESNET_PROBE == 0 && SHOW_RESNET_RUNTIME == 0) ?
        (IMG_WIDTH >= 320 ? IMG_WIDTH-320 : 0) : IMG_WIDTH;
    localparam integer HUD_LARGE_TEXT = HUD_VIEW_WIDTH >= 800 && IMG_HEIGHT >= 240;
    localparam integer HUD_MODERN_LAYOUT = SHOW_EFFECT_LABEL != 0 || SHOW_LATENCY != 0;
    localparam integer LATENCY_PANEL_WIDTH = HUD_LARGE_TEXT ? 320 : 280;
    localparam integer LATENCY_PANEL_X =
        IMG_WIDTH >= LATENCY_PANEL_WIDTH ? IMG_WIDTH-LATENCY_PANEL_WIDTH : 0;
    localparam integer LATENCY_PANEL_HEIGHT = HUD_LARGE_TEXT ? 112 : 64;
    localparam integer LATENCY_PANEL_Y =
        IMG_HEIGHT >= LATENCY_PANEL_HEIGHT+16 ? IMG_HEIGHT-LATENCY_PANEL_HEIGHT-16 : 0;
    localparam integer EFFECT_TEXT_X = 16;
    localparam integer EFFECT_TEXT_WIDTH = HUD_LARGE_TEXT ? 360 : 240;
    localparam integer EFFECT_TEXT_HEIGHT = HUD_LARGE_TEXT ? 32 : 16;
    localparam integer EFFECT_TEXT_Y = IMG_HEIGHT >= EFFECT_TEXT_HEIGHT+16 ?
        IMG_HEIGHT-EFFECT_TEXT_HEIGHT-16 : 0;
    localparam integer TARGET_LARGE_TEXT = HUD_MODERN_LAYOUT && HUD_LARGE_TEXT;
    localparam integer TARGET_TEXT_WIDTH = TARGET_LARGE_TEXT ?
        ((MULTI_TARGET_ENABLE != 0) ? 360 : 552) :
        ((MULTI_TARGET_ENABLE != 0) ? 240 : 368);
    localparam integer TARGET_TEXT_HEIGHT = TARGET_LARGE_TEXT ? 32 : 16;
    localparam integer TARGET_TEXT_PREFERRED_Y = HUD_MODERN_LAYOUT ?
        (EFFECT_TEXT_Y >= TARGET_TEXT_HEIGHT+8 ? EFFECT_TEXT_Y-TARGET_TEXT_HEIGHT-8 : 0) :
        (IMG_HEIGHT >= 32 ? IMG_HEIGHT-32 : 0);
    // Short test formats use the free bottom margin beside the Logo.
    localparam integer TARGET_TEXT_SHORT_FRAME =
        (SHOW_LATENCY != 0 || SHOW_EFFECT_LABEL != 0) && TARGET_TEXT_PREFERRED_Y < 160;
    localparam integer TARGET_TEXT_X = TARGET_TEXT_SHORT_FRAME &&
        IMG_WIDTH >= 176+TARGET_TEXT_WIDTH ? 176 : 16;
    localparam integer TARGET_TEXT_Y = TARGET_TEXT_SHORT_FRAME ?
        (IMG_HEIGHT >= 16 ? IMG_HEIGHT-16 : 0) : TARGET_TEXT_PREFERRED_Y;

    // Divide the bounded half-pixel offset into twelve-column cells using
    // constant comparisons/subtractions. Shared by both lower-left rows.
    function [7:0] F_effect_compact_cell;
        input [7:0] half_x;
        reg [7:0] remainder;
        reg [3:0] position;
        begin
            remainder=half_x;position=0;
            if(remainder>=8'd96) begin remainder=remainder-8'd96;position[3]=1'b1;end
            if(remainder>=8'd48) begin remainder=remainder-8'd48;position[2]=1'b1;end
            if(remainder>=8'd24) begin remainder=remainder-8'd24;position[1]=1'b1;end
            if(remainder>=8'd12) begin remainder=remainder-8'd12;position[0]=1'b1;end
            F_effect_compact_cell={position,remainder[3:0]+4'd2};
        end
    endfunction

    function F_bounds_overlap;
        input [12:0] ax, ay, aright, abottom, bx, by, bright, bbottom;
        begin
            F_bounds_overlap = (ax < bright) && (bx < aright) &&
                               (ay < bbottom) && (by < abottom);
        end
    endfunction

    function [23:0] F_target_color;
        input [1:0] slot;
        begin
            case (slot)
                0: F_target_color = 24'hff3030;
                1: F_target_color = 24'h00e6ff;
                2: F_target_color = 24'hfff200;
                default: F_target_color = 24'h40ff70;
            endcase
        end
    endfunction

    function [7:0] F_target_mode_char;
        input motion_mode;
        input [1:0] color_mode;
        input [1:0] char_index;
        begin
            if (motion_mode) begin
                case (char_index)
                    0: F_target_mode_char = "M";
                    1: F_target_mode_char = "O";
                    default: F_target_mode_char = "V";
                endcase
            end else begin
                case (color_mode)
                    2'd1: begin
                        case (char_index)
                            0: F_target_mode_char = "G";
                            1: F_target_mode_char = "R";
                            default: F_target_mode_char = "N";
                        endcase
                    end
                    2'd2: begin
                        case (char_index)
                            0: F_target_mode_char = "B";
                            1: F_target_mode_char = "L";
                            default: F_target_mode_char = "U";
                        endcase
                    end
                    default: begin
                        case (char_index)
                            0: F_target_mode_char = "R";
                            1: F_target_mode_char = "E";
                            default: F_target_mode_char = "D";
                        endcase
                    end
                endcase
            end
        end
    endfunction

    function [7:0] F_target_shape_char;
        input [1:0] shape;
        input [1:0] char_index;
        begin
            case (shape)
                2'd1: begin
                    case (char_index)
                        0: F_target_shape_char = "S";
                        1: F_target_shape_char = "Q";
                        default: F_target_shape_char = "R";
                    endcase
                end
                2'd2: begin
                    case (char_index)
                        0: F_target_shape_char = "T";
                        1: F_target_shape_char = "R";
                        default: F_target_shape_char = "I";
                    endcase
                end
                2'd3: begin
                    case (char_index)
                        0: F_target_shape_char = "C";
                        1: F_target_shape_char = "I";
                        default: F_target_shape_char = "R";
                    endcase
                end
                default: begin
                    case (char_index)
                        0: F_target_shape_char = "U";
                        1: F_target_shape_char = "N";
                        default: F_target_shape_char = "K";
                    endcase
                end
            endcase
        end
    endfunction

    generate if (MULTI_TARGET_ENABLE != 0) begin: multi_target
        localparam integer ACTIVE_TARGETS = TARGET_SLOTS < 1 ? 1 :
            (TARGET_SLOTS > 4 ? 4 : TARGET_SLOTS);
        localparam integer SLOT_INDEX_WIDTH = ACTIVE_TARGETS < 2 ? 1 :
            $clog2(ACTIVE_TARGETS);
        localparam integer PEER_TARGETS = ACTIVE_TARGETS > 1 ? ACTIVE_TARGETS : 0;
        reg [ACTIVE_TARGETS-1:0] valid, held;
        reg [2*ACTIVE_TARGETS-1:0] shapes;
        reg overflow;
        reg [11:0] xmin [0:ACTIVE_TARGETS-1], xmax [0:ACTIVE_TARGETS-1];
        reg [11:0] ymin [0:ACTIVE_TARGETS-1], ymax [0:ACTIVE_TARGETS-1];
        reg [ACTIVE_TARGETS-1:0] label_valid, label_compact;
        reg [11:0] label_x [0:ACTIVE_TARGETS-1], label_y [0:ACTIVE_TARGETS-1];
        reg layout_busy;
        reg [SLOT_INDEX_WIDTH-1:0] layout_slot;
        reg [4:0] layout_attempt;
        reg [11:0] layout_xmin, layout_xmax, layout_ymin, layout_ymax;
        reg [12:0] candidate_x, candidate_y, candidate_width;
        reg [12:0] candidate_right, candidate_bottom;
        reg candidate_valid;
        reg [12:0] anchor_x, box_right;
        integer target_index, peer_index, render_index, count_index;
        reg [2:0] target_count;
        reg box_hit, label_hit;
        reg [1:0] box_slot, label_slot;
        reg [11:0] label_local_x, label_local_y;
        reg [7:0] label_char;
        wire [12:0] full_width = S_target_motion_mode ? 13'd128 : 13'd192;
        wire [12:0] compact_width = S_target_motion_mode ? 13'd64 : 13'd128;

        always @(*) begin
            target_count = 3'd0;
            for (count_index=0; count_index<ACTIVE_TARGETS; count_index=count_index+1)
                target_count = target_count+valid[count_index];
        end
        assign S_multi_count = target_count;
        assign S_multi_overflow = overflow;
        assign S_multi_box_on = box_hit;
        assign S_multi_box_color = F_target_color(box_slot);
        assign S_target_primary_shape = shapes[1:0];
        assign S_follow_panel_on = label_hit;
        assign S_follow_color = F_target_color(label_slot);
        assign S_follow_char = label_char;
        assign S_follow_row = label_local_y[3:0];
        assign S_follow_col = label_local_x[3:0];

        // Each retained label takes at most 32 clocks to place. Starting at
        // row 16 keeps the scan behind layout even with four retained slots.
        always @(*) begin
            candidate_width = layout_attempt[4] ? compact_width : full_width;
            anchor_x = {1'b0,layout_xmin};
            box_right = {1'b0,layout_xmax};
            candidate_x = anchor_x;
            candidate_y = 13'd16;
            candidate_right = anchor_x+candidate_width;
            candidate_bottom = 13'd32;
            candidate_valid = IMG_WIDTH >= candidate_width && IMG_HEIGHT >= 32;
            if (candidate_x+candidate_width > IMG_WIDTH) begin
                candidate_x = IMG_WIDTH-candidate_width;
                candidate_right = IMG_WIDTH;
            end
            // Generate both edges in parallel. In particular, a left-side
            // label ends at anchor_x-2 regardless of its selected width.
            // Keep the original 13-bit overlap arithmetic and the separate,
            // parameter-width frame-bound checks below.
            case (layout_attempt[3:2])
                1: begin
                    if (anchor_x >= candidate_width+13'd2) begin
                        candidate_x = anchor_x-candidate_width-13'd2;
                        candidate_right = anchor_x-13'd2;
                    end else
                        candidate_valid = 1'b0;
                end
                2: begin
                    candidate_x = box_right+13'd3;
                    candidate_right = box_right+13'd3+candidate_width;
                end
                3: begin
                    candidate_x = (box_right+13'd1 >= candidate_width) ?
                        box_right+13'd1-candidate_width : 13'd0;
                    candidate_right = (box_right+13'd1 >= candidate_width) ?
                        box_right+13'd1 : candidate_width;
                end
                default: begin end
            endcase
            case (layout_attempt[1:0])
                0: begin
                    if (layout_ymin >= 12'd20) begin
                        candidate_y = {1'b0,layout_ymin}-13'd18;
                        candidate_bottom = {1'b0,layout_ymin}-13'd2;
                    end else
                        candidate_valid = 1'b0;
                end
                1: begin
                    candidate_y = {1'b0,layout_ymax}+13'd3;
                    candidate_bottom = {1'b0,layout_ymax}+13'd19;
                end
                2: begin
                    candidate_y = {1'b0,layout_ymin}+13'd3;
                    candidate_bottom = {1'b0,layout_ymin}+13'd19;
                end
                default: begin
                    if (layout_ymax >= 12'd20) begin
                        candidate_y = {1'b0,layout_ymax}-13'd18;
                        candidate_bottom = {1'b0,layout_ymax}-13'd2;
                    end else
                        candidate_valid = 1'b0;
                end
            endcase
            if (candidate_x+candidate_width > IMG_WIDTH ||
                candidate_y < 16 || candidate_y+13'd16 > IMG_HEIGHT)
                candidate_valid = 1'b0;
            if (F_bounds_overlap(candidate_x,candidate_y,candidate_right,candidate_bottom,
                    13'd0,13'd0,13'd160,13'd160) ||
                F_bounds_overlap(candidate_x,candidate_y,candidate_right,candidate_bottom,
                    13'd375,13'd120,13'd575,13'd144) ||
                F_bounds_overlap(candidate_x,candidate_y,candidate_right,candidate_bottom,
                    TARGET_TEXT_X,TARGET_TEXT_Y,
                    TARGET_TEXT_X+TARGET_TEXT_WIDTH,TARGET_TEXT_Y+TARGET_TEXT_HEIGHT))
                candidate_valid = 1'b0;
            if ((SHOW_CAMERA_STATUS != 0) &&
                F_bounds_overlap(candidate_x,candidate_y,candidate_right,candidate_bottom,
                    13'd192,13'd16,13'd280,13'd64))
                candidate_valid = 1'b0;
            if ((SHOW_EFFECT_LABEL != 0) &&
                F_bounds_overlap(candidate_x,candidate_y,candidate_right,candidate_bottom,
                    EFFECT_TEXT_X,EFFECT_TEXT_Y,
                    EFFECT_TEXT_X+EFFECT_TEXT_WIDTH,EFFECT_TEXT_Y+EFFECT_TEXT_HEIGHT))
                candidate_valid = 1'b0;
            if ((SHOW_LATENCY != 0) && S_latency_visible &&
                F_bounds_overlap(candidate_x,candidate_y,candidate_right,candidate_bottom,
                    LATENCY_PANEL_X,LATENCY_PANEL_Y,
                    LATENCY_PANEL_X+LATENCY_PANEL_WIDTH,LATENCY_PANEL_Y+LATENCY_PANEL_HEIGHT))
                candidate_valid = 1'b0;
            if ((SHOW_RAW_STATS != 0) &&
                F_bounds_overlap(candidate_x,candidate_y,candidate_right,candidate_bottom,
                    13'd496,13'd176,13'd1264,13'd528))
                candidate_valid = 1'b0;
            for (peer_index=0; peer_index<PEER_TARGETS; peer_index=peer_index+1)
                if (label_valid[peer_index] &&
                    F_bounds_overlap(candidate_x,candidate_y,candidate_right,candidate_bottom,
                        {1'b0,label_x[peer_index]},{1'b0,label_y[peer_index]},
                        {1'b0,label_x[peer_index]}+
                            (label_compact[peer_index] ? compact_width : full_width),
                        {1'b0,label_y[peer_index]}+13'd16))
                    candidate_valid = 1'b0;
        end

        always @(posedge I_clk or negedge I_rst_n) begin
            if (!I_rst_n) begin
                valid <= 0;
                held <= 0;
                shapes <= 0;
                overflow <= 1'b0;
                label_valid <= 0;
                label_compact <= 0;
                layout_busy <= 1'b0;
                layout_slot <= 0;
                layout_attempt <= 5'd0;
                layout_xmin <= 12'd0; layout_xmax <= 12'd0;
                layout_ymin <= 12'd0; layout_ymax <= 12'd0;
                for (target_index=0; target_index<ACTIVE_TARGETS; target_index=target_index+1) begin
                    xmin[target_index] <= 12'd0; xmax[target_index] <= 12'd0;
                    ymin[target_index] <= 12'd0; ymax[target_index] <= 12'd0;
                    label_x[target_index] <= 12'd0;
                    label_y[target_index] <= 12'd0;
                end
            end else if (I_video_user) begin
                held <= I_target_motion_mode ? 0 :
                    I_target_multi_hold[ACTIVE_TARGETS-1:0];
                shapes <= I_target_motion_mode ? 0 :
                    I_target_multi_shapes[2*ACTIVE_TARGETS-1:0];
                overflow <= ACTIVE_TARGETS > 1 &&
                            I_target_result_ready && !I_target_motion_mode &&
                            I_target_multi_overflow;
                label_valid <= 0;
                label_compact <= 0;
                layout_busy <= I_target_result_ready;
                layout_slot <= 0;
                layout_attempt <= 5'd0;
                // Slot zero is already available at the frame edge. Later
                // slots are prefetched when the previous slot finishes, so
                // rectangle arithmetic never follows a slot-to-box mux.
                layout_xmin <= I_target_motion_mode ? I_target_xmin :
                    I_target_multi_boxes[11:0];
                layout_xmax <= I_target_motion_mode ?
                    (I_target_xmax >= IMG_WIDTH ? IMG_WIDTH-1 : I_target_xmax) :
                    (I_target_multi_boxes[23:12] >= IMG_WIDTH ?
                        IMG_WIDTH-1 : I_target_multi_boxes[23:12]);
                layout_ymin <= I_target_motion_mode ? I_target_ymin :
                    I_target_multi_boxes[35:24];
                layout_ymax <= I_target_motion_mode ?
                    (I_target_ymax >= IMG_HEIGHT ? IMG_HEIGHT-1 : I_target_ymax) :
                    (I_target_multi_boxes[47:36] >= IMG_HEIGHT ?
                        IMG_HEIGHT-1 : I_target_multi_boxes[47:36]);
                for (target_index=0; target_index<ACTIVE_TARGETS; target_index=target_index+1) begin
                    if (I_target_motion_mode) begin
                        valid[target_index] <= I_target_result_ready &&
                            I_target_found && target_index == 0 &&
                            I_target_xmin <= I_target_xmax &&
                            I_target_ymin <= I_target_ymax &&
                            I_target_xmin < IMG_WIDTH && I_target_ymin < IMG_HEIGHT;
                        xmin[target_index] <= I_target_xmin;
                        xmax[target_index] <= I_target_xmax >= IMG_WIDTH ?
                            IMG_WIDTH-1 : I_target_xmax;
                        ymin[target_index] <= I_target_ymin;
                        ymax[target_index] <= I_target_ymax >= IMG_HEIGHT ?
                            IMG_HEIGHT-1 : I_target_ymax;
                    end else begin
                        valid[target_index] <= I_target_result_ready &&
                            I_target_multi_valid[target_index] &&
                            I_target_multi_boxes[target_index*48 +: 12] <=
                                I_target_multi_boxes[target_index*48+12 +: 12] &&
                            I_target_multi_boxes[target_index*48+24 +: 12] <=
                                I_target_multi_boxes[target_index*48+36 +: 12] &&
                            I_target_multi_boxes[target_index*48 +: 12] < IMG_WIDTH &&
                            I_target_multi_boxes[target_index*48+24 +: 12] < IMG_HEIGHT;
                        xmin[target_index] <=
                            I_target_multi_boxes[target_index*48 +: 12];
                        xmax[target_index] <=
                            I_target_multi_boxes[target_index*48+12 +: 12] >= IMG_WIDTH ?
                            IMG_WIDTH-1 : I_target_multi_boxes[target_index*48+12 +: 12];
                        ymin[target_index] <=
                            I_target_multi_boxes[target_index*48+24 +: 12];
                        ymax[target_index] <=
                            I_target_multi_boxes[target_index*48+36 +: 12] >= IMG_HEIGHT ?
                            IMG_HEIGHT-1 : I_target_multi_boxes[target_index*48+36 +: 12];
                    end
                end
            end else if (layout_busy) begin
                if (!valid[layout_slot] || candidate_valid || layout_attempt == 31) begin
                    if (valid[layout_slot] && candidate_valid) begin
                        label_valid[layout_slot] <= 1'b1;
                        label_compact[layout_slot] <= layout_attempt[4];
                        label_x[layout_slot] <= candidate_x[11:0];
                        label_y[layout_slot] <= candidate_y[11:0];
                    end
                    layout_attempt <= 5'd0;
                    if (layout_slot == ACTIVE_TARGETS-1)
                        layout_busy <= 1'b0;
                    else begin
                        layout_slot <= layout_slot+1'b1;
                        layout_xmin <= xmin[layout_slot+2'd1];
                        layout_xmax <= xmax[layout_slot+2'd1];
                        layout_ymin <= ymin[layout_slot+2'd1];
                        layout_ymax <= ymax[layout_slot+2'd1];
                    end
                end else
                    layout_attempt <= layout_attempt+1'b1;
            end
        end

        always @(*) begin
            box_hit = 1'b0;
            label_hit = 1'b0;
            box_slot = 2'd0;
            label_slot = 2'd0;
            label_local_x = 12'd0;
            label_local_y = 12'd0;
            label_char = " ";
            for (render_index=ACTIVE_TARGETS-1; render_index>=0; render_index=render_index-1) begin
                if (valid[render_index] && S_video_de_2d &&
                    S_x_2d >= xmin[render_index] && S_x_2d <= xmax[render_index] &&
                    S_y_2d >= ymin[render_index] && S_y_2d <= ymax[render_index] &&
                    (({1'b0,S_x_2d} < {1'b0,xmin[render_index]}+13'd2) ||
                     ({1'b0,S_x_2d}+13'd2 > {1'b0,xmax[render_index]}) ||
                     ({1'b0,S_y_2d} < {1'b0,ymin[render_index]}+13'd2) ||
                     ({1'b0,S_y_2d}+13'd2 > {1'b0,ymax[render_index]}))) begin
                    box_hit = 1'b1;
                    box_slot = render_index;
                end
                if (label_valid[render_index] && S_video_de_2d &&
                    S_x_2d >= label_x[render_index] &&
                    {1'b0,S_x_2d} < {1'b0,label_x[render_index]}+
                        (label_compact[render_index] ? compact_width : full_width) &&
                    S_y_2d >= label_y[render_index] &&
                    {1'b0,S_y_2d} < {1'b0,label_y[render_index]}+13'd16) begin
                    label_hit = 1'b1;
                    label_slot = render_index;
                    label_local_x = S_x_2d-label_x[render_index];
                    label_local_y = S_y_2d-label_y[render_index];
                end
            end
            if (S_target_motion_mode && label_compact[label_slot]) begin
                case (label_local_x[7:4])
                    0: label_char = 8'h31+{6'd0,label_slot};
                    2: label_char = held[label_slot] ? "H" : "O";
                    3: label_char = held[label_slot] ? " " : "K";
                    default: label_char = " ";
                endcase
            end else if (S_target_motion_mode) begin
                case (label_local_x[7:4])
                    0: label_char = 8'h31+{6'd0,label_slot};
                    2: label_char = F_target_mode_char(S_target_motion_mode,S_target_color_mode,0);
                    3: label_char = F_target_mode_char(S_target_motion_mode,S_target_color_mode,1);
                    4: label_char = F_target_mode_char(S_target_motion_mode,S_target_color_mode,2);
                    6: label_char = held[label_slot] ? "H" : "O";
                    7: label_char = held[label_slot] ? " " : "K";
                    default: label_char = " ";
                endcase
            end else if (label_compact[label_slot]) begin
                case (label_local_x[7:4])
                    0: label_char = 8'h31+{6'd0,label_slot};
                    2: label_char = F_target_shape_char(shapes[2*label_slot +: 2],0);
                    3: label_char = F_target_shape_char(shapes[2*label_slot +: 2],1);
                    4: label_char = F_target_shape_char(shapes[2*label_slot +: 2],2);
                    6: label_char = held[label_slot] ? "H" : "O";
                    7: label_char = held[label_slot] ? " " : "K";
                    default: label_char = " ";
                endcase
            end else begin
                case (label_local_x[7:4])
                    0: label_char = 8'h31+{6'd0,label_slot};
                    2: label_char = F_target_mode_char(1'b0,S_target_color_mode,0);
                    3: label_char = F_target_mode_char(1'b0,S_target_color_mode,1);
                    4: label_char = F_target_mode_char(1'b0,S_target_color_mode,2);
                    6: label_char = F_target_shape_char(shapes[2*label_slot +: 2],0);
                    7: label_char = F_target_shape_char(shapes[2*label_slot +: 2],1);
                    8: label_char = F_target_shape_char(shapes[2*label_slot +: 2],2);
                    10: label_char = held[label_slot] ? "H" : "O";
                    11: label_char = held[label_slot] ? " " : "K";
                    default: label_char = " ";
                endcase
            end
        end
    end else begin: legacy_target
        assign S_multi_count = 3'd0;
        assign S_multi_overflow = 1'b0;
        assign S_multi_box_on = 1'b0;
        assign S_multi_box_color = 24'd0;
        assign S_target_primary_shape = 2'd0;
        assign S_follow_panel_on = 1'b0;
        assign S_follow_color = 24'd0;
        assign S_follow_char = 8'h20;
        assign S_follow_row = 4'd0;
        assign S_follow_col = 4'd0;
    end endgenerate

    // Bottom-left panel: RED/GRN/BLU/MOV plus target status.
    // Uses the existing character ROM; coordinates are zero-based decimals.
    wire S_target_panel_on = (SHOW_COLOR_TARGET != 0) &&
        (!S_cnn_visible || HUD_MODERN_LAYOUT) && S_video_de_2d &&
        (S_x_2d >= TARGET_TEXT_X) &&
        (S_x_2d < TARGET_TEXT_X+TARGET_TEXT_WIDTH) &&
        (S_y_2d >= TARGET_TEXT_Y) && (S_y_2d < TARGET_TEXT_Y+TARGET_TEXT_HEIGHT);
    wire [11:0] S_target_text_x = S_x_2d - TARGET_TEXT_X;
    wire [11:0] S_target_local_y = S_y_2d - TARGET_TEXT_Y;
    wire [8:0] S_target_half_x = S_target_text_x[9:1];
    wire S_target_second_cells = S_target_half_x >= 9'd192;
    wire [8:0] S_target_half_remainder = S_target_second_cells ?
        S_target_half_x-9'd192 : S_target_half_x;
    wire [7:0] S_target_compact_cell = F_effect_compact_cell(S_target_half_remainder[7:0]);
    wire [3:0] S_target_text_y = TARGET_LARGE_TEXT ?
        S_target_local_y[4:1] : S_target_local_y[3:0];
    wire [3:0] S_target_font_col = TARGET_LARGE_TEXT ?
        S_target_compact_cell[3:0] : S_target_text_x[3:0];
    wire [4:0] S_target_char_index = TARGET_LARGE_TEXT ?
        {S_target_second_cells,S_target_compact_cell[7:4]} : S_target_text_x[8:4];
    reg [7:0] S_target_char;
    wire [15:0] S_target_char_bits;
    always @(*) begin
        S_target_char = 8'h20;
        if (MULTI_TARGET_ENABLE != 0 && TARGET_SLOTS <= 1) begin
            case (S_target_char_index)
                0: S_target_char = F_target_mode_char(S_target_motion_mode,S_target_color_mode,0);
                1: S_target_char = F_target_mode_char(S_target_motion_mode,S_target_color_mode,1);
                2: S_target_char = F_target_mode_char(S_target_motion_mode,S_target_color_mode,2);
                3: S_target_char = ":";
                4: S_target_char = S_target_found ? "F" : "N";
                5: S_target_char = "O";
                6: S_target_char = S_target_found ? "U" : "N";
                7: S_target_char = S_target_found ? "N" : "E";
                8: S_target_char = S_target_found ? "D" : " ";
                10: S_target_char = S_target_found && !S_target_motion_mode ?
                    F_target_shape_char(S_target_primary_shape,0) : " ";
                11: S_target_char = S_target_found && !S_target_motion_mode ?
                    F_target_shape_char(S_target_primary_shape,1) : " ";
                12: S_target_char = S_target_found && !S_target_motion_mode ?
                    F_target_shape_char(S_target_primary_shape,2) : " ";
                default: S_target_char = " ";
            endcase
        end else if (MULTI_TARGET_ENABLE != 0) begin
            case (S_target_char_index)
                0: S_target_char = F_target_mode_char(S_target_motion_mode,S_target_color_mode,0);
                1: S_target_char = F_target_mode_char(S_target_motion_mode,S_target_color_mode,1);
                2: S_target_char = F_target_mode_char(S_target_motion_mode,S_target_color_mode,2);
                4: S_target_char = "C";
                5: S_target_char = "O";
                6: S_target_char = "U";
                7: S_target_char = "N";
                8: S_target_char = "T";
                9: S_target_char = ":";
                10: S_target_char = 8'h30+{5'd0,S_multi_count};
                12: S_target_char = S_multi_overflow ? "O" : " ";
                13: S_target_char = S_multi_overflow ? "V" : " ";
                14: S_target_char = S_multi_overflow ? "F" : " ";
                default: S_target_char = " ";
            endcase
        end else case (S_target_char_index)
            0: S_target_char = F_target_mode_char(S_target_motion_mode,S_target_color_mode,0);
            1: S_target_char = F_target_mode_char(S_target_motion_mode,S_target_color_mode,1);
            2: S_target_char = F_target_mode_char(S_target_motion_mode,S_target_color_mode,2);
            3: S_target_char = ":";
            4: S_target_char = S_target_found ? "F" : "N";
            5: S_target_char = "O";
            6: S_target_char = S_target_found ? "U" : "N";
            7: S_target_char = S_target_found ? "N" : "E";
            8: S_target_char = S_target_found ? "D" : " ";
            10: S_target_char = S_target_found ? "X" : " ";
            11: S_target_char = S_target_found ? ":" : " ";
            12: S_target_char = S_target_found ? 8'h30+{4'd0,S_target_bcd_x[15:12]} : " ";
            13: S_target_char = S_target_found ? 8'h30+{4'd0,S_target_bcd_x[11:8]} : " ";
            14: S_target_char = S_target_found ? 8'h30+{4'd0,S_target_bcd_x[7:4]} : " ";
            15: S_target_char = S_target_found ? 8'h30+{4'd0,S_target_bcd_x[3:0]} : " ";
            17: S_target_char = S_target_found ? "Y" : " ";
            18: S_target_char = S_target_found ? ":" : " ";
            19: S_target_char = S_target_found ? 8'h30+{4'd0,S_target_bcd_y[15:12]} : " ";
            20: S_target_char = S_target_found ? 8'h30+{4'd0,S_target_bcd_y[11:8]} : " ";
            21: S_target_char = S_target_found ? 8'h30+{4'd0,S_target_bcd_y[7:4]} : " ";
            22: S_target_char = S_target_found ? 8'h30+{4'd0,S_target_bcd_y[3:0]} : " ";
            default: S_target_char = 8'h20;
        endcase
    end
    wire S_effect_panel_on = (SHOW_EFFECT_LABEL != 0) && S_video_de_2d &&
        (S_x_2d >= EFFECT_TEXT_X) && (S_x_2d < EFFECT_TEXT_X+EFFECT_TEXT_WIDTH) &&
        (S_y_2d >= EFFECT_TEXT_Y) && (S_y_2d < EFFECT_TEXT_Y+EFFECT_TEXT_HEIGHT);
    wire [11:0] S_effect_text_x = S_x_2d - EFFECT_TEXT_X;
    wire [11:0] S_effect_local_y = S_y_2d - EFFECT_TEXT_Y;
    wire [7:0] S_effect_compact_cell = F_effect_compact_cell(S_effect_text_x[8:1]);
    wire [3:0] S_effect_text_y = HUD_LARGE_TEXT ?
        S_effect_local_y[4:1] : S_effect_local_y[3:0];
    wire [3:0] S_effect_font_col = HUD_LARGE_TEXT ?
        S_effect_compact_cell[3:0] : S_effect_text_x[3:0];
    wire [4:0] S_effect_char_index = HUD_LARGE_TEXT ?
        {1'b0,S_effect_compact_cell[7:4]} : S_effect_text_x[8:4];
    reg [95:0] S_effect_name;
    reg [7:0] S_effect_char;
    always @(*) begin
        case (S_effect_mode)
            0: S_effect_name = "COLOR GAMMA ";
            1: S_effect_name = "GRAYSCALE   ";
            2: S_effect_name = "SCHARR EDGE ";
            3: S_effect_name = "NEGATIVE    ";
            4: S_effect_name = "EMBOSS      ";
            5: S_effect_name = "COLOR KEEP  ";
            6: S_effect_name = "CARTOON     ";
            7: S_effect_name = "SCHARR INV  ";
            8: S_effect_name = "MORPH EDGE  ";
            9: S_effect_name = "BINARY      ";
            10: S_effect_name = "EROSION     ";
            11: S_effect_name = "DILATION    ";
            12: S_effect_name = "CLOSE MASK  ";
            default: S_effect_name = "COLOR GAMMA ";
        endcase
        S_effect_char = " ";
        if (S_effect_char_index == 0)
            S_effect_char = S_effect_mode >= 4'd10 ? "1" : "0";
        else if (S_effect_char_index == 1)
            S_effect_char = 8'h30 + (S_effect_mode >= 4'd10 ?
                {4'd0,S_effect_mode}-8'd10 : {4'd0,S_effect_mode});
        else if (S_effect_char_index >= 3 && S_effect_char_index <= 14)
            S_effect_char = S_effect_name[95-8*(S_effect_char_index-3) -: 8];
    end

    // CNN status label. Keep the declarations before the shared character ROM
    // instance; otherwise older Verilog elaboration treats the earlier uses as
    // implicit nets and the synthesized panel becomes undriven.
    localparam CNN_TEXT_X = 16;
    localparam CNN_TEXT_Y = 16;
    localparam integer FRUIT_PANEL_WIDTH = IMG_WIDTH >= 320 ? 320 : IMG_WIDTH;
    localparam integer FRUIT_PANEL_X = IMG_WIDTH-FRUIT_PANEL_WIDTH;
    wire S_fruit_showcase = (FRUIT_CNN != 0) &&
        (SHOW_RESNET_PROBE == 0) && (SHOW_RESNET_RUNTIME == 0);
    wire S_fruit_panel_bg_on = S_fruit_showcase && S_cnn_visible &&
        S_video_de_2d && S_x_2d >= FRUIT_PANEL_X;
    wire S_fruit_header_on = S_fruit_panel_bg_on &&
        S_x_2d >= FRUIT_PANEL_X+24 && S_x_2d < FRUIT_PANEL_X+296 &&
        S_y_2d >= 64 && S_y_2d < 80;
    wire S_fruit_chinese_on = S_fruit_panel_bg_on &&
        S_x_2d >= FRUIT_PANEL_X+96 && S_x_2d < FRUIT_PANEL_X+224 &&
        S_y_2d >= 216 && S_y_2d < 280;
    wire S_fruit_english_on = S_fruit_panel_bg_on &&
        S_x_2d < FRUIT_PANEL_X+320 &&
        S_y_2d >= 328 && S_y_2d < 360;
    wire S_fruit_weight_label_on = S_fruit_panel_bg_on &&
        S_x_2d >= FRUIT_PANEL_X+64 && S_x_2d < FRUIT_PANEL_X+160 &&
        S_y_2d >= 392 && S_y_2d < 408;
    wire S_fruit_weight_value_on = S_fruit_panel_bg_on &&
        S_x_2d >= FRUIT_PANEL_X+32 && S_x_2d < FRUIT_PANEL_X+288 &&
        S_y_2d >= 424 && S_y_2d < 456;
    wire S_fruit_total_label_on = S_fruit_panel_bg_on &&
        S_x_2d >= FRUIT_PANEL_X+64 && S_x_2d < FRUIT_PANEL_X+144 &&
        S_y_2d >= 488 && S_y_2d < 504;
    wire S_fruit_total_value_on = S_fruit_panel_bg_on &&
        S_x_2d >= FRUIT_PANEL_X+16 && S_x_2d < FRUIT_PANEL_X+304 &&
        S_y_2d >= 520 && S_y_2d < 552;
    wire S_fruit_text_on = S_fruit_header_on || S_fruit_chinese_on || S_fruit_english_on ||
        S_fruit_weight_label_on || S_fruit_weight_value_on ||
        S_fruit_total_label_on || S_fruit_total_value_on;
    wire S_legacy_cnn_panel_on = S_cnn_visible && S_video_de_2d &&
        (S_x_2d >= CNN_TEXT_X) &&
        (S_x_2d < CNN_TEXT_X+(SHOW_RESNET_PROBE != 0 ? 320 : SHOW_RESNET_RUNTIME != 0 ? 256 : FRUIT_CNN != 0 ? 208 : 192)) &&
        (S_y_2d >= CNN_TEXT_Y) && (S_y_2d < CNN_TEXT_Y+(SHOW_RESNET_RUNTIME != 0 ? 32 : 16));
    wire S_cnn_panel_on = S_fruit_showcase ? S_fruit_text_on : S_legacy_cnn_panel_on;
    reg [11:0] S_cnn_text_x;
    reg [11:0] S_cnn_local_y;
    reg [3:0] S_cnn_text_y;
    reg [3:0] S_cnn_font_col;
    reg [4:0] S_cnn_char_index;
    always @(*) begin
        S_cnn_text_x=S_x_2d-CNN_TEXT_X;
        S_cnn_local_y=S_y_2d-CNN_TEXT_Y;
        S_cnn_char_index=S_cnn_text_x[8:4];
        S_cnn_font_col=S_cnn_text_x[3:0];
        S_cnn_text_y=S_cnn_local_y[3:0];
        if(S_fruit_header_on) begin
            S_cnn_text_x=S_x_2d-(FRUIT_PANEL_X+24);
            S_cnn_local_y=S_y_2d-64;
            S_cnn_char_index=S_cnn_text_x[8:4];
            S_cnn_font_col=S_cnn_text_x[3:0];
            S_cnn_text_y=S_cnn_local_y[3:0];
        end else if(S_fruit_chinese_on) begin
            S_cnn_text_x=S_x_2d-(FRUIT_PANEL_X+96);
            S_cnn_local_y=S_y_2d-216;
            S_cnn_char_index={4'd0,S_cnn_text_x[6]};
            S_cnn_font_col=S_cnn_text_x[5:2];
            S_cnn_text_y=S_cnn_local_y[5:2];
        end else if(S_fruit_english_on) begin
            S_cnn_text_x=S_x_2d-FRUIT_PANEL_X;
            S_cnn_local_y=S_y_2d-328;
            S_cnn_char_index=S_cnn_text_x[8:5];
            S_cnn_font_col=S_cnn_text_x[4:1];
            S_cnn_text_y=S_cnn_local_y[4:1];
        end else if(S_fruit_weight_label_on) begin
            S_cnn_text_x=S_x_2d-(FRUIT_PANEL_X+64);
            S_cnn_local_y=S_y_2d-392;
            S_cnn_char_index=S_cnn_text_x[8:4];
            S_cnn_font_col=S_cnn_text_x[3:0];
            S_cnn_text_y=S_cnn_local_y[3:0];
        end else if(S_fruit_weight_value_on) begin
            S_cnn_text_x=S_x_2d-(FRUIT_PANEL_X+32);
            S_cnn_local_y=S_y_2d-424;
            S_cnn_char_index=S_cnn_text_x[8:5];
            S_cnn_font_col=S_cnn_text_x[4:1];
            S_cnn_text_y=S_cnn_local_y[4:1];
        end else if(S_fruit_total_label_on) begin
            S_cnn_text_x=S_x_2d-(FRUIT_PANEL_X+64);
            S_cnn_local_y=S_y_2d-488;
            S_cnn_char_index=S_cnn_text_x[8:4];
            S_cnn_font_col=S_cnn_text_x[3:0];
            S_cnn_text_y=S_cnn_local_y[3:0];
        end else if(S_fruit_total_value_on) begin
            S_cnn_text_x=S_x_2d-(FRUIT_PANEL_X+16);
            S_cnn_local_y=S_y_2d-520;
            S_cnn_char_index=S_cnn_text_x[8:5];
            S_cnn_font_col=S_cnn_text_x[4:1];
            S_cnn_text_y=S_cnn_local_y[4:1];
        end
    end
    reg [7:0] S_cnn_char;
    reg S_cnn_runtime_row_2d;
    reg [127:0] S_runtime_text;
    reg [135:0] S_fruit_header_text;
    reg [15:0] S_fruit_chinese_text;
    reg [79:0] S_fruit_english_text;
    reg [47:0] S_fruit_weight_label_text;
    reg [39:0] S_fruit_total_label_text;
    reg [23:0] S_fruit_color;
    always @(*) begin
        S_fruit_header_text="FRUIT RECOGNITION";
        S_fruit_weight_label_text="WEIGHT";
        S_fruit_total_label_text="TOTAL";
        case(S_cnn_class)
            3'd2: begin S_fruit_chinese_text=16'h8283; S_fruit_english_text="  APPLE   "; S_fruit_color=24'hff4058; end
            3'd3: begin S_fruit_chinese_text=16'h8485; S_fruit_english_text="  BANANA  "; S_fruit_color=24'hffd43b; end
            3'd4: begin S_fruit_chinese_text=16'h8687; S_fruit_english_text="  GRAPE   "; S_fruit_color=24'hb080ff; end
            3'd5: begin S_fruit_chinese_text=16'h8889; S_fruit_english_text="  ORANGE  "; S_fruit_color=24'hff8a30; end
            3'd6: begin S_fruit_chinese_text=16'h8a8b; S_fruit_english_text="STRAWBERRY"; S_fruit_color=24'hff4068; end
            default: begin S_fruit_chinese_text=16'h2d2d; S_fruit_english_text=" UNKNOWN  "; S_fruit_color=24'hffc040; end
        endcase
    end
    // Frame only the four populated sections: title, result, weight and price.
    // The removed status row shares the result section; the empty tail is open.
    wire S_fruit_frame_on = S_fruit_panel_bg_on && S_y_2d < 576 &&
        (S_x_2d < FRUIT_PANEL_X+4 || S_x_2d >= IMG_WIDTH-4 ||
         S_y_2d < 4 ||
         (S_y_2d >= 104 && S_y_2d < 108) ||
         (S_y_2d >= 376 && S_y_2d < 380) ||
         (S_y_2d >= 472 && S_y_2d < 476) ||
         (S_y_2d >= 572 && S_y_2d < 576));
    wire S_fruit_name_text_on = S_fruit_chinese_on || S_fruit_english_on;
    wire S_fruit_value_text_on = S_fruit_weight_value_on || S_fruit_total_value_on;
    always @(*) begin
        if(I_resnet_probe_status[29]) S_runtime_text="DDR ERROR       ";
        else if(!I_resnet_probe_status[25]) S_runtime_text="WAIT MODEL      ";
        else if(I_resnet_probe_status[26])
            S_runtime_text=I_resnet_probe_status[27] ? "CAP RETRY       " : "CAPTURE         ";
        else if(I_resnet_probe_status[28]) S_runtime_text="RUN OP          ";
        else if(!I_resnet_probe_status[18]) S_runtime_text="WAIT RESULT     ";
        else if(I_resnet_probe_status[21:19]==3'd1) S_runtime_text="LOW CONF        ";
        else S_runtime_text="RESULT READY    ";
    end
    // New ResNet uses full-frame letterbox. Square mode is a display-only
    // compatibility option for historical component benches.
    localparam integer CNN_ROI_SIDE = IMG_WIDTH < IMG_HEIGHT ? IMG_WIDTH : IMG_HEIGHT;
    localparam integer CNN_ROI_WIDTH = CNN_FULL_FRAME_INPUT ? IMG_WIDTH : CNN_ROI_SIDE;
    localparam integer CNN_ROI_HEIGHT = CNN_FULL_FRAME_INPUT ? IMG_HEIGHT : CNN_ROI_SIDE;
    localparam integer CNN_ROI_X = (IMG_WIDTH-CNN_ROI_WIDTH)/2;
    localparam integer CNN_ROI_Y = (IMG_HEIGHT-CNN_ROI_HEIGHT)/2;
    wire S_legacy_cnn_roi_on = S_cnn_visible && (SHOW_RESNET_PROBE == 0) &&
        S_video_de_2d &&
        S_x_2d >= CNN_ROI_X && S_x_2d < CNN_ROI_X+CNN_ROI_WIDTH &&
        S_y_2d >= CNN_ROI_Y && S_y_2d < CNN_ROI_Y+CNN_ROI_HEIGHT &&
        (S_x_2d < CNN_ROI_X+2 || S_x_2d >= CNN_ROI_X+CNN_ROI_WIDTH-2 ||
         S_y_2d < CNN_ROI_Y+2 || S_y_2d >= CNN_ROI_Y+CNN_ROI_HEIGHT-2);
    reg [48:0] S_hand_box;
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) S_hand_box<=0;
        else if(I_video_user) S_hand_box<={I_hand_box_valid &&
            (!(CNN_RESULT_TIMEOUT_FRAMES != 0 && S_cnn_result_age>=CNN_RESULT_TIMEOUT_FRAMES-1) || I_cnn_result_valid),I_hand_box};
    end
    wire [11:0] hx1=S_hand_box[11:0],hx2=S_hand_box[23:12],hy1=S_hand_box[35:24],hy2=S_hand_box[47:36];
    wire S_hand_roi_on=S_cnn_visible && S_hand_box[48] && S_video_de_2d &&
        S_x_2d>=hx1 && S_x_2d<=hx2 && S_y_2d>=hy1 && S_y_2d<=hy2 &&
        (S_x_2d<hx1+2 || S_x_2d+2>hx2 || S_y_2d<hy1+2 || S_y_2d+2>hy2);
    wire S_cnn_roi_on=HANDCNN_DYNAMIC_ROI ? S_hand_roi_on : S_legacy_cnn_roi_on;

    // Fixed panels and all following labels share one character lookup.
    osd_char_rom_sync u_target_char_lib (
        .I_clk(I_clk),
        .I_char(S_effect_panel_on ? S_effect_char :
                S_cnn_panel_on ? S_cnn_char :
                S_target_panel_on ? S_target_char : S_follow_char),
        .I_row(S_effect_panel_on ? S_effect_text_y :
               S_cnn_panel_on ? S_cnn_text_y :
               S_target_panel_on ? S_target_text_y : S_follow_row),
        .O_row_bits(S_target_char_bits)
    );
    wire [3:0] S_font_col = S_effect_panel_on ? S_effect_font_col :
                           S_cnn_panel_on ? S_cnn_font_col :
                           S_target_panel_on ? S_target_font_col : S_follow_col;

    always @(*) begin
        S_cnn_char = 8'h20;
        case (S_cnn_char_index)
            0: S_cnn_char = "H";
            1: S_cnn_char = "A";
            2: S_cnn_char = "N";
            3: S_cnn_char = "D";
            5: begin
                case (S_cnn_class)
                    3'd1: S_cnn_char = "N";
                    3'd2: S_cnn_char = "P";
                    3'd3: S_cnn_char = "P";
                    default: S_cnn_char = "S";
                endcase
            end
            6: begin
                case (S_cnn_class)
                    3'd1: S_cnn_char = "O";
                    3'd2: S_cnn_char = "E";
                    3'd3: S_cnn_char = "U";
                    default: S_cnn_char = "T";
                endcase
            end
            7: begin
                case (S_cnn_class)
                    3'd1: S_cnn_char = "T";
                    3'd2: S_cnn_char = "A";
                    3'd3: S_cnn_char = "N";
                    3'd4: S_cnn_char = "O";
                    default: S_cnn_char = " ";
                endcase
            end
            8: begin
                case (S_cnn_class)
                    3'd1: S_cnn_char = "H";
                    3'd2: S_cnn_char = "C";
                    3'd3: S_cnn_char = "C";
                    3'd4: S_cnn_char = "P";
                    default: S_cnn_char = " ";
                endcase
            end
            9: S_cnn_char = S_cnn_class == 3'd1 ? "I" :
                            S_cnn_class == 3'd2 ? "E" :
                            S_cnn_class == 3'd3 ? "H" : " ";
            10: S_cnn_char = S_cnn_class == 3'd1 ? "N" : " ";
            11: S_cnn_char = S_cnn_class == 3'd1 ? "G" : " ";
            default: S_cnn_char = 8'h20;
        endcase
        if (FRUIT_CNN != 0) begin
            case (S_cnn_char_index)
                0: S_cnn_char="F";
                1: S_cnn_char="R";
                2: S_cnn_char="U";
                3: S_cnn_char="I";
                4: S_cnn_char="T";
                5: S_cnn_char=" ";
                6,7,8,9,10,11,12: begin
                    case (S_cnn_class)
                        3'd2: S_cnn_char=F_fruit_char(56'h4150504c452020,S_cnn_char_index-6);
                        3'd3: S_cnn_char=F_fruit_char(56'h42414e414e4120,S_cnn_char_index-6);
                        3'd4: S_cnn_char=F_fruit_char(56'h47524150452020,S_cnn_char_index-6);
                        3'd5: S_cnn_char=F_fruit_char(56'h4f52414e474520,S_cnn_char_index-6);
                        3'd6: S_cnn_char=F_fruit_char(56'h53545241574252,S_cnn_char_index-6);
                        default: S_cnn_char=F_fruit_char(56'h554e4b4e4f574e,S_cnn_char_index-6);
                    endcase
                end
                default: S_cnn_char=" ";
            endcase
        end
        if (SHOW_RESNET_PROBE != 0) begin
            case (S_cnn_char_index)
                0: S_cnn_char="R";
                1: S_cnn_char="N";
                2: S_cnn_char="E";
                3: S_cnn_char="T";
                5: S_cnn_char="T";
                6: S_cnn_char="E";
                7: S_cnn_char="S";
                8: S_cnn_char="T";
                10,11,12,13,14,15:
                    S_cnn_char=F_probe_hex(I_resnet_probe_status[23-(S_cnn_char_index-10)*4 -: 4]);
                17: S_cnn_char=F_probe_hex(I_resnet_probe_status[31:28]);
                18: S_cnn_char=F_probe_hex(I_resnet_probe_status[27:24]);
                default: S_cnn_char=" ";
            endcase
        end
        if (SHOW_RESNET_RUNTIME != 0 && S_cnn_runtime_row_2d) begin
            S_cnn_char=S_runtime_text[127-S_cnn_char_index*8 -: 8];
            if(S_cnn_char_index==10 && I_resnet_probe_status[28])
                S_cnn_char=F_probe_hex(I_resnet_probe_status[15:12]);
            if(S_cnn_char_index==11 && I_resnet_probe_status[28])
                S_cnn_char=F_probe_hex(I_resnet_probe_status[11:8]);
            if(S_cnn_char_index==14) S_cnn_char=F_probe_hex(I_resnet_probe_status[7:4]);
            if(S_cnn_char_index==15) S_cnn_char=F_probe_hex(I_resnet_probe_status[3:0]);
        end
        if(S_fruit_showcase) begin
            if(S_fruit_header_on)
                S_cnn_char=S_fruit_header_text[135-S_cnn_char_index*8 -: 8];
            else if(S_fruit_chinese_on)
                S_cnn_char=S_fruit_chinese_text[15-S_cnn_char_index*8 -: 8];
            else if(S_fruit_english_on)
                S_cnn_char=S_fruit_english_text[79-S_cnn_char_index*8 -: 8];
            else if(S_fruit_weight_label_on)
                S_cnn_char=S_fruit_weight_label_text[47-S_cnn_char_index*8 -: 8];
            else if(S_fruit_weight_value_on) begin
                // The checkout BCD stores whole grams. Insert the decimal
                // point after the thousands digit for exact d.ddd kilograms.
                case(S_cnn_char_index)
                    0: S_cnn_char=!I_checkout_weight_valid ? "-" : F_decimal_digit(I_checkout_weight_bcd[15:12]);
                    1: S_cnn_char=".";
                    2: S_cnn_char=!I_checkout_weight_valid ? "-" :
                        F_decimal_digit(I_checkout_weight_bcd[11:8]);
                    3: S_cnn_char=!I_checkout_weight_valid ? "-" : F_decimal_digit(I_checkout_weight_bcd[7:4]);
                    4: S_cnn_char=!I_checkout_weight_valid ? "-" : F_decimal_digit(I_checkout_weight_bcd[3:0]);
                    5: S_cnn_char=" ";
                    6: S_cnn_char="k";
                    7: S_cnn_char="g";
                    default: S_cnn_char=" ";
                endcase
            end else if(S_fruit_total_label_on)
                S_cnn_char=S_fruit_total_label_text[39-S_cnn_char_index*8 -: 8];
            else if(S_fruit_total_value_on) begin
                case(S_cnn_char_index)
                    0: S_cnn_char=!I_checkout_price_valid ? "-" :
                        (I_checkout_price_bcd[15:12]==0 ? " " : F_decimal_digit(I_checkout_price_bcd[15:12]));
                    1: S_cnn_char=!I_checkout_price_valid ? "-" : F_decimal_digit(I_checkout_price_bcd[11:8]);
                    2: S_cnn_char=".";
                    3: S_cnn_char=!I_checkout_price_valid ? "-" : F_decimal_digit(I_checkout_price_bcd[7:4]);
                    4: S_cnn_char=!I_checkout_price_valid ? "-" : F_decimal_digit(I_checkout_price_bcd[3:0]);
                    5: S_cnn_char=" ";
                    6: S_cnn_char="R";
                    7: S_cnn_char="M";
                    8: S_cnn_char="B";
                    default: S_cnn_char=" ";
                endcase
            end
            else
                S_cnn_char=" ";
        end
    end

    function [7:0] F_fruit_char;
        input [55:0] label;
        input [4:0] position;
        begin F_fruit_char=label[55-position*8 -: 8];end
    endfunction

    function [7:0] F_decimal_digit;
        input [3:0] digit;
        begin F_decimal_digit=digit<10 ? 8'h30+digit : "-";end
    endfunction

    function [7:0] F_probe_hex;
        input [3:0] nibble;
        begin
            F_probe_hex=nibble<10 ? 8'h30+nibble : 8'h41+(nibble-10);
        end
    endfunction

    wire S_raw_panel, S_raw_text, S_raw_alert;
    generate if (SHOW_RAW_STATS != 0) begin: raw_readout
        raw_stats_osd u_osd (
            .I_clk(I_clk), .I_rst_n(I_rst_n),
            .I_stats_valid(I_raw_stats_valid), .I_stats_data(I_raw_stats_data),
            .I_ae_valid(I_ae_readout_valid), .I_ae_data(I_ae_readout_data),
            .I_frame_start(S_video_de_1d && S_x_1d==0 && S_y_1d==0),
            .I_de(S_video_de_1d), .I_x(S_x_1d), .I_y(S_y_1d),
            .O_panel(S_raw_panel), .O_text(S_raw_text), .O_alert(S_raw_alert)
        );
    end else begin: no_raw_readout
        assign S_raw_panel=1'b0;
        assign S_raw_text=1'b0;
        assign S_raw_alert=1'b0;
    end endgenerate

    wire S_latency_panel, S_latency_text, S_latency_alert;
    generate if (SHOW_LATENCY != 0) begin: latency_readout
        video_latency_osd #(
            .PANEL_X(LATENCY_PANEL_X), .PANEL_Y(LATENCY_PANEL_Y),
            .LARGE_TEXT(HUD_LARGE_TEXT), .NARROW_TEXT(HUD_LARGE_TEXT)
        ) u_osd (
            .I_clk(I_clk), .I_rst_n(I_rst_n),
            .I_sample_strobe(I_latency_sample_strobe),
            .I_sample_valid(I_latency_sample_valid),
            .I_total_us(I_latency_total_us), .I_isp_us(I_latency_isp_us),
            .I_buffer_us(I_latency_buffer_us),
            .I_de(S_video_de_1d && S_latency_visible),
            .I_x(S_x_1d), .I_y(S_y_1d),
            .O_panel(S_latency_panel), .O_text(S_latency_text),
            .O_alert(S_latency_alert)
        );
    end else begin: no_latency_readout
        assign S_latency_panel=1'b0;
        assign S_latency_text=1'b0;
        assign S_latency_alert=1'b0;
    end endgenerate

    function [4:0] F_logo_text_bits;
        input [3:0] I_char;
        input [2:0] I_row;
        begin
            case(I_char)
                4'd0: begin
                    case(I_row) // A
                        3'd0: F_logo_text_bits = 5'b01110;
                        3'd1: F_logo_text_bits = 5'b10001;
                        3'd2: F_logo_text_bits = 5'b10001;
                        3'd3: F_logo_text_bits = 5'b11111;
                        3'd4: F_logo_text_bits = 5'b10001;
                        3'd5: F_logo_text_bits = 5'b10001;
                        3'd6: F_logo_text_bits = 5'b10001;
                        default: F_logo_text_bits = 5'b00000;
                    endcase
                end
                4'd1: begin
                    case(I_row) // N
                        3'd0: F_logo_text_bits = 5'b10001;
                        3'd1: F_logo_text_bits = 5'b11001;
                        3'd2: F_logo_text_bits = 5'b10101;
                        3'd3: F_logo_text_bits = 5'b10011;
                        3'd4: F_logo_text_bits = 5'b10001;
                        3'd5: F_logo_text_bits = 5'b10001;
                        3'd6: F_logo_text_bits = 5'b10001;
                        default: F_logo_text_bits = 5'b00000;
                    endcase
                end
                4'd2: begin
                    case(I_row) // L
                        3'd0: F_logo_text_bits = 5'b10000;
                        3'd1: F_logo_text_bits = 5'b10000;
                        3'd2: F_logo_text_bits = 5'b10000;
                        3'd3: F_logo_text_bits = 5'b10000;
                        3'd4: F_logo_text_bits = 5'b10000;
                        3'd5: F_logo_text_bits = 5'b10000;
                        3'd6: F_logo_text_bits = 5'b11111;
                        default: F_logo_text_bits = 5'b00000;
                    endcase
                end
                4'd3: begin
                    case(I_row) // O
                        3'd0: F_logo_text_bits = 5'b01110;
                        3'd1: F_logo_text_bits = 5'b10001;
                        3'd2: F_logo_text_bits = 5'b10001;
                        3'd3: F_logo_text_bits = 5'b10001;
                        3'd4: F_logo_text_bits = 5'b10001;
                        3'd5: F_logo_text_bits = 5'b10001;
                        3'd6: F_logo_text_bits = 5'b01110;
                        default: F_logo_text_bits = 5'b00000;
                    endcase
                end
                4'd4: begin
                    case(I_row) // G
                        3'd0: F_logo_text_bits = 5'b01110;
                        3'd1: F_logo_text_bits = 5'b10001;
                        3'd2: F_logo_text_bits = 5'b10000;
                        3'd3: F_logo_text_bits = 5'b10111;
                        3'd4: F_logo_text_bits = 5'b10001;
                        3'd5: F_logo_text_bits = 5'b10001;
                        3'd6: F_logo_text_bits = 5'b01110;
                        default: F_logo_text_bits = 5'b00000;
                    endcase
                end
                4'd5: begin
                    case(I_row) // I
                        3'd0: F_logo_text_bits = 5'b11111;
                        3'd1: F_logo_text_bits = 5'b00100;
                        3'd2: F_logo_text_bits = 5'b00100;
                        3'd3: F_logo_text_bits = 5'b00100;
                        3'd4: F_logo_text_bits = 5'b00100;
                        3'd5: F_logo_text_bits = 5'b00100;
                        3'd6: F_logo_text_bits = 5'b11111;
                        default: F_logo_text_bits = 5'b00000;
                    endcase
                end
                4'd6: begin
                    case(I_row) // C
                        3'd0: F_logo_text_bits = 5'b01110;
                        3'd1: F_logo_text_bits = 5'b10001;
                        3'd2: F_logo_text_bits = 5'b10000;
                        3'd3: F_logo_text_bits = 5'b10000;
                        3'd4: F_logo_text_bits = 5'b10000;
                        3'd5: F_logo_text_bits = 5'b10001;
                        3'd6: F_logo_text_bits = 5'b01110;
                        default: F_logo_text_bits = 5'b00000;
                    endcase
                end
                default: F_logo_text_bits = 5'b00000;
            endcase
        end
    endfunction

    // 7-seg bit mapping: {a,b,c,d,e,f,g}
    function [6:0] F_hex7seg;
        input [3:0] I_hex;
        begin
            case(I_hex)
                4'h0: F_hex7seg = 7'b1111110;
                4'h1: F_hex7seg = 7'b0110000;
                4'h2: F_hex7seg = 7'b1101101;
                4'h3: F_hex7seg = 7'b1111001;
                4'h4: F_hex7seg = 7'b0110011;
                4'h5: F_hex7seg = 7'b1011011;
                4'h6: F_hex7seg = 7'b1011111;
                4'h7: F_hex7seg = 7'b1110000;
                4'h8: F_hex7seg = 7'b1111111;
                4'h9: F_hex7seg = 7'b1111011;
                4'ha: F_hex7seg = 7'b1110111;
                4'hb: F_hex7seg = 7'b0011111;
                4'hc: F_hex7seg = 7'b1001110;
                4'hd: F_hex7seg = 7'b0111101;
                4'he: F_hex7seg = 7'b1001111;
                4'hf: F_hex7seg = 7'b1000111;
                default: F_hex7seg = 7'b0000000;
            endcase
        end
    endfunction

    function F_fail_digit_on;
        input [3:0] I_hex;
        input [3:0] I_x;
        input [4:0] I_y;
        reg [6:0] seg;
        begin
            seg = F_hex7seg(I_hex);
            F_fail_digit_on =
                (seg[6] && I_y >= 5'd2  && I_y < 5'd5  && I_x >= 4'd3  && I_x < 4'd13) ||
                (seg[5] && I_y >= 5'd4  && I_y < 5'd12 && I_x >= 4'd12 && I_x < 4'd15) ||
                (seg[4] && I_y >= 5'd12 && I_y < 5'd21 && I_x >= 4'd12 && I_x < 4'd15) ||
                (seg[3] && I_y >= 5'd20 && I_y < 5'd23 && I_x >= 4'd3  && I_x < 4'd13) ||
                (seg[2] && I_y >= 5'd12 && I_y < 5'd21 && I_x >= 4'd1  && I_x < 4'd4 ) ||
                (seg[1] && I_y >= 5'd4  && I_y < 5'd12 && I_x >= 4'd1  && I_x < 4'd4 ) ||
                (seg[0] && I_y >= 5'd11 && I_y < 5'd14 && I_x >= 4'd3  && I_x < 4'd13);
        end
    endfunction

    function [4:0] F_cnt_label_bits;
        input [1:0] I_idx;
        input [2:0] I_row;
        begin
            case(I_idx)
                2'd0: begin // C
                    case(I_row)
                        3'd0: F_cnt_label_bits = 5'b01110;
                        3'd1: F_cnt_label_bits = 5'b10001;
                        3'd2: F_cnt_label_bits = 5'b10000;
                        3'd3: F_cnt_label_bits = 5'b10000;
                        3'd4: F_cnt_label_bits = 5'b10000;
                        3'd5: F_cnt_label_bits = 5'b10001;
                        3'd6: F_cnt_label_bits = 5'b01110;
                        default: F_cnt_label_bits = 5'b00000;
                    endcase
                end
                2'd1: begin // N
                    case(I_row)
                        3'd0: F_cnt_label_bits = 5'b10001;
                        3'd1: F_cnt_label_bits = 5'b11001;
                        3'd2: F_cnt_label_bits = 5'b10101;
                        3'd3: F_cnt_label_bits = 5'b10011;
                        3'd4: F_cnt_label_bits = 5'b10001;
                        3'd5: F_cnt_label_bits = 5'b10001;
                        3'd6: F_cnt_label_bits = 5'b10001;
                        default: F_cnt_label_bits = 5'b00000;
                    endcase
                end
                2'd2: begin // T
                    case(I_row)
                        3'd0: F_cnt_label_bits = 5'b11111;
                        3'd1: F_cnt_label_bits = 5'b00100;
                        3'd2: F_cnt_label_bits = 5'b00100;
                        3'd3: F_cnt_label_bits = 5'b00100;
                        3'd4: F_cnt_label_bits = 5'b00100;
                        3'd5: F_cnt_label_bits = 5'b00100;
                        3'd6: F_cnt_label_bits = 5'b00100;
                        default: F_cnt_label_bits = 5'b00000;
                    endcase
                end
                default: begin // ':'
                    case(I_row)
                        3'd2: F_cnt_label_bits = 5'b00100;
                        3'd5: F_cnt_label_bits = 5'b00100;
                        default: F_cnt_label_bits = 5'b00000;
                    endcase
                end
            endcase
        end
    endfunction

    // Minimal 16x16 Chinese bitmap rows for "an" and "lu".
    function [15:0] F_cn16_row;
        input I_char; // 0: an, 1: lu
        input [3:0] I_row;
        begin
            if(!I_char) begin
                case(I_row)
                    4'd0:  F_cn16_row = 16'h0200;
                    4'd1:  F_cn16_row = 16'h7ff0;
                    4'd2:  F_cn16_row = 16'h4410;
                    4'd3:  F_cn16_row = 16'h0400;
                    4'd4:  F_cn16_row = 16'h7ff0;
                    4'd5:  F_cn16_row = 16'h0840;
                    4'd6:  F_cn16_row = 16'h1040;
                    4'd7:  F_cn16_row = 16'h1c80;
                    4'd8:  F_cn16_row = 16'h0300;
                    4'd9:  F_cn16_row = 16'h0cc0;
                    4'd10: F_cn16_row = 16'h7020;
                    4'd11: F_cn16_row = 16'h0000;
                    4'd12: F_cn16_row = 16'h0000;
                    4'd13: F_cn16_row = 16'h0000;
                    4'd14: F_cn16_row = 16'h0000;
                    4'd15: F_cn16_row = 16'h0000;
                    default: F_cn16_row = 16'h0000;
                endcase
            end
            else begin
                case(I_row)
                    4'd0:  F_cn16_row = 16'h79e0;
                    4'd1:  F_cn16_row = 16'h4a20;
                    4'd2:  F_cn16_row = 16'h4d40;
                    4'd3:  F_cn16_row = 16'h7880;
                    4'd4:  F_cn16_row = 16'h1140;
                    4'd5:  F_cn16_row = 16'h1630;
                    4'd6:  F_cn16_row = 16'h5be0;
                    4'd7:  F_cn16_row = 16'h5220;
                    4'd8:  F_cn16_row = 16'h5220;
                    4'd9:  F_cn16_row = 16'h5be0;
                    4'd10: F_cn16_row = 16'h6220;
                    4'd11: F_cn16_row = 16'h0000;
                    4'd12: F_cn16_row = 16'h0000;
                    4'd13: F_cn16_row = 16'h0000;
                    4'd14: F_cn16_row = 16'h0000;
                    4'd15: F_cn16_row = 16'h0000;
                    default: F_cn16_row = 16'h0000;
                endcase
            end
        end
    endfunction

    function [4:0] F_dyn_char_bits;
        input [3:0] I_char;
        input [2:0] I_row;
        begin
            case(I_char)
                4'h0: begin case(I_row) 3'd0:F_dyn_char_bits=5'b01110; 3'd1:F_dyn_char_bits=5'b10001; 3'd2:F_dyn_char_bits=5'b10011; 3'd3:F_dyn_char_bits=5'b10101; 3'd4:F_dyn_char_bits=5'b11001; 3'd5:F_dyn_char_bits=5'b10001; 3'd6:F_dyn_char_bits=5'b01110; default:F_dyn_char_bits=5'b00000; endcase end
                4'h1: begin case(I_row) 3'd0:F_dyn_char_bits=5'b00100; 3'd1:F_dyn_char_bits=5'b01100; 3'd2:F_dyn_char_bits=5'b00100; 3'd3:F_dyn_char_bits=5'b00100; 3'd4:F_dyn_char_bits=5'b00100; 3'd5:F_dyn_char_bits=5'b00100; 3'd6:F_dyn_char_bits=5'b01110; default:F_dyn_char_bits=5'b00000; endcase end
                4'h2: begin case(I_row) 3'd0:F_dyn_char_bits=5'b01110; 3'd1:F_dyn_char_bits=5'b10001; 3'd2:F_dyn_char_bits=5'b00001; 3'd3:F_dyn_char_bits=5'b00110; 3'd4:F_dyn_char_bits=5'b01000; 3'd5:F_dyn_char_bits=5'b10000; 3'd6:F_dyn_char_bits=5'b11111; default:F_dyn_char_bits=5'b00000; endcase end
                4'h3: begin case(I_row) 3'd0:F_dyn_char_bits=5'b11110; 3'd1:F_dyn_char_bits=5'b00001; 3'd2:F_dyn_char_bits=5'b00001; 3'd3:F_dyn_char_bits=5'b01110; 3'd4:F_dyn_char_bits=5'b00001; 3'd5:F_dyn_char_bits=5'b00001; 3'd6:F_dyn_char_bits=5'b11110; default:F_dyn_char_bits=5'b00000; endcase end
                4'h4: begin case(I_row) 3'd0:F_dyn_char_bits=5'b00010; 3'd1:F_dyn_char_bits=5'b00110; 3'd2:F_dyn_char_bits=5'b01010; 3'd3:F_dyn_char_bits=5'b10010; 3'd4:F_dyn_char_bits=5'b11111; 3'd5:F_dyn_char_bits=5'b00010; 3'd6:F_dyn_char_bits=5'b00010; default:F_dyn_char_bits=5'b00000; endcase end
                4'h5: begin case(I_row) 3'd0:F_dyn_char_bits=5'b11111; 3'd1:F_dyn_char_bits=5'b10000; 3'd2:F_dyn_char_bits=5'b11110; 3'd3:F_dyn_char_bits=5'b00001; 3'd4:F_dyn_char_bits=5'b00001; 3'd5:F_dyn_char_bits=5'b10001; 3'd6:F_dyn_char_bits=5'b01110; default:F_dyn_char_bits=5'b00000; endcase end
                4'h6: begin case(I_row) 3'd0:F_dyn_char_bits=5'b00110; 3'd1:F_dyn_char_bits=5'b01000; 3'd2:F_dyn_char_bits=5'b10000; 3'd3:F_dyn_char_bits=5'b11110; 3'd4:F_dyn_char_bits=5'b10001; 3'd5:F_dyn_char_bits=5'b10001; 3'd6:F_dyn_char_bits=5'b01110; default:F_dyn_char_bits=5'b00000; endcase end
                4'h7: begin case(I_row) 3'd0:F_dyn_char_bits=5'b11111; 3'd1:F_dyn_char_bits=5'b00001; 3'd2:F_dyn_char_bits=5'b00010; 3'd3:F_dyn_char_bits=5'b00100; 3'd4:F_dyn_char_bits=5'b01000; 3'd5:F_dyn_char_bits=5'b01000; 3'd6:F_dyn_char_bits=5'b01000; default:F_dyn_char_bits=5'b00000; endcase end
                4'h8: begin case(I_row) 3'd0:F_dyn_char_bits=5'b01110; 3'd1:F_dyn_char_bits=5'b10001; 3'd2:F_dyn_char_bits=5'b10001; 3'd3:F_dyn_char_bits=5'b01110; 3'd4:F_dyn_char_bits=5'b10001; 3'd5:F_dyn_char_bits=5'b10001; 3'd6:F_dyn_char_bits=5'b01110; default:F_dyn_char_bits=5'b00000; endcase end
                4'h9: begin case(I_row) 3'd0:F_dyn_char_bits=5'b01110; 3'd1:F_dyn_char_bits=5'b10001; 3'd2:F_dyn_char_bits=5'b10001; 3'd3:F_dyn_char_bits=5'b01111; 3'd4:F_dyn_char_bits=5'b00001; 3'd5:F_dyn_char_bits=5'b00010; 3'd6:F_dyn_char_bits=5'b11100; default:F_dyn_char_bits=5'b00000; endcase end
                4'ha: begin case(I_row) 3'd0:F_dyn_char_bits=5'b01110; 3'd1:F_dyn_char_bits=5'b10001; 3'd2:F_dyn_char_bits=5'b10001; 3'd3:F_dyn_char_bits=5'b11111; 3'd4:F_dyn_char_bits=5'b10001; 3'd5:F_dyn_char_bits=5'b10001; 3'd6:F_dyn_char_bits=5'b10001; default:F_dyn_char_bits=5'b00000; endcase end
                4'hb: begin case(I_row) 3'd0:F_dyn_char_bits=5'b11110; 3'd1:F_dyn_char_bits=5'b10001; 3'd2:F_dyn_char_bits=5'b10001; 3'd3:F_dyn_char_bits=5'b11110; 3'd4:F_dyn_char_bits=5'b10001; 3'd5:F_dyn_char_bits=5'b10001; 3'd6:F_dyn_char_bits=5'b11110; default:F_dyn_char_bits=5'b00000; endcase end
                4'hc: begin case(I_row) 3'd0:F_dyn_char_bits=5'b01110; 3'd1:F_dyn_char_bits=5'b10001; 3'd2:F_dyn_char_bits=5'b10000; 3'd3:F_dyn_char_bits=5'b10000; 3'd4:F_dyn_char_bits=5'b10000; 3'd5:F_dyn_char_bits=5'b10001; 3'd6:F_dyn_char_bits=5'b01110; default:F_dyn_char_bits=5'b00000; endcase end
                4'hd: begin case(I_row) 3'd0:F_dyn_char_bits=5'b11110; 3'd1:F_dyn_char_bits=5'b10001; 3'd2:F_dyn_char_bits=5'b10001; 3'd3:F_dyn_char_bits=5'b10001; 3'd4:F_dyn_char_bits=5'b10001; 3'd5:F_dyn_char_bits=5'b10001; 3'd6:F_dyn_char_bits=5'b11110; default:F_dyn_char_bits=5'b00000; endcase end
                4'he: begin case(I_row) 3'd0:F_dyn_char_bits=5'b11111; 3'd1:F_dyn_char_bits=5'b10000; 3'd2:F_dyn_char_bits=5'b10000; 3'd3:F_dyn_char_bits=5'b11110; 3'd4:F_dyn_char_bits=5'b10000; 3'd5:F_dyn_char_bits=5'b10000; 3'd6:F_dyn_char_bits=5'b11111; default:F_dyn_char_bits=5'b00000; endcase end
                4'hf: begin case(I_row) 3'd0:F_dyn_char_bits=5'b11111; 3'd1:F_dyn_char_bits=5'b10000; 3'd2:F_dyn_char_bits=5'b10000; 3'd3:F_dyn_char_bits=5'b11110; 3'd4:F_dyn_char_bits=5'b10000; 3'd5:F_dyn_char_bits=5'b10000; 3'd6:F_dyn_char_bits=5'b10000; default:F_dyn_char_bits=5'b00000; endcase end
                default: F_dyn_char_bits = 5'b00000;
            endcase
        end
    endfunction

    // Unified prefix character library (16x16 rows): an/lu/C/N/T/:
    function [15:0] F_osd_char16_row;
        input [7:0] I_char;
        input [3:0] I_row;
        begin
            case(I_char)
                CHAR_AN: begin
                    case(I_row)
                        4'd0:  F_osd_char16_row = 16'h0200;
                        4'd1:  F_osd_char16_row = 16'h7ff0;
                        4'd2:  F_osd_char16_row = 16'h4410;
                        4'd3:  F_osd_char16_row = 16'h0400;
                        4'd4:  F_osd_char16_row = 16'h7ff0;
                        4'd5:  F_osd_char16_row = 16'h0840;
                        4'd6:  F_osd_char16_row = 16'h1040;
                        4'd7:  F_osd_char16_row = 16'h1c80;
                        4'd8:  F_osd_char16_row = 16'h0300;
                        4'd9:  F_osd_char16_row = 16'h0cc0;
                        4'd10: F_osd_char16_row = 16'h7020;
                        default: F_osd_char16_row = 16'h0000;
                    endcase
                end
                CHAR_LU: begin
                    case(I_row)
                        4'd0:  F_osd_char16_row = 16'h79e0;
                        4'd1:  F_osd_char16_row = 16'h4a20;
                        4'd2:  F_osd_char16_row = 16'h4d40;
                        4'd3:  F_osd_char16_row = 16'h7880;
                        4'd4:  F_osd_char16_row = 16'h1140;
                        4'd5:  F_osd_char16_row = 16'h1630;
                        4'd6:  F_osd_char16_row = 16'h5be0;
                        4'd7:  F_osd_char16_row = 16'h5220;
                        4'd8:  F_osd_char16_row = 16'h5220;
                        4'd9:  F_osd_char16_row = 16'h5be0;
                        4'd10: F_osd_char16_row = 16'h6220;
                        default: F_osd_char16_row = 16'h0000;
                    endcase
                end
                CHAR_C: begin
                    case(I_row)
                        4'd2:  F_osd_char16_row = 16'h03f0;
                        4'd3:  F_osd_char16_row = 16'h0c0c;
                        4'd4:  F_osd_char16_row = 16'h1800;
                        4'd5:  F_osd_char16_row = 16'h3000;
                        4'd6:  F_osd_char16_row = 16'h3000;
                        4'd7:  F_osd_char16_row = 16'h3000;
                        4'd8:  F_osd_char16_row = 16'h3000;
                        4'd9:  F_osd_char16_row = 16'h3000;
                        4'd10: F_osd_char16_row = 16'h1800;
                        4'd11: F_osd_char16_row = 16'h0c0c;
                        4'd12: F_osd_char16_row = 16'h03f0;
                        default: F_osd_char16_row = 16'h0000;
                    endcase
                end
                CHAR_N: begin
                    case(I_row)
                        4'd2:  F_osd_char16_row = 16'h300c;
                        4'd3:  F_osd_char16_row = 16'h380c;
                        4'd4:  F_osd_char16_row = 16'h3c0c;
                        4'd5:  F_osd_char16_row = 16'h360c;
                        4'd6:  F_osd_char16_row = 16'h330c;
                        4'd7:  F_osd_char16_row = 16'h318c;
                        4'd8:  F_osd_char16_row = 16'h30cc;
                        4'd9:  F_osd_char16_row = 16'h306c;
                        4'd10: F_osd_char16_row = 16'h303c;
                        4'd11: F_osd_char16_row = 16'h301c;
                        4'd12: F_osd_char16_row = 16'h300c;
                        default: F_osd_char16_row = 16'h0000;
                    endcase
                end
                CHAR_T: begin
                    case(I_row)
                        4'd2:  F_osd_char16_row = 16'h3ffc;
                        4'd3:  F_osd_char16_row = 16'h03c0;
                        4'd4:  F_osd_char16_row = 16'h03c0;
                        4'd5:  F_osd_char16_row = 16'h03c0;
                        4'd6:  F_osd_char16_row = 16'h03c0;
                        4'd7:  F_osd_char16_row = 16'h03c0;
                        4'd8:  F_osd_char16_row = 16'h03c0;
                        4'd9:  F_osd_char16_row = 16'h03c0;
                        4'd10: F_osd_char16_row = 16'h03c0;
                        4'd11: F_osd_char16_row = 16'h03c0;
                        4'd12: F_osd_char16_row = 16'h03c0;
                        default: F_osd_char16_row = 16'h0000;
                    endcase
                end
                CHAR_COLON: begin
                    case(I_row)
                        4'd6:  F_osd_char16_row = 16'h0180;
                        4'd7:  F_osd_char16_row = 16'h0180;
                        4'd10: F_osd_char16_row = 16'h0180;
                        4'd11: F_osd_char16_row = 16'h0180;
                        default: F_osd_char16_row = 16'h0000;
                    endcase
                end
                default: F_osd_char16_row = 16'h0000;
            endcase
        end
    endfunction

    assign O_video_rd_en = I_video_de;

    // The logo is 160 pixels wide: y*160 = y*128 + y*32. Express
    // the constant stride with wiring/addition so it needs no multiplier DSP.
    wire [14:0] S_logo_relative_x=S_logo_input_x-LOGO_X;
    wire [14:0] S_logo_relative_y=S_logo_input_y-LOGO_Y;
    wire [14:0] S_logo_row_offset=(S_logo_relative_y<<7)+(S_logo_relative_y<<5);
    assign S_logo_addr =
        (I_video_de &&
         (S_logo_input_x >= LOGO_X) && (S_logo_input_x < LOGO_X + LOGO_W) &&
         (S_logo_input_y >= LOGO_Y) && (S_logo_input_y < LOGO_Y + LOGO_H)) ?
        S_logo_row_offset+S_logo_relative_x :
        15'd0;

    // Exact 24-to-16 glyph scaling: floor(16*x/24), for x in 0..23.
    // A small coordinate map avoids wide constant dividers in the pixel path.
    function [3:0] F_scale24_to16;
        input [4:0] coordinate;
        begin
            case (coordinate)
                5'd0, 5'd1:   F_scale24_to16 = 4'd0;
                5'd2:         F_scale24_to16 = 4'd1;
                5'd3, 5'd4:   F_scale24_to16 = 4'd2;
                5'd5:         F_scale24_to16 = 4'd3;
                5'd6, 5'd7:   F_scale24_to16 = 4'd4;
                5'd8:         F_scale24_to16 = 4'd5;
                5'd9, 5'd10:  F_scale24_to16 = 4'd6;
                5'd11:        F_scale24_to16 = 4'd7;
                5'd12, 5'd13: F_scale24_to16 = 4'd8;
                5'd14:        F_scale24_to16 = 4'd9;
                5'd15, 5'd16: F_scale24_to16 = 4'd10;
                5'd17:        F_scale24_to16 = 4'd11;
                5'd18, 5'd19: F_scale24_to16 = 4'd12;
                5'd20:        F_scale24_to16 = 4'd13;
                5'd21, 5'd22: F_scale24_to16 = 4'd14;
                5'd23:        F_scale24_to16 = 4'd15;
                default:      F_scale24_to16 = 4'd0;
            endcase
        end
    endfunction

    anlogic_logo_rom u_anlogic_logo_rom(
        .I_clk   ( I_clk        ),
        .I_addr  ( S_logo_addr  ),
        .O_pixel ( S_logo_pixel )
    );

    osd_char_lib u_osd_char_lib(
        .I_char     ( S_pf_char     ),
        .I_row      ( S_pf_row      ),
        .O_row_bits ( S_pf_row_bits )
    );

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_x <= 12'd0;
            S_y <= 12'd0;
        end
        else if(I_video_user) begin
            // USER coincides with pixel (0,0) in the supplied VTC. Count
            // that beat now; otherwise pixel (1,0) repeats x=0 and the last
            // column never reaches IMG_WIDTH-1 in following frames.
            S_x <= I_video_de && !I_video_last ? 12'd1 : 12'd0;
            S_y <= I_video_de && I_video_last ? 12'd1 : 12'd0;
        end
        else if(I_video_de) begin
            if(I_video_last) begin
                S_x <= 12'd0;
                S_y <= S_y + 12'd1;
            end
            else begin
                S_x <= S_x + 12'd1;
            end
        end
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_frame_cnt <= 32'd0;
            S_cnt_d0 <= 4'd0;
            S_cnt_d1 <= 4'd0;
            S_cnt_d2 <= 4'd0;
            S_cnt_d3 <= 4'd0;
            S_cnt_d4 <= 4'd0;
            S_cnt_d5 <= 4'd0;
        end
        else if(I_video_user) begin
            S_frame_cnt <= S_frame_cnt + 32'd1;
            if(S_cnt_d0 == 4'd9) begin
                S_cnt_d0 <= 4'd0;
                if(S_cnt_d1 == 4'd9) begin
                    S_cnt_d1 <= 4'd0;
                    if(S_cnt_d2 == 4'd9) begin
                        S_cnt_d2 <= 4'd0;
                        if(S_cnt_d3 == 4'd9) begin
                            S_cnt_d3 <= 4'd0;
                            if(S_cnt_d4 == 4'd9) begin
                                S_cnt_d4 <= 4'd0;
                                if(S_cnt_d5 == 4'd9)
                                    S_cnt_d5 <= 4'd0;
                                else
                                    S_cnt_d5 <= S_cnt_d5 + 4'd1;
                            end
                            else
                                S_cnt_d4 <= S_cnt_d4 + 4'd1;
                        end
                        else
                            S_cnt_d3 <= S_cnt_d3 + 4'd1;
                    end
                    else
                        S_cnt_d2 <= S_cnt_d2 + 4'd1;
                end
                else
                    S_cnt_d1 <= S_cnt_d1 + 4'd1;
            end
            else
                S_cnt_d0 <= S_cnt_d0 + 4'd1;
        end
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_x_1d <= 12'd0;
            S_x_2d <= 12'd0;
            S_y_1d <= 12'd0;
            S_y_2d <= 12'd0;
            S_cnn_runtime_row_2d <= 1'b0;
        end
        else begin
            S_x_1d <= I_video_user ? 12'd0 : S_x;
            S_x_2d <= S_x_1d;
            S_y_1d <= I_video_user ? 12'd0 : S_y;
            S_y_2d <= S_y_1d;
            // This predicate describes the same pixel as S_y_2d. Moving
            // its comparison into stage one adds no video/output delay.
            S_cnn_runtime_row_2d <= S_y_1d >= CNN_TEXT_Y+16;
        end
    end

    // Decode the original counter glyph during the existing first pixel
    // stage. The character lookup then has a full cycle at stage two.
    always @(*) begin
        S_dyn_x = 12'd0;
        S_dyn_y = 12'd0;
        S_dyn_digit_idx = 4'd0;
        S_dyn_digit_x = 12'd0;
        S_dyn_dec_digit = 4'd0;
        S_pf_local_x = 5'd0;
        S_pf_local_y = 5'd0;
        S_pf_next_char = 8'd0;
        S_pf_next_col = 4'd0;
        S_pf_next_row = 4'd0;
        S_pf_next_valid = 1'b0;
        if (S_video_de_1d &&
            S_x_1d >= DYN_OSD_X && S_x_1d < DYN_OSD_X+DYN_OSD_W &&
            S_y_1d >= DYN_OSD_Y && S_y_1d < DYN_OSD_Y+DYN_OSD_H) begin
            S_dyn_x = S_x_1d-DYN_OSD_X;
            S_dyn_y = S_y_1d-DYN_OSD_Y;
            if (S_dyn_x < 48 && S_dyn_y >= CN_Y_OFFSET) begin
                S_pf_next_char = S_dyn_x < 24 ? CHAR_AN : CHAR_LU;
                S_pf_local_x = S_dyn_x < 24 ? S_dyn_x : S_dyn_x-12'd24;
                S_pf_local_y = S_dyn_y-CN_Y_OFFSET;
                S_pf_next_col = F_scale24_to16(S_pf_local_x);
                S_pf_next_row = F_scale24_to16(S_pf_local_y);
                S_pf_next_valid = 1'b1;
            end else if (S_dyn_x >= 52 && S_dyn_x < 100 &&
                         S_dyn_y >= 4 && S_dyn_y < 20) begin
                if (S_dyn_x < 68) begin
                    S_pf_next_char = CHAR_C;
                    S_pf_local_x = S_dyn_x-12'd52;
                end else if (S_dyn_x < 84) begin
                    S_pf_next_char = CHAR_N;
                    S_pf_local_x = S_dyn_x-12'd68;
                end else begin
                    S_pf_next_char = CHAR_T;
                    S_pf_local_x = S_dyn_x-12'd84;
                end
                S_pf_local_y = S_dyn_y-12'd4;
                S_pf_next_col = S_pf_local_x[3:0];
                S_pf_next_row = S_pf_local_y[3:0];
                S_pf_next_valid = 1'b1;
            end else if (S_dyn_x >= 100 && S_dyn_x < 108 &&
                         S_dyn_y >= 4 && S_dyn_y < 20) begin
                S_pf_next_char = CHAR_COLON;
                S_pf_local_x = S_dyn_x-12'd100;
                S_pf_local_y = S_dyn_y-12'd4;
                S_pf_next_col = {S_pf_local_x[2:0],1'b0};
                S_pf_next_row = S_pf_local_y[3:0];
                S_pf_next_valid = 1'b1;
            end else if (S_dyn_x >= 110) begin
                if (S_dyn_x < 125) begin
                    S_dyn_digit_x = S_dyn_x-12'd110;
                    S_dyn_dec_digit = S_cnt_d5;
                end else if (S_dyn_x < 140) begin
                    S_dyn_digit_x = S_dyn_x-12'd125;
                    S_dyn_dec_digit = S_cnt_d4;
                end else if (S_dyn_x < 155) begin
                    S_dyn_digit_x = S_dyn_x-12'd140;
                    S_dyn_dec_digit = S_cnt_d3;
                end else if (S_dyn_x < 170) begin
                    S_dyn_digit_x = S_dyn_x-12'd155;
                    S_dyn_dec_digit = S_cnt_d2;
                end else if (S_dyn_x < 185) begin
                    S_dyn_digit_x = S_dyn_x-12'd170;
                    S_dyn_dec_digit = S_cnt_d1;
                end else begin
                    S_dyn_digit_x = S_dyn_x-12'd185;
                    S_dyn_dec_digit = S_cnt_d0;
                end
                S_pf_next_char = CHAR_0+{4'd0,S_dyn_dec_digit};
                S_pf_next_col = S_dyn_digit_x[3:0];
                S_pf_next_row = F_scale24_to16(S_dyn_y[4:0]);
                S_pf_next_valid = 1'b1;
            end
        end
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            S_pf_char <= 8'd0;
            S_pf_col <= 4'd0;
            S_pf_row <= 4'd0;
            S_pf_valid <= 1'b0;
        end else begin
            S_pf_char <= S_pf_next_char;
            S_pf_col <= S_pf_next_col;
            S_pf_row <= S_pf_next_row;
            S_pf_valid <= S_pf_next_valid;
        end
    end

    always @(*) begin
        S_pf_on = S_pf_valid && S_pf_row_bits[15-S_pf_col];
        S_osd_hit = 1'b0;
        S_osd_color = 24'd0;
        if (S_video_de_2d) begin
            if (S_x_2d >= LOGO_X && S_x_2d < LOGO_X+LOGO_W &&
                S_y_2d >= LOGO_Y && S_y_2d < LOGO_Y+LOGO_H &&
                S_logo_pixel[24]) begin
                S_osd_hit = 1'b1;
                S_osd_color = S_logo_pixel[23:0];
            end else if (S_pf_on) begin
                S_osd_hit = 1'b1;
                S_osd_color = COLOR_DYN_TEXT;
            end
        end
    end

    // Put the pixel context on the same boundary as the synchronous font
    // read. The last selection uses only that registered context and the ROM
    // output, preserving the original RGB/control output cycle.
    reg [23:0] S_rgb_next;
    reg [23:0] S_font_color_next;
    reg S_font_valid_next;
    reg [23:0] S_output_base;
    reg [23:0] S_output_font_color;
    reg S_output_font_valid;
    reg [3:0] S_output_font_col;

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_video_vsync_1d <= 1'b0;
            S_video_vsync_2d <= 1'b0;
            S_video_hsync_1d <= 1'b0;
            S_video_hsync_2d <= 1'b0;
            S_video_de_1d    <= 1'b0;
            S_video_de_2d    <= 1'b0;
            O_hdmi_vsync     <= 1'b0;
            O_hdmi_hsync     <= 1'b0;
            O_hdmi_de        <= 1'b0;
            S_output_base       <= 24'd0;
            S_output_font_color <= 24'd0;
            S_output_font_valid <= 1'b0;
            S_output_font_col   <= 4'd0;
        end
        else begin
            S_video_vsync_1d <= I_video_vsync;
            S_video_vsync_2d <= S_video_vsync_1d;
            O_hdmi_vsync     <= S_video_vsync_2d;

            S_video_hsync_1d <= I_video_hsync;
            S_video_hsync_2d <= S_video_hsync_1d;
            O_hdmi_hsync     <= S_video_hsync_2d;

            S_video_de_1d    <= I_video_de;
            S_video_de_2d    <= S_video_de_1d;
            O_hdmi_de        <= S_video_de_2d;

            S_output_base       <= S_rgb_next;
            S_output_font_color <= S_font_color_next;
            S_output_font_valid <= S_font_valid_next;
            S_output_font_col   <= S_font_col;
        end
    end

    always @(*) begin
        S_rgb_next = S_video_data_2d;
        S_font_color_next = 24'd0;
        S_font_valid_next = 1'b0;
        if(DEBUG_MODE == 1) begin
            if(S_video_de_2d) begin
                if(S_x < 12'd128)
                    S_rgb_next = 24'hff0000;
                else if(S_x < 12'd256)
                    S_rgb_next = 24'h00ff00;
                else if(S_x < 12'd384)
                    S_rgb_next = 24'h0000ff;
                else if(S_x < 12'd512)
                    S_rgb_next = 24'hffff00;
                else if(S_x < 12'd640)
                    S_rgb_next = 24'h00ffff;
                else if(S_x < 12'd768)
                    S_rgb_next = 24'hff00ff;
                else if(S_x < 12'd896)
                    S_rgb_next = 24'hffffff;
                else
                    S_rgb_next = 24'h202020;
            end else begin
                S_rgb_next = 24'd0;
            end
        end else if(DEBUG_MODE == 2) begin
            if(S_video_de_2d) begin
                case (I_debug_status)
                    4'b0000: S_rgb_next = 24'h000000;
                    4'b0001: S_rgb_next = 24'hff0000;
                    4'b0011: S_rgb_next = 24'hffff00;
                    4'b0111: S_rgb_next = 24'h00ff00;
                    4'b1111: S_rgb_next = I_video_rd_data;
                    default: S_rgb_next = 24'h0000ff;
                endcase
            end else begin
                S_rgb_next = 24'd0;
            end
        end else if(DEBUG_MODE == 3) begin
            if(S_video_de_2d) begin
                if(S_x < 12'd256)
                    S_rgb_next = I_debug_status[0] ? 24'hff8000 : 24'h201000;
                else if(S_x < 12'd512)
                    S_rgb_next = I_debug_status[1] ? 24'hffff00 : 24'h202000;
                else if(S_x < 12'd768)
                    S_rgb_next = I_debug_status[2] ? 24'hff0000 : 24'h200000;
                else
                    S_rgb_next = I_debug_status[3] ? 24'h00ffff : 24'h002020;
            end else begin
                S_rgb_next = 24'd0;
            end
        end else begin
            // Four 16x16 status blocks at (192,16), with 8-pixel gaps.
            // Keep the existing priority over the opaque font panels.
            if(SHOW_CAMERA_STATUS && S_video_de_2d &&
               (S_y_2d >= 12'd16) && (S_y_2d < 12'd32) &&
               (S_x_2d >= 12'd192) && (S_x_2d < 12'd208))
                S_rgb_next = I_debug_status[0] ? 24'h00ff00 : 24'hff0000;
            else if(SHOW_CAMERA_STATUS && S_video_de_2d &&
                    (S_y_2d >= 12'd16) && (S_y_2d < 12'd32) &&
                    (S_x_2d >= 12'd216) && (S_x_2d < 12'd232))
                S_rgb_next = I_debug_status[1] ? 24'h00ff00 : 24'hff0000;
            else if(SHOW_CAMERA_STATUS && S_video_de_2d &&
                    (S_y_2d >= 12'd16) && (S_y_2d < 12'd32) &&
                    (S_x_2d >= 12'd240) && (S_x_2d < 12'd256))
                S_rgb_next = I_debug_status[2] ? 24'h00ff00 : 24'hff0000;
            else if(SHOW_CAMERA_STATUS && S_video_de_2d &&
                    (S_y_2d >= 12'd16) && (S_y_2d < 12'd32) &&
                    (S_x_2d >= 12'd264) && (S_x_2d < 12'd280))
                S_rgb_next = I_debug_status[3] ? 24'h00ff00 : 24'hff0000;
            else if(SHOW_CAMERA_STATUS && S_video_de_2d &&
                    I_debug_status[0] && !I_debug_status[3] &&
                    (S_y_2d >= 12'd40) && (S_y_2d < 12'd64) &&
                    (S_x_2d >= 12'd216) && (S_x_2d < 12'd232))
                S_rgb_next = F_fail_digit_on(I_cam_fail_index[7:4],
                    S_x_2d - 12'd216, S_y_2d - 12'd40) ? 24'hfff200 : 24'h101010;
            else if(SHOW_CAMERA_STATUS && S_video_de_2d &&
                    I_debug_status[0] && !I_debug_status[3] &&
                    (S_y_2d >= 12'd40) && (S_y_2d < 12'd64) &&
                    (S_x_2d >= 12'd240) && (S_x_2d < 12'd256))
                S_rgb_next = F_fail_digit_on(I_cam_fail_index[3:0],
                    S_x_2d - 12'd240, S_y_2d - 12'd40) ? 24'hfff200 : 24'h101010;
            else if(S_effect_panel_on) begin
                S_rgb_next = 24'h101010;
                S_font_valid_next = 1'b1;
                S_font_color_next = 24'h00e6ff;
            end else if(S_latency_panel)
                S_rgb_next = S_latency_text ?
                    (S_latency_alert ? 24'hffb040 : 24'hffffff) : 24'h101418;
            else if(S_fruit_panel_bg_on) begin
                S_rgb_next = S_fruit_frame_on ? S_fruit_color : 24'h101418;
                if(S_cnn_panel_on) begin
                    S_font_valid_next = 1'b1;
                    S_font_color_next = S_fruit_name_text_on ? S_fruit_color :
                        ((S_fruit_header_on || S_fruit_value_text_on) ? 24'hffffff : 24'ha8b3bb);
                end
            end else if(S_cnn_panel_on) begin
                S_rgb_next = 24'h101010;
                S_font_valid_next = 1'b1;
                S_font_color_next = 24'h40ff80;
            end else if(S_raw_panel)
                S_rgb_next = S_raw_text ? (S_raw_alert ? 24'hffb040 : 24'hffffff) : 24'h101010;
            else if(S_osd_hit)
                S_rgb_next = S_osd_color;
            else if(S_target_panel_on) begin
                S_rgb_next = 24'h101010;
                S_font_valid_next = 1'b1;
                S_font_color_next = 24'hfff200;
            end else if(SHOW_COLOR_TARGET && !S_cnn_visible && S_follow_panel_on) begin
                S_rgb_next = 24'h101010;
                S_font_valid_next = 1'b1;
                S_font_color_next = S_follow_color;
            end else if(SHOW_COLOR_TARGET && !S_cnn_visible && S_multi_box_on)
                S_rgb_next = S_multi_box_color;
            else if((MULTI_TARGET_ENABLE == 0) &&
                    SHOW_COLOR_TARGET && !S_cnn_visible && S_video_de_2d && S_target_box_on)
                S_rgb_next = 24'hff3030;
            else if(((MULTI_TARGET_ENABLE == 0) ||
                    (S_target_motion_mode && S_multi_count != 0)) &&
                    SHOW_COLOR_TARGET && !S_cnn_visible && S_video_de_2d && S_target_cross_on)
                S_rgb_next = 24'hfff200;
            else if(S_cnn_roi_on)
                S_rgb_next = S_fruit_showcase ? S_fruit_color : 24'h40ff80;
        end
    end

    always @(*) begin
        O_hdmi_data = S_output_base;
        if (S_output_font_valid && S_target_char_bits[15-S_output_font_col])
            O_hdmi_data = S_output_font_color;
    end

endmodule
