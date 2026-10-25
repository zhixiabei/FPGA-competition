

module design_top_wrapper #(
    parameter integer ENABLE_EDGE = 0, // Reset default only; button selects at runtime.
    parameter integer RED_MULTI_ENABLE = 0, // Reserved; auxiliary detectors removed.
    parameter integer SHOW_RED_MASK = 0, // Reserved for compatibility; no mask frame is stored.
    parameter integer SHOW_RAW_STATS = 0, // RAW diagnostics.
    parameter integer ENABLE_HANDCNN = 1 // Fixed ROI + hand7; UART weights required after reset.
) (
    input wire        I_sys_clk,
    input wire        I_rst_n,
    input wire        I_resnet_uart_rx,
    output wire       O_resnet_uart_tx,
      
    output wire       O_cam_scl,
    inout  wire       IO_cam_sda,
    output wire       O_cam_24m,
    output wire       O_cam_rst,
      
    inout wire [1:0]  I_button,
    input wire        I_mode_key_n, // Board K1 (D5), cycle display algorithms.
    input wire        I_detect_key_n, // Board K2 (A9), reserved; detection is ResNet only.
    input wire        I_effect_key_n, // Board K3 (B9), reserved.
    input wire        I_latency_switch, // Board SW1 (A4), high to show latency panel.
    input wire        I_param_key_n, // Board K4 (C7), toggle fixed-ROI CNN.

    output wire       O_screen_pwm,
    output wire       O_tmds_ch0_p,
    output wire       O_tmds_ch1_p,
    output wire       O_tmds_ch2_p,
    output wire       O_tmds_clk_p,

    inout wire        IO_rx_clk_pad_n, 
    inout wire        IO_rx_clk_pad_p, 
    inout wire[3:0]   IO_rx_data_pad_n,
    inout wire[3:0]   IO_rx_data_pad_p,

    output wire[12:0] ddr_addr,
    output wire[ 1:0] ddr_ba,
    output wire[ 0:0] ddr_cke,
    output wire[ 0:0] ddr_odt,
    output wire[ 0:0] ddr_cs_n,
    output wire       ddr_ras_n,
    output wire       ddr_cas_n,
    output wire       ddr_we_n,
    output wire[ 0:0] ddr_ck_p,
    output wire[ 0:0] ddr_ck_n,
    inout wire[1:0]   ddr_dm,
    inout wire[15:0]  ddr_dq,
    inout wire[1:0]   ddr_dqs_p,
    inout wire[1:0]   ddr_dqs_n   
);

    localparam [3:0] DEFAULT_EFFECT_MODE = ENABLE_EDGE != 0 ? 4'd2 : 4'd0;
    localparam [11:0] DEFAULT_EFFECT_CONFIG = {DEFAULT_EFFECT_MODE,8'd0};
    wire        	S_100m_clk;
    wire        	S_24m_clk;
    wire        	S_aux_50m_clk;
	wire        	S_10m_clk;
		
	wire        	S_pll_lock;
    wire        	S_rst_n;
	reg  [17:0] 	S_cam_power_cnt;
	reg         	S_cam_pwdnb;
	reg         	S_cam_i2c_ready;
	(* keep = "true" *) wire [15:0] S_cam_sensor_id;
	(* keep = "true" *) wire        S_cam_sensor_id_ok;
	(* keep = "true" *) wire        S_cam_i2c_error;
	wire [7:0] S_cam_fail_index;
	localparam integer CAM_PWDNB_LOW_CYCLES = 23810;  // >= 1 ms at 23.809524 MHz
	localparam integer CAM_I2C_START_CYCLES = 142857; // release + >= 5 ms
	
	wire [15:0] 	S_ae;
    wire [15:0] 	S_ag;
    wire 			S_cam_cfg_done;
    wire 			S_ae_cfg_done;
    wire 			S_ae_req; 
	
	wire        	S_csi_rx_clk;  
    wire        	S_hs_rx_valid;  
    wire[15:0]  	S_hs_rx_data;   
	wire[1:0]   	S_lane_error;
	
	wire        	S_csi_frame_start;       
	wire        	S_csi_frame_end;         
	wire        	S_csi_valid;             
	wire[31:0]  	S_csi_data;  
		
	wire        	S_raw10_frame_start; 
	wire        	S_raw10_frame_end;   
	wire        	S_raw10_valid;       
	wire [39:0] 	S_raw10_data;
		
	wire 			S_axis_tlast;  
	wire 			S_axis_tuser;  
	wire [39:0]		S_axis_tdata;  
	wire 			S_axis_tvalid; 
	
	wire [39:0]		S_raw_tdata ;
	wire			S_raw_tlast ;
	wire 			S_raw_tvalid;
	wire 			S_raw_tuser ;
	
	wire			S_ISP_O_tready;
	wire [127:0]	S_ISP_O_tdata ;
    wire [127:0] S_hand_rgb_data;
    wire S_hand_rgb_valid,S_hand_rgb_sof;
    wire [48:0] S_hand_box_hdmi;
	wire 			S_ISP_O_tlast ;
	wire 			S_ISP_O_tuser ;
	wire 			S_ISP_O_tvalid; 

    wire [11:0] S_ISP_effect_config;
    wire        S_cnn_result_valid_hdmi;
    wire [2:0]  S_cnn_class_hdmi;
    wire [31:0] S_resnet_probe_status_hdmi;
    wire        S_ISP_ae_stats_valid;
    wire [31:0] S_ISP_ae_sum_y;
    wire [15:0] S_ISP_ae_sample_count;
    wire [15:0] S_ISP_ae_bright_count;
    wire        S_ae_stats_valid;
    wire [63:0] S_ae_stats_data;

    // Buffered video slots retain their display configuration.
    wire [1:0] S_write_frame_slot;
    wire [1:0] S_read_frame_slot;
    wire S_write_frame_start, S_read_frame_start, S_display_frame_start;
    wire [1:0] S_write_start_slot;
    wire [9:0] S_raw_frame_id, S_isp_frame_id;
    wire S_latency_sample_strobe, S_latency_sample_valid;
    wire [9:0] S_latency_frame_id;
    wire [19:0] S_latency_total_us, S_latency_isp_us, S_latency_buffer_us;
    wire [11:0] S_effect_config_hdmi;

    wire        S_ddr_clk;
    wire        S_hdmi_pixel_clk;
    wire        S_hdmi_serial_clk;
    wire        S_hdmi_rst_n;
    wire        S_video_out_rst_n;


    wire        S_vi_128b_frame_start;
    wire        S_vi_128b_valid;      
    wire[127:0] S_vi_128b_data;    
    
    wire        S_video_out_rd_busy;
    wire        S_video_in_wr_busy; 
    wire[1:0]   S_video_out_rp;     

    wire        S_ddr_user_wr_en;       
    wire        S_ddr_user_rd_en;       
    wire[24:0]  S_ddr_user_addr;        
    wire[127:0] S_ddr_user_wr_data;     
    wire        S_ddr_user_ready;       
    wire        S_ddr_user_rd_valid;    
    wire[127:0] S_ddr_user_rd_data;     

    wire        S_vi_ddr_wr_en;   
    wire[24:0]  S_vi_ddr_wr_addr; 
    wire[127:0] S_vi_ddr_wr_data;
    wire        S_vi_ddr_wr_ready;

    wire        S_vo_ddr_rd_en;   
    wire[24:0]  S_vo_ddr_rd_addr; 
    wire        S_vo_ddr_rd_ready;
    wire        S_vo_dbg_fifo_rst;
    wire        S_vo_dbg_ddr_rd_valid;
    wire        S_vo_dbg_fifo_rd_en;
    wire        S_vo_dbg_fifo_empty;

    wire        S_init_calib_complete; 
    reg [1:0]   S_video_calib_sync;
    reg         S_video_ddr_started;
    wire        S_video_ddr_rst_n;
    wire[24:0]  S_mc_app_addr;          
    wire[2:0]   S_mc_app_cmd;           
    wire        S_mc_app_en;            
    wire[127:0] S_mc_app_wdf_data;      
    wire        S_mc_app_wdf_end;       
    wire[15:0]  S_mc_app_wdf_mask;      
    wire        S_mc_app_wdf_wren;      
    wire[127:0] S_mc_app_rd_data;       
    wire        S_mc_app_rd_data_end;   
    wire        S_mc_app_rd_data_valid; 
    wire        S_mc_app_rdy;           
    wire        S_mc_app_wdf_rdy;       
    wire        S_mc_dbg_fifo_afull;
    wire        S_mc_dbg_app_rdy;
    wire        S_mc_dbg_wdf_rdy;
    wire        S_mc_dbg_cmd_pop;

    wire        S_hdmi_vsync;
    wire        S_hdmi_hsync;
    wire        S_hdmi_de;
    wire        S_hdmi_user;
    wire        S_hdmi_last;
    wire        S_video_out_vsync;
    wire        S_hdmi_window_rd_en;
    wire        S_hdmi_out_vsync;
    wire        S_hdmi_out_hsync;
    wire        S_hdmi_out_de;
    wire[23:0]  S_hdmi_out_data;

    wire[23:0]  S_video_rd_data;
    reg         S_dbg_raw_seen;
    reg         S_dbg_isp_seen;
    reg         S_dbg_ddr_wr_seen;
    reg         S_dbg_ddr_rd_seen;
    reg         S_dbg_cam_cfg_seen;
    reg         S_dbg_hs_seen;
    reg         S_dbg_csi_seen;
    reg         S_dbg_raw10_seen;
    reg         S_dbg_isp_fs_seen;
    reg         S_dbg_isp_valid_seen;
    reg         S_dbg_ddr_req_seen;
    reg         S_dbg_ddr_ready_seen;
    reg [1:0]   S_dbg_raw_seen_sync;
    reg [1:0]   S_dbg_isp_seen_sync;
    reg [1:0]   S_dbg_ddr_wr_seen_sync;
    reg [1:0]   S_dbg_ddr_rd_seen_sync;
    reg [1:0]   S_dbg_cam_cfg_seen_sync;
    reg [1:0]   S_dbg_hs_seen_sync;
    reg [1:0]   S_dbg_csi_seen_sync;
    reg [1:0]   S_dbg_raw10_seen_sync;
    reg [1:0]   S_dbg_isp_fs_seen_sync;
    reg [1:0]   S_dbg_isp_valid_seen_sync;
    reg [1:0]   S_dbg_ddr_req_seen_sync;
    reg [1:0]   S_dbg_ddr_ready_seen_sync;
    reg         S_dbg_video_nonzero_seen;
    reg         S_dbg_rd_req_seen;
    reg         S_dbg_rd_valid_seen;
    reg         S_dbg_rd_nonzero_seen;
    reg [1:0]   S_dbg_rd_req_seen_sync;
    reg [1:0]   S_dbg_rd_valid_seen_sync;
    reg [1:0]   S_dbg_rd_nonzero_seen_sync;
    reg         S_dbg_mc_init_seen;
    reg         S_dbg_mc_app_rdy_seen;
    reg         S_dbg_mc_wdf_rdy_seen;
    reg         S_dbg_mc_cmd_pop_seen;
    reg [1:0]   S_dbg_mc_init_seen_sync;
    reg [1:0]   S_dbg_mc_app_rdy_seen_sync;
    reg [1:0]   S_dbg_mc_wdf_rdy_seen_sync;
    reg [1:0]   S_dbg_mc_cmd_pop_seen_sync;
    wire[3:0]   S_hdmi_debug_status;
    reg         S_cam_ae_started;
    reg         S_cam_ae_applied;
    reg [3:0]   S_cam_status;
    wire [11:0] S_cam_diag_sync;
    wire [7:0]  S_cam_fail_sync;
    wire        S_lane_error_any;


    assign O_screen_pwm = 1'b1;
    assign S_video_out_vsync = ~S_hdmi_vsync;
	
	
    assign S_rst_n 		= S_pll_lock;
    assign S_hdmi_rst_n = S_pll_lock;

    // Release the video DDR path synchronously only after initial DDR
    // calibration. HDMI timing and camera configuration keep their own reset.
    // Latch startup: a later calibration drop must not silently discard
    // queued reads while the bridge/controller still retain their ownership.
    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if (!S_rst_n) begin
            S_video_calib_sync <= 2'b00;
            S_video_ddr_started <= 1'b0;
        end else begin
            S_video_calib_sync <= {S_video_calib_sync[0],S_init_calib_complete};
            if (S_video_calib_sync[1]) S_video_ddr_started <= 1'b1;
        end
    end
    assign S_video_ddr_rst_n = S_rst_n && S_video_ddr_started;

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_raw_seen <= 1'b0;
        else if(S_raw10_frame_start | S_axis_tvalid)
            S_dbg_raw_seen <= 1'b1;
    end

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_isp_seen <= 1'b0;
        else if(S_ISP_O_tuser | S_ISP_O_tvalid)
            S_dbg_isp_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_ddr_wr_seen <= 1'b0;
        else if(S_vi_ddr_wr_en)
            S_dbg_ddr_wr_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_ddr_rd_seen <= 1'b0;
        else if(S_ddr_user_rd_valid)
            S_dbg_ddr_rd_seen <= 1'b1;
    end

    always @(posedge S_24m_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_cam_cfg_seen <= 1'b0;
        else if(S_cam_cfg_done)
            S_dbg_cam_cfg_seen <= 1'b1;
    end

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_hs_seen <= 1'b0;
        else if(S_hs_rx_valid)
            S_dbg_hs_seen <= 1'b1;
    end

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_csi_seen <= 1'b0;
        else if(S_csi_frame_start | S_csi_valid)
            S_dbg_csi_seen <= 1'b1;
    end

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_raw10_seen <= 1'b0;
        else if(S_raw10_frame_start | S_raw10_valid)
            S_dbg_raw10_seen <= 1'b1;
    end

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_isp_fs_seen <= 1'b0;
        else if(S_ISP_O_tuser)
            S_dbg_isp_fs_seen <= 1'b1;
    end

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_isp_valid_seen <= 1'b0;
        else if(S_ISP_O_tvalid)
            S_dbg_isp_valid_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_ddr_req_seen <= 1'b0;
        else if(S_vi_ddr_wr_en)
            S_dbg_ddr_req_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_ddr_ready_seen <= 1'b0;
        else if(S_ddr_user_ready)
            S_dbg_ddr_ready_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_video_out_rst_n) begin
        if(!S_video_out_rst_n)
            S_dbg_rd_req_seen <= 1'b0;
        else if(S_video_out_vsync)
            S_dbg_rd_req_seen <= 1'b0;
        else if(S_vo_ddr_rd_en)
            S_dbg_rd_req_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_video_out_rst_n) begin
        if(!S_video_out_rst_n)
            S_dbg_rd_valid_seen <= 1'b0;
        else if(S_video_out_vsync)
            S_dbg_rd_valid_seen <= 1'b0;
        else if(S_ddr_user_rd_valid)
            S_dbg_rd_valid_seen <= 1'b1;
    end

    always @(posedge S_hdmi_pixel_clk or negedge S_video_out_rst_n) begin
        if(!S_video_out_rst_n)
            S_dbg_rd_nonzero_seen <= 1'b0;
        else if(S_video_out_vsync)
            S_dbg_rd_nonzero_seen <= 1'b0;
        else if(S_hdmi_window_rd_en && (S_video_rd_data != 24'd0))
            S_dbg_rd_nonzero_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_mc_init_seen <= 1'b0;
        else if(S_init_calib_complete)
            S_dbg_mc_init_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_mc_app_rdy_seen <= 1'b0;
        else if(S_mc_dbg_app_rdy)
            S_dbg_mc_app_rdy_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_mc_wdf_rdy_seen <= 1'b0;
        else if(S_mc_dbg_wdf_rdy)
            S_dbg_mc_wdf_rdy_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_mc_cmd_pop_seen <= 1'b0;
        else if(S_mc_dbg_cmd_pop)
            S_dbg_mc_cmd_pop_seen <= 1'b1;
    end

    always @(posedge S_hdmi_pixel_clk or negedge S_hdmi_rst_n) begin
        if(!S_hdmi_rst_n) begin
            S_dbg_cam_cfg_seen_sync <= 2'b00;
            S_dbg_hs_seen_sync      <= 2'b00;
            S_dbg_csi_seen_sync     <= 2'b00;
            S_dbg_raw10_seen_sync   <= 2'b00;
            S_dbg_raw_seen_sync    <= 2'b00;
            S_dbg_isp_seen_sync    <= 2'b00;
            S_dbg_ddr_wr_seen_sync <= 2'b00;
            S_dbg_ddr_rd_seen_sync <= 2'b00;
            S_dbg_isp_fs_seen_sync  <= 2'b00;
            S_dbg_isp_valid_seen_sync <= 2'b00;
            S_dbg_ddr_req_seen_sync <= 2'b00;
            S_dbg_ddr_ready_seen_sync <= 2'b00;
            S_dbg_video_nonzero_seen <= 1'b0;
            S_dbg_rd_req_seen_sync <= 2'b00;
            S_dbg_rd_valid_seen_sync <= 2'b00;
            S_dbg_rd_nonzero_seen_sync <= 2'b00;
            S_dbg_mc_init_seen_sync <= 2'b00;
            S_dbg_mc_app_rdy_seen_sync <= 2'b00;
            S_dbg_mc_wdf_rdy_seen_sync <= 2'b00;
            S_dbg_mc_cmd_pop_seen_sync <= 2'b00;
        end
        else begin
            S_dbg_cam_cfg_seen_sync <= {S_dbg_cam_cfg_seen_sync[0], S_dbg_cam_cfg_seen};
            S_dbg_hs_seen_sync      <= {S_dbg_hs_seen_sync[0],      S_dbg_hs_seen};
            S_dbg_csi_seen_sync     <= {S_dbg_csi_seen_sync[0],     S_dbg_csi_seen};
            S_dbg_raw10_seen_sync   <= {S_dbg_raw10_seen_sync[0],   S_dbg_raw10_seen};
            S_dbg_raw_seen_sync    <= {S_dbg_raw_seen_sync[0],    S_dbg_raw_seen};
            S_dbg_isp_seen_sync    <= {S_dbg_isp_seen_sync[0],    S_dbg_isp_seen};
            S_dbg_ddr_wr_seen_sync <= {S_dbg_ddr_wr_seen_sync[0], S_dbg_ddr_wr_seen};
            S_dbg_ddr_rd_seen_sync <= {S_dbg_ddr_rd_seen_sync[0], S_dbg_ddr_rd_seen};
            S_dbg_isp_fs_seen_sync  <= {S_dbg_isp_fs_seen_sync[0],  S_dbg_isp_fs_seen};
            S_dbg_isp_valid_seen_sync <= {S_dbg_isp_valid_seen_sync[0], S_dbg_isp_valid_seen};
            S_dbg_ddr_req_seen_sync <= {S_dbg_ddr_req_seen_sync[0], S_dbg_ddr_req_seen};
            S_dbg_ddr_ready_seen_sync <= {S_dbg_ddr_ready_seen_sync[0], S_dbg_ddr_ready_seen};
            S_dbg_rd_req_seen_sync <= {S_dbg_rd_req_seen_sync[0], S_dbg_rd_req_seen};
            S_dbg_rd_valid_seen_sync <= {S_dbg_rd_valid_seen_sync[0], S_dbg_rd_valid_seen};
            S_dbg_rd_nonzero_seen_sync <= {S_dbg_rd_nonzero_seen_sync[0], S_dbg_rd_nonzero_seen};
            S_dbg_mc_init_seen_sync <= {S_dbg_mc_init_seen_sync[0], S_dbg_mc_init_seen};
            S_dbg_mc_app_rdy_seen_sync <= {S_dbg_mc_app_rdy_seen_sync[0], S_dbg_mc_app_rdy_seen};
            S_dbg_mc_wdf_rdy_seen_sync <= {S_dbg_mc_wdf_rdy_seen_sync[0], S_dbg_mc_wdf_rdy_seen};
            S_dbg_mc_cmd_pop_seen_sync <= {S_dbg_mc_cmd_pop_seen_sync[0], S_dbg_mc_cmd_pop_seen};
            if(S_hdmi_window_rd_en && (S_video_rd_data != 24'd0))
                S_dbg_video_nonzero_seen <= 1'b1;
        end
    end

    assign S_lane_error_any = |S_lane_error;

    assign S_vo_dbg_fifo_rst = 1'b0;
    assign S_vo_dbg_ddr_rd_valid = 1'b0;
    assign S_vo_dbg_fifo_rd_en = 1'b0;
    assign S_vo_dbg_fifo_empty = 1'b0;
    assign S_mc_dbg_fifo_afull = 1'b0;
    assign S_mc_dbg_app_rdy = 1'b0;
    assign S_mc_dbg_wdf_rdy = 1'b0;
    assign S_mc_dbg_cmd_pop = 1'b0;

    // O_ae_cfg_done also goes high after initialization, before any AE write.
    // Require an actual completed AE write. Once applied, normal closed-loop
    // updates do not turn the status red merely because the bus is busy.
    always @(posedge S_24m_clk or negedge S_cam_i2c_ready) begin
        if (!S_cam_i2c_ready) begin
            S_cam_ae_started <= 1'b0;
            S_cam_ae_applied <= 1'b0;
            S_cam_status <= 4'b0000;
        end else begin
            if (!S_cam_cfg_done || S_cam_i2c_error) begin
                S_cam_ae_started <= 1'b0;
                S_cam_ae_applied <= 1'b0;
            end else if (!S_ae_cfg_done)
                S_cam_ae_started <= 1'b1;
            else if (S_cam_ae_started)
                S_cam_ae_applied <= 1'b1;
            S_cam_status <= {
                !S_cam_i2c_error,
                (S_cam_ae_applied && S_cam_cfg_done && !S_cam_i2c_error),
                S_cam_cfg_done,
                S_cam_sensor_id_ok
            };
        end
    end

    camera_diag_cdc #(.WIDTH(12)) u_camera_diag_cdc (
        .I_src_clk(S_24m_clk),
        .I_dst_clk(S_hdmi_pixel_clk),
        .I_rst_n(S_pll_lock),
        .I_src_data({S_cam_status, S_cam_fail_index}),
        .O_dst_data(S_cam_diag_sync)
    );
    assign S_hdmi_debug_status = S_cam_diag_sync[11:8];
    assign S_cam_fail_sync = S_cam_diag_sync[7:0];
	
	// SC520CS上电后先保持PWDNB/XSHUTDN为低，再释放并等待内部上电完成，
	// 避免PLL刚锁定就开始I2C初始化而造成寄存器偶发写入失败。
	always @(posedge S_24m_clk or negedge S_pll_lock) begin
		if (!S_pll_lock) begin
			S_cam_power_cnt <= 18'd0;
			S_cam_pwdnb <= 1'b0;
			S_cam_i2c_ready <= 1'b0;
		end else begin
			if (S_cam_power_cnt < CAM_I2C_START_CYCLES)
				S_cam_power_cnt <= S_cam_power_cnt + 1'b1;
			if (S_cam_power_cnt >= CAM_PWDNB_LOW_CYCLES)
				S_cam_pwdnb <= 1'b1;
			if (S_cam_power_cnt >= CAM_I2C_START_CYCLES - 1)
				S_cam_i2c_ready <= 1'b1;
		end
	end

	assign O_cam_rst 	= S_cam_pwdnb;
    assign O_cam_24m 	= S_24m_clk;
	
	
	
	
    PLL u_PLL(
        .refclk      ( I_sys_clk         ),
        .reset    	 ( ~I_rst_n          ),
        
        .clk0_out    ( S_100m_clk        ),
        .clk1_out    ( S_24m_clk         ),

        .clk4_out    ( S_hdmi_pixel_clk  ),
        .clk5_out    ( S_hdmi_serial_clk ),

        .lock        ( S_pll_lock        )

    );


	

  
    wire [3:0] S_effect_mode_requested;
    wire [7:0] S_effect_param_requested;
    wire [11:0] S_effect_config_csi;
    display_effect_control #(
        .DEBOUNCE_CYCLES(1000000),
        .DEFAULT_MODE(DEFAULT_EFFECT_MODE)
    ) u_display_effect_control (
        .I_clk(I_sys_clk),
        .I_rst_n(S_rst_n),
        .I_prev_key_n(I_mode_key_n),
        .I_effect_key_n(I_effect_key_n),
        .I_param_key_n(I_param_key_n),
        .O_effect_mode(S_effect_mode_requested),
        .O_effect_param(S_effect_param_requested)
    );

    // Transfer the full request to CSI; the ISP commits it only at SOF.
    // HDMI later uses the committed configuration stored with its DDR slot.
    camera_diag_cdc #(.WIDTH(12), .RESET_DATA(DEFAULT_EFFECT_CONFIG)) u_display_effect_cdc (
        .I_src_clk(I_sys_clk),
        .I_dst_clk(S_csi_rx_clk),
        .I_rst_n(S_rst_n),
        .I_src_data({S_effect_mode_requested, S_effect_param_requested}),
        .O_dst_data(S_effect_config_csi)
    );

  ae_stats_cdc u_ae_stats_cdc (
      .I_src_clk(S_csi_rx_clk),
      .I_dst_clk(S_24m_clk),
      .I_rst_n(S_rst_n),
      .I_src_valid(S_ISP_ae_stats_valid),
      .I_src_data({S_ISP_ae_sum_y,S_ISP_ae_sample_count,S_ISP_ae_bright_count}),
      .O_dst_valid(S_ae_stats_valid),
      .O_dst_data(S_ae_stats_data)
  );

  // RAW10 frame feedback: protect daylight highlights while still allowing
  // the sensor's final 32x gain stage for lit indoor night scenes.
  auto_exposure_control #(
      .TARGET_LOW(96),
      .TARGET_HIGH(120),
      .DARK_FAST(64),
      .BRIGHT_FAST(144),
      .GAIN_MAX(176),
      .SETTLE_FRAMES(3),
      .AVERAGE_FRAMES(6)
  ) u_auto_exposure (
      .I_clk(S_24m_clk),
      .I_rst(~S_rst_n),
      .I_cam_cfg_done(S_cam_cfg_done),
      .I_ae_cfg_done(S_ae_cfg_done),
      .I_stats_valid(S_ae_stats_valid),
      .I_sum_y(S_ae_stats_data[63:32]),
      .I_sample_count(S_ae_stats_data[31:16]),
      .I_bright_count(S_ae_stats_data[15:0]),
      .O_ae_req(S_ae_req),
      .O_ae(S_ae),
      .O_ag(S_ag)
  );
  
    // SC520CS原厂真实HD模式：1280x720@60、RAW10、2-Lane、828 Mbps/Lane。
    // 当前寄存器表已关闭Slave/FSIN等待，Sensor以free-run方式连续输出。
    uicfgcs520 #(
      .CLK_DIV(23809524 / 100000 - 1)
  ) u_uicfgcs520 (
      .I_clk(S_24m_clk),  //系统时钟输入
      .I_rst_n(S_cam_i2c_ready), // SC520CS power-up delay completed
      .I_ae_req(S_ae_req),
      .I_ae(S_ae),
      .I_ag(S_ag),
      .O_cam_scl(O_cam_scl),  //I2C总线，SCL时钟
      .IO_cam_sda(IO_cam_sda),  //I2C总线，SDA数据
      .O_cfg_done(S_cam_cfg_done),  //摄像头寄存器初始化完成
      .O_ae_cfg_done(S_ae_cfg_done),  //AE配置完成
      .O_sensor_id(S_cam_sensor_id),
      .O_sensor_id_ok(S_cam_sensor_id_ok),
      .O_iic_error(S_cam_i2c_error),
      .O_fail_index(S_cam_fail_index)
  );
	
    mipi_dphy_rx_ph1p_mipiio_wrapper#(
        .DPHY_RX_LOCATION      ( "DPHY0" ),
        .HS_EQUALIZER          ( "3dB"   ),// 828 Mbps/Lane接收均衡
        .HS_VGA_GAIN           ( "8dB" ),//"-3dB","-1.5dB","0dB","1.5dB","3dB","4.5dB","6dB","7.5dB"
        .LANE_NUM              ( 2       ),
        .BYTE_NUM              ( 1       )
    )u_mipi_dphy_rx_ph1p_mipiio_wrapper(
        .I_lp_clk              ( S_100m_clk       ),
        .I_rst                 ( ~S_rst_n         ),

        .I_clk_lane_in_delay   ( 6'd0             ),
        .I_data_lane0_in_delay ( 6'd0             ),
        .I_data_lane1_in_delay ( 6'd0             ),
        .I_data_lane2_in_delay ( 6'd0             ),
        .I_data_lane3_in_delay ( 6'd0             ),

        .I_lane_invert         ( 4'b0000          ),
     
        .O_hs_rx_clk           ( S_csi_rx_clk     ),
        .O_hs_rx_valid         ( S_hs_rx_valid    ),
        .O_hs_rx_data          ( S_hs_rx_data     ),
      
        .O_lp_rx_lane0_p       (  ),
        .O_lp_rx_lane0_n       (  ),
      
        .I_lp_tx_en            ( 1'b0             ),
        .I_lp_tx_lane0_p       ( 1'b1             ),
        .I_lp_tx_lane0_n       ( 1'b1             ),
      
        .O_lane_match_error    (                  ),
        .O_lane_error          ( S_lane_error     ),
      
        .IO_rx_clk_pad_n       ( IO_rx_clk_pad_n  ),
        .IO_rx_clk_pad_p       ( IO_rx_clk_pad_p  ),
        .IO_rx_data_pad_n      ( IO_rx_data_pad_n ),
        .IO_rx_data_pad_p      ( IO_rx_data_pad_p )
    );
	
	
 //  cwc cwc_inst
 //(
 //    .probe0(S_hs_rx_valid),
 //    .probe1(S_hs_rx_data),
 //    .probe2(S_lane_error),
 //    .clk(S_csi_rx_clk)
 //);

 //csi 解码为RAW数据
csi_unpacket_2lane u_csi_unpacket(
.I_clk                 ( S_csi_rx_clk       ),
.I_rst_n               ( S_rst_n        	),
.I_hs_valid            ( S_hs_rx_valid     ),
.I_hs_data             ( S_hs_rx_data      ),

.O_csi_frame_start     ( S_csi_frame_start ),
.O_csi_frame_end       ( S_csi_frame_end   ),
.O_csi_valid           ( S_csi_valid       ),
.O_csi_data            ( S_csi_data        )
);


//解码为RAW8
raw10_unpacket_2lane u_raw10_unpacket (
.I_clk  (S_csi_rx_clk),
.I_rst_n(S_rst_n),

.I_csi_frame_start(S_csi_frame_start),
.I_csi_frame_end  (S_csi_frame_end),
.I_csi_valid      (S_csi_valid),
.I_csi_data       (S_csi_data),

.O_raw10_frame_start(S_raw10_frame_start),
.O_raw10_frame_end  (S_raw10_frame_end),
.O_raw10_valid      (S_raw10_valid),
.O_raw10_data       (S_raw10_data)
  );


//将数据转为stream流
uial2axis #(
.IMG_WIDTH(1280),
.IMG_HEIGHT(720),
.INPUT_DATA_WIDTH(40)
) 
u_uial2axis (
.I_native_clk(S_csi_rx_clk),
.I_rst_n     (S_rst_n),
.I_data      (S_raw10_data       ),
.I_data_valid(S_raw10_valid      ),
.I_data_start(S_raw10_frame_start),
.I_data_end  (S_raw10_frame_end  ),
.axis_tvalid (S_axis_tvalid),
.axis_tdata  (S_axis_tdata ),
.axis_tuser  (S_axis_tuser ),
.axis_tlast  (S_axis_tlast )
);
	

// The sensor already produces a real 1280x720 frame.  Do not pass it through
// the legacy fixed 1024x600 image_correction crop; keep line/frame markers
// aligned with the factory sensor output.
assign S_raw_tdata  = S_axis_tdata;
assign S_raw_tlast  = S_axis_tlast;
assign S_raw_tvalid = S_axis_tvalid;
assign S_raw_tuser  = S_axis_tuser;


//cwc1 cwc1_Inst
//  (
//      .probe0(S_axis_tuser),
//      .probe1(S_axis_tvalid),
//      .probe2(S_axis_tlast),
//      .probe3(S_axis_tdata),
//      .probe4(S_ISP_O_tuser),
//      .probe5(S_ISP_O_tvalid),
//      .probe6(S_ISP_O_tlast),
//      .probe7(S_ISP_O_tdata),
//      .probe8 (S_raw_tdata ),
//      .probe9 (S_raw_tlast ),
//      .probe10(S_raw_tvalid),
//      .probe11(S_raw_tuser ),
//      .clk(S_csi_rx_clk)
//  );


// Read-only RAW tap, serialized into ten small packets per camera frame.
// In 720p the closest packets are 152 camera clocks apart, comfortably
// exceeding mailbox round trip and the HDMI decimal converter's 44 clocks.
wire S_raw_stats_valid;
wire [44:0] S_raw_stats_data;
wire S_ae_readout_valid;
wire [27:0] S_ae_readout_data;
generate if (SHOW_RAW_STATS != 0) begin: raw_diagnostics
    wire stats_valid;
    wire [44:0] stats_data;
    raw_region_stats u_stats (
        .I_clk(S_csi_rx_clk), .I_rst_n(S_rst_n),
        .I_tdata(S_raw_tdata), .I_tvalid(S_raw_tvalid),
        .I_tuser(S_raw_tuser), .I_tlast(S_raw_tlast),
        .O_valid(stats_valid), .O_data(stats_data)
    );
    ae_stats_cdc #(.WIDTH(45)) u_cdc (
        .I_src_clk(S_csi_rx_clk), .I_dst_clk(S_hdmi_pixel_clk),
        .I_rst_n(S_rst_n), .I_src_valid(stats_valid), .I_src_data(stats_data),
        .O_dst_valid(S_raw_stats_valid), .O_dst_data(S_raw_stats_data)
    );
    // Report completed writes, not new requests. This is not sensor readback.
    // Only complete AE frames advance the sequence; a parameter-only update
    // must not reset the HDMI metering freshness indicator.
    reg ae_done_d, meter_seen;
    reg [7:0] meter_sequence;
    reg [10:0] applied_exposure;
    reg [7:0] applied_gain;
    wire write_done = S_ae_cfg_done && !ae_done_d && S_cam_cfg_done;
    always @(posedge S_24m_clk or negedge S_rst_n) begin
        if (!S_rst_n) begin
            ae_done_d<=0; meter_seen<=0; meter_sequence<=0;
            applied_exposure<=1000; applied_gain<=16;
        end else begin
            ae_done_d<=S_ae_cfg_done;
            if (S_ae_stats_valid) begin
                meter_seen<=1;
                meter_sequence<=meter_sequence+1'b1;
            end
            if (write_done) begin
                applied_exposure<=S_ae[10:0]; applied_gain<=S_ag[7:0];
            end
        end
    end
    ae_stats_cdc #(.WIDTH(28)) u_ae_readout_cdc (
        .I_src_clk(S_24m_clk), .I_dst_clk(S_hdmi_pixel_clk), .I_rst_n(S_rst_n),
        .I_src_valid(S_ae_stats_valid || write_done),
        .I_src_data({meter_seen || S_ae_stats_valid,
            meter_sequence+{7'd0,S_ae_stats_valid},
            write_done ? S_ae[10:0] : applied_exposure,
            write_done ? S_ag[7:0] : applied_gain}),
        .O_dst_valid(S_ae_readout_valid), .O_dst_data(S_ae_readout_data)
    );
end else begin: no_raw_diagnostics
    assign S_raw_stats_valid = 1'b0;
    assign S_raw_stats_data = 45'd0;
    assign S_ae_readout_valid = 1'b0;
    assign S_ae_readout_data = 28'd0;
end endgenerate

    video_latency_monitor u_video_latency (
        .I_time_clk(I_sys_clk), .I_csi_clk(S_csi_rx_clk),
        .I_ddr_clk(S_ddr_clk), .I_hdmi_clk(S_hdmi_pixel_clk), .I_rst_n(S_rst_n),
        .I_raw_sof(S_raw_tuser), .I_raw_valid(S_raw_tvalid),
        .O_raw_frame_id(S_raw_frame_id),
        .I_isp_sof(S_ISP_O_tuser), .I_isp_valid(S_ISP_O_tvalid),
        .I_isp_frame_id(S_isp_frame_id),
        .I_write_start(S_write_frame_start), .I_write_slot(S_write_start_slot),
        .I_write_word(S_vi_ddr_wr_en),
        .I_read_start(S_read_frame_start), .I_read_slot(S_video_out_rp),
        .I_display_frame_start(S_display_frame_start),
        .O_sample_strobe(S_latency_sample_strobe), .O_sample_valid(S_latency_sample_valid),
        .O_frame_id(S_latency_frame_id), .O_total_us(S_latency_total_us),
        .O_isp_us(S_latency_isp_us), .O_buffer_us(S_latency_buffer_us)
    );

    // Only the 12-bit display setting travels with each buffered frame.
    // Detector coordinates, multi-target slots and result mailboxes are gone.
    effect_frame_bridge #(
        .DEFAULT_EFFECT_CONFIG(DEFAULT_EFFECT_CONFIG)
    ) u_effect_frame_bridge (
        .I_csi_clk(S_csi_rx_clk), .I_ddr_clk(S_ddr_clk),
        .I_hdmi_clk(S_hdmi_pixel_clk), .I_rst_n(S_rst_n),
        .I_frame_start(S_ISP_O_tuser), .I_effect_config(S_ISP_effect_config),
        .I_write_start(S_write_frame_start), .I_write_slot(S_write_start_slot),
        .I_read_start(S_read_frame_start), .I_read_slot(S_video_out_rp),
        .O_effect_config(S_effect_config_hdmi)
    );

//ISP算法顶层模块
isp_top #(
        .ENABLE_EDGE(ENABLE_EDGE),
        .ENABLE_GESTURE(0), // Retired embedded CNN cannot be selected by this top.
        .RED_MULTI_ENABLE(0),
        .ENABLE_TARGET_DETECTION(0),
        .ENABLE_HANDCNN_TAP(ENABLE_HANDCNN != 0)
    ) u_isp_top (
.axi4s_video_aclk(S_csi_rx_clk),
.I_rst_n         (S_rst_n),
.I_effect_config (S_effect_config_csi),
.I_motion_mode_async(1'b0),
.I_color_mode_async(2'd0),
.I_tlast         (S_raw_tlast	),
.I_tuser         (S_raw_tuser	),
.I_tdata         (S_raw_tdata	),
.I_tvalid        (S_raw_tvalid	),
.I_tdest         (S_raw_frame_id),
.O_tready        (S_ISP_O_tready),
.O_tdata         (S_ISP_O_tdata ),
.O_hand_rgb_data (S_hand_rgb_data),
.O_hand_rgb_valid(S_hand_rgb_valid),
.O_hand_rgb_sof  (S_hand_rgb_sof),
.O_tlast         (S_ISP_O_tlast ),
.O_tuser         (S_ISP_O_tuser ),
.O_tvalid        (S_ISP_O_tvalid),
.O_effect_config       (S_ISP_effect_config),
.O_ae_stats_valid      (S_ISP_ae_stats_valid),
.O_ae_sum_y            (S_ISP_ae_sum_y),
.O_ae_sample_count     (S_ISP_ae_sample_count),
.O_ae_bright_count     (S_ISP_ae_bright_count),
.O_latency_frame_id   (S_isp_frame_id),
.I_tready        ()
  );

    wire S_rnet_mem_valid,S_rnet_mem_write,S_rnet_mem_ready,S_rnet_rsp_valid,S_rnet_memory_error;
    wire [31:0] S_rnet_mem_addr;
    wire [127:0] S_rnet_mem_data,S_rnet_rsp_data;
generate if (ENABLE_HANDCNN != 0) begin: handcnn_recognition
    wire raw_write,raw_sof;
    wire [1:0] raw_slot;
    wire [24:0] raw_addr;
    wire [127:0] raw_data;
    // FIFO crosses the color ISP stream to DDR clock. Its output is consumed
    // by the private snapshot writer; it does not write the display slots.
    video_in #(.FRAME_STRIDE_NATIVE(1572864)) raw_color_stream(
        .I_rst_n(S_video_ddr_rst_n),.I_camera_clk(S_csi_rx_clk),
        .I_camera_frame_start(S_hand_rgb_sof),.I_camera_valid(S_hand_rgb_valid),.I_camera_data(S_hand_rgb_data),
        .I_mipi_rx_error(1'b0),.I_ddr_clk(S_ddr_clk),.I_display_pause(1'b0),.I_video_out_rd_busy(1'b0),
        .O_video_in_wr_busy(),.O_video_out_rp(),.O_write_frame_slot(),
        .O_write_frame_start(raw_sof),.O_write_start_slot(raw_slot),
        .O_ddr_user_wr_en(raw_write),.O_ddr_user_addr(raw_addr),.O_ddr_user_wr_data(raw_data),.I_ddr_user_ready(1'b1));
    wire result_valid,box_valid;
    wire [2:0] result_class;
    wire [11:0] x1,y1,x2,y2;
    wire [15:0] result_frame;
    wire [31:0] probe_status;
    handfixed_system #(.KEY4_CONTROL(1),.BACKGROUND_CONTROL(1)) u_handcnn(
        .key4_n(I_param_key_n),
        .clk(S_ddr_clk),.rst_n(S_rst_n),.calibrated(S_init_calib_complete),.memory_error(S_rnet_memory_error),
        .uart_rx(I_resnet_uart_rx),.uart_tx(O_resnet_uart_tx),
        .frame_start(raw_sof),.frame_slot(raw_slot),.video_write(raw_write),.video_addr(raw_addr),.video_data(raw_data),
        .mem_valid(S_rnet_mem_valid),.mem_write(S_rnet_mem_write),.mem_addr(S_rnet_mem_addr),.mem_data(S_rnet_mem_data),
        .mem_ready(S_rnet_mem_ready),.mem_rsp_valid(S_rnet_rsp_valid),.mem_rsp_data(S_rnet_rsp_data),
        .result_valid(result_valid),.result_class(result_class),.model_ready(),.operation(),.runtime_status(probe_status),
        .box_valid(box_valid),.box_x1(x1),.box_y1(y1),.box_x2(x2),.box_y2(y2),.result_frame(result_frame));
    camera_diag_cdc #(.WIDTH(32)) u_status_cdc(
        .I_src_clk(S_ddr_clk),.I_dst_clk(S_hdmi_pixel_clk),.I_rst_n(S_rst_n),
        .I_src_data(probe_status),.O_dst_data(S_resnet_probe_status_hdmi));
    // Class, box and source frame share one acknowledged mailbox. HDMI
    // commits this coherent result at its frame boundary.
    reg [67:0] box_payload;
    wire [67:0] result_hdmi;
    reg [67:0] result_seen;
    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n) box_payload<=0;
        else if(result_valid) box_payload<={result_frame,result_class,box_valid,y2,y1,x2,x1};
    end
    camera_diag_cdc #(.WIDTH(68)) u_hand_box_cdc(
        .I_src_clk(S_ddr_clk),.I_dst_clk(S_hdmi_pixel_clk),.I_rst_n(S_rst_n),
        .I_src_data(box_payload),.O_dst_data(result_hdmi));
    always @(posedge S_hdmi_pixel_clk or negedge S_rst_n) begin
        if(!S_rst_n) result_seen<=0;else result_seen<=result_hdmi;
    end
    assign S_hand_box_hdmi=result_hdmi[48:0];
    assign S_cnn_class_hdmi=result_hdmi[51:49];
    assign S_cnn_result_valid_hdmi=result_hdmi!=result_seen;
end else begin: recognition_disabled
    assign S_cnn_result_valid_hdmi=0;
    assign S_cnn_class_hdmi=3'd1;
    assign S_hand_box_hdmi=0;
    assign S_resnet_probe_status_hdmi=0;
    assign O_resnet_uart_tx=1;
    assign S_rnet_mem_valid=0;
    assign S_rnet_mem_write=0;
    assign S_rnet_mem_addr=0;
    assign S_rnet_mem_data=0;
end endgenerate


    video_in #(.FRAME_STRIDE_NATIVE(ENABLE_HANDCNN != 0 ? 1572864 : 7000000)) u_video_in(
        .I_rst_n              ( S_video_ddr_rst_n    ),

        .I_camera_clk         ( S_csi_rx_clk          ),
        .I_camera_frame_start ( S_ISP_O_tuser  ),
        .I_camera_valid       ( S_ISP_O_tvalid ),
        .I_camera_data        ( S_ISP_O_tdata  ),
        .I_mipi_rx_error      ( 1'b0			      ),

        .I_ddr_clk            ( S_ddr_clk             ),
		.I_display_pause      ( 1'b0                  ),
        .I_video_out_rd_busy  ( S_video_out_rd_busy   ),
        .O_video_in_wr_busy   ( S_video_in_wr_busy    ),
        .O_video_out_rp       ( S_video_out_rp        ),
        .O_write_frame_slot   ( S_write_frame_slot    ),
        .O_write_frame_start  ( S_write_frame_start   ),
        .O_write_start_slot   ( S_write_start_slot    ),

        .O_ddr_user_wr_en     ( S_vi_ddr_wr_en        ),
        .O_ddr_user_addr      ( S_vi_ddr_wr_addr      ),
        .O_ddr_user_wr_data   ( S_vi_ddr_wr_data      ),
        .I_ddr_user_ready     ( S_ddr_user_ready      )
    );



    assign S_ddr_user_wr_en    = S_vi_ddr_wr_en;

    assign S_ddr_user_rd_en    = S_vo_ddr_rd_en;

    assign S_ddr_user_addr     = S_vi_ddr_wr_en ? S_vi_ddr_wr_addr :
                                 S_vo_ddr_rd_en ? S_vo_ddr_rd_addr : 'd0;

    assign S_ddr_user_wr_data  = S_vi_ddr_wr_data;


    assign S_video_out_rst_n = S_video_ddr_rst_n;

    video_out #(.FRAME_STRIDE_NATIVE(ENABLE_HANDCNN != 0 ? 1572864 : 7000000)) u_video_out(
        .I_rst_n             ( S_video_out_rst_n    ),
        .I_ddr_clk           ( S_ddr_clk            ),
 
        .O_video_out_rd_busy ( S_video_out_rd_busy  ),
        .I_video_in_wr_busy  ( S_video_in_wr_busy   ),
        .I_video_out_rp      ( S_video_out_rp       ),
        .O_read_frame_slot   ( S_read_frame_slot    ),
        .O_read_frame_start  ( S_read_frame_start   ),
 
        .O_ddr_user_rd_en    ( S_vo_ddr_rd_en       ),
        .O_ddr_user_addr     ( S_vo_ddr_rd_addr     ),
        .I_ddr_user_ready    ( S_ddr_user_ready     ),
        .I_ddr_user_rd_valid ( S_ddr_user_rd_valid  ),
        .I_ddr_user_rd_data  ( S_ddr_user_rd_data   ),

        .I_dsi_clk           ( S_hdmi_pixel_clk     ),
        .I_video_vsync       ( S_video_out_vsync    ),
        .I_video_rd_en       ( S_hdmi_window_rd_en  ),
        .O_vdieo_data        ( S_video_rd_data      )
    );



    mc_to_user_interface u_mc_to_user_interface(
        .I_clk                   ( S_ddr_clk               ),
        .I_rst_n                 ( S_video_ddr_rst_n       ),

        .I_ddr_user_wr_en        ( S_ddr_user_wr_en        ),
        .I_ddr_user_rd_en        ( S_ddr_user_rd_en        ),
        .I_ddr_user_addr         ( S_ddr_user_addr         ),
        .I_ddr_user_wr_data      ( S_ddr_user_wr_data      ),
        .O_ddr_user_ready        ( S_ddr_user_ready        ),
        .O_ddr_user_rd_valid     ( S_ddr_user_rd_valid     ),
        .O_ddr_user_rd_data      ( S_ddr_user_rd_data      ),
            
        .O_mc_app_en             ( S_mc_app_en             ),
        .O_mc_app_addr           ( S_mc_app_addr           ),
        .O_mc_app_cmd            ( S_mc_app_cmd            ),
        .I_mc_app_rdy            ( S_mc_app_rdy            ),
        .O_mc_app_wdf_wren       ( S_mc_app_wdf_wren       ),
        .O_mc_app_wdf_data       ( S_mc_app_wdf_data       ),
        .O_mc_app_wdf_end        ( S_mc_app_wdf_end        ),
        .O_mc_app_wdf_mask       ( S_mc_app_wdf_mask       ),
        .I_mc_app_wdf_rdy        ( S_mc_app_wdf_rdy        ),
        .I_mc_app_rd_data        ( S_mc_app_rd_data        ),
        .I_mc_app_rd_data_end    ( S_mc_app_rd_data_end    ),
        .I_mc_app_rd_data_valid  ( S_mc_app_rd_data_valid  )
    );



    wire [24:0] S_phy_addr;
    wire [2:0] S_phy_cmd;
    wire S_phy_en,S_phy_wren,S_phy_wend,S_phy_rsp_valid,S_phy_rsp_end;
    wire S_phy_legacy_ready,S_phy_legacy_wready,S_phy_arready,S_phy_awready,S_phy_wready;
    wire [127:0] S_phy_wdata,S_phy_rsp_data;
    wire [15:0] S_phy_mask;
generate if (ENABLE_HANDCNN != 0) begin: shared_resnet_ddr
    wire video_ready,physical_read;
    resnet18_memory_bridge u_bridge(
        .clk(S_ddr_clk),.rst_n(S_rst_n),.calibrated(S_init_calib_complete),
        .v_valid(S_mc_app_en),.v_read(S_mc_app_cmd[0]),.v_addr(S_mc_app_addr),
        .v_data(S_mc_app_wdf_data),.v_ready(video_ready),
        .v_rsp_valid(S_mc_app_rd_data_valid),.v_rsp_data(S_mc_app_rd_data),
        .n_valid(S_rnet_mem_valid),.n_write(S_rnet_mem_write),.n_addr(S_rnet_mem_addr),
        .n_data(S_rnet_mem_data),.n_ready(S_rnet_mem_ready),
        .n_rsp_valid(S_rnet_rsp_valid),.n_rsp_data(S_rnet_rsp_data),
        .d_addr(S_phy_addr),.d_read(physical_read),.d_addr_valid(S_phy_en),
        .d_data_valid(S_phy_wren),.d_data(S_phy_wdata),
        .d_read_ready(S_phy_arready),.d_write_ready(S_phy_awready),.d_data_ready(S_phy_wready),
        .d_rsp_valid(S_phy_rsp_valid),.d_rsp_data(S_phy_rsp_data),.protocol_error(S_rnet_memory_error));
    assign S_phy_cmd={2'b00,physical_read};
    assign S_phy_wend=S_phy_wren;
    assign S_phy_mask=16'd0;
    assign S_mc_app_rdy=video_ready;
    assign S_mc_app_wdf_rdy=video_ready;
    assign S_mc_app_rd_data_end=S_mc_app_rd_data_valid;
end else begin: dedicated_video_ddr
    assign S_phy_addr=S_mc_app_addr;
    assign S_phy_cmd=S_mc_app_cmd;
    assign S_phy_en=S_mc_app_en;
    assign S_phy_wdata=S_mc_app_wdf_data;
    assign S_phy_wren=S_mc_app_wdf_wren;
    assign S_phy_wend=S_mc_app_wdf_end;
    assign S_phy_mask=S_mc_app_wdf_mask;
    assign S_mc_app_rd_data=S_phy_rsp_data;
    assign S_mc_app_rd_data_valid=S_phy_rsp_valid;
    assign S_mc_app_rd_data_end=S_phy_rsp_end;
    assign S_mc_app_rdy=S_phy_legacy_ready;
    assign S_mc_app_wdf_rdy=S_phy_legacy_wready;
    assign S_rnet_mem_ready=0;
    assign S_rnet_rsp_valid=0;
    assign S_rnet_rsp_data=0;
    assign S_rnet_memory_error=0;
end endgenerate
    ph1p35_324_ddr_wrapper u_ph1p35_324_ddr_wrapper(
        .I_sys_clk              ( I_sys_clk              ),
        .I_sys_rst_n            ( S_rst_n                ),

        .O_ddr_clk              ( S_ddr_clk              ),
        .O_init_calib_complete  ( S_init_calib_complete  ),
        .I_mc_app_addr          ( S_phy_addr             ),
        .I_mc_app_cmd           ( S_phy_cmd              ),
        .I_mc_app_en            ( S_phy_en               ),
        .I_mc_app_wdf_data      ( S_phy_wdata            ),
        .I_mc_app_wdf_end       ( S_phy_wend             ),
        .I_mc_app_wdf_mask      ( S_phy_mask             ),
        .I_mc_app_wdf_wren      ( S_phy_wren             ),
        .O_mc_app_rd_data       ( S_phy_rsp_data         ),
        .O_mc_app_rd_data_end   ( S_phy_rsp_end          ),
        .O_mc_app_rd_data_valid ( S_phy_rsp_valid        ),
        .O_mc_app_rdy           ( S_phy_legacy_ready     ),
        .O_mc_app_wdf_rdy       ( S_phy_legacy_wready    ),
        .O_mc_read_ready        ( S_phy_arready          ),
        .O_mc_write_ready       ( S_phy_awready          ),
        .O_mc_data_ready        ( S_phy_wready           ),

        .ddr_addr               ( ddr_addr               ),
        .ddr_ba                 ( ddr_ba                 ),
        .ddr_cke                ( ddr_cke                ),
        .ddr_odt                ( ddr_odt                ),
        .ddr_cs_n               ( ddr_cs_n               ),
        .ddr_ras_n              ( ddr_ras_n              ),
        .ddr_cas_n              ( ddr_cas_n              ),
        .ddr_we_n               ( ddr_we_n               ),
        .ddr_ck_p               ( ddr_ck_p               ),
        .ddr_ck_n               ( ddr_ck_n               ),
        .ddr_dm                 ( ddr_dm                 ),
        .ddr_dq                 ( ddr_dq                 ),
        .ddr_dqs_p              ( ddr_dqs_p              ),
        .ddr_dqs_n              ( ddr_dqs_n              )
    );



    uivtc #(
        .H_ActiveSize ( 1280 ),
        .H_FrameSize  ( 1650 ),
        .H_SyncStart  ( 1390 ),
        .H_SyncEnd    ( 1430 ),
        .V_ActiveSize ( 720  ),
        .V_FrameSize  ( 750  ),
        .V_SyncStart  ( 725  ),
        .V_SyncEnd    ( 730  )
    )u_hdmi_vtc(
        .I_vtc_rstn    ( S_hdmi_rst_n    ),
        .I_vtc_clk     ( S_hdmi_pixel_clk ),
        .O_vtc_vs      ( S_hdmi_vsync     ),
        .O_vtc_hs      ( S_hdmi_hsync     ),
        .O_vtc_de_valid( S_hdmi_de        ),
        .O_vtc_user    ( S_hdmi_user      ),
        .O_vtc_last    ( S_hdmi_last      )
    );

    hdmi_mixer #(
        .H_OFFSET   ( 0    ),
        .V_OFFSET   ( 0    ),
        .IMG_WIDTH  ( 1280 ),
        .IMG_HEIGHT ( 720  ),
        .DEBUG_MODE ( 0    ),
        .SHOW_CAMERA_STATUS ( 0 ), // Remove the four camera-status blocks.
        .SHOW_COLOR_TARGET  ( 0 ), // ResNet is the only active detector.
        .MULTI_TARGET_ENABLE( 0 ),
        .SHOW_RED_MASK      ( 0 ), // Front-end metadata carries no per-pixel mask.
        .SHOW_LATENCY       ( 1 ),
        .LATENCY_SWITCH_ENABLE( 1 ),
        .SHOW_EFFECT_LABEL  ( 1 ),
        // The current model consumes the whole frame, not a centered crop.
        .CNN_FULL_FRAME_INPUT ( 1 ),
        .HANDCNN_DYNAMIC_ROI(ENABLE_HANDCNN != 0),
        // Keep the last completed result while the next inference computes.
        // The second status row distinguishes loading/capture/inference/errors.
        // Hand-CNN and ResNet refresh on completed results, without expiry.
        .CNN_RESULT_TIMEOUT_FRAMES ( (ENABLE_HANDCNN != 0) ? 0 : 60 ),
        .SHOW_RESNET_RUNTIME ( ENABLE_HANDCNN != 0 ? 1 : 0 ),
        // The resource probe has no classifier: its class remains NOTHING.
        .SHOW_RESNET_PROBE  ( 0 ),
        .SHOW_RAW_STATS     ( SHOW_RAW_STATS )
    )u_hdmi_mixer(
        .I_clk           ( S_hdmi_pixel_clk   ),
        .I_rst_n         ( S_hdmi_rst_n       ),
        .I_video_vsync   ( S_hdmi_vsync       ),
        .I_video_hsync   ( S_hdmi_hsync       ),
        .I_video_de      ( S_hdmi_de          ),
        .I_video_user    ( S_hdmi_user        ),
        .I_video_last    ( S_hdmi_last        ),
        .I_effect_mode   ( S_effect_config_hdmi[11:8] ),
        .I_effect_param  ( S_effect_config_hdmi[7:0] ),
        .I_debug_status  ( S_hdmi_debug_status),
        .I_cam_fail_index( S_cam_fail_sync    ),
        .I_raw_stats_valid(S_raw_stats_valid),
        .I_raw_stats_data (S_raw_stats_data),
        .I_ae_readout_valid(S_ae_readout_valid),
        .I_ae_readout_data(S_ae_readout_data),
        .I_latency_sample_strobe(S_latency_sample_strobe),
        .I_latency_show(I_latency_switch),
        .I_latency_sample_valid(S_latency_sample_valid),
        .I_latency_total_us(S_latency_total_us),
        .I_latency_isp_us(S_latency_isp_us),
        .I_latency_buffer_us(S_latency_buffer_us),
        .I_cnn_result_valid(S_cnn_result_valid_hdmi),
        .I_cnn_class(S_cnn_class_hdmi),
        .I_hand_box_valid(S_hand_box_hdmi[48]),
        .I_hand_box(S_hand_box_hdmi[47:0]),
        .I_resnet_probe_status(S_resnet_probe_status_hdmi),
        .O_display_frame_start(S_display_frame_start),
        .O_video_rd_en   ( S_hdmi_window_rd_en),
        .I_video_rd_data ( S_video_rd_data    ),
        .I_target_result_ready ( 1'b0 ),
        .I_target_found        ( 1'b0 ),
        .I_target_motion_mode  ( 1'b0 ),
        .I_target_color_mode   ( 2'd0 ),
        .I_target_xmin         ( 12'd0 ),
        .I_target_xmax         ( 12'd0 ),
        .I_target_ymin         ( 12'd0 ),
        .I_target_ymax         ( 12'd0 ),
        .I_target_center_x     ( 12'd0 ),
        .I_target_center_y     ( 12'd0 ),
        .I_target_multi_valid  ( 4'd0 ),
        .I_target_multi_hold   ( 4'd0 ),
        .I_target_multi_boxes  ( 192'd0 ),
        .I_target_multi_overflow( 1'b0 ),
        .O_hdmi_vsync    ( S_hdmi_out_vsync   ),
        .O_hdmi_hsync    ( S_hdmi_out_hsync   ),
        .O_hdmi_de       ( S_hdmi_out_de      ),
        .O_hdmi_data     ( S_hdmi_out_data    )
    );

    hdmi_tx u_hdmi_tx(
        .I_pixel_clk        ( S_hdmi_pixel_clk  ),
        .I_serial_clk       ( S_hdmi_serial_clk ),
        .I_rst              ( ~S_hdmi_rst_n     ),
        .I_key_in           ( 1'b0              ),
        .I_edid_read_trig   ( 1'b0              ),
        .O_edid_read_valid  (                   ),
        .O_edid_read_data   (                   ),
        .I_video_rgb_enable ( 1'b1              ),
        .I_video_in_vs      ( S_hdmi_out_vsync  ),
        .I_video_in_de      ( S_hdmi_out_de     ),
        .I_video_in_user    ( 1'b0              ),
        .I_video_in_valid   ( 1'b0              ),
        .I_video_in_last    ( 1'b0              ),
        .O_video_in_ready   (                   ),
        .I_video_in_data    ( S_hdmi_out_data   ),
        .I_audio_valid      ( 1'b0              ),
        .I_audio_left_data  ( 24'd0             ),
        .I_audio_right_data ( 24'd0             ),
        .I_i2s_BCLK         ( 1'b0              ),
        .I_i2s_LRCK         ( 1'b0              ),
        .I_i2s_DOUT         ( 1'b0              ),
        .O_ddc_scl          (                   ),
        .O_hdmi_clk_p       (                   ),
        .O_hdmi_tx_p        (                   ),
        .O_tmds_ch0_p       ( O_tmds_ch0_p      ),
        .O_tmds_ch1_p       ( O_tmds_ch1_p      ),
        .O_tmds_ch2_p       ( O_tmds_ch2_p      ),
        .O_tmds_clk_p       ( O_tmds_clk_p      )
    );


    
endmodule
