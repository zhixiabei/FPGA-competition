`timescale 1ns/1ps

module target_frame_bridge_payload_case #(
    parameter integer FRAME_WORDS = 4,
    parameter integer CASE_ID = 0
) (
    output reg done = 0
);
    reg csi_clk = 0, ddr_clk = 0, hdmi_clk = 0;
    reg ddr_running = 1, hdmi_running = 1;
    always #7 csi_clk = ~csi_clk;
    always #3 if (ddr_running) ddr_clk = ~ddr_clk;
    always #5.5 if (hdmi_running) hdmi_clk = ~hdmi_clk;
    reg rst_n = 0, frame_start = 0, motion_mode = 0;
    reg [1:0] color_mode = 0, result_color = 0;
    reg [9:0] frame_id = 0, result_id = 0;
    reg [11:0] effect_config = 0;
    reg result_ready = 0, result_found = 0, result_motion = 0;
    reg [11:0] xmin = 0, xmax = 0, ymin = 0, ymax = 0, cx = 0, cy = 0;
    reg [3:0] multi_valid = 0, multi_hold = 0;
    reg [191:0] boxes = 0;
    reg [7:0] shapes = 0;
    reg overflow = 0, write_start = 0, write_word = 0, read_start = 0;
    reg [1:0] write_slot = 0, read_slot = 0;
    wire [297:0] baseline_tuple, full_tuple, compact_tuple;
    integer comparisons = 0, snapshots = 0, invalid_reads = 0;
    integer valid_no_target = 0, motion_reads = 0, wrap_checks = 0;
    integer fallback_checks = 0, queue_checks = 0, id, n;
    reg [297:0] frozen_tuple;

`define PAYLOAD_INPUTS \
        .I_csi_clk(csi_clk), .I_ddr_clk(ddr_clk), .I_hdmi_clk(hdmi_clk), .I_rst_n(rst_n), \
        .I_frame_start(frame_start), .I_frame_id(frame_id), \
        .I_effect_config(effect_config), .I_motion_mode(motion_mode), .I_color_mode(color_mode), \
        .I_result_ready(result_ready), .I_result_frame_id(result_id), \
        .I_result_found(result_found), .I_result_motion_mode(result_motion), \
        .I_result_color_mode(result_color), \
        .I_result_xmin(xmin), .I_result_xmax(xmax), .I_result_ymin(ymin), .I_result_ymax(ymax), \
        .I_result_center_x(cx), .I_result_center_y(cy), \
        .I_multi_valid(multi_valid), .I_multi_hold(multi_hold), \
        .I_multi_boxes(boxes), .I_multi_shapes(shapes), .I_multi_overflow(overflow), \
        .I_write_start(write_start), .I_write_slot(write_slot), .I_write_word(write_word), \
        .I_read_start(read_start), .I_read_slot(read_slot)
