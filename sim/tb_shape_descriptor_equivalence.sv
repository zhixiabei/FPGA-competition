`timescale 1ns/1ps
module shape_descriptor_case #(
    parameter integer STABLE=0,
    parameter integer CASE_ID=0,
    parameter integer MAX_CYCLES=4096
) (output reg done=0);
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, clear=0, start=0, bad=0;
    reg [19:0] area=0;
    reg [15:0] perimeter=0;
    reg [10:0] xmin=0,xmax=0;
    reg [9:0] ymin=0,ymax=0;
    reg [31:0] mx2=0,my2=0;
    reg [11:0] umin=0,umax=0,vmin=0,vmax=0;
    wire ready,ref_ready,circle,ref_circle;
    wire [1:0] shape,ref_shape;
    integer vector_index=0,checks=0,completed=0,cancelled_clear=0,cancelled_reset=0;
    integer seed=32'h512ac4+CASE_ID;
    integer txn_cycles=0,dut_cycles=0,ref_cycles=0,delta_cycles;
    integer dut_min=MAX_CYCLES,dut_max=0,ref_min=MAX_CYCLES,ref_max=0;
    integer delta_min=MAX_CYCLES,delta_max=-MAX_CYCLES;
    integer valid_dut_min=MAX_CYCLES,valid_dut_max=0;
    integer valid_delta_min=MAX_CYCLES,valid_delta_max=-MAX_CYCLES;
    integer faster=0,slower=0,equal_cycles=0;
    integer shape_counts [0:3];
    integer circle_count=0;
    reg active=0,dut_seen=0,ref_seen=0;
    reg [1:0] dut_result,ref_result;
    reg dut_circle_result,ref_circle_result;
    reg [9:0] dut_flags,ref_flags;
    reg [63:0] expected_product [0:13];
    reg [63:0] expected_deviation [0:3];
    integer ref_products=0,dut_products=0,product_checks=0,deviation_checks=0;
    integer ref_previous_state=0,dut_previous_state=0;
    reg expects_products=0;
`define SHAPE_PORTS \
    .I_clk(clk),.I_rst_n(rst_n),.I_clear(clear),.I_start(start),.I_bad(bad), \
    .I_area(area),.I_perimeter(perimeter),.I_xmin(xmin),.I_xmax(xmax), \
    .I_ymin(ymin),.I_ymax(ymax),.I_mx2(mx2),.I_my2(my2), \
    .I_umin(umin),.I_umax(umax),.I_vmin(vmin),.I_vmax(vmax)
    color_shape_descriptor #(.STABLE_INPUTS(STABLE)) dut(
        `SHAPE_PORTS,.O_ready(ready),.O_shape(shape),.O_circle_support(circle));
    color_shape_descriptor_reference #(.STABLE_INPUTS(STABLE)) baseline(
        `SHAPE_PORTS,.O_ready(ref_ready),.O_shape(ref_shape),
        .O_circle_support(ref_circle));
