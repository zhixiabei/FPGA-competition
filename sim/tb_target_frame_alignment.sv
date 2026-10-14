`timescale 1ns/1ps
// Integration boundary:
//   Real DUT: design_top_wrapper, video_in, video_out, hdmi_mixer.
//   Forced inputs: independent clocks/reset, ISP frame marker/results, HDMI
//   scan markers, and inactive FIFO occupancy. Camera/ISP algorithms, DDR
//   transactions, PLL and display timing generation are outside this test.
//   Reference slot tags come from actual DDR base addresses, not the new
//   metadata status outputs or the RTL's pointer arithmetic.
// Compile with TARGET_ALIGNMENT_STUBS for the self-contained non-tested
// peripheral declarations at the end of this file. Compile the real Logo
// ROM and character library alongside the real mixer.
module tb_target_frame_alignment;
    reg csi_clk = 0, hdmi_clk = 0, ddr_clk = 0;
    always #7 csi_clk = ~csi_clk;
    always #5.5 hdmi_clk = ~hdmi_clk;
    always #3 ddr_clk = ~ddr_clk;

    reg rst_n = 0;
    reg camera_user = 0, result_ready = 0, result_found = 0;
    reg [11:0] result_xmin = 0, result_xmax = 0;
    reg [11:0] result_ymin = 0, result_ymax = 0;
    reg [11:0] result_cx = 0, result_cy = 0;
    reg hdmi_vs = 1, hdmi_hs = 0, hdmi_de = 0;
    reg hdmi_user = 0, hdmi_last = 0;
    reg camera_error = 0, camera_pause = 0;
    reg edge_mode = 0;
    reg [3:0] diagnostic_status = 0;
    reg [7:0] diagnostic_fail = 0;
    reg status_i2c_ready = 0, status_cfg_done = 0, status_ae_done = 1;
    reg status_sensor_ok = 0, status_i2c_error = 0;
    reg [15:0] status_exposure = 1000, status_gain = 16;

    integer ref_frame [0:3];
    bit ref_valid [0:3];
    bit ref_found [0:3];
    bit ref_edge [0:3];
    integer active_frame = -1;
    integer write_events = 0, read_events = 0, display_checks = 0;
    integer result_checks = 0, invalidate_checks = 0;
    integer diagnostic_checks = 0;
    integer actual_status_checks = 0;
    integer actual_write_slot = -1, actual_read_slot = -1;
    integer request_count = 0;
    reg request_seen = 0;

    // RAW readout is verified separately with the real tap/CDC/HDMI chain.
    design_top_wrapper #(.SHOW_RAW_STATS(0)) dut (
        .I_sys_clk(ddr_clk), .I_rst_n(rst_n), .I_mode_key_n(1'b1)
    );

    function automatic integer slot_of_base(input [24:0] address);
        case (address)
            25'd0: slot_of_base = 0;
            25'd7000000: slot_of_base = 1;
            25'd14000000: slot_of_base = 2;
            25'd21000000: slot_of_base = 3;
            default: slot_of_base = -1;
        endcase
    endfunction

    function automatic bit frame_has_target(input integer id);
        frame_has_target = ((id % 5) != 1);
    endfunction
    function automatic integer frame_xmin(input integer id);
        frame_xmin = id == 28 ? 1268 : 300 + id * 7;
    endfunction
    function automatic integer frame_xmax(input integer id);
        frame_xmax = id == 28 ? 1278 : frame_xmin(id)+40;
    endfunction
    function automatic integer frame_ymin(input integer id);
        frame_ymin = id == 28 ? 710 : 180 + (id % 7) * 4;
    endfunction
    function automatic integer frame_ymax(input integer id);
        frame_ymax = id == 28 ? 719 : frame_ymin(id)+30;
    endfunction
    function automatic integer display_x(input integer value, input bit edge_on);
        display_x = edge_on ? (value+3 > 1279 ? 1279 : value+3) : value;
    endfunction
    function automatic integer display_y(input integer value, input bit edge_on);
        display_y = edge_on ? (value+3 > 719 ? 719 : value+3) : value;
    endfunction

    // The addresses below are the existing DDR control path. Metadata output
    // pins are checked against them, never used to derive the reference.
    always @(posedge ddr_clk) begin
        if (rst_n && dut.u_video_in.S_frame_start) begin
            #1;
            actual_write_slot = slot_of_base(dut.S_vi_ddr_wr_addr);
            if (actual_write_slot < 0)
                $fatal(1, "Unexpected write base address %0d", dut.S_vi_ddr_wr_addr);
            if (dut.S_write_frame_slot !== actual_write_slot[1:0])
                $fatal(1, "Write status disagrees with actual DDR base");
            ref_frame[actual_write_slot] = active_frame;
            ref_valid[actual_write_slot] = 0;
            ref_found[actual_write_slot] = 0;
            ref_edge[actual_write_slot] = edge_mode;
            write_events = write_events + 1;
        end
    end
    always @(posedge ddr_clk) begin
        if (rst_n && dut.u_video_out.S_video_frame_start) begin
            #1;
            actual_read_slot = slot_of_base(dut.S_vo_ddr_rd_addr);
            if (actual_read_slot < 0)
                $fatal(1, "Unexpected read base address %0d", dut.S_vo_ddr_rd_addr);
            if (dut.S_read_frame_slot !== actual_read_slot[1:0])
                $fatal(1, "Read status disagrees with actual DDR base");
            read_events = read_events + 1;
        end
    end
    always @(posedge csi_clk) begin
        if (!rst_n)
            request_seen = 0;
        else begin
            #1;
            if (dut.S_target_request != request_seen) begin
                request_count = request_count + 1;
                request_seen = dut.S_target_request;
            end
        end
    end

    task automatic mailbox_idle;
        integer limit;
        begin
            limit = 0;
            while (dut.S_target_request !== dut.S_target_ack_sync) begin
                @(negedge csi_clk);
                limit = limit + 1;
                if (limit > 40)
                    $fatal(1, "Mailbox did not acknowledge within 40 CSI clocks");
            end
            repeat (2) @(negedge csi_clk);
        end
    endtask

    task automatic check_slot(input integer slot);
        integer id, x0, x1, y0, y1;
        begin
            id = ref_frame[slot];
            x0 = display_x(frame_xmin(id), ref_edge[slot]);
            x1 = display_x(frame_xmax(id), ref_edge[slot]);
            y0 = display_y(frame_ymin(id), ref_edge[slot]);
            y1 = display_y(frame_ymax(id), ref_edge[slot]);
            if (dut.S_target_slots_valid[slot] !== ref_valid[slot])
                $fatal(1, "Slot valid mismatch slot=%0d frame=%0d", slot, id);
            if (ref_valid[slot] && ref_found[slot]) begin
                if (dut.S_target_slots[slot][72] !== 1'b1 ||
                    dut.S_target_slots[slot][71:60] != x0 ||
                    dut.S_target_slots[slot][59:48] != x1 ||
                    dut.S_target_slots[slot][47:36] != y0 ||
                    dut.S_target_slots[slot][35:24] != y1 ||
                    dut.S_target_slots[slot][23:12] != (x0+x1)/2 ||
                    dut.S_target_slots[slot][11:0] != (y0+y1)/2)
                    $fatal(1, "Result payload mismatch slot=%0d frame=%0d", slot, id);
            end else if ((!ref_valid[slot] && dut.S_target_slots[slot] !== 73'd0) ||
                         (ref_valid[slot] && dut.S_target_slots[slot][72] !== 1'b0))
                $fatal(1, "No-target or invalid slot retains old target slot=%0d frame=%0d",
                       slot, id);
        end
    endtask

    task automatic reset_test;
        begin
            rst_n = 0;
            camera_user = 0; result_ready = 0;
            hdmi_de = 0; hdmi_user = 0; hdmi_last = 0; hdmi_vs = 1;
            camera_error = 0; camera_pause = 0;
            active_frame = -1;
            for (integer slot = 0; slot < 4; slot = slot+1) begin
                ref_frame[slot] = -1;
                ref_valid[slot] = 0;
                ref_found[slot] = 0;
                ref_edge[slot] = 0;
            end
            repeat (10) @(negedge csi_clk);
            if (dut.S_target_slots_valid !== 4'b0000)
                $fatal(1, "Reset did not clear metadata validity");
            if (dut.u_hdmi_mixer.S_target_found !== 1'b0)
                $fatal(1, "Reset did not clear mixer target");
            rst_n = 1;
            repeat (10) @(negedge csi_clk);
        end
    endtask

    task automatic start_camera(input integer id, input integer phase);
        integer before_count;
        begin
            mailbox_idle();
            active_frame = id;
            edge_mode = ((id >= 8 && id < 18) || id >= 24);
            before_count = write_events;
            // Sweep arrival phase relative to the DDR and HDMI clocks.
            @(negedge csi_clk);
            #(phase);
            camera_user = 1;
            @(negedge csi_clk);
            camera_user = 0;
            repeat (8) @(negedge csi_clk);
            if (write_events != before_count + 1)
                $fatal(1, "Camera marker did not produce exactly one write frame");
            if (ref_frame[actual_write_slot] != id)
                $fatal(1, "Independent write-address reference has wrong frame");
        end
    endtask

    task automatic publish_result(input integer id, input bit immediate = 0);
        integer slot, before_requests;
        begin
            slot = actual_write_slot;
            if (!immediate)
                mailbox_idle();
            before_requests = request_count;
            @(negedge csi_clk);
            result_found = frame_has_target(id);
            result_xmin = result_found ? frame_xmin(id) : 0;
            result_xmax = result_found ? frame_xmax(id) : 0;
            result_ymin = result_found ? frame_ymin(id) : 0;
            result_ymax = result_found ? frame_ymax(id) : 0;
            result_cx = result_found ? (frame_xmin(id)+frame_xmax(id))/2 : 0;
            result_cy = result_found ? (frame_ymin(id)+frame_ymax(id))/2 : 0;
            result_ready = 1;
            @(negedge csi_clk);
            result_ready = 0;
            ref_valid[slot] = 1;
            ref_found[slot] = frame_has_target(id);
            mailbox_idle();
            if (request_count != before_requests+1)
                $fatal(1, "Complete result was lost or duplicated frame=%0d", id);
            check_slot(slot);
            result_checks = result_checks+1;
        end
    endtask

    task automatic check_invalidation;
        integer slot;
        begin
            slot = actual_write_slot;
            repeat (45) @(negedge csi_clk);
            mailbox_idle();
            check_slot(slot);
            invalidate_checks = invalidate_checks+1;
        end
    endtask

    task automatic display_frame(input integer phase);
        integer before_count, slot, id, x0, x1, y0, y1;
        bit expected_found;
        begin
            before_count = read_events;
            @(negedge hdmi_clk);
            #(phase);
            hdmi_vs = 0; // video_out sees the rising inverted vsync.
            repeat (9) @(negedge hdmi_clk);
            hdmi_vs = 1;
            repeat (8) @(negedge hdmi_clk);
            if (read_events != before_count+1)
                $fatal(1, "Display sync did not select exactly one DDR read base");
            slot = actual_read_slot;
            id = ref_frame[slot];
            x0 = display_x(frame_xmin(id), ref_edge[slot]);
            x1 = display_x(frame_xmax(id), ref_edge[slot]);
            y0 = display_y(frame_ymin(id), ref_edge[slot]);
            y1 = display_y(frame_ymax(id), ref_edge[slot]);
            if (dut.S_read_slot_sync !== slot[1:0])
                $fatal(1, "Read-slot CDC has not settled before active pixels");
            check_slot(slot);
            expected_found = ref_valid[slot] && ref_found[slot];
            // A short first line is enough to exercise the real mixer's
            // pixel(0,0) latch; full-frame pixel processing is outside scope.
            hdmi_de = 1; hdmi_user = 1; hdmi_last = 0;
            @(negedge hdmi_clk);
            hdmi_user = 0;
            repeat (5) @(negedge hdmi_clk);
            if (dut.u_hdmi_mixer.S_target_found !== expected_found)
                $fatal(1, "Mixer latched wrong frame target slot=%0d frame=%0d", slot, id);
            if (expected_found &&
                (dut.u_hdmi_mixer.S_target_xmin != x0 ||
                 dut.u_hdmi_mixer.S_target_xmax != x1 ||
                 dut.u_hdmi_mixer.S_target_ymin != y0 ||
                 dut.u_hdmi_mixer.S_target_ymax != y1 ||
                 dut.u_hdmi_mixer.S_target_center_x != (x0+x1)/2 ||
                 dut.u_hdmi_mixer.S_target_center_y != (y0+y1)/2))
                $fatal(1, "Mixer latched newer or older box slot=%0d frame=%0d", slot, id);
            hdmi_last = 1;
            @(negedge hdmi_clk);
            hdmi_last = 0; hdmi_de = 0;
            repeat (4) @(negedge hdmi_clk);
            display_checks = display_checks+1;
        end
    endtask

    task automatic diagnostic_send(input [3:0] status, input [7:0] fail_index);
        integer cycles;
        begin
            @(negedge csi_clk);
            #0.173;
            diagnostic_status = status;
            diagnostic_fail = fail_index;
            cycles = 0;
            while (dut.S_hdmi_debug_status !== status ||
                   dut.S_cam_fail_sync !== fail_index) begin
                @(negedge hdmi_clk);
                cycles = cycles + 1;
                if (cycles > 50)
                    $fatal(1, "Diagnostic CDC failed: got %h/%h expected %h/%h",
                        dut.S_hdmi_debug_status, dut.S_cam_fail_sync,
                        status, fail_index);
            end
            if (dut.u_hdmi_mixer.I_debug_status !== status ||
                dut.u_hdmi_mixer.I_cam_fail_index !== fail_index)
                $fatal(1, "Mixer diagnostic inputs disagree with CDC outputs");
            diagnostic_checks = diagnostic_checks + 1;
        end
    endtask

    // Observe the production status state machine and its real diagnostic
    // CDC after releasing the synthetic status stimulus used above. Camera
    // configuration/write handshake inputs remain explicitly controlled.
    task automatic check_actual_status(input [3:0] expected,
                                       input bit expected_applied);
        integer cycles;
        begin
            repeat (3) @(negedge csi_clk);
            if (dut.S_cam_status !== expected ||
                dut.S_cam_ae_applied !== expected_applied)
                $fatal(1, "Actual camera status mismatch: status=%h applied=%b expected=%h/%b",
                       dut.S_cam_status, dut.S_cam_ae_applied, expected, expected_applied);
            cycles = 0;
            while (dut.S_hdmi_debug_status !== expected ||
                   dut.S_cam_fail_sync !== diagnostic_fail) begin
                @(negedge hdmi_clk);
                cycles = cycles+1;
                if (cycles > 50)
                    $fatal(1, "Actual camera status did not reach HDMI: got=%h expected=%h",
                           dut.S_hdmi_debug_status, expected);
            end
            if (dut.u_hdmi_mixer.I_debug_status !== expected ||
                dut.u_hdmi_mixer.I_cam_fail_index !== diagnostic_fail)
                $fatal(1, "Actual camera status differs at mixer input");
            actual_status_checks = actual_status_checks+1;
        end
    endtask

    task automatic test_actual_status;
        begin
            @(negedge csi_clk);
            force dut.S_cam_i2c_ready = status_i2c_ready;
            force dut.S_cam_cfg_done = status_cfg_done;
            force dut.S_ae_cfg_done = status_ae_done;
            force dut.S_cam_sensor_id_ok = status_sensor_ok;
            force dut.S_cam_i2c_error = status_i2c_error;
            force dut.S_ae = status_exposure;
            force dut.S_ag = status_gain;
            release dut.S_cam_status;
            check_actual_status(4'h0, 0);

            status_i2c_ready = 1;
            check_actual_status(4'h8, 0);
            status_sensor_ok = 1; status_cfg_done = 1;
            // Initial high "done" has never completed an exposure write.
            // The values intentionally differ from the old 1991/144 test.
            check_actual_status(4'hB, 0);
            status_ae_done = 0;
            check_actual_status(4'hB, 0);
            status_ae_done = 1;
            check_actual_status(4'hF, 1);

            // Later closed-loop updates keep the applied indication green
            // across busy intervals, with varying exposure/gain values.
            status_exposure = 300; status_gain = 32; status_ae_done = 0;
            check_actual_status(4'hF, 1);
            status_ae_done = 1;
            check_actual_status(4'hF, 1);
            status_exposure = 1500; status_gain = 64; status_ae_done = 0;
            check_actual_status(4'hF, 1);
            status_ae_done = 1;
            check_actual_status(4'hF, 1);

            // An I2C failure invalidates prior successful application.
            // Clearing the error alone cannot declare a fresh write done.
            status_i2c_error = 1;
            check_actual_status(4'h3, 0);
            status_i2c_error = 0;
            check_actual_status(4'hB, 0);
            status_ae_done = 0;
            check_actual_status(4'hB, 0);
            status_ae_done = 1;
            check_actual_status(4'hF, 1);

            // Camera reconfiguration also requires a new busy/done pair.
            status_cfg_done = 0;
            check_actual_status(4'h9, 0);
            status_cfg_done = 1;
            check_actual_status(4'hB, 0);
            status_ae_done = 0;
            check_actual_status(4'hB, 0);
            status_ae_done = 1;
            check_actual_status(4'hF, 1);
            status_i2c_ready = 0;
            check_actual_status(4'h0, 0);
            status_i2c_ready = 1;
            check_actual_status(4'hB, 0);
        end
    endtask

    initial begin
        // The force points intentionally exclude slot pointers, mailbox,
        // table validity, synchronizers, addresses and mixer geometry.
        force dut.S_csi_rx_clk = csi_clk;
        force dut.S_hdmi_pixel_clk = hdmi_clk;
        force dut.S_hdmi_serial_clk = hdmi_clk;
        force dut.S_ddr_clk = ddr_clk;
        force dut.S_24m_clk = csi_clk;
        force dut.S_cam_status = diagnostic_status;
        force dut.S_cam_fail_index = diagnostic_fail;
        force dut.S_100m_clk = ddr_clk;
        force dut.S_pll_lock = rst_n;
        force dut.S_ISP_O_tuser = camera_user;
        force dut.S_ISP_O_tvalid = 1'b0;
        force dut.S_ISP_O_tdata = 128'd0;
        force dut.S_ISP_target_result_ready = result_ready;
        force dut.S_ISP_target_found = result_found;
        force dut.S_ISP_target_xmin = result_xmin;
        force dut.S_ISP_target_xmax = result_xmax;
        force dut.S_ISP_target_ymin = result_ymin;
        force dut.S_ISP_target_ymax = result_ymax;
        force dut.S_ISP_target_center_x = result_cx;
        force dut.S_ISP_target_center_y = result_cy;
        force dut.S_ISP_edge_mode_active = edge_mode;
        force dut.S_hdmi_vsync = hdmi_vs;
        force dut.S_hdmi_hsync = hdmi_hs;
        force dut.S_hdmi_de = hdmi_de;
        force dut.S_hdmi_user = hdmi_user;
        force dut.S_hdmi_last = hdmi_last;
        force dut.S_video_rd_data = 24'h000000;
        force dut.S_ddr_user_ready = 1'b1;
        force dut.S_ddr_user_rd_valid = 1'b0;
        force dut.u_video_in.S_fifo_rd_num = 9'd0;
        force dut.u_video_out.S_fifo_wr_num = 9'd511;
        force dut.u_video_in.I_mipi_rx_error = camera_error;
        force dut.u_video_in.I_display_pause = camera_pause;

        reset_test();
        for (integer id = 0; id < 18; id = id+1) begin
            start_camera(id, id % 6);
            if (id == 3) begin
                // Complete result competes with scheduled invalidation.
                wait (dut.S_target_frame_pending &&
                      dut.S_target_frame_wait == 31);
                publish_result(id, 1);
            end else
                check_invalidation();
            display_frame(id % 4);
            if (id != 7 && id != 13 && id != 3)
                publish_result(id);
            // IDs 7 and 13 deliberately have no completion pulse.
            repeat (11 + (id % 5)) @(negedge csi_clk);
        end
        // Existing pointer error/pause branches must expose the actual base.
        camera_error = 1;
        start_camera(18, 1);
        check_invalidation();
        publish_result(18);
        display_frame(2);
        camera_error = 0;
        camera_pause = 1;
        start_camera(19, 2);
        check_invalidation();
        publish_result(19);
        display_frame(1);
        camera_pause = 0;

        // A reset after populated tables must erase every prior target.
        reset_test();
        for (integer id = 20; id < 30; id = id+1) begin
            start_camera(id, id % 6);
            check_invalidation();
            display_frame(id % 4);
            publish_result(id);
            repeat (13) @(negedge csi_clk);
        end
        mailbox_idle();
        for (integer bit_index = 0; bit_index < 4; bit_index = bit_index+1) begin
            diagnostic_send(4'b0001 << bit_index, 8'h03);
            diagnostic_send(4'b0001 << bit_index, 8'hA5);
            diagnostic_send(4'b0001 << bit_index, 8'hFF);
        end
        diagnostic_send(4'hF, 8'h00);
        diagnostic_send(4'h0, 8'h00);
        test_actual_status();
        if (write_events < 30 || display_checks < 30 ||
            result_checks < 28 || invalidate_checks < 29 ||
            diagnostic_checks != 14 || actual_status_checks != 19)
            $fatal(1, "Coverage counters did not reach required scenarios");
        $display("TARGET_FRAME_ALIGNMENT_PASS write=%0d read=%0d display=%0d result=%0d invalidation=%0d mailbox=%0d diagnostic=%0d actual_status=%0d",
            write_events, read_events, display_checks, result_checks,
            invalidate_checks, request_count, diagnostic_checks, actual_status_checks);
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "Alignment test timeout");
    end
endmodule

`ifdef TARGET_ALIGNMENT_STUBS
// Deliberately inert boundary declarations, enabled only for this test.
// Every port is an input: the forced wrapper nets supply the tested stimulus,
// while these declarations must never drive the real integration logic.
// The common wide width is intentional and may cause harmless width warnings.
// Do not compile real versions of these peripherals with this macro enabled.
module PLL(input wire [127:0] refclk, reset, clk0_out, clk1_out,
    clk4_out, clk5_out, lock);
