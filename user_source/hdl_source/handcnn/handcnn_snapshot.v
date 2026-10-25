// Copies a complete, contiguous video write slot into a private DDR snapshot.
// A capture is discarded on an interrupted frame or queue overflow. The
// compute client must wait for done before reading the immutable snapshot.
module handcnn_snapshot #(
    parameter integer BEATS=172800
)(
    input wire clk,rst_n,start,
    input wire [31:0] SNAPSHOT_BASE,
    input wire frame_start,
    input wire [1:0] frame_slot,
    input wire video_write,
    input wire [24:0] video_addr,
    input wire [127:0] video_data,
    output wire mem_valid,
    output wire [31:0] mem_addr,
    output wire [127:0] mem_data,
    input wire mem_ready,
    output reg done,busy,failed,
    output wire [18:0] captured_beats,written_beats
);
    reg armed,capturing;
    reg [24:0] base,expected;
    reg [18:0] captured,written;
    assign captured_beats=captured;
    assign written_beats=written;
    reg [8:0] wp,rp;
    reg [9:0] count;
    (* ram_style="bram" *) reg [127:0] queue[0:511];
    reg [127:0] q;
    reg q_valid;
    wire take=video_write && capturing && video_addr==expected && captured<BEATS;
    // The BRAM read and q_valid update take effect at the same edge. Replace
    // a consumed output immediately so consecutive writes need no bubbles.
    wire fetch=busy && count!=0 && (!q_valid || mem_ready);
    assign mem_valid=busy && q_valid;
    assign mem_data=q;
    assign mem_addr=SNAPSHOT_BASE+{9'd0,written,4'd0};
    function [24:0] slot_base;
        input [1:0] slot;
        begin case(slot)
            0:slot_base=0;1:slot_base=1572864;2:slot_base=3145728;3:slot_base=4718592;
        endcase end
    endfunction
    always @(posedge clk) begin
        if(take && count<512) queue[wp]<=video_data;
        if(fetch) q<=queue[rp];
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            done<=0;busy<=0;failed<=0;armed<=0;capturing<=0;base<=0;expected<=0;
            captured<=0;written<=0;wp<=0;rp<=0;count<=0;q_valid<=0;
        end else begin
            done<=0;
            if(start && !busy) begin
                busy<=1;armed<=1;capturing<=0;failed<=0;captured<=0;written<=0;
                wp<=0;rp<=0;count<=0;q_valid<=0;
            end else begin
                // A fresh start must override the previous failure's idle exit.
                if(frame_start && armed) begin
                    armed<=0;capturing<=1;base<=slot_base(frame_slot);expected<=slot_base(frame_slot);
                end else if(frame_start && capturing && captured<BEATS) begin
                    failed<=1;capturing<=0;
                end
                if(take) begin
                    if(count==512) begin failed<=1;capturing<=0;end
                    else begin
                        wp<=wp+1'b1;captured<=captured+1'b1;expected<=expected+8;
                        if(captured==BEATS-1) capturing<=0;
                    end
                end
                if(fetch) rp<=rp+1'b1;
                case({take && count<512,fetch})
                    2'b10:count<=count+1'b1;
                    2'b01:count<=count-1'b1;
                endcase
                if(fetch) q_valid<=1;
                else if(mem_valid && mem_ready) q_valid<=0;
                if(mem_valid && mem_ready) begin
                    written<=written+1'b1;
                    if(written==BEATS-1) begin busy<=0;done<=!failed;end
                end
                if(failed && count==0 && !q_valid) busy<=0;
            end
        end
    end
endmodule
