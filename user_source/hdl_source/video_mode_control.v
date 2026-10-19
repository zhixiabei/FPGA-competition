// Active-low mode button, sampled on the 50 MHz board clock.
// Each debounced press advances red -> green -> blue -> motion -> red.
module video_mode_control #(
    parameter integer DEBOUNCE_CYCLES = 1000000,
    parameter integer DEFAULT_EDGE_MODE = 0,
    parameter integer DEFAULT_MODE = (DEFAULT_EDGE_MODE != 0) ? 3 : 0
)(
    input wire I_clk,
    input wire I_rst_n,
    input wire I_key_n,
    output reg [1:0] O_detection_mode,
    output wire O_edge_mode
);
    localparam integer COUNT_WIDTH = (DEBOUNCE_CYCLES > 1)
                                      ? $clog2(DEBOUNCE_CYCLES) : 1;
    (* keep = "true" *) reg key_meta;
    (* keep = "true" *) reg key_sync;
    reg key_stable;
    reg [COUNT_WIDTH-1:0] stable_count;
    assign O_edge_mode = O_detection_mode == 2'b11;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            key_meta <= 1'b1;
            key_sync <= 1'b1;
        end else begin
            key_meta <= I_key_n;
            key_sync <= key_meta;
        end
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            key_stable <= 1'b1;
            stable_count <= 0;
            O_detection_mode <= DEFAULT_MODE[1:0];
        end else if (key_sync == key_stable) begin
            stable_count <= 0;
        end else if (stable_count == DEBOUNCE_CYCLES - 1) begin
            stable_count <= 0;
            key_stable <= key_sync;
            if (!key_sync)
                O_detection_mode <= O_detection_mode + 1'b1;
        end else begin
            stable_count <= stable_count + 1'b1;
        end
    end
endmodule
