// RGB128 stream: select every fourth pixel and row.
// 32x32 green samples, double buffered in one ERAM. Commit complete paused
// scans only; enabling freezes the latest complete reference, never a partial
// frame. This detects scene change, not semantic hand presence or motion.
module handfixed_background #(
    parameter integer PIXEL_DELTA=24,
    parameter integer ENTER_PIXELS=64,
    parameter integer EXIT_PIXELS=32
)(
    input wire clk,rst_n,run_enabled,
    input wire start,scan_background,done,
    input wire pixel_valid,row_end,
    input wire [7:0] green,
    output reg reference_ready,
    output wire foreground,
    output reg [10:0] changed_pixels
);
    reg reference_bank,write_bank,training,aborted,present;
    reg [1:0] sx,sy;
    reg [10:0] samples;
    reg [9:0] address;
    reg compare_valid;
    reg [7:0] compare_green;
    wire selected=pixel_valid && sx==1 && sy==1;
    wire [7:0] reference_green;
    wire [7:0] delta=compare_green>=reference_green ? compare_green-reference_green : reference_green-compare_green;
    wire write_reference=selected && training && !aborted && !run_enabled;
    cnn_eram_byte_dp #(.ADDR_WIDTH(11),.DATA_DEPTH(2048)) reference_memory(
        .I_clk(clk),.I_wr_en(write_reference),.I_wr_addr({write_bank,address}),.I_wr_data(green),
        .I_rd_addr({reference_bank,address}),.O_rd_data(reference_green));
    assign foreground=reference_ready && !training &&
                      (changed_pixels >= (present ? EXIT_PIXELS : ENTER_PIXELS));
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            reference_ready<=0;reference_bank<=0;write_bank<=1;training<=0;aborted<=0;present<=0;
            sx<=0;sy<=0;samples<=0;address<=0;compare_valid<=0;compare_green<=0;changed_pixels<=0;
        end else begin
            compare_valid<=selected && !training && run_enabled && reference_ready;
            if(selected) begin address<=address+1'b1;samples<=samples+1'b1;compare_green<=green;end
            if(compare_valid && delta>=PIXEL_DELTA) changed_pixels<=changed_pixels+1'b1;
            if(pixel_valid) begin
                if(row_end) begin sx<=0;sy<=sy+1'b1;end
                else sx<=sx+1'b1;
            end
            if(training && run_enabled) aborted<=1;
            if(!run_enabled) present<=0;
            if(done) begin
                if(training && !run_enabled && !aborted && samples==1024) begin
                    reference_bank<=write_bank;reference_ready<=1;
                end else if(!training && run_enabled) present<=foreground;
            end
            if(start) begin
                sx<=0;sy<=0;samples<=0;address<=0;changed_pixels<=0;compare_valid<=0;
                training<=scan_background;aborted<=0;write_bank<=!reference_bank;
            end
        end
    end
endmodule
