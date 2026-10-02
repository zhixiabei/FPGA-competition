// Runtime RGB/Sobel selector for the existing non-stallable camera stream.
// The edge pipeline always runs, including while RGB is displayed. RGB and
// all stream markers have the same one-clock latency as edge_detect_96.
module rgb_edge_switch_96 #(
    parameter integer IMG_WIDTH = 1280,
    parameter integer IMG_HEIGHT = 720,
    parameter integer EDGE_TH = 80,
    parameter integer DEFAULT_EDGE_MODE = 1
)(
    input wire I_clk,
    input wire I_rst_n,
    input wire I_edge_mode_async,
    input wire I_tlast,
    input wire I_tuser,
    input wire [95:0] I_tdata,
    input wire I_tvalid,
    output wire O_tlast,
    output wire O_tuser,
    output wire [95:0] O_tdata,
    output wire O_tvalid,
    output wire O_edge_mode
);
    (* keep = "true" *) reg mode_meta;
    (* keep = "true" *) reg mode_sync;
    reg active_edge;
    reg [95:0] rgb_data_d;
    wire [95:0] edge_data;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            mode_meta <= (DEFAULT_EDGE_MODE != 0);
            mode_sync <= (DEFAULT_EDGE_MODE != 0);
            active_edge <= (DEFAULT_EDGE_MODE != 0);
            rgb_data_d <= 96'd0;
        end else begin
            mode_meta <= I_edge_mode_async;
            mode_sync <= mode_meta;
            rgb_data_d <= I_tvalid ? I_tdata : 96'd0;
            // AWB may assert its frame marker before the first valid beat.
            // Do not qualify this update with I_tvalid. If the marker and
            // first beat coincide, both paths and this selector update on
            // the same edge, so the first output beat uses the new mode.
            if (I_tuser)
                active_edge <= mode_sync;
        end
    end

    edge_detect_96 #(
        .IMG_WIDTH(IMG_WIDTH),
        .IMG_HEIGHT(IMG_HEIGHT),
        .EDGE_TH(EDGE_TH)
    ) u_edge_detect_96 (
        .I_clk(I_clk), .I_rst_n(I_rst_n),
        .I_tlast(I_tlast), .I_tuser(I_tuser),
        .I_tdata(I_tdata), .I_tvalid(I_tvalid), .I_tready(1'b1),
        .O_tlast(O_tlast), .O_tuser(O_tuser),
        .O_tdata(edge_data), .O_tvalid(O_tvalid), .O_tready()
    );

    assign O_tdata = active_edge ? edge_data : rgb_data_d;
    assign O_edge_mode = active_edge;
endmodule
