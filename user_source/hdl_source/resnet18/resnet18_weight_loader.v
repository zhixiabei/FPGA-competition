// Stop-and-wait packets: "R18D", uint32 LE sequence, 256 payload bytes,
// uint32 LE CRC32(sequence bytes + payload). ACK is 0x79, NAK is 0x1f.
// The selected complete model's full CRC32 is checked before model_ready.
// No command can write outside the reserved model byte-address range.
module resnet18_weight_loader #(
    parameter integer TIMEOUT_CYCLES=66666667
)(
    input wire clk,rst_n,
    input wire rx_valid,rx_error,
    input wire [7:0] rx_data,
    output reg tx_valid,
    output reg [7:0] tx_data,
    input wire tx_ready,
    input wire allow_load,
    // Read-only R18S query, available before/during/after weight loading.
    // 32 frozen status bytes followed by their IEEE CRC32, little endian.
    input wire [255:0] runtime_status,
    input wire [31:0] MODEL_BASE,MODEL_BYTES,MODEL_CRC32,
    output reg model_ready,
    output reg [31:0] accepted_packets,
    output wire mem_valid,
    output wire [31:0] mem_addr,
    output wire [127:0] mem_data,
    input wire mem_ready
);
    localparam SEARCH=0,SEQUENCE=1,DATA=2,CRC=3,VALIDATE=4,WRITE=5,ACK=6,FETCH=7,GET=8,STATUS=9;
    reg [3:0] state;
    reg [2:0] magic_index;
    reg [8:0] index;
    reg [31:0] packet_sequence,packet_crc,received_crc,image_crc,trial_crc,last_crc,timer;
    reg [3:0] beat;
    reg [127:0] payload_q;
    reg [3:0] fetch_byte;
    reg [255:0] status_shift;
    reg [31:0] status_crc;
    wire [7:0] payload_byte;
    wire [31:0] packet_count=MODEL_BYTES>>8;
    // A byte-wide native ERAM avoids 2048 flip-flops and a 128-bit read mux.
    // Serializing sixteen reads costs less than one UART byte per packet.
    cnn_eram_byte_dp #(.ADDR_WIDTH(8),.DATA_DEPTH(256)) packet_ram(
        .I_clk(clk),.I_wr_en(state==DATA && rx_valid),.I_wr_addr(index[7:0]),
        .I_wr_data(rx_data),.I_rd_addr({beat,fetch_byte}),.O_rd_data(payload_byte));
    assign mem_data=payload_q;
    assign mem_valid=state==WRITE;
    assign mem_addr=MODEL_BASE+(accepted_packets<<8)+{24'd0,beat,4'd0};
    function [31:0] crc_byte;
        input [31:0] crc;
        input [7:0] value;
        reg [31:0] c;
        integer i;
        begin
            c=crc^{24'd0,value};
            for(i=0;i<8;i=i+1) c=c[0] ? (c>>1)^32'hedb88320 : c>>1;
            crc_byte=c;
        end
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=SEARCH;magic_index<=0;index<=0;packet_sequence<=0;
            packet_crc<=32'hffffffff;received_crc<=0;image_crc<=32'hffffffff;
            trial_crc<=32'hffffffff;last_crc<=0;beat<=0;timer<=0;fetch_byte<=0;payload_q<=0;
            tx_valid<=0;tx_data<=0;accepted_packets<=0;model_ready<=0;
            status_shift<=0;status_crc<=32'hffffffff;
        end else begin
            tx_valid<=0;
            if(rx_valid || state==SEARCH || state==WRITE || state==ACK || state==STATUS) timer<=0;
            else if(timer<TIMEOUT_CYCLES) timer<=timer+1'b1;
            if(rx_error || (timer==TIMEOUT_CYCLES && state!=WRITE)) begin
                state<=SEARCH;magic_index<=0;timer<=0;
            end else case(state)
                SEARCH: if(rx_valid) begin
                    case(magic_index)
                        0: magic_index<=rx_data=="R" ? 1 : 0;
                        1: magic_index<=rx_data=="1" ? 2 : rx_data=="R" ? 1 : 0;
                        2: magic_index<=rx_data=="8" ? 3 : rx_data=="R" ? 1 : 0;
                        3: begin
                            magic_index<=0;
                            if(rx_data=="D") begin
                                state<=SEQUENCE;index<=0;packet_crc<=32'hffffffff;
                                trial_crc<=image_crc;
                            end else if(rx_data=="S") begin
                                status_shift<=runtime_status;status_crc<=32'hffffffff;
                                index<=0;state<=STATUS;
                            end
                        end
                    endcase
                end
                SEQUENCE: if(rx_valid) begin
                    packet_sequence[index*8+:8]<=rx_data;
                    packet_crc<=crc_byte(packet_crc,rx_data);
                    if(index==3) begin index<=0;state<=DATA;end
                    else index<=index+1'b1;
                end
                DATA: if(rx_valid) begin
                    packet_crc<=crc_byte(packet_crc,rx_data);
                    trial_crc<=crc_byte(trial_crc,rx_data);
                    if(index==255) begin index<=0;state<=CRC;end
                    else index<=index+1'b1;
                end
                CRC: if(rx_valid) begin
                    received_crc[index*8+:8]<=rx_data;
                    if(index==3) state<=VALIDATE;else index<=index+1'b1;
                end
                VALIDATE: begin
                    tx_data<=8'h1f;state<=ACK;
                    if(received_crc==~packet_crc) begin
                        if(accepted_packets!=0 && packet_sequence==accepted_packets-1 && received_crc==last_crc)
                            tx_data<=8'h79;
                        else if(allow_load && !model_ready && packet_sequence==accepted_packets &&
                                packet_sequence<packet_count) begin
                            state<=FETCH;beat<=0;fetch_byte<=0;
                        end
                    end
                end
                FETCH: state<=GET;
                GET: begin
                    payload_q[fetch_byte*8+:8]<=payload_byte;
                    if(fetch_byte==15) state<=WRITE;
                    else begin fetch_byte<=fetch_byte+1'b1;state<=FETCH;end
                end
                WRITE: if(mem_ready) begin
                    if(beat==15) begin
                        image_crc<=trial_crc;last_crc<=received_crc;
                        accepted_packets<=accepted_packets+1'b1;state<=ACK;tx_data<=8'h79;
                        if(accepted_packets+1==packet_count) begin
                            model_ready<=(~trial_crc==MODEL_CRC32);
                            if(~trial_crc!=MODEL_CRC32) begin
                                accepted_packets<=0;image_crc<=32'hffffffff;tx_data<=8'h1f;
                            end
                        end
                    end else begin beat<=beat+1'b1;fetch_byte<=0;state<=FETCH;end
                end
                ACK: if(tx_ready && !tx_valid) begin
                    tx_valid<=1;state<=SEARCH;magic_index<=0;
                end
                STATUS: if(tx_ready && !tx_valid) begin
                    tx_valid<=1;
                    if(index<32) begin
                        tx_data<=status_shift[7:0];status_shift<=status_shift>>8;
                        status_crc<=crc_byte(status_crc,status_shift[7:0]);
                    end else begin
                        tx_data<=~status_crc[7:0];status_crc<=status_crc>>8;
                    end
                    if(index==35) begin state<=SEARCH;magic_index<=0;end
                    else index<=index+1'b1;
                end
            endcase
        end
    end
endmodule
