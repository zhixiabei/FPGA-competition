`timescale 1ns/1ps
module tb_osd_char_rom_equivalence;
    reg clk=0;
    always #5 clk=~clk;
    reg [7:0] code=0;
    reg [3:0] row=0;
    wire [15:0] old_bits,new_bits;
    reg [15:0] expected=0,previous=0;
    integer c,r,pass,checks=0,hold_checks=0,nonblank=0;
    integer lowercase_g_rows=0,lowercase_k_rows=0,unknown_checks=0;
    reg have_previous=0;
    function automatic supported_code(input [7:0] character);
        supported_code =
            (character>=8'h41 && character<=8'h5a) ||
            (character>=8'h30 && character<=8'h3a) ||
            (character>=8'h80 && character<=8'h8b) ||
            character==8'h2e || character==8'h2d || character==8'h2f ||
            character==8'h67 || character==8'h6b;
    endfunction
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
                    if(!supported_code(code)) begin
                        unknown_checks=unknown_checks+1;
                        if(expected !== 16'd0)
                            $fatal(1,"Unknown font code has pixels code=%h row=%0d bits=%h",
                                code,row,expected);
                    end
                    @(posedge clk);
                    #1;
                    checks=checks+1;
                    if(new_bits !== expected)
                        $fatal(1,"Font ROM mismatch code=%h row=%0d got=%h expected=%h",
                            code,row,new_bits,expected);
                    if(new_bits!=0) nonblank=nonblank+1;
                    if(code==8'h67 && new_bits!=0)
                        lowercase_g_rows=lowercase_g_rows+1;
                    if(code==8'h6b && new_bits!=0)
                        lowercase_k_rows=lowercase_k_rows+1;
                    previous=new_bits;have_previous=1;
                end
            end
        end
        if(checks!=8192 || hold_checks!=8191 || nonblank==0 ||
           lowercase_g_rows==0 || lowercase_k_rows==0 || unknown_checks!=6464)
            $fatal(1,"Incomplete font coverage checks=%0d holds=%0d nonblank=%0d g=%0d k=%0d unknown=%0d",
                checks,hold_checks,nonblank,lowercase_g_rows,lowercase_k_rows,unknown_checks);
        $display("OSD_CHAR_ROM_EQUIVALENCE_PASS characters=256 rows=16 checks=%0d holds=%0d nonblank=%0d g_rows=%0d k_rows=%0d unknown_checks=%0d",
            checks,hold_checks,nonblank,lowercase_g_rows,lowercase_k_rows,unknown_checks);
        $finish;
    end
    initial begin #100000;$fatal(1,"Font ROM equivalence timeout");end
endmodule
