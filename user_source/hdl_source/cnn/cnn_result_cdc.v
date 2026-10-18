// Held-payload toggle mailbox from the camera/CNN clock to HDMI pixel clock.
module cnn_result_cdc (
    input  wire       I_src_clk,
    input  wire       I_dst_clk,
    input  wire       I_rst_n,
    input  wire       I_src_valid,
    input  wire [2:0] I_src_class,
    output reg        O_dst_valid,
    output reg  [2:0] O_dst_class
);
    reg [2:0] payload;
    reg request;
    (* async_reg = "true" *) reg req_meta, req_sync, req_seen;
    (* async_reg = "true" *) reg [2:0] class_meta, class_sync;

    always @(posedge I_src_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            payload <= 3'd0;
            request <= 1'b0;
        end else if (I_src_valid) begin
            payload <= I_src_class;
            request <= ~request;
        end
    end

    always @(posedge I_dst_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            req_meta <= 1'b0;
            req_sync <= 1'b0;
            req_seen <= 1'b0;
            class_meta <= 3'd0;
            class_sync <= 3'd0;
            O_dst_valid <= 1'b0;
            O_dst_class <= 3'd0;
        end else begin
            req_meta <= request;
            req_sync <= req_meta;
            class_meta <= payload;
            class_sync <= class_meta;
            O_dst_valid <= 1'b0;
            if (req_sync != req_seen) begin
                req_seen <= req_sync;
                O_dst_class <= class_sync;
                O_dst_valid <= 1'b1;
            end
        end
    end
endmodule
