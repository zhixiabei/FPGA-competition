// Fixed visible 480px ROI -> frozen seven-convolution classifier.
// Reuses the CRC-protected UART transport, but loads only the new bundle.
// One snapshot writer alternates DDR slots, overlapping compute and capture.
module fruitfixed_system #(
    parameter integer KEY4_CONTROL=0,
    parameter integer BACKGROUND_CONTROL=0,
    parameter integer SWITCH_CONTROL=0,
    parameter integer FLASH_MODEL_ENABLE=0,
    parameter integer KEY_DEBOUNCE_CYCLES=1333334
)(
    input wire clk,rst_n,calibrated,uart_rx,memory_error,
    input wire key4_n,
    input wire run_switch,
    output wire uart_tx,
    output wire flash_cs_n,flash_sck,flash_mosi,
    input wire flash_miso,
    input wire frame_start,
    input wire [1:0] frame_slot,
    input wire video_write,
    input wire [24:0] video_addr,
    input wire [127:0] video_data,
    output wire mem_valid,mem_write,
    output wire [31:0] mem_addr,
    output wire [127:0] mem_data,
    input wire mem_ready,mem_rsp_valid,
    input wire [127:0] mem_rsp_data,
    output reg result_valid,
    output reg [2:0] result_class,
    output wire model_ready,
    output wire [5:0] operation,
    output wire [31:0] runtime_status,
    output reg box_valid,
    output reg [11:0] box_x1,box_y1,box_x2,box_y2,
    output reg [15:0] result_frame
);
    localparam IDLE=0,CLASS_PREP=4,CLASSIFY=5,DECISION=6;
    reg [2:0] state;
    wire background_ready,foreground;
    wire key_enabled;
    wire run_requested=(KEY4_CONTROL!=0 || SWITCH_CONTROL!=0) ? key_enabled : 1'b1;
    // A switch already ON at startup first acquires a complete background.
    wire run_enabled=run_requested &&
                     (SWITCH_CONTROL==0 || BACKGROUND_CONTROL==0 || background_ready);
    handfixed_key_control #(.DEBOUNCE_CYCLES(KEY_DEBOUNCE_CYCLES),
        .LEVEL_CONTROL(SWITCH_CONTROL)) key_control(
        .clk(clk),.rst_n(rst_n),.key_n(SWITCH_CONTROL!=0 ? !run_switch : key4_n),.enabled(key_enabled));
    reg run_previous,discard_compute,discard_capture;
    wire stop_event=run_previous && !run_enabled;
    wire monitor_enabled=(run_enabled || (BACKGROUND_CONTROL!=0)) && model_ready;
    reg [4:0] op;
    assign operation={1'b0,op};
    wire [31:0] model_base,model_bytes,model_crc32;
    wire [15:0] fixed_x,fixed_y,fixed_side;
    reg guide_pending;
    handfixed_config config_rom(.model_base(model_base),.model_bytes(model_bytes),.model_crc32(model_crc32),
        .roi_x(fixed_x),.roi_y(fixed_y),.roi_side(fixed_side));
    wire rx_valid,rx_error,tx_valid,tx_ready;
    wire [7:0] rx_byte,tx_byte;
    wire load_valid,load_write;
    wire [31:0] load_addr;
    wire [127:0] load_data;
    wire [255:0] status_packet;
    generate if(FLASH_MODEL_ENABLE!=0) begin: flash_model
        wire [255:0] flash_diagnostics;
        fruit_flash_boot boot(.clk(clk),.rst_n(rst_n),.calibrated(calibrated),.memory_error(memory_error),
            .model_base(model_base),.model_bytes(model_bytes),.model_crc32(model_crc32),.model_ready(model_ready),
            .mem_valid(load_valid),.mem_write(load_write),.mem_addr(load_addr),.mem_data(load_data),
            .mem_ready(mem_ready),.mem_rsp_valid(mem_rsp_valid),.mem_rsp_data(mem_rsp_data),
            .flash_cs_n(flash_cs_n),.flash_sck(flash_sck),.flash_mosi(flash_mosi),.flash_miso(flash_miso),
            .diagnostics(flash_diagnostics));
        flash_status_uart status_uart(.clk(clk),.rst_n(rst_n),.rx(uart_rx),.tx(uart_tx),
            .runtime_status(status_packet),.flash_status(flash_diagnostics));
    end else begin: uart_model
        assign flash_cs_n=1'b1;
        assign flash_sck=1'b0;
        assign flash_mosi=1'b0;
        assign load_write=1'b1;
        resnet18_uart uart(.clk(clk),.rst_n(rst_n),.rx(uart_rx),.tx(uart_tx),
            .rx_valid(rx_valid),.rx_error(rx_error),.rx_data(rx_byte),
            .tx_valid(tx_valid),.tx_ready(tx_ready),.tx_data(tx_byte));
        resnet18_weight_loader loader(.clk(clk),.rst_n(rst_n),.rx_valid(rx_valid),.rx_error(rx_error),
        .rx_data(rx_byte),.tx_valid(tx_valid),.tx_data(tx_byte),.tx_ready(tx_ready),
        .allow_load(calibrated),.runtime_status(status_packet),.MODEL_BASE(model_base),
        .MODEL_BYTES(model_bytes),.MODEL_CRC32(model_crc32),.model_ready(model_ready),
        .accepted_packets(),.mem_valid(load_valid),.mem_addr(load_addr),.mem_data(load_data),.mem_ready(mem_ready));
    end endgenerate
    wire snap_valid,snap_done,snap_busy,snap_failed;
    wire [31:0] snap_addr;
    wire [127:0] snap_data;
    wire [18:0] captured,written;
    reg snap_start,capture_slot,pending_slot,read_slot,pending,capture_sof_seen;
    reg [15:0] frame_number,capture_frame,pending_frame,read_frame;
    reg [1:0] capture_phase;
    reg [7:0] capture_failures;
    reg [31:0] snapshot_base;
    reg [31:0] processing_cycles,last_processing_cycles;
    reg [15:0] result_count;
    handcnn_snapshot snapshot(.clk(clk),.rst_n(rst_n),.start(snap_start),
        .SNAPSHOT_BASE(capture_slot ? 32'h01100000 : 32'h00e00000),
        .frame_start(frame_start),.frame_slot(frame_slot),.video_write(video_write),
        .video_addr(video_addr),.video_data(video_data),.mem_valid(snap_valid),.mem_addr(snap_addr),
        .mem_data(snap_data),.mem_ready(mem_ready && !load_valid),.done(snap_done),.busy(snap_busy),
        .failed(snap_failed),.captured_beats(captured),.written_beats(written));
    wire pp_valid,pp_write,pp_done,pp_busy;
    wire [31:0] pp_addr;
    wire [127:0] pp_data;
    reg pp_start;
    reg background_job;
    wire has_texture;
    wire green_valid,green_row_end;
    wire [7:0] green_pixel;
    generate if(BACKGROUND_CONTROL!=0) begin: background_control
        handfixed_background background(.clk(clk),.rst_n(rst_n),.run_enabled(run_enabled),
            .start(pp_start),.scan_background(background_job),.done(pp_done),
            .pixel_valid(green_valid),.row_end(green_row_end),.green(green_pixel),
            .reference_ready(background_ready),.foreground(foreground),.changed_pixels());
    end else begin: no_background_control
        assign background_ready=1'b0;
        assign foreground=1'b1;
    end endgenerate
    wire compute_ready=mem_ready && !load_valid && !snap_valid;
    handfixed_preprocess preprocess(.clk(clk),.rst_n(rst_n),.start(pp_start),
        .has_texture(has_texture),.texture_edges(),.texture_range(),
        .green_valid(green_valid),.green_row_end(green_row_end),.green_pixel(green_pixel),
        .classifier(1'b1),.snapshot_base(snapshot_base),
        .roi_x(fixed_x),.roi_y(fixed_y),.roi_side(fixed_side),.busy(pp_busy),.done(pp_done),
        .mem_valid(pp_valid),.mem_write(pp_write),.mem_addr(pp_addr),.mem_data(pp_data),
        .mem_ready(compute_ready),.mem_rsp_valid(mem_rsp_valid),.mem_rsp_data(mem_rsp_data));
    wire core_valid,core_write,core_done,core_busy,core_fault;
    wire [31:0] core_addr,core_cycles,mac_cycles,wait_cycles;
    wire [127:0] core_data;
    reg core_start;
    wire [2:0] group;
    wire [383:0] descriptor;
    handfixed_program program_rom(.operation(op),.group(group),.descriptor(descriptor));
    fruitcnn128_core core(.clk(clk),.rst_n(rst_n),.start(core_start),.operation(op),.group(group),
        .descriptor(descriptor),.busy(core_busy),.done(core_done),.fault(core_fault),
        .mem_valid(core_valid),.mem_write(core_write),.mem_addr(core_addr),.mem_data(core_data),
        .mem_ready(compute_ready),.mem_rsp_valid(mem_rsp_valid),.mem_rsp_data(mem_rsp_data),
        .cycles(core_cycles),.mac_cycles(mac_cycles),.wait_cycles(wait_cycles));
    wire dec_valid,dec_done;
    wire [31:0] dec_addr;
    wire [2:0] dec_class;
    wire [79:0] logits;
    reg dec_start;
    fruitfixed_decode decode(.clk(clk),.rst_n(rst_n),.start(dec_start),.done(dec_done),
        .result_class(dec_class),.mem_valid(dec_valid),.mem_addr(dec_addr),
        .mem_ready(compute_ready),.mem_rsp_valid(mem_rsp_valid),.mem_rsp_data(mem_rsp_data),.debug_logits(logits));
    wire prep=state==CLASS_PREP;
    wire decoding=state==DECISION;
    wire compute_valid=prep ? pp_valid : decoding ? dec_valid : core_valid;
    assign mem_valid=load_valid || snap_valid || compute_valid;
    assign mem_write=load_valid ? load_write : snap_valid || (prep ? pp_write : decoding ? 1'b0 : core_write);
    assign mem_addr=load_valid ? load_addr : snap_valid ? snap_addr : prep ? pp_addr : decoding ? dec_addr : core_addr;
    assign mem_data=load_valid ? load_data : snap_valid ? snap_data : prep ? pp_data : core_data;
    wire [2:0] confirmed_class;
    wire skipped_unknown=prep && pp_done && !background_job && run_enabled &&
                         !discard_compute && (!has_texture || !foreground);
    wire filter_clear=!run_enabled || discard_compute || memory_error || core_fault ||
                      (prep && pp_done && background_job);
    fruitfixed_result_filter result_filter(.clk(clk),.rst_n(rst_n),.clear(filter_clear),
        .in_valid((run_enabled && !discard_compute && decoding && dec_done) || skipped_unknown),
        .in_class(skipped_unknown ? 3'd1 : dec_class),
        .decision_class(confirmed_class),.stable_class());
    // HFX1 flag bit 6 marks temporal confirmation. Logits remain RAW scores.
    wire [7:0] flags={core_fault,1'b1,memory_error,state!=IDLE,snap_failed,snap_busy,model_ready,calibrated};
    assign runtime_status={flags,2'd0,result_class,(result_count!=0),4'd0,1'b0,op,result_count[7:0]};
    // HFX1: same counters, fixed-region classifier-only firmware.
    // Class byte bits 7/6/5: manual control / requested run / old work draining.
    wire old_work_draining=(discard_compute && state!=IDLE) || (discard_capture && capture_phase!=0);
    assign status_packet={mac_cycles[15:0],core_cycles,last_processing_cycles,logits,
                          result_frame,result_count,capture_failures,(KEY4_CONTROL!=0),run_enabled,old_work_draining,
                          (BACKGROUND_CONTROL!=0),background_ready,result_class,flags,8'd1,32'h31555246};
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;op<=6;guide_pending<=1;snap_start<=0;capture_slot<=0;pending_slot<=0;read_slot<=0;
            run_previous<=0;discard_compute<=0;discard_capture<=0;
            pending<=0;capture_sof_seen<=0;frame_number<=0;capture_frame<=0;pending_frame<=0;read_frame<=0;
            capture_phase<=0;capture_failures<=0;snapshot_base<=32'h00e00000;
            pp_start<=0;background_job<=0;core_start<=0;dec_start<=0;result_valid<=0;result_class<=1;
            processing_cycles<=0;last_processing_cycles<=0;result_count<=0;
            box_valid<=0;box_x1<=0;box_y1<=0;box_x2<=0;box_y2<=0;result_frame<=0;
        end else begin
            snap_start<=0;pp_start<=0;core_start<=0;dec_start<=0;result_valid<=0;
            run_previous<=run_enabled;
            // Publish the guide once after reset, even before weights arrive.
            // Thereafter class, guide and source frame update only on completion.
            if(guide_pending) begin
                guide_pending<=0;result_valid<=1;box_valid<=1;
                box_x1<=fixed_x;box_y1<=fixed_y;
                box_x2<=fixed_x+fixed_side;box_y2<=fixed_y+fixed_side;
            end
            if(frame_start) frame_number<=frame_number+1'b1;
            if(state!=IDLE) processing_cycles<=processing_cycles+1'b1;
            // Publish only complete inference results. Keep the previous
            // class and box throughout capture/preprocessing/classification.
            // Pending snapshots are immutable. Never overwrite the read slot or
            // a completed pending frame. Busy capture may overlap all compute.
            case(capture_phase)
                0:if(monitor_enabled && (model_ready || BACKGROUND_CONTROL!=0) && calibrated && !pending) begin
                    capture_slot<=state!=IDLE ? !read_slot : !capture_slot;
                    snap_start<=1;capture_phase<=1;capture_sof_seen<=0;discard_capture<=0;
                end
                1:if(snap_busy) capture_phase<=2;
                2:begin
                    if(frame_start && !capture_sof_seen) begin capture_frame<=frame_number;capture_sof_seen<=1;end
                    if(snap_done) begin pending<=monitor_enabled && !discard_capture;pending_slot<=capture_slot;pending_frame<=capture_frame;capture_phase<=0;end
                    else if(!snap_busy) begin capture_phase<=0;capture_failures<=capture_failures+1'b1;end
                end
            endcase
            if(memory_error || core_fault) begin
                if(result_class!=1 || box_valid) result_valid<=1;
                result_class<=1;box_valid<=0;
            end else case(state)
                IDLE:if(monitor_enabled && pending && (BACKGROUND_CONTROL==0 || !run_enabled || model_ready)) begin
                    pending<=0;read_slot<=pending_slot;read_frame<=pending_frame;
                    snapshot_base<=pending_slot ? 32'h01100000 : 32'h00e00000;
                    pp_start<=1;background_job<=(BACKGROUND_CONTROL!=0) && !run_enabled;
                    processing_cycles<=0;state<=CLASS_PREP;op<=6;discard_compute<=0;
                end
                CLASS_PREP:if(pp_done) begin
                    if(has_texture && foreground && !background_job && run_enabled && !discard_compute) begin core_start<=1;state<=CLASSIFY;end
                    else begin
                        if(run_enabled && !discard_compute && !background_job) begin
                            // Flat/background frames use the same temporal
                            // confirmation as CNN labels, preventing a single
                            // threshold excursion from clearing the display.
                            result_class<=confirmed_class;result_valid<=1;result_frame<=read_frame;
                            box_valid<=1;box_x1<=fixed_x;box_y1<=fixed_y;
                            box_x2<=fixed_x+fixed_side;box_y2<=fixed_y+fixed_side;
                            result_count<=result_count+1'b1;last_processing_cycles<=processing_cycles;
                        end
                        state<=IDLE;
                    end
                end
                CLASSIFY:if(core_done) begin
                    if(op==14) begin dec_start<=1;state<=DECISION;end
                    else begin op<=op+1'b1;core_start<=1;end
                end
                DECISION:if(dec_done) begin
                    if(run_enabled && !discard_compute) begin
                        result_class<=confirmed_class;result_valid<=1;result_frame<=read_frame;
                        box_valid<=1;box_x1<=fixed_x;box_y1<=fixed_y;
                        box_x2<=fixed_x+fixed_side;box_y2<=fixed_y+fixed_side;
                        result_count<=result_count+1'b1;last_processing_cycles<=processing_cycles;
                    end
                    state<=IDLE;
                end
            endcase
            if(stop_event) begin
                // Do not reset a DDR client with outstanding commands. Finish
                // old work, suppress its result, and discard its capture even
                // if KEY4 is pressed again before that work has drained.
                pending<=0;discard_compute<=1;discard_capture<=1;
                if(!memory_error && !core_fault) begin
                    result_class<=1;result_valid<=1;box_valid<=1;
                    box_x1<=fixed_x;box_y1<=fixed_y;
                    box_x2<=fixed_x+fixed_side;box_y2<=fixed_y+fixed_side;
                end
            end
        end
    end
endmodule
