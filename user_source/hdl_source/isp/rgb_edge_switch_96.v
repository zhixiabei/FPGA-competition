// Frame-boundary RGB/spatial-effect/color-mask camera selector.
// The synchronized mode/parameter snapshot commits on input SOF, including
// SOF before the first valid beat. Data, markers and configuration all have
// twelve registered clocks of latency, and bubbles advance all paths.
module rgb_edge_switch_96 #(
    parameter integer IMG_WIDTH=1280,
    parameter integer IMG_HEIGHT=720,
    parameter integer EDGE_TH=20,
    parameter integer DEFAULT_EDGE_MODE=1
)(
    input wire I_clk,input wire I_rst_n,input wire [11:0] I_effect_config,
    input wire I_tlast,input wire I_tuser,input wire [95:0] I_tdata,
    input wire I_tvalid,
    input wire [3:0] I_mask_pixels,
    output wire O_tlast,output wire O_tuser,output wire [95:0] O_tdata,
    output wire O_tvalid,output wire O_edge_mode,
    output wire [11:0] O_effect_config
);
    localparam integer LATENCY=11;
    localparam [11:0] DEFAULT_CONFIG =
        {(DEFAULT_EDGE_MODE!=0) ? 4'd2 : 4'd0, 8'd0};
    reg [11:0] active_config;
    wire [11:0] frame_config = I_tuser ? I_effect_config : active_config;
    wire [95:0] rgb_delayed;
    reg [11:0] config_delay [0:LATENCY-1];
    reg [LATENCY-2:0] select_valid_delay;
    wire [95:0] edge_data,emboss_data,cartoon_data,morph_data;
    wire selected_last, selected_user, selected_valid;
    wire [95:0] selected_data;
    reg [95:0] output_data;
    reg [2:0] output_markers;
    reg [11:0] output_config;
    // The detector shares its binary windows with the shape engine. Its
    // four mask bits already have the same eleven-clock latency as this
    // selector; expand only at the output, with lane 0 displayed first.
    wire [95:0] mask_data = {{24{I_mask_pixels[0]}},
                             {24{I_mask_pixels[1]}},
                             {24{I_mask_pixels[2]}},
                             {24{I_mask_pixels[3]}}};
    integer i;
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            active_config<=DEFAULT_CONFIG;
            select_valid_delay<=0;
            for(i=0;i<LATENCY;i=i+1) config_delay[i]<=DEFAULT_CONFIG;
        end else begin
            select_valid_delay<={select_valid_delay[LATENCY-3:0],I_tvalid};
            if(I_tuser) active_config<=I_effect_config;
            config_delay[0]<=frame_config;
            for(i=1;i<LATENCY;i=i+1) config_delay[i]<=config_delay[i-1];
        end
    end
    // No reset is needed for pixel storage: O_tvalid remains low until all
    // LATENCY clocks have been filled after reset. Shift on bubbles as well.
    // Keep registers at both ends of the short shift memory. This releases
    // five ERAM sites without the placement cost of eleven full FF stages.
    (* shifter_style="reg_shifter_reg" *) reg [95:0] rgb_delay[0:LATENCY-1];
    integer pixel_stage;
    always @(posedge I_clk) begin
        rgb_delay[0]<=I_tdata;
        for(pixel_stage=1;pixel_stage<LATENCY;pixel_stage=pixel_stage+1)
            rgb_delay[pixel_stage]<=rgb_delay[pixel_stage-1];
    end
    assign rgb_delayed=rgb_delay[LATENCY-1];
    scharr_edge_detect_96 #(
        .IMG_WIDTH(IMG_WIDTH),.IMG_HEIGHT(IMG_HEIGHT),.EDGE_TH(EDGE_TH)
    ) u_scharr_edge_detect_96 (
        .I_clk(I_clk),.I_rst_n(I_rst_n),.I_tlast(I_tlast),.I_tuser(I_tuser),
        .I_tdata(I_tdata),.I_tvalid(I_tvalid),.I_tready(1'b1),
        .O_tlast(selected_last),.O_tuser(selected_user),.O_tdata(edge_data),
        .O_emboss_data(emboss_data),.O_cartoon_data(cartoon_data),
        .O_morph_data(morph_data),
        .O_tvalid(selected_valid),.O_tready()
    );
    function [5:0] decode_effect;
        input [3:0] mode;
        begin
            case(mode)
                4'd2,4'd7: decode_effect=6'b000010;
                4'd4: decode_effect=6'b000100;
                4'd6: decode_effect=6'b001000;
                4'd8: decode_effect=6'b010000;
                4'd9,4'd10,4'd11,4'd12: decode_effect=6'b100000;
                default: decode_effect=6'b000001;
            endcase
        end
    endfunction
    // Decode in the existing last control stage. Each lane gets local
    // selection registers, without adding a pixel or marker pipeline stage.
    genvar output_lane;
    generate for(output_lane=0;output_lane<4;output_lane=output_lane+1) begin: output_lanes
        (* preserve=1 *) reg [5:0] select_effect;
        always @(posedge I_clk or negedge I_rst_n) begin
            if(!I_rst_n) select_effect<=0;
            else select_effect<=select_valid_delay[LATENCY-2] ?
                decode_effect(config_delay[LATENCY-2][11:8]) : 6'd0;
        end
        assign selected_data[95-output_lane*24 -:24]=
            ({24{select_effect[0]}} & rgb_delayed[95-output_lane*24 -:24]) |
            ({24{select_effect[1]}} & edge_data[95-output_lane*24 -:24]) |
            ({24{select_effect[2]}} & emboss_data[95-output_lane*24 -:24]) |
            ({24{select_effect[3]}} & cartoon_data[95-output_lane*24 -:24]) |
            ({24{select_effect[4]}} & morph_data[95-output_lane*24 -:24]) |
            ({24{select_effect[5]}} & mask_data[95-output_lane*24 -:24]);
    end endgenerate
    // Separate effect selection from the downstream 96-to-128 packing mux.
    // All metadata crosses this boundary with its pixel, including bubbles.
    always @(posedge I_clk) output_data<=selected_data;
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            output_markers<=0;
            output_config<=DEFAULT_CONFIG;
        end else begin
            output_markers<={selected_valid,selected_user,selected_last};
            output_config<=config_delay[LATENCY-1];
        end
    end
    assign O_tdata=output_data;
    assign {O_tvalid,O_tuser,O_tlast}=output_markers;
    assign O_effect_config=output_config;
    assign O_edge_mode=O_effect_config[11:8]==4'd2;
endmodule
