// Same switchable RGB/edge pipeline, with RGB selected after reset.
module sc520_capture_top (
    input wire        I_sys_clk,
    input wire        I_rst_n,
    input wire        I_resnet_uart_rx, // Shared board UART pin; video-only mode ignores RX.
    output wire       O_resnet_uart_tx,
      
    output wire       O_cam_scl,
    inout  wire       IO_cam_sda,
    output wire       O_cam_24m,
    output wire       O_cam_rst,
      
    inout wire [1:0]  I_button,
    input wire        I_mode_key_n, // Board K1 (D5), cycle display algorithms.
    input wire        I_detect_key_n, // Board K2 (A9), active low.
    input wire        I_effect_key_n, // Board K3 (B9), reserved.
    input wire        I_fruit_switch, // Board SW2 (B4), reserved in video-only project.
    input wire        I_latency_switch, // Board SW1 (A4), high to show latency panel.
    input wire        I_param_key_n, // Board K4 (C7), reserved.

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
    design_top_wrapper #(.ENABLE_EDGE(0),.ENABLE_HANDCNN(0)) u_video (
        .I_sys_clk(I_sys_clk),
        .I_rst_n(I_rst_n),
        .I_resnet_uart_rx(I_resnet_uart_rx),
        .O_resnet_uart_tx(O_resnet_uart_tx),
        .O_cam_scl(O_cam_scl),
        .IO_cam_sda(IO_cam_sda),
        .O_cam_24m(O_cam_24m),
        .O_cam_rst(O_cam_rst),
        .I_button(I_button),
        .I_mode_key_n(I_mode_key_n),
        .I_detect_key_n(I_detect_key_n),
        .I_effect_key_n(I_effect_key_n),
        .I_latency_switch(I_latency_switch),
        .I_fruit_switch(I_fruit_switch),
        .I_param_key_n(I_param_key_n),
        .O_screen_pwm(O_screen_pwm),
        .O_tmds_ch0_p(O_tmds_ch0_p),
        .O_tmds_ch1_p(O_tmds_ch1_p),
        .O_tmds_ch2_p(O_tmds_ch2_p),
        .O_tmds_clk_p(O_tmds_clk_p),
        .IO_rx_clk_pad_n(IO_rx_clk_pad_n),
        .IO_rx_clk_pad_p(IO_rx_clk_pad_p),
        .IO_rx_data_pad_n(IO_rx_data_pad_n),
        .IO_rx_data_pad_p(IO_rx_data_pad_p),
        .ddr_addr(ddr_addr),
        .ddr_ba(ddr_ba),
        .ddr_cke(ddr_cke),
        .ddr_odt(ddr_odt),
        .ddr_cs_n(ddr_cs_n),
        .ddr_ras_n(ddr_ras_n),
        .ddr_cas_n(ddr_cas_n),
        .ddr_we_n(ddr_we_n),
        .ddr_ck_p(ddr_ck_p),
        .ddr_ck_n(ddr_ck_n),
        .ddr_dm(ddr_dm),
        .ddr_dq(ddr_dq),
        .ddr_dqs_p(ddr_dqs_p),
        .ddr_dqs_n(ddr_dqs_n)
    );
endmodule
