module isp_top #(
    parameter integer ENABLE_EDGE = 1 // Reset default, not a generate-time bypass.
) (
    input 			axi4s_video_aclk,
    input 			I_rst_n			,
    input           I_edge_mode_async,
    input 			I_tlast			,
    input 			I_tuser			,
    input [39:0] 	I_tdata			,
    input 			I_tvalid		,
    input [9:0] 	I_tdest			,
    input 			O_tready		,
    output [127:0] 	O_tdata			,
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
    output          O_edge_mode_active
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
    .axi4s_video_tdata 	(I_tdata)	,  // AXI4-Stream视频数据
    .axi4s_video_tdest 	(I_tdest)	,
    .axi4s_video_tlast 	(I_tlast)	,  // 行结束信号
    .axi4s_video_tvalid	(I_tvalid)	,  // 数据有效信号
    .axi4s_video_tuser 	(I_tuser)	,  // 帧开始信号
    .axi4s_video_tready	(I_tready)	,  // 从模块准备好接受数据
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

rgb_edge_switch_96 #(
    .IMG_WIDTH (1280),
    .IMG_HEIGHT(720),
    .EDGE_TH   (11'd20), // Color-gradient magnitude is scaled down by four.
    .DEFAULT_EDGE_MODE(ENABLE_EDGE)
) u_rgb_edge_switch (
    .I_clk   (axi4s_video_aclk),
    .I_rst_n (I_rst_n),
    .I_edge_mode_async(I_edge_mode_async),
    .I_tlast (awb_O_tlast),
    .I_tuser (awb_O_tuser),
    .I_tdata (awb_O_tdata),
    .I_tvalid(awb_O_tvalid),
    .O_tlast (edge_O_tlast),
    .O_tuser (edge_O_tuser),
    .O_tdata (edge_O_tdata),
    .O_tvalid(edge_O_tvalid),
    .O_edge_mode(O_edge_mode_active)
);

red_target_detect_96 #(
    .IMG_WIDTH (1280),
    .IMG_HEIGHT(720),
    .RED_MIN(80),
    .RED_DELTA(30),
    .MIN_PIXELS(128)
) u_red_target_detect_96 (
    .I_clk(axi4s_video_aclk),
    .I_rst_n(I_rst_n),
    .I_tuser(awb_O_tuser),
    .I_tvalid(awb_O_tvalid),
    .I_tdata(awb_O_tdata),
    .O_result_ready(target_result_ready),
    .O_found(target_found),
    .O_xmin(target_xmin),
    .O_xmax(target_xmax),
    .O_ymin(target_ymin),
    .O_ymax(target_ymax),
    .O_center_x(target_center_x),
    .O_center_y(target_center_y),
    .O_pixels(target_pixels),
    .O_frame_toggle(target_frame_toggle)
);


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