endmodule
module video_mode_control #(parameter DEBOUNCE_CYCLES=0, DEFAULT_EDGE_MODE=0)
    (input wire [127:0] I_clk, I_rst_n, I_key_n, O_edge_mode);
endmodule
module auto_exposure_control(input wire [127:0] I_clk, I_rst, I_cam_cfg_done,
    I_ae_cfg_done, I_stats_valid, I_sum_y, I_sample_count, I_bright_count,
    O_ae_req, O_ae, O_ag);
endmodule
module ae_stats_cdc(input wire [127:0] I_src_clk, I_dst_clk, I_rst_n,
    I_src_valid, I_src_data, O_dst_valid, O_dst_data);
endmodule
module uicfgcs520 #(parameter CLK_DIV=0)
    (input wire [127:0] I_clk, I_rst_n, I_ae_req, I_ae, I_ag, O_cam_scl,
    IO_cam_sda, O_cfg_done, O_ae_cfg_done, O_sensor_id, O_sensor_id_ok,
    O_iic_error, O_fail_index);
endmodule
module mipi_dphy_rx_ph1p_mipiio_wrapper #(
    parameter DPHY_RX_LOCATION=0, HS_EQUALIZER=0, HS_VGA_GAIN=0,
    LANE_NUM=0, BYTE_NUM=0)
    (input wire [127:0] I_lp_clk, I_rst, I_clk_lane_in_delay,
    I_data_lane0_in_delay, I_data_lane1_in_delay, I_data_lane2_in_delay,
    I_data_lane3_in_delay, I_lane_invert, O_hs_rx_clk, O_hs_rx_valid,
    O_hs_rx_data, O_lp_rx_lane0_p, O_lp_rx_lane0_n, I_lp_tx_en,
    I_lp_tx_lane0_p, I_lp_tx_lane0_n, O_lane_match_error, O_lane_error,
    IO_rx_clk_pad_n, IO_rx_clk_pad_p, IO_rx_data_pad_n, IO_rx_data_pad_p);
