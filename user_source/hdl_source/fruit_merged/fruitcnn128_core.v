// RGB128 signed A12 activations in INT16 DDR.
// Shared 24-lane W8A16 core. Three convolution rows are prefetched into a
// compact cache; the four-beat cache remains for the 1x1 and pooling tails.
// This keeps the live video line buffers while avoiding per-term DDR stalls.
module fruitcnn128_core(
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
        SELECT_SUM=19,ADD_BIAS=20,SHIFT_SUM=21,
        ACT_REQUEST=22,ACT_WAIT=23,ACT_RUN=24,COEFF_READ=25,ROW_LOAD=26;
    reg [4:0] state;
    reg [2:0] active_group;
    // The model ROM is indexed by group. Do not feed the high-fanout state
    // decode back through that ROM into the address/cache-hit datapath.
    // Clear the group on completion so IDLE still presents group zero.
    assign group=active_group;
    assign busy=state!=IDLE;
    wire kind=descriptor[0];
    wire relu=descriptor[8];
    // Geometry is constant for an operation, including all output groups.
    // Capture it on the accepted start edge so the live model-ROM decode
    // cannot feed through address generation and cache hit into term advance.
    // Group-dependent weight/coefficient/output addresses remain live.
    reg [3:0] kernel,padding;
    reg stride_two;
    wire [9:0] cin=descriptor[57:48],cout=descriptor[73:64];
    reg [7:0] iw,ih;
    wire [7:0] ow=descriptor[103:96],oh=descriptor[111:104];
    reg [15:0] src_plane;
    wire [15:0] dst_plane=descriptor[143:128];
    wire [31:0] src=descriptor[175:144],dst=descriptor[207:176];
    wire [31:0] weights_base=descriptor[239:208],coeff_base=descriptor[271:240];
    // Shape products and group offsets are computed by the exporter, so address
    // generation never consumes the DSPs reserved for the MAC lanes.
    wire [15:0] input_words=descriptor[287:272],program_terms=descriptor[303:288];
    wire [15:0] program_area=descriptor[319:304];
    wire [31:0] group_dst=descriptor[351:320];
    reg [15:0] issued,received,total;
    wire burst=state==WEIGHTS || state==COEFF || state==ROW_LOAD;
    wire can_read=burst && issued<total && issued-received<16;
    wire [31:0] read_base=state==WEIGHTS ? weights_base : coeff_base;
    assign mem_valid=can_read || state==ACT_REQUEST || state==WRITE || state==POOL_WRITE;
    assign mem_write=state==WRITE || state==POOL_WRITE;
    reg [31:0] write_address;
    reg [127:0] store_word;
    reg [31:0] activation_read_address;
    wire [31:0] row_read_address;
    assign mem_addr=mem_write ? write_address :
                    state==ROW_LOAD ? row_read_address :
                    state==ACT_REQUEST ? activation_read_address :
                    read_base+{12'd0,issued,4'd0};
    assign mem_data=store_word;
    // A 576-deep wide ERAM rounds up to 1024 rows. Keep the final 64
    // terms in distributed RAM instead of wasting another five ERAMs.
    (* ram_style="bram" *) reg [191:0] weight_cache[0:511];
    reg [9:0] term,terms,ic;
    reg [127:0] first_weight_word;
    reg [95:0] input_q;
    // Maximum footprint: 3 rows * 12 channels * 8 words at the 64-wide
    // layer. Other layers trade row width for channel count and also fit.
    (* ram_style="bram" *) reg [95:0] row_cache[0:287];
    reg [95:0] row_cache_q;
    reg [95:0] activation_cache;
    reg [95:0] activation_cache_1,activation_cache_2,activation_cache_3;
    reg [12:0] activation_cache_word;
    reg [12:0] activation_cache_word_1,activation_cache_word_2,activation_cache_word_3;
    reg [12:0] activation_request_word;
    reg activation_cache_valid;
    reg activation_cache_valid_1,activation_cache_valid_2,activation_cache_valid_3;
    reg [1:0] activation_replace;
    reg [2:0] activation_offset;
    reg [4:0] activation_return_state;
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
    reg [4:0] lane,store_lane;
    wire [45:0] coefficient_q;
    // Bias and shift coefficients are loaded once per output group. Keeping
    // the 24 entries in embedded RAM releases 1104 slice registers while
    // preserving their exact signed widths.
    PH1P_LOGIC_ERAM #(
        .DATA_WIDTH_A(46),.DATA_WIDTH_B(46),.ADDR_WIDTH_A(5),.ADDR_WIDTH_B(5),
        .DATA_DEPTH_A(32),.DATA_DEPTH_B(32),.MODE("DP"),
        .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
        .WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),
        .IMPLEMENT("20K(FAST)"),.CLKMODE("SYNC"),
        .ECC_ENCODE("DISABLE"),.ECC_DECODE("DISABLE"),
        .INIT_FILE("NONE"),.FILL_ALL("NONE")
    ) coefficient_memory(
        .clka(clk),.clkb(clk),.cea(state==COEFF && mem_rsp_valid),.ceb(1'b1),
        .ocea(1'b0),.oceb(1'b0),
        .wea(state==COEFF && mem_rsp_valid),.web(state==COEFF && mem_rsp_valid),
        .rsta(1'b0),.rstb(1'b0),.bea(1'b0),.beb(1'b0),
        .addra({received[3:0],1'b0}),
        .addrb(state==COEFF ? {received[3:0],1'b1} : {1'b0,lane}),
        .dia({mem_rsp_data[45:40],mem_rsp_data[39:0]}),
        .dib({mem_rsp_data[109:104],mem_rsp_data[103:64]}),
        .doa(),.dob(coefficient_q),.ecc_sbiterr(),.ecc_dbiterr(),
        .ecc_sbiterrinj(1'b0),.ecc_dbiterrinj(1'b0)
    );
    reg [15:0] act_address;
    reg [3:0] kx,ky;
    reg [15:0] channel_offset;
    reg [8:0] cache_channel_offset;
    reg [15:0] prefetch_channel_offset;
    reg [9:0] prefetch_channel;
    reg [3:0] prefetch_row;
    reg [4:0] prefetch_word;
    reg [7:0] ox,oy;
    reg [15:0] pos,tile_start,area;
    reg [2:0] pack_index;
    reg [15:0] store_addr;
    (* ram_style="bram" *) reg [15:0] output_cache[0:191];
    reg [15:0] output_q;
    reg pipe_valid,pipe_first,pipe_padding;
    reg [2:0] pipe_offset;
    wire [95:0] convolution_input=kernel==3 ? row_cache_q : input_q;
    wire signed [15:0] activation=pipe_padding ? 16'sd0 :
        {{4{convolution_input[pipe_offset*12+11]}},convolution_input[pipe_offset*12+:12]};
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
    function [8:0] row_cache_words;
        input [9:0] channels;
        input [7:0] width;
        reg [8:0] per_row;
        begin
            case(width)
                128:per_row=channels<<4;
                64:per_row=channels<<3;
                32:per_row=channels<<2;
                16:per_row=channels<<1;
                8,6,4,2,1:per_row=channels;
                default:per_row=0;
            endcase
            row_cache_words=per_row+(per_row<<1);
        end
    endfunction
    function [8:0] cache_row_offset;
        input [3:0] row;
        input [7:0] width;
        begin
            case(width)
                128:cache_row_offset={row,4'd0};
                64:cache_row_offset={1'd0,row,3'd0};
                32:cache_row_offset={2'd0,row,2'd0};
                16:cache_row_offset={3'd0,row,1'd0};
                8,6,4,2,1:cache_row_offset={4'd0,row};
                default:cache_row_offset=0;
            endcase
        end
    endfunction
    wire signed [10:0] ix=$signed({2'd0,ox,1'b0})-$signed({7'd0,padding})+$signed({7'd0,kx});
    wire signed [10:0] iy=$signed({2'd0,oy,1'b0})-$signed({7'd0,padding})+$signed({7'd0,ky});
    wire signed [10:0] sx=stride_two ? ix : $signed({3'd0,ox})-$signed({7'd0,padding})+$signed({7'd0,kx});
    wire signed [10:0] sy=stride_two ? iy : $signed({3'd0,oy})-$signed({7'd0,padding})+$signed({7'd0,ky});
    wire outside=sx<0 || sy<0 || sx>=iw || sy>=ih;
    wire [15:0] conv_address=channel_offset+row_offset(sy[7:0],iw)+sx[7:0];
    wire [8:0] row_cache_address=outside ? 9'd0 : cache_channel_offset+
        cache_row_offset(ky,iw)+{1'd0,sx[7:3]};
    wire signed [10:0] prefetch_y=(stride_two ? $signed({2'd0,oy,1'b0}) :
        $signed({3'd0,oy}))-$signed({7'd0,padding})+$signed({7'd0,prefetch_row});
    wire [7:0] prefetch_source_y=(prefetch_y<0 || prefetch_y>=ih) ? 8'd0 : prefetch_y[7:0];
    wire [4:0] prefetch_words_per_row=({1'b0,iw}+8'd7)>>3;
    assign row_read_address=src+
        {15'd0,(prefetch_channel_offset+row_offset(prefetch_source_y,iw)+
        {prefetch_word,3'd0}),1'b0};
    wire conv_cache_hit_0=activation_cache_valid && activation_cache_word==conv_address[15:3];
    wire conv_cache_hit_1=activation_cache_valid_1 && activation_cache_word_1==conv_address[15:3];
    wire conv_cache_hit_2=activation_cache_valid_2 && activation_cache_word_2==conv_address[15:3];
    wire conv_cache_hit_3=activation_cache_valid_3 && activation_cache_word_3==conv_address[15:3];
    wire [95:0] conv_cache_data=conv_cache_hit_0 ? activation_cache :
        conv_cache_hit_1 ? activation_cache_1 :
        conv_cache_hit_2 ? activation_cache_2 : activation_cache_3;
    wire cached_term=outside ||
        conv_cache_hit_0 || conv_cache_hit_1 || conv_cache_hit_2 || conv_cache_hit_3;
    // Both a cache hit and a completed DDR fetch consume exactly one term.
    // Keep one counter-update path; ACT_RUN must return to RUN afterwards.
    wire consume_term=(state==RUN && (kernel==3 || cached_term)) || state==ACT_RUN;
    reg [9:0] pool_channel;
    reg [15:0] pool_offset;
    reg signed [23:0] pool_sum;
    wire [7:0] pool_y={5'd0,pool_channel[1],2'd0}+ky;
    wire [7:0] pool_x={5'd0,pool_channel[0],2'd0}+kx;
    wire [15:0] pool_address=pool_offset+row_offset(pool_y,8'd8)+pool_x;
    wire pool_cache_hit_0=activation_cache_valid && activation_cache_word==pool_address[15:3];
    wire pool_cache_hit_1=activation_cache_valid_1 && activation_cache_word_1==pool_address[15:3];
    wire pool_cache_hit_2=activation_cache_valid_2 && activation_cache_word_2==pool_address[15:3];
    wire pool_cache_hit_3=activation_cache_valid_3 && activation_cache_word_3==pool_address[15:3];
    wire pool_cached=pool_cache_hit_0 || pool_cache_hit_1 || pool_cache_hit_2 || pool_cache_hit_3;
    wire [95:0] pool_cache_data=pool_cache_hit_0 ? activation_cache :
        pool_cache_hit_1 ? activation_cache_1 :
        pool_cache_hit_2 ? activation_cache_2 : activation_cache_3;
    reg [2:0] pool_byte;
    wire signed [15:0] pool_value={{4{input_q[pool_byte*12+11]}},input_q[pool_byte*12+:12]};
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
    wire [15:0] saturated=relu && scaled<0 ? 16'd0 : relu && scaled>2047 ? 16'd2047 : scaled>32767 ? 16'h7fff : scaled< -32768 ? 16'h8000 : scaled[15:0];
    wire [9:0] output_channel={group,4'd0}+{group,3'd0}+store_lane;
    wire [9:0] lane_channel={group,4'd0}+{group,3'd0}+lane;
    function [95:0] pack_activations;
        input [127:0] word;
        begin
            pack_activations={word[112+:12],word[96+:12],word[80+:12],word[64+:12],
                              word[48+:12],word[32+:12],word[16+:12],word[0+:12]};
        end
    endfunction
    always @(posedge clk) begin
        if(state==ROW_LOAD && mem_rsp_valid)
            row_cache[received[8:0]]<=pack_activations(mem_rsp_data);
        if(state==WEIGHTS && mem_rsp_valid && received[0]) begin
            if(!received[10]) weight_cache[received[9:1]]<={mem_rsp_data[63:0],first_weight_word};
        end
        weight_main_q<=weight_cache[term[8:0]];
        weight_select_tail<=term[9];
        if(state==RUN && kernel==3) row_cache_q<=row_cache[row_cache_address];
        if(state==SCALE) output_cache[{lane,pos[2:0]}]<=lane_channel<cout ? saturated : 16'd0;
        output_q<=output_cache[{store_lane,pack_index}];
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;active_group<=0;done<=0;fault<=0;issued<=0;received<=0;total<=0;
            kernel<=0;padding<=0;stride_two<=0;iw<=0;ih<=0;src_plane<=0;
            first_weight_word<=0;term<=0;terms<=0;ic<=0;kx<=0;ky<=0;
            channel_offset<=0;cache_channel_offset<=0;ox<=0;oy<=0;pos<=0;tile_start<=0;area<=0;lane<=0;
            store_lane<=0;pack_index<=0;store_addr<=0;store_word<=0;write_address<=0;
            pipe_valid<=0;pipe_first<=0;pipe_padding<=0;pipe_offset<=0;
            pool_channel<=0;pool_offset<=0;pool_sum<=0;pool_byte<=0;
            divide_n<=0;divide_q<=0;divide_rem<=0;divide_step<=0;divide_negative<=0;
            selected_sum<=0;selected_bias<=0;selected_shift<=0;biased<=0;scaled<=0;
            activation_read_address<=0;activation_cache<=0;activation_cache_word<=0;activation_request_word<=0;
            activation_cache_1<=0;activation_cache_2<=0;activation_cache_3<=0;
            activation_cache_word_1<=0;activation_cache_word_2<=0;activation_cache_word_3<=0;
            activation_cache_valid<=0;activation_cache_valid_1<=0;
            activation_cache_valid_2<=0;activation_cache_valid_3<=0;activation_replace<=0;
            activation_offset<=0;activation_return_state<=0;
            prefetch_channel_offset<=0;prefetch_channel<=0;prefetch_row<=0;prefetch_word<=0;
            cycles<=0;mac_cycles<=0;wait_cycles<=0;
        end else begin
            done<=0;
            if(busy) cycles<=cycles+1'b1;
            if(mac_enable) mac_cycles<=mac_cycles+1'b1;
            if(mem_valid && !mem_ready) wait_cycles<=wait_cycles+1'b1;
            if(can_read && mem_ready) issued<=issued+1'b1;
            if(burst && mem_rsp_valid) received<=received+1'b1;
            if(state==ROW_LOAD && can_read && mem_ready) begin
                if(prefetch_word==prefetch_words_per_row-1'b1) begin
                    prefetch_word<=0;
                    if(prefetch_row==kernel-1) begin
                        prefetch_row<=0;
                        prefetch_channel<=prefetch_channel+1'b1;
                        prefetch_channel_offset<=prefetch_channel_offset+src_plane;
                    end else prefetch_row<=prefetch_row+1'b1;
                end else prefetch_word<=prefetch_word+1'b1;
            end
            if((state==ACT_REQUEST && mem_ready && mem_rsp_valid) ||
               (state==ACT_WAIT && mem_rsp_valid)) begin
                case(activation_replace)
                    0:begin activation_cache<=pack_activations(mem_rsp_data);
                        activation_cache_word<=activation_request_word;activation_cache_valid<=1;end
                    1:begin activation_cache_1<=pack_activations(mem_rsp_data);
                        activation_cache_word_1<=activation_request_word;activation_cache_valid_1<=1;end
                    2:begin activation_cache_2<=pack_activations(mem_rsp_data);
                        activation_cache_word_2<=activation_request_word;activation_cache_valid_2<=1;end
                    default:begin activation_cache_3<=pack_activations(mem_rsp_data);
                        activation_cache_word_3<=activation_request_word;activation_cache_valid_3<=1;end
                endcase
                activation_replace<=activation_replace+1'b1;
            end
            if(consume_term && term!=terms-1) begin
                term<=term+1'b1;
                if(kx==kernel-1) begin
                    kx<=0;
                    if(ky==kernel-1) begin
                        ky<=0;ic<=ic+1'b1;channel_offset<=channel_offset+src_plane;
                        if(kernel==3) cache_channel_offset<=cache_channel_offset+
                            cache_row_offset(3,iw);
                    end else ky<=ky+1'b1;
                end else kx<=kx+1'b1;
            end
            case(state)
                IDLE:if(start) begin
                    kernel<=descriptor[19:16];padding<=descriptor[35:32];
                    stride_two<=descriptor[27:24]==4'd2;
                    iw<=descriptor[87:80];ih<=descriptor[95:88];src_plane<=descriptor[127:112];
                    active_group<=0;issued<=0;received<=0;terms<=program_terms;area<=program_area;
                    activation_cache_valid<=0;activation_cache_valid_1<=0;
                    activation_cache_valid_2<=0;activation_cache_valid_3<=0;activation_replace<=0;
                    if(input_words>6144 || input_words==0 || (!kind && program_terms>576) || cin==0 || cout==0) begin
                        fault<=1;done<=1;state<=IDLE;
                    end else if(kind) begin
                        pool_channel<=0;pool_offset<=0;kx<=0;ky<=0;pool_sum<=0;
                        state<=POOL_ADDR;
                    end else begin
                        total<=program_terms<<1;
                        state<=WEIGHTS;
                    end
                end
                WEIGHTS:begin
                    if(mem_rsp_valid && !received[0]) first_weight_word<=mem_rsp_data;
                    if(mem_rsp_valid && received==total-1) begin
                        issued<=0;received<=0;total<=12;state<=COEFF;
                    end
                end
                COEFF:if(mem_rsp_valid) begin
                    if(received==11) begin
                        ox<=0;oy<=0;pos<=0;tile_start<=0;
                        if(kernel==3) begin
                            issued<=0;received<=0;total<=row_cache_words(cin,iw);
                            prefetch_channel_offset<=0;prefetch_channel<=0;
                            prefetch_row<=0;prefetch_word<=0;state<=ROW_LOAD;
                        end else state<=SETUP;
                    end
                end
                ROW_LOAD:if(mem_rsp_valid && received==total-1) state<=SETUP;
                SETUP:begin
                    term<=0;ic<=0;kx<=0;ky<=0;channel_offset<=0;
                    cache_channel_offset<=0;pipe_valid<=0;state<=RUN;
                end
                RUN:begin
                    if(kernel==3 || cached_term) begin
                        if(kernel!=3) input_q<=outside ? 96'd0 : conv_cache_data;
                        pipe_valid<=1;pipe_first<=term==0;pipe_padding<=outside;
                        pipe_offset<=outside ? 3'd0 :
                            kernel==3 ? sx[2:0] : conv_address[2:0];
                        if(term==terms-1) state<=DRAIN;
                    end else begin
                        activation_read_address<=src+{15'd0,conv_address[15:3],4'd0};
                        activation_request_word<=conv_address[15:3];
                        activation_offset<=conv_address[2:0];
                        activation_return_state<=ACT_RUN;
                        pipe_valid<=0;
                        state<=ACT_REQUEST;
                    end
                end
                ACT_REQUEST:if(mem_ready) begin
                    if(mem_rsp_valid) begin
                        input_q<=pack_activations(mem_rsp_data);
                        state<=activation_return_state;
                    end else state<=ACT_WAIT;
                end
                ACT_WAIT:if(mem_rsp_valid) begin
                    input_q<=pack_activations(mem_rsp_data);
                    state<=activation_return_state;
                end
                ACT_RUN:begin
                    pipe_valid<=1;pipe_first<=term==0;pipe_padding<=0;pipe_offset<=activation_offset;
                    if(term==terms-1) state<=DRAIN;
                    else state<=RUN;
                end
                DRAIN:begin pipe_valid<=0;state<=SUM_WAIT;end
                SUM_WAIT:begin lane<=0;state<=COEFF_READ;end
                COEFF_READ:state<=SELECT_SUM;
                SELECT_SUM:begin selected_sum<=sums[lane*54+:54];selected_bias<=coefficient_q[39:0];selected_shift<=coefficient_q[45:40];state<=ADD_BIAS;end
                ADD_BIAS:begin biased<=selected_sum+{{14{selected_bias[39]}},selected_bias};state<=SHIFT_SUM;end
                SHIFT_SUM:begin scaled<=biased>>>selected_shift;state<=SCALE;end
                SCALE:if(lane==23) state<=NEXT_POS;else begin lane<=lane+1'b1;state<=COEFF_READ;end
                NEXT_POS:begin
                    if(ox==ow-1) begin ox<=0;oy<=oy+1'b1;end else ox<=ox+1'b1;
                    if(pos[2:0]==7 || pos==area-1) begin
                        store_lane<=0;pack_index<=0;store_addr<=0;store_word<=0;
                        write_address<=group_dst+{15'd0,tile_start,1'b0};
                        state<=PACK_READ;
                    end else begin
                        pos<=pos+1'b1;
                        if(kernel==3 && ox==ow-1) begin
                            issued<=0;received<=0;total<=row_cache_words(cin,iw);
                            prefetch_channel_offset<=0;prefetch_channel<=0;
                            prefetch_row<=0;prefetch_word<=0;state<=ROW_LOAD;
                        end else state<=SETUP;
                    end
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
                        else begin
                            pos<=pos+1'b1;tile_start<=pos+1'b1;
                            if(kernel==3 && ox==0) begin
                                issued<=0;received<=0;total<=row_cache_words(cin,iw);
                                prefetch_channel_offset<=0;prefetch_channel<=0;
                                prefetch_row<=0;prefetch_word<=0;state<=ROW_LOAD;
                            end else state<=SETUP;
                        end
                    end else begin
                        store_lane<=store_lane+1'b1;pack_index<=0;store_word<=0;
                        write_address<=write_address+(dst_plane<<1);state<=PACK_READ;
                    end
                end
                NEXT_GROUP:if(({group,4'd0}+{group,3'd0}+24)>=cout) begin done<=1;active_group<=0;state<=IDLE;end
                    else begin active_group<=active_group+1'b1;issued<=0;received<=0;total<=terms<<1;state<=WEIGHTS;end
                POOL_ADDR:begin
                    pool_byte<=pool_address[2:0];
                    if(pool_cached) begin
                        input_q<=pool_cache_data;
                        state<=POOL_GET;
                    end else begin
                        activation_read_address<=src+{15'd0,pool_address[15:3],4'd0};
                        activation_request_word<=pool_address[15:3];
                        activation_return_state<=POOL_GET;
                        state<=ACT_REQUEST;
                    end
                end
                POOL_GET:state<=POOL_SUM;
                POOL_SUM:begin
                    pool_sum<=pool_sum+pool_value;
                    if(kx==3 && ky==3) begin
                        // Exact floor(sum/16), matching the 8x8 -> 2x2 pool.
                        store_word<={112'd0,pool_total[19:4]};
                        write_address<=dst+{18'd0,pool_channel,4'd0};state<=POOL_WRITE;
                    end else begin
                        if(kx==3) begin kx<=0;ky<=ky+1'b1;end else kx<=kx+1'b1;
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
