module isp_top #(
    parameter integer ENABLE_EDGE = 1, // Reset default, not a generate-time bypass.
    parameter integer RED_MULTI_ENABLE = 0,
    parameter integer ENABLE_GESTURE = 0, // Reserved; embedded classifier retired.
    parameter integer ENABLE_HANDCNN_TAP = 0,
    // Top-level production disables this branch; legacy ISP tests retain it.
    parameter integer ENABLE_TARGET_DETECTION = 1,
    // LSC_PROFILE_RGB_20261015: small residual fit from 15 PRE-WB RGB regions.
    // Preserve global channel ratios; fit the six intermediate regions too.
    // Nodes 1..9 are row-major; Gr/Gb share each fitted scale.
    // Reciprocal-aware interpolation avoids green bulges between the nodes.
    parameter integer LSC_ENABLE = 1,
    parameter integer LSC_MESH_CURVE_ENABLE = 1,
    parameter [71:0] LSC_MESH_GR_Q8 = {8'd240,8'd192,8'd221,8'd241,8'd161,8'd218,8'd233,8'd177,8'd212},
    parameter [71:0] LSC_MESH_GB_Q8 = {8'd224,8'd195,8'd214,8'd219,8'd161,8'd206,8'd220,8'd183,8'd208},
    parameter [80:0] LSC_MESH_B_Q8 = {9'd291,9'd261,9'd272,9'd291,9'd255,9'd277,9'd291,9'd272,9'd281}
) (
    input 			axi4s_video_aclk,
    input 			I_rst_n			,
    input [11:0]    I_effect_config,
    input           I_motion_mode_async,
    input [1:0]     I_color_mode_async,
    input 			I_tlast			,
    input 			I_tuser			,
    input [39:0] 	I_tdata			,
    input 			I_tvalid		,
    input [9:0] 	I_tdest			,
    input 			O_tready		,
    output [127:0] 	O_tdata			,
    output [127:0] O_hand_rgb_data,
    output O_hand_rgb_valid,O_hand_rgb_sof,
    output 			O_tlast			,
    output 			O_tuser			,
    output 			O_tvalid		,
    output 			I_tready,
    output          O_target_result_ready,
    output          O_target_found,
    output [11:0]   O_target_xmin,
    output [11:0]   O_target_xmax,
    output [11:0]   O_target_ymin,
    output [11:0]   O_target_ymax,
    output [11:0]   O_target_center_x,
    output [11:0]   O_target_center_y,
    output [23:0]   O_target_pixels,
    output          O_target_frame_toggle,
    output          O_target_motion_mode,
    output [1:0]    O_target_color_mode,
    output          O_motion_mode_active,
    output [1:0]    O_color_mode_active,
    output [9:0]    O_target_result_frame_id,
    output [3:0]    O_target_multi_valid,
    output [3:0]    O_target_multi_hold,
    output [191:0]  O_target_multi_boxes,
    output          O_target_multi_overflow,
    output          O_edge_mode_active,
    output [11:0]   O_effect_config,
    output          O_ae_stats_valid,
    output [31:0]   O_ae_sum_y,
    output [15:0]   O_ae_sample_count,
    output [15:0]   O_ae_bright_count,
    output          O_cnn_result_valid,
    output [2:0]    O_cnn_class,
    output          O_cnn_busy,
    output          O_cnn_overrun,
    output reg [9:0] O_latency_frame_id
);
 
wire         m_aixs_tvalid;  //synthesis keep 
  wire [127:0] m_aixs_tdata;  //synthesis keep 
  wire         m_aixs_tuser;  //synthesis keep 
  wire         m_aixs_tlast;  //synthesis keep 
  wire         m_aixs_tready;  //synthesis keep 
  
  wire [ 95:0] m_aixs_tdata_96;  //synthesis keep 


  wire         awb_O_tlast;  //synthesis keep 
  wire         awb_O_tuser;  //synthesis keep 
  wire [ 95:0] awb_O_tdata;  //synthesis keep 
  wire         awb_O_tvalid;  //synthesis keep 
  wire         awb_O_tready;  //synthesis keep 

  wire         awb_O_tuser_128;  //synthesis keep 
  wire         awb_O_tvalid_128;  //synthesis keep 
  wire [127:0] awb_O_tdata_128;  //synthesis keep 

  wire         target_result_ready;
  wire         target_found;
  wire [11:0]  target_xmin, target_xmax, target_ymin, target_ymax;
  wire [11:0]  target_center_x, target_center_y;
  wire [23:0]  target_pixels;
  wire         target_frame_toggle;

    wire         edge_O_tlast;  //synthesis keep
    wire         edge_O_tuser;  //synthesis keep
    wire [ 95:0] edge_O_tdata;  //synthesis keep
    wire         edge_O_tvalid;  //synthesis keep
    assign awb_O_tready = O_tready;
  assign O_tdata  = awb_O_tdata_128;
  assign O_tlast  = awb_O_tlast    ;
  assign O_tuser  = awb_O_tuser_128    ;
  assign O_tvalid = awb_O_tvalid_128   ;
  assign O_target_result_ready = target_result_ready;
  assign O_target_found = target_found;
  assign O_target_xmin = target_xmin;
  assign O_target_xmax = target_xmax;
  assign O_target_ymin = target_ymin;
  assign O_target_ymax = target_ymax;
  assign O_target_center_x = target_center_x;
  assign O_target_center_y = target_center_y;
  assign O_target_pixels = target_pixels;
  assign O_target_frame_toggle = target_frame_toggle;
  
  //assign m_aixs_tready = O_tready;
  //assign O_tdata  = m_aixs_tdata;
  //assign O_tlast  = m_aixs_tlast    ;
  //assign O_tuser  = m_aixs_tuser    ;
  //assign O_tvalid = m_aixs_tvalid   ;
 
 
wire [39:0] lsc_data;
wire lsc_valid, lsc_user, lsc_last, lsc_ready;
wire [9:0] demosaic_frame_id;
reg [9:0] lsc_frame_id_1d, lsc_frame_id_2d, lsc_frame_id_3d;
reg [9:0] rgb_frame_id;
always @(posedge axi4s_video_aclk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        lsc_frame_id_1d<=0; lsc_frame_id_2d<=0; lsc_frame_id_3d<=0;
        rgb_frame_id<=0; O_latency_frame_id<=0;
    end else begin
        lsc_frame_id_1d<=I_tdest;
        lsc_frame_id_2d<=lsc_frame_id_1d;
        lsc_frame_id_3d<=lsc_frame_id_2d;
        if (m_aixs_tuser) rgb_frame_id<=demosaic_frame_id;
        // The packer's SOF is one cycle after the edge/RGB SOF.
        if (edge_O_tuser) O_latency_frame_id<=rgb_frame_id;
    end
end

// Exposure feedback uses the sensor-linear RAW stream before LSC. Sampling a
// complete Bayer row pair gives the intended 1:2:1 RGB luminance weighting
// without demosaic, multipliers or frame storage.
ae_frame_stats_raw10_4x #(
    .IMG_WIDTH(1280),
    .IMG_HEIGHT(720),
    .BLACK_LEVEL(0),
    .CLIP_LEVEL(192)
) u_ae_frame_stats (
    .I_clk(axi4s_video_aclk),
    .I_rst_n(I_rst_n),
    .I_tuser(I_tuser),
    .I_tlast(I_tlast),
    .I_tvalid(I_tvalid),
    .I_tdata(I_tdata),
    .O_stats_valid(O_ae_stats_valid),
    .O_sum_y(O_ae_sum_y),
    .O_sample_count(O_ae_sample_count),
    .O_bright_count(O_ae_bright_count)
);

lsc_raw10_4x #(
    .IMG_WIDTH(1280), .IMG_HEIGHT(720), .BAYER_MODE("BGGR"), .ENABLE(LSC_ENABLE),
    .MESH_ENABLE(1), .MESH_CURVE_ENABLE(LSC_MESH_CURVE_ENABLE),
    .MESH_GR_Q8(LSC_MESH_GR_Q8),
    .MESH_GB_Q8(LSC_MESH_GB_Q8), .MESH_B_Q8(LSC_MESH_B_Q8)
) u_lsc (
    .I_clk(axi4s_video_aclk), .I_rst_n(I_rst_n),
    .I_tdata(I_tdata), .I_tvalid(I_tvalid), .I_tuser(I_tuser), .I_tlast(I_tlast),
    .I_tready(I_tready), .O_tdata(lsc_data), .O_tvalid(lsc_valid),
    .O_tuser(lsc_user), .O_tlast(lsc_last), .O_tready(lsc_ready)
);

demosaic #(
    .IMG_HEIGHT          (720),  // 图像高度
    .IMG_WIDTH           (1280), // 图像宽度
    .data_complete_delay (50  ),
    .BAYER_MODE          ("BGGR")
)
u_demosaic
(
    .I_clk   			(axi4s_video_aclk)	,   // 时钟信号
    .I_rst_n 			(I_rst_n)	,   // 复位信号，低有效
    .axi4s_video_tdata 	(lsc_data)	,  // Corrected RAW10, before truncation/demosaic.
    .axi4s_video_tdest 	(lsc_frame_id_3d)	,
    .axi4s_video_tlast 	(lsc_last)	,  // 行结束信号
    .axi4s_video_tvalid	(lsc_valid)	,  // 数据有效信号
    .axi4s_video_tuser 	(lsc_user)	,  // 帧开始信号
    .axi4s_video_tready	(lsc_ready)	,  // 从模块准备好接受数据
    .O_frame_id         (demosaic_frame_id),
    .O_tlast  			(m_aixs_tlast)	,  // 输出行结束信号
    .O_tuser  			(m_aixs_tuser)	,  // 输出帧开始信号
    .O_tdata  			(m_aixs_tdata)	,  // 输出数据
    .O_tvalid 			(m_aixs_tvalid)	,  // 输出数据有效信号
    .O_tready   		(m_aixs_tready)	   // 输出数据准备好信号
);
 
