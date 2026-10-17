module camera_diag_cdc #(
    parameter WIDTH = 12,
    parameter [WIDTH-1:0] RESET_DATA = {WIDTH{1'b0}}
) (
    input                  I_src_clk,
    input                  I_dst_clk,
    input                  I_rst_n,
    input      [WIDTH-1:0] I_src_data,
    output reg [WIDTH-1:0] O_dst_data
);
    (* async_reg = "true" *) reg [1:0] src_reset_pipe;
    (* async_reg = "true" *) reg [1:0] dst_reset_pipe;
    reg [WIDTH-1:0] payload_hold;
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

    // Keep the entire snapshot stable until its acknowledgement returns.
    // Intermediate diagnostic changes may coalesce into the latest state.
    always @(posedge I_src_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            payload_hold <= RESET_DATA;
            req_toggle <= 1'b0;
            ack_meta <= 1'b0;
            ack_sync <= 1'b0;
        end else if (!src_reset_pipe[1]) begin
            payload_hold <= RESET_DATA;
            req_toggle <= 1'b0;
            ack_meta <= 1'b0;
            ack_sync <= 1'b0;
        end else begin
            ack_meta <= ack_toggle;
            ack_sync <= ack_meta;
            if ((req_toggle == ack_sync) && (I_src_data != payload_hold)) begin
                payload_hold <= I_src_data;
                req_toggle <= ~req_toggle;
            end
        end
    end

    // Two request stages give the bounded payload path time to settle.
    // Acknowledge only on the edge that captures the complete snapshot.
    always @(posedge I_dst_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            req_meta <= 1'b0;
            req_sync <= 1'b0;
            ack_toggle <= 1'b0;
            O_dst_data <= RESET_DATA;
        end else if (!dst_reset_pipe[1]) begin
            req_meta <= 1'b0;
            req_sync <= 1'b0;
            ack_toggle <= 1'b0;
            O_dst_data <= RESET_DATA;
        end else begin
            req_meta <= req_toggle;
            req_sync <= req_meta;
            if (req_sync != ack_toggle) begin
                O_dst_data <= payload_hold;
                ack_toggle <= req_sync;
            end
        end
    end
endmodule
