`timescale 1ns/1ps
// Start requests immediately after reset, without the old hold_read delay.
// Use the real command/display FIFOs; the memory responder is a test model.
module tb_video_startup_reset;
    reg clk=0,pclk=0;
    always #7.5 clk=~clk;
    always begin #6.666 pclk=~pclk;#6.667 pclk=~pclk;end
    reg rst_n=0,manual=1,request=0,controller_ready=1;
    reg vsync=0,pixels=0,hold_read=0;
    wire user_ready,video_read,read_busy,response;
    wire [24:0] video_address;
    wire [23:0] pixel;
    wire [127:0] response_data;
    integer sent=0,forwarded=0,returned=0,checked=0,errors=0,index=0;
    wire user_read=manual ? (request && user_ready) : video_read;
    wire [24:0] user_address=manual ? sent*8 : video_address;
    wire command;
    wire [24:0] command_address;
    wire [2:0] command_kind;
    reg [7:0] response_pipe=0;
    reg [127:0] data_pipe[0:7];
    integer k;
    assign response=response_pipe[7];
    assign response_data=data_pipe[7];

    video_out video(.I_rst_n(rst_n),.I_ddr_clk(clk),
        .O_video_out_rd_busy(read_busy),.I_video_in_wr_busy(hold_read || manual),
        .I_video_out_rp(2'd0),.O_read_frame_slot(),.O_read_frame_start(),
        .O_ddr_user_rd_en(video_read),.O_ddr_user_addr(video_address),
        .I_ddr_user_ready(user_ready),.I_ddr_user_rd_valid(response && !manual),
        .I_ddr_user_rd_data(response_data),.I_dsi_clk(pclk),
        .I_video_vsync(vsync),.I_video_rd_en(pixels),.O_vdieo_data(pixel));
    mc_to_user_interface commands(.I_clk(clk),.I_rst_n(rst_n),
        .I_ddr_user_wr_en(1'b0),.I_ddr_user_rd_en(user_read),
        .I_ddr_user_addr(user_address),.I_ddr_user_wr_data(128'd0),
        .O_ddr_user_ready(user_ready),.O_ddr_user_rd_valid(),.O_ddr_user_rd_data(),
        .O_mc_app_en(command),.O_mc_app_addr(command_address),.O_mc_app_cmd(command_kind),
        .I_mc_app_rdy(controller_ready),.O_mc_app_wdf_wren(),.O_mc_app_wdf_data(),
        .O_mc_app_wdf_end(),.O_mc_app_wdf_mask(),.I_mc_app_wdf_rdy(controller_ready),
        .I_mc_app_rd_data(response_data),.I_mc_app_rd_data_end(response),
        .I_mc_app_rd_data_valid(response));

    function [127:0] encoded_word(input [24:0] address);
        integer b,byte_index;
        reg [23:0] color;
        begin
            encoded_word=0;
            for(b=0;b<16;b=b+1) begin
                byte_index=address*2+b;
                color=24'h200000+byte_index/3;
                encoded_word[127-b*8 -:8]=color >> ((2-byte_index%3)*8);
            end
        end
    endfunction

    always @(posedge clk) begin
        if(!rst_n) begin
            sent=0;forwarded=0;returned=0;response_pipe<=0;
        end else begin
            if(user_ready && commands.U_w155_d512_fifo.soft_fifo_al_f58e8b3e1f3d_Inst.asy_rst)
                $fatal(1,"ready advertised while command FIFO pointers are still reset");
            if(user_read) sent=sent+1;
            if(command) begin
                if(command_kind!==3'd1 || command_address!==forwarded*8)
                    $fatal(1,"lost/duplicated startup command index=%0d address=%h",forwarded,command_address);
                forwarded=forwarded+1;
            end
            if(response) returned=returned+1;
            response_pipe<={response_pipe[6:0],command};
            data_pipe[0]<=encoded_word(command_address);
            for(k=1;k<8;k=k+1) data_pipe[k]<=data_pipe[k-1];
            #1;
            if(!manual && video.S_pending_reads!==sent-returned)
                $fatal(1,"video pending count differs from accepted minus returned requests");
        end
    end

    reg previous_valid=0;
    integer previous_index=0;
    always @(posedge pclk) begin
        if(!rst_n) previous_valid=0;
        else begin
            if(video.S_fifo_rd_en && video.S_fifo_emtpy)
                $fatal(1,"startup display underflow");
            // video_out's pixel register has one full clock of latency.
            if(previous_valid) begin
                #1;
                checked=checked+1;
                if(pixel!==24'h200000+previous_index) errors=errors+1;
            end else #1;
            previous_valid=pixels;
            previous_index=index;
        end
    end

    initial begin
        repeat(100) @(negedge clk);
        rst_n=1;request=1;
        wait(sent==256);
        @(negedge clk);request=0;
        wait(returned==256);
        if(forwarded!=sent) $fatal(1,"startup requests were discarded");
        $display("COMMAND_FIFO_STARTUP_PASS accepted=%0d returned=%0d",sent,returned);

        // Repeat with the display active and controller acceptance delayed.
        // No hold_read is asserted after reset; SOF must arm the reader.
        @(negedge clk);rst_n=0;manual=0;controller_ready=0;
        repeat(20) @(negedge clk);
        rst_n=1;
        repeat(100) @(negedge clk);
        if(sent!=0 || video.S_fifo_rst!==1'b1)
            $fatal(1,"display started before its first frame boundary");
        vsync=1;
        repeat(20) @(negedge clk);
        vsync=0;
        repeat(100) @(negedge clk);
        controller_ready=1;
        repeat(1000) @(negedge clk);
        if(returned==0 || video.S_fifo_rst!==1'b0)
            $fatal(1,"display stuck in reset after startup");
        for(integer x=0;x<1280;x=x+1) begin
            @(negedge pclk);pixels=1;index=x;
        end
        @(negedge pclk);pixels=0;hold_read=1;
        repeat(1000) @(negedge clk);
        if(checked!=1280 || errors || video.S_pending_reads!=0 || sent!=returned)
            $fatal(1,"startup recovery failed checked=%0d errors=%0d pending=%0d",checked,errors,video.S_pending_reads);
        $display("VIDEO_STARTUP_RESET_PASS pixels=%0d accepted=%0d returned=%0d",checked,sent,returned);
        $finish;
    end
    initial begin #1000000;$fatal(1,"startup reset deadlock");end
endmodule