data128_96 u_data128_96 (
    .I_tdata(m_aixs_tdata),
    .O_tdata(m_aixs_tdata_96)
);

awb #(
    .IMG_HEIGHT(720),
    .IMG_WIDTH (1280)
) u_awb (
    .I_clk   (axi4s_video_aclk),
    .I_rst_n (I_rst_n),
    .I_tlast (m_aixs_tlast),
    .I_tuser (m_aixs_tuser),
    .I_tdata (m_aixs_tdata_96),
    .I_tvalid(m_aixs_tvalid),
    .I_tready(m_aixs_tready),
    .O_tlast (awb_O_tlast ),
    .O_tuser (awb_O_tuser ),
    .O_tdata (awb_O_tdata ),
    .O_tvalid(awb_O_tvalid),
    .O_tready(awb_O_tready)
);

// Recognition runs in the DDR-backed fixed-ROI HandCNN.
// Keep the old ISP result ports inactive for interface compatibility.
assign O_cnn_result_valid = 1'b0;
assign O_cnn_class = 3'd1;
assign O_cnn_busy = 1'b0;
assign O_cnn_overrun = 1'b0;

rgb_edge_switch_96 #(
    .IMG_WIDTH (1280),
    .IMG_HEIGHT(720),
    .EDGE_TH   (20), // Scharr: compare |Gx|+|Gy| against 16*EDGE_TH.
    .DEFAULT_EDGE_MODE(ENABLE_EDGE)
) u_rgb_edge_switch (
    .I_clk   (axi4s_video_aclk),
    .I_rst_n (I_rst_n),
    .I_effect_config(I_effect_config),
    .I_tlast (awb_O_tlast),
    .I_tuser (awb_O_tuser),
    .I_tdata (awb_O_tdata),
    .I_tvalid(awb_O_tvalid),
    .O_tlast (edge_O_tlast),
    .O_tuser (edge_O_tuser),
    .O_tdata (edge_O_tdata),
    .O_tvalid(edge_O_tvalid),
    .O_edge_mode(O_edge_mode_active),
    .O_effect_config(O_effect_config)
);