`undef SHAPE_PORTS
    // Each implementation may finish at a different cycle. Latch its result
    // exactly on ready so a later idle/start cycle cannot overwrite evidence.
    always @(posedge clk) begin
        #1;
        if(!rst_n || clear) begin
            if(ready !== 1'b0 || ref_ready !== 1'b0 ||
               shape !== 2'd0 || ref_shape !== 2'd0 ||
               circle !== 1'b0 || ref_circle !== 1'b0)
                $fatal(1,"SHAPE_CANCEL_OUTPUT stable=%0d vector=%0d",STABLE,vector_index);
        end else if(active) begin
            txn_cycles=txn_cycles+1;
            if(dut_previous_state==dut.MULTIPLY && dut.state!=dut.MULTIPLY) begin
                if(dut_products>=14 || dut.product !==
                   expected_product[dut_products][dut.MATH_BITS-1:0])
                    $fatal(1,"SHAPE_DUT_PRODUCT stable=%0d vector=%0d product=%0d got=%h expected=%h",
                        STABLE,vector_index,dut_products,dut.product,expected_product[dut_products]);
                if(dut_products>=7 && (dut_products&1)) begin
                    if(dut.deviation !==
                       expected_deviation[(dut_products-7)/2][dut.MATH_BITS-1:0])
                        $fatal(1,"SHAPE_DUT_DEVIATION stable=%0d vector=%0d projection=%0d got=%h expected=%h",
                            STABLE,vector_index,(dut_products-7)/2,dut.deviation,
                            expected_deviation[(dut_products-7)/2]);
                    deviation_checks=deviation_checks+1;
                end
                dut_products=dut_products+1;product_checks=product_checks+1;
            end
            if(ref_previous_state==baseline.MULTIPLY && baseline.state!=baseline.MULTIPLY) begin
                if(ref_products>=14 || baseline.product !==
                   expected_product[ref_products][baseline.MATH_BITS-1:0])
                    $fatal(1,"SHAPE_REFERENCE_PRODUCT stable=%0d vector=%0d product=%0d got=%h expected=%h",
                        STABLE,vector_index,ref_products,baseline.product,expected_product[ref_products]);
                if(ref_products>=7 && (ref_products&1)) begin
                    if(baseline.deviation !==
                       expected_deviation[(ref_products-7)/2][baseline.MATH_BITS-1:0])
                        $fatal(1,"SHAPE_REFERENCE_DEVIATION stable=%0d vector=%0d projection=%0d",
                            STABLE,vector_index,(ref_products-7)/2);
                    deviation_checks=deviation_checks+1;
                end
                ref_products=ref_products+1;product_checks=product_checks+1;
            end
            if(ready) begin
                if(dut_seen) $fatal(1,"SHAPE_DUPLICATE_DUT stable=%0d vector=%0d",STABLE,vector_index);
                if((^shape) === 1'bx || (circle !== 1'b0 && circle !== 1'b1))
                    $fatal(1,"SHAPE_UNKNOWN_DUT stable=%0d vector=%0d",STABLE,vector_index);
                dut_seen=1;dut_cycles=txn_cycles;
                dut_result=shape;dut_circle_result=circle;
                dut_flags={dut.isotropic,dut.centered,dut.skew,dut.circle_metric,
                    dut.square_metric,dut.triangle_metric,dut.circle_fill,
                    dut.circle_support,dut.square_fill,dut.square_spans_ok};
            end
            if(ref_ready) begin
                if(ref_seen) $fatal(1,"SHAPE_DUPLICATE_REFERENCE stable=%0d vector=%0d",STABLE,vector_index);
                if((^ref_shape) === 1'bx || (ref_circle !== 1'b0 && ref_circle !== 1'b1))
                    $fatal(1,"SHAPE_UNKNOWN_REFERENCE stable=%0d vector=%0d",STABLE,vector_index);
                ref_seen=1;ref_cycles=txn_cycles;
                ref_result=ref_shape;ref_circle_result=ref_circle;
                ref_flags={baseline.isotropic,baseline.centered,baseline.skew,baseline.circle_metric,
                    baseline.square_metric,baseline.triangle_metric,baseline.circle_fill,
                    baseline.circle_support,baseline.square_fill,baseline.square_spans_ok};
            end
            checks=checks+1;
        end else if(ready !== 1'b0 || ref_ready !== 1'b0)
            $fatal(1,"SHAPE_STRAY_READY stable=%0d vector=%0d",STABLE,vector_index);
        ref_previous_state=baseline.state;
        dut_previous_state=dut.state;
    end

    task centered_box;
        input integer pixels,length,x0,x1,y0,y1;
        begin
            bad=0;area=pixels;perimeter=length;
            xmin=x0;xmax=x1;ymin=y0;ymax=y1;
            mx2=pixels*(x0+x1);my2=pixels*(y0+y1);
            umin=x0+y0;umax=x1+y1;
            vmin=x0+720-y1;vmax=x1+720-y0;
        end
    endtask
    task circle_vector;
        begin
            centered_box(7854,2512,100,199,100,199);
            umin=229;umax=369;vmin=650;vmax=790;
        end
    endtask
    task random_vector;
        begin
            area=$random(seed);perimeter=$random(seed);
            xmin=10+($unsigned($random(seed))%400);
            xmax=600+($unsigned($random(seed))%650);
            ymin=10+($unsigned($random(seed))%200);
            ymax=300+($unsigned($random(seed))%400);
            mx2=$random(seed);my2=$random(seed);
            umin=$random(seed);umax=$random(seed);
            vmin=$random(seed);vmax=$random(seed);
            bad=vector_index%31==0;
        end
    endtask
    task perturb_inputs;
        begin
            bad=$random(seed);area=$random(seed);perimeter=$random(seed);
            xmin=$random(seed);xmax=$random(seed);ymin=$random(seed);ymax=$random(seed);
            mx2=$random(seed);my2=$random(seed);
            umin=$random(seed);umax=$random(seed);vmin=$random(seed);vmax=$random(seed);
        end
    endtask
    task directed_vector;
        begin
            case(vector_index%64)
                0:begin area=20'hfffff;perimeter=16'hffff;end
                1:begin area=1;perimeter=0;end
                2:begin area=0;end
                3:circle_vector();
                4:centered_box(10000,3200,100,199,100,199);
                5:begin centered_box(5000,3000,100,199,100,199);my2=5000*332;end
                6:begin centered_box(10000,3200,100,240,100,240);
                    umin=270;umax=410;vmin=650;vmax=790;end
                7:begin circle_vector();xmin=3;end
                8:begin circle_vector();xmin=4;mx2=area*(xmin+xmax);end
                9:begin circle_vector();ymin=3;end
                10:begin circle_vector();xmax=1276;end
                11:begin circle_vector();ymax=716;end
                12:begin circle_vector();xmin=xmax-10;end
                13:begin circle_vector();ymin=ymax-11;end
                14:begin centered_box(1216,1216,100,139,100,139);end
                15:begin centered_box(1216,1215,100,139,100,139);end
                16:begin centered_box(1216,1217,100,139,100,139);end
                17:begin centered_box(864,864,100,139,100,139);end
                18:begin centered_box(864,863,100,139,100,139);end
                19:begin centered_box(864,865,100,139,100,139);end
                20:begin circle_vector();area=7199;mx2=area*299;my2=mx2;end
                21:begin circle_vector();area=7200;mx2=area*299;my2=mx2;end
                22:begin circle_vector();area=7201;mx2=area*299;my2=mx2;end
                23:begin circle_vector();area=6799;mx2=area*299;my2=mx2;end
                24:begin circle_vector();area=6800;mx2=area*299;my2=mx2;end
                25:begin circle_vector();area=6801;mx2=area*299;my2=mx2;end
                26:begin circle_vector();area=6399;mx2=area*299;my2=mx2;end
                27:begin circle_vector();area=6400;mx2=area*299;my2=mx2;end
                28:begin circle_vector();area=6401;mx2=area*299;my2=mx2;end
                29:begin circle_vector();mx2=area*299+(area*100)/8;end
                30:begin circle_vector();mx2=area*299+(area*100)/8+1;end
                31:begin circle_vector();mx2=area*299-(area*100)/8;end
                32:begin circle_vector();mx2=area*299-(area*100)/8-1;end
                33:begin circle_vector();mx2=32'h0000ffff;my2=32'h00000001;end
                34:begin circle_vector();mx2=32'h00010000;my2=32'h00000001;end
                35:begin circle_vector();mx2=32'h00010001;my2=32'h00000002;end
                36:begin circle_vector();mx2=32'hffff0000;my2=32'h00010000;end
                37:begin circle_vector();mx2=32'hffffffff;my2=32'h00000001;end
                38:begin circle_vector();mx2=32'hffffffff;my2=32'hffffffff;end
                39:begin circle_vector();mx2=0;my2=32'hffffffff;end
                40:begin circle_vector();mx2=32'h80000000;my2=32'h7fffffff;end
                41:begin circle_vector();mx2=32'h7fffffff;my2=32'h80000000;end
                42:begin circle_vector();mx2=32'h00010000;my2=32'h00010001;end
                43:begin circle_vector();mx2=32'h00010001;my2=32'h00010000;end
                44:begin circle_vector();umin=0;umax=4095;vmin=0;vmax=4095;end
                45:begin circle_vector();umin=4095;umax=0;vmin=4095;vmax=0;end
                46:begin circle_vector();vmin=0;vmax=1;end
                47:begin circle_vector();vmin=4094;vmax=4095;end
                48:begin circle_vector();umin=0;umax=0;vmin=720;vmax=720;end
                49:begin centered_box(65535,65535,4,1275,4,715);end
                50:begin centered_box(65536,65534,4,1275,4,715);end
                51:begin centered_box(65537,65533,4,1275,4,715);end
                52:begin centered_box(20'hfffff,65535,4,1275,4,715);end
                53:begin centered_box(20'h80000,16'h8000,4,1275,4,715);end
                54:begin circle_vector();bad=1;end
                55:begin circle_vector();xmin=200;xmax=100;end
                56:begin circle_vector();ymin=200;ymax=100;end
                default:begin end
            endcase
        end
    endtask
    task expected_math;
        reg [63:0] a,w,h,u,v,p;
        reg signed [63:0] centers [0:3];
        reg signed [63:0] moments [0:3];
        reg signed [63:0] difference;
        integer projection;
        begin
            a=area;p=perimeter;
            // Match the public coordinate widths, including deliberately
            // reversed projection bounds, before doing independent 64-bit math.
            w=({1'b0,xmax}-{1'b0,xmin}+1'b1)&13'h1fff;
            h=({1'b0,ymax}-{1'b0,ymin}+1'b1)&13'h1fff;
            u=({1'b0,umax}-{1'b0,umin}+1'b1)&13'h1fff;
            v=({1'b0,vmax}-{1'b0,vmin}+1'b1)&13'h1fff;
            expected_product[0]=p*p;
            expected_product[1]=a*1216;
            expected_product[2]=a*864;
            expected_product[3]=a*25;
            expected_product[4]=w*h;
            expected_product[5]=u*v;
            centers[0]=$signed({1'b0,xmin})+$signed({1'b0,xmax});
            centers[1]=$signed({1'b0,ymin})+$signed({1'b0,ymax});
            centers[2]=$signed({1'b0,umin})+$signed({1'b0,umax});
            centers[3]=$signed({1'b0,vmin})+$signed({1'b0,vmax})-1440;
            moments[0]=$signed({1'b0,mx2});moments[1]=$signed({1'b0,my2});
            moments[2]=$signed({1'b0,mx2})+$signed({1'b0,my2});
            moments[3]=$signed({1'b0,mx2})-$signed({1'b0,my2});
            for(projection=0;projection<4;projection=projection+1) begin
                expected_product[6+projection*2]=a*
                    (centers[projection]<0 ? -centers[projection] : centers[projection]);
                case(projection)
                    0:expected_product[7+projection*2]=a*w;
                    1:expected_product[7+projection*2]=a*h;
                    2:expected_product[7+projection*2]=a*u;
                    3:expected_product[7+projection*2]=a*v;
                endcase
                difference=moments[projection]-$signed(a)*centers[projection];
                expected_deviation[projection]=difference<0 ? -difference : difference;
            end
            expects_products=!(bad || area==0 || xmin<=3 || ymin<=3 ||
                xmax>=1276 || ymax>=716 || xmax-xmin<11 || ymax-ymin<11);
        end
    endtask

    initial begin : run_vectors
        integer cancel_kind,cancel_cycle,quiet_cycle;
        for(integer index=0;index<4;index=index+1) shape_counts[index]=0;
        repeat(3) @(negedge clk);
        rst_n=1;
        for(vector_index=0;vector_index<2400;vector_index=vector_index+1) begin
            @(negedge clk);
            random_vector();
            directed_vector();
            cancel_kind=vector_index%37==0 ? 1 : (vector_index%53==0 ? 2 : 0);
            cancel_cycle=1+((vector_index/37)%3)*31;
            // Cancellation cases use a valid, full computation rather than
            // immediately rejected geometry. No completion is expected.
            if(cancel_kind!=0) circle_vector();
            expected_math();
            txn_cycles=0;dut_cycles=0;ref_cycles=0;
            ref_products=0;dut_products=0;
            dut_seen=0;ref_seen=0;active=1;start=1;
            @(negedge clk);start=0;
            while((!dut_seen || !ref_seen) && txn_cycles<MAX_CYCLES &&
                  (cancel_kind==0 || txn_cycles<cancel_cycle)) begin
                if(!STABLE) perturb_inputs();
                @(negedge clk);
            end
            if(cancel_kind!=0) begin
                if(dut_seen || ref_seen)
                    $fatal(1,"SHAPE_CANCEL_TOO_LATE stable=%0d vector=%0d cycle=%0d",
                        STABLE,vector_index,txn_cycles);
                if(cancel_kind==1) begin clear=1;cancelled_clear=cancelled_clear+1;end
                else begin rst_n=0;cancelled_reset=cancelled_reset+1;end
                @(negedge clk);clear=0;rst_n=1;active=0;
                for(quiet_cycle=0;quiet_cycle<MAX_CYCLES+4;quiet_cycle=quiet_cycle+1)
                    @(negedge clk);
            end else begin
                if(!dut_seen || !ref_seen)
                    $fatal(1,"SHAPE_TIMEOUT stable=%0d vector=%0d cycle=%0d dut=%b ref=%b",
                        STABLE,vector_index,txn_cycles,dut_seen,ref_seen);
                if({dut_result,dut_circle_result} !== {ref_result,ref_circle_result})
                    $fatal(1,"SHAPE_DIFFERENTIAL stable=%0d vector=%0d dut=%0d/%b@%0d ref=%0d/%b@%0d",
                        STABLE,vector_index,dut_result,dut_circle_result,dut_cycles,
                        ref_result,ref_circle_result,ref_cycles);
                if(ref_products!=(expects_products ? 14 : 0) ||
                   dut_products!=(expects_products ? 14 : 0))
                    $fatal(1,"SHAPE_PRODUCT_COUNT stable=%0d vector=%0d dut=%0d reference=%0d expected=%0d",
                        STABLE,vector_index,dut_products,ref_products,expects_products ? 14 : 0);
                if(expects_products && dut_flags !== ref_flags)
                    $fatal(1,"SHAPE_FLAGS_DIFFERENTIAL stable=%0d vector=%0d dut=%b reference=%b",
                        STABLE,vector_index,dut_flags,ref_flags);
                completed=completed+1;
                shape_counts[dut_result]=shape_counts[dut_result]+1;
                if(dut_circle_result) circle_count=circle_count+1;
                if(dut_cycles<dut_min) dut_min=dut_cycles;
                if(dut_cycles>dut_max) dut_max=dut_cycles;
                if(ref_cycles<ref_min) ref_min=ref_cycles;
                if(ref_cycles>ref_max) ref_max=ref_cycles;
                delta_cycles=dut_cycles-ref_cycles;
                if(delta_cycles<delta_min) delta_min=delta_cycles;
                if(delta_cycles>delta_max) delta_max=delta_cycles;
                if(expects_products) begin
                    if(dut_cycles<valid_dut_min) valid_dut_min=dut_cycles;
                    if(dut_cycles>valid_dut_max) valid_dut_max=dut_cycles;
                    if(delta_cycles<valid_delta_min) valid_delta_min=delta_cycles;
                    if(delta_cycles>valid_delta_max) valid_delta_max=delta_cycles;
                end
                if(delta_cycles<0) faster=faster+1;
                else if(delta_cycles>0) slower=slower+1;
                else equal_cycles=equal_cycles+1;
                active=0;
            end
            repeat(2) @(negedge clk);
        end
        if(shape_counts[1]==0 || shape_counts[2]==0 || shape_counts[3]==0 || circle_count==0)
            $fatal(1,"SHAPE_CLASS_COVERAGE stable=%0d counts=%0d/%0d/%0d/%0d support=%0d",
                STABLE,shape_counts[0],shape_counts[1],shape_counts[2],shape_counts[3],circle_count);
        done=1;
        $display("SHAPE_DESCRIPTOR_CASE_PASS stable=%0d vectors=2400 completed=%0d clear_cancelled=%0d reset_cancelled=%0d checks=%0d product_checks=%0d deviation_checks=%0d dut_cycles_min=%0d dut_cycles_max=%0d ref_cycles_min=%0d ref_cycles_max=%0d delta_cycles_min=%0d delta_cycles_max=%0d valid_dut_cycles_min=%0d valid_dut_cycles_max=%0d valid_delta_cycles_min=%0d valid_delta_cycles_max=%0d faster=%0d slower=%0d equal=%0d three_targets_max_cycles=%0d three_targets_added_max_cycles=%0d three_targets_delta_max_cycles=%0d classes=%0d/%0d/%0d/%0d circle_support=%0d",
            STABLE,completed,cancelled_clear,cancelled_reset,checks,product_checks,deviation_checks,
            dut_min,dut_max,ref_min,ref_max,
            delta_min,delta_max,valid_dut_min,valid_dut_max,valid_delta_min,valid_delta_max,
            faster,slower,equal_cycles,3*dut_max,
            delta_max>0 ? 3*delta_max : 0,3*valid_delta_max,shape_counts[0],shape_counts[1],
            shape_counts[2],shape_counts[3],circle_count);
    end
endmodule
module tb_shape_descriptor_equivalence;
    wire a,b;
    shape_descriptor_case #(.STABLE(0),.CASE_ID(0)) captured(a);
    shape_descriptor_case #(.STABLE(1),.CASE_ID(1)) stable(b);
    initial begin
        wait(a&&b);
        $display("SHAPE_DESCRIPTOR_EQUIVALENCE_PASS vectors=4800 result_exact=1 variable_latency=1");
        $finish;
    end
    initial begin #400000000; $fatal(1,"SHAPE_DIFFERENTIAL_WATCHDOG");end
endmodule
