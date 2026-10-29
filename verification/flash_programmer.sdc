create_clock -name sys_clk_50m -period 20.000 [get_ports I_sys_clk]
set_false_path -from [get_ports I_rst_n]
set_false_path -from [get_ports I_resnet_uart_rx]
# Board-returned data enters a two-flop synchronizer. SPI samples eight clocks
# after its previous falling edge; only the first capture is asynchronous.
set_false_path -from [get_ports I_model_flash_miso] -to [get_regs {programmer/bus/miso_meta}]
set_output_delay -max 5.000 -clock sys_clk_50m [get_ports {O_model_flash_cs_n O_model_flash_sck O_model_flash_mosi}]
set_output_delay -min 0.000 -clock sys_clk_50m [get_ports {O_model_flash_cs_n O_model_flash_sck O_model_flash_mosi}]
