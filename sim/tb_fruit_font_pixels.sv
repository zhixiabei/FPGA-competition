`timescale 1ns/1ps

// Production fruit panel: exercise the real input-to-output pixel pipeline.
// Only the input coordinate counters are injected to skip camera pixels.
// The oracle owns the strings, numeric formatting, layout and scale factors;
// it gets bitmap rows from the separately checked combinational font library.
module tb_fruit_font_pixels;
    localparam integer W=1280, H=720, PANEL_X=960, PANEL_W=320;
    localparam integer PANEL_PIXELS=PANEL_W*H;
    localparam integer ROI_LEFT=240, ROI_TOP=120, ROI_RIGHT=719, ROI_BOTTOM=599;
    localparam integer ROI_WIDTH=ROI_RIGHT-ROI_LEFT+1, ROI_HEIGHT=ROI_BOTTOM-ROI_TOP+1;
    localparam integer ROI_OUTLINE_PIXELS=ROI_WIDTH*ROI_HEIGHT-(ROI_WIDTH-4)*(ROI_HEIGHT-4);
    // The unchanged 200px-wide legacy counter covers the top 2px border.
    localparam integer ROI_VISIBLE_PER_CLASS=ROI_OUTLINE_PIXELS-200*2;
    localparam integer ROI_PREVIEW_LEFT=ROI_LEFT-4, ROI_PREVIEW_TOP=ROI_TOP-4;
    localparam integer ROI_PREVIEW_W=ROI_WIDTH+8, ROI_PREVIEW_H=ROI_HEIGHT+8;
    localparam [47:0] FRUIT_ROI={12'd599,12'd120,12'd719,12'd240};
    localparam [47:0] ALTERNATE_ROI={12'd575,12'd144,12'd695,12'd264};
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, de=0, user=0, last=0, hs=0, vs=0;
    reg [23:0] rgb=0;
    reg [3:0] effect_mode=0;
    reg latency_strobe=0;
    reg [1:0] detection_mode=0, expected_detection_mode=0;
    reg target_found=1, expected_target_found=1;
    reg [1:0] target_shape=1, expected_target_shape=1;
    reg cnn_enable=0, cnn_valid=0;
    reg [2:0] cnn_class=1;
    reg hand_box_valid=1, expected_box_valid=1;
    reg [47:0] hand_box=FRUIT_ROI, expected_box=FRUIT_ROI;
    reg [15:0] weight_bcd=0, price_bcd=0;
    reg weight_valid=0, price_valid=0;
    reg [11:0] injected_x=0, injected_y=0;
    reg sample_verify=0, sample_capture=0, sample_full=0;
    reg panel_enabled=0;
    integer selected_class=1;
    wire [23:0] got;
    wire got_de, got_hs, got_vs, got_rd, got_sof;

    hdmi_mixer #(
        .IMG_WIDTH(W), .IMG_HEIGHT(H), .SHOW_CNN(1),
        .FRUIT_CNN(1), .SHOW_RESNET_PROBE(0), .SHOW_RESNET_RUNTIME(0),
        .HANDCNN_DYNAMIC_ROI(1), .CNN_RESULT_TIMEOUT_FRAMES(0),
        .SHOW_LATENCY(1), .LATENCY_SWITCH_ENABLE(1), .SHOW_EFFECT_LABEL(1),
        .SHOW_COLOR_TARGET(1), .MULTI_TARGET_ENABLE(1), .TARGET_SLOTS(1)
    ) dut (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_video_vsync(vs), .I_video_hsync(hs), .I_video_de(de),
        .I_video_user(user), .I_video_last(last),
        .I_effect_mode(effect_mode), .I_effect_param(8'd0),
        .I_debug_status(4'hf), .I_cam_fail_index(8'd0),
        .I_latency_sample_strobe(latency_strobe), .I_latency_show(1'b1),
        .I_latency_sample_valid(1'b1), .I_latency_total_us(20'd24123),
        .I_latency_isp_us(20'd1750), .I_latency_buffer_us(20'd22373),
        .I_cnn_enable(cnn_enable), .I_cnn_result_valid(cnn_valid),
        .I_cnn_class(cnn_class),
        .I_checkout_weight_bcd(weight_bcd), .I_checkout_price_bcd(price_bcd),
        .I_checkout_weight_valid(weight_valid),
        .I_checkout_price_valid(price_valid),
        .I_hand_box_valid(hand_box_valid), .I_hand_box(hand_box),
        .I_resnet_probe_status(32'd0), .I_video_rd_data(rgb),
        .I_target_result_ready(1'b1), .I_target_found(target_found),
        .I_target_motion_mode(detection_mode==3), .I_target_color_mode(detection_mode),
        .I_target_xmin(12'd550), .I_target_xmax(12'd650),
        .I_target_ymin(12'd300), .I_target_ymax(12'd400),
        .I_target_center_x(12'd600), .I_target_center_y(12'd350),
        .I_target_multi_valid({3'd0,target_found}), .I_target_multi_hold(4'd0),
        .I_target_multi_boxes({144'd0,12'd400,12'd300,12'd650,12'd550}),
        .I_target_multi_shapes({6'd0,target_shape}),
        .I_target_multi_overflow(1'b0),
        .O_hdmi_data(got), .O_hdmi_de(got_de),
        .O_hdmi_hsync(got_hs), .O_hdmi_vsync(got_vs),
        .O_video_rd_en(got_rd), .O_display_frame_start(got_sof)
    );

    reg [7:0] oracle_char=0;
    reg [3:0] oracle_row=0;
    wire [15:0] oracle_bits;
    reg [15:0] glyphs [0:4095];
    osd_char_lib oracle_font (
        .I_char(oracle_char), .I_row(oracle_row), .O_row_bits(oracle_bits)
    );

    function automatic integer gamma_channel(input integer value);
        integer x0,x1,y0,y1;
        begin
            // Independent interpolation of the documented gamma anchors.
            if(value<16) begin x0=0;x1=16;y0=0;y1=23;end
            else if(value<32) begin x0=16;x1=32;y0=23;y1=44;end
            else if(value<64) begin x0=32;x1=64;y0=44;y1=80;end
            else if(value<96) begin x0=64;x1=96;y0=80;y1=104;end
            else if(value<128) begin x0=96;x1=128;y0=104;y1=128;end
            else if(value<160) begin x0=128;x1=160;y0=128;y1=152;end
            else if(value<192) begin x0=160;x1=192;y0=152;y1=180;end
            else if(value<224) begin x0=192;x1=224;y0=180;y1=210;end
            else if(value<240) begin x0=224;x1=240;y0=210;y1=232;end
            else begin x0=240;x1=255;y0=232;y1=255;end
            gamma_channel=y0+((value-x0)*(y1-y0)+(x1-x0)/2)/(x1-x0);
        end
    endfunction

    function automatic [23:0] corrected_pixel(input [23:0] pixel);
        begin
            corrected_pixel={8'(gamma_channel(pixel[23:16])),
                8'(gamma_channel(pixel[15:8])),
                8'(gamma_channel(pixel[7:0]))};
        end
    endfunction

    function automatic [23:0] fruit_color(input integer id);
        begin
            case(id)
                2: fruit_color=24'hff4058;
                3: fruit_color=24'hffd43b;
                4: fruit_color=24'hb080ff;
                5: fruit_color=24'hff8a30;
                6: fruit_color=24'hff4068;
                default: fruit_color=24'hffc040;
            endcase
        end
    endfunction

    function automatic [7:0] decimal_char(input [3:0] digit);
        begin decimal_char=digit<10 ? "0"+digit : "-";end
    endfunction

    // The expected frame owns its geometry; mid-frame input changes never
    // modify these bounds. Inclusive endpoints describe exactly 480x480.
    function automatic bit roi_outline(input integer x,y);
        integer left,top,right,bottom;
        begin
            left=expected_box[11:0];right=expected_box[23:12];
            top=expected_box[35:24];bottom=expected_box[47:36];
            roi_outline=x>=left && x<=right && y>=top && y<=bottom &&
                (x-left<2 || right-x<2 || y-top<2 || bottom-y<2);
        end
    endfunction

    function automatic bit legacy_counter_area(input integer x,y);
        begin
            // The original counter has higher priority than the fruit ROI.
            // Its font is covered separately; preserve it in real previews.
            legacy_counter_area=x>=375 && x<575 && y>=120 && y<144;
        end
    endfunction

    // Independent strings for the sidebar and the enlarged lower readouts.
    // Only the removed status and footer remain blank.
    function automatic [7:0] text_character(input integer region,index,id);
        reg [135:0] header;
        reg [15:0] chinese;
        reg [79:0] english;
        reg [47:0] weight_label;
        reg [39:0] total_label;
        reg [127:0] latency_line;
        reg [95:0] effect_name;
        reg [119:0] detection_line;
        reg [23:0] detection_prefix, shape_name;
        reg [95:0] follow_color_line;
        reg [63:0] follow_motion_line;
        begin
            header="FRUIT RECOGNITION";
            case(id)
                2: begin chinese=16'h8283;english="  APPLE   ";end
                3: begin chinese=16'h8485;english="  BANANA  ";end
                4: begin chinese=16'h8687;english="  GRAPE   ";end
                5: begin chinese=16'h8889;english="  ORANGE  ";end
                6: begin chinese=16'h8a8b;english="STRAWBERRY";end
                default: begin chinese=16'h2d2d;english=" UNKNOWN  ";end
            endcase
            case(region)
                10: latency_line="TOT:024.123MS";
                11: latency_line="ISP:001.750MS";
                default: latency_line="BUF:022.373MS";
            endcase
            case(expected_detection_mode)
                0: detection_prefix="RED";
                1: detection_prefix="GRN";
                2: detection_prefix="BLU";
                default: detection_prefix="MOV";
            endcase
            case(expected_target_shape)
                1: shape_name="SQR";
                2: shape_name="TRI";
                3: shape_name="CIR";
                default: shape_name="UNK";
            endcase
            if(!expected_target_found)
                detection_line={detection_prefix,":NONE       "};
            else if(expected_detection_mode==3)
                detection_line={detection_prefix,":FOUND      "};
            else
                detection_line={detection_prefix,":FOUND ",shape_name,"  "};
            follow_color_line={"1 ",detection_prefix," ",shape_name," OK"};
            follow_motion_line="1 MOV OK";
            case(effect_mode)
                0: effect_name="COLOR GAMMA ";
                1: effect_name="GRAYSCALE   ";
                2: effect_name="SCHARR EDGE ";
                3: effect_name="NEGATIVE    ";
                4: effect_name="EMBOSS      ";
                5: effect_name="COLOR KEEP  ";
                6: effect_name="CARTOON     ";
                7: effect_name="SCHARR INV  ";
                8: effect_name="MORPH EDGE  ";
                9: effect_name="BINARY      ";
                10: effect_name="EROSION     ";
                11: effect_name="DILATION    ";
                12: effect_name="CLOSE MASK  ";
                default: effect_name="COLOR GAMMA ";
            endcase
            weight_label="WEIGHT";total_label="TOTAL";
            text_character=" ";
            case(region)
                1: text_character=header[135-8*index -: 8];
                3: text_character=chinese[15-8*index -: 8];
                4: text_character=english[79-8*index -: 8];
                5: text_character=weight_label[47-8*index -: 8];
                6: case(index)
                    0: text_character=!weight_valid ? "-" : decimal_char(weight_bcd[15:12]);
                    1: text_character=".";
                    2: text_character=!weight_valid ? "-" : decimal_char(weight_bcd[11:8]);
                    3: text_character=!weight_valid ? "-" : decimal_char(weight_bcd[7:4]);
                    4: text_character=!weight_valid ? "-" : decimal_char(weight_bcd[3:0]);
                    6: text_character="k";
                    7: text_character="g";
                    default: text_character=" ";
                endcase
                7: text_character=total_label[39-8*index -: 8];
                8: case(index)
                    0: text_character=!price_valid ? "-" :
                        price_bcd[15:12]==0 ? " " : decimal_char(price_bcd[15:12]);
                    1: text_character=!price_valid ? "-" : decimal_char(price_bcd[11:8]);
                    2: text_character=".";
                    3: text_character=!price_valid ? "-" : decimal_char(price_bcd[7:4]);
                    4: text_character=!price_valid ? "-" : decimal_char(price_bcd[3:0]);
                    6: text_character="R";
                    7: text_character="M";
                    8: text_character="B";
                    default: text_character=" ";
                endcase
                10,11,12: text_character=latency_line[103-8*index -: 8];
                13: begin
                    if(index==0) text_character="0"+effect_mode/10;
                    else if(index==1) text_character="0"+effect_mode%10;
                    else if(index>=3 && index<15)
                        text_character=effect_name[95-8*(index-3) -: 8];
                end
                14: text_character=detection_line[119-8*index -: 8];
                15: text_character=expected_detection_mode==3 ?
                    follow_motion_line[63-8*index -: 8] :
                    follow_color_line[95-8*index -: 8];
                default: text_character=" ";
            endcase
        end
    endfunction

    task automatic render_sample(
        input integer x,y,
        input [23:0] camera_pixel,
        output reg [23:0] expected,
        output integer region,
        output reg [7:0] character,
        output integer glyph_row,glyph_col,
        output reg ink
    );
        integer left,top,scale,index;
        reg [23:0] foreground;
        begin
            expected=corrected_pixel(camera_pixel);
            region=0;character=" ";glyph_row=0;glyph_col=0;ink=0;
            left=0;top=0;scale=1;index=0;foreground=24'ha8b3bb;
            if(panel_enabled && expected_box_valid && roi_outline(x,y))
                expected=fruit_color(selected_class);
            if(panel_enabled && x>=PANEL_X) begin
                expected=24'h101418;
                if(y<576 &&
                    (x<PANEL_X+4 || x>=W-4 || y<4 ||
                     (y>=104 && y<108) || (y>=376 && y<380) ||
                     (y>=472 && y<476) || (y>=572 && y<576)))
                    expected=fruit_color(selected_class);
                if(x>=984 && x<1256 && y>=64 && y<80) begin
                    region=1;left=984;top=64;foreground=24'hffffff;
                end else if(x>=1056 && x<1184 && y>=216 && y<280) begin
                    region=3;left=1056;top=216;scale=4;
                    foreground=fruit_color(selected_class);
                end else if(x>=960 && x<1280 && y>=328 && y<360) begin
                    region=4;left=960;top=328;scale=2;
                    foreground=fruit_color(selected_class);
                end else if(x>=1024 && x<1120 && y>=392 && y<408) begin
                    region=5;left=1024;top=392;
                end else if(x>=992 && x<1248 && y>=424 && y<456) begin
                    region=6;left=992;top=424;scale=2;foreground=24'hffffff;
                end else if(x>=1024 && x<1104 && y>=488 && y<504) begin
                    region=7;left=1024;top=488;
                end else if(x>=976 && x<1264 && y>=520 && y<552) begin
                    region=8;left=976;top=520;scale=2;foreground=24'hffffff;
                end
                if(region!=0) begin
                    index=(x-left)/(16*scale);
                    glyph_col=((x-left)/scale)%16;
                    glyph_row=(y-top)/scale;
                    character=text_character(region,index,selected_class);
                    ink=glyphs[16*character+glyph_row][15-glyph_col];
                    if(ink) expected=foreground;
                end
            end
            // The fixed test target's existing follow label is directly
            // above its box. Its background crosses the square's right edge
            // only while the CNN view is disabled.
            if(!panel_enabled && expected_target_found &&
                x>=550 && x<(expected_detection_mode==3 ? 678 : 742) &&
                y>=282 && y<298) begin
                expected=24'h101010;region=15;
                index=(x-550)/16;
                glyph_col=(x-550)%16;
                glyph_row=y-282;
                character=text_character(region,index,selected_class);
                ink=glyphs[16*character+glyph_row][15-glyph_col];
                if(ink) expected=24'hff3030;
            end
            // This is the real 1280x720 configuration, with both diagnostics
            // enabled at once. The oracle uses literal requested geometry.
            if(x>=960 && x<1280 && y>=592 && y<704) begin
                expected=24'h101418;
                if(x>=964 && x<1276 && y>=600 && y<696) begin
                    region=10+(y-600)/32;
                    index=(x-964)/24;
                    glyph_col=2+((x-964)/2)%12;
                    glyph_row=((y-600)/2)%16;
                    character=text_character(region,index,selected_class);
                    ink=glyphs[16*character+glyph_row][15-glyph_col];
                    if(ink) expected=24'hffffff;
                end
            end else if(x>=16 && x<376 && y>=672 && y<704) begin
                expected=24'h101010;region=13;
                index=(x-16)/24;
                glyph_col=2+((x-16)/2)%12;
                glyph_row=(y-672)/2;
                character=text_character(region,index,selected_class);
                ink=glyphs[16*character+glyph_row][15-glyph_col];
                if(ink) expected=24'h00e6ff;
            end else if(x>=16 && x<376 && y>=632 && y<664) begin
                expected=24'h101010;region=14;
                index=(x-16)/24;
                glyph_col=2+((x-16)/2)%12;
                glyph_row=(y-632)/2;
                character=text_character(region,index,selected_class);
                ink=glyphs[16*character+glyph_row][15-glyph_col];
                if(ink) expected=24'hfff200;
            end
        end
    endtask

    reg pipe_de [0:2],pipe_hs [0:2],pipe_vs [0:2];
    reg pipe_verify [0:2],pipe_capture [0:2],pipe_full [0:2],pipe_ink [0:2];
    reg pipe_roi [0:2],pipe_roi_geometry [0:2];
    reg [23:0] pipe_expected [0:2];
    reg [7:0] pipe_char [0:2];
    integer pipe_x [0:2],pipe_y [0:2],pipe_region [0:2];
    integer pipe_row [0:2],pipe_col [0:2];
    integer checks=0,verified_pixels=0,transparent_pixels=0;
    integer camera_pixels=0,hyphen_pixels=0,dot_pixels=0;
    integer kg_pixels=0,removed_text_pixels=0;
    integer snapshot_pixels=0,frame_starts=0;
    integer full_snapshot_pixels=0,effect_modes_checked=0,detection_modes_checked=0;
    integer roi_visible_pixels=0,roi_hidden_pixels=0,roi_counter_pixels=0;
    integer roi_frame_checks=0,roi_midframe_checks=0;
    integer roi_class_pixels [0:6];
    integer region_pixels [0:15],ink_pixels [0:15];
    integer chinese_class_pixels [0:6],english_class_pixels [0:6];
    integer j;
    reg [23:0] panel_image [0:PANEL_PIXELS-1];
    reg [23:0] full_image [0:W*H-1];

    always @(posedge clk) begin
        if(!rst_n) begin
            for(j=0;j<3;j=j+1) begin
                pipe_de[j]=0;pipe_hs[j]=0;pipe_vs[j]=0;
                pipe_verify[j]=0;pipe_capture[j]=0;pipe_ink[j]=0;
                pipe_full[j]=0;
                pipe_roi[j]=0;pipe_roi_geometry[j]=0;
                pipe_expected[j]=0;pipe_char[j]=" ";
                pipe_x[j]=0;pipe_y[j]=0;pipe_region[j]=0;
                pipe_row[j]=0;pipe_col[j]=0;
            end
        end else begin
            for(j=2;j>0;j=j-1) begin
                pipe_de[j]=pipe_de[j-1];pipe_hs[j]=pipe_hs[j-1];
                pipe_vs[j]=pipe_vs[j-1];pipe_verify[j]=pipe_verify[j-1];
                pipe_capture[j]=pipe_capture[j-1];pipe_ink[j]=pipe_ink[j-1];
                pipe_full[j]=pipe_full[j-1];
                pipe_roi[j]=pipe_roi[j-1];
                pipe_roi_geometry[j]=pipe_roi_geometry[j-1];
                pipe_expected[j]=pipe_expected[j-1];pipe_char[j]=pipe_char[j-1];
                pipe_x[j]=pipe_x[j-1];pipe_y[j]=pipe_y[j-1];
                pipe_region[j]=pipe_region[j-1];
                pipe_row[j]=pipe_row[j-1];pipe_col[j]=pipe_col[j-1];
            end
            pipe_de[0]=de;pipe_hs[0]=hs;pipe_vs[0]=vs;
            pipe_verify[0]=sample_verify;pipe_capture[0]=sample_capture;
            pipe_full[0]=sample_full;
            pipe_x[0]=user ? 0 : injected_x;
            pipe_y[0]=user ? 0 : injected_y;
            pipe_roi_geometry[0]=roi_outline(pipe_x[0],pipe_y[0]);
            pipe_roi[0]=panel_enabled && expected_box_valid && pipe_roi_geometry[0];
            render_sample(pipe_x[0],pipe_y[0],rgb,pipe_expected[0],
                pipe_region[0],pipe_char[0],pipe_row[0],pipe_col[0],pipe_ink[0]);
            #1;
            checks=checks+1;
            if({got_de,got_hs,got_vs} !== {pipe_de[2],pipe_hs[2],pipe_vs[2]})
                $fatal(1,"Fruit video control is not three input registers deep at %0d,%0d",
                    pipe_x[2],pipe_y[2]);
            if(got_rd !== de)
                $fatal(1,"Video read enable no longer follows input DE");
            if(got_sof !== (pipe_de[1] && pipe_x[1]==0 && pipe_y[1]==0))
                $fatal(1,"Display SOF no longer matches the second coordinate stage");
            if(got_sof) frame_starts=frame_starts+1;
            if(pipe_verify[1] && pipe_de[1] &&
                dut.S_cnn_roi_on !== pipe_roi[1])
                $fatal(1,"Fruit ROI geometry/mode/latched-box mismatch at %0d,%0d actual=%b expected=%b",
                    pipe_x[1],pipe_y[1],dut.S_cnn_roi_on,pipe_roi[1]);
            // Verify field semantics and scaled coordinates before the shared
            // ROM. Pixel comparison below separately checks its real latency.
            if(pipe_verify[1] && pipe_de[1] && pipe_region[1]>0 && pipe_region[1]<10) begin
                if(dut.S_cnn_char !== pipe_char[1] ||
                    dut.S_cnn_text_y !== 4'(pipe_row[1]) ||
                    dut.S_cnn_font_col !== 4'(pipe_col[1]))
                    $fatal(1,"Fruit field/scale class=%0d region=%0d xy=%0d,%0d char=%h/%h row=%0d/%0d col=%0d/%0d",
                        selected_class,pipe_region[1],pipe_x[1],pipe_y[1],
                        dut.S_cnn_char,pipe_char[1],dut.S_cnn_text_y,pipe_row[1],
                        dut.S_cnn_font_col,pipe_col[1]);
            end
            if(pipe_verify[1] && pipe_de[1] && panel_enabled &&
                ((pipe_x[1]>=1040 && pipe_x[1]<1200 &&
                  pipe_y[1]>=136 && pipe_y[1]<152) ||
                 (pipe_x[1]>=1024 && pipe_x[1]<1216 &&
                  pipe_y[1]>=656 && pipe_y[1]<672))) begin
                if(dut.S_cnn_panel_on || dut.S_font_valid_next)
                    $fatal(1,"Removed fruit text still enabled at %0d,%0d",
                        pipe_x[1],pipe_y[1]);
                removed_text_pixels=removed_text_pixels+1;
            end
            if(pipe_verify[2] && pipe_de[2]) begin
                verified_pixels=verified_pixels+1;
                if(legacy_counter_area(pipe_x[2],pipe_y[2]))
                    roi_counter_pixels=roi_counter_pixels+1;
                else if(got !== pipe_expected[2])
                    $fatal(1,"Fruit pixel class=%0d region=%0d xy=%0d,%0d glyph=%h row=%0d col=%0d ink=%b got=%h expected=%h",
                        selected_class,pipe_region[2],pipe_x[2],pipe_y[2],
                        pipe_char[2],pipe_row[2],pipe_col[2],pipe_ink[2],
                        got,pipe_expected[2]);
                if(pipe_roi[2] && !legacy_counter_area(pipe_x[2],pipe_y[2])) begin
                    roi_visible_pixels=roi_visible_pixels+1;
                    roi_class_pixels[selected_class]=roi_class_pixels[selected_class]+1;
                end else if(pipe_roi_geometry[2] && !pipe_roi[2])
                    roi_hidden_pixels=roi_hidden_pixels+1;
                region_pixels[pipe_region[2]]=region_pixels[pipe_region[2]]+1;
                if(pipe_region[2]!=0 && !pipe_ink[2])
                    transparent_pixels=transparent_pixels+1;
                if(pipe_ink[2]) begin
                    ink_pixels[pipe_region[2]]=ink_pixels[pipe_region[2]]+1;
                    if(pipe_char[2]=="-") hyphen_pixels=hyphen_pixels+1;
                    if(pipe_char[2]==".") dot_pixels=dot_pixels+1;
                    if(pipe_char[2]=="k" || pipe_char[2]=="g") kg_pixels=kg_pixels+1;
                end
                if(pipe_region[2]==3)
                    chinese_class_pixels[selected_class]=chinese_class_pixels[selected_class]+1;
                if(pipe_region[2]==4)
                    english_class_pixels[selected_class]=english_class_pixels[selected_class]+1;
                if(pipe_region[2]==0 &&
                    (!panel_enabled || pipe_x[2]<PANEL_X)) camera_pixels=camera_pixels+1;
            end
            if(pipe_capture[2] && pipe_de[2] && pipe_x[2]>=PANEL_X) begin
                panel_image[pipe_y[2]*PANEL_W+pipe_x[2]-PANEL_X]=got;
                snapshot_pixels=snapshot_pixels+1;
            end
            if(pipe_full[2] && pipe_de[2]) begin
                full_image[pipe_y[2]*W+pipe_x[2]]=got;
                full_snapshot_pixels=full_snapshot_pixels+1;
            end
        end
    end

    task automatic blank(input integer cycles);
        begin
            @(negedge clk);
            de=0;user=0;last=0;cnn_valid=0;
            sample_verify=0;sample_capture=0;sample_full=0;latency_strobe=0;hs=1;
            repeat(cycles) @(negedge clk);
            hs=0;
        end
    endtask

    task automatic configure(
        input integer id,enable,
        input [15:0] weight,price,
        input integer valid_weight,valid_price
    );
        integer frame;
        begin
            blank(5);
            selected_class=id;panel_enabled=enable!=0;
            expected_detection_mode=detection_mode;
            expected_target_found=target_found;
            expected_target_shape=target_shape;
            expected_box_valid=hand_box_valid;
            expected_box=hand_box;
            cnn_class=3'(id);cnn_enable=enable!=0;
            weight_bcd=weight;price_bcd=price;
            weight_valid=valid_weight!=0;price_valid=valid_price!=0;
            blank(5);
            // First SOF latches enable; second also tests the normal class
            // update after the previously disabled visibility becomes active.
            for(frame=0;frame<2;frame=frame+1) begin
                @(negedge clk);
                injected_x=0;injected_y=0;
                de=1;user=1;last=0;cnn_valid=1;rgb=0;
                vs=frame[0];
                blank(5);
            end
            vs=0;
            if(dut.S_cnn_visible !== (enable!=0) ||
                dut.S_cnn_class !== 3'(enable!=0 ? id : 1) ||
                !dut.S_fruit_showcase)
                $fatal(1,"Production fruit frame configuration did not latch");
            if(dut.S_hand_box !== {expected_box_valid,expected_box})
                $fatal(1,"Fruit ROI valid/geometry did not latch at frame start");
            roi_frame_checks=roi_frame_checks+1;
        end
    endtask

    task automatic scan_rectangle(
        input integer left,top,width,height,capture
    );
        integer x,y;
        begin
            for(y=top;y<top+height;y=y+1)
                for(x=left;x<left+width;x=x+1) begin
                    @(negedge clk);
                    injected_x=12'(x);injected_y=12'(y);
                    de=1;user=0;last=x==W-1;
                    hs=(x%29)==0;vs=(y%37)==0;
                    rgb={8'(x+selected_class*17),8'(y*3+31),8'(x+y+83)};
                    // The complete screenshot also includes legacy Logo and
                    // counter pixels. Independently compare every changed
                    // field and its surrounding camera margin.
                    sample_verify=capture!=2 || x>=958 ||
                        (x>=15 && x<378 && y>=631 && y<706) ||
                        (x>=ROI_LEFT-2 && x<=ROI_RIGHT+2 &&
                         y>=ROI_TOP-2 && y<=ROI_BOTTOM+2 &&
                         (x<ROI_LEFT+4 || x>ROI_RIGHT-4 ||
                          y<ROI_TOP+4 || y>ROI_BOTTOM-4));
                    sample_capture=capture==1;sample_full=capture==2;
                end
            blank(5);
        end
    endtask

    task automatic scan_roi_perimeter(input [47:0] box);
        integer left,top,right,bottom,width,height;
        begin
            left=box[11:0];right=box[23:12];
            top=box[35:24];bottom=box[47:36];
            width=right-left+1;height=bottom-top+1;
            // Two outer and two inner camera pixels around each 2px edge.
            scan_rectangle(left-2,top-2,width+4,6,0);
            scan_rectangle(left-2,bottom-3,width+4,6,0);
            scan_rectangle(left-2,top+4,6,height-8,0);
            scan_rectangle(right-3,top+4,6,height-8,0);
        end
    endtask

    task automatic save_full(input string filename);
        integer file_handle,index;
        begin
            if(full_snapshot_pixels!=W*H)
                $fatal(1,"Incomplete full-screen capture %0d",full_snapshot_pixels);
            file_handle=$fopen(filename,"wb");
            if(!file_handle) $fatal(1,"Cannot create full-screen preview");
            $fwrite(file_handle,"P6\n1280 720\n255\n");
            for(index=0;index<W*H;index=index+1)
                $fwrite(file_handle,"%c%c%c",full_image[index][23:16],
                    full_image[index][15:8],full_image[index][7:0]);
            $fclose(file_handle);
        end
    endtask

    task automatic save_roi_preview;
        integer file_handle,x,y,index;
        begin
            file_handle=$fopen("fruit_roi_detail.ppm","wb");
            if(!file_handle) $fatal(1,"Cannot create fruit ROI preview");
            $fwrite(file_handle,"P6\n%0d %0d\n255\n",ROI_PREVIEW_W,ROI_PREVIEW_H);
            for(y=ROI_PREVIEW_TOP;y<ROI_PREVIEW_TOP+ROI_PREVIEW_H;y=y+1)
                for(x=ROI_PREVIEW_LEFT;x<ROI_PREVIEW_LEFT+ROI_PREVIEW_W;x=x+1) begin
                    index=y*W+x;
                    $fwrite(file_handle,"%c%c%c",full_image[index][23:16],
                        full_image[index][15:8],full_image[index][7:0]);
                end
            $fclose(file_handle);
        end
    endtask

    task automatic save_panel(input integer id);
        integer file_handle,index;
        reg [255:0] filename;
        begin
            if(snapshot_pixels!=PANEL_PIXELS)
                $fatal(1,"Incomplete preview class=%0d got=%0d expected=%0d",
                    id,snapshot_pixels,PANEL_PIXELS);
            $sformat(filename,"fruit_panel_class_%0d.ppm",id);
            file_handle=$fopen(filename,"wb");
            if(!file_handle) $fatal(1,"Cannot create preview %0s",filename);
            $fwrite(file_handle,"P6\n320 720\n255\n");
            for(index=0;index<PANEL_PIXELS;index=index+1)
                $fwrite(file_handle,"%c%c%c",panel_image[index][23:16],
                    panel_image[index][15:8],panel_image[index][7:0]);
            $fclose(file_handle);
            $display("FRUIT_FONT_PREVIEW class=%0d path=%0s pixels=%0d",
                id,filename,snapshot_pixels);
        end
    endtask

    integer c,r,id,d;
    initial begin
        if(ROI_WIDTH!=480 || ROI_HEIGHT!=480 ||
            2*ROI_LEFT+ROI_WIDTH!=PANEL_X || 2*ROI_TOP+ROI_HEIGHT!=H ||
            ROI_RIGHT>=PANEL_X || ROI_BOTTOM>=632)
            $fatal(1,"Fruit ROI must be centered in the camera area and avoid both lower HUDs");
        for(r=0;r<16;r=r+1) begin region_pixels[r]=0;ink_pixels[r]=0;end
        for(r=0;r<7;r=r+1) begin
            chinese_class_pixels[r]=0;
            english_class_pixels[r]=0;
            roi_class_pixels[r]=0;
        end
        // Populate once; no DUT hierarchy or address mapping is used here.
        for(c=0;c<256;c=c+1)
            for(r=0;r<16;r=r+1) begin
                oracle_char=8'(c);oracle_row=4'(r);#1;
                glyphs[c*16+r]=oracle_bits;
                if(c>=32 && c<128 && (oracle_bits & 16'hc003)!=0)
                    $fatal(1,"ASCII side-bearing crop would remove ink char=%h row=%0d",c,r);
            end
        force dut.S_x=injected_x;
        force dut.S_y=injected_y;
        blank(4);rst_n=1;blank(4);
        @(negedge clk);latency_strobe=1;
        @(negedge clk);latency_strobe=0;
        blank(70);
        for(id=1;id<=6;id=id+1) begin
            case(id)
                1: configure(id,1,16'h4321,16'h8765,0,0);
                2: configure(id,1,16'h1250,16'h1000,1,1);
                3: configure(id,1,16'h0037,16'h0088,1,1);
                4: configure(id,1,16'h0000,16'h0000,1,1);
                5: configure(id,1,16'h9999,16'h9999,1,1);
                6: configure(id,1,16'h0008,16'h0105,1,1);
            endcase
            snapshot_pixels=0;
            // Two real camera columns before x=960 catch a shifted or opaque
            // panel edge. All 720 rows include the removed text and blanks.
            scan_rectangle(PANEL_X-2,0,PANEL_W+2,H,1);
            save_panel(id);
            scan_roi_perimeter(FRUIT_ROI);
        end
        // Invalid channels independently retain the other field, and every
        // decimal digit is exercised in all four numeric positions.
        configure(2,1,16'h0012,16'h0345,0,1);
        scan_rectangle(991,423,258,34,0);
        scan_rectangle(975,519,290,34,0);
        configure(2,1,16'h0678,16'h0090,1,0);
        scan_rectangle(991,423,258,34,0);
        scan_rectangle(975,519,290,34,0);
        for(d=0;d<10;d=d+1) begin
            configure(2,1,16'(d*16'h1111),16'(d*16'h1111),1,1);
            scan_rectangle(991,423,258,34,0);
            scan_rectangle(975,519,290,34,0);
        end
        // Kilogram carry boundaries, retaining all three fractional digits.
        configure(2,1,16'h0001,16'h0001,1,1);
        scan_rectangle(991,423,258,34,0);
        configure(2,1,16'h0999,16'h0799,1,1);
        scan_rectangle(991,423,258,34,0);
        configure(2,1,16'h1000,16'h0800,1,1);
        scan_rectangle(991,423,258,34,0);
        // BCD corruption is represented by visible dashes, not glyph aliases.
        configure(2,1,16'ha1b2,16'hc3d4,1,1);
        scan_rectangle(991,423,258,34,0);
        scan_rectangle(975,519,290,34,0);
        configure(1,0,16'h1250,16'h1000,1,1);
        scan_rectangle(958,60,322,22,0);
        scan_rectangle(958,212,322,70,0);
        scan_rectangle(958,326,322,36,0);
        scan_rectangle(958,654,322,20,0);
        scan_roi_perimeter(FRUIT_ROI);
        blank(5);
        for(id=1;id<=9;id=id+1)
            if(id==2 || id==9) begin
                if(region_pixels[id]!=0 || ink_pixels[id]!=0)
                    $fatal(1,"Deleted fruit field still rendered %0d",id);
            end else if(region_pixels[id]==0 || ink_pixels[id]==0)
                $fatal(1,"Untested fruit field %0d",id);
        for(id=1;id<=6;id=id+1)
            if(chinese_class_pixels[id]!=128*64 || english_class_pixels[id]!=320*32)
                $fatal(1,"Incomplete scaled result coverage class=%0d pixels=%0d",
                    id,chinese_class_pixels[id]);
        if(camera_pixels<1000 || transparent_pixels<10000 ||
            hyphen_pixels==0 || dot_pixels==0 || kg_pixels==0 ||
            removed_text_pixels<30000 || frame_starts<12)
            $fatal(1,"Incomplete background/punctuation/pipeline coverage");
        // Geometry and valid are frame-latched independently of class text.
        // Changing both raw inputs must leave the old border intact.
        configure(2,1,16'h1250,16'h1000,1,1);
        hand_box=ALTERNATE_ROI;hand_box_valid=0;
        scan_roi_perimeter(FRUIT_ROI);
        scan_roi_perimeter(ALTERNATE_ROI);
        roi_midframe_checks=roi_midframe_checks+1;
        configure(2,1,16'h1250,16'h1000,1,1);
        scan_roi_perimeter(FRUIT_ROI);
        scan_roi_perimeter(ALTERNATE_ROI);
        // Raising valid in the middle of a frame cannot enable the new box.
        hand_box_valid=1;
        scan_roi_perimeter(ALTERNATE_ROI);
        roi_midframe_checks=roi_midframe_checks+1;
        configure(2,1,16'h1250,16'h1000,1,1);
        scan_roi_perimeter(ALTERNATE_ROI);
        scan_roi_perimeter(FRUIT_ROI);
        // Restore the real fruit geometry, checking that its old location
        // disappears only after the next frame boundary.
        hand_box=FRUIT_ROI;
        scan_roi_perimeter(ALTERNATE_ROI);
        scan_roi_perimeter(FRUIT_ROI);
        roi_midframe_checks=roi_midframe_checks+1;
        configure(2,1,16'h1250,16'h1000,1,1);
        scan_roi_perimeter(FRUIT_ROI);
        scan_roi_perimeter(ALTERNATE_ROI);
        scan_rectangle(0,0,W,H,2);
        save_full("fruit_hud_720p.ppm");
        save_roi_preview();
        // Verify all thirteen names and the two-digit 10/11/12 prefixes in
        // the actual large-cell geometry, including its first/last pixels.
        for(d=0;d<13;d=d+1) begin
            effect_mode=4'(d);
            configure(2,1,16'h1250,16'h1000,1,1);
            scan_rectangle(16,672,360,32,0);
            effect_modes_checked=effect_modes_checked+1;
        end
        effect_mode=0;
        for(d=0;d<4;d=d+1) begin
            detection_mode=2'(d);target_shape=2'(d);target_found=1;
            configure(2,0,16'h1250,16'h1000,1,1);
            // Changing raw metadata must wait until a new frame. The fixed
            // oracle retains the selected mode, shape and found flag.
            detection_mode=2'(d+1);target_shape=2'(d+1);target_found=0;
            scan_rectangle(15,631,362,74,0);
            // Latency remains independently visible with the fruit panel
            // disabled, on every detector mode and with no target found.
            scan_rectangle(959,591,321,114,0);
            detection_mode=2'(d);target_shape=2'(d);target_found=0;
            configure(2,0,16'h1250,16'h1000,1,1);
            scan_rectangle(15,631,362,74,0);
            // The frame bridge keeps producing real detector results in the
            // fruit view. Check FOUND and NONE, including mid-frame changes.
            target_found=1;
            configure(2,1,16'h1250,16'h1000,1,1);
            detection_mode=2'(d+1);target_shape=2'(d+1);target_found=0;
            scan_rectangle(15,631,362,74,0);
            detection_mode=2'(d);target_shape=2'(d);target_found=0;
            configure(2,1,16'h1250,16'h1000,1,1);
            scan_rectangle(15,631,362,74,0);
            detection_modes_checked=detection_modes_checked+1;
        end
        detection_mode=3;target_found=1;
        configure(2,0,16'h1250,16'h1000,1,1);
        full_snapshot_pixels=0;
        scan_rectangle(0,0,W,H,2);
        save_full("detection_hud_720p.ppm");
        if(region_pixels[10]<6*312*32 || region_pixels[11]<6*312*32 ||
            region_pixels[12]<6*312*32 || region_pixels[13]<14*360*32 ||
            ink_pixels[10]==0 || ink_pixels[11]==0 || ink_pixels[12]==0 ||
            ink_pixels[13]==0 || ink_pixels[14]==0 ||
            effect_modes_checked!=13 || detection_modes_checked!=4)
            $fatal(1,"Incomplete production lower-HUD pixel coverage");
        for(id=1;id<=6;id=id+1)
            if(roi_class_pixels[id]<ROI_VISIBLE_PER_CLASS)
                $fatal(1,"Fruit ROI class color was not verified id=%0d pixels=%0d",
                    id,roi_class_pixels[id]);
        if(roi_visible_pixels<6*ROI_VISIBLE_PER_CLASS || roi_hidden_pixels<ROI_OUTLINE_PIXELS ||
            roi_frame_checks<6 || roi_midframe_checks!=3 || roi_counter_pixels==0 ||
            hand_box!==FRUIT_ROI || !hand_box_valid)
            $fatal(1,"Incomplete fruit ROI edge/color/mode/frame-latch coverage");
        $display("FRUIT_FONT_PIXELS_PASS checks=%0d pixels=%0d transparent=%0d camera=%0d hyphen_ink=%0d decimal_ink=%0d kg_ink=%0d removed_text_pixels=%0d frame_starts=%0d previews=9 full_screen=%0d large_effect_modes=%0d detection_modes=%0d roi_visible=%0d roi_hidden=%0d roi_frames=%0d roi_midframe=%0d",
            checks,verified_pixels,transparent_pixels,camera_pixels,
            hyphen_pixels,dot_pixels,kg_pixels,removed_text_pixels,frame_starts,
            full_snapshot_pixels,effect_modes_checked,detection_modes_checked,
            roi_visible_pixels,roi_hidden_pixels,roi_frame_checks,roi_midframe_checks);
        $finish;
    end
    initial begin #80000000;$fatal(1,"Production fruit font pixel timeout");end
endmodule
