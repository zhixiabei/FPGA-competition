`timescale 1ns/1ps

// Structural transaction checks against the production fruit_merged system.
// CNN completion is injected; snapshot queuing and the first preprocessor
// read use their real state machines. Only snapshot length is reduced.
module tb_fruit_roi_system;
    reg clk=0;
    always #7.5 clk=~clk;
    reg rst_n=0,calibrated=0,memory_error=0;
    reg run_override=0,frame_start=0,video_write=0;
    reg [1:0] frame_slot=0;
    reg [24:0] video_addr=0;
    reg [127:0] video_data=0;
    reg mem_ready=0,mem_rsp_valid=0;
    reg [127:0] mem_rsp_data=0;
    wire mem_valid,mem_write,result_valid,box_valid;
    wire [31:0] mem_addr;
    wire [127:0] mem_data;
    wire [2:0] result_class;
    wire [11:0] x1,y1,x2,y2;
    wire [15:0] result_frame;

    // Deliberately use the production ROI defaults, rather than supplying
    // expected coordinates as parameters to the implementation.
    fruitfixed_system #(
        .KEY4_CONTROL(1),.BACKGROUND_CONTROL(1),.SWITCH_CONTROL(1),
        .FLASH_MODEL_ENABLE(1),.KEY_DEBOUNCE_CYCLES(4)
    ) dut(
        .clk(clk),.rst_n(rst_n),.calibrated(calibrated),
        .uart_rx(1'b1),.uart_tx(),.memory_error(memory_error),
        .key4_n(1'b1),.run_switch(1'b1),
        .flash_cs_n(),.flash_sck(),.flash_mosi(),.flash_miso(1'b1),
        .frame_start(frame_start),.frame_slot(frame_slot),
        .video_write(video_write),.video_addr(video_addr),.video_data(video_data),
        .mem_valid(mem_valid),.mem_write(mem_write),.mem_addr(mem_addr),
        .mem_data(mem_data),.mem_ready(mem_ready),.mem_rsp_valid(mem_rsp_valid),
        .mem_rsp_data(mem_rsp_data),
        .result_valid(result_valid),.result_class(result_class),
        .model_ready(),.operation(),.runtime_status(),
        .box_valid(box_valid),.box_x1(x1),.box_y1(y1),
        .box_x2(x2),.box_y2(y2),.result_frame(result_frame)
    );
    defparam dut.snapshot.BEATS=4;

    integer checks=0,guide_checks=0,flat_checks=0,decision_checks=0;
    integer stop_checks=0,stalled_read_cycles=0,stalled_write_cycles=0;
    integer snapshot_writes=0;
    reg snapshot_scoreboard=0;

    function [127:0] snapshot_word(input integer index);
        snapshot_word=128'h0123456789abcdef_fedcba9876543210^{96'd0,index[31:0]};
    endfunction

    task automatic check(input bit condition,input string message);
        begin
            checks=checks+1;
            if(!condition) $fatal(1,"%s",message);
        end
    endtask

    task automatic tick;
        begin @(posedge clk);#1;end
    endtask

    task automatic expect_box(
        input string route,input [2:0] expected_class,input [15:0] expected_frame
    );
        begin
            check(result_valid===1'b1 && box_valid===1'b1,
                {route,": publication or box valid missing"});
            check(x1===12'd240 && y1===12'd120 &&
                  x2===12'd719 && y2===12'd599,
                {route,": default ROI differs from centered 480x480 square"});
            check(result_class===expected_class && result_frame===expected_frame,
                {route,": class/source frame publication mismatch"});
            check((x2-x1+1)==480 && (y2-y1+1)==480 &&
                  (x1+x2+1)==960 && (y1+y2+1)==720,
                {route,": ROI size/center/inclusive endpoint mismatch"});
        end
    endtask

    task automatic reset_and_guide;
        begin
            @(negedge clk);
            rst_n=0;calibrated=0;memory_error=0;run_override=0;
            frame_start=0;video_write=0;video_addr=0;video_data=0;
            mem_ready=0;mem_rsp_valid=0;mem_rsp_data=0;
            repeat(5) tick();
            check(result_valid===1'b0 && box_valid===1'b0 &&
                  x1===12'd0 && y1===12'd0 && x2===12'd0 && y2===12'd0,
                "Reset did not invalidate/clear published ROI");
            check(mem_valid===1'b0 && dut.state===3'd0 &&
                  dut.capture_phase===2'd0 && dut.snapshot.busy===1'b0,
                "Reset did not clear compute/capture transactions");
            @(negedge clk);rst_n=1;
            tick();
            expect_box("initial guide",3'd1,16'd0);
            guide_checks=guide_checks+1;
            tick();
            check(result_valid===1'b0 && box_valid===1'b1,
                "Initial guide was republished without an event");
        end
    endtask

    task automatic enable_run;
        begin
            @(negedge clk);run_override=1;
            tick();
            check(dut.run_enabled===1'b1 && dut.run_previous===1'b1,
                "Test run control failed to enter enabled state");
        end
    endtask

    task automatic publish_flat(
        input [2:0] expected_class,input [15:0] source_frame
    );
        begin
            @(negedge clk);
            dut.state=3'd4;dut.background_job=0;dut.read_frame=source_frame;
            force dut.pp_done=1'b1;
            force dut.has_texture=1'b0;
            tick();
            expect_box("CLASS_PREP flat/NONE",expected_class,source_frame);
            check(dut.state===3'd0 && dut.core_start===1'b0,
                "Flat completion launched CNN or failed to return idle");
            flat_checks=flat_checks+1;
            @(negedge clk);
            release dut.pp_done;
            release dut.has_texture;
        end
    endtask

    // Static task: ModelSim permits forcing a hierarchical wire to its inputs.
    task publish_decision(
        input [2:0] raw_class,input [2:0] expected_class,input [15:0] source_frame
    );
        begin
            @(negedge clk);
            dut.state=3'd6;dut.read_frame=source_frame;
            force dut.dec_done=1'b1;
            force dut.dec_class=raw_class;
            tick();
            expect_box("DECISION",expected_class,source_frame);
            check(dut.state===3'd0,"Decision did not return idle");
            decision_checks=decision_checks+1;
            @(negedge clk);
            release dut.dec_done;
            release dut.dec_class;
        end
    endtask

    task automatic stop_and_expect(input [15:0] retained_frame);
        begin
            @(negedge clk);run_override=0;
            tick();
            expect_box("stop",3'd1,retained_frame);
            check(dut.discard_compute===1'b1 && dut.discard_capture===1'b1,
                "Stop did not mark old compute/capture for discard");
            stop_checks=stop_checks+1;
        end
    endtask

    // Check every accepted snapshot word independently of the producer.
    always @(posedge clk) if(rst_n && snapshot_scoreboard && mem_valid && mem_ready) begin
        if(mem_write!==1'b1 || mem_addr!==(32'h01100000+16*snapshot_writes) ||
           mem_data!==snapshot_word(snapshot_writes))
            $fatal(1,"Snapshot DDR transaction mismatch beat=%0d addr=%h data=%h",
                snapshot_writes,mem_addr,mem_data);
        snapshot_writes=snapshot_writes+1;
    end

    integer waited,i;
    reg [31:0] held_address;
    reg [127:0] held_data;
    initial begin
        // Downstream model/background readiness is outside this geometry
        // regression. Keep all real DDR client state machines in circuit.
        force dut.key_enabled=run_override;
        force dut.background_ready=1'b1;
        force dut.model_ready=1'b1;

        reset_and_guide();
        enable_run();
        publish_flat(3'd1,16'd101);
        publish_decision(3'd2,3'd1,16'd201);
        publish_decision(3'd2,3'd2,16'd202);
        publish_flat(3'd2,16'd203);
        publish_flat(3'd2,16'd204);
        publish_flat(3'd1,16'd205);
        stop_and_expect(16'd205);
        tick();
        check(!result_valid && box_valid,"Stopped guide did not remain stable");

        // Start the restored square preprocessor and verify that the actual
        // sampling origin moves with the display guide.
        reset_and_guide();
        enable_run();
        @(negedge clk);
        dut.state=3'd4;dut.background_job=0;dut.read_frame=16'd301;
        dut.pp_start=1;mem_ready=1;
        tick();
        waited=0;
        @(negedge clk);
        while(!(mem_valid && !mem_write) && waited<100000) begin
            waited=waited+1;
            @(negedge clk);
        end
        check(waited<100000,"Real ROI preprocessor never requested snapshot data");
        check(dut.preprocess.origin_x===16'd240 &&
              dut.preprocess.origin_y===16'd120 &&
              dut.preprocess.side===16'd480 &&
              dut.preprocess.step===32'd245760 &&
              dut.preprocess.xstart===32'sd15818752 &&
              dut.preprocess.ystart===32'sd7954432,
            "Production square crop origin/side/3.75px sampling differs from guide");
        check(mem_addr===(32'h00e00000+32'd465360),
            "First square read did not use source pixel (241,121)");
        mem_ready=0;
        held_address=mem_addr;held_data=mem_data;
        for(i=0;i<4;i=i+1) begin
            tick();
            check(mem_valid && !mem_write && mem_addr===held_address &&
                  mem_data===held_data && dut.pp_busy && dut.state===3'd4,
                "Preprocessor changed a backpressured read before stop");
            stalled_read_cycles=stalled_read_cycles+1;
        end
        stop_and_expect(16'd0);
        for(i=0;i<5;i=i+1) begin
            tick();
            check(mem_valid && !mem_write && mem_addr===held_address &&
                  mem_data===held_data && dut.pp_busy && dut.state===3'd4,
                "Stop aborted/changed an unaccepted preprocessor read");
            stalled_read_cycles=stalled_read_cycles+1;
        end
        @(negedge clk);mem_ready=1;
        tick();
        check(dut.pp_busy && !mem_valid && dut.preprocess.state===5'd4,
            "Accepted read did not wait for its DDR response");
        for(i=0;i<5;i=i+1) begin
            tick();
            check(dut.pp_busy && dut.preprocess.state===5'd4 && dut.state===3'd4,
                "Stop aborted the outstanding DDR response");
        end
        @(negedge clk);
        mem_rsp_valid=1;mem_rsp_data=128'h1122334455667788_99aabbccddeeff00;
        tick();
        check(dut.pp_busy && dut.preprocess.state!==5'd4 &&
              dut.preprocess.cache_valid!==4'd0,
            "Stopped preprocessor failed to consume/cache delayed DDR response");
        @(negedge clk);mem_rsp_valid=0;
        // Completion of the rest of the tensor is injected only after the
        // real accepted transaction has drained. No pending request is cut.
        force dut.pp_done=1'b1;
        tick();
        check(dut.state===3'd0 && !result_valid && result_class===3'd1 &&
              box_valid && dut.result_count===16'd0,
            "Discarded preprocessing published a stale class/frame");
        @(negedge clk);release dut.pp_done;

        // Exercise a genuine four-beat immutable snapshot while stopped.
        reset_and_guide();
        enable_run();
        @(negedge clk);calibrated=1;mem_ready=0;
        waited=0;
        while(!(dut.snap_busy && dut.snapshot.armed) && waited<20) begin
            waited=waited+1;
            @(negedge clk);
        end
        check(waited<20,"Snapshot capture did not arm");
        frame_start=1;
        tick();
        @(negedge clk);frame_start=0;
        for(i=0;i<4;i=i+1) begin
            video_write=1;video_addr=25'(8*i);video_data=snapshot_word(i);
            tick();
            @(negedge clk);
        end
        video_write=0;
        check(dut.snap_busy && dut.capture_slot===1'b1 &&
              dut.captured===19'd4 && dut.written===19'd0 &&
              mem_valid && mem_write,
            "Snapshot did not retain all four source beats under backpressure");
        held_address=mem_addr;held_data=mem_data;
        stop_and_expect(16'd0);
        for(i=0;i<5;i=i+1) begin
            tick();
            check(dut.snap_busy && dut.capture_phase===2'd2 &&
                  mem_valid && mem_write && mem_addr===held_address &&
                  mem_data===held_data && dut.written===19'd0,
                "Stop aborted/changed queued snapshot DDR write");
            stalled_write_cycles=stalled_write_cycles+1;
        end
        @(negedge clk);snapshot_scoreboard=1;mem_ready=1;
        repeat(4) tick();
        @(negedge clk);calibrated=0;snapshot_scoreboard=0;
        check(snapshot_writes==4 && dut.written===19'd4 && !dut.snap_busy,
            "Snapshot did not drain every queued DDR word after stop");
        repeat(3) tick();
        check(dut.capture_phase===2'd0 && !dut.pending && !result_valid &&
              !dut.old_work_draining && dut.result_count===16'd0,
            "Discarded capture became a pending or published inference");

        // Error invalidation must retain the existing one-pulse behavior;
        // a fresh reset is the event that restores the initial guide.
        reset_and_guide();
        @(negedge clk);memory_error=1;
        tick();
        check(result_valid && !box_valid && result_class===3'd1,
            "Memory error failed to publish an invalid ROI");
        tick();
        check(!result_valid && !box_valid,"Persistent memory error republished ROI");
        @(negedge clk);memory_error=0;
        repeat(2) tick();
        check(!result_valid && !box_valid,"Clearing error revived an unvalidated ROI");

        reset_and_guide();
        @(negedge clk);force dut.core_fault=1'b1;
        tick();
        check(result_valid && !box_valid && result_class===3'd1,
            "Core error failed to invalidate the ROI");
        tick();
        check(!result_valid && !box_valid,"Persistent core error republished ROI");
        @(negedge clk);release dut.core_fault;
        reset_and_guide();

        check(guide_checks==6 && flat_checks==4 && decision_checks==2 &&
              stop_checks==3 && stalled_read_cycles==9 &&
              stalled_write_cycles==5 && snapshot_writes==4,
            "Incomplete ROI publication/transaction coverage");
        $display("FRUIT_ROI_SYSTEM_PASS checks=%0d guide=%0d flat_none=%0d decision=%0d stop=%0d read_stall_cycles=%0d write_stall_cycles=%0d snapshot_writes=%0d roi=240,120,480,480 inclusive=719,599",
            checks,guide_checks,flat_checks,decision_checks,stop_checks,
            stalled_read_cycles,stalled_write_cycles,snapshot_writes);
        $finish;
    end
    initial begin #3000000;$fatal(1,"Fruit ROI system timeout");end
endmodule
