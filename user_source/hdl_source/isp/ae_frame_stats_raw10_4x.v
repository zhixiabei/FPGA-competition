// Sparse, frame-complete exposure statistics from four RAW10 pixels/clock.
// Metering is placed before LSC so the feedback remains monotonic with sensor
// exposure. Every eighth group is sampled on two adjacent rows out of eight.
// A Bayer row pair therefore contributes 2R + 4G + 2B without demosaic logic.
// Each component is converted to eight bits and capped, but never discarded.
module ae_frame_stats_raw10_4x #(
    parameter integer IMG_WIDTH = 1280,
    parameter integer IMG_HEIGHT = 720,
    parameter integer SAMPLE_GROUP_LOG2 = 3,
    parameter integer SAMPLE_ROW_LOG2 = 3,
    parameter integer BLACK_LEVEL = 0,
    parameter integer CLIP_LEVEL = 192
) (
    input wire I_clk,
    input wire I_rst_n,
    input wire I_tuser,
    input wire I_tlast,
    input wire I_tvalid,
    input wire [39:0] I_tdata,
    output reg O_stats_valid,
    output reg [31:0] O_sum_y,
    output reg [15:0] O_sample_count,
    output reg [15:0] O_bright_count
);
    function integer bit_width;
        input integer size;
        integer value;
        begin
            value = size - 1;
            bit_width = 0;
            while (value > 0) begin
                value = value >> 1;
                bit_width = bit_width + 1;
            end
            if (bit_width < 1)
                bit_width = 1;
        end
    endfunction

    localparam integer GROUPS = IMG_WIDTH / 4;
    localparam integer GROUP_BITS = bit_width(GROUPS);
    localparam integer ROW_BITS = bit_width(IMG_HEIGHT);
    localparam integer GROUP_PERIOD = 1 << SAMPLE_GROUP_LOG2;
    localparam integer ROW_PERIOD = 1 << SAMPLE_ROW_LOG2;
    localparam integer SAMPLED_GROUPS =
        (GROUPS + GROUP_PERIOD - 1) / GROUP_PERIOD;
    localparam integer ROW_REMAINDER = IMG_HEIGHT % ROW_PERIOD;
    localparam integer SAMPLED_ROWS =
        (IMG_HEIGHT / ROW_PERIOD) * (ROW_PERIOD > 1 ? 2 : 1) +
        (ROW_REMAINDER == 0 ? 0 :
         (ROW_PERIOD == 1 ? 1 : (ROW_REMAINDER > 1 ? 2 : 1)));
    localparam integer SAMPLE_TOTAL = SAMPLED_GROUPS * SAMPLED_ROWS * 4;
    localparam integer COUNT_BITS = bit_width(SAMPLE_TOTAL + 1);
    localparam integer SUM_BITS = bit_width(SAMPLE_TOTAL * CLIP_LEVEL + 1);
    localparam [GROUP_BITS-1:0] GROUP_MASK = GROUP_PERIOD - 1;
    localparam [ROW_BITS-1:0] ROW_MASK = ROW_PERIOD - 1;

    reg user_d;
    reg frame_pending;
    reg frame_open;
    reg frame_bad;
    reg [GROUP_BITS-1:0] group_pos;
    reg [ROW_BITS-1:0] row_pos;
    reg [SUM_BITS-1:0] sum_y;
    reg [COUNT_BITS-1:0] sample_count;
    reg [COUNT_BITS-1:0] bright_count;

    wire frame_marker = I_tuser && !user_d;
    wire first_beat = frame_pending || frame_marker;
    wire accept_beat = I_tvalid && (frame_open || first_beat);
    wire [GROUP_BITS-1:0] beat_group =
        first_beat ? {GROUP_BITS{1'b0}} : group_pos;
    wire [ROW_BITS-1:0] beat_row =
        first_beat ? {ROW_BITS{1'b0}} : row_pos;
    wire final_group = beat_group == GROUPS - 1;
    wire final_beat = final_group && (beat_row == IMG_HEIGHT - 1);
    wire bad_line_marker = I_tlast != final_group;
    wire [ROW_BITS-1:0] row_phase = beat_row & ROW_MASK;
    wire sample_row = (row_phase == 0) ||
                      ((ROW_PERIOD > 1) && (row_phase == 1));
    wire sample_beat = ((beat_group & GROUP_MASK) == 0) && sample_row;

    wire [9:0] raw0 = I_tdata[9:0];
    wire [9:0] raw1 = I_tdata[19:10];
    wire [9:0] raw2 = I_tdata[29:20];
    wire [9:0] raw3 = I_tdata[39:30];
    wire [9:0] signal0 = raw0 > BLACK_LEVEL ? raw0 - BLACK_LEVEL : 10'd0;
    wire [9:0] signal1 = raw1 > BLACK_LEVEL ? raw1 - BLACK_LEVEL : 10'd0;
    wire [9:0] signal2 = raw2 > BLACK_LEVEL ? raw2 - BLACK_LEVEL : 10'd0;
    wire [9:0] signal3 = raw3 > BLACK_LEVEL ? raw3 - BLACK_LEVEL : 10'd0;
    wire [7:0] value0 = signal0[9:2];
    wire [7:0] value1 = signal1[9:2];
    wire [7:0] value2 = signal2[9:2];
    wire [7:0] value3 = signal3[9:2];
    wire bright0 = value0 >= CLIP_LEVEL;
    wire bright1 = value1 >= CLIP_LEVEL;
    wire bright2 = value2 >= CLIP_LEVEL;
    wire bright3 = value3 >= CLIP_LEVEL;
    wire [7:0] meter0 = bright0 ? CLIP_LEVEL : value0;
    wire [7:0] meter1 = bright1 ? CLIP_LEVEL : value1;
    wire [7:0] meter2 = bright2 ? CLIP_LEVEL : value2;
    wire [7:0] meter3 = bright3 ? CLIP_LEVEL : value3;
    wire [9:0] beat_sum = {2'd0, meter0} + {2'd0, meter1} +
                           {2'd0, meter2} + {2'd0, meter3};
    wire [2:0] beat_bright = {2'd0, bright0} + {2'd0, bright1} +
                              {2'd0, bright2} + {2'd0, bright3};

    wire [SUM_BITS-1:0] sum_next =
        (first_beat ? {SUM_BITS{1'b0}} : sum_y) +
        (sample_beat ? beat_sum : 10'd0);
    wire [COUNT_BITS-1:0] count_next =
        (first_beat ? {COUNT_BITS{1'b0}} : sample_count) +
        (sample_beat ? 3'd4 : 3'd0);
    wire [COUNT_BITS-1:0] bright_next =
        (first_beat ? {COUNT_BITS{1'b0}} : bright_count) +
        (sample_beat ? beat_bright : 3'd0);

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            user_d <= 1'b0;
            frame_pending <= 1'b0;
            frame_open <= 1'b0;
            frame_bad <= 1'b0;
            group_pos <= {GROUP_BITS{1'b0}};
            row_pos <= {ROW_BITS{1'b0}};
            sum_y <= {SUM_BITS{1'b0}};
            sample_count <= {COUNT_BITS{1'b0}};
            bright_count <= {COUNT_BITS{1'b0}};
            O_stats_valid <= 1'b0;
            O_sum_y <= 32'd0;
            O_sample_count <= 16'd0;
            O_bright_count <= 16'd0;
        end else begin
            user_d <= I_tuser;
            O_stats_valid <= 1'b0;
            if (frame_marker) begin
                frame_pending <= 1'b1;
                frame_open <= 1'b0;
            end
            if (accept_beat) begin
                frame_pending <= 1'b0;
                frame_open <= !final_beat;
                frame_bad <= (first_beat ? 1'b0 : frame_bad) || bad_line_marker;
                sum_y <= sum_next;
                sample_count <= count_next;
                bright_count <= bright_next;
                if (final_group) begin
                    group_pos <= {GROUP_BITS{1'b0}};
                    row_pos <= final_beat ? {ROW_BITS{1'b0}} : beat_row + 1'b1;
                end else begin
                    group_pos <= beat_group + 1'b1;
                    row_pos <= beat_row;
                end
                if (final_beat && !(first_beat ? 1'b0 : frame_bad) &&
                    !bad_line_marker && (count_next == SAMPLE_TOTAL)) begin
                    O_stats_valid <= 1'b1;
                    O_sum_y <= sum_next;
                    O_sample_count <= count_next;
                    O_bright_count <= bright_next;
                end
            end
        end
    end

    // synthesis translate_off
    initial begin
        if ((IMG_WIDTH % 4) != 0)
            $fatal(1, "AE RAW statistics require a width divisible by four");
        if (CLIP_LEVEL < 1 || CLIP_LEVEL > 255)
            $fatal(1, "AE RAW statistics clip level is outside 1..255");
        if (BLACK_LEVEL < 0 || BLACK_LEVEL > 1023)
            $fatal(1, "AE RAW statistics black level is outside RAW10");
        if (SAMPLE_TOTAL > 65535)
            $fatal(1, "AE RAW statistics count exceeds the 16-bit interface");
    end
    // synthesis translate_on
endmodule
