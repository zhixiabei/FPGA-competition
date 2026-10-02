`timescale 1ns/1ps

// Exercise the real configuration controller and uii2c through SCL/SDA.
// The sensor model implements the ID registers and accepts register writes;
// it does not model MIPI, exposure physics, or the sensor's internal analog state.
module tb_sc520_config;
    reg clk = 0;
    always #21 clk = ~clk;
    reg rst_n = 0;
    reg ae_req = 0;
    reg [15:0] exposure = 16'h1234;
    reg [15:0] gain = 16'd144;
    wire scl, cfg_done, ae_done, id_ok, bus_error;
    wire [15:0] sensor_id;
    tri1 sda;
    reg sensor_low = 0;
    assign sda = sensor_low ? 1'b0 : 1'bz;

    uicfgcs520 #(.CLK_DIV(15)) dut (
        .I_clk(clk), .I_rst_n(rst_n), .I_ae_req(ae_req),
        .I_ae(exposure), .I_ag(gain), .O_cam_scl(scl), .IO_cam_sda(sda),
        .O_cfg_done(cfg_done), .O_ae_cfg_done(ae_done),
        .O_sensor_id(sensor_id), .O_sensor_id_ok(id_ok), .O_iic_error(bus_error)
    );

    reg [15:0] model_id = 16'hee4b;
    integer nack_at = -1;
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

    task automatic receive_byte(output reg [7:0] value);
        integer bit_index;
        begin
            for (bit_index = 7; bit_index >= 0; bit_index = bit_index - 1) begin
                @(posedge scl);
                value[bit_index] = sda;
            end
            @(negedge scl);
            sensor_low = (nack_at < 0 || transactions < nack_at);
            @(posedge scl);
            @(negedge scl);
            sensor_low = 0;
        end
    endtask

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
                forever begin
                    wait_start();
                    transactions = transactions + 1;
                    receive_byte(address_byte);
                    if (address_byte == 8'h6c) begin
                        receive_byte(high_byte);
                        receive_byte(low_byte);
                        pointer = {high_byte, low_byte};
                        if (pointer != 16'h3107 && pointer != 16'h3108) begin
                            receive_byte(data_byte);
                            if (writes == 0) reset_write_time = $time;
                            if (writes == 1) second_write_time = $time;
                            write_addr[writes] = pointer;
                            write_value[writes] = data_byte;
                            registers[pointer] = data_byte;
                            writes = writes + 1;
                        end
                    end else if (address_byte == 8'h6d) begin
                        if (pointer == 16'h3107) transmit_byte(model_id[15:8]);
                        else if (pointer == 16'h3108) transmit_byte(model_id[7:0]);
                        else $fatal(1, "Unexpected sensor read at %h", pointer);
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
            writes = 0;
            transactions = 0;
            rst_n = 1;
        end
    endtask

    task automatic verify_init;
        begin
            wait(cfg_done);
            #1;
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
        end
    endtask

    initial begin
        // A global bound catches a wedged controller or an invalid bus sequence.
        #60000000;
        $fatal(1, "SC520 simulation timed out: state=%0d writes=%0d ID=%h", dut.state, writes, sensor_id);
    end

    initial begin
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
        $display("PASS: missing-camera NACK latches error");

        restart(16'hee4b, 10);
        verify_error();
        $display("PASS: initialization NACK cannot report success");
        $display("SC520_CONFIG_TEST_PASS");
        $finish;
    end
endmodule
