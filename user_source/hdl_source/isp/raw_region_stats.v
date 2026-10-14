// Nine pre-LSC Bayer windows, four RAW10 pixels/clock (pixel 0 in bits 9:0).
// Default: 32x32 pixels/window, exactly 256 samples/channel; rounded means
// use shifts. Three sets of accumulators are reused for the three row bands.
// Packets: [44:41] region 0..8, [40] any sample == 1023, [39:0] B/Gb/Gr/R.
// Region 15 commits the complete frame. Incomplete/bad frames never commit.
// This read-only tap does not change or backpressure the video path.
module raw_region_stats #(
    parameter integer IMG_WIDTH = 1280,
    parameter integer IMG_HEIGHT = 720,
    parameter integer PATCH_LOG2 = 5,
    parameter BAYER_MODE = "BGGR"
) (
    input wire I_clk, I_rst_n,
    input wire [39:0] I_tdata,
    input wire I_tvalid, I_tuser, I_tlast,
    output reg O_valid,
    output reg [44:0] O_data
);
    localparam integer P = 1 << PATCH_LOG2;
    localparam integer GROUPS = IMG_WIDTH/4;
    localparam integer XB = $clog2(GROUPS);
    localparam integer YB = $clog2(IMG_HEIGHT);
    localparam integer SHIFT = 2*PATCH_LOG2-2;
    localparam integer SB = 10+SHIFT;
    localparam [SB-1:0] ROUND = 1 << (SHIFT-1);
    localparam TOP_RED = BAYER_MODE == "RGGB" || BAYER_MODE == "GRBG";
    localparam TOP_GREEN_EVEN = BAYER_MODE == "GBRG" || BAYER_MODE == "GRBG";
    // All origins preserve the sensor's Bayer phase. Supported geometry:
    // P >= 8, width divisible by 4, even height, width/height >= 4*P.
    reg user_d, pending, frame_open, frame_bad;
    reg [XB-1:0] x;
    reg [YB-1:0] y;
    wire marker = I_tuser && !user_d;
    wire first = pending || marker;
    wire accept = I_tvalid && (frame_open || first);
    wire [XB-1:0] bx = first ? 0 : x;
    wire [YB-1:0] by = first ? 0 : y;
    wire last_group = bx == GROUPS-1;
    wire last_frame = last_group && by == IMG_HEIGHT-1;
    wire bad_marker = I_tlast != last_group;
    wire bad = (first ? 1'b0 : frame_bad) || bad_marker;
    wire band0 = by >= P/2 && by < P/2+P;
    wire band1 = by >= ((IMG_HEIGHT-P)/4)*2 && by < ((IMG_HEIGHT-P)/4)*2+P;
    wire band2 = by >= IMG_HEIGHT-P-P/2 && by < IMG_HEIGHT-P/2;
    wire in_band = band0 || band1 || band2;
    wire first_row = by == P/2 || by == ((IMG_HEIGHT-P)/4)*2 || by == IMG_HEIGHT-P-P/2;
    wire last_row = by == P/2+P-1 || by == ((IMG_HEIGHT-P)/4)*2+P-1 || by == IMG_HEIGHT-P/2-1;
    wire [3:0] region_base = band0 ? 4'd0 : band1 ? 4'd3 : 4'd6;
    wire red_line = TOP_RED ^ by[0];
    wire green_even = TOP_GREEN_EVEN ^ by[0];
    wire [10:0] even_pair = {1'b0,I_tdata[9:0]} + {1'b0,I_tdata[29:20]};
    wire [10:0] odd_pair = {1'b0,I_tdata[19:10]} + {1'b0,I_tdata[39:30]};
    wire [10:0] green_pair = green_even ? even_pair : odd_pair;
    wire [10:0] colour_pair = green_even ? odd_pair : even_pair;
    wire clipped = I_tdata[9:0] == 1023 || I_tdata[19:10] == 1023 ||
                   I_tdata[29:20] == 1023 || I_tdata[39:30] == 1023;
    wire [2:0] publish;
    wire [40:0] result [0:2];
    genvar c;
    generate for (c=0; c<3; c=c+1) begin: column
        localparam integer X0 = c==0 ? P/8 : c==1 ? (IMG_WIDTH-P)/8 : (IMG_WIDTH-P-P/2)/4;
        reg [SB-1:0] sr, sgr, sgb, sb;
        reg sat;
        wire hit = in_band && bx >= X0 && bx < X0+P/4;
        wire clear = first_row && bx == X0;
        wire [SB-1:0] nr = (clear ? {SB{1'b0}} : sr) + (red_line ? colour_pair : 11'd0);
        wire [SB-1:0] ngr = (clear ? {SB{1'b0}} : sgr) + (red_line ? green_pair : 11'd0);
        wire [SB-1:0] ngb = (clear ? {SB{1'b0}} : sgb) + (red_line ? 11'd0 : green_pair);
        wire [SB-1:0] nb = (clear ? {SB{1'b0}} : sb) + (red_line ? 11'd0 : colour_pair);
        wire [SB-1:0] rr = nr+ROUND, rgr = ngr+ROUND, rgb = ngb+ROUND, rb = nb+ROUND;
        wire next_sat = (clear ? 1'b0 : sat) || clipped;
        assign publish[c] = accept && !bad && hit && last_row && bx == X0+P/4-1;
        assign result[c] = {next_sat,rb[SB-1:SHIFT],rgb[SB-1:SHIFT],rgr[SB-1:SHIFT],rr[SB-1:SHIFT]};
        always @(posedge I_clk or negedge I_rst_n) begin
            if (!I_rst_n) begin sr<=0; sgr<=0; sgb<=0; sb<=0; sat<=0; end
            else if (accept && hit) begin sr<=nr; sgr<=ngr; sgb<=ngb; sb<=nb; sat<=next_sat; end
        end
    end endgenerate

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            user_d<=0; pending<=0; frame_open<=0; frame_bad<=0; x<=0; y<=0;
            O_valid<=0; O_data<=0;
        end else begin
            user_d<=I_tuser;
            O_valid<=0;
            if (marker) begin pending<=1; frame_open<=0; end
            if (accept) begin
                pending<=0;
                frame_open<=!last_frame;
                frame_bad<=bad;
                if (last_group) begin x<=0; y<=last_frame ? 0 : by+1'b1; end
                else begin x<=bx+1'b1; y<=by; end
                if (last_frame && !bad) begin O_valid<=1; O_data<={4'd15,41'd0}; end
            end
            if (publish[0]) begin O_valid<=1; O_data<={region_base,result[0]}; end
            if (publish[1]) begin O_valid<=1; O_data<={region_base+4'd1,result[1]}; end
            if (publish[2]) begin O_valid<=1; O_data<={region_base+4'd2,result[2]}; end
        end
    end
endmodule
