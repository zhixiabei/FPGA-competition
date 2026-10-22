// Optional, CSI-clock diagnostic snapshots. These are NOT DDR/display-slot
// metadata. Every packet identifies its own source frame; never overlay it as
// if it described the currently displayed frame.
//
// Packet header: [127:124] kind, [123:122] channel, [121:112] source frame ID.
// Kinds 0 RAW, 1 LSC, 2 pre-WB RGB, 3 post-WB RGB:
// [111:96] count, [95:72] sum, [71:56] near-white count,
// [55:40] clip count. RAW/LSC have black-subtracted near count [39:24]
// and zero [23:0]; RGB has zero [39:0]. RAW/LSC near is >=992, RGB >=248.
// RAW/LSC channels: R=0, Gr=1, Gb=2, B=3. RGB: R=0, G=1, B=3.
// RAW clip means original code==1023; pre-WB clip is component==255.
// LSC/post-WB clip means the supplied
// internal arithmetic overflow event, NOT merely an output at the top code.
// Kind 4 histogram: [111:107] P5, [106:102] P50, [101:97] P95,
// [96:92] P99, [91:76] count, [75:60] near count, [59:44] RAW clip, rest zero.
// Kind 5 WB status: [111:101] frame-applied R gain, [100:90] B gain,
// [89] candidate state at statistics completion, [88:73] accepted samples.
// Candidate state is not an assertion that this frame's later divider result
// was accepted. WB sample count is read only with I_awb_stats_valid.
//
// A new complete snapshot may replace an undrained snapshot from the same
// stage. Individual packets remain atomic and tagged. There is no backpressure.
// RAW/LSC use the existing 1/8 groups and two rows/8 sampling (28800 samples
// at 720p). RGB uses one rotating lane per 16 valid groups (14400 samples).
module iq_diagnostic_stats #(
    parameter integer ENABLE = 0,
    parameter integer IMG_WIDTH = 1280,
    parameter integer IMG_HEIGHT = 720,
    parameter BAYER_MODE = "BGGR",
    parameter integer BLACK_LEVEL = 0
) (
    input wire I_clk, I_rst_n,
    input wire I_raw_valid, I_raw_user, I_raw_last,
    input wire [39:0] I_raw_data,
    input wire [9:0] I_raw_frame_id,
    input wire I_lsc_valid, I_lsc_user, I_lsc_last,
    input wire [39:0] I_lsc_data,
    input wire [3:0] I_lsc_clip_new,
    input wire [9:0] I_lsc_frame_id,
    input wire I_rgb_valid, I_rgb_user, I_rgb_last,
    input wire [95:0] I_rgb_data,
    input wire [9:0] I_rgb_frame_id,
    input wire I_awb_valid, I_awb_user, I_awb_last,
    input wire [95:0] I_awb_data,
    input wire [7:0] I_awb_clip_new,
    input wire [9:0] I_awb_frame_id,
    input wire [10:0] I_awb_gain_r_q8, I_awb_gain_b_q8,
    input wire I_awb_stats_valid, I_awb_candidate_valid,
    input wire [15:0] I_awb_sample_count,
    input wire I_hist_valid,
    input wire [9:0] I_hist_frame_id,
    input wire [4:0] I_hist_p5, I_hist_p50, I_hist_p95, I_hist_p99,
    input wire [15:0] I_hist_count, I_hist_near_count, I_hist_clip_count,
    output wire O_diag_valid,
    output wire [127:0] O_diag_data
);
    generate if (ENABLE != 0) begin : enabled
        wire [511:0] packets [0:3];
        wire [3:0] snapshot_valid;
        wire [10:0] frame_gain_r, frame_gain_b;
        wire [9:0] wb_frame_id;
        iq_diag_raw_bank #(
            .IMG_WIDTH(IMG_WIDTH), .IMG_HEIGHT(IMG_HEIGHT),
            .BAYER_MODE(BAYER_MODE), .BLACK_LEVEL(BLACK_LEVEL), .KIND(0)
        ) raw_bank (
            .I_clk(I_clk), .I_rst_n(I_rst_n), .I_valid(I_raw_valid),
            .I_user(I_raw_user), .I_last(I_raw_last), .I_data(I_raw_data),
            .I_clip_new(4'd0), .I_frame_id(I_raw_frame_id),
            .O_valid(snapshot_valid[0]), .O_packets(packets[0])
        );
        iq_diag_raw_bank #(
            .IMG_WIDTH(IMG_WIDTH), .IMG_HEIGHT(IMG_HEIGHT),
            .BAYER_MODE(BAYER_MODE), .BLACK_LEVEL(0), .KIND(1)
        ) lsc_bank (
            .I_clk(I_clk), .I_rst_n(I_rst_n), .I_valid(I_lsc_valid),
            .I_user(I_lsc_user), .I_last(I_lsc_last), .I_data(I_lsc_data),
            .I_clip_new(I_lsc_clip_new), .I_frame_id(I_lsc_frame_id),
            .O_valid(snapshot_valid[1]), .O_packets(packets[1])
        );
        iq_diag_rgb_bank #(
            .IMG_WIDTH(IMG_WIDTH), .IMG_HEIGHT(IMG_HEIGHT), .KIND(2)
        ) rgb_bank (
            .I_clk(I_clk), .I_rst_n(I_rst_n), .I_valid(I_rgb_valid),
            .I_user(I_rgb_user), .I_last(I_rgb_last), .I_data(I_rgb_data),
            .I_clip_new(8'd0), .I_frame_id(I_rgb_frame_id),
            .I_gain_r(11'd0), .I_gain_b(11'd0),
            .O_valid(snapshot_valid[2]), .O_packets(packets[2]),
            .O_gain_r(), .O_gain_b(), .O_frame_id()
        );
        iq_diag_rgb_bank #(
            .IMG_WIDTH(IMG_WIDTH), .IMG_HEIGHT(IMG_HEIGHT), .KIND(3)
        ) awb_bank (
            .I_clk(I_clk), .I_rst_n(I_rst_n), .I_valid(I_awb_valid),
            .I_user(I_awb_user), .I_last(I_awb_last), .I_data(I_awb_data),
            .I_clip_new(I_awb_clip_new), .I_frame_id(I_awb_frame_id),
            .I_gain_r(I_awb_gain_r_q8), .I_gain_b(I_awb_gain_b_q8),
            .O_valid(snapshot_valid[3]), .O_packets(packets[3]),
            .O_gain_r(frame_gain_r), .O_gain_b(frame_gain_b),
            .O_frame_id(wb_frame_id)
        );
        reg [5:0] pending;
        reg [1:0] packet_index [0:3];
        reg [127:0] histogram_packet, wb_packet;
        reg diag_valid;
        reg [127:0] diag_data;
        reg [9:0] last_wb_frame;
        reg wb_complete_pending;
        integer bank, selected, search;
        always @(*) begin
            selected = -1;
            for (search = 5; search >= 0; search = search - 1)
                if (pending[search]) selected = search;
        end
        always @(posedge I_clk or negedge I_rst_n) begin
            if (!I_rst_n) begin
                pending <= 0; diag_valid <= 0; diag_data <= 0;
                histogram_packet <= 0; wb_packet <= 0;
                last_wb_frame <= 0; wb_complete_pending <= 0;
                for (bank=0; bank<4; bank=bank+1) packet_index[bank] <= 0;
            end else begin
                diag_valid <= selected >= 0;
                if (selected >= 0 && selected < 4) begin
                    diag_data <= packets[selected][packet_index[selected]*128 +:128];
                    if (packet_index[selected] == (selected < 2 ? 3 : 2)) begin
                        pending[selected] <= 0;
                        packet_index[selected] <= 0;
                    end else packet_index[selected] <= packet_index[selected] + 1'b1;
                end else if (selected == 4) begin
                    diag_data <= histogram_packet; pending[4] <= 0;
                end else if (selected == 5) begin
                    diag_data <= wb_packet; pending[5] <= 0;
                end
                for (bank=0; bank<4; bank=bank+1)
                    if (snapshot_valid[bank]) begin
                        pending[bank] <= 1;
                        packet_index[bank] <= 0;
                    end
                if (snapshot_valid[3]) begin
                    last_wb_frame <= wb_frame_id;
                    wb_complete_pending <= 1;
                end
                // Stats-ready follows the two-clock math frame tail. A bad
                // or truncated math frame cannot lend its ID to a WB status.
                if (I_awb_stats_valid && wb_complete_pending) begin
                    wb_packet <= {4'd5,2'd0,last_wb_frame,frame_gain_r,frame_gain_b,
                        I_awb_candidate_valid,I_awb_sample_count,73'd0};
                    pending[5] <= 1;
                    wb_complete_pending <= 0;
                end
                if (I_hist_valid) begin
                    histogram_packet <= {4'd4,2'd0,I_hist_frame_id,
                        I_hist_p5,I_hist_p50,I_hist_p95,I_hist_p99,
                        I_hist_count,I_hist_near_count,I_hist_clip_count,44'd0};
                    pending[4] <= 1;
                end
            end
        end
        assign O_diag_valid = diag_valid;
        assign O_diag_data = diag_valid ? diag_data : 128'd0;
    end else begin : disabled
        assign O_diag_valid = 1'b0;
        assign O_diag_data = 128'd0;
    end endgenerate
endmodule

module iq_diag_raw_bank #(
    parameter integer IMG_WIDTH=1280, IMG_HEIGHT=720,
    parameter BAYER_MODE="BGGR",
    parameter integer BLACK_LEVEL=0, KIND=0
) (
    input wire I_clk, I_rst_n, I_valid, I_user, I_last,
    input wire [39:0] I_data,
    input wire [3:0] I_clip_new,
    input wire [9:0] I_frame_id,
    output reg O_valid,
    output reg [511:0] O_packets
);
    localparam integer GROUPS=IMG_WIDTH/4;
    localparam integer X_BITS=GROUPS>1 ? $clog2(GROUPS) : 1;
    localparam integer Y_BITS=IMG_HEIGHT>1 ? $clog2(IMG_HEIGHT) : 1;
    localparam integer SAMPLE_ROWS=(IMG_HEIGHT/8)*2 +
        (IMG_HEIGHT%8==0 ? 0 : IMG_HEIGHT%8==1 ? 1 : 2);
    localparam integer MAX_COUNT=((GROUPS+7)/8)*((SAMPLE_ROWS+1)/2)*2;
    localparam integer COUNT_BITS=$clog2(MAX_COUNT+1);
    localparam integer SUM_BITS=$clog2(MAX_COUNT*1023+1);
    localparam TOP_RED=BAYER_MODE=="RGGB" || BAYER_MODE=="GRBG";
    localparam TOP_GREEN_EVEN=BAYER_MODE=="GBRG" || BAYER_MODE=="GRBG";
    reg user_d, pending, active, bad;
    reg [9:0] frame_id, pending_id;
    reg [X_BITS-1:0] x;
    reg [Y_BITS-1:0] y;
    reg [COUNT_BITS-1:0] count[0:3], near_count[0:3], clips[0:3], black_near[0:3];
    reg [SUM_BITS-1:0] sums[0:3];
    reg [COUNT_BITS-1:0] count_next[0:3], near_next[0:3], clip_next[0:3], black_next[0:3];
    reg [SUM_BITS-1:0] sum_next[0:3];
    wire marker=I_user && !user_d;
    wire first=pending || marker;
    wire accept=I_valid && (active || first);
    wire [X_BITS-1:0] bx=first ? 0 : x;
    wire [Y_BITS-1:0] by=first ? 0 : y;
    wire final_group=bx==GROUPS-1;
    wire final_beat=final_group && by==IMG_HEIGHT-1;
    wire bad_line=I_last!=final_group;
    wire take=(bx%8)==0 && (by%8)<2;
    wire [9:0] beat_id=marker ? I_frame_id : first ? pending_id : frame_id;
    integer c, lane, colour;
    reg [9:0] raw, corrected;
    always @(*) begin
        for (c=0; c<4; c=c+1) begin
            count_next[c]=first ? 0 : count[c];
            near_next[c]=first ? 0 : near_count[c];
            clip_next[c]=first ? 0 : clips[c];
            black_next[c]=first ? 0 : black_near[c];
            sum_next[c]=first ? 0 : sums[c];
        end
        raw=0; corrected=0; colour=0;
        if (take) for (lane=0; lane<4; lane=lane+1) begin
            raw=I_data[10*lane +:10];
            corrected=raw>BLACK_LEVEL ? raw-BLACK_LEVEL : 10'd0;
            if ((lane%2)==((TOP_GREEN_EVEN ^ by[0]) ? 0 : 1))
                colour=(TOP_RED ^ by[0]) ? 1 : 2;
            else colour=(TOP_RED ^ by[0]) ? 0 : 3;
            count_next[colour]=count_next[colour]+1'b1;
            sum_next[colour]=sum_next[colour]+raw;
            near_next[colour]=near_next[colour]+(raw>=992);
            clip_next[colour]=clip_next[colour]+
                (KIND==0 ? raw==1023 : I_clip_new[lane]);
            black_next[colour]=black_next[colour]+(corrected>=992);
        end
    end
    function [127:0] packet;
        input [1:0] channel;
        input [9:0] tag;
        input [15:0] number, near_value, clip_value, black_value;
        input [23:0] total;
        begin packet={KIND[3:0],channel,tag,number,total,
            near_value,clip_value,black_value,24'd0}; end
    endfunction
    integer k;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            user_d<=0; pending<=0; active<=0; bad<=0;
            x<=0; y<=0; frame_id<=0; pending_id<=0;
            O_valid<=0; O_packets<=0;
            for (k=0; k<4; k=k+1) begin
                count[k]<=0; sums[k]<=0; near_count[k]<=0;
                clips[k]<=0; black_near[k]<=0;
            end
        end else begin
            user_d<=I_user; O_valid<=0;
            if (marker) begin pending<=1; active<=0; pending_id<=I_frame_id; end
            if (accept) begin
                pending<=0; active<=!final_beat;
                bad<=(first ? 1'b0 : bad) || bad_line;
                frame_id<=beat_id;
                x<=final_group ? 0 : bx+1'b1;
                y<=final_group ? (final_beat ? 0 : by+1'b1) : by;
                for (k=0; k<4; k=k+1) begin
                    count[k]<=count_next[k]; sums[k]<=sum_next[k];
                    near_count[k]<=near_next[k]; clips[k]<=clip_next[k];
                    black_near[k]<=black_next[k];
                    if (final_beat && !(first ? 1'b0 : bad) && !bad_line)
                        O_packets[k*128 +:128] <= packet(k,beat_id,count_next[k],
                            near_next[k],clip_next[k],black_next[k],sum_next[k]);
                end
                if (final_beat && !(first ? 1'b0 : bad) && !bad_line) O_valid<=1;
            end
        end
    end
    // synthesis translate_off
    initial begin
        if (IMG_WIDTH<4 || IMG_WIDTH%4!=0 || IMG_HEIGHT<1 ||
            BLACK_LEVEL<0 || BLACK_LEVEL>1023 || MAX_COUNT>65535 ||
            MAX_COUNT*1023>16777215 ||
            (BAYER_MODE!="BGGR" && BAYER_MODE!="RGGB" &&
             BAYER_MODE!="GBRG" && BAYER_MODE!="GRBG"))
            $fatal(1,"Unsupported RAW diagnostic parameters");
    end
    // synthesis translate_on
endmodule

module iq_diag_rgb_bank #(
    parameter integer IMG_WIDTH=1280, IMG_HEIGHT=720, KIND=2
) (
    input wire I_clk, I_rst_n, I_valid, I_user, I_last,
    input wire [95:0] I_data,
    input wire [7:0] I_clip_new,
    input wire [9:0] I_frame_id,
    input wire [10:0] I_gain_r, I_gain_b,
    output reg O_valid,
    output reg [511:0] O_packets,
    output reg [10:0] O_gain_r, O_gain_b,
    output reg [9:0] O_frame_id
);
    localparam integer GROUPS=IMG_WIDTH/4, BEATS=GROUPS*IMG_HEIGHT;
    localparam integer X_BITS=GROUPS>1 ? $clog2(GROUPS) : 1;
    localparam integer Y_BITS=IMG_HEIGHT>1 ? $clog2(IMG_HEIGHT) : 1;
    localparam integer MAX_COUNT=(BEATS+15)/16;
    localparam integer COUNT_BITS=$clog2(MAX_COUNT+1);
    localparam integer SUM_BITS=$clog2(MAX_COUNT*255+1);
    reg user_d, pending, active, bad;
    reg [9:0] frame_id, pending_id;
    reg [10:0] frame_gain_r, frame_gain_b;
    reg [X_BITS-1:0] x;
    reg [Y_BITS-1:0] y;
    reg [3:0] phase;
    reg [1:0] lane;
    reg [COUNT_BITS-1:0] count, count_next;
    reg [COUNT_BITS-1:0] near_count[0:2], clips[0:2], near_next[0:2], clip_next[0:2];
    reg [SUM_BITS-1:0] sums[0:2], sum_next[0:2];
    wire marker=I_user && !user_d;
    wire first=marker || pending;
    wire accept=I_valid && (active || first);
    wire [X_BITS-1:0] bx=first ? 0 : x;
    wire [Y_BITS-1:0] by=first ? 0 : y;
    wire final_group=bx==GROUPS-1;
    wire final_beat=final_group && by==IMG_HEIGHT-1;
    wire bad_line=I_last!=final_group;
    wire take=first || phase==0;
    wire [1:0] selected_lane=first ? 2'd0 : lane;
    wire [23:0] sample_rgb=I_data>>(selected_lane*24);
    wire [9:0] beat_id=marker ? I_frame_id : first ? pending_id : frame_id;
    integer c;
    reg [7:0] component;
    reg clipping;
    always @(*) begin
        count_next=(first ? 0 : count)+(take ? 1'b1 : 1'b0);
        component=0; clipping=0;
        for (c=0; c<3; c=c+1) begin
            sum_next[c]=first ? 0 : sums[c];
            near_next[c]=first ? 0 : near_count[c];
            clip_next[c]=first ? 0 : clips[c];
            component=sample_rgb[(2-c)*8 +:8];
            clipping=KIND==2 ? component==255 :
                c==0 ? I_clip_new[2*selected_lane+1] :
                c==2 ? I_clip_new[2*selected_lane] : 1'b0;
            if (take) begin
                sum_next[c]=sum_next[c]+component;
                near_next[c]=near_next[c]+(component>=248);
                clip_next[c]=clip_next[c]+clipping;
            end
        end
    end
    function [127:0] packet;
        input [1:0] channel;
        input [9:0] tag;
        input [15:0] number, near_value, clip_value;
        input [23:0] total;
        begin packet={KIND[3:0],channel,tag,number,total,
            near_value,clip_value,40'd0}; end
    endfunction
    integer k;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            user_d<=0; pending<=0; active<=0; bad<=0;
            x<=0; y<=0; frame_id<=0; pending_id<=0; phase<=0; lane<=0;
            count<=0; frame_gain_r<=0; frame_gain_b<=0;
            O_valid<=0; O_packets<=0; O_gain_r<=0; O_gain_b<=0; O_frame_id<=0;
            for (k=0; k<3; k=k+1) begin sums[k]<=0; near_count[k]<=0; clips[k]<=0; end
        end else begin
            user_d<=I_user; O_valid<=0;
            if (marker) begin pending<=1; active<=0; pending_id<=I_frame_id; end
            if (accept) begin
                pending<=0; active<=!final_beat;
                bad<=(first ? 1'b0 : bad) || bad_line;
                frame_id<=beat_id;
                x<=final_group ? 0 : bx+1'b1;
                y<=final_group ? (final_beat ? 0 : by+1'b1) : by;
                phase<=(first ? 0 : phase)+1'b1;
                if (take) lane<=selected_lane+1'b1;
                if (first) begin frame_gain_r<=I_gain_r; frame_gain_b<=I_gain_b; end
                count<=count_next;
                for (k=0; k<3; k=k+1) begin
                    sums[k]<=sum_next[k]; near_count[k]<=near_next[k]; clips[k]<=clip_next[k];
                    if (final_beat && !(first ? 1'b0 : bad) && !bad_line)
                        O_packets[k*128 +:128] <= packet(k==2 ? 2'd3 : k[1:0],
                            beat_id,count_next,near_next[k],clip_next[k],sum_next[k]);
                end
                if (final_beat && !(first ? 1'b0 : bad) && !bad_line) begin
                    O_valid<=1; O_frame_id<=beat_id;
                    O_gain_r<=first ? I_gain_r : frame_gain_r;
                    O_gain_b<=first ? I_gain_b : frame_gain_b;
                end
            end
        end
    end
    // synthesis translate_off
    initial begin
        if (IMG_WIDTH<4 || IMG_WIDTH%4!=0 || IMG_HEIGHT<1 ||
            MAX_COUNT>65535 || MAX_COUNT*255>16777215)
            $fatal(1,"Unsupported RGB diagnostic parameters");
    end
    // synthesis translate_on
endmodule
