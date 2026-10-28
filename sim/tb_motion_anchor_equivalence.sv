`timescale 1ns/1ps

module motion_anchor_equivalence_case #(
    parameter integer CASE_ID=0,
    parameter integer WIDTH=1280, HEIGHT=720,
    parameter integer MIN_SUPPORT=8, CONFIRM=3, RELEASE=3,
    parameter integer CENTER_STEP=64, MARGIN=32, DEAD=8
)(output reg done=0);
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, ready=0, found=0, scene=0;
    reg [23:0] support=0, pixels=0;
    reg [11:0] x0=0,x1=0,y0=0,y1=0;
    wire [98:0] actual, reference_value;
    motion_result_stabilizer #(
        .IMG_WIDTH(WIDTH),.IMG_HEIGHT(HEIGHT),.MIN_SUPPORTED_BLOCKS(MIN_SUPPORT),
        .CONFIRM_FRAMES(CONFIRM),.RELEASE_FRAMES(RELEASE),
        .MAX_CENTER_STEP(CENTER_STEP),.SIZE_MARGIN(MARGIN),.DEADBAND(DEAD)
    ) dut(
        .I_clk(clk),.I_rst_n(rst_n),.I_result_ready(ready),.I_found(found),
        .I_scene_change(scene),.I_supported_blocks(support),.I_pixels(pixels),
        .I_xmin(x0),.I_xmax(x1),.I_ymin(y0),.I_ymax(y1),
        .O_result_ready(actual[98]),.O_found(actual[97]),
        .O_xmin(actual[96:85]),.O_xmax(actual[84:73]),
        .O_ymin(actual[72:61]),.O_ymax(actual[60:49]),
        .O_center_x(actual[48:37]),.O_center_y(actual[36:25]),
        .O_pixels(actual[24:1]),.O_frame_toggle(actual[0])
    );
    motion_result_stabilizer_reference #(
        .IMG_WIDTH(WIDTH),.IMG_HEIGHT(HEIGHT),.MIN_SUPPORTED_BLOCKS(MIN_SUPPORT),
        .CONFIRM_FRAMES(CONFIRM),.RELEASE_FRAMES(RELEASE),
        .MAX_CENTER_STEP(CENTER_STEP),.SIZE_MARGIN(MARGIN),.DEADBAND(DEAD)
    ) original(
        .I_clk(clk),.I_rst_n(rst_n),.I_result_ready(ready),.I_found(found),
        .I_scene_change(scene),.I_supported_blocks(support),.I_pixels(pixels),
        .I_xmin(x0),.I_xmax(x1),.I_ymin(y0),.I_ymax(y1),
        .O_result_ready(reference_value[98]),.O_found(reference_value[97]),
        .O_xmin(reference_value[96:85]),.O_xmax(reference_value[84:73]),
        .O_ymin(reference_value[72:61]),.O_ymax(reference_value[60:49]),
        .O_center_x(reference_value[48:37]),.O_center_y(reference_value[36:25]),
        .O_pixels(reference_value[24:1]),.O_frame_toggle(reference_value[0])
    );
    reg [31:0] random_state=32'hac31f257+CASE_ID;
    integer comparisons=0, tokens=0, publications=0, confirmations=0;
    integer associations=0, held=0, resets=0;
    integer i,j,dx,dy,span_w,span_h,bx,by,selector;
    reg last_ready=0;
    reg [12:0] anchor_w,anchor_h,anchor_cx,anchor_cy;
    reg [98:0] previous_payload=0;
    integer prior_active=0;

    function [31:0] random_next;
        input [31:0] value;
        reg [31:0] t;
        begin t=value^(value<<13);t=t^(t>>17);random_next=t^(t<<5);end
    endfunction

    always @(posedge clk) begin
        prior_active=original.active;
        #1;
        if(actual!==reference_value)
            $fatal(1,"Motion differential mismatch case=%0d sample=%0d ready=%b found=%b scene=%b input=%0d,%0d,%0d,%0d actual=%h reference=%h",
                   CASE_ID,comparisons,ready,found,scene,x0,x1,y0,y1,actual,reference_value);
        if({dut.active,dut.confirmations,dut.misses,
            dut.anchor_x0,dut.anchor_x1,dut.anchor_y0,dut.anchor_y1,
            dut.track_x0,dut.track_x1,dut.track_y0,dut.track_y1,dut.track_pixels}
           !==
           {original.active,original.confirmations,original.misses,
            original.anchor_x0,original.anchor_x1,original.anchor_y0,original.anchor_y1,
            original.track_x0,original.track_x1,original.track_y0,original.track_y1,original.track_pixels})
            $fatal(1,"Motion internal track/counters differ case=%0d sample=%0d",CASE_ID,comparisons);
        anchor_w={1'b0,dut.anchor_x1}-{1'b0,dut.anchor_x0}+13'd1;
        anchor_h={1'b0,dut.anchor_y1}-{1'b0,dut.anchor_y0}+13'd1;
        anchor_cx={1'b0,dut.anchor_x0}+{1'b0,dut.anchor_x1};
        anchor_cy={1'b0,dut.anchor_y0}+{1'b0,dut.anchor_y1};
        if({dut.anchor_width,dut.anchor_height,dut.anchor_center_x,dut.anchor_center_y}
           !=={anchor_w,anchor_h,anchor_cx,anchor_cy})
            $fatal(1,"Cached anchor feature invariant broken case=%0d sample=%0d",CASE_ID,comparisons);
        if(rst_n) begin
            if(actual[98]!==last_ready)
                $fatal(1,"Publication latency changed case=%0d sample=%0d",CASE_ID,comparisons);
            last_ready=ready;
            if(ready) begin
                tokens=tokens+1;
                if(dut.candidate && dut.associated) associations=associations+1;
            end
            if(actual[98]) publications=publications+1;
            if(!prior_active && original.active) confirmations=confirmations+1;
            if(original.active && original.misses!=0) held=held+1;
            if(!actual[98] && actual[97:0]!==previous_payload[97:0])
                $fatal(1,"Publication changed without token case=%0d",CASE_ID);
        end else last_ready=0;
        previous_payload=actual;
        comparisons=comparisons+1;
    end

    task send;
        input integer is_ready,is_found,is_scene,supported,pixel_count;
        input integer ax0,ax1,ay0,ay1;
        begin
            @(negedge clk);
            ready=is_ready;found=is_found;scene=is_scene;support=supported;pixels=pixel_count;
            x0=ax0;x1=ax1;y0=ay0;y1=ay1;
        end
    endtask
    task reset_between_edges;
        begin
            @(negedge clk);#2;rst_n=0;
            #1;
            if(actual!==reference_value || actual!==99'd0)
                $fatal(1,"Asynchronous reset mismatch case=%0d",CASE_ID);
            @(negedge clk);rst_n=1;ready=0;
            resets=resets+1;
        end
    endtask

    initial begin
        repeat(3) @(negedge clk);
        rst_n=1;
        // Confirm, smooth in each direction including deadband boundaries,
        // hold/release, candidate-size/overlap/center thresholds and scenes.
        for(j=0;j<4;j=j+1) begin
            for(i=0;i<CONFIRM+2;i=i+1)
                send(1,1,0,100000,1000,100,179,100,159);
            for(i=-2;i<=2;i=i+1) begin
                dx=DEAD+i;
                send(1,1,0,100000,1000,100+dx,179+dx,100,159);
                send(1,1,0,100000,1000,100,179,100+dx,159+dx);
                dx=CENTER_STEP+i;
                send(1,1,0,100000,1000,100+dx,179+dx,100,159);
                send(1,1,0,100000,1000,100,179,100,159);
            end
            for(i=0;i<RELEASE+2;i=i+1)
                send(1,0,0,0,0,4000,0,4095,0);
            send(1,1,1,100000,999,100,179,100,159);
            send(0,1,1,100000,999,4095,0,4095,0);
        end
        for(i=0;i<30000;i=i+1) begin
            random_state=random_next(random_state);
            selector=random_state%12;
            bx=100;by=100;span_w=80;span_h=60;
            dx=$signed(random_state[12:0])%70;
            dy=$signed(random_state[25:13])%70;
            case(selector)
                0: send(1,1,0,100000,i,100+dx,179+dx,100+dy,159+dy);
                1: send(1,1,0,MIN_SUPPORT+(i%3)-1,i,100,179,100,159);
                2: send(1,1,0,(i%100),i,100,179,100,159);
                3: send(1,0,0,0,0,100,179,100,159);
                4: send(1,1,i%7==0,100000,i,100,179,100,159);
                5: send(0,random_state[7],random_state[8],24'hffffff,i,
                        random_state[11:0],random_state[23:12],0,4095);
                6: send(1,1,0,100000,i,0,WIDTH-1,0,HEIGHT-1);
                7: send(1,1,0,100000,i,0,WIDTH,0,HEIGHT);
                8: send(1,1,0,100000,i,0,0,0,0);
                9: send(1,1,0,100000,i,4095,0,4095,0);
                10: send(1,1,0,100000,i,100,100+(i%240),100,100+(i%180));
                default: send(1,1,0,100000,i,100,179,100,159);
            endcase
            if(i==511 || i==4095 || i==17000) reset_between_edges();
        end
        send(0,0,0,0,0,0,0,0,0);
        repeat(4) @(negedge clk);
        if(tokens<1000 || publications<1000 || confirmations==0 || associations==0 ||
           (RELEASE>1 && held==0))
            $fatal(1,"Insufficient motion state coverage case=%0d tokens=%0d publications=%0d confirms=%0d associated=%0d holds=%0d",
                   CASE_ID,tokens,publications,confirmations,associations,held);
        $display("MOTION_ANCHOR_CASE_PASS case=%0d confirm=%0d release=%0d center=%0d margin=%0d deadband=%0d comparisons=%0d tokens=%0d publications=%0d confirms=%0d associated=%0d holds=%0d resets=%0d",
                 CASE_ID,CONFIRM,RELEASE,CENTER_STEP,MARGIN,DEAD,comparisons,tokens,
                 publications,confirmations,associations,held,resets);
        done=1;
    end
endmodule

module motion_center_arithmetic_case #(
    parameter integer STEP=64
)(output reg done=0);
    motion_result_stabilizer #(.MAX_CENTER_STEP(STEP)) dut(
        .I_clk(1'b0),.I_rst_n(1'b0),.I_result_ready(1'b0),
        .I_found(1'b0),.I_scene_change(1'b0),.I_supported_blocks(24'd0),
        .I_pixels(24'd0),.I_xmin(12'd0),.I_xmax(12'd0),
        .I_ymin(12'd0),.I_ymax(12'd0),.O_result_ready(),.O_found(),
        .O_xmin(),.O_xmax(),.O_ymin(),.O_ymax(),.O_center_x(),
        .O_center_y(),.O_pixels(),.O_frame_toggle()
    );
    reg [63:0] cpu_limit;
    reg [31:0] random_state=32'h17d5e039+STEP;
    integer current_value,previous_value,offset,difference;
    integer comparisons=0,i;
    function [31:0] random_next;
        input [31:0] v;
        reg [31:0] t;
        begin t=v^(v<<13);t=t^(t>>17);random_next=t^(t<<5);end
    endfunction
    task check_pair;
        input integer current_center,previous_center;
        integer distance;
        reg expected,observed;
        begin
            if(current_center>=0 && current_center<=8191 &&
               previous_center>=0 && previous_center<=8191) begin
                distance=current_center>=previous_center ?
                    current_center-previous_center : previous_center-current_center;
                expected=distance<=cpu_limit;
                observed=dut.centers_match(current_center[12:0],previous_center[12:0]);
                if(observed!==expected)
                    $fatal(1,"Center arithmetic mismatch step=%0d limit=%0d current=%0d previous=%0d got=%b expected=%b",
                           STEP,cpu_limit,current_center,previous_center,observed,expected);
                comparisons=comparisons+1;
            end
        end
    endtask
    initial begin
        // Wide CPU arithmetic makes the legacy 32-bit multiplication wrap
        // explicit, rather than reusing the RTL's signed comparison.
        cpu_limit=(64'd2*STEP)%64'd4294967296;
        // Every possible center and every signed difference, both orderings.
        for(previous_value=0;previous_value<=8191;previous_value=previous_value+1) begin
            check_pair(0,previous_value);check_pair(8191,previous_value);
            check_pair(previous_value,0);check_pair(previous_value,8191);
            if(cpu_limit<8192) begin
                for(offset=-2;offset<=2;offset=offset+1) begin
                    current_value=previous_value+integer'(cpu_limit)+offset;
                    check_pair(current_value,previous_value);
                    current_value=previous_value-integer'(cpu_limit)+offset;
                    check_pair(current_value,previous_value);
                end
            end
        end
        for(difference=-8191;difference<=8191;difference=difference+1) begin
            if(difference<0) check_pair(0,-difference);
            else check_pair(difference,0);
        end
        for(i=0;i<100000;i=i+1) begin
            random_state=random_next(random_state);
            check_pair(random_state[12:0],random_state[25:13]);
        end
        $display("MOTION_CENTER_ARITHMETIC_PASS step=%0d unsigned_limit=%0d comparisons=%0d",
                 STEP,cpu_limit,comparisons);
        done=1;
    end
endmodule

module tb_motion_anchor_equivalence;
    wire [4:0] done;
    wire [8:0] arithmetic_done;
    motion_anchor_equivalence_case #(.CASE_ID(0)) c0(done[0]);
    motion_anchor_equivalence_case #(.CASE_ID(1),.CONFIRM(1),.RELEASE(1),.CENTER_STEP(1),.MARGIN(0),.DEAD(0)) c1(done[1]);
    motion_anchor_equivalence_case #(.CASE_ID(2),.CONFIRM(2),.RELEASE(7),.CENTER_STEP(7),.MARGIN(1),.DEAD(1)) c2(done[2]);
    motion_anchor_equivalence_case #(.CASE_ID(3),.WIDTH(4096),.HEIGHT(4096),.CONFIRM(5),.RELEASE(2),.CENTER_STEP(4096),.MARGIN(8192),.DEAD(4096)) c3(done[3]);
    motion_anchor_equivalence_case #(.CASE_ID(4),.CONFIRM(7),.RELEASE(8),.CENTER_STEP(65),.MARGIN(33),.DEAD(7)) c4(done[4]);
    motion_center_arithmetic_case #(.STEP(1)) a0(arithmetic_done[0]);
    motion_center_arithmetic_case #(.STEP(7)) a1(arithmetic_done[1]);
    motion_center_arithmetic_case #(.STEP(64)) a2(arithmetic_done[2]);
    motion_center_arithmetic_case #(.STEP(65)) a3(arithmetic_done[3]);
    motion_center_arithmetic_case #(.STEP(4095)) a4(arithmetic_done[4]);
    motion_center_arithmetic_case #(.STEP(4096)) a5(arithmetic_done[5]);
    motion_center_arithmetic_case #(.STEP(1073741823)) a6(arithmetic_done[6]);
    motion_center_arithmetic_case #(.STEP(1073741824)) a7(arithmetic_done[7]);
    motion_center_arithmetic_case #(.STEP(2147483647)) a8(arithmetic_done[8]);
    initial begin
        wait((&done)&&(&arithmetic_done));
        $display("MOTION_ANCHOR_EQUIVALENCE_PASS cases=5 arithmetic_parameters=9 exact_cycle_latency=1");
        $finish;
    end
    initial begin #1000000;$fatal(1,"Motion anchor differential timeout");end
endmodule
