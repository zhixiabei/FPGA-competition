`timescale 1ns/1ps
// The unchanged tensor oracle below checks every activation, all 24 weights,
// and every output value independently from scheduler state and DDR timing.
module tb_fruitcnn128_timing_equivalence;
    tb_fruit_core_numeric numeric();
    integer cycle_index=0, ordinal=0, previous_mac_cycle=-1;
    integer throughput_checks=0, completed_cases=0, trace_fd;
    integer last_pattern=-1, case_read_count=0, case_write_count=0;
    integer case_mac_count=0, same_edge_reads=0, pending_peak=0;
    integer case_wait_base=0;
    integer last_done_cycle=-1;
    reg prior_done=0;
    reg [1023:0] trace_path;
    function [12:0] expected_width_select;
        input integer width;
        begin
            expected_width_select=0;
            case(width)
                1:expected_width_select[0]=1;
                2:expected_width_select[1]=1;
                4:expected_width_select[2]=1;
                8:expected_width_select[3]=1;
                16:expected_width_select[4]=1;
                32:expected_width_select[5]=1;
                64:expected_width_select[6]=1;
                128:expected_width_select[7]=1;
                6:expected_width_select[8]=1;
                12:expected_width_select[9]=1;
                24:expected_width_select[10]=1;
                48:expected_width_select[11]=1;
                96:expected_width_select[12]=1;
            endcase
        end
    endfunction
    integer tested_width,tested_y,expected_row,exhaustive_checks=0;
    initial begin
        for(tested_width=0;tested_width<256;tested_width=tested_width+1)
            for(tested_y=0;tested_y<256;tested_y=tested_y+1) begin
                expected_row=expected_width_select(tested_width)!=0 ?
                    tested_width*tested_y : 0;
                if(numeric.dut.row_offset(tested_y[7:0],tested_width[7:0])!==expected_row[15:0])
                    $fatal(1,"Original row offset differs from integer product y=%0d width=%0d",
                        tested_y,tested_width);
`ifdef CNN_HAS_DECODED_ROW_OFFSET
                if(numeric.dut.decoded_row_offset(tested_y[7:0],
                   expected_width_select(tested_width))!==expected_row[15:0])
                    $fatal(1,"Decoded row offset differs from integer product y=%0d width=%0d expected=%0d",
                        tested_y,tested_width,expected_row);
`endif
                exhaustive_checks=exhaustive_checks+1;
            end
`ifdef CNN_HAS_DECODED_ROW_OFFSET
        $display("CNN_ROW_OFFSET_EXHAUSTIVE_PASS pairs=%0d decoded=1 supported_widths=13 default_zero=1 max_3y=765",
            exhaustive_checks);
`else
        $display("CNN_ROW_OFFSET_EXHAUSTIVE_PASS pairs=%0d decoded=0 supported_widths=13 default_zero=1 max_3y=765",
            exhaustive_checks);
`endif
    end
    initial begin
        if(!$value$plusargs("OUTPUT_TRACE=%s",trace_path))
            trace_path="output_trace.txt";
        trace_fd=$fopen(trace_path,"w");
        if(trace_fd==0) $fatal(1,"Cannot open CNN numerical output trace");
        if($bits(numeric.dut.sums)/54!=24)
            $fatal(1,"CNN timing change modified the 24-MAC lane count");
    end
    always @(posedge numeric.clk) begin
        cycle_index=cycle_index+1;
        if(!numeric.rst_n || !numeric.checking) begin
            ordinal=0; previous_mac_cycle=-1;
            case_read_count=0; case_write_count=0; case_mac_count=0;
            same_edge_reads=0; pending_peak=0;
        end else begin
            if(numeric.pattern_id!=last_pattern) begin
                last_pattern=numeric.pattern_id;
                case_read_count=0; case_write_count=0; case_mac_count=0;
                same_edge_reads=0; pending_peak=0;
            end
            if(numeric.qcount>pending_peak) pending_peak=numeric.qcount;
            if(numeric.start && !numeric.busy) case_wait_base=numeric.wait_cycles;
            if(numeric.mem_valid && numeric.mem_ready) begin
                if(numeric.mem_write) begin
                    $fdisplay(trace_fd,"CASE %0d WRITE %08h %032h",
                        numeric.pattern_id,numeric.mem_addr,numeric.mem_data);
                    case_write_count=case_write_count+1;
                end else begin
                    case_read_count=case_read_count+1;
                    if(numeric.mem_rsp_valid && numeric.qcount==0)
                        same_edge_reads=same_edge_reads+1;
                end
            end
            if(numeric.dut.mac_enable) begin
                // Prefetch and output packing may pause between positions,
                // but all terms of a 3x3 position must stay one per clock.
                if(numeric.kernel==3 && ordinal%numeric.terms!=0) begin
                    if(cycle_index!=previous_mac_cycle+1)
                        $fatal(1,"3x3 term throughput regressed case=%0d term=%0d gap=%0d",
                            numeric.pattern_id,ordinal%numeric.terms,
                            cycle_index-previous_mac_cycle);
                    throughput_checks=throughput_checks+1;
                end
                ordinal=ordinal+1;
                previous_mac_cycle=cycle_index;
                case_mac_count=case_mac_count+1;
            end
        end
        #1;
