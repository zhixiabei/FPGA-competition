// Standalone temporary bitstream, loaded into SRAM through JTAG.
module fruit_flash_program_top(
    input wire I_sys_clk,I_rst_n,I_resnet_uart_rx,
    output wire O_resnet_uart_tx,
    output wire O_model_flash_cs_n,O_model_flash_sck,O_model_flash_mosi,
    output wire O_model_flash_wp_n,O_model_flash_hold_n,
    input wire I_model_flash_miso
);
    reg [15:0] startup=0;
    always @(posedge I_sys_clk) if(!(&startup)) startup<=startup+1'b1;
    wire rst_n=I_rst_n && (&startup);
    wire [17:0] address;
    wire [7:0] data;
    wire [255:0] status;
    fruit_flash_model_rom rom(.clk(I_sys_clk),.address(address),.data(data));
    fruit_flash_programmer programmer(.clk(I_sys_clk),.rst_n(rst_n),
        .rom_address(address),.rom_data(data),.cs_n(O_model_flash_cs_n),
        .sck(O_model_flash_sck),.mosi(O_model_flash_mosi),.miso(I_model_flash_miso),
        .diagnostics(status),.finished(),.error_code());
    flash_status_uart #(.CLOCK_HZ(50000000)) status_uart(.clk(I_sys_clk),.rst_n(rst_n),
        .rx(I_resnet_uart_rx),.tx(O_resnet_uart_tx),.runtime_status(status),.flash_status(status));
    assign O_model_flash_wp_n=1'b1;
    assign O_model_flash_hold_n=1'b1;
endmodule
