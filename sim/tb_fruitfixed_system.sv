`timescale 1ns/1ps
module tb_fruitfixed_system;
    reg clk=0;
    always #7.5 clk=~clk;
    reg rst_n=0,calibrated=0;
    wire result_valid,box_valid;
    wire [2:0] result_class;
    wire [11:0] x1,y1,x2,y2;
    wire [15:0] result_frame;
    wire [31:0] runtime_status;
    fruitfixed_system #(.KEY4_CONTROL(1),.BACKGROUND_CONTROL(1),.KEY_DEBOUNCE_CYCLES(4)) dut(
        .clk(clk),.rst_n(rst_n),.calibrated(calibrated),.uart_rx(1'b1),.memory_error(1'b0),
        .key4_n(1'b1),.uart_tx(),.frame_start(1'b0),.frame_slot(2'b0),
        .video_write(1'b0),.video_addr(25'b0),.video_data(128'b0),
        .mem_valid(),.mem_write(),.mem_addr(),.mem_data(),
        .mem_ready(1'b0),.mem_rsp_valid(1'b0),.mem_rsp_data(128'b0),
        .result_valid(result_valid),.result_class(result_class),.model_ready(),
        .operation(),.runtime_status(runtime_status),.box_valid(box_valid),
        .box_x1(x1),.box_y1(y1),.box_x2(x2),.box_y2(y2),.result_frame(result_frame));

    task publish(input [2:0] raw_class,input [2:0] expected_class);
        begin
            @(negedge clk);
            dut.state=3'd6;
            force dut.dec_done=1'b1;
            force dut.dec_class=raw_class;
            @(posedge clk);#1;
            if(!result_valid || result_class!==expected_class || !box_valid ||
               x1!=400 || y1!=120 || x2!=880 || y2!=600)
                $fatal(1,"published class=%0d expected=%0d raw=%0d",result_class,expected_class,raw_class);
            release dut.dec_done;
            release dut.dec_class;
        end
    endtask

    integer c;
    initial begin
        repeat(6) @(negedge clk);
        rst_n=1;
        calibrated=1;
        repeat(20) @(negedge clk);
        if(dut.snap_busy || dut.snap_start || dut.capture_phase!=0)
            $fatal(1,"pre-model background capture contends with UART loading");
        force dut.key_enabled=1'b1;
        // Unknown to fruit takes two results; changing fruit takes three.
        publish(3'd2,3'd1);
        publish(3'd2,3'd2);
        for(c=3;c<=6;c=c+1) begin
            publish(c[2:0],(c-1));
            publish(c[2:0],(c-1));
            publish(c[2:0],c[2:0]);
        end
        if(dut.status_packet[31:0]!==32'h31555246 ||
           dut.status_packet[39:32]!==8'd1 ||
           dut.status_packet[50:48]!==3'd6 ||
           dut.status_packet[79:64]!==16'd14)
            $fatal(1,"FRU1 status header/class/count mismatch");
        dut.decode.logits[0]=16'd1;
        dut.decode.logits[1]=16'd2;
        dut.decode.logits[2]=16'd3;
        dut.decode.logits[3]=16'd4;
        dut.decode.logits[4]=16'd5;
        #1;
        if(dut.status_packet[175:96]!==80'h00050004000300020001 ||
           dut.status_packet[255:240]!==dut.mac_cycles[15:0])
            $fatal(1,"five-logit status layout mismatch packed=%h logits=%h mac=%h status_mac=%h",
                   dut.status_packet[175:96],dut.logits,dut.mac_cycles[15:0],dut.status_packet[255:240]);
        $display("FRUIT_SYSTEM_PASS five_classes roi_400_120_480 FRU1 five_logits result_count=%0d",dut.result_count);
        $finish;
    end
    initial begin #100000; $fatal(1,"fruit system timeout"); end
endmodule