endmodule
module csi_unpacket_2lane(input wire [127:0] I_clk, I_rst_n, I_hs_valid,
    I_hs_data, O_csi_frame_start, O_csi_frame_end, O_csi_valid, O_csi_data);
endmodule
module raw10_unpacket_2lane(input wire [127:0] I_clk, I_rst_n,
    I_csi_frame_start, I_csi_frame_end, I_csi_valid, I_csi_data,
    O_raw10_frame_start, O_raw10_frame_end, O_raw10_valid, O_raw10_data);
endmodule
module uial2axis #(parameter IMG_WIDTH=0, IMG_HEIGHT=0, INPUT_DATA_WIDTH=0)
    (input wire [127:0] I_native_clk, I_rst_n, I_data, I_data_valid,
    I_data_start, I_data_end, axis_tvalid, axis_tdata, axis_tuser, axis_tlast);
endmodule
module isp_top #(parameter ENABLE_EDGE=0)
    (input wire [127:0] axi4s_video_aclk, I_rst_n, I_edge_mode_async,
    I_tlast, I_tuser, I_tdata, I_tvalid, I_tdest, O_tready, O_tdata,
    O_tlast, O_tuser, O_tvalid, O_target_result_ready, O_target_found,
    O_target_xmin, O_target_xmax, O_target_ymin, O_target_ymax,
    O_target_center_x, O_target_center_y, O_target_pixels,
    O_target_frame_toggle, O_edge_mode_active, I_tready,
    O_ae_stats_valid, O_ae_sum_y, O_ae_sample_count, O_ae_bright_count);