`ifdef CNN_HAS_DECODED_ROW_OFFSET
        if(numeric.rst_n && numeric.busy &&
           numeric.dut.row_width_select!==expected_width_select(numeric.width))
            $fatal(1,"Operation width predecode did not capture/retain descriptor width=%0d decode=%h",
                numeric.width,numeric.dut.row_width_select);
`endif
        if(numeric.rst_n && numeric.done && !prior_done) begin
            completed_cases=completed_cases+1;
            last_done_cycle=cycle_index;
            $display("CNN_TIMING_CASE_PASS id=%0d cycles=%0d macs=%0d reads=%0d writes=%0d waits=%0d same_edge=%0d pending_peak=%0d",
                numeric.pattern_id,numeric.cycles-numeric.operation_cycle_base,
                case_mac_count,case_read_count,case_write_count,
                numeric.wait_cycles-case_wait_base,same_edge_reads,pending_peak);
        end
        prior_done=numeric.done;
    end

    initial begin
        // The runner inserts only a completion barrier into a copied golden
        // bench, allowing these schedules to reuse all of its numeric checks.
        wait(numeric.timing_base_complete===1);
        numeric.configure(800,8,2,1,1,0,3,24,0,0,0,1);
        numeric.reset_core(); numeric.begin_operation(); numeric.finish_operation();
        numeric.configure(801,8,8,3,1,1,3,24,0,1,0,1);
        numeric.reset_core(); numeric.begin_operation(); numeric.finish_operation();
        numeric.configure(802,8,8,4,4,0,2,8,1,0,0,1);
        numeric.reset_core(); numeric.begin_operation(); numeric.finish_operation();

        // Cancel while multiple row-prefetch reads are outstanding, then
        // restart from the same descriptor without retaining stale cache data.
        numeric.configure(803,8,8,3,1,1,3,24,0,1,2,1);
        numeric.reset_core(); numeric.begin_operation();
        wait(numeric.dut.state==5'd26 && numeric.qcount>0);
        numeric.reset_core();
        if(numeric.busy || numeric.done || numeric.mem_valid ||
           numeric.dut.pipe_valid || numeric.qcount!=0)
            $fatal(1,"Reset retained outstanding 3x3 prefetch state");
        numeric.begin_operation(); numeric.finish_operation();

        // Reload all 576 terms for two output groups, including every W8
        // lane in the tail. Cancel partway through loading the tail first;
        // embedded RAM contents survive reset and must never leak through.
        numeric.configure(900,2,2,3,1,1,64,25,0,0,2,1);
        numeric.reset_core(); numeric.begin_operation();
        wait(numeric.dut.state==5'd2 && numeric.dut.received>=16'd1056);
        numeric.reset_core();
        if(numeric.busy || numeric.mem_valid || numeric.dut.pipe_valid || numeric.qcount!=0)
            $fatal(1,"Reset retained a partially loaded weight tail transaction");
        numeric.begin_operation(); numeric.finish_operation();

        // Interrupt active tail MACs, then restart with a different tensor.
        // This also checks that no extra RAM output cycle shifts term 512.
        numeric.configure(901,2,2,3,1,1,64,24,0,1,0,0);
        numeric.reset_core(); numeric.begin_operation();
        wait(numeric.dut.mac_enable && numeric.dut.term>=10'd520);
        numeric.reset_core();
        numeric.configure(902,2,2,3,1,1,64,24,0,1,0,0);
        numeric.begin_operation(); numeric.finish_operation();

        if(completed_cases!=29 || numeric.cases_passed!=29 ||
           throughput_checks<1000 || last_done_cycle<0)
            $fatal(1,"CNN timing verification coverage incomplete cases=%0d numeric=%0d throughput=%0d",
                completed_cases,numeric.cases_passed,throughput_checks);
        $fclose(trace_fd);
        $display("CNN_TIMING_EQUIVALENCE_PASS cases=%0d throughput_checks=%0d lanes=24 conv3_one_term_per_clock=1 immediate_stalled_ddr=1 reset_activation=1 reset_prefetch=1 reset_tail_load=1 reset_tail_mac=1",
            completed_cases,throughput_checks);
        numeric.timing_extensions_complete=1;
    end
endmodule
