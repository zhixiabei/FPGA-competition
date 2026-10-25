`timescale 1ns/1ps
// Real pixel-chain regression. The source is independent RGB; reference bytes
// are captured BEFORE the 96-to-128 packer and compared with real DDR writes.
// No FIFO or algorithm stub, no framing forced into the DUT, and no ROI mask.
module tb_video_fifo_frame_integrity #(
    parameter integer W=1280,H=720,
    parameter real DDR_PHASE=9.3,
    parameter integer READY_GAPS=1,
    parameter integer RAW_SOURCE=0
);
localparam integer GROUPS=W/4,PIXELS=W*H,WORDS=PIXELS*3/16;
reg camera_clk=0,ddr_clk=0;
always #4.830 camera_clk=~camera_clk;
initial begin #(DDR_PHASE);forever #7.5 ddr_clk=~ddr_clk;end
reg rst_n=0,in_user=0,in_valid=0,in_last=0,edge_mode=0;
reg [95:0] in_data=0;
integer frame,row,group_index,pixel_lane,clear_index;
wire [95:0] rgb_source;
wire rgb_user,rgb_last,rgb_valid;
generate if(RAW_SOURCE) begin: raw_input
    reg [39:0] raw_data;
    reg [23:0] raw_colour;
    integer raw_lane;
    always @(*) begin
        for(raw_lane=0;raw_lane<4;raw_lane=raw_lane+1) begin
            raw_colour=in_data[95-raw_lane*24 -:24];
            raw_data[raw_lane*10 +:10]=
                ((row%2==0 && raw_lane%2==0)?raw_colour[7:0]:
                 (row%2==1 && raw_lane%2==1)?raw_colour[23:16]:raw_colour[15:8])*4;
        end
    end
    wire [127:0] reconstructed;
    demosaic #(.IMG_WIDTH(W),.IMG_HEIGHT(H),.BAYER_MODE("BGGR")) u_demosaic (
        .I_clk(camera_clk),.I_rst_n(rst_n),.axi4s_video_tdata(raw_data),
        .axi4s_video_tdest(10'd0),.axi4s_video_tvalid(in_valid),
        .axi4s_video_tuser(in_user),.axi4s_video_tlast(in_last),
        .axi4s_video_tready(),.O_tvalid(rgb_valid),.O_tuser(rgb_user),
        .O_tlast(rgb_last),.O_tdata(reconstructed),.O_tready(1'b1));
    data128_96 u_order(.I_tdata(reconstructed),.O_tdata(rgb_source));
end else begin: rgb_input
    assign rgb_source=in_data;
    assign rgb_user=in_user;assign rgb_last=in_last;assign rgb_valid=in_valid;
end endgenerate
wire awb_user,awb_valid,awb_last;wire [95:0] awb_data;
awb #(.IMG_WIDTH(W),.IMG_HEIGHT(H)) u_awb(
.I_clk(camera_clk),.I_rst_n(rst_n),.I_tlast(rgb_last),.I_tuser(rgb_user),
.I_tdata(rgb_source),.I_tvalid(rgb_valid),.I_tready(),.O_tlast(awb_last),
.O_tuser(awb_user),.O_tdata(awb_data),.O_tvalid(awb_valid),.O_tready(1'b1));
wire selected_user,selected_valid,selected_last,selected_mode;
wire [95:0] selected_data;
rgb_edge_switch_96 #(.IMG_WIDTH(W),.IMG_HEIGHT(H),.DEFAULT_EDGE_MODE(0)) u_selector(
.I_clk(camera_clk),.I_rst_n(rst_n),
.I_effect_config({edge_mode ? 4'd2 : 4'd0,8'd0}),
.I_tlast(awb_last),.I_tuser(awb_user),.I_tdata(awb_data),.I_tvalid(awb_valid),
.O_tlast(selected_last),.O_tuser(selected_user),.O_tdata(selected_data),
.O_tvalid(selected_valid),.O_edge_mode(selected_mode));
wire packed_user,packed_valid;wire [127:0] packed_data;
data_96bit_to_128bit u_packer(
.I_clk(camera_clk),.I_rst_n(rst_n),.I_96b_frame_start(selected_user),
.I_96b_valid(selected_valid),.I_96b_data(selected_data),
.O_128b_frame_start(packed_user),.O_128b_valid(packed_valid),.O_128b_data(packed_data));
wire writer_busy,ddr_write;wire [1:0] read_slot,write_slot;
wire write_start;wire [1:0] write_start_slot;
wire [24:0] write_address;wire [127:0] write_data;
integer ddr_cycle=0;
wire ddr_ready=!READY_GAPS || ddr_cycle%19!=0;
video_in #(.FRAME_STRIDE_NATIVE(1572864)) u_video_in(
.I_rst_n(rst_n),.I_camera_clk(camera_clk),.I_camera_frame_start(packed_user),
.I_camera_valid(packed_valid),.I_camera_data(packed_data),.I_mipi_rx_error(1'b0),
.I_ddr_clk(ddr_clk),.I_display_pause(1'b0),.I_video_out_rd_busy(1'b0),
.O_video_in_wr_busy(writer_busy),.O_video_out_rp(read_slot),.O_write_frame_slot(write_slot),
.O_write_frame_start(write_start),.O_write_start_slot(write_start_slot),
.O_ddr_user_wr_en(ddr_write),.O_ddr_user_addr(write_address),
.O_ddr_user_wr_data(write_data),.I_ddr_user_ready(ddr_ready));
reg [23:0] reference_pixels[0:PIXELS-1];
reg [127:0] stored_words[0:WORDS-1];
reg snapshot_start=0;
wire snapshot_valid,snapshot_done,snapshot_busy,snapshot_failed;
wire [31:0] snapshot_address;
wire [127:0] snapshot_data;
wire snapshot_ready=ddr_cycle%7!=0;
integer snapshot_words=0,snapshot_frames=0;
handcnn_snapshot #(.BEATS(WORDS)) u_snapshot(
    .clk(ddr_clk),.rst_n(rst_n),.start(snapshot_start),.SNAPSHOT_BASE(32'h03d13840),
    .frame_start(write_start),.frame_slot(write_start_slot),.video_write(ddr_write),
    .video_addr(write_address),.video_data(write_data),.mem_valid(snapshot_valid),
    .mem_addr(snapshot_address),.mem_data(snapshot_data),.mem_ready(snapshot_ready),
    .done(snapshot_done),.busy(snapshot_busy),.failed(snapshot_failed),.captured_beats(),.written_beats());
always @(posedge ddr_clk) begin
    if(snapshot_start) snapshot_words=0;
    if(snapshot_valid && snapshot_ready) begin
        if(snapshot_address!==32'h03d13840+snapshot_words*16 ||
           snapshot_data!==stored_words[snapshot_words])
            $fatal(1,"real camera snapshot mismatch beat=%0d",snapshot_words);
        snapshot_words=snapshot_words+1;
    end
    if(snapshot_done) snapshot_frames=snapshot_frames+1;
end
integer capture_frame=-1,capture_pixels=0,packed_words=0;
integer ddr_frame=-1,committed_words=0,first_mismatch=-1,mismatched_words=0;
integer byte_checks=0,prefix_index=-1,fifo_reset_overlaps=0,fifo_full_errors=0;
integer edge_pixels=0,colour_pixels=0,awb_pixels=0;
integer frames_passed=0;
integer lane,word_byte,source_byte,source_pixel,byte_channel,address_index;
reg [23:0] pixel_value;reg [127:0] expected_word;
reg [2047:0] export_root;
integer export_enabled=0;
function [23:0] source_rgb(input integer pixel_index);
    source_rgb=pixel_index;
endfunction
function automatic integer source_raw(input integer px,input integer py);
    integer xx,yy;
    reg [23:0] colour;
    begin
        xx=px<0?1:px>=W?W-2:px;
        yy=py<0?1:py>=H?H-2:py;
        colour=source_rgb(yy*W+xx);
        source_raw=(yy%2==0 && xx%2==0)?colour[7:0]:
                   (yy%2==1 && xx%2==1)?colour[23:16]:colour[15:8];
    end
endfunction
function automatic [23:0] expected_rgb(input integer pixel_index);
    integer px,py,c,n,s,e,w,diag,rr,gg,bb,dh,dv;
    begin
        if(!RAW_SOURCE) expected_rgb=source_rgb(pixel_index);
        else begin
            px=pixel_index%W;py=pixel_index/W;
            c=source_raw(px,py);n=source_raw(px,py-1);s=source_raw(px,py+1);
            e=source_raw(px+1,py);w=source_raw(px-1,py);
            diag=(source_raw(px-1,py-1)+source_raw(px+1,py-1)+
                  source_raw(px-1,py+1)+source_raw(px+1,py+1))/4;
            if(px%2==py%2) begin
                dh=e>w?e-w:w-e;dv=n>s?n-s:s-n;
                gg=dh+8<dv?(e+w)/2:dv+8<dh?(n+s)/2:(n+s+e+w)/4;
                rr=py%2?c:diag;bb=py%2?diag:c;
            end else begin
                gg=c;rr=py%2?(e+w)/2:(n+s)/2;
                bb=py%2?(n+s)/2:(e+w)/2;
            end
            expected_rgb={rr[7:0],gg[7:0],bb[7:0]};
        end
    end
endfunction
function [7:0] reference_byte(input integer byte_index);
    integer px,ch;
    begin
        px=byte_index/3;ch=byte_index%3;
        case(ch)
            0:reference_byte=reference_pixels[px][23:16];
            1:reference_byte=reference_pixels[px][15:8];
            default:reference_byte=reference_pixels[px][7:0];
        endcase
    end
endfunction
always @(posedge camera_clk) begin
    if(rst_n) begin
        if(awb_user) awb_pixels=0;
        if(awb_valid) begin
            for(lane=0;lane<4;lane=lane+1) begin
                if(awb_data[95-lane*24 -:24]!==expected_rgb(awb_pixels))
                    $fatal(1,"AWB changed source coordinate RGB px=%0d got=%h expected=%h",awb_pixels,awb_data[95-lane*24 -:24],expected_rgb(awb_pixels));
                awb_pixels=awb_pixels+1;
            end
        end
        if(selected_user) begin
            if(capture_frame>=0 && capture_pixels!=PIXELS)
                $fatal(1,"A new SOF truncated selected output: %0d pixels",capture_pixels);
            capture_frame=capture_frame+1;capture_pixels=0;
            edge_pixels=0;colour_pixels=0;
        end
        if(selected_valid) begin
            if(capture_frame<0 || capture_pixels+4>PIXELS)
                $fatal(1,"Selector published data outside complete frame");
            for(lane=0;lane<4;lane=lane+1) begin
                pixel_value=selected_data[95-lane*24 -:24];
                if(^pixel_value===1'bx) $fatal(1,"Unknown vendor-RAM pixel");
                if(capture_frame==0) begin
                    if(selected_mode || pixel_value!==expected_rgb(capture_pixels))
                        $fatal(1,"RGB ring/selector moved source coordinate %0d got=%h expected=%h",capture_pixels,pixel_value,expected_rgb(capture_pixels));
                    colour_pixels=colour_pixels+1;
                end else begin
                    if(!selected_mode || (pixel_value!==24'h000000 && pixel_value!==24'hffffff))
                        $fatal(1,"Edge frame mode/data incoherent");
                    if(pixel_value==24'hffffff) edge_pixels=edge_pixels+1;
                end
                reference_pixels[capture_pixels]=pixel_value;
                capture_pixels=capture_pixels+1;
            end
        end
        if(packed_user) packed_words=0;
        if(packed_valid) packed_words=packed_words+1;
        if(packed_valid && u_video_in.U_w128_d512_fifo.full_flag)
            fifo_full_errors=fifo_full_errors+1;
        if(packed_valid && u_video_in.U_w128_d512_fifo.soft_fifo_al_4057d6b76aa6_Inst.wr_rst)
            fifo_reset_overlaps=fifo_reset_overlaps+1;
    end
end
always @(posedge ddr_clk) begin
    ddr_cycle=ddr_cycle+1;
    if(rst_n && u_video_in.S_frame_start) begin
        ddr_frame=ddr_frame+1;committed_words=0;
        mismatched_words=0;first_mismatch=-1;prefix_index=-1;
    end
    // The real DDR user interface samples these registered signals at this edge.
    if(rst_n && ddr_write) begin
        address_index=(write_address-ddr_frame*1572864)/8;
        if(address_index!=committed_words || address_index<0 || address_index>=WORDS)
            $fatal(1,"Wrong DDR frame address index %0d expected%0d frame%0d addr%0d",address_index,committed_words,ddr_frame,write_address);
        if(committed_words==0 && ddr_frame==0) prefix_index=write_data[127:104];
        if(capture_pixels<(committed_words*16+16+2)/3)
            $fatal(1,"DDR wrote source bytes that have not arrived");
        expected_word=0;
        for(word_byte=0;word_byte<16;word_byte=word_byte+1) begin
            expected_word[127-word_byte*8 -:8]=reference_byte(committed_words*16+word_byte);
            byte_checks=byte_checks+1;
        end
        if(write_data!==expected_word) begin
            mismatched_words=mismatched_words+1;
            if(first_mismatch<0) first_mismatch=committed_words;
            $fatal(1,"DDR byte order/frame prefix mismatch frame%0d word%0d got%h expected%h",ddr_frame,committed_words,write_data,expected_word);
        end
        stored_words[committed_words]=write_data;
        committed_words=committed_words+1;
    end
end
reg [95:0] next_group;
task automatic send_frame(input integer mode_value);
    begin
        @(negedge ddr_clk);snapshot_start=1;
        @(negedge ddr_clk);snapshot_start=0;
        @(negedge camera_clk);edge_mode=mode_value;
        repeat(200)@(negedge camera_clk);
        for(clear_index=0;clear_index<WORDS;clear_index=clear_index+1)
            stored_words[clear_index]=0;
        for(row=0;row<H;row=row+1) begin
            for(group_index=0;group_index<GROUPS;group_index=group_index+1) begin
                @(negedge camera_clk);
                in_user=(row==0 && group_index==0);
                in_valid=1;in_last=(group_index==GROUPS-1);
                for(pixel_lane=0;pixel_lane<4;pixel_lane=pixel_lane+1)
                    next_group[95-pixel_lane*24 -:24]=source_rgb(row*W+group_index*4+pixel_lane);
                in_data=next_group;
            end
            @(negedge camera_clk);in_valid=0;in_user=0;in_last=0;in_data=0;
            // The clearing edge above and these 1404 blank edges produce
            // 1405 idle clocks: 320+1405=1725 source clocks per row.
            // This load cannot overflow the 512-word FIFO.
            repeat(1404)@(negedge camera_clk);
        end
        repeat(3000)@(negedge ddr_clk);
        if(snapshot_busy || snapshot_failed || snapshot_words!=WORDS || snapshot_frames!=mode_value+1)
            $fatal(1,"real camera did not produce complete snapshot got=%0d expected=%0d frames=%0d failed=%0d",snapshot_words,WORDS,snapshot_frames,snapshot_failed);
        $display("RESNET18_CAMERA_SNAPSHOT_PASS H=%0d mode=%0d beats=%0d",H,mode_value,snapshot_words);
        if(capture_pixels!=PIXELS || packed_words!=WORDS || awb_pixels!=PIXELS || fifo_full_errors!=0)
            $fatal(1,"Incomplete upstream frame/capture/packer or FIFO overflow");
        if(mode_value==1 && (edge_pixels==0 || edge_pixels>=PIXELS))
            $fatal(1,"Edge reference lacks both black and white output pixels");
        begin
            if(committed_words!=WORDS || mismatched_words!=0 || fifo_reset_overlaps!=0)
                $fatal(1,"Guarded stream was truncated or overlapped reset");
            frames_passed=frames_passed+1;
            $display("FIFO_FRAME_INTEGRITY_FRAME_PASS mode=%0d phase=%0.3f pixels=%0d words=%0d byte_checks=%0d edge_pixels=%0d reset_overlap=%0d",mode_value,DDR_PHASE,capture_pixels,committed_words,byte_checks,edge_pixels,fifo_reset_overlaps);
        end
        if(export_enabled && H==720) begin
            if(mode_value==0) begin
                $writememh({export_root,"/ddr_color.memh"},stored_words);
                $writememh({export_root,"/reference_color.memh"},reference_pixels);
            end else begin
                $writememh({export_root,"/ddr_edge.memh"},stored_words);
                $writememh({export_root,"/reference_edge.memh"},reference_pixels);
            end
        end
    end
endtask
initial begin
    export_enabled=$value$plusargs("EXPORT=%s",export_root);
    repeat(100)@(negedge camera_clk);rst_n=1;
    repeat(100)@(negedge camera_clk);
    send_frame(0);send_frame(1);
    if(frames_passed!=2) $fatal(1,"Missing complete frame coverage");
    $display("FIFO_FRAME_INTEGRITY_PASS H=%0d phase=%0.3f frames=%0d bytes=%0d",H,DDR_PHASE,frames_passed,byte_checks);
    if(RAW_SOURCE) $display("RAW_TO_DDR_FRAME_PASS pixels=%0d",PIXELS*frames_passed);
    $finish;
end
initial begin #150000000;$fatal(1,"Pixel-chain integrity test timeout");end
endmodule


// Independent reader: consumes the actual writer DDR dump and the RGB
// reference captured before packing. It checks every active display pixel,
// including pixels that cross a 128-bit word boundary and both side borders.
`timescale 1ns/1ps
module tb_video_fifo_frame_reader;
  localparam W=1280, H=720, LINE_TOTAL=1650, WORDS=(W*H*3)/16;
  reg ddr_clk=0, pixel_clk=0;
  always #7.5 ddr_clk=~ddr_clk;
  // 75.002 MHz report: 13.333 ns period; split halves avoid 1ps rounding bias.
  always begin #6.666 pixel_clk=~pixel_clk; #6.667 pixel_clk=~pixel_clk; end
  reg rst_n=0, frame_vsync=0, rd_en=0, hold_read=1;
  reg [1:0] slot=0;
  wire [1:0] display_slot;
  wire read_busy, read_cmd;
  wire [24:0] read_addr;
  reg rd_data_valid=0; reg [127:0] rd_data=0;
  wire [23:0] pixel;
  integer ddr_cycles=0, stress=0, request_index=0;
  wire ready=(!stress || ((ddr_cycles%13)!=0));
  wire writer_busy=hold_read || (stress && ((ddr_cycles%1024)<200));
  video_out #(.FRAME_STRIDE_NATIVE(1572864)) dut(.I_rst_n(rst_n), .I_ddr_clk(ddr_clk),
    .O_video_out_rd_busy(read_busy), .I_video_in_wr_busy(writer_busy),
    .I_video_out_rp(slot), .O_read_frame_slot(display_slot),
    .O_ddr_user_rd_en(read_cmd), .O_ddr_user_addr(read_addr),
    .I_ddr_user_ready(ready), .I_ddr_user_rd_valid(rd_data_valid), .I_ddr_user_rd_data(rd_data),
    .I_dsi_clk(pixel_clk), .I_video_vsync(frame_vsync), .I_video_rd_en(rd_en), .O_vdieo_data(pixel));
  reg [39:0] valid_pipeline=0;
  reg [24:0] addr_pipeline[0:39];
  integer c, cmds=0, returns=0, bursts=0, burst_words=0, badbursts=0;
  reg [127:0] external_mem[0:WORDS-1];
  reg use_external=0,use_reference=0; reg [2047:0] mem_path,reference_path; reg [23:0] reference_mem[0:W*H-1]; integer frame_limit=2;
  function [23:0] expected_pixel;
    input integer pix_index;
    input integer frame_slot;
    begin
      if(use_reference && pix_index<W*H)expected_pixel=reference_mem[pix_index];
      else expected_pixel=24'h200000+frame_slot*24'h100000+pix_index;
    end
  endfunction
  function [127:0] word_at_addr;
    input [24:0] addr;
    integer frame_slot,word_index,b,byte_index,pix_index,channel;
    reg [23:0] pix; reg [127:0] packed_word;
    begin
      frame_slot=addr/1572864;
      word_index=(addr-frame_slot*1572864)/8;
      packed_word=0;
      if(use_external && word_index<WORDS) packed_word=external_mem[word_index];
      else begin
        for(b=0;b<16;b=b+1)begin
          byte_index=word_index*16+b;
          pix_index=byte_index/3;
          channel=byte_index%3;
          pix=expected_pixel(pix_index,frame_slot);
          packed_word[127-b*8 -: 8]=pix >> ((2-channel)*8);
        end
      end
      word_at_addr=packed_word;
    end
  endfunction
  always @(posedge ddr_clk) begin
    ddr_cycles=ddr_cycles+1;
    if(!rst_n)begin valid_pipeline<=0;rd_data_valid<=0;rd_data<=0;end
    else begin
      valid_pipeline<={valid_pipeline[38:0],read_cmd};
      addr_pipeline[0]<=read_addr;
      for(c=1;c<40;c=c+1)addr_pipeline[c]<=addr_pipeline[c-1];
      rd_data_valid<=valid_pipeline[39];
      if(valid_pipeline[39])begin rd_data<=word_at_addr(addr_pipeline[39]);returns=returns+1;end
      if(read_cmd)begin
        cmds=cmds+1;burst_words=burst_words+1;
        if(dut.S_ddr_rd_cnt==239)begin
          bursts=bursts+1;
          if(burst_words!=240)begin badbursts=badbursts+1;$display("BAD_BURST words=%0d",burst_words);end
          burst_words=0;
        end
      end
    end
  end
  integer checked=0, errors=0, underflows=0, overflows=0, edge_checks=0, checked_frame=0;
  integer previous_index=0, previous_slot=0, compare_index=0,compare_slot=0;
  reg previous_valid=0, compare_valid=0;
  reg [23:0] expected;
  integer x,y,f,j;
  always @(posedge ddr_clk) begin
    if(rst_n && rd_data_valid && !dut.S_fifo_rst && dut.U_w128_d512_fifo.full_flag)begin
      overflows=overflows+1;
      if(overflows<5)$display("FIFO_FULL ddr_cycle=%0d",ddr_cycles);
    end
  end
  always @(posedge pixel_clk) begin
    compare_valid=previous_valid;compare_index=previous_index;compare_slot=previous_slot;
    previous_valid=rd_en;previous_index=request_index;previous_slot=slot;
    if(rst_n && dut.S_fifo_rd_en && dut.S_fifo_emtpy)begin
      underflows=underflows+1;
      if(underflows<5)$display("FIFO_EMPTY pixel=%0d",request_index);
    end
    #1;
    if(compare_valid)begin
      checked=checked+1;
      if((compare_index%W)<16 || (compare_index%W)>=W-16)edge_checks=edge_checks+1;
      expected=expected_pixel(compare_index,compare_slot);
      if(^pixel===1'bx || ^expected===1'bx)
        $fatal(1,"Unknown reader pixel/reference slot=%0d index=%0d pixel=%h expected=%h",compare_slot,compare_index,pixel,expected);
      if(pixel !== expected)begin
        errors=errors+1;
        if(errors<30)$display("PIXEL_BAD slot=%0d y=%0d x=%0d got=%h expected=%h idxdiff=%0d fifo_used=%0d",compare_slot,compare_index/W,compare_index%W,pixel,expected,$signed({1'b0,pixel})-$signed({1'b0,expected}),dut.S_fifo_wr_num);
      end
      if((compare_index/W)==0 && ((compare_index%W)<7 || (compare_index%W)>W-8))
        $display("PIXEL_TRACE slot=%0d y=%0d x=%0d data=%h expected=%h",compare_slot,compare_index/W,compare_index%W,pixel,expected);
      if(compare_index==W*H-1)begin
        checked_frame=checked_frame+1;
        $display("FRAME_DONE slot=%0d pixels=%0d errors=%0d underflows=%0d",compare_slot,W*H,errors,underflows);
      end
    end
  end
  task blank_cycles;
    input integer count;
    integer k;
    begin
      // count includes this first idle edge, keeping each row at 1650 clocks.
      @(negedge pixel_clk);rd_en=0;
      for(k=1;k<count;k=k+1)@(negedge pixel_clk);
    end
  endtask
  initial begin
    if($test$plusargs("STRESS"))stress=1;
    if($value$plusargs("MEM=%s",mem_path))begin use_external=1;$readmemh(mem_path,external_mem);end
    if($value$plusargs("REF=%s",reference_path))begin use_reference=1;$readmemh(reference_path,reference_mem);end
    if(use_external!=use_reference)
      $fatal(1,"Reader needs both independent +MEM and +REF, or neither for synthetic stress");
    if($value$plusargs("FRAMES=%d",frame_limit))begin end
    repeat(100)@(negedge pixel_clk);
    rst_n=1;
    for(f=0;f<frame_limit;f=f+1)begin
      slot=f;
      frame_vsync=1;
      blank_cycles(LINE_TOTAL*5);
      frame_vsync=0;hold_read=0;
      blank_cycles(LINE_TOTAL*20);
      for(y=0;y<H;y=y+1)begin
        for(x=0;x<W;x=x+1)begin
          @(negedge pixel_clk);request_index=y*W+x;rd_en=1;
        end
        blank_cycles(LINE_TOTAL-W);
      end
      blank_cycles(LINE_TOTAL*5);
    end
    hold_read=1;blank_cycles(5000);
    $display("VIDEO_OUT_FINAL frames=%0d pixels=%0d edgepixels=%0d errors=%0d underflows=%0d overflows=%0d cmds=%0d returns=%0d bursts=%0d badbursts=%0d stress=%0d",checked_frame,checked,edge_checks,errors,underflows,overflows,cmds,returns,bursts,badbursts,stress);
    if(errors || underflows || overflows || badbursts || checked!=frame_limit*W*H || checked_frame!=frame_limit)$fatal(1,"video_out regression failed");
    $display("FIFO_FRAME_READER_PASS frames=%0d pixels=%0d side_pixels=%0d errors=%0d underflows=%0d overflows=%0d",checked_frame,checked,edge_checks,errors,underflows,overflows);
    $finish;
  end
  initial begin #50000000;$fatal(1,"timeout");end
endmodule



