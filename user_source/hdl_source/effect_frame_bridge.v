// Retained compact bridge for standalone CNN/effect regressions.
module effect_frame_bridge #(
    parameter [11:0] DEFAULT_EFFECT_CONFIG = 12'd0
) (
    input wire I_csi_clk,
    input wire I_ddr_clk,
    input wire I_hdmi_clk,
    input wire I_rst_n,
    input wire I_frame_start,
    input wire [11:0] I_effect_config,
    input wire I_write_start,
    input wire [1:0] I_write_slot,
    input wire I_read_start,
    input wire [1:0] I_read_slot,
    output reg [11:0] O_effect_config
);
    // The same ISP SOF crosses two stages in video_in before I_write_start.
    // Hold this payload until the next SOF; its 20 ns CDC bound stays active.
    reg [11:0] S_start_effect_config;
    always @(posedge I_csi_clk or negedge I_rst_n) begin
        if (!I_rst_n) S_start_effect_config <= DEFAULT_EFFECT_CONFIG;
        else if (I_frame_start) S_start_effect_config <= I_effect_config;
    end

    reg [11:0] S_slot_effect_config [0:3];
    genvar slot;
    generate for (slot=0; slot<4; slot=slot+1) begin: g_effect_slot
        always @(posedge I_ddr_clk or negedge I_rst_n) begin
            if (!I_rst_n) S_slot_effect_config[slot] <= DEFAULT_EFFECT_CONFIG;
            else if (I_write_start && I_write_slot == slot)
                S_slot_effect_config[slot] <= S_start_effect_config;
        end
    end endgenerate

    reg [11:0] S_read_payload, S_read_pending_payload;
    reg S_read_request, S_read_ack, S_read_pending_valid;
    (* async_reg = "true" *) reg S_read_ack_meta, S_read_ack_sync;
    always @(posedge I_ddr_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            S_read_payload <= DEFAULT_EFFECT_CONFIG;
            S_read_pending_payload <= DEFAULT_EFFECT_CONFIG;
            S_read_request <= 0; S_read_pending_valid <= 0;
            S_read_ack_meta <= 0; S_read_ack_sync <= 0;
        end else begin
            S_read_ack_meta <= S_read_ack;
            S_read_ack_sync <= S_read_ack_meta;
            if (S_read_request == S_read_ack_sync) begin
                if (I_read_start) begin
                    S_read_payload <= S_slot_effect_config[I_read_slot];
                    S_read_request <= !S_read_request;
                    S_read_pending_valid <= 0;
                end else if (S_read_pending_valid) begin
                    S_read_payload <= S_read_pending_payload;
                    S_read_request <= !S_read_request;
                    S_read_pending_valid <= 0;
                end
            end else if (I_read_start) begin
                // Freeze the selected config even if that DDR slot is reused.
                // A newer display selection supersedes the pending selection.
                S_read_pending_payload <= S_slot_effect_config[I_read_slot];
                S_read_pending_valid <= 1;
            end
        end
    end

    (* async_reg = "true" *) reg S_read_req_meta, S_read_req_sync;
    always @(posedge I_hdmi_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            S_read_req_meta <= 0; S_read_req_sync <= 0; S_read_ack <= 0;
            O_effect_config <= DEFAULT_EFFECT_CONFIG;
        end else begin
            S_read_req_meta <= S_read_request;
            S_read_req_sync <= S_read_req_meta;
            if (S_read_req_sync != S_read_ack) begin
                O_effect_config <= S_read_payload;
                S_read_ack <= S_read_req_sync;
            end
        end
    end
endmodule
