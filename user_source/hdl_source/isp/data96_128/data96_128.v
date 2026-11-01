// Four 96-bit input beats form three 128-bit output beats. A line must
// contain a multiple of four beats; a valid gap restarts the group phase.
module data_96bit_to_128bit (
    input wire        I_clk,
    input wire        I_rst_n,
    input wire        I_96b_frame_start,
    input wire        I_96b_valid,
    input wire [95:0] I_96b_data,
    output reg        O_128b_frame_start,
    output reg        O_128b_valid,
    output reg [127:0] O_128b_data
);
    reg [95:0] previous_data;
    wire [1:0] valid_phase;

    always @(posedge I_clk) previous_data<=I_96b_data;

    // Parallel phase copies drive local 32-bit muxes at the original cycle.
    // Only valid beats enter the FIFO; invalid data needs no clear or enable.
    genvar bank;
    generate for(bank=0;bank<4;bank=bank+1) begin: packing_banks
        (* preserve=1 *) reg [1:0] phase;
        wire [127:0] word_data=phase==2'd1 ? {previous_data,I_96b_data[95:64]} :
            phase==2'd2 ? {previous_data[63:0],I_96b_data[95:32]} :
                         {previous_data[31:0],I_96b_data};
        always @(posedge I_clk or negedge I_rst_n) begin
            if(!I_rst_n) phase<=0;
            else phase<=I_96b_valid ? phase+2'd1 : 2'd0;
        end
        always @(posedge I_clk)
            O_128b_data[bank*32 +:32]<=word_data[bank*32 +:32];
        if(bank==0) assign valid_phase=phase;
    end endgenerate

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            O_128b_valid<=0;
            O_128b_frame_start<=0;
        end else begin
            O_128b_valid<=I_96b_valid && valid_phase!=0;
            O_128b_frame_start<=I_96b_frame_start;
        end
    end
endmodule

