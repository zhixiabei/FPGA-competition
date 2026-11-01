`timescale 1ns/1ps
// Real DDR reader and asynchronous FIFO; synthetic memory is byte-addressed independently.
module tb_video_out_mirror;
  parameter integer FRAME_STRIDE=1572864;
  localparam W=1280, H=720, LINE_TOTAL=1650, WORDS=(W*H*3)/16;
  reg ddr_clk=0, pixel_clk=0;
  always #7.5 ddr_clk=~ddr_clk;
  // 75.002 MHz report: 13.333 ns period; split halves avoid 1ps rounding bias.
  always begin #6.666 pixel_clk=~pixel_clk; #6.667 pixel_clk=~pixel_clk; end
  reg rst_n=0, frame_vsync=0, rd_en=0, hold_read=1;
  reg [1:0] slot=0;
  reg mirror_request=0, frame_mirror=0;
  integer address_checks=0, accepted=0, expected_address;
  wire [1:0] display_slot;
  wire read_busy, read_cmd;
  wire [24:0] read_addr;
  reg rd_data_valid=0; reg [127:0] rd_data=0;
  wire [23:0] pixel;
  integer ddr_cycles=0, stress=1, request_index=0;
  wire ready=(!stress || ((ddr_cycles%13)!=0));
  wire writer_busy=hold_read || (stress && ((ddr_cycles%1024)<200));
  video_out #(.FRAME_STRIDE_NATIVE(FRAME_STRIDE),.MIRROR_ENABLE(1)) dut(.I_rst_n(rst_n), .I_ddr_clk(ddr_clk),
    .O_video_out_rd_busy(read_busy), .I_video_in_wr_busy(writer_busy),
    .I_video_out_rp(slot), .I_mirror(mirror_request), .O_read_frame_slot(display_slot),
    .O_ddr_user_rd_en(read_cmd), .O_ddr_user_addr(read_addr),
    .I_ddr_user_ready(ready), .I_ddr_user_rd_valid(rd_data_valid), .I_ddr_user_rd_data(rd_data),
    .I_dsi_clk(pixel_clk), .I_video_vsync(frame_vsync), .I_video_rd_en(rd_en), .O_vdieo_data(pixel));
  reg [39:0] valid_pipeline=0;
  reg [24:0] addr_pipeline[0:39];
  integer c, cmds=0, returns=0, bursts=0, burst_words=0, badbursts=0;
  reg [127:0] external_mem[0:WORDS-1];
  reg use_external=0,use_reference=0; reg [2047:0] mem_path,reference_path; reg [23:0] reference_mem[0:W*H-1]; integer frame_limit=4;
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
      frame_slot=addr/FRAME_STRIDE;
      word_index=(addr-frame_slot*FRAME_STRIDE)/8;
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
      if(dut.S_video_frame_start) begin
        accepted=0;frame_mirror=mirror_request;
      end
      if(read_cmd)begin
        expected_address=slot*FRAME_STRIDE+(accepted/240)*1920+
            (frame_mirror ? 239-(accepted%240) : accepted%240)*8;
        if(read_addr!==expected_address[24:0])
            $fatal(1,"mirror DDR address %0d expected %0d got %0d",accepted,expected_address,read_addr);
        address_checks++;accepted++;
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
      expected=expected_pixel((compare_index/W)*W+((compare_slot==1 || compare_slot==2) ? W-1-(compare_index%W) : compare_index%W),compare_slot);
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
      slot=f;mirror_request=(f==1 || f==2);
      frame_vsync=1;
      blank_cycles(LINE_TOTAL*5);
      frame_vsync=0;hold_read=0;
      blank_cycles(LINE_TOTAL*20);
      for(y=0;y<H;y=y+1)begin
        for(x=0;x<W;x=x+1)begin
          // A changed request must not turn an already selected frame around.
          if(y==100 && x==W/2)mirror_request=!mirror_request;
          @(negedge pixel_clk);request_index=y*W+x;rd_en=1;
        end
        blank_cycles(LINE_TOTAL-W);
      end
      blank_cycles(LINE_TOTAL*5);
    end
    hold_read=1;blank_cycles(5000);
    $display("VIDEO_OUT_FINAL frames=%0d pixels=%0d edgepixels=%0d errors=%0d underflows=%0d overflows=%0d cmds=%0d returns=%0d bursts=%0d badbursts=%0d stress=%0d",checked_frame,checked,edge_checks,errors,underflows,overflows,cmds,returns,bursts,badbursts,stress);
    if(errors || underflows || overflows || badbursts || checked!=frame_limit*W*H || checked_frame!=frame_limit)$fatal(1,"video_out regression failed");
    $display("VIDEO_OUT_MIRROR_PASS frames=%0d pixels=%0d side_pixels=%0d errors=%0d underflows=%0d overflows=%0d address_checks=%0d midframe_switch=1",checked_frame,checked,edge_checks,errors,underflows,overflows,address_checks);
    $finish;
  end
  initial begin #100000000;$fatal(1,"timeout");end
endmodule
