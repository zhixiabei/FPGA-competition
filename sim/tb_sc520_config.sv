`timescale 1ns/1ps

// Exercise the real configuration controller and its I2C engine through SCL/SDA.
// The sensor model implements the ID registers and accepts register writes;
// it does not model MIPI, exposure physics, or the sensor's internal analog state.
module tb_sc520_config #(
    parameter integer BUS_DIV = 15
);
    reg clk = 0;
    always #21 clk = ~clk;
    reg rst_n = 0;
    reg ae_req = 0;
    reg [15:0] exposure = 16'h1234;
    reg [15:0] gain = 16'd144;
    wire scl, cfg_done, ae_done, id_ok, bus_error;
    wire [15:0] sensor_id;
    wire [7:0] fail_index;
    tri1 sda;
    reg sensor_low = 0;
    assign sda = sensor_low ? 1'b0 : 1'bz;

    uicfgcs520 #(.CLK_DIV(BUS_DIV)) dut (
        .I_clk(clk), .I_rst_n(rst_n), .I_ae_req(ae_req),
        .I_ae(exposure), .I_ag(gain), .O_cam_scl(scl), .IO_cam_sda(sda),
        .O_cfg_done(cfg_done), .O_ae_cfg_done(ae_done),
        .O_sensor_id(sensor_id), .O_sensor_id_ok(id_ok),
        .O_iic_error(bus_error), .O_fail_index(fail_index)
    );

    reg [15:0] model_id = 16'hee4b;
    integer nack_at = -1;
    integer nack_once_at = -1;
    integer nack_byte_index = 0;
    integer byte_index = 0;
    integer stops = 0;
    integer ack_delay_ns = 0;
    integer transactions = 0;
    integer writes = 0;
    reg [15:0] write_addr [0:255];
    reg [7:0] write_value [0:255];
    reg [7:0] registers [0:65535];
    reg [15:0] pointer;
    reg [7:0] address_byte, high_byte, low_byte, data_byte;
    time reset_write_time, second_write_time;

    task automatic wait_start;
        begin : find_start
            forever begin
                @(negedge sda);
                if (scl === 1'b1) disable find_start;
            end
        end
    endtask

    task automatic wait_stop;
        begin : find_stop
            forever begin
                @(posedge sda);
                if (scl === 1'b1) begin
                    stops = stops + 1;
                    disable find_stop;
                end
            end
        end
    endtask

    task automatic receive_byte(output reg [7:0] value, output reg acked);
        integer bit_index;
        integer stop_clocks;
        begin
            for (bit_index = 7; bit_index >= 0; bit_index = bit_index - 1) begin
                @(posedge scl);
                value[bit_index] = sda;
            end
            @(negedge scl);
            acked = (nack_at < 0 || transactions < nack_at) &&
                    !(transactions == nack_once_at && byte_index == nack_byte_index);
            #(ack_delay_ns);
            sensor_low = acked;
            @(posedge scl);
            @(negedge scl);
            sensor_low = 0;
            byte_index = byte_index + 1;
            if (!acked) begin
                stop_clocks = 0;
                fork : nack_stop
                    wait_stop();
                    forever begin
                        @(posedge scl);
                        stop_clocks = stop_clocks + 1;
                    end
                join_any
                disable nack_stop;
                if (stop_clocks != 1)
                    $fatal(1, "NACK must abort the byte stream and generate STOP");
            end
        end
    endtask

    // Check Standard-mode limits using the actual project divider (237).
    time scl_rise_time, scl_fall_time, start_time, stop_time;
    reg high_valid = 0, low_valid = 0, start_pending = 0, stop_valid = 0;
    always @(negedge rst_n) begin
        high_valid = 0;
        low_valid = 0;
        start_pending = 0;
        stop_valid = 0;
    end
    always @(posedge scl) if (rst_n && BUS_DIV >= 200) begin
        if (low_valid && $time - scl_fall_time < 4700)
            $fatal(1, "SCL low interval shorter than 4.7 us");
        scl_rise_time = $time;
        high_valid = 1;
    end
    always @(negedge scl) if (rst_n && BUS_DIV >= 200) begin
        if (high_valid && $time - scl_rise_time < 4000)
            $fatal(1, "SCL high interval shorter than 4 us");
        if (start_pending && $time - start_time < 4000)
            $fatal(1, "START hold shorter than 4 us");
        start_pending = 0;
        scl_fall_time = $time;
        low_valid = 1;
    end
    always @(negedge sda) if (rst_n && BUS_DIV >= 200 && scl === 1'b1) begin
        if (high_valid && $time - scl_rise_time < 4700)
            $fatal(1, "Repeated START setup shorter than 4.7 us");
        if (stop_valid && $time - stop_time < 4700)
            $fatal(1, "Bus free interval shorter than 4.7 us");
        start_time = $time;
        start_pending = 1;
    end
    always @(posedge sda) if (rst_n && BUS_DIV >= 200 && scl === 1'b1) begin
        if (high_valid && $time - scl_rise_time < 4000)
            $fatal(1, "STOP setup shorter than 4 us");
        stop_time = $time;
        stop_valid = 1;
    end

    task automatic transmit_byte(input [7:0] value);
        integer bit_index;
        begin
            for (bit_index = 7; bit_index >= 0; bit_index = bit_index - 1) begin
                sensor_low = !value[bit_index];
                @(posedge scl);
                @(negedge scl);
            end
            sensor_low = 0;
            @(posedge scl);
            if (sda !== 1'b1) $fatal(1, "Master must NACK the final ID byte");
        end
    endtask

    initial forever begin
        wait(rst_n);
        fork : sensor_session
            begin
                forever begin : sensor_transaction
                    reg acked;
                    wait_start();
                    transactions = transactions + 1;
                    byte_index = 0;
                    receive_byte(address_byte, acked);
                    if (!acked) disable sensor_transaction;
                    if (address_byte == 8'h6c) begin
                        receive_byte(high_byte, acked);
                        if (!acked) disable sensor_transaction;
                        receive_byte(low_byte, acked);
                        if (!acked) disable sensor_transaction;
                        pointer = {high_byte, low_byte};
                        if (pointer != 16'h3107 && pointer != 16'h3108) begin
                            receive_byte(data_byte, acked);
                            if (!acked) disable sensor_transaction;
                            if (writes == 0) reset_write_time = $time;
                            if (writes == 1) second_write_time = $time;
                            write_addr[writes] = pointer;
                            write_value[writes] = data_byte;
                            registers[pointer] = data_byte;
                            writes = writes + 1;
                            wait_stop();
                        end
                    end else if (address_byte == 8'h6d) begin
                        if (pointer == 16'h3107) transmit_byte(model_id[15:8]);
                        else if (pointer == 16'h3108) transmit_byte(model_id[7:0]);
                        else $fatal(1, "Unexpected sensor read at %h", pointer);
                        wait_stop();
                    end else $fatal(1, "Incorrect sensor address %h", address_byte);
                end
            end
            begin
                @(negedge rst_n);
            end
        join_any
        disable sensor_session;
        sensor_low = 0;
    end

    task automatic restart(input [15:0] id, input integer nack_transaction);
        begin
            @(negedge clk);
            rst_n = 0;
            ae_req = 0;
            repeat (50) @(negedge clk);
            model_id = id;
            nack_at = nack_transaction;
            nack_once_at = -1;
            nack_byte_index = 0;
            ack_delay_ns = 0;
            writes = 0;
            transactions = 0;
            stops = 0;
            rst_n = 1;
        end
    endtask

    task automatic verify_init;
        begin
            wait(cfg_done || bus_error);
            #1;
            if (bus_error)
                $fatal(1, "Initialization stopped at %h instead of recovering a transient NACK", fail_index);
            if (sensor_id !== model_id || !id_ok || bus_error || !ae_done)
                $fatal(1, "Incorrect successful initialization flags");
            if (writes != 165) $fatal(1, "Expected 165 init writes, got %0d", writes);
            if (write_addr[0] != 16'h0103 || write_value[0] != 1)
                $fatal(1, "Software reset must be first");
            if (second_write_time - reset_write_time < 5000000)
                $fatal(1, "Software-reset delay shorter than 5 ms");
            if ({registers[16'h3208], registers[16'h3209]} !== 16'd1280 ||
                {registers[16'h320a], registers[16'h320b]} !== 16'd720)
                $fatal(1, "Incorrect output resolution");
            if (registers[16'h3220] !== 8'h81 || registers[16'h3222] !== 0)
                $fatal(1, "Free-run mode not configured");
            if (write_addr[164] != 16'h0100 || write_value[164] != 1)
                $fatal(1, "Stream-on must be last");
            $display("PASS: ID %h, 165 initialization writes, 720p, free-run, reset delay", model_id);
        end
    endtask

    task automatic request_ae;
        begin
            @(negedge clk); ae_req = 1;
            wait(!ae_done);
            @(negedge clk); ae_req = 0;
        end
    endtask

    task automatic verify_error;
        integer stopped_at;
        begin
            wait(bus_error);
            repeat (2000) @(negedge clk);
            stopped_at = transactions;
            repeat (2000) @(negedge clk);
            if (cfg_done || ae_done || !bus_error || transactions != stopped_at)
                $fatal(1, "I2C error must latch, clear done, and stop new requests");
            if (scl !== 1'b1 || sda !== 1'b1 || dut.iic_busy)
                $fatal(1, "Failed transaction must finish STOP and release the bus");
        end
    endtask

    initial begin
        // A global bound catches a wedged controller or an invalid bus sequence.
        #600000000;
        $fatal(1, "SC520 simulation timed out: state=%0d writes=%0d ID=%h", dut.state, writes, sensor_id);
    end

    initial begin
        // The board reports table index 03. Reject exactly this write once.
        // Unlike the old model, a rejected byte ends at STOP before another START.
        restart(16'hee4b, -1);
        nack_once_at = 8;
        nack_byte_index = 3;
        ack_delay_ns = BUS_DIV >= 200 ? 3400 : ((BUS_DIV + 4) / 4) * 42 - 21;
        verify_init();
        if (transactions != 170 || stops != 168)
            $fatal(1, "Index 03 must be retried once after a complete STOP");
        $display("PASS: transient NACK at index 03 recovers with delayed ACK");
        if (BUS_DIV >= 200) begin
            $display("SC520_CONFIG_TEST_PASS: actual divider, delayed ACK, START/STOP timing");
            $finish;
        end

        restart(16'hee4b, -1);
        verify_init();
        request_ae();
        wait(ae_done);
        #1;
        if (writes != 173 || !cfg_done || bus_error) $fatal(1, "AE update incomplete");
        if (write_addr[165] != 16'h3812 || write_value[165] != 0 ||
            write_addr[172] != 16'h3812 || write_value[172] != 8'h30)
            $fatal(1, "AE group hold sequence incorrect");
        if (registers[16'h3e00] !== 8'h01 || registers[16'h3e01] !== 8'h23 ||
            registers[16'h3e02] !== 8'h40 || registers[16'h3e09] !== 8'h0f ||
            registers[16'h3e06] !== 0 || registers[16'h3e07] !== 8'h80)
            $fatal(1, "Exposure or gain packing incorrect");
        $display("PASS: exposure 0x1234, gain 144, eight writes with group hold");

        nack_at = transactions + 1;
        request_ae();
        verify_error();
        $display("PASS: NACK during AE stops configuration and clears done");

        restart(16'h9e4b, -1);
        verify_init();
        $display("PASS: reset recovers from latched error");

        restart(16'h1234, -1);
        wait(sensor_id == 16'h1234);
        repeat (2000) @(negedge clk);
        if (cfg_done || ae_done || id_ok || bus_error || writes != 0)
            $fatal(1, "Wrong sensor ID must block initialization");
        $display("PASS: wrong sensor ID blocks register writes");

        restart(16'hee4b, 1);
        verify_error();
        if (writes != 0) $fatal(1, "Missing camera must not receive init writes");
        if (transactions != 4 || stops != 4)
            $fatal(1, "Missing camera must stop after four bounded attempts");
        $display("PASS: missing-camera NACK latches error");

        restart(16'hee4b, 10);
        verify_error();
        if (fail_index !== 8'd5)
            $fatal(1, "Expected NACK at init table index 5, got %0d", fail_index);
        $display("PASS: initialization NACK cannot report success");

        restart(16'hee4b, 8);
        verify_error();
        if (fail_index !== 8'd3 || writes != 3 || transactions != 11 || stops != 9)
            $fatal(1, "Persistent index 03 NACK must fail after four attempts without skipping");
        $display("PASS: persistent index 03 NACK stops without skipping the register");

        restart(16'hee4b, -1);
        nack_once_at = 2;
        verify_init();
        if (transactions != 171 || stops != 168)
            $fatal(1, "Failed repeated-START read must retry the complete ID transaction");
        $display("PASS: ID read-address NACK retries the complete read");

        for (nack_byte_index = 0; nack_byte_index < 3; nack_byte_index = nack_byte_index + 1) begin : retry_each_byte
            integer failed_byte;
            failed_byte = nack_byte_index;
            restart(16'hee4b, -1);
            nack_once_at = 8;
            nack_byte_index = failed_byte;
            verify_init();
            if (transactions != 170 || stops != 168)
                $fatal(1, "Incorrect retry after NACK of byte %0d", failed_byte);
            $display("PASS: index 03 retries after NACK of byte %0d", failed_byte);
        end
        $display("SC520_CONFIG_TEST_PASS");
        $finish;
    end
endmodule
