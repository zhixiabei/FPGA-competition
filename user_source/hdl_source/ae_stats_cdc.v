// Coherent frame-statistics mailbox. Repeated identical frames still deliver
// a pulse, so the exposure loop can continue to settle and adjust.
module ae_stats_cdc #(
    parameter integer WIDTH = 64
) (
    input wire I_src_clk,
    input wire I_dst_clk,
    input wire I_rst_n,
    input wire I_src_valid,
    input wire [WIDTH-1:0] I_src_data,
    output reg O_dst_valid,
    output reg [WIDTH-1:0] O_dst_data
);
    (* async_reg = "true" *) reg [1:0] src_reset_pipe;
    (* async_reg = "true" *) reg [1:0] dst_reset_pipe;
    reg [WIDTH-1:0] payload_hold;
    reg [WIDTH-1:0] pending_data;
    reg pending_valid;
    reg req_toggle;
    reg ack_toggle;
    (* async_reg = "true" *) reg req_meta;
    (* async_reg = "true" *) reg req_sync;
    (* async_reg = "true" *) reg ack_meta;
    (* async_reg = "true" *) reg ack_sync;

    always @(posedge I_src_clk or negedge I_rst_n) begin
        if (!I_rst_n)
            src_reset_pipe <= 2'b00;
        else
            src_reset_pipe <= {src_reset_pipe[0], 1'b1};
    end
    always @(posedge I_dst_clk or negedge I_rst_n) begin
        if (!I_rst_n)
            dst_reset_pipe <= 2'b00;
        else
            dst_reset_pipe <= {dst_reset_pipe[0], 1'b1};
    end

    // A stalled destination may coalesce pending frames into the latest
    // complete one. It can never overwrite the snapshot being received.
    always @(posedge I_src_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            payload_hold <= {WIDTH{1'b0}};
            pending_data <= {WIDTH{1'b0}};
            pending_valid <= 1'b0;
            req_toggle <= 1'b0;
            ack_meta <= 1'b0;
            ack_sync <= 1'b0;
        end else if (!src_reset_pipe[1]) begin
            payload_hold <= {WIDTH{1'b0}};
            pending_data <= {WIDTH{1'b0}};
            pending_valid <= 1'b0;
            req_toggle <= 1'b0;
            ack_meta <= 1'b0;
            ack_sync <= 1'b0;
        end else begin
            ack_meta <= ack_toggle;
            ack_sync <= ack_meta;
            if (I_src_valid) begin
                pending_data <= I_src_data;
                pending_valid <= 1'b1;
            end
            if (req_toggle == ack_sync) begin
                if (I_src_valid) begin
                    payload_hold <= I_src_data;
                    req_toggle <= ~req_toggle;
                    pending_valid <= 1'b0;
                end else if (pending_valid) begin
                    payload_hold <= pending_data;
                    req_toggle <= ~req_toggle;
                    pending_valid <= 1'b0;
                end
            end
        end
    end

    // The payload is stable throughout the two request synchronizers and
    // the capture edge; the SDC bounds that direct path to 20 ns.
    always @(posedge I_dst_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            req_meta <= 1'b0;
            req_sync <= 1'b0;
            ack_toggle <= 1'b0;
            O_dst_valid <= 1'b0;
            O_dst_data <= {WIDTH{1'b0}};
        end else if (!dst_reset_pipe[1]) begin
            req_meta <= 1'b0;
            req_sync <= 1'b0;
            ack_toggle <= 1'b0;
            O_dst_valid <= 1'b0;
            O_dst_data <= {WIDTH{1'b0}};
        end else begin
            req_meta <= req_toggle;
            req_sync <= req_meta;
            O_dst_valid <= 1'b0;
            if (req_sync != ack_toggle) begin
                O_dst_data <= payload_hold;
                O_dst_valid <= 1'b1;
                ack_toggle <= req_sync;
            end
        end
    end
endmodule
