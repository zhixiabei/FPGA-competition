// Shared 24-lane W8A16 core. One complete input tensor (<=72 KiB) and one
// <=13.5 KiB weight group fit the same 88 KiB scratch budget as the plan.
// Input/weight bursts allow 16 ordered reads in flight. During convolution
// all operands come from synchronous ERAM; one term is issued per clock.
module handcnn_core(
    input wire clk,rst_n,start,
    input wire [4:0] operation,
    output wire [2:0] group,
    input wire [383:0] descriptor,
    output wire busy,
    output reg done,fault,
    output wire mem_valid,mem_write,
    output wire [31:0] mem_addr,
    output wire [127:0] mem_data,
    input wire mem_ready,mem_rsp_valid,
    input wire [127:0] mem_rsp_data,
    output reg [31:0] cycles,mac_cycles,wait_cycles
);
    localparam IDLE=0,LOAD=1,WEIGHTS=2,COEFF=3,SETUP=4,RUN=5,DRAIN=6,
        SUM_WAIT=7,SCALE=8,NEXT_POS=9,PACK_READ=10,PACK_GET=11,WRITE=12,
        NEXT_GROUP=13,POOL_ADDR=14,POOL_GET=15,POOL_SUM=16,POOL_WRITE=17,POOL_DIVIDE=18,
        SELECT_SUM=19,ADD_BIAS=20,SHIFT_SUM=21;
    reg [4:0] state;
    reg [2:0] active_group;
    assign group=state==IDLE ? 3'd0 : active_group;
    assign busy=state!=IDLE;
    wire kind=descriptor[0];
    wire relu=descriptor[8];
    wire [3:0] kernel=descriptor[19:16],stride=descriptor[27:24],padding=descriptor[35:32];
    wire [9:0] cin=descriptor[57:48],cout=descriptor[73:64];
    wire [7:0] iw=descriptor[87:80],ih=descriptor[95:88],ow=descriptor[103:96],oh=descriptor[111:104];
    wire [15:0] src_plane=descriptor[127:112],dst_plane=descriptor[143:128];
    wire [31:0] src=descriptor[175:144],dst=descriptor[207:176];
    wire [31:0] weights_base=descriptor[239:208],coeff_base=descriptor[271:240];
    // Shape products and group offsets are computed by the exporter, so address
    // generation never consumes the DSPs reserved for the MAC lanes.
    wire [15:0] input_words=descriptor[287:272],program_terms=descriptor[303:288];
    wire [15:0] program_area=descriptor[319:304];
    wire [31:0] group_dst=descriptor[351:320];
    reg [15:0] issued,received,total;
    wire burst=state==LOAD || state==WEIGHTS || state==COEFF;
    wire can_read=burst && issued<total && issued-received<16;
    wire [31:0] read_base=state==LOAD ? src : state==WEIGHTS ? weights_base : coeff_base;
    assign mem_valid=can_read || state==WRITE || state==POOL_WRITE;
    assign mem_write=state==WRITE || state==POOL_WRITE;
    reg [31:0] write_address;
    reg [127:0] store_word;
    assign mem_addr=mem_write ? write_address : read_base+{12'd0,issued,4'd0};
    assign mem_data=store_word;
    (* ram_style="bram" *) reg [127:0] input_cache[0:4607];
    // A 576-deep wide ERAM rounds up to 1024 rows. Keep the final 64
    // terms in distributed RAM instead of wasting another five ERAMs.
    (* ram_style="bram" *) reg [191:0] weight_cache[0:511];
    reg [9:0] term,terms,ic;
    reg [127:0] first_weight_word,input_q;
    reg [191:0] weight_main_q;
    wire [191:0] weight_tail_q;
    // Explicit vendor DRAM prevents the mapper re-promoting the small tail
    // to five mostly empty ERAMs when its read is independently registered.
    PH1P_LOGIC_DRAM #(.DATA_WIDTH_W(192),.DATA_WIDTH_R(192),
        .ADDR_WIDTH_W(6),.ADDR_WIDTH_R(6),.DATA_DEPTH_W(64),.DATA_DEPTH_R(64),
        .READREG("ENABLE"),.RESETMODE("ASYNC"),.INIT_FILE("NONE"),.FILL_ALL("NONE")) weight_tail(
        .di({mem_rsp_data[63:0],first_weight_word}),.waddr(received[6:1]),
        .we(state==WEIGHTS && mem_rsp_valid && received[0] && received[10]),.wclk(clk),
        .raddr(term[5:0]),.rclk(clk),.rrst(!rst_n),.rce(1'b1),.rdo(),.rdoq(weight_tail_q));
    reg weight_select_tail;
    wire [191:0] weight_q=weight_select_tail ? weight_tail_q : weight_main_q;
    reg signed [39:0] biases[0:23];
    reg [5:0] shifts[0:23];
    reg [15:0] act_address;
    reg [3:0] kx,ky;
    reg [15:0] channel_offset;
    reg [7:0] ox,oy;
    reg [15:0] pos,tile_start,area;
    reg [4:0] lane,store_lane;
    reg [2:0] pack_index;
    reg [15:0] store_addr;
    (* ram_style="bram" *) reg [15:0] output_cache[0:191];
    reg [15:0] output_q;
    reg pipe_valid,pipe_first,pipe_padding;
    reg [2:0] pipe_offset;
    wire signed [15:0] activation=pipe_padding ? 16'sd0 : input_q[pipe_offset*16+:16];
    wire [24*54-1:0] sums;
    wire mac_enable=pipe_valid && (state==RUN || state==DRAIN);
    genvar n;
    generate for(n=0;n<24;n=n+1) begin: lanes
        resnet_ph1p_dsp #(.ACTIVATION_WIDTH(16),.WEIGHT_WIDTH(8)) mac(
            .clk(clk),.rst_n(rst_n),.enable(mac_enable),.activation(activation),
            .weight(weight_q[n*8+:8]),.opctrl(pipe_first ? 11'h404 : 11'h40c),
            .muxctrl(pipe_first ? 7'h02 : 7'h22),.result(sums[n*54+:54]));
    end endgenerate
    function [15:0] row_offset;
        input [7:0] y,width;
        reg [15:0] v;
        begin v={8'd0,y};case(width)
            128:row_offset=v<<7;96:row_offset=(v<<6)+(v<<5);
            64:row_offset=v<<6;48:row_offset=(v<<5)+(v<<4);
            32:row_offset=v<<5;24:row_offset=(v<<4)+(v<<3);
            16:row_offset=v<<4;12:row_offset=(v<<3)+(v<<2);
            8:row_offset=v<<3;6:row_offset=(v<<2)+(v<<1);
            4:row_offset=v<<2;2:row_offset=v<<1;1:row_offset=v;
            default:row_offset=0;
        endcase end
    endfunction
    wire signed [10:0] ix=$signed({2'd0,ox,1'b0})-$signed({7'd0,padding})+$signed({7'd0,kx});
    wire signed [10:0] iy=$signed({2'd0,oy,1'b0})-$signed({7'd0,padding})+$signed({7'd0,ky});
    wire signed [10:0] sx=stride==2 ? ix : $signed({3'd0,ox})-$signed({7'd0,padding})+$signed({7'd0,kx});
    wire signed [10:0] sy=stride==2 ? iy : $signed({3'd0,oy})-$signed({7'd0,padding})+$signed({7'd0,ky});
    wire outside=sx<0 || sy<0 || sx>=iw || sy>=ih;
    wire [15:0] conv_address=channel_offset+row_offset(sy[7:0],iw)+sx[7:0];
    reg [9:0] pool_channel;
    reg [15:0] pool_offset;
    reg signed [23:0] pool_sum;
    wire [7:0] pool_y={6'd0,pool_channel[1],1'b0}+pool_channel[1]+ky;
    wire [7:0] pool_x={6'd0,pool_channel[0],1'b0}+pool_channel[0]+kx;
    wire [15:0] pool_address=pool_offset+row_offset(pool_y,8'd6)+pool_x;
    wire [15:0] ram_address=state==RUN ? (outside ? 16'd0 : conv_address) : pool_address;
    reg [2:0] pool_byte;
    wire signed [15:0] pool_value=input_q[pool_byte*16+:16];
    wire signed [23:0] pool_total=pool_sum+pool_value;
    reg [18:0] divide_n,divide_q;
    reg [3:0] divide_rem;
    reg [4:0] divide_step;
    reg divide_negative;
    wire [4:0] divide_trial={divide_rem,divide_n[18]};
    wire [18:0] divide_next_q={divide_q[17:0],divide_trial>=9};
    wire [15:0] divide_answer=divide_negative ? -divide_next_q[15:0] : divide_next_q[15:0];
    reg signed [53:0] selected_sum,biased,scaled;
    reg signed [39:0] selected_bias;
    reg [5:0] selected_shift;
    wire [15:0] saturated=relu && scaled<0 ? 16'd0 : scaled>32767 ? 16'h7fff : scaled< -32768 ? 16'h8000 : scaled[15:0];
    wire [9:0] output_channel={group,4'd0}+{group,3'd0}+store_lane;
    wire [9:0] lane_channel={group,4'd0}+{group,3'd0}+lane;
    always @(posedge clk) begin
        if(state==LOAD && mem_rsp_valid) input_cache[received]<=mem_rsp_data;
        if(state==WEIGHTS && mem_rsp_valid && received[0]) begin
            if(!received[10]) weight_cache[received[9:1]]<={mem_rsp_data[63:0],first_weight_word};
        end
        input_q<=input_cache[ram_address[15:3]];
        weight_main_q<=weight_cache[term[8:0]];
        weight_select_tail<=term[9];
        if(state==SCALE) output_cache[{lane,pos[2:0]}]<=lane_channel<cout ? saturated : 16'd0;
        output_q<=output_cache[{store_lane,pack_index}];
    end
    integer j;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;active_group<=0;done<=0;fault<=0;issued<=0;received<=0;total<=0;
            first_weight_word<=0;term<=0;terms<=0;ic<=0;kx<=0;ky<=0;
            channel_offset<=0;ox<=0;oy<=0;pos<=0;tile_start<=0;area<=0;lane<=0;
            store_lane<=0;pack_index<=0;store_addr<=0;store_word<=0;write_address<=0;
            pipe_valid<=0;pipe_first<=0;pipe_padding<=0;pipe_offset<=0;
            pool_channel<=0;pool_offset<=0;pool_sum<=0;pool_byte<=0;
            divide_n<=0;divide_q<=0;divide_rem<=0;divide_step<=0;divide_negative<=0;
            selected_sum<=0;selected_bias<=0;selected_shift<=0;biased<=0;scaled<=0;
            cycles<=0;mac_cycles<=0;wait_cycles<=0;
            for(j=0;j<24;j=j+1) begin biases[j]<=0;shifts[j]<=0;end
        end else begin
            done<=0;
            if(busy) cycles<=cycles+1'b1;
            if(mac_enable) mac_cycles<=mac_cycles+1'b1;
            if(mem_valid && !mem_ready) wait_cycles<=wait_cycles+1'b1;
            if(can_read && mem_ready) issued<=issued+1'b1;
            if(burst && mem_rsp_valid) received<=received+1'b1;
            case(state)
                IDLE:if(start) begin
                    active_group<=0;issued<=0;received<=0;total<=input_words;
                    terms<=program_terms;area<=program_area;state<=LOAD;
                    if(input_words>4608 || input_words==0 || (!kind && program_terms>576) || cin==0 || cout==0) begin
                        fault<=1;done<=1;state<=IDLE;
                    end
                end
                LOAD:if(mem_rsp_valid && received==total-1) begin
                    issued<=0;received<=0;total<=terms<<1;
                    state<=kind ? POOL_ADDR : WEIGHTS;
                    pool_channel<=0;pool_offset<=0;kx<=0;ky<=0;pool_sum<=0;
                end
                WEIGHTS:begin
                    if(mem_rsp_valid && !received[0]) first_weight_word<=mem_rsp_data;
                    if(mem_rsp_valid && received==total-1) begin
                        issued<=0;received<=0;total<=12;state<=COEFF;
                    end
                end
                COEFF:if(mem_rsp_valid) begin
                    biases[{received[3:0],1'b0}]<=mem_rsp_data[39:0];
                    shifts[{received[3:0],1'b0}]<=mem_rsp_data[45:40];
                    biases[{received[3:0],1'b0}+1]<=mem_rsp_data[103:64];
                    shifts[{received[3:0],1'b0}+1]<=mem_rsp_data[109:104];
                    if(received==11) begin
                        ox<=0;oy<=0;pos<=0;tile_start<=0;state<=SETUP;
                    end
                end
                SETUP:begin
                    term<=0;ic<=0;kx<=0;ky<=0;channel_offset<=0;pipe_valid<=0;state<=RUN;
                end
                RUN:begin
                    pipe_valid<=1;pipe_first<=term==0;pipe_padding<=outside;pipe_offset<=ram_address[2:0];
                    if(term==terms-1) state<=DRAIN;
                    else begin
                        term<=term+1'b1;
                        if(kx==kernel-1) begin
                            kx<=0;
                            if(ky==kernel-1) begin ky<=0;ic<=ic+1'b1;channel_offset<=channel_offset+src_plane;end
                            else ky<=ky+1'b1;
                        end else kx<=kx+1'b1;
                    end
                end
                DRAIN:begin pipe_valid<=0;state<=SUM_WAIT;end
                SUM_WAIT:begin lane<=0;state<=SELECT_SUM;end
                SELECT_SUM:begin selected_sum<=sums[lane*54+:54];selected_bias<=biases[lane];selected_shift<=shifts[lane];state<=ADD_BIAS;end
                ADD_BIAS:begin biased<=selected_sum+{{14{selected_bias[39]}},selected_bias};state<=SHIFT_SUM;end
                SHIFT_SUM:begin scaled<=biased>>>selected_shift;state<=SCALE;end
                SCALE:if(lane==23) state<=NEXT_POS;else begin lane<=lane+1'b1;state<=SELECT_SUM;end
                NEXT_POS:begin
                    if(ox==ow-1) begin ox<=0;oy<=oy+1'b1;end else ox<=ox+1'b1;
                    if(pos[2:0]==7 || pos==area-1) begin
                        store_lane<=0;pack_index<=0;store_addr<=0;store_word<=0;
                        write_address<=group_dst+{15'd0,tile_start,1'b0};
                        state<=PACK_READ;
                    end else begin pos<=pos+1'b1;state<=SETUP;end
                end
                PACK_READ:state<=PACK_GET;
                PACK_GET:begin
                    store_word[pack_index*16+:16]<=tile_start+pack_index<area ? output_q : 16'd0;
                    if(pack_index==7) state<=WRITE;
                    else begin pack_index<=pack_index+1'b1;state<=PACK_READ;end
                end
                WRITE:if(mem_ready) begin
                    if(store_lane==23 || output_channel==cout-1) begin
                        if(pos==area-1) state<=NEXT_GROUP;
                        else begin pos<=pos+1'b1;tile_start<=pos+1'b1;state<=SETUP;end
                    end else begin
                        store_lane<=store_lane+1'b1;pack_index<=0;store_word<=0;
                        write_address<=write_address+(dst_plane<<1);state<=PACK_READ;
                    end
                end
                NEXT_GROUP:if(({group,4'd0}+{group,3'd0}+24)>=cout) begin done<=1;state<=IDLE;end
                    else begin active_group<=active_group+1'b1;issued<=0;received<=0;total<=terms<<1;state<=WEIGHTS;end
                POOL_ADDR:begin pool_byte<=pool_address[2:0];state<=POOL_GET;end
                POOL_GET:state<=POOL_SUM;
                POOL_SUM:begin
                    pool_sum<=pool_sum+pool_value;
                    if(kx==2 && ky==2) begin
                        // Restoring constant division replaces a long reciprocal
                        // multiply path; 19 clocks cost <0.12 ms per full pool.
                        divide_n<=pool_total<0 ? -pool_total : pool_total;
                        divide_negative<=pool_total<0;divide_q<=0;divide_rem<=0;divide_step<=0;
                        write_address<=dst+{18'd0,pool_channel,4'd0};state<=POOL_DIVIDE;
                    end else begin
                        if(kx==2) begin kx<=0;ky<=ky+1'b1;end else kx<=kx+1'b1;
                        state<=POOL_ADDR;
                    end
                end
                POOL_DIVIDE:begin
                    divide_n<={divide_n[17:0],1'b0};divide_q<=divide_next_q;
                    divide_rem<=divide_trial>=9 ? divide_trial-9 : divide_trial;
                    if(divide_step==18) begin store_word<={112'd0,divide_answer};state<=POOL_WRITE;end
                    else divide_step<=divide_step+1'b1;
                end
                POOL_WRITE:if(mem_ready) begin
                    if(pool_channel==cout-1) begin done<=1;state<=IDLE;end
                    else begin
                        pool_channel<=pool_channel+1'b1;
                        if(pool_channel[1:0]==3) pool_offset<=pool_offset+src_plane;
                        kx<=0;ky<=0;pool_sum<=0;state<=POOL_ADDR;
                    end
                end
            endcase
        end
    end
endmodule
