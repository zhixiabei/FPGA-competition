// Fixed display tone curve, one registered RGB888 pixel per clock.
// Offline linear interpolation, rounded to nearest (half up), from:
// x: 0,16,32,64,96,128,160,192,224,240,255
// y: 0,23,44,80,104,128,152,180,210,232,255
module gamma_lut_rgb888 #(
    parameter integer ENABLE = 1
) (
    input wire        I_clk,
    input wire [23:0] I_rgb,
    output reg [23:0] O_rgb
);
    // Byte 0 is at the least significant end. All interpolation is offline.
    localparam [2047:0] TONE_LUT = {
        128'hfffdfcfaf9f7f6f4f3f1f0eeedebeae8,
        128'he7e5e4e3e1e0dedddcdad9d8d6d5d3d2,
        128'hd1d0cfcecdcccbcbcac9c8c7c6c5c4c3,
        128'hc2c1c0bfbebdbcbcbbbab9b8b7b6b5b4,
        128'hb3b2b1b1b0afaeadacabaaaaa9a8a7a6,
        128'ha5a4a3a3a2a1a09f9e9d9c9c9b9a9998,
        128'h97979695949493929191908f8e8e8d8c,
        128'h8b8b8a89888887868585848382828180,
        128'h7f7f7e7d7c7c7b7a7979787776767574,
        128'h7373727170706f6e6d6d6c6b6a6a6968,
        128'h67676665646463626161605f5e5e5d5c,
        128'h5b5b5a59585857565555545352525150,
        128'h4f4e4d4c4a4948474645444341403f3e,
        128'h3d3c3b3a38373635343332312f2e2d2c,
        128'h2b29282725242322201f1e1c1b1a1817,
        128'h16141311100e0d0c0a09070604030100
    };

    // TD's "none" ROM style implements these three read ports in logic,
    // rather than allocating three ERAM blocks to the small constant table.
    (* rom_style = "none" *) reg [7:0] tone_rom [0:255];
    integer table_index;
    initial begin
        for (table_index = 0; table_index < 256; table_index = table_index+1)
            tone_rom[table_index] = TONE_LUT[table_index*8 +: 8];
    end

    // Both modes retain the original first pixel register. Pixels need no
    // reset because the mixer's DE pipeline suppresses them during reset.
    always @(posedge I_clk) begin
        if (ENABLE != 0) begin
            O_rgb[23:16] <= tone_rom[I_rgb[23:16]];
            O_rgb[15:8]  <= tone_rom[I_rgb[15:8]];
            O_rgb[7:0]   <= tone_rom[I_rgb[7:0]];
        end else begin
            O_rgb <= I_rgb;
        end
    end
endmodule
