// Stop-and-wait packets: "R18D", uint32 LE sequence, 256 payload bytes,
// uint32 LE CRC32(sequence bytes + payload). ACK is 0x79, NAK is 0x1f.
// The selected complete model's full CRC32 is checked before model_ready.
// R18L reports the last rejection and loader/model identity without changing
// progress. It uses the same 32-byte payload + CRC32 response as R18S.
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
    reg [7:0] index;
    reg [31:0] packet_sequence,packet_crc,received_crc,image_crc,trial_crc,last_crc,timer;
    // UART bytes are about 720 clocks apart. A bit per clock avoids three
    // copies of the eight-level byte-CRC network without reducing line rate.
    localparam CRC_PACKET=0,CRC_DATA=1,CRC_STATUS=2;
    reg [1:0] crc_target;
    reg [3:0] crc_steps;
    // 0 OK, 1 packet CRC, 2 sequence, 3 DDR not calibrated, 4 already ready,
    // 5 range, 6 complete model CRC, 7 UART framing, 8 timeout, 9 overrun.
    reg [7:0] reject_reason;
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
    function [31:0] crc_bit;
        input [31:0] crc;
        begin
            crc_bit=(crc>>1)^(crc[0] ? 32'hedb88320 : 32'd0);
        end
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=SEARCH;magic_index<=0;index<=0;packet_sequence<=0;
            packet_crc<=32'hffffffff;received_crc<=0;image_crc<=32'hffffffff;
            trial_crc<=32'hffffffff;last_crc<=0;beat<=0;timer<=0;fetch_byte<=0;payload_q<=0;
            tx_valid<=0;tx_data<=0;accepted_packets<=0;model_ready<=0;
            status_shift<=0;status_crc<=32'hffffffff;
            crc_target<=CRC_PACKET;crc_steps<=0;reject_reason<=0;
        end else begin
            tx_valid<=0;
            if(rx_valid || state==SEARCH || state==WRITE || state==ACK || state==STATUS) timer<=0;
            else if(timer<TIMEOUT_CYCLES) timer<=timer+1'b1;
            if(rx_error || (timer==TIMEOUT_CYCLES && state!=WRITE)) begin
                state<=SEARCH;magic_index<=0;timer<=0;crc_steps<=0;
                reject_reason<=rx_error ? 8'd7 : 8'd8;
            end else begin
                if(crc_steps!=0) begin
                    crc_steps<=crc_steps-1'b1;
                    if(crc_target==CRC_STATUS) status_crc<=crc_bit(status_crc);
                    else begin
                        packet_crc<=crc_bit(packet_crc);
                        if(crc_target==CRC_DATA) trial_crc<=crc_bit(trial_crc);
                    end
                end
                case(state)
                SEARCH: if(rx_valid) begin
                    case(magic_index)
                        0: magic_index<=rx_data=="R" ? 1 : 0;
                        1: magic_index<=rx_data=="1" ? 2 : rx_data=="R" ? 1 : 0;
                        2: magic_index<=rx_data=="8" ? 3 : rx_data=="R" ? 1 : 0;
                        3: begin
                            magic_index<=0;
                            if(rx_data=="D") begin
                                state<=SEQUENCE;index<=0;packet_crc<=32'hffffffff;
                                trial_crc<=image_crc;crc_steps<=0;
                            end else if(rx_data=="S") begin
                                status_shift<=runtime_status;status_crc<=32'hffffffff;
                                index<=0;state<=STATUS;crc_steps<=0;
                            end else if(rx_data=="L") begin
                                // LE fields at offsets 8,12,16,20,24,28:
                                // accepted, sequence, calculated/received CRC,
                                // model byte count, complete model CRC.
                                status_shift<={MODEL_CRC32,MODEL_BYTES,received_crc,
                                    ~packet_crc,packet_sequence,accepted_packets,
                                    8'd0,6'd0,model_ready,allow_load,
                                    reject_reason,8'd1,32'h4c383152};
                                status_crc<=32'hffffffff;
                                index<=0;state<=STATUS;crc_steps<=0;
                            end
                        end
                    endcase
                end
                SEQUENCE: if(rx_valid) begin
                    if(crc_steps!=0) begin
                        state<=SEARCH;magic_index<=0;crc_steps<=0;reject_reason<=9;
                    end else begin
                        packet_sequence<={rx_data,packet_sequence[31:8]};
                        packet_crc<=packet_crc^{24'd0,rx_data};
                        crc_target<=CRC_PACKET;crc_steps<=8;
                        if(index==3) begin index<=0;state<=DATA;end
                        else index<=index+1'b1;
                    end
                end
                DATA: if(rx_valid) begin
                    if(crc_steps!=0) begin
                        state<=SEARCH;magic_index<=0;crc_steps<=0;reject_reason<=9;
                    end else begin
                        packet_crc<=packet_crc^{24'd0,rx_data};
                        trial_crc<=trial_crc^{24'd0,rx_data};
                        crc_target<=CRC_DATA;crc_steps<=8;
                        if(index==255) begin index<=0;state<=CRC;end
                        else index<=index+1'b1;
                    end
                end
                CRC: if(rx_valid) begin
                    received_crc<={rx_data,received_crc[31:8]};
                    if(index==3) state<=VALIDATE;else index<=index+1'b1;
                end
                VALIDATE: if(crc_steps==0) begin
                    tx_data<=8'h1f;state<=ACK;
                    reject_reason<=1;
                    if(received_crc==~packet_crc) begin
                        if(accepted_packets!=0 && packet_sequence==accepted_packets-1 && received_crc==last_crc) begin
                            tx_data<=8'h79;reject_reason<=0;
                        end else if(!allow_load) reject_reason<=3;
                        else if(model_ready) reject_reason<=4;
                        else if(packet_sequence>=packet_count) reject_reason<=5;
                        else if(packet_sequence!=accepted_packets) reject_reason<=2;
                        else begin
                            state<=FETCH;beat<=0;fetch_byte<=0;reject_reason<=0;
                        end
                    end
                end
                FETCH: state<=GET;
                GET: begin
                    payload_q<={payload_byte,payload_q[127:8]};
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
                                accepted_packets<=0;image_crc<=32'hffffffff;tx_data<=8'h1f;reject_reason<=6;
                            end
                        end
                    end else begin beat<=beat+1'b1;fetch_byte<=0;state<=FETCH;end
                end
                ACK: if(tx_ready && !tx_valid) begin
                    tx_valid<=1;state<=SEARCH;magic_index<=0;
                end
                STATUS: if(tx_ready && !tx_valid && crc_steps==0) begin
                    tx_valid<=1;
                    if(index<32) begin
                        tx_data<=status_shift[7:0];status_shift<=status_shift>>8;
                        status_crc<=status_crc^{24'd0,status_shift[7:0]};
                        crc_target<=CRC_STATUS;crc_steps<=8;
                    end else begin
                        tx_data<=~status_crc[7:0];status_crc<=status_crc>>8;
                    end
                    if(index==35) begin state<=SEARCH;magic_index<=0;end
                    else index<=index+1'b1;
                end
                endcase
            end
        end
    end
endmodule