`define PAYLOAD_OUTPUTS(T) \
        .O_ready(T[297]), .O_effect_config(T[296:285]), \
        .O_motion_mode(T[284]), .O_color_mode(T[283:282]), .O_found(T[281]), \
        .O_xmin(T[280:269]), .O_xmax(T[268:257]), .O_ymin(T[256:245]), .O_ymax(T[244:233]), \
        .O_center_x(T[232:221]), .O_center_y(T[220:209]), \
        .O_multi_valid(T[208:205]), .O_multi_hold(T[204:201]), \
        .O_multi_shapes(T[200:193]), .O_multi_boxes(T[192:1]), .O_multi_overflow(T[0])

    target_frame_bridge_reference #(
        .FRAME_WORDS(FRAME_WORDS), .DEFAULT_EFFECT_CONFIG(12'hc5a)
    ) baseline (`PAYLOAD_INPUTS, `PAYLOAD_OUTPUTS(baseline_tuple));
    target_frame_bridge #(
        .FRAME_WORDS(FRAME_WORDS), .DEFAULT_EFFECT_CONFIG(12'hc5a)
    ) full (`PAYLOAD_INPUTS, `PAYLOAD_OUTPUTS(full_tuple));
    target_frame_bridge #(
        .FRAME_WORDS(FRAME_WORDS), .DEFAULT_EFFECT_CONFIG(12'hc5a),
        .COMPACT_MODE_PAYLOAD(1)
    ) compact (`PAYLOAD_INPUTS, `PAYLOAD_OUTPUTS(compact_tuple));
`undef PAYLOAD_INPUTS
`undef PAYLOAD_OUTPUTS

    // Check every publication and every idle edge, not only final snapshots.
    always @(posedge hdmi_clk) begin
        #1;
        if (baseline_tuple !== full_tuple || baseline_tuple !== compact_tuple)
            $fatal(1,"payload differential case=%0d words=%0d time=%0t baseline=%h full=%h compact=%h",
                CASE_ID,FRAME_WORDS,$time,baseline_tuple,full_tuple,compact_tuple);
        comparisons = comparisons+1;
    end
    always @(posedge csi_clk) begin
        #1;
        if (rst_n && ({
            baseline.S_result_request,baseline.S_result_pending_valid,baseline.S_result_dropped,
            baseline.S_result_ack_meta,baseline.S_result_ack_sync} !== {
            compact.S_result_request,compact.S_result_pending_valid,compact.S_result_dropped,
            compact.S_result_ack_meta,compact.S_result_ack_sync}))
            $fatal(1,"CSI queue protocol changed case=%0d time=%0t",CASE_ID,$time);
        if (rst_n && result_ready) begin
            if (result_motion) begin
                if ({multi_valid,multi_hold,shapes,boxes,overflow} !== 209'b0)
                    $fatal(1,"Motion source violated production invariant");
            end else begin
                if ({ymax,ymin,xmax,xmin} !==
                    (multi_valid[0] ? boxes[0 +: 48] :
                     multi_valid[1] ? boxes[48 +: 48] :
                     multi_valid[2] ? boxes[96 +: 48] : boxes[144 +: 48]))
                    $fatal(1,"Color source violated first-box invariant");
                if (result_found !== (|multi_valid))
                    $fatal(1,"Color source violated found invariant");
            end
        end
    end
    always @(posedge ddr_clk) begin
        #1;
        if (rst_n && ({
            baseline.S_slot_started,baseline.S_slot_complete,baseline.S_slot_result_valid,
            baseline.S_read_request,baseline.S_read_pending_valid,baseline.S_result_ack,
            baseline.S_last_result_valid} !== {
            compact.S_slot_started,compact.S_slot_complete,compact.S_slot_result_valid,
            compact.S_read_request,compact.S_read_pending_valid,compact.S_result_ack,
            compact.S_last_result_valid}))
            $fatal(1,"DDR slot/queue protocol changed case=%0d time=%0t",CASE_ID,$time);
    end

    function automatic [191:0] source_boxes(input integer seed);
        integer b;
        reg [11:0] x0,x1,y0,y1;
        begin
            for (b=0; b<4; b=b+1) begin
                case ((seed+b)%5)
                    0: begin x0=0; x1=1279; y0=0; y1=719; end
                    1: begin x0=1278; x1=1279; y0=718; y1=719; end
                    2: begin x0=4094; x1=4095; y0=4094; y1=4095; end
                    default: begin
                        x0=12'((seed*17+b*29)%1280); x1=12'((seed*19+b*31)%1280);
                        y0=12'((seed*23+b*37)%720); y1=12'((seed*13+b*41)%720);
                    end
                endcase
                source_boxes[48*b +: 48] = {y1,y0,x1,x0};
            end
        end
    endfunction
    task automatic source_frame(input integer new_id, input [11:0] config_value,
                                input bit motion, input [1:0] color);
        begin
            @(negedge csi_clk);
            frame_start=1; frame_id=10'(new_id); effect_config=config_value;
            motion_mode=motion; color_mode=color;
            @(negedge csi_clk);
            frame_start=0;
        end
    endtask
    task automatic start_write(input integer slot, input bit same_word);
        begin
            repeat (5) @(negedge ddr_clk);
            write_start=1; write_slot=2'(slot); write_word=same_word;
            @(negedge ddr_clk);
            write_start=0; write_word=0;
        end
    endtask
    task automatic words(input integer count);
        begin
            if (count>0) begin
                @(negedge ddr_clk);
                write_word=1;
                repeat (count) @(negedge ddr_clk);
                write_word=0;
            end
        end
    endtask
    task automatic send_result(input integer new_id, input bit motion,
                               input [1:0] color, input integer seed,
                               input [3:0] valids);
        reg [47:0] first_box;
        reg [12:0] sum_x,sum_y;
        begin
            @(negedge csi_clk);
            result_ready=1; result_id=10'(new_id); result_motion=motion; result_color=color;
            if (motion) begin
                multi_valid=0; multi_hold=0; shapes=0; boxes=0; overflow=0;
                result_found=seed[0];
                xmin=12'(seed%1280); xmax=(seed%3==0) ? 12'd4095 : 12'd1279;
                ymin=12'(seed%720); ymax=(seed%3==0) ? 12'd4095 : 12'd719;
                cx=12'((seed*29)%4096); cy=12'((seed*41)%4096);
            end else begin
                multi_valid=valids; multi_hold=4'(seed); shapes=8'(seed*17);
                boxes=source_boxes(seed); overflow=seed[0]; result_found=|valids;
                first_box=valids[0] ? boxes[0 +: 48] :
                    valids[1] ? boxes[48 +: 48] :
                    valids[2] ? boxes[96 +: 48] : boxes[144 +: 48];
                xmin=first_box[11:0]; xmax=first_box[23:12];
                ymin=first_box[35:24]; ymax=first_box[47:36];
                sum_x={1'b0,xmin}+{1'b0,xmax};
                sum_y={1'b0,ymin}+{1'b0,ymax};
                cx=sum_x[12:1]; cy=sum_y[12:1];
            end
            @(negedge csi_clk);
            result_ready=0;
        end
    endtask
    task automatic drain;
        repeat (24) @(negedge csi_clk);
    endtask
    task automatic request_read(input integer slot);
        begin
            @(negedge ddr_clk); read_slot=2'(slot); read_start=1;
            @(negedge ddr_clk); read_start=0;
        end
    endtask
    task automatic select_read(input integer slot, input bit expected_ready,
                               input [11:0] config_value, input bit motion,
                               input [1:0] color);
        integer b;
        reg [11:0] zero_shift;
        begin
            request_read(slot);
            repeat (20) @(negedge hdmi_clk);
            if (baseline_tuple[297:282] !== {expected_ready,config_value,motion,color})
                $fatal(1,"Unexpected snapshot metadata case=%0d slot=%0d actual=%h",
                    CASE_ID,slot,baseline_tuple[297:282]);
            snapshots=snapshots+1;
            if (!expected_ready) begin
                if (baseline_tuple[281:0] !== 282'b0)
                    $fatal(1,"Invalid read geometry was not zero");
                invalid_reads=invalid_reads+1;
            end else if (motion) begin
                case (config_value[11:8])
                    2,6,7,12: zero_shift=3;
                    4,8,10,11: zero_shift=1;
                    default: zero_shift=0;
                endcase
                for (b=0; b<4; b=b+1)
                    if (compact_tuple[1+48*b +: 48] !==
                        {zero_shift,zero_shift,zero_shift,zero_shift})
                        $fatal(1,"Motion multi-box zero/offset behavior changed");
                motion_reads=motion_reads+1;
            end else if (!baseline_tuple[281]) begin
                if (baseline_tuple[280:209] === 72'b0)
                    $fatal(1,"No-target test did not exercise nonzero geometry");
                valid_no_target=valid_no_target+1;
            end
        end
    endtask
    task automatic collide_write(input integer slot, input bit same_word);
        begin
            wait (baseline.S_result_req_sync != baseline.S_result_ack);
            @(negedge ddr_clk);
            write_start=1; write_slot=2'(slot); write_word=same_word;
            @(negedge ddr_clk);
            write_start=0; write_word=0;
        end
    endtask

    initial begin
        repeat (8) @(negedge csi_clk);
        if (baseline_tuple !== {1'b0,12'hc5a,285'b0})
            $fatal(1,"Reset/default output changed");
        if ($bits(compact.S_result_payload)!=236 || $bits(compact.S_read_payload)!=223 ||
            $bits(compact.S_slot_result[0])!=210 || $bits(full.S_slot_result[0])!=252)
            $fatal(1,"Payload compression did not remove exactly 42 stored bits");
        rst_n=1;

        // Invalid read must keep config/modes but bypass spatial offset.
        source_frame(10,12'hc5a,1,0); start_write(1,0);
        select_read(1,0,12'hc5a,1,0);
        words(FRAME_WORDS);
        select_read(1,0,12'hc5a,1,0);
        send_result(10,1,0,501,0); drain();
        select_read(1,1,12'hc5a,1,0);
        words(9); select_read(1,1,12'hc5a,1,0);

        source_frame(11,12'h4e1,0,2); start_write(3,1);
        words(FRAME_WORDS-1);
        send_result(11,0,2,70,0); drain();
        select_read(3,1,12'h4e1,0,2);
        fallback_checks=fallback_checks+1;

        if (FRAME_WORDS!=172800) begin
            // Exercise every effect offset, each first-valid choice and the
            // all-invalid slot-three fallback with nonzero invalid fields.
            for (n=0; n<13; n=n+1) begin
                source_frame(20+n,{4'(n),8'ha5},0,2'(n%3));
                start_write(n%4,n[0]); words(FRAME_WORDS-(n%2));
                send_result(20+n,0,2'(n%3),100+n,
                    (n%5==4) ? 4'd0 : (4'd1<<(n%4)));
                drain(); select_read(n%4,1,{4'(n),8'ha5},0,2'(n%3));
            end
            // A new start cancels an incomplete old write without changing
            // queue or result nonce behavior.
            source_frame(50,12'h200,1,0); start_write(2,0);
            words(FRAME_WORDS-1); send_result(50,1,0,300,0); drain();
            select_read(2,0,12'h200,1,0);
            source_frame(51,12'h800,1,0); start_write(2,1);
            words(FRAME_WORDS-1); send_result(51,1,0,301,0); drain();
            select_read(2,1,12'h800,1,0);

            // Complete results may precede allocation and may coincide with
            // the write-start accept edge.
            source_frame(52,12'h700,0,1);
            send_result(52,0,1,110,4); drain();
            start_write(0,1); words(FRAME_WORDS-1);
            select_read(0,1,12'h700,0,1);
            source_frame(53,12'h600,0,2);
            fork
                send_result(53,0,2,111,8);
                collide_write(1,1);
            join
            words(FRAME_WORDS-1); drain(); select_read(1,1,12'h600,0,2);

            // Fill the two-record result mailbox while DDR is stopped.
            source_frame(100,12'h100,0,0); start_write(0,0); words(FRAME_WORDS);
            source_frame(101,12'h400,1,0); start_write(1,0); words(FRAME_WORDS);
            source_frame(102,12'h800,0,2); start_write(3,0); words(FRAME_WORDS);
            @(negedge ddr_clk); ddr_running=0;
            send_result(100,0,0,100,1);
            send_result(101,1,0,200,0);
            send_result(102,0,2,300,7);
            repeat (4) @(negedge csi_clk);
            ddr_running=1; drain();
            select_read(0,1,12'h100,0,0);
            select_read(1,1,12'h400,1,0);
            select_read(3,0,12'h800,0,2);
            queue_checks=queue_checks+1;

            // A stopped HDMI clock holds the in-flight and newest pending
            // snapshot. Slot reuse cannot mutate the frozen record.
            @(negedge hdmi_clk); hdmi_running=0;
            request_read(0); repeat (4) @(negedge ddr_clk);
            request_read(3); repeat (4) @(negedge ddr_clk);
            request_read(1); repeat (4) @(negedge ddr_clk);
            hdmi_running=1;
            repeat (35) @(negedge hdmi_clk);
            if (baseline_tuple[297:282] !== {1'b1,12'h400,1'b1,2'd0})
                $fatal(1,"Latest queued read snapshot was not delivered");
            frozen_tuple=baseline_tuple;
            source_frame(103,12'h200,0,1); start_write(1,1);
            words(FRAME_WORDS-1); send_result(103,0,1,401,2); drain();
            if (baseline_tuple !== frozen_tuple)
                $fatal(1,"Frozen output changed without read-start");
            select_read(1,1,12'h200,0,1);
            queue_checks=queue_checks+1;

            // Hold an old payload across a full 10-bit ID wrap. Reallocation
            // under the same ID must reject it by the unchanged 16-bit nonce.
            source_frame(7,12'h000,0,0); start_write(2,1); words(FRAME_WORDS-1);
            @(negedge ddr_clk); ddr_running=0;
            send_result(7,0,0,70,1);
            for (id=8; id<=1031; id=id+1)
                source_frame(id%1024,12'hc00,1,0);
            ddr_running=1;
            start_write(2,1); words(FRAME_WORDS-1); drain();
            select_read(2,0,12'hc00,1,0);
            send_result(7,1,0,371,0); drain();
            select_read(2,1,12'hc00,1,0);
            wrap_checks=wrap_checks+1;

            // Context replacement and wrong identity still reject a result.
            source_frame(600,12'h000,0,0); start_write(0,1); words(FRAME_WORDS-1);
            source_frame(604,12'h400,0,1);
            send_result(600,0,0,700,1); drain(); select_read(0,0,12'h000,0,0);
            source_frame(605,12'h600,0,2); start_write(3,1); words(FRAME_WORDS-1);
            send_result(605,0,1,701,2); drain(); select_read(3,0,12'h600,0,2);
            send_result(605,1,2,702,0); drain(); select_read(3,0,12'h600,0,2);
            send_result(605,0,2,703,0); drain(); select_read(3,1,12'h600,0,2);
        end
        rst_n=0;
        repeat (6) @(negedge csi_clk);
        rst_n=1; words(FRAME_WORDS);
        select_read(1,0,12'hc5a,0,0);
        if (snapshots<6 || valid_no_target<1 || motion_reads<2 || invalid_reads<3 ||
            (FRAME_WORDS!=172800 && (wrap_checks!=1 || queue_checks!=2)))
            $fatal(1,"Payload differential coverage incomplete case=%0d",CASE_ID);
        $display("TARGET_FRAME_BRIDGE_PAYLOAD_CASE_PASS words=%0d comparisons=%0d snapshots=%0d invalid=%0d valid_no_target=%0d motion=%0d wrap=%0d queues=%0d",
            FRAME_WORDS,comparisons,snapshots,invalid_reads,valid_no_target,motion_reads,
            wrap_checks,queue_checks);
        done=1;
    end
endmodule

module tb_target_frame_bridge_payload_equivalence;
    wire [4:0] done;
    target_frame_bridge_payload_case #(.FRAME_WORDS(1),.CASE_ID(0)) c0(done[0]);
    target_frame_bridge_payload_case #(.FRAME_WORDS(2),.CASE_ID(1)) c1(done[1]);
    target_frame_bridge_payload_case #(.FRAME_WORDS(4),.CASE_ID(2)) c2(done[2]);
    target_frame_bridge_payload_case #(.FRAME_WORDS(8),.CASE_ID(3)) c3(done[3]);
    target_frame_bridge_payload_case #(.FRAME_WORDS(172800),.CASE_ID(4)) c4(done[4]);
    initial begin
        wait (&done);
        $display("TARGET_FRAME_BRIDGE_PAYLOAD_EQUIVALENCE_PASS cases=5 frozen_reference=1 generic_full=1 compact=1");
        $finish;
    end
    initial begin
        #10000000;
        $fatal(1,"Payload differential timed out");
    end
endmodule
