// Frame-boundary RGB/color-vector-edge selector for the non-stallable camera
// stream. Both data paths, markers AND mode have eleven registered clocks of
// latency. A request is synchronized then committed on input SOF (including
// a SOF before the first valid beat); its delayed token selects output data.
module rgb_edge_switch_96 #(
    parameter integer IMG_WIDTH=1280,
    parameter integer IMG_HEIGHT=720,
    parameter integer EDGE_TH=20,
    parameter integer DEFAULT_EDGE_MODE=1
)(
    input wire I_clk,input wire I_rst_n,input wire I_edge_mode_async,
    input wire I_tlast,input wire I_tuser,input wire [95:0] I_tdata,
    input wire I_tvalid,
    output wire O_tlast,output wire O_tuser,output wire [95:0] O_tdata,
    output wire O_tvalid,output wire O_edge_mode
);
    localparam integer LATENCY=11;
    (* keep="true" *) reg mode_meta;
    (* keep="true" *) reg mode_sync;
    reg active_edge;
    reg [95:0] rgb_delay[0:LATENCY-1];
    reg [LATENCY-1:0] mode_delay;
    wire [95:0] edge_data;
    integer i;
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            mode_meta<=(DEFAULT_EDGE_MODE!=0);
            mode_sync<=(DEFAULT_EDGE_MODE!=0);
            active_edge<=(DEFAULT_EDGE_MODE!=0);
            mode_delay<={LATENCY{(DEFAULT_EDGE_MODE!=0)}};
            for(i=0;i<LATENCY;i=i+1) rgb_delay[i]<=96'd0;
        end else begin
            mode_meta<=I_edge_mode_async; mode_sync<=mode_meta;
            if(I_tuser) active_edge<=mode_sync;
            mode_delay[0]<=I_tuser ? mode_sync : active_edge;
            rgb_delay[0]<=I_tvalid ? I_tdata : 96'd0;
            for(i=1;i<LATENCY;i=i+1) begin
                rgb_delay[i]<=rgb_delay[i-1]; mode_delay[i]<=mode_delay[i-1];
            end
        end
    end
    color_edge_detect_96 #(
        .IMG_WIDTH(IMG_WIDTH),.IMG_HEIGHT(IMG_HEIGHT),.EDGE_TH(EDGE_TH)
    ) u_color_edge_detect_96 (
        .I_clk(I_clk),.I_rst_n(I_rst_n),.I_tlast(I_tlast),.I_tuser(I_tuser),
        .I_tdata(I_tdata),.I_tvalid(I_tvalid),.I_tready(1'b1),
        .O_tlast(O_tlast),.O_tuser(O_tuser),.O_tdata(edge_data),
        .O_tvalid(O_tvalid),.O_tready()
    );
    assign O_tdata=mode_delay[LATENCY-1] ? edge_data : rgb_delay[LATENCY-1];
    assign O_edge_mode=mode_delay[LATENCY-1];
endmodule
