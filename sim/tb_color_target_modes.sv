`timescale 1ns/1ps
module tb_color_target_modes;
    localparam integer W=32, H=24, GROUPS=W/4;
    reg clk=0, rst_n=0, user=0, valid=0;
    reg [1:0] color_mode=0;
    reg [95:0] data=0;
    reg [9:0] frame_id=0;
    wire ready, found;
    wire [11:0] xmin,xmax,ymin,ymax;
    integer checks=0;
    always #5 clk=~clk;

    red_target_detect_96 #(
        .IMG_WIDTH(W),.IMG_HEIGHT(H),.RED_MIN(24),.RED_DELTA(6),
        .MIN_PIXELS(32),.MIN_WIDTH(4),.MIN_HEIGHT(4),.MULTI_ENABLE(0)
    ) dut (
        .I_clk(clk),.I_rst_n(rst_n),.I_tuser(user),.I_tvalid(valid),
        .I_tdata(data),.I_color_mode(color_mode),
        .O_result_ready(ready),.O_found(found),
        .O_xmin(xmin),.O_xmax(xmax),.O_ymin(ymin),.O_ymax(ymax),
        .O_center_x(),.O_center_y(),.O_pixels(),.O_frame_toggle(),
        .I_frame_id(frame_id),.I_multi_clear(1'b0),
        .O_multi_ready(),.O_multi_valid(),.O_multi_hold(),.O_multi_boxes(),
        .O_multi_frame_id(),.O_multi_overflow()
    );

    function automatic [23:0] pixel_at;
        input integer x,y;
        input [23:0] foreground;
        begin
            pixel_at=(x>=8 && x<=19 && y>=6 && y<=17) ? foreground : 24'h101010;
        end
    endfunction

    task automatic send_case;
        input [1:0] selected;
        input [23:0] foreground;
        input expected_found;
        integer x,y;
        begin
            color_mode=selected;
            for (y=0;y<H;y=y+1) begin
                for (x=0;x<W;x=x+4) begin
                    @(negedge clk);
                    valid=1;
                    user=(x==0 && y==0);
                    data={pixel_at(x,y,foreground),pixel_at(x+1,y,foreground),
                          pixel_at(x+2,y,foreground),pixel_at(x+3,y,foreground)};
                end
            end
            @(negedge clk); valid=0; user=0; data=0;
            wait (ready===1'b1);
            #1;
            if (found!==expected_found)
                $fatal(1,"mode=%0d foreground=%h expected found=%0d got=%b",
                       selected,foreground,expected_found,found);
            if (expected_found && (xmin>8 || xmax<19 || ymin>6 || ymax<17))
                $fatal(1,"mode=%0d unexpected box %0d,%0d..%0d,%0d",
                       selected,xmin,ymin,xmax,ymax);
            checks=checks+1;
            frame_id=frame_id+1'b1;
            repeat (8) @(negedge clk);
        end
    endtask

    initial begin
        repeat (5) @(negedge clk); rst_n=1;
        send_case(2'd0,24'hf02020,1'b1);
        send_case(2'd0,24'h20f020,1'b0);
        send_case(2'd1,24'h20f020,1'b1);
        send_case(2'd1,24'h2020f0,1'b0);
        send_case(2'd2,24'h2020f0,1'b1);
        send_case(2'd2,24'hf02020,1'b0);
        $display("COLOR_TARGET_MODES_PASS checks=%0d modes=RED,GRN,BLU",checks);
        $finish;
    end
    initial begin #2000000; $fatal(1,"Color mode test timeout"); end
endmodule
