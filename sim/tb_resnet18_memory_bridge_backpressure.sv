`timescale 1ns/1ps
module tb_resnet18_memory_bridge_backpressure;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,calibrated=1;
    reg v_valid=0,v_read=0,n_valid=0,n_write=1;
    reg [24:0] v_addr=0;
    reg [31:0] n_addr=0;
    reg [127:0] v_data=0,n_data=0;
    reg d_read_ready=0,d_write_ready=0,d_data_ready=0,d_rsp_valid=0;
    reg [127:0] d_rsp_data=0;
    wire v_ready,n_ready,v_rsp_valid,n_rsp_valid;
    wire [127:0] v_rsp_data,n_rsp_data,d_data;
    wire [24:0] d_addr;
    wire d_read,d_addr_valid,d_data_valid,protocol_error;
    resnet18_memory_bridge dut(.*);

    reg [24:0] addresses[0:16383];
    reg reads[0:16383],owners[0:16383],return_owners[0:16383];
    reg [127:0] writes[0:16383];
    integer accepted=0,addr_count=0,write_count=0,data_count=0;
    integer return_count=0,response_count=0;
    integer total_addresses=0,total_writes=0,total_responses=0;
    integer address_wait=0,data_wait=0,simultaneous=0;
    reg v_fired=0,n_fired=0,allow_fault=0;
    always @(posedge clk) begin
        if(!rst_n) begin
            accepted=0;addr_count=0;write_count=0;data_count=0;
            return_count=0;response_count=0;v_fired=0;n_fired=0;
        end else begin
            v_fired=v_valid && v_ready;
            n_fired=n_valid && n_ready;
            if(v_fired || (n_fired && n_addr[31:26]==0 && n_addr[3:0]==0)) begin
                if(accepted==16384) $fatal(1,"Scoreboard overflow");
                addresses[accepted]=v_fired ? v_addr : n_addr[25:1];
                reads[accepted]=v_fired ? v_read : !n_write;
                owners[accepted]=!v_fired;
                if(!reads[accepted]) begin
                    writes[write_count]=v_fired ? v_data : n_data;
                    write_count=write_count+1;
                end
                accepted=accepted+1;
            end
            if(d_addr_valid) begin
                if(addr_count>=accepted || d_addr!==addresses[addr_count] ||
                   d_read!==reads[addr_count])
                    $fatal(1,"Address changed/lost during backpressure at %0d",addr_count);
                if(d_read ? d_read_ready : d_write_ready) begin
                    if(d_read) begin
                        return_owners[return_count]=owners[addr_count];
                        return_count=return_count+1;
                    end
                    addr_count=addr_count+1;total_addresses=total_addresses+1;
                end else address_wait=address_wait+1;
            end
            if(d_data_valid) begin
                if(data_count>=write_count || d_data!==writes[data_count])
                    $fatal(1,"Write data changed/lost during backpressure at %0d",data_count);
                if(d_data_ready) begin
                    data_count=data_count+1;total_writes=total_writes+1;
                end else data_wait=data_wait+1;
            end
            if(d_addr_valid && d_write_ready && d_data_valid && d_data_ready)
                simultaneous=simultaneous+1;
            if(d_rsp_valid && response_count<return_count) begin
                if({n_rsp_valid,v_rsp_valid}!==
                   (return_owners[response_count] ? 2'b10 : 2'b01) ||
                   n_rsp_data!==d_rsp_data || v_rsp_data!==d_rsp_data)
                    $fatal(1,"Response owner/data mismatch at %0d",response_count);
                response_count=response_count+1;total_responses=total_responses+1;
            end else if(v_rsp_valid || n_rsp_valid)
                $fatal(1,"Spurious response");
            if(protocol_error && !allow_fault) $fatal(1,"Unexpected protocol error");
        end
    end

    reg [31:0] random_state=32'h61ac073d;
    integer tick,phase;
    task next_random;
        begin random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]}; end
    endtask
    task drive_requests;
        input integer mode;
        begin
            next_random();
            if(!v_valid || v_fired) begin
                v_valid=mode<3 || random_state[3];
                v_read=mode==3 && random_state[4];
                v_addr={random_state[23:0],1'b0};
                v_data={random_state,~random_state,random_state^32'h531a927c,32'hfe127abc};
            end
            if(!n_valid || n_fired) begin
                n_valid=mode<3 || random_state[7];
                n_write=mode<3 || random_state[9];
                n_addr={6'd0,random_state[21:0],4'd0};
                n_data={~random_state,random_state,32'h89014fed,random_state^32'h2c730ba5};
            end
            d_read_ready=mode!=2 && (mode<3 || random_state[10]);
            d_write_ready=mode!=2 && (mode<3 || random_state[11]);
            d_data_ready=mode!=1 && (mode<3 || random_state[12]);
            d_rsp_valid=response_count<return_count && (mode<3 || random_state[13]);
            d_rsp_data={96'h12deadbeef3456789abcdef01,32'(response_count)};
        end
    endtask
    task reset_bridge;
        begin
            @(negedge clk);rst_n=0;v_valid=0;n_valid=0;d_rsp_valid=0;
            repeat(3) @(negedge clk);
            rst_n=1;allow_fault=0;
        end
    endtask
    task drain;
        integer limit;
        begin
            @(negedge clk);v_valid=0;n_valid=0;
            d_read_ready=1;d_write_ready=1;d_data_ready=1;
            for(limit=0;limit<1024;limit=limit+1) begin
                d_rsp_valid=response_count<return_count;
                @(negedge clk);
            end
            d_rsp_valid=0;
            if(accepted!=addr_count || write_count!=data_count || return_count!=response_count)
                $fatal(1,"Dropped command/data/response while draining");
        end
    endtask
    initial begin
        reset_bridge();
        for(phase=0;phase<4;phase=phase+1) begin
            for(tick=0;tick<(phase==3 ? 12000 : 128);tick=tick+1) begin
                @(negedge clk);drive_requests(phase);
            end
            if(phase==0 && addr_count<125) $fatal(1,"Lost full-rate command throughput");
        end
        drain();
        // Abort a write while each half is independently stalled.
        for(phase=1;phase<=2;phase=phase+1) begin
            for(tick=0;tick<32;tick=tick+1) begin
                @(negedge clk);drive_requests(phase);
            end
            reset_bridge();
            for(tick=0;tick<64;tick=tick+1) begin
                @(negedge clk);drive_requests(0);
            end
            drain();
        end
        // Neither invalid network command may reach the DDR interface.
        for(phase=0;phase<2;phase=phase+1) begin
            reset_bridge();
            @(negedge clk);allow_fault=1;n_valid=1;n_write=1;
            n_addr=phase==0 ? 32'h00000001 : 32'h04000000;
            repeat(8) @(negedge clk);
            n_valid=0;
            if(!protocol_error || d_addr_valid || d_data_valid)
                $fatal(1,"Invalid address issued a DDR command");
        end
        if(address_wait<100 || data_wait<100 || total_responses<100 || simultaneous<100)
            $fatal(1,"Insufficient backpressure/response coverage");
        $display("RESNET18_MEMORY_BRIDGE_BACKPRESSURE_PASS addresses=%0d writes=%0d responses=%0d addr_wait=%0d data_wait=%0d",
            total_addresses,total_writes,total_responses,address_wait,data_wait);
        $finish;
    end
    initial begin #500000; $fatal(1,"Bridge backpressure timeout"); end
endmodule
