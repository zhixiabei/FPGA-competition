// Free-running microsecond time. Each update advances by one so the
// registered Gray bus can be sampled by independent video clocks.
module video_latency_timebase #(
    parameter integer TIME_WIDTH = 32,
    parameter integer TIME_NUM = 1,
    parameter integer TIME_DEN = 50
) (
    input wire I_clk,
    input wire I_rst_n,
    output reg [TIME_WIDTH-1:0] O_time_us,
    output reg [TIME_WIDTH-1:0] O_time_gray
);
    localparam integer PHASE_WIDTH = $clog2(TIME_DEN+TIME_NUM+1);
    reg [PHASE_WIDTH-1:0] S_phase;
    wire [PHASE_WIDTH:0] S_phase_next = {1'b0,S_phase} + TIME_NUM;
    wire [TIME_WIDTH-1:0] S_time_next = O_time_us + 1'b1;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            S_phase <= 0;
            O_time_us <= 0;
            O_time_gray <= 0;
        end else if (S_phase_next >= TIME_DEN) begin
            S_phase <= S_phase_next - TIME_DEN;
            O_time_us <= S_time_next;
            O_time_gray <= (S_time_next >> 1) ^ S_time_next;
        end else
            S_phase <= S_phase_next;
    end
endmodule
