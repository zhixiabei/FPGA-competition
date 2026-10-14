// Frame-complete, sparse pre-white-balance metering for four RGB pixels/clock.
// sum_y includes NON-HIGHLIGHT samples only; sample_count includes all samples.
// bright_count records white highlights, so sample_count-bright_count is the
// denominator for background metering. Lamps/screens may clip without forcing
// nearby non-emissive objects to be underexposed.
// This is a statistics tap: it does not stall or modify the video stream.
module ae_frame_stats_96 #(
    parameter integer IMG_WIDTH = 1280,
    parameter integer IMG_HEIGHT = 720,
    parameter integer SAMPLE_GROUP_LOG2 = 3,
    parameter integer SAMPLE_ROW_LOG2 = 2,
    parameter integer BRIGHT_Y = 232,
    // Post-LSC metering can use channel thresholds derived at elaboration
    // from the minimum grid gains. Keep the original policy when disabled.
    parameter integer BRIGHT_RGB_ENABLE = 0,
    parameter integer BRIGHT_R = 232,
    parameter integer BRIGHT_G = 232,
    parameter integer BRIGHT_B = 232
) (
    input wire I_clk,
    input wire I_rst_n,
    input wire I_tuser,
    input wire I_tlast,
    input wire I_tvalid,
    input wire [95:0] I_tdata,
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
    localparam integer SAMPLE_TOTAL =
        ((GROUPS + GROUP_PERIOD - 1) / GROUP_PERIOD) *
        ((IMG_HEIGHT + ROW_PERIOD - 1) / ROW_PERIOD);
    localparam integer COUNT_BITS = bit_width(SAMPLE_TOTAL + 1);
    localparam integer SUM_BITS = bit_width(SAMPLE_TOTAL * 255 + 1);
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

    // A marker may precede its first valid RGB beat. A held marker denotes
    // one frame, and a new marker discards an incomplete preceding frame.
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
    wire sample_beat = ((beat_group & GROUP_MASK) == 0) &&
                       ((beat_row & ROW_MASK) == 0);

    // Lane zero is the earliest pixel, RGB bytes in 95:72.
    // Y=(R+2G+B)/4 avoids multipliers and cannot exceed 255.
    wire [8:0] rb = {1'b0, I_tdata[95:88]} +
                    {1'b0, I_tdata[79:72]};
    wire [9:0] rgb_sum = {1'b0, rb} + {1'b0, I_tdata[87:80], 1'b0};
    wire [7:0] pixel_y = rgb_sum[9:2];
    // A saturated single colour (e.g. 255,0,0) is not a white-light highlight.
    // A single channel reaching 255 is not sufficient to exclude this sample.
    wire pixel_bright = (pixel_y >= BRIGHT_Y) ||
        (BRIGHT_RGB_ENABLE != 0 && I_tdata[95:88] >= BRIGHT_R &&
         I_tdata[87:80] >= BRIGHT_G && I_tdata[79:72] >= BRIGHT_B);
    wire [SUM_BITS-1:0] sum_next =
        (first_beat ? {SUM_BITS{1'b0}} : sum_y) +
        ((sample_beat && !pixel_bright) ? pixel_y : 8'd0);
    wire [COUNT_BITS-1:0] count_next =
        (first_beat ? {COUNT_BITS{1'b0}} : sample_count) + sample_beat;
    wire [COUNT_BITS-1:0] bright_next =
        (first_beat ? {COUNT_BITS{1'b0}} : bright_count) +
        (sample_beat && pixel_bright);

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
                // Include the final beat, and never publish a malformed or
                // truncated frame. Held output payload is suitable for CDC.
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
endmodule
