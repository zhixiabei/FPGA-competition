set clkw [get_clocks -nowarn -of [get_ports {clkw}]]
set clkr [get_clocks -nowarn -of [get_ports {clkr}]]

set wr_clk_period [get_property -nowarn -max PERIOD $clkw]
set rd_clk_period [get_property -nowarn -max PERIOD $clkr]

set dly_sly_slack 0.3

# TD can evaluate the generated raw_color_stream instance at top-level scope,
# where clkw/clkr are not ports. A 1000 ns fallback silently leaves its Gray
# bus unbounded for the real clock. In this project the fastest FIFO clock is
# MIPI_RX_BYTE_CLK: 4 * 2.415 ns = 9.660 ns. Use that conservative period for
# either unresolved port; the build checks all 54 effective Gray-bus paths.
if { $clkw =="" } {
    set wr_clk_period 9.660
}

if { $clkr =="" } {
    set rd_clk_period 9.660
}

set_max_delay -from [get_regs -nowarn {*/primary_addr_gray_reg[*]}] -to [get_regs -nowarn {*/sync_r1[*]}] [expr min($wr_clk_period,$rd_clk_period) - $dly_sly_slack] -nowarn -datapath_only
