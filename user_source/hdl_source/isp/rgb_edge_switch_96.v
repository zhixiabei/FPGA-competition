// Frame-boundary RGB/Scharr/emboss selector for the camera stream.
// The synchronized mode/parameter snapshot commits on input SOF, including
// SOF before the first valid beat. Data, markers and configuration all have
// eleven registered clocks of latency, and bubbles advance all paths.
module rgb_edge_switch_96 #(
    parameter integer IMG_WIDTH=1280,
    parameter integer IMG_HEIGHT=720,
    parameter integer EDGE_TH=20,
    parameter integer DEFAULT_EDGE_MODE=1
)(
    input wire I_clk,input wire I_rst_n,input wire [11:0] I_effect_config,
    input wire I_tlast,input wire I_tuser,input wire [95:0] I_tdata,
    input wire I_tvalid,
    output wire O_tlast,output wire O_tuser,output wire [95:0] O_tdata,
    output wire O_tvalid,output wire O_edge_mode,
    output wire [11:0] O_effect_config
);
    localparam integer LATENCY=11;
    localparam [11:0] DEFAULT_CONFIG =
        {(DEFAULT_EDGE_MODE!=0) ? 4'd2 : 4'd0, 8'd0};
    reg [11:0] active_config;
    wire [11:0] frame_config = I_tuser ? I_effect_config : active_config;
    wire [95:0] rgb_delayed;
    reg [11:0] config_delay [0:LATENCY-1];
    wire [95:0] edge_data,emboss_data;
    integer i;
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            active_config<=DEFAULT_CONFIG;
            for(i=0;i<LATENCY;i=i+1) config_delay[i]<=DEFAULT_CONFIG;
        end else begin
            if(I_tuser) active_config<=I_effect_config;
            config_delay[0]<=frame_config;
            for(i=1;i<LATENCY;i=i+1) config_delay[i]<=config_delay[i-1];
        end
    end
    // No reset is needed for pixel storage: O_tvalid remains low until all
    // LATENCY clocks have been filled after reset. Shift on bubbles as well.
    // The hardware uses a small ERAM ring and its registered read output.
`ifdef SCHARR_PORTABLE_RAM
    reg [95:0] rgb_delay[0:LATENCY-1];
    integer pixel_stage;
    always @(posedge I_clk) begin
        rgb_delay[0]<=I_tdata;
        for(pixel_stage=1;pixel_stage<LATENCY;pixel_stage=pixel_stage+1)
            rgb_delay[pixel_stage]<=rgb_delay[pixel_stage-1];
    end
    assign rgb_delayed=rgb_delay[LATENCY-1];
`else
    // Read nine samples behind the write pointer; the two-clock RAM read
    // makes the same eleven-clock delay as the portable shift register.
    reg [3:0] rgb_write_address,rgb_read_address;
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin rgb_write_address<=0;rgb_read_address<=7;end
        else begin
            rgb_write_address<=rgb_write_address+1'b1;
            rgb_read_address<=rgb_read_address+1'b1;
        end
    end
    PH1P_LOGIC_ERAM #(
        .DATA_WIDTH_A(96),.DATA_WIDTH_B(96),.ADDR_WIDTH_A(4),.ADDR_WIDTH_B(4),
        .DATA_DEPTH_A(16),.DATA_DEPTH_B(16),.MODE("DP"),
        .REGMODE_A("NOREG"),.REGMODE_B("OUTREG"),
        .WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),
        .IMPLEMENT("20K(FAST)"),.CLKMODE("SYNC"),
        .ECC_ENCODE("DISABLE"),.ECC_DECODE("DISABLE"),
        .INIT_FILE("NONE"),.FILL_ALL("NONE")
    ) u_rgb_delay (
        .clka(I_clk),.clkb(I_clk),.cea(I_rst_n),.ceb(I_rst_n),
        .ocea(1'b0),.oceb(1'b1),.wea(I_rst_n),.web(1'b0),
        .rsta(1'b0),.rstb(1'b0),.bea(1'b0),.beb(1'b0),
        .addra(rgb_write_address),.addrb(rgb_read_address),.dia(I_tdata),.dib(96'd0),
        .doa(),.dob(rgb_delayed),.ecc_sbiterr(),.ecc_dbiterr(),
        .ecc_sbiterrinj(1'b0),.ecc_dbiterrinj(1'b0)
    );
`endif
    scharr_edge_detect_96 #(
        .IMG_WIDTH(IMG_WIDTH),.IMG_HEIGHT(IMG_HEIGHT),.EDGE_TH(EDGE_TH)
    ) u_scharr_edge_detect_96 (
        .I_clk(I_clk),.I_rst_n(I_rst_n),.I_tlast(I_tlast),.I_tuser(I_tuser),
        .I_tdata(I_tdata),.I_tvalid(I_tvalid),.I_tready(1'b1),
        .O_tlast(O_tlast),.O_tuser(O_tuser),.O_tdata(edge_data),
        .O_emboss_data(emboss_data),
        .O_tvalid(O_tvalid),.O_tready()
    );
    assign O_tdata=!O_tvalid ? 96'd0 :
                  O_effect_config[11:8]==4'd2 ? edge_data :
                  O_effect_config[11:8]==4'd4 ? emboss_data : rgb_delayed;
    assign O_effect_config=config_delay[LATENCY-1];
    assign O_edge_mode=O_effect_config[11:8]==4'd2;
endmodule
