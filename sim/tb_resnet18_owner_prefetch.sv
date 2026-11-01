`timescale 1ns/1ps
module tb_resnet18_owner_prefetch;
    reg clk=0,rst_n=0,calibrated=1;
    always #5 clk=~clk;
    reg v_valid=0,v_read=1,n_valid=0,n_write=0;
    reg [24:0] v_addr=0;
    reg [31:0] n_addr=0;
    reg [127:0] v_data=0,n_data=0,d_rsp_data=0;
    reg d_read_ready=1,d_write_ready=1,d_data_ready=1;
    reg response=0,immediate=0;
    wire v_ready,n_ready,v_rsp_valid,n_rsp_valid;
    wire [127:0] v_rsp_data,n_rsp_data,d_data;
    wire [24:0] d_addr;
    wire d_read,d_addr_valid,d_data_valid,protocol_error;
    wire d_rsp_valid=immediate ? d_addr_valid && d_read && d_read_ready : response;
    resnet18_memory_bridge dut(.*);

    reg expected_commands[0:32767];
    reg expected_returns[0:32767];
    integer commands=0,address_count=0,returns=0,responses=0;
    integer checked=0,empty_returns=0,replacements=0,max_outstanding=0;
    integer cycles;
    reg [31:0] rng=32'h4d7bac12;
    always @(posedge clk) begin
        if(!rst_n) begin
            commands=0;address_count=0;returns=0;responses=0;
        end else begin
            if(v_valid && v_ready) begin
                expected_commands[commands]=0;commands=commands+1;
            end else if(n_valid && n_ready) begin
                expected_commands[commands]=1;commands=commands+1;
            end
            if(d_addr_valid && (d_read ? d_read_ready : d_write_ready)) begin
                if(address_count>=commands) $fatal(1,"Unrequested DDR command");
                if(d_read) begin
                    expected_returns[returns]=expected_commands[address_count];
                    returns=returns+1;
                end
                address_count=address_count+1;
            end
            if(d_rsp_valid) begin
                if(responses>=returns || {n_rsp_valid,v_rsp_valid}!==
                    (expected_returns[responses] ? 2'b10 : 2'b01))
                    $fatal(1,"Owner mismatch at response %0d",responses);
                responses=responses+1;checked=checked+1;
                if(dut.count==0) empty_returns=empty_returns+1;
                if(dut.count==1 && dut.push) replacements=replacements+1;
            end
            if(dut.count>max_outstanding) max_outstanding=dut.count;
            if(protocol_error) $fatal(1,"Unexpected bridge protocol error");
        end
    end
    task drain;
        begin
            @(negedge clk);v_valid=0;n_valid=0;immediate=0;
            d_read_ready=1;d_write_ready=1;d_data_ready=1;
            repeat(1024) begin response=responses<returns;@(negedge clk);end
            response=0;
            if(commands!=address_count || responses!=returns) $fatal(1,"Drain mismatch");
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);
        rst_n=1;v_valid=1;n_valid=1;
        // Reach the outstanding-credit limit and wrap both pointer counters.
        repeat(600) @(negedge clk);
        if(max_outstanding<510) $fatal(1,"Did not fill owner queue");
        response=1;
        repeat(2200) @(negedge clk);
        drain();
        // A zero-latency DDR responder bypasses an empty owner queue.
        v_valid=1;n_valid=1;immediate=1;
        repeat(1300) @(negedge clk);
        drain();
        // Keep one queued owner while a new owner arrives on each return.
        v_valid=1;n_valid=1;
        repeat(2) @(negedge clk);
        response=1;
        repeat(1100) @(negedge clk);
        drain();
        // Exercise both independent write handshakes mixed with read owners.
        for(cycles=0;cycles<16000;cycles=cycles+1) begin
            rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
            v_valid=rng[0];n_valid=rng[1];v_read=rng[2];n_write=rng[3];
            d_read_ready=rng[4];d_write_ready=rng[5];d_data_ready=rng[6];
            response=responses<returns && rng[7];
            @(negedge clk);
        end
        drain();
        // Reset with live entries; no stale owner may escape after restart.
        v_valid=1;n_valid=1;v_read=1;n_write=0;
        repeat(40) @(negedge clk);
        rst_n=0;v_valid=0;n_valid=0;response=0;
        repeat(4) @(negedge clk);
        rst_n=1;v_valid=1;n_valid=1;immediate=1;
        repeat(1100) @(negedge clk);
        drain();
        if(checked<5000 || empty_returns<1000 || replacements<1000)
            $fatal(1,"Insufficient coverage: checked=%0d empty=%0d replacements=%0d",
                checked,empty_returns,replacements);
        $display("RESNET18_OWNER_PREFETCH_PASS responses=%0d empty=%0d replacements=%0d max_outstanding=%0d added_clocks=0",
            checked,empty_returns,replacements,max_outstanding);
        $finish;
    end
    initial begin #400000; $fatal(1,"Owner prefetch timeout"); end
endmodule
