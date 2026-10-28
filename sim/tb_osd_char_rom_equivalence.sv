`timescale 1ns/1ps
module tb_osd_char_rom_equivalence;
    reg clk=0;
    always #5 clk=~clk;
    reg [7:0] code=0;
    reg [3:0] row=0;
    wire [15:0] old_bits,new_bits;
    reg [15:0] expected=0,previous=0;
    integer c,r,pass,checks=0,hold_checks=0,nonblank=0;
    reg have_previous=0;
    osd_char_lib reference(.I_char(code),.I_row(row),.O_row_bits(old_bits));
    osd_char_rom_sync dut(.I_clk(clk),.I_char(code),.I_row(row),.O_row_bits(new_bits));
    initial begin
        // Forward and reverse requests catch both glyph/address errors and
        // combinational feedthrough instead of a one-edge synchronous read.
        for(pass=0;pass<2;pass=pass+1) begin
            for(c=0;c<256;c=c+1) begin
                for(r=0;r<16;r=r+1) begin
                    @(negedge clk);
                    code=pass==0 ? 8'(c) : 8'(255-c);
                    row=pass==0 ? 4'(r) : 4'(15-r);
                    #1;
                    if(have_previous) begin
                        hold_checks=hold_checks+1;
                        if(new_bits !== previous)
                            $fatal(1,"Font changed before read edge code=%h row=%0d got=%h previous=%h",
                                code,row,new_bits,previous);
                    end
                    expected=old_bits;
                    @(posedge clk);
                    #1;
                    checks=checks+1;
                    if(new_bits !== expected)
                        $fatal(1,"Font ROM mismatch code=%h row=%0d got=%h expected=%h",
                            code,row,new_bits,expected);
                    if(new_bits!=0) nonblank=nonblank+1;
                    previous=new_bits;have_previous=1;
                end
            end
        end
        if(checks!=8192 || hold_checks!=8191 || nonblank==0)
            $fatal(1,"Incomplete font coverage checks=%0d holds=%0d nonblank=%0d",
                checks,hold_checks,nonblank);
        $display("OSD_CHAR_ROM_EQUIVALENCE_PASS characters=256 rows=16 checks=%0d holds=%0d nonblank=%0d",
            checks,hold_checks,nonblank);
        $finish;
    end
    initial begin #100000;$fatal(1,"Font ROM equivalence timeout");end
endmodule
