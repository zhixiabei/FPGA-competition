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
    parameter integer CLIP_LEVEL = 192,
    parameter integer BRIGHT_LEVEL = CLIP_LEVEL,
    parameter integer HISTOGRAM_ENABLE = 0,
    parameter integer HIST_BIN_BITS = 5,
    parameter integer HOLD_OUTPUTS = 1
) (
    input wire I_clk,
    input wire I_rst_n,
    input wire I_tuser,
    input wire I_tlast,
    input wire I_tvalid,
    input wire [39:0] I_tdata,
    output reg O_stats_valid,
    output wire [31:0] O_sum_y,
    output wire [15:0] O_sample_count,
    output wire [15:0] O_bright_count,
    output wire [4:0] O_p95,
    output wire [4:0] O_p5, O_p50, O_p99,
    output wire [15:0] O_clip_count
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
    localparam integer LAST_SAMPLE_ROW=((IMG_HEIGHT-1)/ROW_PERIOD)*ROW_PERIOD +
        (((IMG_HEIGHT-1)%ROW_PERIOD)>0 ? 1 : 0);
    localparam integer LAST_SAMPLE_GROUP=((GROUPS-1)/GROUP_PERIOD)*GROUP_PERIOD;
    localparam integer TAIL_CLOCKS=(IMG_HEIGHT-1-LAST_SAMPLE_ROW)*GROUPS +
        GROUPS-1-LAST_SAMPLE_GROUP;
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
    reg [COUNT_BITS-1:0] clip_count;

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
    wire bright0 = value0 >= BRIGHT_LEVEL;
    wire bright1 = value1 >= BRIGHT_LEVEL;
    wire bright2 = value2 >= BRIGHT_LEVEL;
    wire bright3 = value3 >= BRIGHT_LEVEL;
    wire [7:0] meter0 = value0 >= CLIP_LEVEL ? CLIP_LEVEL : value0;
    wire [7:0] meter1 = value1 >= CLIP_LEVEL ? CLIP_LEVEL : value1;
    wire [7:0] meter2 = value2 >= CLIP_LEVEL ? CLIP_LEVEL : value2;
    wire [7:0] meter3 = value3 >= CLIP_LEVEL ? CLIP_LEVEL : value3;
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
    wire [2:0] beat_clip = {2'd0,raw0==1023} + {2'd0,raw1==1023} +
                           {2'd0,raw2==1023} + {2'd0,raw3==1023};
    wire [COUNT_BITS-1:0] clip_next =
        (first_beat ? {COUNT_BITS{1'b0}} : clip_count) +
        (sample_beat ? beat_clip : 3'd0);
    wire hist_ready;
    wire [4:0] hist_p5, hist_p50, hist_p95, hist_p99;
    generate if (HISTOGRAM_ENABLE != 0) begin : histogram
        // Six unsampled tail rows in the production frame allow a single
        // bank to be scanned and cleared before the next SOF. No blanking
        // assumption, no video stalls and no extra frame RAM.
        ae_raw_histogram #(.BIN_BITS(HIST_BIN_BITS), .COUNT_BITS(COUNT_BITS),
            .SAMPLE_TOTAL(SAMPLE_TOTAL)) u_histogram (
            .I_clk(I_clk), .I_rst_n(I_rst_n),
            .I_start(accept_beat && first_beat),
            .I_take(accept_beat && sample_beat),
            .I_last(count_next == SAMPLE_TOTAL),
            .I_raw({signal3,signal2,signal1,signal0}),
            .O_ready(hist_ready), .O_p5(hist_p5), .O_p50(hist_p50),
            .O_p95(hist_p95), .O_p99(hist_p99));
    end else begin : no_histogram
        assign hist_ready = 1'b1;
        assign hist_p5=0, hist_p50=0, hist_p95=0, hist_p99=0;
    end endgenerate
    wire publish_frame = accept_beat && final_beat &&
        !(first_beat ? 1'b0 : frame_bad) && !bad_line_marker &&
        count_next == SAMPLE_TOTAL && hist_ready;

    generate if (HOLD_OUTPUTS != 0) begin : held_outputs
        reg [31:0] result_sum;
        reg [15:0] result_count, result_bright, result_clip;
        reg [4:0] result_p5, result_p50, result_p95, result_p99;
        always @(posedge I_clk or negedge I_rst_n) begin
            if (!I_rst_n) begin
                result_sum<=0; result_count<=0; result_bright<=0; result_clip<=0;
                result_p5<=0; result_p50<=0; result_p95<=0; result_p99<=0;
            end else if (publish_frame) begin
                result_sum<=sum_next;
                result_count<=SAMPLE_TOTAL;
                result_bright<=bright_next; result_clip<=clip_next;
                result_p5<=hist_p5; result_p50<=hist_p50;
                result_p95<=hist_p95; result_p99<=hist_p99;
            end
        end
        assign O_sum_y=result_sum;
        assign O_sample_count=result_count;
        assign O_bright_count=result_bright;
        assign O_clip_count=result_clip;
        assign O_p5=result_p5, O_p50=result_p50;
        assign O_p95=result_p95, O_p99=result_p99;
    end else begin : valid_outputs
        // The synchronous consumer captures only when O_stats_valid is high.
        // Accumulators contain the completed frame during that cycle, even
        // if a new SOF/first beat is captured on the consumer's same edge.
        // Values outside that valid cycle intentionally need not be held.
        assign O_sum_y=sum_y;
        assign O_sample_count=SAMPLE_TOTAL;
        assign O_bright_count=bright_count;
        assign O_clip_count=clip_count;
        assign O_p5=hist_p5, O_p50=hist_p50;
        assign O_p95=hist_p95, O_p99=hist_p99;
    end endgenerate

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
            clip_count <= 0;
            O_stats_valid <= 1'b0;
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
                clip_count <= clip_next;
                if (final_group) begin
                    group_pos <= {GROUP_BITS{1'b0}};
                    row_pos <= final_beat ? {ROW_BITS{1'b0}} : beat_row + 1'b1;
                end else begin
                    group_pos <= beat_group + 1'b1;
                    row_pos <= beat_row;
                end
                if (publish_frame) begin
                    O_stats_valid <= 1'b1;
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
        if (BRIGHT_LEVEL < 1 || BRIGHT_LEVEL > 255)
            $fatal(1, "AE bright threshold outside 1..255");
        if (HISTOGRAM_ENABLE && (SAMPLE_GROUP_LOG2 < 2 ||
            HIST_BIN_BITS < 3 || HIST_BIN_BITS > 5 || GROUPS%GROUP_PERIOD!=0 ||
            TAIL_CLOCKS < (1<<HIST_BIN_BITS)+5))
            $fatal(1, "Histogram needs >=4 clocks between groups and 8..32 bins");
    end
    // synthesis translate_on
endmodule

// Sparse four-component histogram with one asynchronous read/synchronous
// write port. Repeated addresses see the preceding clock's updated count.
// A premature SOF discards the unfinished histogram, clears it, and drops
// that frame's statistics; video continues. Ready qualifies complete sums.
module ae_raw_histogram #(
    parameter integer BIN_BITS=5, COUNT_BITS=15, SAMPLE_TOTAL=28800
) (
    input wire I_clk, I_rst_n, I_start, I_take, I_last,
    input wire [39:0] I_raw,
    output reg O_ready,
    output reg [4:0] O_p5, O_p50, O_p95, O_p99
);
    localparam integer BINS=1<<BIN_BITS;
    localparam [1:0] CLEAR=0, COLLECT=1, SCAN=2;
    reg [1:0] state;
    reg [BIN_BITS-1:0] address;
    reg [4*BIN_BITS-1:0] queue;
    reg [2:0] remaining;
    reg last_group, clean_bank, frame_ok;
    reg [COUNT_BITS:0] cumulative;
    (* ram_style="distributed" *) reg [COUNT_BITS-1:0] bucket_ram[0:BINS-1];
    wire [BIN_BITS-1:0] ram_address = state==COLLECT ? queue[BIN_BITS-1:0] : address;
    wire [COUNT_BITS-1:0] read_count = bucket_ram[ram_address];
    wire [COUNT_BITS:0] next_cumulative = cumulative + read_count;
    wire [4:0] bucket_code = (address << (5-BIN_BITS)) | ((1<<(5-BIN_BITS))-1);
    wire write_sample = state==COLLECT && remaining!=0;
    // Array is initialized by the sequential CLEAR state, not reset FFs.
    always @(posedge I_clk) begin
        if (I_rst_n && (state==CLEAR || state==SCAN || write_sample))
            bucket_ram[ram_address] <= write_sample ? read_count+1'b1 : 0;
    end
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            state<=CLEAR; address<=0; remaining<=0; queue<=0;
            last_group<=0; clean_bank<=0; frame_ok<=0; cumulative<=0;
            O_ready<=0; O_p5<=0; O_p50<=0; O_p95<=0; O_p99<=0;
        end else begin
            if (state==CLEAR) begin
                address<=address+1'b1;
                if (address==BINS-1) begin state<=COLLECT; clean_bank<=1; end
            end
            if (write_sample) begin
                queue<=queue>>BIN_BITS;
                remaining<=remaining-1'b1;
                if (remaining==1 && last_group) begin
                    state<=SCAN; address<=0; cumulative<=0;
                end
            end
            if (state==SCAN) begin
                cumulative<=next_cumulative;
                address<=address+1'b1;
                if (cumulative < (SAMPLE_TOTAL*5+99)/100 &&
                    next_cumulative >= (SAMPLE_TOTAL*5+99)/100) O_p5<=bucket_code;
                if (cumulative < (SAMPLE_TOTAL+1)/2 &&
                    next_cumulative >= (SAMPLE_TOTAL+1)/2) O_p50<=bucket_code;
                if (cumulative < (SAMPLE_TOTAL*95+99)/100 &&
                    next_cumulative >= (SAMPLE_TOTAL*95+99)/100) O_p95<=bucket_code;
                if (cumulative < (SAMPLE_TOTAL*99+99)/100 &&
                    next_cumulative >= (SAMPLE_TOTAL*99+99)/100) O_p99<=bucket_code;
                if (address==BINS-1) begin
                    state<=COLLECT; clean_bank<=1;
                    O_ready<=frame_ok && next_cumulative==SAMPLE_TOTAL;
                end
            end
            if (I_start) begin
                O_ready<=0;
                frame_ok<=clean_bank && state==COLLECT;
                if (!clean_bank || state!=COLLECT) begin
                    state<=CLEAR; address<=0; remaining<=0; clean_bank<=0;
                end
            end
            if (I_take && (I_start ? clean_bank && state==COLLECT : frame_ok)) begin
                if (state==COLLECT && (remaining==0 || remaining==1)) begin
                    queue<={I_raw[39 -: BIN_BITS],I_raw[29 -: BIN_BITS],
                            I_raw[19 -: BIN_BITS],I_raw[9 -: BIN_BITS]};
                    remaining<=4; last_group<=I_last; clean_bank<=0;
                end else begin
                    frame_ok<=0; O_ready<=0; state<=CLEAR;
                    address<=0; remaining<=0; clean_bank<=0;
                end
            end
        end
    end
endmodule
