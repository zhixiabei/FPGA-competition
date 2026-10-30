// Consume the checkout's numerical outputs in its DDR clock domain.
// Price valid stays high between calculations: only rising edges are new pairs.
// Empty-pan observations use weight_updated, including consecutive exact zeros.
module checkout_voice_bridge #(
    parameter integer CLOCK_HZ=66666667,
    parameter integer STARTUP_MS=1000,
    parameter integer INIT_GAP_MS=100,
    parameter integer STABLE_MS=1000,
    parameter integer SAMPLE_TIMEOUT_MS=2000,
    parameter integer POLL_MS=200,
    parameter integer START_GRACE_MS=1000,
    parameter integer PLAY_TIMEOUT_MS=30000,
    parameter integer VOLUME=30
)(
    input wire clk,rst_n,run_switch,
    input wire [13:0] weight_g,total_fen,
    input wire weight_valid,price_valid,weight_updated,
    input wire [3:0] status,
    input wire rx,
    output wire tx
);
    (* async_reg="true" *) reg enable_meta,enable_sync;
    reg price_valid_d;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            enable_meta<=0;enable_sync<=0;
            price_valid_d<=0;
        end else begin
            enable_meta<=run_switch;enable_sync<=enable_meta;
            price_valid_d<=price_valid;
        end
    end
    // Status 10 is the normal, short calculation gap between ADC averages.
    // Keeping it enabled preserves deduplication across those gaps.
    wire scale_ready=status==4'd7 || status==4'd10;
    // An empty pan also rearms playback when the classifier has no result.
    wire empty_pan=weight_g<14'd20;
    wire new_pair=(price_valid && !price_valid_d) ||
                  (weight_updated && weight_valid && empty_pan);
    scale_voice_auto #(.CLOCK_HZ(CLOCK_HZ),.STARTUP_MS(STARTUP_MS),
        .INIT_GAP_MS(INIT_GAP_MS),.STABLE_MS(STABLE_MS),
        .SAMPLE_TIMEOUT_MS(SAMPLE_TIMEOUT_MS),.POLL_MS(POLL_MS),
        .START_GRACE_MS(START_GRACE_MS),.PLAY_TIMEOUT_MS(PLAY_TIMEOUT_MS),
        .VOLUME(VOLUME),.VALUE_WIDTH(14)) u_voice(
        .clk(clk),.rst_n(rst_n),.enable(enable_sync && scale_ready),
        .sample_valid(new_pair),.weight_g({10'd0,weight_g}),
        .amount_fen(empty_pan ? 24'd0 : {10'd0,total_fen}),.rx(rx),.tx(tx),
        .initialized(),.busy(),.announcement_started(),.announcement_finished(),
        .playback_timeout(),.spoken_weight_g(),.spoken_amount_fen());
endmodule