generate if (ENABLE_TARGET_DETECTION != 0) begin: legacy_targets
target_detect_switch_96 #(
    .IMG_WIDTH (1280),
    .IMG_HEIGHT(720),
    .RED_MIN_PIXELS(128),
    .DIFF_THRESHOLD(10),
    .MIN_BLOCKS(12),
    .GLOBAL_CHANGE_PERCENT(40),
    .RED_MULTI_ENABLE(RED_MULTI_ENABLE)
) u_target_detect_switch (
    .I_clk(axi4s_video_aclk),
    .I_rst_n(I_rst_n),
    .I_motion_mode_async(I_motion_mode_async),
    .I_color_mode_async(I_color_mode_async),
    .I_tuser(awb_O_tuser),
    .I_tlast(awb_O_tlast),
    .I_tvalid(awb_O_tvalid),
    .I_tdata(awb_O_tdata),
    .I_frame_id(demosaic_frame_id),
    .O_result_ready(target_result_ready),
    .O_found(target_found),
    .O_xmin(target_xmin),
    .O_xmax(target_xmax),
    .O_ymin(target_ymin),
    .O_ymax(target_ymax),
    .O_center_x(target_center_x),
    .O_center_y(target_center_y),
    .O_pixels(target_pixels),
    .O_frame_toggle(target_frame_toggle),
    .O_target_motion_mode(O_target_motion_mode),
    .O_target_color_mode(O_target_color_mode),
    .O_motion_mode_active(O_motion_mode_active),
    .O_color_mode_active(O_color_mode_active),
    .O_result_frame_id(O_target_result_frame_id),
    .O_multi_valid(O_target_multi_valid),
    .O_multi_hold(O_target_multi_hold),
    .O_multi_boxes(O_target_multi_boxes),
    .O_multi_overflow(O_target_multi_overflow)
);
end else begin: no_targets
    assign target_result_ready = 1'b0;
    assign target_found = 1'b0;
    assign target_xmin = 12'd0;
    assign target_xmax = 12'd0;
    assign target_ymin = 12'd0;
    assign target_ymax = 12'd0;
    assign target_center_x = 12'd0;
    assign target_center_y = 12'd0;
    assign target_pixels = 24'd0;
    assign target_frame_toggle = 1'b0;
    assign O_target_motion_mode = 1'b0;
    assign O_target_color_mode = 2'd0;
    assign O_motion_mode_active = 1'b0;
    assign O_color_mode_active = 2'd0;
    assign O_target_result_frame_id = 10'd0;
    assign O_target_multi_valid = 4'd0;
    assign O_target_multi_hold = 4'd0;
    assign O_target_multi_boxes = 192'd0;
    assign O_target_multi_overflow = 1'b0;
