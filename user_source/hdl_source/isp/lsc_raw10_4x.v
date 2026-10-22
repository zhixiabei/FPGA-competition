// Low-cost separable 2-D colour-shading correction, four RAW10 pixels/clock.
// Production: measured 3x3 neutral gains with reciprocal-aware interpolation.
// Legacy quadratic axes remain available when MESH_ENABLE=0.
// Pixel 0 is I_tdata[9:0]. All markers and pixels have the same three-stage
// latency, including bubbles and an early SOF. The camera cannot be stalled.
//
// For group j, N=IMG_WIDTH/4-1:
//   dx_c = round(EDGE_c_Q8 * ((2*j-N)/N)^2)
//   dy_c = round(EDGE_Y_c_Q8 * ((2*y-(IMG_HEIGHT-1))/(IMG_HEIGHT-1))^2)
//   delta_c = min(MAX_c_Q8, dx_c + dy_c)
//   output = saturate10(input + round(max(input-BLACK_LEVEL,0)*delta_c/256))
// Four neighbouring pixels share the horizontal coefficient. Two mirrored
// half-profiles are computed at elaboration: no runtime square or division.
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
    parameter integer BLACK_LEVEL = 0,
    parameter integer IMG_HEIGHT = 720,
    parameter integer EDGE_Y_R_Q8 = 0,
    parameter integer EDGE_Y_GR_Q8 = 48,
    parameter integer EDGE_Y_GB_Q8 = 48,
    parameter integer EDGE_Y_B_Q8 = 0,
    parameter integer MAX_R_Q8 = 255,
    parameter integer MAX_GR_Q8 = 255,
    parameter integer MAX_GB_Q8 = 255,
    parameter integer MAX_B_Q8 = 255,
    parameter integer MESH_ENABLE = 0,
    parameter integer MESH_CURVE_ENABLE = 1,
    // Row-major nodes, node 1 in the most significant bits. R stays at unity.
    // This sensor profile attenuates Gr/Gb (8-bit Q8), B uses 9-bit Q8.
    parameter [71:0] MESH_GR_Q8 = {9{8'd255}},
    parameter [71:0] MESH_GB_Q8 = {9{8'd255}},
    parameter [80:0] MESH_B_Q8 = {9{9'd256}},
    parameter integer DIAGNOSTIC_ENABLE = 0
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
    input wire O_tready,
    output wire [3:0] O_diag_clip_new
);
    localparam integer GROUPS = IMG_WIDTH / 4;
    localparam integer HALF_GROUPS = (GROUPS + 1) / 2;
    localparam integer X_BITS = GROUPS > 1 ? $clog2(GROUPS) : 1;
    localparam integer ROM_BITS = HALF_GROUPS > 1 ? $clog2(HALF_GROUPS) : 1;
    localparam integer HALF_ROWS = (IMG_HEIGHT + 1) / 2;
    localparam integer Y_BITS = IMG_HEIGHT > 1 ? $clog2(IMG_HEIGHT) : 1;
    localparam integer Y_ROM_BITS = HALF_ROWS > 1 ? $clog2(HALF_ROWS) : 1;
    localparam TOP_RED = BAYER_MODE == "RGGB" || BAYER_MODE == "GRBG";
    localparam TOP_GREEN_EVEN = BAYER_MODE == "GBRG" || BAYER_MODE == "GRBG";

    function [4:0] mesh_curve_shape;
        input [8:0] group;
        reg [8:0] distance;
        reg [6:0] folded;
        begin
            // Exact thresholds for round(64*d*(152-d)/152^2), d=0..76.
            // Comparisons keep this fixed 720p profile out of ERAM and DSPs.
            distance=group<160 ? 9'd160-group : group-9'd160;
            folded=distance<76 ? distance[6:0] : 9'd152-distance;
            if(distance>=152) mesh_curve_shape=0;
            else if(folded<2) mesh_curve_shape=0;
            else if(folded<4) mesh_curve_shape=1;
            else if(folded<7) mesh_curve_shape=2;
            else if(folded<9) mesh_curve_shape=3;
            else if(folded<12) mesh_curve_shape=4;
            else if(folded<15) mesh_curve_shape=5;
            else if(folded<18) mesh_curve_shape=6;
            else if(folded<21) mesh_curve_shape=7;
            else if(folded<24) mesh_curve_shape=8;
            else if(folded<28) mesh_curve_shape=9;
            else if(folded<32) mesh_curve_shape=10;
            else if(folded<36) mesh_curve_shape=11;
            else if(folded<41) mesh_curve_shape=12;
            else if(folded<46) mesh_curve_shape=13;
            else if(folded<53) mesh_curve_shape=14;
            else if(folded<63) mesh_curve_shape=15;
            else mesh_curve_shape=16;
        end
    endfunction

    function [2047:0] mesh_scale_table;
        input integer unused;
        integer amplitude, shape;
        begin
            mesh_scale_table=0;
            for(amplitude=0;amplitude<16;amplitude=amplitude+1)
                for(shape=0;shape<=16;shape=shape+1)
                    mesh_scale_table[4*(32*amplitude+shape) +:4]=
                        (amplitude*shape+8)/16;
        end
    endfunction

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
        assign O_diag_clip_new = 4'd0;
    end else if (MESH_ENABLE) begin: mesh
        // 720x80 bits still fit four 20-bit ERAMs. Biased knot storage leaves
        // room for the horizontal midpoint corrections. Vertical reciprocal
        // interpolation and curvature are calculated only at elaboration.
        // x anchors 8/160/312 correspond to group centres 33.5/641.5/1249.5;
        // the measured patch centres are 31.5/639.5/1247.5 (2-pixel offset).
        // y anchors use the exact half-pixel patch centres 31.5/359.5/687.5.
        localparam integer LEFT=8, MID=160, RIGHT=312, SPAN=152;
        reg [8:0] x_group, x_d0;
        reg [9:0] y_row;
        wire [8:0] current_x = I_tuser ? 9'd0 : x_group;
        wire [9:0] current_y = I_tuser ? 10'd0 : y_row;
        reg [79:0] row_rom [0:719];
        reg [79:0] row_d0;
        reg [4:0] curve_d0;
        reg [39:0] raw_d0;
        reg red_d0, green_even_d0, green_even_d1;
        function integer node;
            input integer channel, index;
            begin
                case(channel)
                    0: node=(MESH_GR_Q8 >> (8*(8-index))) & 255;
                    1: node=(MESH_GB_Q8 >> (8*(8-index))) & 255;
                    default: node=(MESH_B_Q8 >> (9*(8-index))) & 511;
                endcase
            end
        endfunction
        function [8:0] row_gain;
            input integer channel, column, row;
            integer y2, band, offset, a, b, denominator;
            begin
                y2=2*row;
                if(y2<=63) row_gain=node(channel,column);
                else if(y2>=1375) row_gain=node(channel,6+column);
                else begin
                    band=y2<719 ? 0 : 1;
                    offset=y2-(band==0 ? 63 : 719);
                    a=node(channel,3*band+column);
                    b=node(channel,3*band+3+column);
                    if(MESH_CURVE_ENABLE) begin
                        denominator=b*(656-offset)+a*offset;
                        row_gain=(656*a*b+denominator/2)/denominator;
                    end else row_gain=(a*(656-offset)+b*offset+328)/656;
                end
            end
        endfunction
        function [3:0] midpoint_correction;
            input integer channel, side, row;
            integer a, b;
            begin
                a=row_gain(channel,side,row);
                b=row_gain(channel,side+1,row);
                // Arithmetic midpoint minus harmonic midpoint, rounded Q8.
                midpoint_correction=MESH_CURVE_ENABLE ?
                    ((a-b)*(a-b)+a+b)/(2*(a+b)) : 0;
            end
        endfunction
        localparam [2047:0] CURVE_SCALE_TABLE=mesh_scale_table(0);
        function [3:0] curved_delta;
            input [3:0] amplitude;
            input [4:0] shape;
            begin
                // Combinational lookup removes the carry chain before the pixel DSP.
                curved_delta=CURVE_SCALE_TABLE[{amplitude,shape,2'b00} +:4];
            end
        endfunction
        integer row, col;
        initial begin
            for(row=0;row<720;row=row+1) begin
                for(col=0;col<3;col=col+1) begin
                    row_rom[row][7*col +:7]=row_gain(0,col,row)-128;
                    row_rom[row][21+7*col +:7]=row_gain(1,col,row)-128;
                    row_rom[row][42+6*col +:6]=row_gain(2,col,row)-240;
                end
                row_rom[row][60 +:4]=midpoint_correction(0,0,row);
                row_rom[row][64 +:4]=midpoint_correction(0,1,row);
                row_rom[row][68 +:4]=midpoint_correction(1,0,row);
                row_rom[row][72 +:4]=midpoint_correction(1,1,row);
                row_rom[row][76 +:2]=midpoint_correction(2,0,row);
                row_rom[row][78 +:2]=midpoint_correction(2,1,row);
            end
        end
        // Keep the synchronous ROM output reset-free for ERAM inference.
        always @(posedge I_clk) row_d0<=row_rom[current_y];
        always @(posedge I_clk or negedge I_rst_n) begin
            if(!I_rst_n) begin
                x_group<=0; y_row<=0; x_d0<=0; raw_d0<=0;
                red_d0<=0; green_even_d0<=0; curve_d0<=0;
            end else begin
                x_d0<=current_x; raw_d0<=I_tdata;
                curve_d0<=MESH_CURVE_ENABLE ? mesh_curve_shape(current_x) : 5'd0;
                red_d0<=TOP_RED ^ current_y[0];
                green_even_d0<=TOP_GREEN_EVEN ^ current_y[0];
                if(I_tuser) begin x_group<=0; y_row<=0; end
                if(I_tvalid) begin
                    if(I_tlast || current_x==319) begin
                        x_group<=0;
                        y_row<=current_y<719 ? current_y+1'b1 : current_y;
                    end else x_group<=current_x+1'b1;
                end
            end
        end
        wire [8:0] gain [0:2];
        genvar c;
        for(c=0;c<3;c=c+1) begin: channel
            wire [8:0] left_gain, mid_gain, right_gain;
            localparam integer CODE_BITS=c<2 ? 7 : 6;
            localparam integer CODE_OFFSET=c<2 ? 21*c : 42;
            wire [CODE_BITS-1:0] left_code=row_d0[CODE_OFFSET +:CODE_BITS];
            wire [CODE_BITS-1:0] mid_code=row_d0[CODE_OFFSET+CODE_BITS +:CODE_BITS];
            wire [CODE_BITS-1:0] right_code=row_d0[CODE_OFFSET+2*CODE_BITS +:CODE_BITS];
            wire [3:0] curve_left, curve_right;
            if(c<2) begin: green_knots
                assign left_gain={2'b01,left_code};
                assign mid_gain={2'b01,mid_code};
                assign right_gain={2'b01,right_code};
                assign curve_left=row_d0[60+8*c +:4];
                assign curve_right=row_d0[64+8*c +:4];
            end else begin: blue_knots
                assign left_gain={3'd0,left_code}+9'd240;
                assign mid_gain={3'd0,mid_code}+9'd240;
                assign right_gain={3'd0,right_code}+9'd240;
                assign curve_left={2'd0,row_d0[76 +:2]};
                assign curve_right={2'd0,row_d0[78 +:2]};
            end
            reg [8:0] gain_acc;
            reg [7:0] remainder;
            wire signed [10:0] difference = x_d0<MID ?
                $signed({2'b00,mid_gain})-$signed({2'b00,left_gain}) :
                $signed({2'b00,right_gain})-$signed({2'b00,mid_gain});
            wire signed [10:0] trial=$signed({3'b000,remainder})+difference;
            wire [3:0] correction=curved_delta(x_d0<MID ? curve_left : curve_right,curve_d0);
            assign gain[c]=(x_d0==0 ? left_gain : gain_acc)-{5'd0,correction};
            always @(posedge I_clk or negedge I_rst_n) begin
                if(!I_rst_n) begin gain_acc<=0; remainder<=SPAN/2; end
                else if(valid_pipe[0]) begin
                    if(x_d0==0) begin gain_acc<=left_gain; remainder<=SPAN/2; end
                    else if(x_d0>=LEFT && x_d0<RIGHT) begin
                        if(trial<0) begin
                            gain_acc<=gain_acc-1'b1; remainder<=trial+SPAN;
                        end else if(trial>=SPAN) begin
                            gain_acc<=gain_acc+1'b1; remainder<=trial-SPAN;
                        end else remainder<=trial;
                    end
                end
            end
        end
        wire [8:0] green_gain=red_d0 ? gain[0] : gain[1];
        wire [8:0] other_gain=red_d0 ? 9'd256 : gain[2];
        wire [9:0] pixel [0:3];
        assign pixel[0]=green_even_d0 ? raw_d0[9:0] : raw_d0[19:10];
        assign pixel[1]=green_even_d0 ? raw_d0[29:20] : raw_d0[39:30];
        assign pixel[2]=green_even_d0 ? raw_d0[19:10] : raw_d0[9:0];
        assign pixel[3]=green_even_d0 ? raw_d0[39:30] : raw_d0[29:20];
        wire [9:0] corrected [0:3];
        wire [3:0] arithmetic_clip;
        genvar p;
        for(p=0;p<4;p=p+1) begin: multiply
            reg [18:0] product;
            reg [9:0] base;
            wire [9:0] signal_value=pixel[p]>BLACK_LEVEL ? pixel[p]-BLACK_LEVEL : 10'd0;
            wire [19:0] rounded={1'b0,product}+20'd128;
            wire [11:0] total=rounded[19:8]+base;
            always @(posedge I_clk or negedge I_rst_n) begin
                if(!I_rst_n) begin product<=0; base<=0; end
                else begin
                    product<=signal_value*(p<2 ? green_gain : other_gain);
                    base<=pixel[p]>BLACK_LEVEL ? BLACK_LEVEL : pixel[p];
                end
            end
            assign corrected[p]=|total[11:10] ? 10'd1023 : total[9:0];
            assign arithmetic_clip[p]=|total[11:10];
        end
        reg [39:0] corrected_data;
        always @(posedge I_clk or negedge I_rst_n) begin
            if(!I_rst_n) begin green_even_d1<=0; corrected_data<=0; end
            else begin
                green_even_d1<=green_even_d0;
                corrected_data<=green_even_d1 ?
                    {corrected[3],corrected[1],corrected[2],corrected[0]} :
                    {corrected[1],corrected[3],corrected[0],corrected[2]};
            end
        end
        assign O_tdata=O_tvalid ? corrected_data : 40'd0;
        if (DIAGNOSTIC_ENABLE != 0) begin : diagnostic
            reg [3:0] clip_new;
            always @(posedge I_clk or negedge I_rst_n) begin
                if (!I_rst_n) clip_new<=0;
                else clip_new<=green_even_d1 ?
                    {arithmetic_clip[3],arithmetic_clip[1],
                     arithmetic_clip[2],arithmetic_clip[0]} :
                    {arithmetic_clip[1],arithmetic_clip[3],
                     arithmetic_clip[0],arithmetic_clip[2]};
            end
            assign O_diag_clip_new=O_tvalid ? clip_new : 4'd0;
        end else begin : no_diagnostic
            assign O_diag_clip_new=4'd0;
        end
        // synthesis translate_off
        integer ch, band, d, check_row, a_check, b_check, correction_check;
        initial begin
            if(IMG_WIDTH!=1280 || IMG_HEIGHT!=720)
                $fatal(1,"Measured LSC mesh is calibrated for 1280x720 only");
            for(ch=0;ch<3;ch=ch+1) begin
                for(d=0;d<9;d=d+1)
                    if((ch<2 && node(ch,d)<128) ||
                       (ch==2 && (node(ch,d)<240 || node(ch,d)>303)))
                        $fatal(1,"LSC mesh knot outside compact ROM range");
                for(check_row=0;check_row<720;check_row=check_row+1)
                    for(d=0;d<2;d=d+1) begin
                        a_check=row_gain(ch,d,check_row);
                        b_check=row_gain(ch,d+1,check_row);
                        correction_check=((a_check-b_check)*(a_check-b_check)+a_check+b_check)/
                            (2*(a_check+b_check));
                        if(MESH_CURVE_ENABLE && correction_check>(ch<2 ? 15 : 3))
                            $fatal(1,"LSC mesh curvature outside compact ROM range");
                    end
            end
            for(ch=0;ch<3;ch=ch+1)
                for(band=0;band<3;band=band+1)
                    for(d=0;d<2;d=d+1)
                        if(node(ch,band*3+d+1)-node(ch,band*3+d)>SPAN ||
                           node(ch,band*3+d)-node(ch,band*3+d+1)>SPAN)
                            $fatal(1,"LSC mesh slope exceeds one Q8 step/group");
        end
        // synthesis translate_on
    end else begin: correct
        reg [X_BITS-1:0] x_group;
        reg [Y_BITS-1:0] y_row;
        reg row_odd;
        wire [X_BITS-1:0] current_x = I_tuser ? {X_BITS{1'b0}} : x_group;
        wire [Y_BITS-1:0] current_y = I_tuser ? {Y_BITS{1'b0}} : y_row;
        wire current_row = I_tuser ? 1'b0 : row_odd;
        wire [X_BITS-1:0] mirrored_x = GROUPS-1-current_x;
        wire [ROM_BITS-1:0] rom_address =
            current_x < HALF_GROUPS ? current_x : mirrored_x;
        wire [Y_BITS-1:0] mirrored_y = IMG_HEIGHT-1-current_y;
        wire [Y_ROM_BITS-1:0] y_rom_address =
            current_y < HALF_ROWS ? current_y : mirrored_y;
        always @(posedge I_clk or negedge I_rst_n) begin
            if (!I_rst_n) begin x_group <= 0; y_row <= 0; row_odd <= 0; end
            else begin
                if (I_tuser) begin x_group <= 0; y_row <= 0; row_odd <= 0; end
                if (I_tvalid) begin
                    if (I_tlast || current_x == GROUPS-1) begin
                        x_group <= 0;
                        // Clamp malformed extra lines until the next SOF;
                        // never address past the vertical profile.
                        y_row <= current_y < IMG_HEIGHT-1 ? current_y+1'b1 : current_y;
                        row_odd <= !current_row;
                    end else begin
                        x_group <= current_x + 1'b1;
                        row_odd <= current_row;
                    end
                end
            end
        end

        function [7:0] profile;
            input integer strength, address, span, limit;
            reg [63:0] distance_squared, denominator, numerator, value;
            begin
                distance_squared = (span-1-2*address)*(span-1-2*address);
                denominator = (span-1)*(span-1);
                numerator = strength*distance_squared + denominator/2;
                value = span > 1 ? numerator/denominator : 0;
                // Clamping each axis before the final sum is equivalent to
                // clamping the sum. It also removes unused ROM output bits.
                profile = value > limit ? limit : value;
            end
        endfunction
        reg [31:0] coefficient_rom [0:HALF_GROUPS-1];
        reg [31:0] coefficient_y_rom [0:HALF_ROWS-1];
        integer address;
        initial begin
            for (address=0; address<HALF_GROUPS; address=address+1)
                coefficient_rom[address] = {
                    profile(EDGE_R_Q8,address,GROUPS,MAX_R_Q8), profile(EDGE_GR_Q8,address,GROUPS,MAX_GR_Q8),
                    profile(EDGE_GB_Q8,address,GROUPS,MAX_GB_Q8), profile(EDGE_B_Q8,address,GROUPS,MAX_B_Q8)};
            for (address=0; address<HALF_ROWS; address=address+1)
                coefficient_y_rom[address] = {
                    profile(EDGE_Y_R_Q8,address,IMG_HEIGHT,MAX_R_Q8), profile(EDGE_Y_GR_Q8,address,IMG_HEIGHT,MAX_GR_Q8),
                    profile(EDGE_Y_GB_Q8,address,IMG_HEIGHT,MAX_GB_Q8), profile(EDGE_Y_B_Q8,address,IMG_HEIGHT,MAX_B_Q8)};
        end
        reg [31:0] coefficient_d0, coefficient_y_d0;
        // No reset on ROM output, to allow synchronous ROM inference.
        always @(posedge I_clk) begin
            coefficient_d0 <= coefficient_rom[rom_address];
            coefficient_y_d0 <= coefficient_y_rom[y_rom_address];
        end
        reg [39:0] raw_d0;
        reg green_even_d0, red_row_d0, green_even_d1;
        function [7:0] add_profile;
            input [7:0] horizontal, vertical, limit;
            reg [8:0] total;
            begin
                total = {1'b0,horizontal} + {1'b0,vertical};
                add_profile = total > {1'b0,limit} ? limit : total[7:0];
            end
        endfunction
        wire [7:0] green_delta = red_row_d0 ?
            add_profile(coefficient_d0[23:16],coefficient_y_d0[23:16],MAX_GR_Q8) :
            add_profile(coefficient_d0[15:8],coefficient_y_d0[15:8],MAX_GB_Q8);
        wire [7:0] other_delta = red_row_d0 ?
            add_profile(coefficient_d0[31:24],coefficient_y_d0[31:24],MAX_R_Q8) :
            add_profile(coefficient_d0[7:0],coefficient_y_d0[7:0],MAX_B_Q8);
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
        if (EDGE_GR_Q8 != 0 || EDGE_GB_Q8 != 0 ||
            EDGE_Y_GR_Q8 != 0 || EDGE_Y_GB_Q8 != 0) begin: green_multiply
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
        if (EDGE_R_Q8 != 0 || EDGE_B_Q8 != 0 ||
            EDGE_Y_R_Q8 != 0 || EDGE_Y_B_Q8 != 0) begin: other_multiply
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
        if (DIAGNOSTIC_ENABLE != 0) begin : diagnostic
            function overflowed;
                input [9:0] pixel;
                input [17:0] product;
                reg [18:0] rounded;
                reg [10:0] result;
                begin
                    rounded={1'b0,product}+19'd128;
                    result={1'b0,pixel}+rounded[18:8];
                    overflowed=result[10];
                end
            endfunction
            wire g0=overflowed(green0_d1,green_product0);
            wire g1=overflowed(green1_d1,green_product1);
            wire o0=overflowed(other0_d1,other_product0);
            wire o1=overflowed(other1_d1,other_product1);
            reg [3:0] clip_new;
            always @(posedge I_clk or negedge I_rst_n) begin
                if (!I_rst_n) clip_new<=0;
                else clip_new<=green_even_d1 ? {o1,g1,o0,g0} : {g1,o1,g0,o0};
            end
            assign O_diag_clip_new=O_tvalid ? clip_new : 4'd0;
        end else begin : no_diagnostic
            assign O_diag_clip_new=4'd0;
        end
    end endgenerate

    // synthesis translate_off
    initial begin
        if (IMG_WIDTH < 4 || IMG_WIDTH % 4 != 0 || IMG_HEIGHT < 1 ||
            BLACK_LEVEL < 0 || BLACK_LEVEL > 1023 ||
            EDGE_R_Q8 < 0 || EDGE_R_Q8 > 255 || EDGE_GR_Q8 < 0 || EDGE_GR_Q8 > 255 ||
            EDGE_GB_Q8 < 0 || EDGE_GB_Q8 > 255 || EDGE_B_Q8 < 0 || EDGE_B_Q8 > 255 ||
            EDGE_Y_R_Q8 < 0 || EDGE_Y_R_Q8 > 255 || EDGE_Y_GR_Q8 < 0 || EDGE_Y_GR_Q8 > 255 ||
            EDGE_Y_GB_Q8 < 0 || EDGE_Y_GB_Q8 > 255 || EDGE_Y_B_Q8 < 0 || EDGE_Y_B_Q8 > 255 ||
            MAX_R_Q8 < 0 || MAX_R_Q8 > 255 || MAX_GR_Q8 < 0 || MAX_GR_Q8 > 255 ||
            MAX_GB_Q8 < 0 || MAX_GB_Q8 > 255 || MAX_B_Q8 < 0 || MAX_B_Q8 > 255 ||
            (BAYER_MODE != "BGGR" && BAYER_MODE != "RGGB" &&
             BAYER_MODE != "GBRG" && BAYER_MODE != "GRBG"))
            $fatal(1,"Unsupported LSC parameters");
    end
    // synthesis translate_on
endmodule
