`timescale 1ns/1ps
module flash_test_device #(parameter integer SIZE=512)(
    input wire cs_n,sck,mosi,output reg miso=1,
    input wire [23:0] device_id,input wire protect
);
    reg [7:0] memory[0:SIZE-1];
    reg [7:0] shift=0,command=0,output_byte=8'hff;
    integer bits=0,bytes=0,read_bits=0,address=0,program_count=0,write_commands=0;
    reg write_enable=0;
    reg [23:0] address_shift=0;
    reg [7:0] incoming;
    always @(negedge cs_n) begin
        bits=0;bytes=0;read_bits=0;shift=0;command=0;address_shift=0;
        output_byte=8'hff;miso=1;program_count=0;
    end
    always @(posedge sck) if(!cs_n) begin
        incoming={shift[6:0],mosi};shift=incoming;bits=bits+1;
        if(bits==8) begin
            bits=0;
            if(bytes==0) begin
                command=incoming;
                if(command==8'h06 && !protect) write_enable=1;
                if(command==8'h02) write_commands=write_commands+1;
                if(command!=8'h03 && command!=8'h9f && command!=8'h05 && command!=8'h06 && command!=8'h02)
                    $fatal(1,"Unexpected Flash command %h",command);
            end else if((command==8'h03 || command==8'h02) && bytes<=3) begin
                address_shift={address_shift[15:0],incoming};
                if(bytes==3) begin
                    if(address_shift<24'hf00000 || address_shift>=24'hf00000+SIZE)
                        $fatal(1,"Out of range Flash access %h",address_shift);
                    address=address_shift-24'hf00000;
                end
            end else if(command==8'h02 && bytes>=4) begin
                if(!write_enable || protect) $fatal(1,"Program without WEL");
                if(address>=SIZE || program_count>=256) $fatal(1,"Program range/page overflow");
                memory[address]=memory[address]&incoming;address=address+1;program_count=program_count+1;
            end
            bytes=bytes+1;
        end
    end
    always @(negedge sck) if(!cs_n) begin
        if(bytes>=1 && command==8'h9f) begin
            case(bytes) 1:output_byte=device_id[23:16];2:output_byte=device_id[15:8];default:output_byte=device_id[7:0];endcase
        end else if(bytes>=1 && command==8'h05) output_byte={6'd0,write_enable,1'b0};
        else if(bytes>=4 && command==8'h03) begin
            if(bits==0 && bytes>4) address=address+1;
            output_byte=address<SIZE ? memory[address] : 8'hff;
        end else output_byte=8'hff;
        miso=output_byte[7-bits];
    end
    always @(posedge cs_n) if(command==8'h02) write_enable=0;
endmodule

module tb_fruit_flash;
    localparam SIZE=512;
    reg clk=0;
    always #5 clk=~clk;
    reg programmer_reset=0,boot_reset=0,protect=0,calibrated=0,corrupt_ddr=0;
    reg [23:0] jedec=24'h20ba18;
    wire p_cs,p_sck,p_mosi,p_done;
    wire b_cs,b_sck,b_mosi,model_ready;
    wire [7:0] error;
    wire [17:0] rom_address;
    reg [7:0] rom_data;
    reg [7:0] model[0:SIZE-1];
    reg [31:0] model_crc;
    wire miso;
    wire [255:0] p_status,b_status;
    wire mem_valid,mem_write;
    wire [31:0] mem_addr;
    wire [127:0] mem_data;
    reg mem_ready=0,rsp_valid=0;
    reg [127:0] rsp_data;
    reg [127:0] ddr[0:SIZE/16-1];
    integer cycle=0,reads=0,writes=0;
    wire cs=boot_reset ? b_cs : p_cs;
    wire sck=boot_reset ? b_sck : p_sck;
    wire mosi=boot_reset ? b_mosi : p_mosi;
    flash_test_device #(.SIZE(SIZE)) flash(.cs_n(cs),.sck(sck),.mosi(mosi),.miso(miso),.device_id(jedec),.protect(protect));
    fruit_flash_programmer #(.MODEL_BYTES(SIZE),.HALF_PERIOD(4),.POWERUP_CYCLES(3)) programmer(
        .clk(clk),.rst_n(programmer_reset),.rom_address(rom_address),.rom_data(rom_data),
        .cs_n(p_cs),.sck(p_sck),.mosi(p_mosi),.miso(miso),.diagnostics(p_status),.finished(p_done),.error_code(error));
    always @(posedge clk) rom_data<=rom_address<SIZE ? model[rom_address] : 8'hff;
    fruit_flash_boot #(.HALF_PERIOD(4),.TIMEOUT_CYCLES(10000)) boot(
        .clk(clk),.rst_n(boot_reset),.calibrated(calibrated),.memory_error(1'b0),
        .model_base(32'h00c00000),.model_bytes(SIZE),.model_crc32(model_crc),.model_ready(model_ready),
        .mem_valid(mem_valid),.mem_write(mem_write),.mem_addr(mem_addr),.mem_data(mem_data),
        .mem_ready(mem_ready),.mem_rsp_valid(rsp_valid),.mem_rsp_data(rsp_data),
        .flash_cs_n(b_cs),.flash_sck(b_sck),.flash_mosi(b_mosi),.flash_miso(miso),.diagnostics(b_status));
    always @(posedge clk) begin
        cycle<=cycle+1;mem_ready<=cycle%7==0;rsp_valid<=0;
        if(boot_reset && mem_valid && mem_ready) begin
            if(mem_addr<32'h00c00000 || mem_addr>=32'h00c00000+SIZE || mem_addr[3:0]!=0)
                $fatal(1,"DDR range error");
            if(mem_write) begin ddr[(mem_addr-32'h00c00000)/16]<=mem_data;writes<=writes+1;end
            else begin
                rsp_valid<=1;rsp_data<=ddr[(mem_addr-32'h00c00000)/16]^{127'd0,corrupt_ddr};reads<=reads+1;
            end
        end
    end
    function [31:0] crc_byte(input [31:0] old,input [7:0] value);
        reg [31:0] c;integer b;
        begin c=old^value;for(b=0;b<8;b=b+1)c=(c>>1)^(c[0]?32'hedb88320:0);crc_byte=c;end
    endfunction
    task reset_programmer;
        begin boot_reset=0;programmer_reset=0;repeat(10) @(negedge clk);programmer_reset=1;end
    endtask
    task await_programmer;
        integer n;
        begin n=0;while(!p_done && error==0 && n<200000)begin @(negedge clk);n=n+1;end
        if(n==200000)$fatal(1,"Programmer hung");end
    endtask
    task reset_boot;
        begin programmer_reset=0;boot_reset=0;calibrated=0;repeat(10)@(negedge clk);
        boot_reset=1;repeat(20)@(negedge clk);if(!b_cs)$fatal(1,"Flash started before DDR calibrated");calibrated=1;end
    endtask
    task await_boot;
        integer n;
        begin n=0;while(!model_ready && b_status[55:48]==0 && n<100000)begin @(negedge clk);n=n+1;end
        if(n==100000)$fatal(1,"Boot hung");end
    endtask
    integer i,old_writes;
    initial begin
        model_crc=32'hffffffff;
        for(i=0;i<SIZE;i=i+1)begin model[i]=(i*37+i/7)&255;flash.memory[i]=8'hff;model_crc=crc_byte(model_crc,model[i]);end
        model_crc=~model_crc;
        reset_programmer();await_programmer();
        if(!p_done)$fatal(1,"Blank programming failed error=%d",error);
        for(i=0;i<SIZE;i=i+1)if(flash.memory[i]!=model[i])$fatal(1,"Readback mismatch %d",i);
        old_writes=flash.write_commands;reset_programmer();await_programmer();
        if(!p_done || flash.write_commands!=old_writes)$fatal(1,"Idempotent load failed");
        reset_boot();await_boot();
        if(!model_ready || reads!=SIZE/16 || writes!=SIZE/16)$fatal(1,"DDR verify failed %h",b_status);
        if(b_status[127:96]!=model_crc || b_status[159:128]!=model_crc)$fatal(1,"CRC report incorrect");
        corrupt_ddr=1;reset_boot();await_boot();
        if(model_ready || b_status[55:48]!=2)$fatal(1,"Corrupt DDR was accepted");
        corrupt_ddr=0;flash.memory[17]=flash.memory[17]^1;reset_boot();await_boot();
        if(model_ready || b_status[55:48]!=1)$fatal(1,"Corrupt Flash was accepted");
        reset_programmer();await_programmer();
        if(error!=2 || flash.write_commands!=old_writes)$fatal(1,"Nonblank overwrite not blocked");
        jedec=24'hffffff;reset_programmer();await_programmer();
        if(error!=1)$fatal(1,"Wrong device accepted");
        jedec=24'h20ba18;protect=1;
        for(i=0;i<SIZE;i=i+1)flash.memory[i]=8'hff;
        reset_programmer();await_programmer();if(error!=3)$fatal(1,"Protection was ignored");
        $display("FRUIT_FLASH_TEST_PASS blank_program exact_readback idempotent preserve_nonblank wrong_id write_protect boot_crc ddr_crc backpressure");
        $finish;
    end
endmodule