end endgenerate


    generate if(ENABLE_HANDCNN_TAP) begin: handcnn_color_tap
        data_96bit_to_128bit raw_pack(
            .I_clk(axi4s_video_aclk),.I_rst_n(I_rst_n),
            .I_96b_frame_start(awb_O_tuser),.I_96b_valid(awb_O_tvalid),.I_96b_data(awb_O_tdata),
            .O_128b_frame_start(O_hand_rgb_sof),.O_128b_valid(O_hand_rgb_valid),.O_128b_data(O_hand_rgb_data));
    end else begin: no_handcnn_tap
        assign O_hand_rgb_sof=0;assign O_hand_rgb_valid=0;assign O_hand_rgb_data=0;
    end endgenerate

    data_96bit_to_128bit u_data_96bit_to_128bit(
        .I_clk              ( axi4s_video_aclk  ),
        .I_rst_n            ( I_rst_n           ),
	
        .I_96b_frame_start  ( edge_O_tuser	    ),
        .I_96b_valid        ( edge_O_tvalid 		),
        .I_96b_data         ( edge_O_tdata		),
	
        .O_128b_frame_start ( awb_O_tuser_128  	),
        .O_128b_valid       ( awb_O_tvalid_128 	),
        .O_128b_data        ( awb_O_tdata_128  	)
    );



//data96_128 u_data96_128 (
//    .I_tdata(awb_O_tdata),
//    .O_tdata(awb_O_tdata_128)
//);
	
endmodule