endmodule
module mc_to_user_interface(input wire [127:0] I_clk, I_rst_n,
    I_ddr_user_wr_en, I_ddr_user_rd_en, I_ddr_user_addr, I_ddr_user_wr_data,
    O_ddr_user_ready, O_ddr_user_rd_valid, O_ddr_user_rd_data, O_mc_app_en,
    O_mc_app_addr, O_mc_app_cmd, I_mc_app_rdy, O_mc_app_wdf_wren,
    O_mc_app_wdf_data, O_mc_app_wdf_end, O_mc_app_wdf_mask,
    I_mc_app_wdf_rdy, I_mc_app_rd_data, I_mc_app_rd_data_end,
    I_mc_app_rd_data_valid);
endmodule
module ph1p35_324_ddr_wrapper(input wire [127:0] I_sys_clk, I_sys_rst_n,
    O_ddr_clk, O_init_calib_complete, I_mc_app_addr, I_mc_app_cmd,
    I_mc_app_en, I_mc_app_wdf_data, I_mc_app_wdf_end, I_mc_app_wdf_mask,
    I_mc_app_wdf_wren, O_mc_app_rd_data, O_mc_app_rd_data_end,
    O_mc_app_rd_data_valid, O_mc_app_rdy, O_mc_app_wdf_rdy, ddr_addr,
    ddr_ba, ddr_cke, ddr_odt, ddr_cs_n, ddr_ras_n, ddr_cas_n, ddr_we_n,
    ddr_ck_p, ddr_ck_n, ddr_dm, ddr_dq, ddr_dqs_p, ddr_dqs_n);
