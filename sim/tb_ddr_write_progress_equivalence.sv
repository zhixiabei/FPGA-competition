`timescale 1ns/1ps

module ddr_write_progress_case #(
    parameter integer FRAME_WORDS = 4,
    parameter integer CASE_ID = 0,
    parameter integer TIME_WIDTH = 12,
    parameter integer MAX_AGE_US = 500
) (
    output reg done
);
    reg time_clk=0, csi_clk=0, ddr_clk=0, hdmi_clk=0;
    reg ddr_running=1, hdmi_running=1;
    always #5 if (!done) time_clk=~time_clk;
    always #7 if (!done) csi_clk=~csi_clk;
    always #3 if (!done && ddr_running) ddr_clk=~ddr_clk;
    always #5.5 if (!done && hdmi_running) hdmi_clk=~hdmi_clk;
    reg rst_n=0, raw_sof=0, raw_valid=0, isp_sof=0, isp_valid=0;
    reg [9:0] isp_id=0;
    reg [11:0] effect_config=0;
    reg motion_mode=0;
    reg [1:0] color_mode=0;
    reg result_ready=0;
    reg write_start=0, write_word=0, read_start=0, display_start=0;
    reg [1:0] write_slot=0, read_slot=0;
    wire [9:0] raw_id_reference,raw_id_internal,raw_id_external;
    wire [297:0] bridge_reference_tuple,bridge_internal_tuple,bridge_external_tuple;
    wire [71:0] latency_reference_tuple,latency_internal_tuple,latency_external_tuple;
    wire bridge_complete,latency_complete;
    integer comparisons=0,bridge_events=0,latency_events=0,valid_samples=0;
    integer start_word_checks=0,restarts=0,age_collisions=0,stop_checks=0,wrap_checks=0;
    integer slot,h,n,random_value,display_cycles=0;
    reg [31:0] rng=32'h3257abc1^CASE_ID;
    reg random_display=0;
    reg [9:0] next_id;
    reg [31:0] held_progress;

`define BRIDGE_INPUTS \
        .I_csi_clk(csi_clk), .I_ddr_clk(ddr_clk), .I_hdmi_clk(hdmi_clk), .I_rst_n(rst_n), \
        .I_frame_start(isp_sof), .I_frame_id(isp_id), .I_effect_config(effect_config), \
        .I_motion_mode(motion_mode), .I_color_mode(color_mode), \
        .I_result_ready(result_ready), .I_result_frame_id(isp_id), .I_result_found(1'b1), \
        .I_result_motion_mode(motion_mode), .I_result_color_mode(color_mode), \
        .I_result_xmin(12'd19), .I_result_xmax(12'd1179), \
        .I_result_ymin(12'd23), .I_result_ymax(12'd619), \
        .I_result_center_x(12'd599), .I_result_center_y(12'd321), \
        .I_multi_valid(4'h5), .I_multi_hold(4'h4), .I_multi_shapes(8'h6c), \
        .I_multi_boxes({4{48'h250120450030}}), .I_multi_overflow(1'b1), \
        .I_write_start(write_start), .I_write_slot(write_slot), .I_write_word(write_word), \
        .I_read_start(read_start), .I_read_slot(read_slot)
`define BRIDGE_OUTPUTS(T) \
        .O_ready(T[297]), .O_effect_config(T[296:285]), .O_motion_mode(T[284]), \
        .O_color_mode(T[283:282]), .O_found(T[281]), \
        .O_xmin(T[280:269]), .O_xmax(T[268:257]), .O_ymin(T[256:245]), .O_ymax(T[244:233]), \
        .O_center_x(T[232:221]), .O_center_y(T[220:209]), \
        .O_multi_valid(T[208:205]), .O_multi_hold(T[204:201]), .O_multi_shapes(T[200:193]), \
        .O_multi_boxes(T[192:1]), .O_multi_overflow(T[0])
`define LATENCY_INPUTS \
        .I_time_clk(time_clk), .I_csi_clk(csi_clk), .I_ddr_clk(ddr_clk), \
        .I_hdmi_clk(hdmi_clk), .I_rst_n(rst_n), \
        .I_raw_sof(raw_sof), .I_raw_valid(raw_valid), \
        .I_isp_sof(isp_sof), .I_isp_valid(isp_valid), .I_isp_frame_id(isp_id), \
        .I_write_start(write_start), .I_write_slot(write_slot), .I_write_word(write_word), \
        .I_read_start(read_start), .I_read_slot(read_slot), .I_display_frame_start(display_start)
`define LATENCY_OUTPUTS(T,R) \
        .O_raw_frame_id(R), .O_sample_strobe(T[71]), .O_sample_valid(T[70]), \
        .O_frame_id(T[69:60]), .O_total_us(T[59:40]), .O_isp_us(T[39:20]), .O_buffer_us(T[19:0])
`define LATENCY_PARAMS \
        .TIME_WIDTH(TIME_WIDTH), .TIME_NUM(1), .TIME_DEN(1), \
        .FRAME_WORDS(FRAME_WORDS), .MAX_AGE_US(MAX_AGE_US)

    target_frame_bridge_reference #(.FRAME_WORDS(FRAME_WORDS)) bridge_reference (
        `BRIDGE_INPUTS, `BRIDGE_OUTPUTS(bridge_reference_tuple));
    target_frame_bridge #(.FRAME_WORDS(FRAME_WORDS)) bridge_internal (
        `BRIDGE_INPUTS, `BRIDGE_OUTPUTS(bridge_internal_tuple), .I_write_complete(1'b0));
    target_frame_bridge #(
        .FRAME_WORDS(FRAME_WORDS), .USE_EXTERNAL_WRITE_PROGRESS(1)
    ) bridge_external (
        `BRIDGE_INPUTS, `BRIDGE_OUTPUTS(bridge_external_tuple), .I_write_complete(bridge_complete));
    video_latency_monitor_reference #(`LATENCY_PARAMS) latency_reference (
        `LATENCY_INPUTS, `LATENCY_OUTPUTS(latency_reference_tuple,raw_id_reference));
    video_latency_monitor #(`LATENCY_PARAMS) latency_internal (
        `LATENCY_INPUTS, `LATENCY_OUTPUTS(latency_internal_tuple,raw_id_internal),
        .I_write_complete(1'b0));
    video_latency_monitor #(
        `LATENCY_PARAMS, .USE_EXTERNAL_WRITE_PROGRESS(1)
    ) latency_external (
        `LATENCY_INPUTS, `LATENCY_OUTPUTS(latency_external_tuple,raw_id_external),
        .I_write_complete(latency_complete));
    video_ddr_write_progress #(.FRAME_WORDS(FRAME_WORDS)) progress (
        .I_clk(ddr_clk), .I_rst_n(rst_n), .I_write_start(write_start), .I_write_word(write_word),
        .O_bridge_complete(bridge_complete), .O_latency_complete(latency_complete));
`undef BRIDGE_INPUTS
`undef BRIDGE_OUTPUTS
`undef LATENCY_INPUTS
`undef LATENCY_OUTPUTS
`undef LATENCY_PARAMS

    always @(posedge ddr_clk) begin
        // These comparisons run before nonblocking register updates: a
        // registered completion pulse would fail immediately.
        if (rst_n) begin
            if (bridge_complete !== (!write_start && write_word &&
                bridge_reference.S_write_active &&
                bridge_reference.S_write_count==FRAME_WORDS-1))
                $fatal(1,"Bridge completion edge changed words=%0d time=%0t",
                    FRAME_WORDS,$time);
            if (latency_complete !== (!write_start && write_word &&
                latency_reference.S_write_active &&
                latency_reference.S_write_count==FRAME_WORDS-1))
                $fatal(1,"Latency completion edge changed words=%0d time=%0t",
                    FRAME_WORDS,$time);
            if (bridge_complete) bridge_events=bridge_events+1;
            if (latency_complete) latency_events=latency_events+1;
        end
        #1;
        if (rst_n) begin
            if (bridge_reference.S_slot_complete !== bridge_external.S_slot_complete ||
                bridge_reference.S_slot_complete !== bridge_internal.S_slot_complete ||
                bridge_reference.S_slot_started !== bridge_external.S_slot_started ||
                bridge_reference.S_slot_result_valid !== bridge_external.S_slot_result_valid ||
                bridge_reference.S_read_payload !== bridge_external.S_read_payload ||
                bridge_reference.S_read_request !== bridge_external.S_read_request ||
                bridge_reference.S_read_pending_payload !== bridge_external.S_read_pending_payload ||
                bridge_reference.S_read_pending_valid !== bridge_external.S_read_pending_valid)
                $fatal(1,"Bridge DDR state mismatch words=%0d time=%0t",FRAME_WORDS,$time);
            if (latency_reference.S_slot_complete !== latency_external.S_slot_complete ||
                latency_reference.S_slot_complete !== latency_internal.S_slot_complete ||
                latency_reference.S_slot_started !== latency_external.S_slot_started ||
                latency_reference.S_slot_metadata !== latency_external.S_slot_metadata ||
                latency_reference.S_read_payload !== latency_external.S_read_payload ||
                latency_reference.S_read_request !== latency_external.S_read_request)
                $fatal(1,"Latency DDR state mismatch words=%0d time=%0t",FRAME_WORDS,$time);
            for (integer b=0; b<4; b=b+1)
                if (latency_reference.S_slot_age[b] !== latency_external.S_slot_age[b] ||
                    latency_reference.S_slot_ids[b] !== latency_external.S_slot_ids[b] ||
                    latency_reference.S_slot_raw[b] !== latency_external.S_slot_raw[b] ||
                    latency_reference.S_slot_isp[b] !== latency_external.S_slot_isp[b] ||
                    bridge_reference.S_slot_nonce[b] !== bridge_external.S_slot_nonce[b] ||
                    bridge_reference.S_slot_result[b] !== bridge_external.S_slot_result[b])
                    $fatal(1,"Slot metadata mismatch words=%0d slot=%0d",FRAME_WORDS,b);
        end
    end
    always @(posedge hdmi_clk) begin
        #1;
        if (bridge_reference_tuple !== bridge_internal_tuple ||
            bridge_reference_tuple !== bridge_external_tuple ||
            latency_reference_tuple !== latency_internal_tuple ||
            latency_reference_tuple !== latency_external_tuple)
            $fatal(1,"Published output changed words=%0d time=%0t bridge=%h/%h latency=%h/%h",
                FRAME_WORDS,$time,bridge_reference_tuple,bridge_external_tuple,
                latency_reference_tuple,latency_external_tuple);
        comparisons=comparisons+1;
        if (latency_reference_tuple[71:70]==2'b11)
            valid_samples=valid_samples+1;
    end
    always @(negedge hdmi_clk) begin
        if (random_display) begin
            display_cycles=display_cycles+1;
            display_start=(display_cycles%19==0 || display_cycles%19==1);
        end
    end

    task automatic source_frame;
        begin
            @(negedge csi_clk);
            raw_sof=1; raw_valid=1;
            #1; next_id=raw_id_reference;
            @(negedge csi_clk);
            raw_sof=0; raw_valid=0;
            repeat (2) @(negedge csi_clk);
            isp_sof=1; isp_valid=1; isp_id=next_id;
            effect_config={4'(next_id%13),8'h35};
            motion_mode=next_id[0]; color_mode=next_id[2:1];
            @(negedge csi_clk);
            isp_sof=0; isp_valid=0;
            repeat (2) @(negedge csi_clk);
            result_ready=1;
            @(negedge csi_clk);
            result_ready=0;
        end
    endtask
    task automatic start_write(input integer selected_slot, input bit same_word);
        begin
            repeat (5) @(negedge ddr_clk);
            write_start=1; write_word=same_word; write_slot=2'(selected_slot);
            @(negedge ddr_clk);
            write_start=0; write_word=0;
        end
    endtask
    task automatic words(input integer count);
        begin
            if (count>0) begin
                @(negedge ddr_clk); write_word=1;
                repeat (count) @(negedge ddr_clk);
                write_word=0;
            end
        end
    endtask
    task automatic snapshot(input integer selected_slot);
        begin
            @(negedge ddr_clk); read_start=1; read_slot=2'(selected_slot);
            @(negedge ddr_clk); read_start=0;
            repeat (18) @(negedge hdmi_clk);
            @(negedge hdmi_clk); display_start=1;
            @(negedge hdmi_clk); display_start=0;
            repeat (5) @(negedge hdmi_clk);
        end
    endtask
    task automatic reset_case;
        begin
            @(negedge csi_clk);
            rst_n=0; write_start=0; write_word=0; read_start=0;
            raw_sof=0; raw_valid=0; isp_sof=0; isp_valid=0; result_ready=0;
            repeat (6) @(negedge csi_clk);
            rst_n=1;
            repeat (6) @(negedge csi_clk);
        end
    endtask

    initial begin
        done=0;
        repeat (8) @(negedge csi_clk);
        rst_n=1;
        words(9);
        if (bridge_reference.S_slot_complete!==0 ||
            latency_reference.S_slot_complete!==0)
            $fatal(1,"Words without start manufactured completion");
        for (slot=0; slot<((FRAME_WORDS==172800)?1:4); slot=slot+1) begin
            for (h=0; h<2; h=h+1) begin
                source_frame(); start_write(slot,1'(h));
                words(FRAME_WORDS-1);
                // Bridge may already have completed when start carried a
                // word; latency still needs this final subsequent word.
                if (bridge_reference.S_slot_complete[slot] !== 1'(h) ||
                    latency_reference.S_slot_complete[slot] !== 1'b0)
                    $fatal(1,"Different completion conventions lost words=%0d h=%0d",
                        FRAME_WORDS,h);
                @(negedge ddr_clk);
                write_word=1; read_start=1; read_slot=2'(slot);
                @(negedge ddr_clk); write_word=0; read_start=0;
                snapshot(slot); words(7); snapshot(slot);
                start_word_checks=start_word_checks+1;
            end
        end
        if (FRAME_WORDS!=172800) begin
            // Partial restart, start+word on consecutive cycles, and reads
            // of the very slot being invalidated all retain start priority.
            source_frame(); start_write(0,0); words(FRAME_WORDS-1);
            source_frame();
            @(negedge ddr_clk);
            write_start=1; write_word=1; write_slot=0; read_start=1; read_slot=0;
            @(negedge ddr_clk); write_slot=1;
            @(negedge ddr_clk); write_start=0; write_word=0; read_start=0;
            words(FRAME_WORDS); snapshot(1); restarts=restarts+1;

            source_frame(); start_write(2,0); words(FRAME_WORDS-1);
            @(negedge ddr_clk); ddr_running=0; write_word=1;
            held_progress=progress.S_write_count;
            repeat (40) @(negedge csi_clk);
            if (progress.S_write_count !== held_progress[$bits(progress.S_write_count)-1:0])
                $fatal(1,"Progress advanced while DDR was stopped");
            ddr_running=1;
            @(negedge ddr_clk); write_word=0;
            snapshot(2); stop_checks=stop_checks+1;

            // Age clear runs earlier in the original always block; a terminal
            // word on this edge sets complete even while started is cleared.
            reset_case(); source_frame(); start_write(2,0); words(FRAME_WORDS-1);
            wait (latency_reference.S_age_step &&
                  latency_reference.S_slot_age[2]>=2);
            @(negedge ddr_clk);
            write_word=1; read_start=1; read_slot=2;
            @(negedge ddr_clk); write_word=0; read_start=0;
            if (latency_reference.S_slot_complete[2]!==1 ||
                latency_reference.S_slot_started[2]!==0)
                $fatal(1,"Terminal word / age-clear priority test did not hit");
            age_collisions=age_collisions+1; snapshot(2);

            random_display=1;
            for (n=0; n<2048; n=n+1) begin
                @(negedge ddr_clk);
                rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
                random_value=rng;
                write_start=(random_value%17==0);
                write_word=random_value[0];
                write_slot=random_value[3:2];
                read_start=(random_value%7==0);
                read_slot=random_value[5:4];
            end
            @(negedge ddr_clk); write_start=0; write_word=0; read_start=0;
            @(negedge hdmi_clk); random_display=0; display_start=0;

            // CSI metadata and time continue while the DDR counter is held,
            // spanning a full ID wrap and multiple 12-bit timestamp wraps.
            @(negedge ddr_clk); ddr_running=0;
            for (n=0; n<1025; n=n+1)
                source_frame();
            ddr_running=1;
            start_write(3,1); words(FRAME_WORDS); snapshot(3);
            wrap_checks=wrap_checks+1;

            // The shared counter must receive asynchronous reset even while
            // DDR is stopped; trailing words cannot complete a phantom frame.
            source_frame(); start_write(0,0);
            @(negedge ddr_clk); ddr_running=0;
            @(negedge csi_clk); rst_n=0;
            repeat (6) @(negedge csi_clk);
            if ({progress.S_write_active,progress.S_start_word,progress.S_write_count}!==0)
                $fatal(1,"Stopped DDR progress was not asynchronously reset");
            rst_n=1; ddr_running=1; words(FRAME_WORDS+2); snapshot(0);
            stop_checks=stop_checks+1;
        end
        if (latency_events<2 || bridge_events<1 || start_word_checks<2 ||
            valid_samples<1 || (FRAME_WORDS!=172800 &&
            (restarts!=1 || age_collisions!=1 || stop_checks!=2 || wrap_checks!=1)))
            $fatal(1,"Progress coverage incomplete words=%0d valid=%0d bridge=%0d latency=%0d",
                FRAME_WORDS,valid_samples,bridge_events,latency_events);
        $display("DDR_WRITE_PROGRESS_CASE_PASS words=%0d comparisons=%0d bridge_events=%0d latency_events=%0d start_word=%0d valid_samples=%0d restart=%0d age_collision=%0d stopped=%0d id_time_wrap=%0d",
            FRAME_WORDS,comparisons,bridge_events,latency_events,start_word_checks,valid_samples,
            restarts,age_collisions,stop_checks,wrap_checks);
        done=1;
    end
endmodule

module tb_ddr_write_progress_equivalence;
    wire [6:0] done;
    ddr_write_progress_case #(.FRAME_WORDS(1),.CASE_ID(0)) c0(done[0]);
    ddr_write_progress_case #(.FRAME_WORDS(2),.CASE_ID(1)) c1(done[1]);
    ddr_write_progress_case #(.FRAME_WORDS(3),.CASE_ID(2)) c2(done[2]);
    ddr_write_progress_case #(.FRAME_WORDS(4),.CASE_ID(3)) c3(done[3]);
    ddr_write_progress_case #(.FRAME_WORDS(7),.CASE_ID(4)) c4(done[4]);
    ddr_write_progress_case #(.FRAME_WORDS(8),.CASE_ID(5)) c5(done[5]);
    ddr_write_progress_case #(
        .FRAME_WORDS(172800),.CASE_ID(6),.TIME_WIDTH(24),.MAX_AGE_US(1000000)
    ) c6(done[6]);
    initial begin
        wait (&done);
        $display("DDR_WRITE_PROGRESS_EQUIVALENCE_PASS cases=7 frozen_reference=1 internal_default=1 shared_external=1");
        $finish;
    end
    initial begin
        #10000000;
        $fatal(1,"Shared DDR progress differential timed out");
    end
endmodule
