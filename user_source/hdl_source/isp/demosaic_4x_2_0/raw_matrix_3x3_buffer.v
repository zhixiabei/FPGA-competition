// Coordinate-preserving Bayer windows. Four rotating ERAM rows allow the
// camera to write the next row while the three completed neighbours are read.
// Read one group ahead so interpolation is centred on the OUTPUT coordinate.
// Reflect at image borders (rather than duplicating a different Bayer colour).
module raw_matrix_3x3_buffer #(
    parameter IMG_HEIGHT=1080,
    parameter IMG_WIDTH=1920,
    parameter data_complete_delay=50
) (
    input wire I_clk,input wire I_rst_n,
    input wire [39:0] axi4s_video_tdata,
    input wire [9:0] axi4s_video_tdest,
    input wire axi4s_video_tlast,axi4s_video_tvalid,axi4s_video_tuser,
    output wire axi4s_video_tready,
    output reg O_tlast,O_tuser,O_tvalid,
    input wire O_tready,
    output reg bayer_ypos,
    output reg [95:0] matrix_last_line,matrix_cur_line,matrix_next_line
);
    localparam integer GROUPS=IMG_WIDTH/4;
    localparam integer AB=$clog2(GROUPS);
    localparam integer YB=$clog2(IMG_HEIGHT);
    reg [AB-1:0] write_x,read_x;
    reg [YB-1:0] write_y,read_y;
    reg frame_active,sof_seen,reading,bottom_pending;
    wire new_frame=axi4s_video_tuser && !sof_seen;
    wire accept=axi4s_video_tvalid && (frame_active || new_frame);
    wire [AB-1:0] wx=new_frame ? {AB{1'b0}} : write_x;
    wire [YB-1:0] wy=new_frame ? {YB{1'b0}} : write_y;
    wire line_done=accept && wx==GROUPS-1;
    wire row_ready=line_done && wy!=0;
    wire [31:0] raw_group={
        axi4s_video_tdata[9:2],axi4s_video_tdata[19:12],
        axi4s_video_tdata[29:22],axi4s_video_tdata[39:32]};
    wire [31:0] bank_data[0:3];
    assign axi4s_video_tready=O_tready;

    genvar bank;
    generate for(bank=0;bank<4;bank=bank+1) begin: row_bank
        PH1P_LOGIC_ERAM #(
            .DATA_WIDTH_A(32),.DATA_WIDTH_B(32),
            .ADDR_WIDTH_A(AB),.ADDR_WIDTH_B(AB),
            .DATA_DEPTH_A(GROUPS),.DATA_DEPTH_B(GROUPS),.MODE("DP"),
            .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
            .WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),
            .IMPLEMENT("20K(FAST)"),.CLKMODE("SYNC"),
            .ECC_ENCODE("DISABLE"),.ECC_DECODE("DISABLE"),
            .INIT_FILE("NONE"),.FILL_ALL("NONE")
        ) u_ram (
            .clka(I_clk),.clkb(I_clk),.cea(I_rst_n),.ceb(I_rst_n && reading),
            .ocea(1'b0),.oceb(1'b0),
            .wea(accept && wy[1:0]==bank),.web(1'b0),
            .rsta(1'b0),.rstb(1'b0),.bea(1'b0),.beb(1'b0),
            .addra(wx),.addrb(read_x),.dia(raw_group),.dib(32'd0),
            .doa(),.dob(bank_data[bank]),.ecc_sbiterr(),.ecc_dbiterr(),
            .ecc_sbiterrinj(1'b0),.ecc_dbiterrinj(1'b0)
        );
    end endgenerate

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            write_x<=0;write_y<=0;frame_active<=0;sof_seen<=0;
        end else begin
            sof_seen<=axi4s_video_tuser;
            if(new_frame) begin write_x<=0;write_y<=0;frame_active<=1;end
            if(accept) begin
                if(wx==GROUPS-1) begin
                    write_x<=0;
                    if(wy==IMG_HEIGHT-1) frame_active<=0;
                    else write_y<=wy+1'b1;
                end else write_x<=wx+1'b1;
            end
        end
    end

    // Each completed input row supplies the bottom neighbour of row y-1.
    // The final reflected row is read during vertical blanking.
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            reading<=0;read_x<=0;read_y<=0;bottom_pending<=0;
        end else if(new_frame) begin
            reading<=0;read_x<=0;read_y<=0;bottom_pending<=0;
        end else begin
            if(reading) begin
                if(read_x==GROUPS-1) begin
                    read_x<=0;reading<=0;
                    if(bottom_pending) begin
                        read_y<=IMG_HEIGHT-1;reading<=1;bottom_pending<=0;
                    end
                end else read_x<=read_x+1'b1;
            end
            if(row_ready) begin
                read_y<=wy-1'b1;read_x<=0;reading<=1;
                if(wy==IMG_HEIGHT-1) bottom_pending<=1;
            end
        end
    end

    reg rd_valid;
    reg [AB-1:0] rd_x;
    reg [YB-1:0] rd_y;
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin rd_valid<=0;rd_x<=0;rd_y<=0;end
        else begin
            rd_valid<=reading && !new_frame;
            rd_x<=read_x;rd_y<=read_y;
        end
    end
    wire [1:0] top_bank=rd_y==0 ? 2'd1 : rd_y[1:0]-2'd1;
    wire [1:0] bottom_bank=rd_y==IMG_HEIGHT-1 ?
        rd_y[1:0]-2'd1 : rd_y[1:0]+2'd1;
    wire [31:0] top_word=bank_data[top_bank];
    wire [31:0] mid_word=bank_data[rd_y[1:0]];
    wire [31:0] bot_word=bank_data[bottom_bank];
    reg [31:0] top_hold,mid_hold,bot_hold;
    reg [7:0] top_left,mid_left,bot_left;
    reg [AB-1:0] hold_x;
    reg [YB-1:0] hold_y;
    reg flush_last;
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            O_tvalid<=0;O_tuser<=0;O_tlast<=0;bayer_ypos<=0;
            matrix_last_line<=0;matrix_cur_line<=0;matrix_next_line<=0;
            top_hold<=0;mid_hold<=0;bot_hold<=0;
            top_left<=0;mid_left<=0;bot_left<=0;hold_x<=0;hold_y<=0;
            flush_last<=0;
        end else begin
            O_tvalid<=0;O_tuser<=0;O_tlast<=0;
            flush_last<=rd_valid && rd_x==GROUPS-1;
            if(new_frame) flush_last<=0;
            if(rd_valid && !new_frame) begin
                top_hold<=top_word;mid_hold<=mid_word;bot_hold<=bot_word;
                hold_x<=rd_x;hold_y<=rd_y;
                // For x=0 reflect x=-1 to x=1, preserving CFA phase.
                top_left<=rd_x==0 ? top_word[23:16] : top_hold[7:0];
                mid_left<=rd_x==0 ? mid_word[23:16] : mid_hold[7:0];
                bot_left<=rd_x==0 ? bot_word[23:16] : bot_hold[7:0];
                if(rd_x!=0) begin
                    matrix_last_line<={24'd0,top_left,top_hold,top_word[31:24],24'd0};
                    matrix_cur_line <={24'd0,mid_left,mid_hold,mid_word[31:24],24'd0};
                    matrix_next_line<={24'd0,bot_left,bot_hold,bot_word[31:24],24'd0};
                    O_tvalid<=1;O_tuser<=hold_y==0 && hold_x==0;
                    bayer_ypos<=hold_y[0];
                end
            end
            if(flush_last && !new_frame) begin
                matrix_last_line<={24'd0,top_left,top_hold,top_hold[15:8],24'd0};
                matrix_cur_line <={24'd0,mid_left,mid_hold,mid_hold[15:8],24'd0};
                matrix_next_line<={24'd0,bot_left,bot_hold,bot_hold[15:8],24'd0};
                O_tvalid<=1;O_tlast<=1;bayer_ypos<=hold_y[0];
            end
        end
    end
endmodule
