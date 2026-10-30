`timescale 1ns/1ps

module cx_sp5t_uart_test_case #(
    parameter integer DATA_BITS=8,
    parameter integer MAX_DATA_BYTES=25
)(
    input wire clk,rst_n,
    output reg finished=0
);
    reg rx=1,start=0;
    reg [7:0] command=0;
    reg [4:0] data_count=0;
    reg [199:0] data_bytes=0;
    wire tx,ready,done,invalid_command,status_valid;
    wire [1:0] playback_status;
    integer status_events=0;
    reg [1:0] last_status=0;

    cx_sp5t_uart #(.CLOCK_HZ(96000),.BAUD(9600),
        .DEVICE_ADDRESS(16'h1234),.DATA_BITS(DATA_BITS),
        .MAX_DATA_BYTES(MAX_DATA_BYTES)) dut(
        .clk(clk),.rst_n(rst_n),.rx(rx),.tx(tx),.start(start),
        .command(command),.data_count(data_count),.data_bytes(data_bytes),
        .ready(ready),.done(done),.invalid_command(invalid_command),
        .status_valid(status_valid),.playback_status(playback_status));

    always @(posedge clk) if(status_valid) begin
        status_events=status_events+1;
        last_status=playback_status;
    end

    // Decode the serial wire independently of the DUT's internal byte bus.
    task read_byte(output reg [7:0] value);
        integer bit_index;
        begin
            @(negedge tx);
            repeat(5) @(posedge clk);
            #1;
            if(tx!==0) $fatal(1,"DATA_BITS=%0d bad UART start bit",DATA_BITS);
            for(bit_index=0;bit_index<8;bit_index=bit_index+1) begin
                repeat(10) @(posedge clk);
                #1;
                value[bit_index]=tx;
            end
            repeat(10) @(posedge clk);
            #1;
            if(tx!==1) $fatal(1,"DATA_BITS=%0d bad UART stop bit",DATA_BITS);
        end
    endtask

    task check_frame(input [7:0] opcode,input integer count,
                     input [199:0] payload_value);
        reg [7:0] expected[0:31];
        reg [7:0] actual;
        integer byte_index,sum;
        begin
            expected[0]=8'hfe;
            expected[1]=7+count;
            expected[2]=8'h12;
            expected[3]=8'h34;
            expected[4]=opcode;
            for(byte_index=0;byte_index<count;byte_index=byte_index+1)
                expected[5+byte_index]=payload_value[byte_index*8+:8];
            sum=0;
            for(byte_index=0;byte_index<5+count;byte_index=byte_index+1)
                sum=(sum+expected[byte_index])&255;
            expected[5+count]=sum;
            expected[6+count]=8'hbe;

            wait(ready);
            @(negedge clk);
            command=opcode;data_count=count;data_bytes=payload_value;start=1;
            @(negedge clk);
            start=0;
            if(invalid_command)
                $fatal(1,"DATA_BITS=%0d valid command rejected",DATA_BITS);
            for(byte_index=0;byte_index<7+count;byte_index=byte_index+1) begin
                read_byte(actual);
                if(actual!==expected[byte_index])
                    $fatal(1,"DATA_BITS=%0d command=%h count=%0d byte=%0d got=%h expected=%h",
                        DATA_BITS,opcode,count,byte_index,actual,expected[byte_index]);
            end
            wait(done);
            @(negedge clk);
            if(!ready) $fatal(1,"DATA_BITS=%0d failed to drain UART",DATA_BITS);
        end
    endtask

    task reject_command(input [7:0] opcode,input integer count);
        begin
            wait(ready);
            @(negedge clk);
            command=opcode;data_count=count;data_bytes=0;start=1;
            @(negedge clk);
            start=0;
            if(!invalid_command || !ready || tx!==1)
                $fatal(1,"DATA_BITS=%0d accepted invalid command=%h count=%0d",
                    DATA_BITS,opcode,count);
            repeat(2) @(negedge clk);
            if(invalid_command || tx!==1)
                $fatal(1,"DATA_BITS=%0d invalid command did not clear",DATA_BITS);
        end
    endtask

    task send_byte(input [7:0] value);
        integer bit_index;
        begin
            @(negedge clk);
            rx=0;
            repeat(10) @(negedge clk);
            for(bit_index=0;bit_index<8;bit_index=bit_index+1) begin
                rx=value[bit_index];
                repeat(10) @(negedge clk);
            end
            rx=1;
            repeat(10) @(negedge clk);
        end
    endtask

    task send_status(input [15:0] address,input [7:0] status,
                     input integer corrupt_checksum);
        reg [7:0] checksum;
        begin
            checksum=8'hfe+8'd8+address[15:8]+address[7:0]+8'd1+
                status+corrupt_checksum;
            send_byte(8'hfe);send_byte(8'd8);
            send_byte(address[15:8]);send_byte(address[7:0]);
            send_byte(8'd1);send_byte(status);send_byte(checksum);send_byte(8'hbe);
            repeat(3) @(negedge clk);
        end
    endtask

    reg [199:0] max_payload=0;
    integer index;
    initial begin
        wait(rst_n);
        check_frame(8'h01,0,200'd0);
        check_frame(8'h13,1,200'd30);
        for(index=0;index<MAX_DATA_BYTES;index=index+1) begin
            if(DATA_BITS==8)
                max_payload[index*8+:8]=(128+37*index)&255;
            else
                max_payload[index*8+:8]=index+1;
        end
        check_frame(8'h1b,MAX_DATA_BYTES,max_payload);
        reject_command(8'h1b,0);
        reject_command(8'h1b,26);
        if(MAX_DATA_BYTES<25) reject_command(8'h1b,MAX_DATA_BYTES+1);

        send_status(16'h1234,8'd1,1);
        send_status(16'h1235,8'd2,0);
        send_status(16'h1234,8'd3,0);
        send_status(16'h1234,8'h81,0);
        if(status_events!=0)
            $fatal(1,"DATA_BITS=%0d accepted invalid response",DATA_BITS);
        send_status(16'h1234,8'd1,0);
        if(status_events!=1 || last_status!=1)
            $fatal(1,"DATA_BITS=%0d lost playing status",DATA_BITS);
        send_status(16'h1234,8'd2,0);
        if(status_events!=2 || last_status!=2)
            $fatal(1,"DATA_BITS=%0d lost paused status",DATA_BITS);
        send_status(16'h1234,8'd0,0);
        if(status_events!=3 || last_status!=0)
            $fatal(1,"DATA_BITS=%0d lost stopped status",DATA_BITS);
        finished=1;
    end
endmodule

module tb_cx_sp5t_uart;
    reg clk=0,rst_n=0;
    wire default_finished,compact_finished;
    always #5 clk=~clk;

    cx_sp5t_uart_test_case full_width(
        .clk(clk),.rst_n(rst_n),.finished(default_finished));
    cx_sp5t_uart_test_case #(.DATA_BITS(5),.MAX_DATA_BYTES(14)) compact(
        .clk(clk),.rst_n(rst_n),.finished(compact_finished));

    initial begin
        repeat(5) @(negedge clk);
        rst_n=1;
        wait(default_finished && compact_finished);
        $display("CX_SP5T_UART_PASS count0 count1 count25 high-byte-payload bits5 count14 volume30 invalid-command checksum unicast-status");
        $finish;
    end
    initial begin
        #2000000;
        $fatal(1,"CX-SP5T UART test watchdog");
    end
endmodule
