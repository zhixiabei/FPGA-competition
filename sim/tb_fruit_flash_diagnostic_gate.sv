`timescale 1ns/1ps

// Exercise the real top-level generate branches and UART wire protocol.
// The core and primitive memories are idle; the packet-buffer RAM is active.
module tb_fruit_flash_diagnostic_gate;
    localparam integer UART_DIV=72;
    reg clk=0;
    always #7.5 clk=~clk;
    reg rst_n=0,rx=1,flash_calibrated=0,memory_error=0;
    wire tx_default,tx_diagnostic,tx_loader;
    wire default_valid,default_write,diagnostic_valid,diagnostic_write;
    wire [31:0] default_addr,diagnostic_addr;
    wire [127:0] default_data,diagnostic_data;
    wire [2:0] default_spi,diagnostic_spi;
    wire default_ready,diagnostic_ready;
    wire loader_valid,loader_write,loader_ready;
    wire [31:0] loader_addr;
    wire [127:0] loader_data;

    // Deliberately omit FLASH_DIAGNOSTIC_ENABLE to verify its default.
    fruitfixed_system #(.FLASH_MODEL_ENABLE(1)) default_flash(
        .clk(clk),.rst_n(rst_n),.calibrated(flash_calibrated),
        .uart_rx(rx),.uart_tx(tx_default),.memory_error(memory_error),
        .key4_n(1'b1),.run_switch(1'b0),
        .flash_cs_n(default_spi[2]),.flash_sck(default_spi[1]),
        .flash_mosi(default_spi[0]),.flash_miso(1'b1),
        .frame_start(1'b0),.frame_slot(2'd0),.video_write(1'b0),
        .video_addr(25'd0),.video_data(128'd0),
        .mem_valid(default_valid),.mem_write(default_write),
        .mem_addr(default_addr),.mem_data(default_data),.mem_ready(1'b1),
        .mem_rsp_valid(1'b0),.mem_rsp_data(128'd0),
        .result_valid(),.result_class(),.model_ready(default_ready),
        .operation(),.runtime_status(),.box_valid(),
        .box_x1(),.box_y1(),.box_x2(),.box_y2(),.result_frame());

    fruitfixed_system #(.FLASH_MODEL_ENABLE(1),.FLASH_DIAGNOSTIC_ENABLE(1)) diagnostic_flash(
        .clk(clk),.rst_n(rst_n),.calibrated(flash_calibrated),
        .uart_rx(rx),.uart_tx(tx_diagnostic),.memory_error(memory_error),
        .key4_n(1'b1),.run_switch(1'b0),
        .flash_cs_n(diagnostic_spi[2]),.flash_sck(diagnostic_spi[1]),
        .flash_mosi(diagnostic_spi[0]),.flash_miso(1'b1),
        .frame_start(1'b0),.frame_slot(2'd0),.video_write(1'b0),
        .video_addr(25'd0),.video_data(128'd0),
        .mem_valid(diagnostic_valid),.mem_write(diagnostic_write),
        .mem_addr(diagnostic_addr),.mem_data(diagnostic_data),.mem_ready(1'b1),
        .mem_rsp_valid(1'b0),.mem_rsp_data(128'd0),
        .result_valid(),.result_class(),.model_ready(diagnostic_ready),
        .operation(),.runtime_status(),.box_valid(),
        .box_x1(),.box_y1(),.box_x2(),.box_y2(),.result_frame());

    // The diagnostic parameter must not remove the alternate weight loader.
    fruitfixed_system #(.FLASH_MODEL_ENABLE(0),.FLASH_DIAGNOSTIC_ENABLE(0)) uart_loader(
        .clk(clk),.rst_n(rst_n),.calibrated(1'b1),
        .uart_rx(rx),.uart_tx(tx_loader),.memory_error(1'b0),
        .key4_n(1'b1),.run_switch(1'b0),
        .flash_cs_n(),.flash_sck(),.flash_mosi(),.flash_miso(1'b1),
        .frame_start(1'b0),.frame_slot(2'd0),.video_write(1'b0),
        .video_addr(25'd0),.video_data(128'd0),
        .mem_valid(loader_valid),.mem_write(loader_write),
        .mem_addr(loader_addr),.mem_data(loader_data),.mem_ready(1'b1),
        .mem_rsp_valid(1'b0),.mem_rsp_data(128'd0),
        .result_valid(),.result_class(),.model_ready(loader_ready),
        .operation(),.runtime_status(),.box_valid(),
        .box_x1(),.box_y1(),.box_x2(),.box_y2(),.result_frame());

    fruit_diagnostic_uart_receiver receiver_diagnostic(.clk(clk),.rst_n(rst_n),.rx(tx_diagnostic));
    fruit_diagnostic_uart_receiver receiver_loader(.clk(clk),.rst_n(rst_n),.rx(tx_loader));

    integer flash_writes=0,loader_writes=0;
    integer byte_lane;
    always @(posedge clk) if(rst_n) begin
        if(tx_default!==1'b1)
            $fatal(1,"Default Flash diagnostic UART was not disabled");
        if(default_spi!==diagnostic_spi || default_ready!==diagnostic_ready ||
           default_valid!==diagnostic_valid || default_write!==diagnostic_write)
            $fatal(1,"Diagnostic option changed Flash boot control");
        if(default_valid) begin
            if(default_addr!==diagnostic_addr || default_data!==diagnostic_data)
                $fatal(1,"Diagnostic option changed Flash DDR transaction");
            if(default_write) flash_writes=flash_writes+1;
        end
        if(loader_valid) begin
            if(!loader_write || loader_addr!==32'h00c00000+loader_writes*16)
                $fatal(1,"Alternate UART loader DDR address/command mismatch");
            for(byte_lane=0;byte_lane<16;byte_lane=byte_lane+1)
                if(loader_data[byte_lane*8 +: 8]!==((loader_writes*16+byte_lane)^8'h5a))
                    $fatal(1,"Alternate UART loader payload mismatch beat=%0d lane=%0d",
                           loader_writes,byte_lane);
            loader_writes=loader_writes+1;
        end
    end

    function [31:0] crc_byte(input [31:0] previous,input [7:0] value);
        reg [31:0] crc;
        integer bit_index;
        begin
            crc=previous^{24'd0,value};
            for(bit_index=0;bit_index<8;bit_index=bit_index+1)
                crc=(crc>>1)^(crc[0] ? 32'hedb88320 : 32'd0);
            crc_byte=crc;
        end
    endfunction

    task send_byte(input [7:0] value);
        integer bit_index;
        begin
            @(negedge clk);rx=0;
            repeat(UART_DIV) @(negedge clk);
            for(bit_index=0;bit_index<8;bit_index=bit_index+1) begin
                rx=value[bit_index];
                repeat(UART_DIV) @(negedge clk);
            end
            rx=1;
            repeat(UART_DIV) @(negedge clk);
        end
    endtask

    task send_command(input [7:0] command);
        begin send_byte("R");send_byte("1");send_byte("8");send_byte(command);end
    endtask

    task wait_replies(input integer diagnostic_count,input integer loader_count);
        integer cycles;
        begin
            cycles=0;
            while((receiver_diagnostic.count<diagnostic_count ||
                   receiver_loader.count<loader_count) && cycles<40000) begin
                @(negedge clk);cycles=cycles+1;
            end
            repeat(1000) @(negedge clk);
            if(receiver_diagnostic.count!=diagnostic_count || receiver_loader.count!=loader_count)
                $fatal(1,"UART reply lengths diagnostic=%0d/%0d loader=%0d/%0d",
                       receiver_diagnostic.count,diagnostic_count,receiver_loader.count,loader_count);
        end
    endtask

    task check_status(input integer diagnostic,input integer base,input [255:0] payload);
        reg [31:0] crc;
        reg [7:0] expected,actual;
        integer index;
        begin
            crc=32'hffffffff;
            for(index=0;index<36;index=index+1) begin
                if(index<32) begin
                    expected=payload[index*8 +: 8];
                    crc=crc_byte(crc,expected);
                end else expected=(~crc)>>((index-32)*8);
                actual=diagnostic ? receiver_diagnostic.bytes[base+index] :
                                   receiver_loader.bytes[base+index];
                if(actual!==expected)
                    $fatal(1,"Status/CRC mismatch diagnostic=%0d byte=%0d actual=%02x expected=%02x",
                           diagnostic,index,actual,expected);
            end
        end
    endtask

    reg [255:0] diagnostic_status,loader_status,flash_status;
    reg [31:0] packet_crc;
    integer index;
    initial begin
        repeat(8) @(negedge clk);rst_n=1;
        repeat(20) @(negedge clk);
        diagnostic_status=diagnostic_flash.status_packet;
        loader_status=uart_loader.status_packet;
        send_command("S");
        wait_replies(36,36);
        check_status(1,0,diagnostic_status);
        check_status(0,0,loader_status);

        flash_status=diagnostic_flash.flash_model.flash_diagnostics;
        send_command("F");
        wait_replies(72,36);
        check_status(1,36,flash_status);

        // A complete valid R18D packet proves that disabling Flash diagnostics
        // leaves the alternate production UART-to-DDR path operational.
        packet_crc=32'hffffffff;
        send_command("D");
        for(index=0;index<4;index=index+1) begin
            send_byte(8'd0);packet_crc=crc_byte(packet_crc,8'd0);
        end
        for(index=0;index<256;index=index+1) begin
            send_byte(index[7:0]^8'h5a);
            packet_crc=crc_byte(packet_crc,index[7:0]^8'h5a);
        end
        packet_crc=~packet_crc;
        for(index=0;index<4;index=index+1) send_byte(packet_crc[index*8 +: 8]);
        wait_replies(72,37);
        if(receiver_loader.bytes[36]!==8'h79 || loader_writes!=16 ||
           uart_loader.uart_model.loader.accepted_packets!==32'd1 || loader_ready)
            $fatal(1,"Alternate UART model packet not accepted exactly once");

        send_command("L");
        wait_replies(72,73);
        if({receiver_loader.bytes[40],receiver_loader.bytes[39],
            receiver_loader.bytes[38],receiver_loader.bytes[37]}!==32'h4c383152 ||
           receiver_loader.bytes[45]!==8'd1)
            $fatal(1,"Alternate UART loader R18L identity/progress mismatch");

        // Compare both Flash boot implementations while real SPI and DDR
        // writes are active, then confirm an error is still diagnosable.
        flash_calibrated=1;
        repeat(5000) @(negedge clk);
        if(flash_writes==0) $fatal(1,"Flash boot never issued a DDR write");
        memory_error=1;
        repeat(20) @(negedge clk);
        flash_status=diagnostic_flash.flash_model.flash_diagnostics;
        if(flash_status[63:56]!==8'd0 || flash_status[55:48]!==8'd4)
            $fatal(1,"Flash memory-error guard changed");
        send_command("F");
        wait_replies(108,73);
        check_status(1,72,flash_status);
        $display("FRUIT_FLASH_DIAGNOSTIC_GATE_PASS default_uart_idle=1 enabled_R18S_R18F_crc=1 uart_R18D_R18L=1 loader_ddr_beats=%0d flash_boot_equal=1 flash_writes=%0d",
                 loader_writes,flash_writes);
        $finish;
    end
    initial begin #20000000;$fatal(1,"Flash diagnostic gate timeout");end
endmodule

// Independent wire-level 8N1 receiver, sampling at the center of each bit.
module fruit_diagnostic_uart_receiver(input wire clk,rst_n,rx);
    localparam integer UART_DIV=72;
    reg [7:0] bytes [0:127];
    integer count=0;
    integer bit_index;
    reg [7:0] value;
    always @(negedge rx) if(rst_n) begin
        repeat(UART_DIV/2) @(posedge clk);#1;
        if(rx!==1'b0) $fatal(1,"UART response start bit");
        for(bit_index=0;bit_index<8;bit_index=bit_index+1) begin
            repeat(UART_DIV) @(posedge clk);#1;value[bit_index]=rx;
        end
        repeat(UART_DIV) @(posedge clk);#1;
        if(rx!==1'b1) $fatal(1,"UART response stop bit");
        if(count>=128) $fatal(1,"UART response overflow");
        bytes[count]=value;count=count+1;
    end
endmodule
