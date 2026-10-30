// Complete automatic quote controller. All inputs use this clock domain.
// sample_valid must identify a newly computed coherent weight/total pair.
// A status response from the module confirms playback has finished; no ACK
// is expected for initialization, volume or combination-play commands.
module scale_voice_auto #(
    parameter integer CLOCK_HZ=66666667,
    parameter integer BAUD=9600,
    parameter integer STARTUP_MS=1000,
    parameter integer INIT_GAP_MS=100,
    parameter integer STABLE_MS=1000,
    parameter integer SAMPLE_TIMEOUT_MS=2000,
    parameter integer POLL_MS=200,
    parameter integer START_GRACE_MS=1000,
    parameter integer PLAY_TIMEOUT_MS=30000,
    parameter integer VOLUME=20,
    parameter integer VALUE_WIDTH=24
)(
    input wire clk,rst_n,enable,sample_valid,
    input wire [23:0] weight_g,amount_fen,
    input wire rx,
    output wire tx,
    output wire initialized,busy,
    output reg announcement_started,announcement_finished,playback_timeout,
    output wire [23:0] spoken_weight_g,spoken_amount_fen
);
    localparam BOOT=0,TF_REQ=1,TF_WAIT=2,TF_GAP=3,VOL_REQ=4,VOL_WAIT=5,
        VOL_GAP=6,READY=7,BUILD=8,PLAY_REQ=9,PLAY_TX=10,PLAYING=11,
        POLL_REQ=12,POLL_TX=13;
    localparam integer MS_CYCLES=(CLOCK_HZ/1000)>0 ? CLOCK_HZ/1000:1;
    localparam integer MS_BITS=MS_CYCLES>1 ? $clog2(MS_CYCLES):1;
    localparam integer WAIT_LIMIT=STARTUP_MS+INIT_GAP_MS+1;
    localparam integer WAIT_BITS=WAIT_LIMIT>0 ? $clog2(WAIT_LIMIT+1):1;
    localparam integer PLAY_BITS=PLAY_TIMEOUT_MS>0 ? $clog2(PLAY_TIMEOUT_MS+1):1;
    localparam integer POLL_BITS=POLL_MS>0 ? $clog2(POLL_MS+1):1;
    localparam [7:0] VOLUME_BYTE=VOLUME;
    localparam integer TRANSPORT_BITS=VOLUME_BYTE>127 ? 8:VOLUME_BYTE>63 ? 7:
        VOLUME_BYTE>31 ? 6:VOLUME_BYTE>15 ? 5:4;
    localparam integer DECIMAL_DIGITS=((VALUE_WIDTH*30103)/100000+1)>4 ?
        (VALUE_WIDTH*30103)/100000+1 : 4;
    localparam integer MAX_DATA_BYTES=2*DECIMAL_DIGITS+4;
    reg [3:0] state;
    reg [MS_BITS-1:0] ms_div;
    reg [WAIT_BITS-1:0] wait_ms;
    reg [PLAY_BITS-1:0] play_age_ms;
    reg [POLL_BITS-1:0] poll_age_ms;
    wire ms_tick=ms_div==MS_CYCLES-1;
    wire quote_valid,phrase_done;
    wire [4:0] phrase_count;
    wire [199:0] phrase_clips;
    wire transport_ready,transport_done,status_valid;
    wire [1:0] playback_status;
    reg seen_playing;
    wire active_playback=state>=PLAY_TX;
    assign initialized=state>=READY;
    assign busy=state!=READY;

    scale_voice_stable #(.CLOCK_HZ(CLOCK_HZ),.STABLE_MS(STABLE_MS),
        .SAMPLE_TIMEOUT_MS(SAMPLE_TIMEOUT_MS),.VALUE_WIDTH(VALUE_WIDTH)) u_stable(
        .clk(clk),.rst_n(rst_n),.enable(enable),.sample_valid(sample_valid),
        .weight_g(weight_g),.amount_fen(amount_fen),
        .quote_ready(state==READY),.quote_valid(quote_valid),
        .quote_weight_g(spoken_weight_g),.quote_amount_fen(spoken_amount_fen));
    scale_voice_phrase #(.VALUE_WIDTH(VALUE_WIDTH)) u_phrase(.clk(clk),.rst_n(rst_n),.start(quote_valid),
        .weight_g(spoken_weight_g),.amount_fen(spoken_amount_fen),
        .ready(),.done(phrase_done),.clip_count(phrase_count),.clips(phrase_clips));

    reg [7:0] command;
    reg [4:0] data_count;
    reg [199:0] data_bytes;
    wire transport_start=transport_ready &&
        (state==TF_REQ || state==VOL_REQ || (state==PLAY_REQ && enable) || state==POLL_REQ);
    always @* begin
        command=8'h01;data_count=0;data_bytes=0;
        case(state)
            TF_REQ: begin command=8'h0b;data_count=1;data_bytes[7:0]=1;end
            VOL_REQ: begin command=8'h13;data_count=1;data_bytes[7:0]=VOLUME;end
            PLAY_REQ: begin command=8'h1b;data_count=phrase_count;data_bytes=phrase_clips;end
        endcase
    end
    cx_sp5t_uart #(.CLOCK_HZ(CLOCK_HZ),.BAUD(BAUD),.DATA_BITS(TRANSPORT_BITS),
        .MAX_DATA_BYTES(MAX_DATA_BYTES)) u_transport(
        .clk(clk),.rst_n(rst_n),.rx(rx),.tx(tx),.start(transport_start),
        .command(command),.data_count(data_count),.data_bytes(data_bytes),
        .ready(transport_ready),.done(transport_done),.invalid_command(),
        .status_valid(status_valid),.playback_status(playback_status));

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=BOOT;ms_div<=0;wait_ms<=0;play_age_ms<=0;poll_age_ms<=0;
            seen_playing<=0;announcement_started<=0;announcement_finished<=0;playback_timeout<=0;
        end else begin
            announcement_started<=0;announcement_finished<=0;playback_timeout<=0;
            if(ms_tick) ms_div<=0;else ms_div<=ms_div+1'b1;
            if(ms_tick) begin
                if(wait_ms<STARTUP_MS+INIT_GAP_MS+1) wait_ms<=wait_ms+1'b1;
                if(active_playback) begin
                    if(play_age_ms<PLAY_TIMEOUT_MS) play_age_ms<=play_age_ms+1'b1;
                    if(poll_age_ms<POLL_MS) poll_age_ms<=poll_age_ms+1'b1;
                end
            end
            if(active_playback && status_valid && playback_status==1) seen_playing<=1;
            case(state)
                BOOT: if(wait_ms>=STARTUP_MS) state<=TF_REQ;
                TF_REQ: if(transport_ready) state<=TF_WAIT;
                TF_WAIT: if(transport_done) begin wait_ms<=0;state<=TF_GAP;end
                TF_GAP: if(wait_ms>=INIT_GAP_MS) state<=VOL_REQ;
                VOL_REQ: if(transport_ready) state<=VOL_WAIT;
                VOL_WAIT: if(transport_done) begin wait_ms<=0;state<=VOL_GAP;end
                VOL_GAP: if(wait_ms>=INIT_GAP_MS) state<=READY;
                READY: if(quote_valid) state<=BUILD;
                BUILD: if(!enable) state<=READY;else if(phrase_done) state<=PLAY_REQ;
                PLAY_REQ: if(!enable) state<=READY;else if(transport_ready) begin
                    state<=PLAY_TX;announcement_started<=1;
                    play_age_ms<=0;poll_age_ms<=0;seen_playing<=0;
                end
                PLAY_TX: if(transport_done) begin state<=PLAYING;poll_age_ms<=0;end
                PLAYING: if(poll_age_ms>=POLL_MS) state<=POLL_REQ;
                POLL_REQ: if(transport_ready) state<=POLL_TX;
                POLL_TX: if(transport_done) begin state<=PLAYING;poll_age_ms<=0;end
                default: state<=BOOT;
            endcase
            if(active_playback && status_valid && playback_status==0 &&
               (seen_playing || play_age_ms>=START_GRACE_MS)) begin
                announcement_finished<=1;state<=READY;
            end else if(active_playback && play_age_ms>=PLAY_TIMEOUT_MS) begin
                playback_timeout<=1;state<=READY;
            end
        end
    end
endmodule
