// Adjacent-frame motion on 8x8 RGB block means, four pixels per clock.
// Only the 160x90 reference is stored at 720p; the DDR video path is untouched.
// Three changed blocks in a 3x3 neighbourhood support thin moving edges while
// rejecting isolated changes. The single box includes supported edge blocks.
module motion_target_detect_96 #(
    parameter integer IMG_WIDTH = 1280,
    parameter integer IMG_HEIGHT = 720,
    parameter integer DIFF_THRESHOLD = 6,
    parameter integer MIN_BLOCKS = 8,
    parameter integer GLOBAL_CHANGE_PERCENT = 40
) (
    input wire I_clk,
    input wire I_rst_n,
    input wire I_tuser,
    input wire I_tlast,
    input wire I_tvalid,
    input wire [95:0] I_tdata,
    output reg O_result_ready,
    output reg O_found,
    output reg [11:0] O_xmin,
    output reg [11:0] O_xmax,
    output reg [11:0] O_ymin,
    output reg [11:0] O_ymax,
    output reg [11:0] O_center_x,
    output reg [11:0] O_center_y,
    output reg [23:0] O_pixels,
    output reg [23:0] O_supported_blocks,
    output reg O_scene_change,
    output reg O_frame_toggle
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
            if (bit_width < 1) bit_width = 1;
        end
    endfunction

    function [7:0] gray;
        input [23:0] rgb;
        reg [9:0] weighted;
        begin
            weighted = {2'd0,rgb[23:16]} + {1'b0,rgb[15:8],1'b0} +
                       {2'd0,rgb[7:0]};
            gray = weighted[9:2];
        end
    endfunction

    localparam integer GROUPS = IMG_WIDTH / 4;
    localparam integer COLS = IMG_WIDTH / 8;
    localparam integer ROWS = IMG_HEIGHT / 8;
    localparam integer BLOCKS = COLS * ROWS;
    localparam integer GROUP_BITS = bit_width(GROUPS);
    localparam integer ROW_BITS = bit_width(IMG_HEIGHT);
    localparam integer COL_BITS = bit_width(COLS);
    localparam integer BLOCK_ROW_BITS = bit_width(ROWS);
    localparam integer ADDR_BITS = bit_width(BLOCKS);
    localparam integer COUNT_BITS = bit_width(BLOCKS + 1);
    localparam integer MAX_CHANGED_BLOCKS =
        (BLOCKS * GLOBAL_CHANGE_PERCENT + 99) / 100;
    localparam integer LIGHT_CHANGE_BLOCKS = (BLOCKS + 7) / 8;
`ifdef MOTION_PORTABLE_RAM
    localparam integer PORTABLE_REFERENCE = 1;
`elsif SCHARR_PORTABLE_RAM
    localparam integer PORTABLE_REFERENCE = 1;
`else
    localparam integer PORTABLE_REFERENCE = 0;
`endif

    // SOF may precede valid pixels. Geometry advances only on valid beats.
    // A partial/bad frame has already overwritten part of the reference:
    // invalidate it and require a complete warm-up frame before comparing.
    reg user_d, frame_pending, frame_open, frame_bad;
    reg reference_valid, compare_frame;
    reg [GROUP_BITS-1:0] group_pos;
    reg [ROW_BITS-1:0] row_pos;
    wire frame_marker = I_tuser && !user_d;
    wire first_beat = frame_pending || frame_marker;
    wire accept_beat = I_tvalid && (frame_open || first_beat);
    wire [GROUP_BITS-1:0] beat_group = first_beat ? 0 : group_pos;
    wire [ROW_BITS-1:0] beat_row = first_beat ? 0 : row_pos;
    wire final_group = beat_group == GROUPS - 1;
    wire final_beat = final_group && beat_row == IMG_HEIGHT - 1;
    wire bad_line_marker = I_tlast != final_group;
    wire beat_clean = !(first_beat ? 1'b0 : frame_bad) && !bad_line_marker;
    wire beat_compare = first_beat ?
        (reference_valid && !(frame_marker && frame_open)) : compare_frame;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            user_d <= 0;
            frame_pending <= 0;
            frame_open <= 0;
            frame_bad <= 0;
            reference_valid <= 0;
            compare_frame <= 0;
            group_pos <= 0;
            row_pos <= 0;
        end else begin
            user_d <= I_tuser;
            if (frame_marker) begin
                frame_pending <= 1;
                frame_open <= 0;
                if (frame_open) reference_valid <= 0;
            end
            if (accept_beat) begin
                frame_pending <= 0;
                frame_open <= !final_beat;
                frame_bad <= !beat_clean;
                compare_frame <= beat_compare;
                if (!beat_clean) reference_valid <= 0;
                if (final_beat) reference_valid <= beat_clean;
                if (final_group) begin
                    group_pos <= 0;
                    row_pos <= final_beat ? 0 : beat_row + 1'b1;
                end else begin
                    group_pos <= beat_group + 1'b1;
                    row_pos <= beat_row;
                end
            end
        end
    end

    // Two short stages keep the RGB reduction off the block accumulator path.
    wire [7:0] gray0 = gray(I_tdata[95:72]);
    wire [7:0] gray1 = gray(I_tdata[71:48]);
    wire [7:0] gray2 = gray(I_tdata[47:24]);
    wire [7:0] gray3 = gray(I_tdata[23:0]);
    reg valid0, valid1, eligible0, eligible1;
    reg [8:0] pair01, pair23;
    reg [9:0] beat_sum1;
    reg [GROUP_BITS-1:0] group0, group1;
    reg [ROW_BITS-1:0] row0, row1;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            valid0 <= 0; valid1 <= 0;
            eligible0 <= 0; eligible1 <= 0;
            pair01 <= 0; pair23 <= 0; beat_sum1 <= 0;
            group0 <= 0; group1 <= 0; row0 <= 0; row1 <= 0;
        end else begin
            valid0 <= accept_beat;
            valid1 <= valid0;
            if (accept_beat) begin
                pair01 <= {1'b0,gray0} + {1'b0,gray1};
                pair23 <= {1'b0,gray2} + {1'b0,gray3};
                group0 <= beat_group;
                row0 <= beat_row;
                eligible0 <= beat_compare && beat_clean;
            end
            if (valid0) begin
                beat_sum1 <= {1'b0,pair01} + {1'b0,pair23};
                group1 <= group0;
                row1 <= row0;
                eligible1 <= eligible0;
            end
        end
    end

    // A column is read on the second four-pixel beat, then updated one
    // clock later. Row zero replaces old contents, so RAM needs no reset.
    reg [13:0] column_sums [0:COLS-1];
    reg [13:0] column_previous;
    reg [9:0] half_sum;
    reg [10:0] row_sum2;
    reg valid2, eligible2;
    reg [COL_BITS-1:0] col2;
    reg [ROW_BITS-1:0] row2;
    wire [COL_BITS-1:0] column_index = group1 >> 1;
    wire [13:0] block_sum =
        (row2[2:0] == 0 ? 14'd0 : column_previous) + {3'd0,row_sum2};
    always @(posedge I_clk) begin
        if (valid1 && group1[0])
            column_previous <= column_sums[column_index];
        if (valid2)
            column_sums[col2] <= block_sum;
    end
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            half_sum <= 0; row_sum2 <= 0;
            valid2 <= 0; eligible2 <= 0; col2 <= 0; row2 <= 0;
        end else begin
            valid2 <= valid1 && group1[0];
            if (valid1) begin
                if (!group1[0]) half_sum <= beat_sum1;
                else begin
                    row_sum2 <= {1'b0,half_sum} + {1'b0,beat_sum1};
                    col2 <= column_index;
                    row2 <= row1;
                    eligible2 <= eligible1;
                end
            end
        end
    end

    reg mean_valid, mean_first, mean_last, mean_eligible;
    reg [7:0] mean_gray;
    reg [COL_BITS-1:0] mean_x;
    reg [BLOCK_ROW_BITS-1:0] mean_y;
    reg [ADDR_BITS-1:0] mean_address, next_address;
    wire first_block = col2 == 0 && row2 == 7;
    wire [ADDR_BITS-1:0] current_address = first_block ? 0 : next_address;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            mean_valid <= 0; mean_first <= 0; mean_last <= 0;
            mean_eligible <= 0; mean_gray <= 0;
            mean_x <= 0; mean_y <= 0; mean_address <= 0; next_address <= 0;
        end else begin
            mean_valid <= valid2 && row2[2:0] == 7;
            if (valid2 && row2[2:0] == 7) begin
                mean_gray <= block_sum[13:6];
                mean_x <= col2;
                mean_y <= row2 >> 3;
                mean_first <= first_block;
                mean_last <= col2 == COLS-1 && row2 == IMG_HEIGHT-1;
                mean_eligible <= eligible2;
                mean_address <= current_address;
                next_address <= current_address + 1'b1;
            end
        end
    end

    // Two-clock registered ERAM read. The current mean is written only after
    // the old mean has been read; no same-address read/write collision.
    reg ref_valid1, ref_valid2;
    reg ref_first1, ref_first2, ref_last1, ref_last2;
    reg ref_eligible1, ref_eligible2;
    reg [7:0] ref_mean1, ref_mean2;
    reg [ADDR_BITS-1:0] ref_address1, ref_address2;
    reg [COL_BITS-1:0] ref_x1, ref_x2;
    reg [BLOCK_ROW_BITS-1:0] ref_y1, ref_y2;
    wire [7:0] reference_old;
    generate
        if (PORTABLE_REFERENCE) begin : gen_portable_reference
            reg [7:0] memory [0:BLOCKS-1];
            reg [7:0] read_data, read_output;
            always @(posedge I_clk) begin
                if (mean_valid && I_rst_n) read_data <= memory[mean_address];
                if (ref_valid1 && I_rst_n) read_output <= read_data;
                if (ref_valid2 && I_rst_n) memory[ref_address2] <= ref_mean2;
            end
            assign reference_old = read_output;
        end else begin : gen_eram_reference
            PH1P_LOGIC_ERAM #(
                .DATA_WIDTH_A(8), .DATA_WIDTH_B(8),
                .ADDR_WIDTH_A(ADDR_BITS), .ADDR_WIDTH_B(ADDR_BITS),
                .DATA_DEPTH_A(BLOCKS), .DATA_DEPTH_B(BLOCKS), .MODE("DP"),
                .REGMODE_A("NOREG"), .REGMODE_B("OUTREG"),
                .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
                .IMPLEMENT("20K(FAST)"), .CLKMODE("SYNC"),
                .ECC_ENCODE("DISABLE"), .ECC_DECODE("DISABLE"),
                .INIT_FILE("NONE"), .FILL_ALL("NONE")
            ) u_reference (
                .clka(I_clk), .clkb(I_clk),
                .cea(ref_valid2 && I_rst_n), .ceb(mean_valid && I_rst_n),
                .ocea(1'b0), .oceb(ref_valid1 && I_rst_n),
                .wea(ref_valid2 && I_rst_n), .web(1'b0),
                .rsta(1'b0), .rstb(1'b0), .bea(1'b0), .beb(1'b0),
                .addra(ref_address2), .addrb(mean_address),
                .dia(ref_mean2), .dib(8'd0), .doa(), .dob(reference_old),
                .ecc_sbiterr(), .ecc_dbiterr(),
                .ecc_sbiterrinj(1'b0), .ecc_dbiterrinj(1'b0)
            );
        end
    endgenerate
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            ref_valid1 <= 0; ref_valid2 <= 0;
            ref_first1 <= 0; ref_first2 <= 0;
            ref_last1 <= 0; ref_last2 <= 0;
            ref_eligible1 <= 0; ref_eligible2 <= 0;
            ref_mean1 <= 0; ref_mean2 <= 0;
            ref_address1 <= 0; ref_address2 <= 0;
            ref_x1 <= 0; ref_x2 <= 0; ref_y1 <= 0; ref_y2 <= 0;
        end else begin
            ref_valid1 <= mean_valid;
            ref_valid2 <= ref_valid1;
            if (mean_valid) begin
                ref_first1 <= mean_first; ref_last1 <= mean_last;
                ref_eligible1 <= mean_eligible;
                ref_mean1 <= mean_gray; ref_address1 <= mean_address;
                ref_x1 <= mean_x; ref_y1 <= mean_y;
            end
            if (ref_valid1) begin
                ref_first2 <= ref_first1; ref_last2 <= ref_last1;
                ref_eligible2 <= ref_eligible1;
                ref_mean2 <= ref_mean1; ref_address2 <= ref_address1;
                ref_x2 <= ref_x1; ref_y2 <= ref_y1;
            end
        end
    end

    wire [7:0] difference = ref_mean2 >= reference_old ?
        ref_mean2 - reference_old : reference_old - ref_mean2;
    reg mask_valid, mask_hit, mask_first, mask_last, mask_eligible, mask_rising;
    reg [COL_BITS-1:0] mask_x;
    reg [BLOCK_ROW_BITS-1:0] mask_y;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            mask_valid <= 0; mask_hit <= 0; mask_first <= 0;
            mask_last <= 0; mask_eligible <= 0; mask_x <= 0; mask_y <= 0;
            mask_rising <= 0;
        end else begin
            mask_valid <= ref_valid2;
            if (ref_valid2) begin
                mask_hit <= ref_eligible2 && difference >= DIFF_THRESHOLD;
                mask_rising <= ref_mean2 >= reference_old;
                mask_first <= ref_first2; mask_last <= ref_last2;
                mask_eligible <= ref_eligible2;
                mask_x <= ref_x2; mask_y <= ref_y2;
            end
        end
    end

    reg line1 [0:COLS-1];
    reg line2 [0:COLS-1];
    reg top_now, mid_now, bot_now, bot_rising;
    always @(posedge I_clk) begin
        if (mask_valid) begin
            top_now <= line2[mask_x];
            mid_now <= line1[mask_x];
            bot_now <= mask_hit;
            bot_rising <= mask_rising;
            line2[mask_x] <= line1[mask_x];
            line1[mask_x] <= mask_hit;
        end
    end
    reg line_valid, line_first, line_last, line_eligible;
    reg [COL_BITS-1:0] line_x;
    reg [BLOCK_ROW_BITS-1:0] line_y;
    reg [1:0] top_tail, mid_tail, bot_tail;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            line_valid <= 0; line_first <= 0; line_last <= 0;
            line_eligible <= 0; line_x <= 0; line_y <= 0;
            top_tail <= 0; mid_tail <= 0; bot_tail <= 0;
        end else begin
            line_valid <= mask_valid;
            if (mask_valid) begin
                line_first <= mask_first; line_last <= mask_last;
                line_eligible <= mask_eligible;
                line_x <= mask_x; line_y <= mask_y;
            end
            if (line_valid) begin
                top_tail <= {line_x == 0 ? 1'b0 : top_tail[0],top_now};
                mid_tail <= {line_x == 0 ? 1'b0 : mid_tail[0],mid_now};
                bot_tail <= {line_x == 0 ? 1'b0 : bot_tail[0],bot_now};
            end
        end
    end

    wire [2:0] top_window = {top_tail,top_now};
    wire [2:0] mid_window = {mid_tail,mid_now};
    wire [2:0] bot_window = {bot_tail,bot_now};
    wire [1:0] top_votes = {1'b0,top_window[0]} +
        {1'b0,top_window[1]} + {1'b0,top_window[2]};
    wire [1:0] mid_votes = {1'b0,mid_window[0]} +
        {1'b0,mid_window[1]} + {1'b0,mid_window[2]};
    wire [1:0] bot_votes = {1'b0,bot_window[0]} +
        {1'b0,bot_window[1]} + {1'b0,bot_window[2]};
    wire [3:0] votes = {2'd0,top_votes} + {2'd0,mid_votes} + {2'd0,bot_votes};
    wire left_hit = top_window[2] || mid_window[2] || bot_window[2];
    wire middle_hit = top_window[1] || mid_window[1] || bot_window[1];
    wire right_hit = top_window[0] || mid_window[0] || bot_window[0];
    reg filter_valid, filter_first, filter_last, filter_eligible;
    reg filter_hit, filter_raw_hit, filter_supported, filter_rising;
    reg [COL_BITS-1:0] filter_xmin, filter_xmax;
    reg [BLOCK_ROW_BITS-1:0] filter_ymin, filter_ymax;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            filter_valid <= 0; filter_first <= 0; filter_last <= 0;
            filter_eligible <= 0; filter_hit <= 0; filter_raw_hit <= 0;
            filter_supported <= 0; filter_rising <= 0;
            filter_xmin <= 0; filter_xmax <= 0;
            filter_ymin <= 0; filter_ymax <= 0;
        end else begin
            filter_valid <= line_valid;
            if (line_valid) begin
                filter_first <= line_first; filter_last <= line_last;
                filter_eligible <= line_eligible;
                filter_raw_hit <= bot_now;
                filter_rising <= bot_rising;
                filter_hit <= line_x >= 2 && line_y >= 2 && votes >= 3;
                // Count each supported center once; unrelated raw speckles
                // must not satisfy the stable result's minimum support.
                filter_supported <= line_x >= 2 && line_y >= 2 &&
                    mid_window[1] && votes >= 3;
                filter_xmin <= left_hit ? line_x - 2'd2 :
                    middle_hit ? line_x - 1'b1 : line_x;
                filter_xmax <= right_hit ? line_x :
                    middle_hit ? line_x - 1'b1 : line_x - 2'd2;
                filter_ymin <= (|top_window) ? line_y - 2'd2 :
                    (|mid_window) ? line_y - 1'b1 : line_y;
                filter_ymax <= (|bot_window) ? line_y :
                    (|mid_window) ? line_y - 1'b1 : line_y - 2'd2;
            end
        end
    end

    reg [COUNT_BITS-1:0] count, supported_count, rising_count;
    reg have_box;
    reg [COL_BITS-1:0] xmin, xmax;
    reg [BLOCK_ROW_BITS-1:0] ymin, ymax;
    wire [COUNT_BITS-1:0] count_next =
        (filter_first ? {COUNT_BITS{1'b0}} : count) + filter_raw_hit;
    wire [COUNT_BITS-1:0] supported_next =
        (filter_first ? {COUNT_BITS{1'b0}} : supported_count) + filter_supported;
    wire [COUNT_BITS-1:0] rising_next =
        (filter_first ? {COUNT_BITS{1'b0}} : rising_count) +
        (filter_raw_hit && filter_rising);
    wire widespread_light_change = count_next >= LIGHT_CHANGE_BLOCKS &&
        (rising_next <= (count_next >> 3) ||
         rising_next >= count_next - (count_next >> 3));
    wire have_box_next = (filter_first ? 1'b0 : have_box) || filter_hit;
    wire [COL_BITS-1:0] xmin_next = filter_first ?
        (filter_hit ? filter_xmin : COLS-1) :
        (filter_hit && filter_xmin < xmin ? filter_xmin : xmin);
    wire [COL_BITS-1:0] xmax_next = filter_first ?
        (filter_hit ? filter_xmax : 0) :
        (filter_hit && filter_xmax > xmax ? filter_xmax : xmax);
    wire [BLOCK_ROW_BITS-1:0] ymin_next = filter_first ?
        (filter_hit ? filter_ymin : ROWS-1) :
        (filter_hit && filter_ymin < ymin ? filter_ymin : ymin);
    wire [BLOCK_ROW_BITS-1:0] ymax_next = filter_first ?
        (filter_hit ? filter_ymax : 0) :
        (filter_hit && filter_ymax > ymax ? filter_ymax : ymax);
    reg snapshot_valid, snapshot_found, snapshot_scene_change;
    reg [COUNT_BITS-1:0] snapshot_count, snapshot_supported;
    reg [COL_BITS-1:0] snapshot_xmin, snapshot_xmax;
    reg [BLOCK_ROW_BITS-1:0] snapshot_ymin, snapshot_ymax;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            count <= 0; supported_count <= 0; rising_count <= 0; have_box <= 0;
            xmin <= COLS-1; xmax <= 0; ymin <= ROWS-1; ymax <= 0;
            snapshot_valid <= 0; snapshot_found <= 0; snapshot_count <= 0;
            snapshot_supported <= 0; snapshot_scene_change <= 0;
            snapshot_xmin <= 0; snapshot_xmax <= 0;
            snapshot_ymin <= 0; snapshot_ymax <= 0;
        end else begin
            snapshot_valid <= filter_valid && filter_last;
            if (filter_valid) begin
                count <= count_next;
                supported_count <= supported_next;
                rising_count <= rising_next;
                have_box <= have_box_next;
                xmin <= xmin_next; xmax <= xmax_next;
                ymin <= ymin_next; ymax <= ymax_next;
                if (filter_last) begin
                    snapshot_found <= filter_eligible && have_box_next &&
                        count_next >= MIN_BLOCKS && count_next < MAX_CHANGED_BLOCKS;
                    snapshot_count <= count_next;
                    snapshot_supported <= supported_next;
                    snapshot_scene_change <= !filter_eligible ||
                        count_next >= MAX_CHANGED_BLOCKS || widespread_light_change;
                    snapshot_xmin <= xmin_next; snapshot_xmax <= xmax_next;
                    snapshot_ymin <= ymin_next; snapshot_ymax <= ymax_next;
                end
            end
        end
    end

    wire [COL_BITS:0] center_x_sum =
        {1'b0,snapshot_xmin} + {1'b0,snapshot_xmax};
    wire [BLOCK_ROW_BITS:0] center_y_sum =
        {1'b0,snapshot_ymin} + {1'b0,snapshot_ymax};
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_result_ready <= 0; O_found <= 0; O_frame_toggle <= 0;
            O_xmin <= 0; O_xmax <= 0; O_ymin <= 0; O_ymax <= 0;
            O_center_x <= 0; O_center_y <= 0; O_pixels <= 0;
            O_supported_blocks <= 0; O_scene_change <= 0;
        end else begin
            O_result_ready <= snapshot_valid;
            if (snapshot_valid) begin
                O_frame_toggle <= ~O_frame_toggle;
                O_found <= snapshot_found;
                O_pixels <= {snapshot_count,6'd0};
                O_supported_blocks <= snapshot_supported;
                O_scene_change <= snapshot_scene_change;
                O_xmin <= snapshot_found ? {snapshot_xmin,3'b000} : 12'd0;
                O_xmax <= snapshot_found ? {snapshot_xmax,3'b111} : 12'd0;
                O_ymin <= snapshot_found ? {snapshot_ymin,3'b000} : 12'd0;
                O_ymax <= snapshot_found ? {snapshot_ymax,3'b111} : 12'd0;
                O_center_x <= snapshot_found ? {center_x_sum,2'b00} + 12'd3 : 12'd0;
                O_center_y <= snapshot_found ? {center_y_sum,2'b00} + 12'd3 : 12'd0;
            end
        end
    end

    // synthesis translate_off
    initial begin
        if (IMG_WIDTH < 24 || IMG_HEIGHT < 24 ||
            IMG_WIDTH > 4096 || IMG_HEIGHT > 4096 ||
            IMG_WIDTH % 8 != 0 || IMG_HEIGHT % 8 != 0)
            $fatal(1, "Motion detection requires dimensions divisible by eight, 24..4096");
        if (DIFF_THRESHOLD < 1 || DIFF_THRESHOLD > 255 ||
            MIN_BLOCKS < 1 || MIN_BLOCKS > BLOCKS ||
            GLOBAL_CHANGE_PERCENT < 1 || GLOBAL_CHANGE_PERCENT > 100)
            $fatal(1, "Motion detection thresholds are outside the supported range");
    end
    // synthesis translate_on
endmodule
