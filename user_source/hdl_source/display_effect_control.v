// K1/K3 select original Gamma, grayscale, Scharr edge, negative and emboss.
// Outputs belong to I_clk. The HDMI path must transfer and commit them together.
module display_effect_control #(
    parameter integer DEBOUNCE_CYCLES = 1000000,
    parameter [3:0] DEFAULT_MODE = 4'd0
)(
    input wire I_clk,
    input wire I_rst_n,
    input wire I_prev_key_n,
    input wire I_effect_key_n,
    input wire I_param_key_n,
    output reg [3:0] O_effect_mode,
    output wire [7:0] O_effect_param
);
    localparam integer COUNT_WIDTH = (DEBOUNCE_CYCLES > 1)
                                      ? $clog2(DEBOUNCE_CYCLES) : 1;
    localparam [3:0] MODE_COUNT = 4'd5;
    localparam [3:0] RESET_MODE = (DEFAULT_MODE < MODE_COUNT)
                                ? DEFAULT_MODE : 4'd0;

    (* keep = "true" *) reg effect_key_meta;
    (* keep = "true" *) reg effect_key_sync;
    (* keep = "true" *) reg prev_key_meta;
    (* keep = "true" *) reg prev_key_sync;
    reg effect_key_stable;
    reg prev_key_stable;
    reg [COUNT_WIDTH-1:0] effect_stable_count;
    reg [COUNT_WIDTH-1:0] prev_stable_count;

    wire effect_press = !effect_key_sync && effect_key_stable &&
                        (effect_stable_count == DEBOUNCE_CYCLES - 1);
    wire prev_press = !prev_key_sync && prev_key_stable &&
                      (prev_stable_count == DEBOUNCE_CYCLES - 1);

    // The retained parameter interface has no adjustable settings or K4 logic.
    assign O_effect_param = 8'd0;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            effect_key_meta <= 1'b1;
            effect_key_sync <= 1'b1;
            prev_key_meta <= 1'b1;
            prev_key_sync <= 1'b1;
        end else begin
            effect_key_meta <= I_effect_key_n;
            effect_key_sync <= effect_key_meta;
            prev_key_meta <= I_prev_key_n;
            prev_key_sync <= prev_key_meta;
        end
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            effect_key_stable <= 1'b1;
            prev_key_stable <= 1'b1;
            effect_stable_count <= 0;
            prev_stable_count <= 0;
        end else begin
            if (effect_key_sync == effect_key_stable) begin
                effect_stable_count <= 0;
            end else if (effect_stable_count == DEBOUNCE_CYCLES - 1) begin
                effect_stable_count <= 0;
                effect_key_stable <= effect_key_sync;
            end else begin
                effect_stable_count <= effect_stable_count + 1'b1;
            end

            if (prev_key_sync == prev_key_stable) begin
                prev_stable_count <= 0;
            end else if (prev_stable_count == DEBOUNCE_CYCLES - 1) begin
                prev_stable_count <= 0;
                prev_key_stable <= prev_key_sync;
            end else begin
                prev_stable_count <= prev_stable_count + 1'b1;
            end
        end
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_effect_mode <= RESET_MODE;
        end else if (effect_press) begin
            // A qualified next press takes priority over previous.
            O_effect_mode <= (O_effect_mode >= MODE_COUNT - 1'b1)
                           ? 4'd0 : O_effect_mode + 4'd1;
        end else if (prev_press) begin
            O_effect_mode <= (O_effect_mode == 4'd0) ? MODE_COUNT - 1'b1
                           : (O_effect_mode >= MODE_COUNT) ? 4'd0
                           : O_effect_mode - 4'd1;
        end
    end
endmodule
