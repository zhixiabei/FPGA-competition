`timescale 1ns/1ps
// Two real-photo results while snapshot capture and independent video traffic
// compete through the production DDR bridge. Address and write-data ACKs stall
// separately. Frozen input slots must never be written by an active capture.
module tb_handfixed_system;
    reg clk=0;always #7.5 clk=~clk;
    reg rst_n=0,sof=0,vw=0,key4_n=1;
    reg [1:0] frame_slot=0;
    reg [24:0] va=0;
    reg [127:0] vd=0;
    wire nv,nw,nready,nrsp,rv,model_ready,error;
    wire [31:0] na,status;
    wire [127:0] nd,nrd;
    wire [2:0] label;wire box_valid;wire [11:0] x1,y1,x2,y2;
    wire [15:0] result_frame;
    reg vv=0,vr=0;
    wire vready,vrsp;
    wire [127:0] vrd,dd;
    wire [24:0] da;
    wire dr,dav,ddv;
    reg drr=0,dwr=0,ddr=0,rs=0;
    reg [127:0] rd=0;
    reg show_hand=0;reg [127:0] background[0:172799];
    reg [127:0] photo[0:172799],snap0[0:172799],snap1[0:172799];
    reg [127:0] features[0:16383],model[0:20000];
    reg [31:0] ra[0:511],wa[0:511];
    reg [127:0] wd[0:511];
    reg [31:0] rng=32'h73591abc;
    integer rp=0,wp=0,rc=0,arp=0,awp=0,ac=0,drp=0,dwp=0,dc=0;
    integer tick=0,ft=0,frame=0,beat=0,results=0,last_frame=-1;
    integer stale_frame=-1,paused_count=0;reg check_paused=0;
    integer video_reads=0,video_responses=0,video_writes=0,snapshots=0;
    handfixed_system #(.KEY4_CONTROL(1),.BACKGROUND_CONTROL(1),.KEY_DEBOUNCE_CYCLES(4)) dut(.key4_n(key4_n),.clk(clk),.rst_n(rst_n),.calibrated(1'b1),.uart_rx(1'b1),.uart_tx(),
        .memory_error(error),.frame_start(sof),.frame_slot(frame_slot),.video_write(vw),.video_addr(va),.video_data(vd),
        .mem_valid(nv),.mem_write(nw),.mem_addr(na),.mem_data(nd),.mem_ready(nready),.mem_rsp_valid(nrsp),.mem_rsp_data(nrd),
        .result_valid(rv),.result_class(label),.model_ready(model_ready),.operation(),.runtime_status(status),
        .box_valid(box_valid),.box_x1(x1),.box_y1(y1),.box_x2(x2),.box_y2(y2),.result_frame(result_frame));
    resnet18_memory_bridge bridge(.clk(clk),.rst_n(rst_n),.calibrated(1'b1),
        .v_valid(vv),.v_read(vr),.v_addr(25'h0400000),.v_data(128'h1234),.v_ready(vready),.v_rsp_valid(vrsp),.v_rsp_data(vrd),
        .n_valid(nv),.n_write(nw),.n_addr(na),.n_data(nd),.n_ready(nready),.n_rsp_valid(nrsp),.n_rsp_data(nrd),
        .d_addr(da),.d_read(dr),.d_addr_valid(dav),.d_data_valid(ddv),.d_data(dd),
        .d_read_ready(drr),.d_write_ready(dwr),.d_data_ready(ddr),.d_rsp_valid(rs),.d_rsp_data(rd),.protocol_error(error));
    function [127:0] read_word(input [31:0] a);
        begin
            if(a==32'h00800000) read_word=128'h1234;
            else if(a>=32'h00c00000 && a<32'h00c50000) read_word=model[(a-32'h00c00000)>>4];
            else if(a>=32'h00d00000 && a<32'h00d40000) read_word=features[(a-32'h00d00000)>>4];
            else if(a>=32'h00e00000 && a<32'h010a3000) read_word=snap0[(a-32'h00e00000)>>4];
            else if(a>=32'h01100000 && a<32'h013a3000) read_word=snap1[(a-32'h01100000)>>4];
            else begin $fatal(1,"bad system DDR read %h",a);read_word=0;end
        end
    endfunction
    task write_word(input [31:0] a,input [127:0] value);
        begin
            if(a==32'h00800000) begin end
            else if(a>=32'h00d00000 && a<32'h00d40000) features[(a-32'h00d00000)>>4]=value;
            else if(a>=32'h00e00000 && a<32'h010a3000) begin
                snap0[(a-32'h00e00000)>>4]=value;
            end else if(a>=32'h01100000 && a<32'h013a3000) begin
                snap1[(a-32'h01100000)>>4]=value;
            end else $fatal(1,"bad system DDR write %h",a);
        end
    endtask
    always @(negedge clk) begin
        tick=tick+1;rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
        drr=rng[1:0]!=0 && rc<400;dwr=rng[3:2]!=0;ddr=rng[6:4]!=0;rs=0;
        if(rc>0 && rng[8:7]!=0) begin rs=1;rd=read_word(ra[rp]);rp=(rp+1)%512;rc=rc-1;end
        if(ac>0 && dc>0) begin write_word(wa[arp],wd[drp]);arp=(arp+1)%512;drp=(drp+1)%512;ac=ac-1;dc=dc-1;end
        sof=0;vw=0;
        if(rst_n) begin
            if(ft==0) begin sof=1;frame_slot=frame%4;beat=0;end
            if(ft>=4 && ft<691204 && ft%4==0) begin
                vw=1;va=(frame%4)*1572864+beat*8;vd=show_hand ? photo[beat] : background[beat];beat=beat+1;
            end
            ft=ft+1;if(ft==800000) begin ft=0;frame=frame+1;end
            if(!vv && tick%4==0) begin vv=1;vr=~vr;end
        end
    end
    always @(posedge clk) begin
        // Check submission, since the bridge can retire the last capture
        // write after the FSM starts (ordered DDR commands preserve it).
        if(nv && nw && nready && dut.state!=0) begin
            if(na>=32'h00e00000 && na<32'h010a3000 && !dut.read_slot) $fatal(1,"active snapshot A overwritten");
            if(na>=32'h01100000 && na<32'h013a3000 && dut.read_slot) $fatal(1,"active snapshot B overwritten");
        end
        if(dav && (dr ? drr : dwr)) begin
            if(dr) begin ra[wp]={6'd0,da,1'b0};wp=(wp+1)%512;rc=rc+1;end
            else begin wa[awp]={6'd0,da,1'b0};awp=(awp+1)%512;ac=ac+1;end
        end
        if(ddv && ddr) begin wd[dwp]=dd;dwp=(dwp+1)%512;dc=dc+1;end
        if(vv && vready) begin if(vr) video_reads=video_reads+1;else video_writes=video_writes+1;vv=0;end
        if(vrsp) begin video_responses=video_responses+1;if(vrd!==128'h1234) $fatal(1,"read owner/data corrupted");end
        if(dut.snap_done) snapshots=snapshots+1;
        if(error || dut.core_fault || dut.snap_failed || tick>40000000) $fatal(1,"system fault/timeout state=%0d op=%0d",dut.state,dut.op);
        if(!dut.run_enabled && dut.core_start) $fatal(1,"CNN started during background calibration");
        if(rv && dut.result_count!=0 && !box_valid) $fatal(1,"fixed guide lost");

    end
    task key_press;
        begin
            @(negedge clk);key4_n=0;repeat(12) @(negedge clk);
            key4_n=1;repeat(12) @(negedge clk);
        end
    endtask
    task next_result;
        integer count_before;
        begin
            count_before=dut.result_count;
            wait(dut.result_count!=count_before);
            @(negedge clk);
            if(!box_valid || x1!=400 || y1!=120 || x2!=880 || y2!=600) $fatal(1,"ROI changed");
        end
    endtask
    task set_hand(input integer value);
        begin wait(ft==799999);@(posedge clk);show_hand=value;end
    endtask
    integer before_cycles,blank_count;
    initial begin
        $readmemh("model.hex",model,0,14591);
        $readmemh("snapshot_punch.hex",photo);
        $readmemh("snapshot_background.hex",background);
        force dut.loader.model_ready=1'b0;
        repeat(10) @(negedge clk);rst_n=1;
        wait(dut.background_ready);@(negedge clk);
        if(dut.run_enabled || dut.core_cycles || dut.result_count) $fatal(1,"calibration ran CNN");
        force dut.loader.model_ready=1'b1;
        key_press();
        repeat(3) begin next_result();if(label!=1 || !dut.has_texture || dut.core_cycles) $fatal(1,"textured background accepted");end
        $display("HANDFIXED_BACKGROUND_SYSTEM_EMPTY_PASS texture=%0d count=%0d",dut.has_texture,dut.result_count);
        set_hand(1);wait(label==3);@(negedge clk);
        if(dut.logits!==48'hf1c9278fe9d0 || !dut.foreground) $fatal(1,"hand CNN/logits changed");
        repeat(2) begin next_result();if(label!=3 || !dut.foreground) $fatal(1,"stationary hand lost");end
        $display("HANDFIXED_BACKGROUND_SYSTEM_HAND_PASS stationary confirmed_punch");
        set_hand(0);wait(label==1);@(negedge clk);
        before_cycles=dut.core_cycles;blank_count=dut.result_count;
        repeat(3) begin next_result();if(label!=1 || dut.core_cycles!=before_cycles) $fatal(1,"background reclassified");end
        key_press();if(dut.run_enabled || label!=1 || !dut.model_ready) $fatal(1,"stop lost model/display");
        repeat(2) begin wait(dut.background_job && dut.pp_done);@(negedge clk);end
        if(!dut.background_ready || dut.core_cycles!=before_cycles || dut.result_count!=blank_count+3)
            $fatal(1,"paused reference refresh ran CNN or published results");
        if(video_reads<10000 || video_responses<10000 || video_writes<10000 || error || dut.capture_failures)
            $fatal(1,"DDR/video coverage failure");
        $display("HANDFIXED_BACKGROUND_SYSTEM_PASS textured_empty stationary_hand removal_nothing paused_refresh model_preserved fixed480 video_reads=%0d",video_reads);
        $finish;
    end
endmodule
