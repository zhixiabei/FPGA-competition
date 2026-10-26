// Command buffer with independent DDR write-address/data handshakes. Read
// responses retain their owner in strict controller order. Video has priority;
// the network uses idle command slots and has only one read outstanding.
module resnet18_memory_bridge(
    input wire clk,rst_n,calibrated,
    input wire v_valid,v_read,
    input wire [24:0] v_addr,
    input wire [127:0] v_data,
    output wire v_ready,
    output wire v_rsp_valid,
    output wire [127:0] v_rsp_data,
    input wire n_valid,n_write,
    input wire [31:0] n_addr,
    input wire [127:0] n_data,
    output wire n_ready,
    output wire n_rsp_valid,
    output wire [127:0] n_rsp_data,
    output wire [24:0] d_addr,
    output wire d_read,d_addr_valid,d_data_valid,
    output wire [127:0] d_data,
    input wire d_read_ready,d_write_ready,d_data_ready,
    input wire d_rsp_valid,
    input wire [127:0] d_rsp_data,
    output reg protocol_error
);
    reg pending,p_read,p_owner,addr_done,data_done;
    reg [24:0] p_addr;
    reg [127:0] p_data;
    reg owners[0:511];
    reg [8:0] wr_ptr,rd_ptr;
    reg [9:0] count;
    wire addr_accept,data_accept;
    // Retire and replace the buffer at the same edge. A forced empty cycle
    // halves video bandwidth even when the DDR accepts a command every clock.
    wire complete=pending && (addr_done || addr_accept) &&
                  (p_read || data_done || data_accept);
    wire slot=calibrated && (!pending || complete) && count<510 && !protocol_error;
    assign v_ready=slot;
    assign n_ready=slot && !v_valid;
    assign d_addr=p_addr;
    assign d_data=p_data;
    assign d_read=p_read;
    assign d_addr_valid=pending && !addr_done;
    assign d_data_valid=pending && !p_read && !data_done;
    assign addr_accept=d_addr_valid && (p_read ? d_read_ready : d_write_ready);
    assign data_accept=d_data_valid && d_data_ready;
    wire push=addr_accept && p_read;
    wire owner=count!=0 ? owners[rd_ptr] : p_owner;
    wire pop=d_rsp_valid && (count!=0 || push);
    assign v_rsp_valid=pop && !owner;
    assign n_rsp_valid=pop && owner;
    assign v_rsp_data=d_rsp_data;
    assign n_rsp_data=d_rsp_data;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            pending<=0;p_read<=0;p_owner<=0;addr_done<=0;data_done<=0;
            p_addr<=0;p_data<=0;wr_ptr<=0;rd_ptr<=0;count<=0;protocol_error<=0;
        end else begin
            if(addr_accept) addr_done<=1;
            if(data_accept) data_done<=1;
            if(complete) pending<=0;
            // A replacement must override the retiring command's done bits.
            if(v_valid && v_ready) begin
                pending<=1;p_read<=v_read;p_owner<=0;p_addr<=v_addr;p_data<=v_data;
                addr_done<=0;data_done<=0;
            end else if(n_valid && n_ready) begin
                if(n_addr[31:26]!=0 || n_addr[3:0]!=0) begin
                    // Consume and fault the illegal command without issuing
                    // either half of a write to a truncated/wrapped address.
                    protocol_error<=1;
                end else begin
                    pending<=1;p_read<=!n_write;p_owner<=1;p_addr<=n_addr[25:1];p_data<=n_data;
                    addr_done<=0;data_done<=0;
                end
            end
            if(push) begin owners[wr_ptr]<=p_owner;wr_ptr<=wr_ptr+1'b1;end
            if(pop) rd_ptr<=rd_ptr+1'b1;
            case({push,pop})
                2'b10: count<=count+1'b1;
                2'b01: count<=count-1'b1;
            endcase
            if(d_rsp_valid && !pop) protocol_error<=1;
        end
    end
endmodule
