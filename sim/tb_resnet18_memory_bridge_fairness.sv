`timescale 1ns/1ps

module tb_resnet18_memory_bridge_fairness;
    localparam [24:0] VIDEO_ADDR = 25'h000001;
    localparam [31:0] NETWORK_ADDR = 32'h00000020;

    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0;
    reg v_valid=0,v_read=1;
    reg n_valid=0,n_write=0;
    reg d_rsp_valid=0;
    reg [127:0] d_rsp_data=0;
    wire v_ready,n_ready,v_rsp_valid,n_rsp_valid;
    wire [127:0] v_rsp_data,n_rsp_data;
    wire [24:0] d_addr;
    wire d_read,d_addr_valid,d_data_valid;
    wire [127:0] d_data;
    wire protocol_error;

    resnet18_memory_bridge #(.MAX_VIDEO_GRANTS(16)) dut(
        .clk(clk),.rst_n(rst_n),.calibrated(1'b1),
        .v_valid(v_valid),.v_read(v_read),.v_addr(VIDEO_ADDR),.v_data(128'h1111),
        .v_ready(v_ready),.v_rsp_valid(v_rsp_valid),.v_rsp_data(v_rsp_data),
        .n_valid(n_valid),.n_write(n_write),.n_addr(NETWORK_ADDR),.n_data(128'h2222),
        .n_ready(n_ready),.n_rsp_valid(n_rsp_valid),.n_rsp_data(n_rsp_data),
        .d_addr(d_addr),.d_read(d_read),.d_addr_valid(d_addr_valid),
        .d_data_valid(d_data_valid),.d_data(d_data),
        .d_read_ready(1'b1),.d_write_ready(1'b1),.d_data_ready(1'b1),
        .d_rsp_valid(d_rsp_valid),.d_rsp_data(d_rsp_data),
        .protocol_error(protocol_error));

    reg expected_owner[0:127];
    integer accepted=0,video_accepted=0,network_accepted=0;
    integer current_video_run=0,max_video_run=0;
    integer responses=0,i;

    always @(posedge clk) begin
        if(rst_n && d_addr_valid) begin
            if(!d_read) $fatal(1,"Unexpected write command");
            if(d_addr==VIDEO_ADDR) begin
                expected_owner[accepted]=0;
                video_accepted=video_accepted+1;
                current_video_run=current_video_run+1;
                if(current_video_run>max_video_run) max_video_run=current_video_run;
            end else if(d_addr==NETWORK_ADDR[25:1]) begin
                expected_owner[accepted]=1;
                network_accepted=network_accepted+1;
                current_video_run=0;
            end else $fatal(1,"Unexpected DDR address %h",d_addr);
            accepted=accepted+1;
        end
        if(d_rsp_valid) begin
            if(expected_owner[responses]) begin
                if(!n_rsp_valid || v_rsp_valid || n_rsp_data!==d_rsp_data)
                    $fatal(1,"Network response ownership corrupted at %0d",responses);
            end else begin
                if(!v_rsp_valid || n_rsp_valid || v_rsp_data!==d_rsp_data)
                    $fatal(1,"Video response ownership corrupted at %0d",responses);
            end
            responses=responses+1;
        end
        if(protocol_error) $fatal(1,"Bridge protocol_error asserted");
    end

    initial begin
        repeat(4) @(negedge clk);
        rst_n=1;v_valid=1;n_valid=1;
        while(accepted<68) @(negedge clk);
        v_valid=0;n_valid=0;
        repeat(3) @(negedge clk);
        if(network_accepted<4 || max_video_run>16)
            $fatal(1,"Fairness failed video=%0d network=%0d max_run=%0d",
                video_accepted,network_accepted,max_video_run);

        for(i=0;i<accepted;i=i+1) begin
            @(negedge clk);
            d_rsp_data={96'd0,16'(i),15'd0,expected_owner[i]};
            d_rsp_valid=1;
        end
        @(negedge clk);d_rsp_valid=0;
        repeat(3) @(negedge clk);
        if(responses!=accepted)
            $fatal(1,"Response count mismatch %0d/%0d",responses,accepted);
        $display("RESNET18_MEMORY_BRIDGE_FAIRNESS_PASS commands=%0d video=%0d network=%0d max_video_run=%0d responses=%0d",
            accepted,video_accepted,network_accepted,max_video_run,responses);
        $finish;
    end

    initial begin
        #200000;
        $fatal(1,"Bridge fairness timeout");
    end
endmodule
