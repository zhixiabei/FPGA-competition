// Small fixed-point CNN engine -- address-generation rework of cnn_infer_32.
//
// Behaviour-preserving re-implementation. The datapath, the weight tables,
// the 72-tap issue cadence and the reset/advance policy are unchanged. Only
// the address arithmetic was restructured:
//
//   * c1_k / c2_k are still the tap counters, but the /3, %3, /9 and %9
//     constant dividers that fed the read address are gone. Parallel
//     (ky,kx) / (ic,ky,kx) counters advance in lockstep with the tap counter
//     and are used only where the decomposition is needed.
//   * the read addresses are assembled from register slices plus one small
//     sign-extended tap offset, instead of 32-bit `integer` multiply-adds.
//     {ic,y,x} is pure wiring because each field is narrower than its stride.
//   * the wide 0..31 range compares behind the zero padding become edge tests.
//
// cnn_infer_32 is the production implementation; sim/tb_cnn_infer_32.sv
// checks that both produce identical O_class / O_busy / O_overrun every clock
// across several complete inferences.
module cnn_infer_32_opt #(
    parameter integer IMG_WIDTH = 1280,
    parameter integer IMG_HEIGHT = 720,
    parameter integer ROI_X = 512,
    parameter integer ROI_Y = 232,
    parameter integer C1_SHIFT = 8,
    parameter integer C2_SHIFT = 9
) (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_tuser,
    input  wire        I_tlast,
    input  wire        I_tvalid,
    input  wire [95:0] I_tdata,
    output reg         O_result_valid,
    output reg  [2:0]  O_class,
    output reg         O_busy,
    output reg         O_overrun
);
    localparam integer PIXELS = 1024;
    localparam integer C1_WORDS = 8*PIXELS;
    localparam integer FRAME_LAST_X = IMG_WIDTH/4-1;
    localparam integer FRAME_LAST_Y = IMG_HEIGHT-1;
    localparam integer C2_BIAS_SHIFT = 7-C1_SHIFT;
    localparam integer FC_BIAS_SHIFT = 24-C1_SHIFT-C2_SHIFT;

    // Declared before first use: some tools reject a function referenced by an
    // instantiation that appears above its declaration.
    function [7:0] relu_q7;
        input signed [31:0] value;
        input integer       shift;
        reg signed [31:0] q;
        begin
            q = value >>> shift;
            if (q < 0) relu_q7 = 8'd0;
            else if (q > 127) relu_q7 = 8'd127;
            else relu_q7 = q[7:0];
        end
    endfunction

    function signed [31:0] scale_bias;
        input signed [31:0] value;
        input integer shift;
        begin
            if (shift >= 0) scale_bias = value <<< shift;
            else scale_bias = value >>> (-shift);
        end
    endfunction

    reg [16:0] pool_sum [0:15];
    wire [16:0] feat_mem [0:15];
    genvar feature_index;
    generate
        for (feature_index=0; feature_index<16; feature_index=feature_index+1) begin : g_feature
            assign feat_mem[feature_index] = pool_sum[feature_index];
        end
    endgenerate

    reg capture_buf;
    reg infer_buf;
    reg completed_buf;
    reg frame_toggle;
    reg frame_toggle_d;
    reg [8:0] beat_x;
    reg [9:0] row_y;
    reg frame_seen;
    reg capture_frame_bad;
    reg capture_frame_enabled;
    reg capture_drop;

    function [7:0] gray_pixel;
        input [23:0] rgb;
        reg [9:0] sum;
        begin
            sum = {2'd0,rgb[23:16]} +
                  {1'd0,rgb[15:8],1'd0} + {2'd0,rgb[7:0]};
            gray_pixel = sum[9:2];
        end
    endfunction

    wire [8:0] cur_beat_x = I_tuser ? 9'd0 : beat_x;
    wire [9:0] cur_row_y = I_tuser ? 10'd0 : row_y;
    wire [11:0] lane_x0 = {cur_beat_x,2'b00};
    wire [11:0] lane_x1 = lane_x0 + 12'd1;
    wire [11:0] lane_x2 = lane_x0 + 12'd2;
    wire [11:0] lane_x3 = lane_x0 + 12'd3;
    wire [23:0] rgb0 = I_tdata[95:72];
    wire [23:0] rgb1 = I_tdata[71:48];
    wire [23:0] rgb2 = I_tdata[47:24];
    wire [23:0] rgb3 = I_tdata[23:0];

    function sample_pixel;
        input [11:0] x;
        input [9:0] y;
        begin
            sample_pixel = (x >= ROI_X) && (x < ROI_X+256) &&
                           (y >= ROI_Y) && (y < ROI_Y+256) &&
                           (((x-ROI_X) & 12'd7) == 0) &&
                           (((y-ROI_Y) & 10'd7) == 0);
        end
    endfunction

    wire sample0 = I_tvalid && sample_pixel(lane_x0,cur_row_y);
    wire sample1 = I_tvalid && sample_pixel(lane_x1,cur_row_y);
    wire sample2 = I_tvalid && sample_pixel(lane_x2,cur_row_y);
    wire sample3 = I_tvalid && sample_pixel(lane_x3,cur_row_y);
    // In-ROI rows/columns span 0..31 after the 8x downsample, so five bits each
    // are enough and the capture pointer becomes a plain concatenation.
    wire [4:0] sample_row = (cur_row_y-ROI_Y) >> 3;
    wire [4:0] sample_col0 = (lane_x0-ROI_X) >> 3;
    wire [4:0] sample_col1 = (lane_x1-ROI_X) >> 3;
    wire [4:0] sample_col2 = (lane_x2-ROI_X) >> 3;
    wire [4:0] sample_col3 = (lane_x3-ROI_X) >> 3;
    wire capture_valid = I_tvalid && (frame_seen || I_tuser);
    wire capture_line_clean = (I_tlast == (cur_beat_x == FRAME_LAST_X));
    wire capture_frame_clean = (I_tuser || !capture_frame_bad) && capture_line_clean;
    wire capture_enabled = I_tuser ?
        (!O_busy || capture_buf != infer_buf) : capture_frame_enabled;
    wire input_wr_valid = capture_valid && capture_enabled &&
                          (sample0 || sample1 || sample2 || sample3);
    wire [10:0] input_wr_addr = {capture_buf, sample_row,
                                 sample0 ? sample_col0 :
                                 sample1 ? sample_col1 :
                                 sample2 ? sample_col2 : sample_col3};
    wire [7:0] input_wr_data = sample0 ? (gray_pixel(rgb0) >> 1) :
                                sample1 ? (gray_pixel(rgb1) >> 1) :
                                sample2 ? (gray_pixel(rgb2) >> 1) :
                                          (gray_pixel(rgb3) >> 1);

    // Decide bank ownership at SOF. A frame that would overwrite inference's
    // bank is dropped in full, even if inference finishes partway through it.
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            capture_buf <= 1'b0;
            completed_buf <= 1'b0;
            frame_toggle <= 1'b0;
            beat_x <= 9'd0;
            row_y <= 10'd0;
            frame_seen <= 1'b0;
            capture_frame_bad <= 1'b0;
            capture_frame_enabled <= 1'b0;
            capture_drop <= 1'b0;
        end else begin
            capture_drop <= 1'b0;
            if (I_tuser) begin
                frame_seen <= 1'b1;
                capture_frame_bad <= 1'b0;
                capture_frame_enabled <= !O_busy || capture_buf != infer_buf;
                beat_x <= 9'd0;
                row_y <= 10'd0;
            end
            // AXI4-Stream may assert SOF together with the first valid beat.
            // Accept that beat immediately instead of waiting one cycle.
            if (capture_valid) begin
                capture_frame_bad <= !capture_frame_clean;
                if (I_tlast) begin
                    beat_x <= 9'd0;
                    if (cur_row_y == FRAME_LAST_Y) begin
                        row_y <= 10'd0;
                        frame_seen <= 1'b0;
                        if (capture_enabled && capture_frame_clean) begin
                            completed_buf <= capture_buf;
                            capture_buf <= ~capture_buf;
                            frame_toggle <= ~frame_toggle;
                        end else begin
                            capture_drop <= 1'b1;
                        end
                    end else begin
                        row_y <= cur_row_y + 10'd1;
                    end
                end else begin
                    beat_x <= cur_beat_x + 9'd1;
                end
            end
        end
    end

    localparam [3:0] ST_IDLE = 4'd0, ST_C1 = 4'd1, ST_C2 = 4'd2,
                     ST_FC = 4'd3;
    reg [3:0] state;

    reg [2:0] c1_oc;
    reg [4:0] c1_x, c1_y;
    reg [3:0] c1_k;            // tap counter, 0..8
    reg [1:0] c1_ky, c1_kx;    // c1_k decomposition, advance in lockstep
    reg signed [7:0] c1_weight_rd;
    reg c1_rd_valid, c1_rd_in_map, c1_rd_first, c1_rd_last;
    reg c1_issue_done;
    reg signed [31:0] acc;

    reg [4:0] c2_oc;
    reg [4:0] c2_x, c2_y;
    reg [6:0] c2_k;            // tap counter, 0..71
    reg [2:0] c2_ic;           // c2_k decomposition, advance in lockstep
    reg [1:0] c2_ky, c2_kx;
    reg signed [7:0] c2_weight_rd;
    reg c2_rd_valid, c2_rd_in_map, c2_rd_first, c2_rd_last;
    // Align metadata to the synchronous RAM response before registering the
    // product; neither the read nor the multiply shares the accumulator cycle.
    reg signed [31:0] c2_product_pipe;
    reg signed [31:0] c2_bias_pipe;
    reg                c2_pipe_valid;
    reg                c2_pipe_first;
    reg                c2_pipe_last;
    reg                c2_issue_done;

    reg [2:0] fc_class;
    reg [4:0] fc_k;
    reg signed [31:0] best_logit;
    reg [2:0] best_class;

    wire signed [7:0] w1_data, w2_data, wf_data;
    wire signed [31:0] b1_data, b2_data, bf_data;
    wire [7:0] input_rd_data;
    wire [7:0] conv1_rd_data;

    // ---- weight / bias pointers -------------------------------------------
    // w1_addr = c1_oc*9 + c1_k, w2_addr = c2_oc*72 + c2_k. Both are a shift-add
    // of two narrow registers, and wf_addr = fc_class*16 + fc_k is pure wiring.
    wire [6:0]  w1_addr = {1'b0,c1_oc,3'b0} + {1'b0,c1_oc} + {3'd0,c1_k};
    wire [10:0] w2_addr = {c2_oc,6'd0} + {c2_oc,3'd0} + {4'd0,c2_k};
    wire [6:0]  wf_addr = {fc_class,fc_k[3:0]};
    wire [3:0]  b1_addr = {1'b0,c1_oc};
    wire [4:0]  b2_addr = c2_oc;
    wire [2:0]  bf_addr = fc_class;

    // ---- read address ------------------------------------------------------
    // The stride of y is 32 and of x is 1, so a tap sits at
    // (ky-1)*32 + (kx-1) = ky*32 + kx - 33, which fits in a signed byte.
    wire signed [7:0] c1_tap_off = $signed({6'd0,c1_ky}) * 8'sd32
                                 + $signed({6'd0,c1_kx}) - 8'sd33;
    wire signed [7:0] c2_tap_off = $signed({6'd0,c2_ky}) * 8'sd32
                                 + $signed({6'd0,c2_kx}) - 8'sd33;

    // x and y never reach their stride, so {y,x} needs no adder and ic simply
    // occupies the bits above it.
    wire [10:0] c1_base = {infer_buf, c1_y, c1_x};
    wire [12:0] c2_base = {c2_ic, c2_y, c2_x};

    wire signed [11:0] c1_base_s = {1'b0, c1_base};
    wire signed [11:0] c1_off_s  = {{4{c1_tap_off[7]}}, c1_tap_off};
    wire signed [13:0] c2_base_s = {1'b0, c2_base};
    wire signed [13:0] c2_off_s  = {{6{c2_tap_off[7]}}, c2_tap_off};
    wire [11:0] c1_addr_sum = c1_base_s + c1_off_s;
    wire [13:0] c2_addr_sum = c2_base_s + c2_off_s;

    // A tap leaves the zero-padded 32x32 map only on the four edges, so the
    // 0..31 range compares become two-bit edge tests.
    wire c1_in_map = !((c1_x == 5'd0  && c1_kx == 2'd0) ||
                       (c1_x == 5'd31 && c1_kx == 2'd2) ||
                       (c1_y == 5'd0  && c1_ky == 2'd0) ||
                       (c1_y == 5'd31 && c1_ky == 2'd2));
    wire c2_in_map = !((c2_x == 5'd0  && c2_kx == 2'd0) ||
                       (c2_x == 5'd31 && c2_kx == 2'd2) ||
                       (c2_y == 5'd0  && c2_ky == 2'd0) ||
                       (c2_y == 5'd31 && c2_ky == 2'd2));

    wire [10:0] input_rd_addr  = c1_in_map ? c1_addr_sum[10:0] : 11'd0;
    wire [12:0] conv1_rd_addr  = c2_in_map ? c2_addr_sum[12:0] : 13'd0;
    wire signed [7:0] c1_in_data = c1_rd_in_map ? $signed(input_rd_data)  : 8'sd0;
    wire signed [7:0] c2_in_data = c2_rd_in_map ? $signed(conv1_rd_data) : 8'sd0;

    wire signed [31:0] c1_product = c1_in_data * c1_weight_rd;
    wire signed [31:0] c2_product = c2_in_data * c2_weight_rd;
    wire signed [31:0] fc_product = $signed({1'b0,pool_sum[fc_k]}) * wf_data;
    wire signed [31:0] c1_sum_next = (c1_rd_first ? b1_data : acc) + c1_product;
    wire signed [31:0] fc_sum_next =
        (fc_k == 0 ? scale_bias(bf_data, FC_BIAS_SHIFT) : acc) + fc_product;
    wire signed [31:0] c2_pipe_sum_next =
        (c2_pipe_first ? c2_bias_pipe : acc) + c2_product_pipe;
    wire conv1_wr_valid = (state == ST_C1) && c1_rd_valid && c1_rd_last;
    wire [12:0] conv1_wr_addr = {c1_oc, c1_y, c1_x};
    wire [7:0] conv1_wr_data = relu_q7(c1_sum_next, C1_SHIFT);
    wire conv2_result_valid = (state == ST_C2) && c2_pipe_valid && c2_pipe_last;
    wire [13:0] conv2_result_addr = {c2_oc[3:0], c2_y, c2_x};
    wire [7:0] conv2_result_data = relu_q7(c2_pipe_sum_next, C2_SHIFT);
    wire [17:0] c2_pool_sum_next =
        {1'b0,pool_sum[c2_oc]} + {10'd0,conv2_result_data};

    cnn_eram_byte_dp #(.ADDR_WIDTH(11), .DATA_DEPTH(2048)) u_input_mem (
        .I_clk(I_clk), .I_wr_en(input_wr_valid), .I_wr_addr(input_wr_addr),
        .I_wr_data(input_wr_data), .I_rd_addr(input_rd_addr),
        .O_rd_data(input_rd_data)
    );

    cnn_eram_byte_dp #(.ADDR_WIDTH(13), .DATA_DEPTH(C1_WORDS)) u_conv1_mem (
        .I_clk(I_clk), .I_wr_en(conv1_wr_valid),
        .I_wr_addr(conv1_wr_addr),
        .I_wr_data(conv1_wr_data),
        .I_rd_addr(conv1_rd_addr),
        .O_rd_data(conv1_rd_data)
    );

    cnn_weights u_weights (
        .I_w1_addr(w1_addr), .I_w2_addr(w2_addr), .I_wf_addr(wf_addr),
        .I_b1_addr(b1_addr), .I_b2_addr(b2_addr), .I_bf_addr(bf_addr),
        .O_w1(w1_data), .O_w2(w2_data), .O_wf(wf_data),
        .O_b1(b1_data), .O_b2(b2_data), .O_bf(bf_data)
    );

    integer init_i;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            frame_toggle_d <= 1'b0;
            state <= ST_IDLE;
            infer_buf <= 1'b0;
            c1_oc <= 0; c1_x <= 0; c1_y <= 0; c1_k <= 0;
            c1_ky <= 0; c1_kx <= 0;
            c1_weight_rd <= 0;
            c1_rd_valid <= 1'b0; c1_rd_in_map <= 1'b0;
            c1_rd_first <= 1'b0; c1_rd_last <= 1'b0;
            c1_issue_done <= 1'b0;
            c2_oc <= 0; c2_x <= 0; c2_y <= 0; c2_k <= 0;
            c2_ic <= 0; c2_ky <= 0; c2_kx <= 0;
            c2_weight_rd <= 0;
            c2_rd_valid <= 1'b0; c2_rd_in_map <= 1'b0;
            c2_rd_first <= 1'b0; c2_rd_last <= 1'b0;
            c2_product_pipe <= 0;
            c2_bias_pipe <= 0;
            c2_pipe_valid <= 1'b0;
            c2_pipe_first <= 1'b0;
            c2_pipe_last <= 1'b0;
            c2_issue_done <= 1'b0;
            fc_class <= 0; fc_k <= 0;
            acc <= 0; best_logit <= 32'sh80000000; best_class <= 0;
            O_result_valid <= 1'b0;
            O_class <= 3'd1;
            O_busy <= 1'b0;
            O_overrun <= 1'b0;
            for (init_i=0; init_i<16; init_i=init_i+1) begin
                pool_sum[init_i] <= 0;
            end
        end else begin
            O_result_valid <= 1'b0;
            frame_toggle_d <= frame_toggle;
            if (capture_drop)
                O_overrun <= 1'b1;
            if (frame_toggle != frame_toggle_d) begin
                if (O_busy) O_overrun <= 1'b1;
                else begin
                    infer_buf <= completed_buf;
                    state <= ST_C1;
                    O_busy <= 1'b1;
                    c1_oc <= 0; c1_x <= 0; c1_y <= 0; c1_k <= 0;
                    c1_ky <= 0; c1_kx <= 0;
                    c1_rd_valid <= 1'b0;
                    c1_issue_done <= 1'b0;
                    O_overrun <= 1'b0;
                end
            end

            case (state)
                ST_C1: begin
                    c1_rd_valid <= 1'b0;
                    if (!c1_issue_done) begin
                        c1_weight_rd <= w1_data;
                        c1_rd_in_map <= c1_in_map;
                        c1_rd_first <= (c1_k == 0);
                        c1_rd_last <= (c1_k == 8);
                        c1_rd_valid <= 1'b1;
                        if (c1_k == 8) c1_issue_done <= 1'b1;
                        else begin
                            c1_k <= c1_k + 4'd1;
                            if (c1_kx == 2'd2) begin
                                c1_kx <= 2'd0;
                                c1_ky <= c1_ky + 2'd1;
                            end else c1_kx <= c1_kx + 2'd1;
                        end
                    end
                    if (c1_rd_valid) begin
                        if (c1_rd_last) begin
                            c1_k <= 0;
                            c1_ky <= 0;
                            c1_kx <= 0;
                            c1_issue_done <= 1'b0;
                            if (c1_x == 5'd31) begin
                                c1_x <= 0;
                                if (c1_y == 5'd31) begin
                                    c1_y <= 0;
                                    if (c1_oc == 3'd7) begin
                                        c2_oc <= 0; c2_x <= 0; c2_y <= 0; c2_k <= 0;
                                        c2_ic <= 0; c2_ky <= 0; c2_kx <= 0;
                                        c2_rd_valid <= 1'b0;
                                        c2_pipe_valid <= 1'b0;
                                        c2_issue_done <= 1'b0;
                                        for (init_i=0; init_i<16; init_i=init_i+1)
                                            pool_sum[init_i] <= 0;
                                        state <= ST_C2;
                                    end else c1_oc <= c1_oc + 1'b1;
                                end else c1_y <= c1_y + 1'b1;
                            end else c1_x <= c1_x + 1'b1;
                        end else begin
                            acc <= c1_sum_next;
                        end
                    end
                end
                ST_C2: begin
                    c2_rd_valid <= 1'b0;
                    c2_pipe_valid <= c2_rd_valid;
                    if (!c2_issue_done) begin
                        c2_weight_rd <= w2_data;
                        c2_rd_in_map <= c2_in_map;
                        c2_rd_first <= (c2_k == 0);
                        c2_rd_last <= (c2_k == 71);
                        c2_rd_valid <= 1'b1;
                        if (c2_k == 71)
                            c2_issue_done <= 1'b1;
                        else begin
                            c2_k <= c2_k + 7'd1;
                            if (c2_kx == 2'd2) begin
                                c2_kx <= 2'd0;
                                if (c2_ky == 2'd2) begin
                                    c2_ky <= 2'd0;
                                    c2_ic <= c2_ic + 3'd1;
                                end else c2_ky <= c2_ky + 2'd1;
                            end else c2_kx <= c2_kx + 2'd1;
                        end
                    end
                    if (c2_rd_valid) begin
                        c2_product_pipe <= c2_product;
                        c2_bias_pipe <= scale_bias(b2_data, C2_BIAS_SHIFT);
                        c2_pipe_first <= c2_rd_first;
                        c2_pipe_last <= c2_rd_last;
                    end
                    if (c2_pipe_valid) begin
                        if (c2_pipe_last) begin
                            pool_sum[c2_oc] <= c2_pool_sum_next[16:0];
                            c2_pipe_valid <= 1'b0;
                            c2_pipe_first <= 1'b0;
                            c2_pipe_last <= 1'b0;
                            c2_issue_done <= 1'b0;
                            c2_k <= 0;
                            c2_ic <= 0; c2_ky <= 0; c2_kx <= 0;
                            if (c2_x == 5'd31) begin
                                c2_x <= 0;
                                if (c2_y == 5'd31) begin
                                    c2_y <= 0;
                                    if (c2_oc == 5'd15) begin
                                        fc_class <= 0; fc_k <= 0;
                                        best_logit <= 32'sh80000000; best_class <= 0;
                                        state <= ST_FC;
                                    end else c2_oc <= c2_oc + 1'b1;
                                end else c2_y <= c2_y + 1'b1;
                            end else c2_x <= c2_x + 1'b1;
                        end else begin
                            acc <= c2_pipe_sum_next;
                        end
                    end
                end
                ST_FC: begin
                    if (fc_k == 5'd15) begin
                        if (fc_class == 3'd0 || fc_sum_next > best_logit) begin
                            best_logit <= fc_sum_next;
                            best_class <= fc_class;
                        end
                        fc_k <= 0;
                        if (fc_class == 3'd4) begin
                            O_class <= (fc_sum_next > best_logit) ? fc_class : best_class;
                            O_result_valid <= 1'b1;
                            O_busy <= 1'b0;
                            state <= ST_IDLE;
                        end else fc_class <= fc_class + 1'b1;
                    end else begin
                        acc <= fc_sum_next;
                        fc_k <= fc_k + 1'b1;
                    end
                end
                default: begin end
            endcase
        end
    end
endmodule