endmodule
module uivtc #(parameter H_ActiveSize=0, H_FrameSize=0, H_SyncStart=0,
    H_SyncEnd=0, V_ActiveSize=0, V_FrameSize=0, V_SyncStart=0, V_SyncEnd=0)
    (input wire [127:0] I_vtc_rstn, I_vtc_clk, O_vtc_vs, O_vtc_hs,
    O_vtc_de_valid, O_vtc_user, O_vtc_last);
endmodule
module hdmi_tx(input wire [127:0] I_pixel_clk, I_serial_clk, I_rst, I_key_in,
    I_edid_read_trig, O_edid_read_valid, O_edid_read_data, I_video_rgb_enable,
    I_video_in_vs, I_video_in_de, I_video_in_user, I_video_in_valid,
    I_video_in_last, O_video_in_ready, I_video_in_data, I_audio_valid,
    I_audio_left_data, I_audio_right_data, I_i2s_BCLK, I_i2s_LRCK,
    I_i2s_DOUT, O_ddc_scl, O_hdmi_clk_p, O_hdmi_tx_p, O_tmds_ch0_p,
    O_tmds_ch1_p, O_tmds_ch2_p, O_tmds_clk_p);
endmodule
module w128_d512_fifo(input wire [127:0] rst, clkw, we, di, afull,
    full_flag, wrusedw, clkr, re, dout, rdusedw, valid, empty_flag, aempty);
endmodule
`endif
