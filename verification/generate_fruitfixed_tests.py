"""Build frozen RTL fixtures for fruit preprocessing, all CNN layers and decisions."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

ROOT=Path(__file__).resolve().parents[1]


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--model',type=Path,required=True)
    args=p.parse_args();out=args.model
    config=json.loads((out/'model.json').read_text())
    cases=json.loads((out/'simulation_cases.json').read_text())
    for name in ['fruitfixed_decode.v','fruitfixed_result_filter.v']:
        if name == 'fruitfixed_decode.v' and (out/name).is_file():
            continue  # Keep the checkpoint-specific acceptance threshold.
        shutil.copyfile(ROOT/'user_source/hdl_source/fruitfixed'/name,out/name)
    lines=[]
    for case in cases['pipeline']:
        c=case['case']
        lines += [f'$readmemh("snapshot_{c}.hex",snapshot);',
                  '@(negedge clk);mode=0;pp_start=1;@(negedge clk);pp_start=0;',
                  'wait(pp_done);@(negedge clk);',f'$readmemh("input_{c}.hex",expected,0,3455);',
                  f'check_words(32\'h00d00000,3456,{c},-1);',
                  f'if(texture_edges!={case["texture"]["texture_edges"]} || texture_range!={case["texture"]["texture_range"]}) $fatal(1,"texture mismatch case {c}");']
        for op in config['operations']:
            n=op['index'];words=op['cout']*op['dst_plane']//8
            lines += [f'@(negedge clk);mode=1;operation=5\'d{n};core_start=1;@(negedge clk);core_start=0;',
                      'wait(core_done);@(negedge clk);',
                      f'$readmemh("case_{c}_op_{n}.hex",expected,0,{words-1});',
                      f'check_words(32\'h{op["dst"]:08x},{words},{c},{n});']
        packed=sum((v&65535)<<(i*16) for i,v in enumerate(case['logits']))
        lines += ['@(negedge clk);mode=2;dec_start=1;@(negedge clk);dec_start=0;wait(dec_done);@(negedge clk);',
                  f'if(label!={case["expected_class"]} || debug_logits!==80\'h{packed:020x}) $fatal(1,"decoder mismatch case {c}");',
                  f'$display("FRUIT_PIPELINE_CASE_PASS case={c} label=%0d logits=%h",label,debug_logits);']
    for i,case in enumerate(cases['decoder']):
        for c,v in enumerate(case['logits']): lines.append(f"features[8192+{c}]=128'h{v&65535:032x};")
        lines += ['@(negedge clk);mode=2;dec_start=1;@(negedge clk);dec_start=0;wait(dec_done);@(negedge clk);',
                  f'if(label!={case["expected"]} || decode.exp_sum!={case["exp_sum"]}) $fatal(1,"decoder edge case {i} label=%d sum=%d",label,decode.exp_sum);']
    lines += [f'$display("FRUIT_DECODER_PASS cases={len(cases["decoder"])}");',
              'for(c=2;c<=6;c=c+1) begin',
              ' @(negedge clk);filter_clear=1;@(negedge clk);filter_clear=0;',
              ' send_result(c,1); send_result(c,c);',
              ' send_result(1,c);send_result(1,c);send_result(1,1);',
              'end',
              '// Switching from orange to pear must preserve both new IDs.',
              'send_result(5,1);send_result(5,5);send_result(6,5);send_result(6,5);send_result(6,6);',
              'send_result(7,6);send_result(7,6);send_result(7,1);',
              '$display("FRUIT_FILTER_PASS all_five acquire_switch_reject_invalid");',
              '$display("FRUIT_RTL_PASS five_images all_layers preprocessing decoder filter randomized_memory");',
              '$finish;']
    tb=r'''`timescale 1ns/1ps
module tb_fruitfixed;
reg clk=0;always #7.5 clk=~clk;
reg rst_n=0,pp_start=0,core_start=0,dec_start=0;
reg [1:0] mode=0;
reg [4:0] operation=6;
wire [2:0] group;
wire [383:0] descriptor;
wire pv,pw,pdone,cv,cw,cdone,cfault,dv,ddone;
wire [31:0] pa,ca,da;
wire [127:0] pd,cd;
wire [79:0] debug_logits;
wire [2:0] label;
wire [13:0] texture_edges;
wire [7:0] texture_range;
wire has_texture;
wire pp_done=pdone,core_done=cdone,dec_done=ddone;
reg ready=0,rsp=0;
reg [127:0] response=0;
wire valid=mode==0 ? pv : mode==1 ? cv : dv;
wire write_enable=mode==0 ? pw : mode==1 ? cw : 1'b0;
wire [31:0] address=mode==0 ? pa : mode==1 ? ca : da;
wire [127:0] data=mode==0 ? pd : cd;
reg [127:0] model[0:MODEL_LAST],snapshot[0:172799],features[0:16383],expected[0:4607];
reg [31:0] queue[0:31];integer head=0,tail=0,count=0,ticks=0;
reg [31:0] rng=32'h10203040;
handfixed_preprocess preprocess(.clk(clk),.rst_n(rst_n),.start(pp_start),.classifier(1'b1),
 .snapshot_base(32'h00e00000),.roi_x(16'd400),.roi_y(16'd120),.roi_side(16'd480),
 .has_texture(has_texture),.texture_edges(texture_edges),.texture_range(texture_range),
 .green_valid(),.green_row_end(),.green_pixel(),.busy(),.done(pdone),
 .mem_valid(pv),.mem_write(pw),.mem_addr(pa),.mem_data(pd),
 .mem_ready(ready && mode==0),.mem_rsp_valid(rsp && mode==0),.mem_rsp_data(response));
handfixed_program program_rom(.operation(operation),.group(group),.descriptor(descriptor));
handcnn_core core(.clk(clk),.rst_n(rst_n),.start(core_start),.operation(operation),.group(group),
 .descriptor(descriptor),.busy(),.done(cdone),.fault(cfault),.mem_valid(cv),.mem_write(cw),
 .mem_addr(ca),.mem_data(cd),.mem_ready(ready && mode==1),.mem_rsp_valid(rsp && mode==1),
 .mem_rsp_data(response),.cycles(),.mac_cycles(),.wait_cycles());
fruitfixed_decode decode(.clk(clk),.rst_n(rst_n),.start(dec_start),.done(ddone),.result_class(label),
 .mem_valid(dv),.mem_addr(da),.mem_ready(ready && mode==2),.mem_rsp_valid(rsp && mode==2),
 .mem_rsp_data(response),.debug_logits(debug_logits));
reg filter_clear=0,filter_valid=0;reg [2:0] filter_class=1;
wire [2:0] filtered,stable;
fruitfixed_result_filter filter(.clk(clk),.rst_n(rst_n),.clear(filter_clear),.in_valid(filter_valid),
 .in_class(filter_class),.decision_class(filtered),.stable_class(stable));
function [127:0] read_word(input [31:0] a);
 begin
 if(a>=32'h00c00000 && a<32'h00c00000+MODEL_BYTES) read_word=model[(a-32'h00c00000)>>4];
 else if(a>=32'h00d00000 && a<32'h00d40000) read_word=features[(a-32'h00d00000)>>4];
 else if(a>=32'h00e00000 && a<32'h010a3000) read_word=snapshot[(a-32'h00e00000)>>4];
 else begin read_word=0;$fatal(1,"invalid read %h",a);end
 end
endfunction
always @(negedge clk) begin
 rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
 ready=rng[1:0]!=0 && count<30;rsp=0;
 if(count>0 && rng[3:2]!=0) begin
  response=read_word(queue[head]);head=(head+1)%32;count=count-1;rsp=1;
 end
end
always @(posedge clk) begin
 ticks=ticks+1;
 if(cfault || ticks>30000000) $fatal(1,"core fault or timeout mode=%d op=%d",mode,operation);
 if(rst_n && valid && ready) begin
  if(address[3:0]!=0) $fatal(1,"unaligned DDR access");
  if(write_enable) begin
   if(address<32'h00d00000 || address>=32'h00d40000) $fatal(1,"invalid write %h",address);
   features[(address-32'h00d00000)>>4]=data;
  end else begin queue[tail]=address;tail=(tail+1)%32;count=count+1;end
 end
end
task check_words(input [31:0] base,input integer words,input integer test_case,input integer op);
 integer j;
 begin
 if(count!=0) $fatal(1,"pending reads at completion");
 for(j=0;j<words;j=j+1) if(features[((base-32'h00d00000)>>4)+j]!==expected[j])
  $fatal(1,"word mismatch case=%0d op=%0d word=%0d actual=%h expected=%h",test_case,op,j,features[((base-32'h00d00000)>>4)+j],expected[j]);
 $display("FRUIT_LAYER_PASS case=%0d op=%0d words=%0d",test_case,op,words);
 end
endtask
task send_result(input [2:0] value,input [2:0] expected_class);
 begin
 @(negedge clk);filter_class=value;filter_valid=1;
 @(posedge clk);#1;if(stable!==expected_class) $fatal(1,"filter result %d expected %d",stable,expected_class);
 @(negedge clk);filter_valid=0;
 end
endtask
integer c;
initial begin
 $readmemh("model.hex",model);
 repeat(10) @(negedge clk);rst_n=1;
TEST_BODY
end
endmodule
'''
    tb=tb.replace('MODEL_LAST',str(config['model_bytes']//16-1)).replace('MODEL_BYTES',str(config['model_bytes'])).replace('TEST_BODY','\n'.join(lines))
    (out/'tb_fruitfixed.sv').write_text(tb,encoding='ascii')
    tcl='''onerror {quit -code 1 -force}
onbreak {quit -code 1 -force}
vlib fruit_work
set lib E:/TD_6.2.1_Engineer_6.2.168.116/sim_release/ph1p
vlog -work fruit_work -sv $lib/ph1p_logic_dram.v $lib/ph1p_logic_dram64x8.v $lib/ph1p_phy_mslice.v $lib/ph1p_phy_dramhardcon.v $lib/ph1p_phy_gsr.v
vlog -work fruit_work -sv ../../sim/resnet18_dsp_reference.sv
vlog -work fruit_work -sv ../../user_source/hdl_source/handcnn/handcnn_core.v ../../user_source/hdl_source/handcnn/handcnn_normalize.v ../../user_source/hdl_source/handfixed/handfixed_preprocess.v handfixed_program.v handcnn_confidence.v fruitfixed_decode.v fruitfixed_result_filter.v tb_fruitfixed.sv
vsim -onfinish exit -t ps fruit_work.tb_fruitfixed fruit_work.PH1P_PHY_GSR
run -all
quit -code 0 -force
'''
    (out/'run_simulation.tcl').write_text(tcl,encoding='ascii')
    sources=[ROOT/'verification'/name for name in [
        'quantize_fruitcnn.py','generate_fruitfixed_tests.py','check_fruit128_release.py',
        'fruitcnn.py','handcnn_model.py','handcnn_training_utils.py','handfixed_math.py',
        'handfixed_reference.py','export_handfixed_fpga.py']]
    sources += [ROOT/'user_source/hdl_source'/name for name in [
        'handcnn/handcnn_core.v','handcnn/handcnn_normalize.v','handfixed/handfixed_preprocess.v',
        'handfixed/handfixed_background.v','handfixed/handfixed_key_control.v',
        'fruitfixed/fruitfixed_decode.v','fruitfixed/fruitfixed_result_filter.v']]
    sources.append(ROOT/'sim/resnet18_dsp_reference.sv')
    inventory=[]
    for source in sources:
        target=out/'source'/source.relative_to(ROOT)
        target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(source,target)
        inventory.append(dict(path=str(source),snapshot=str(target.resolve()),
                              sha256=hashlib.sha256(source.read_bytes()).hexdigest()))
    (out/'sources.json').write_text(json.dumps(inventory,indent=2),encoding='utf-8')
    print('Generated five-image full pipeline and '+str(len(cases['decoder']))+' decoder cases')


if __name__=='__main__': main()
