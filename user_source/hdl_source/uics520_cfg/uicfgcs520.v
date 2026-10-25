`timescale 1ns / 1ps

module uicfgcs520 #(
    parameter integer CLK_DIV = 16'd239
) (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_ae_req,
    input  wire [15:0] I_ae,
    input  wire [15:0] I_ag,
    output wire        O_cam_scl,
    inout  wire        IO_cam_sda,
    output reg         O_cfg_done,
    output reg         O_ae_cfg_done,
    output reg  [15:0] O_sensor_id,
    output reg         O_sensor_id_ok,
    output reg         O_iic_error,
    output reg  [7:0]  O_fail_index
);
    localparam [7:0] CAM_ID = 8'h6c;

    localparam [3:0] ST_IDH_REQ  = 4'd0;
    localparam [3:0] ST_IDH_BUSY = 4'd1;
    localparam [3:0] ST_IDH_DONE = 4'd2;
    localparam [3:0] ST_IDL_REQ  = 4'd3;
    localparam [3:0] ST_IDL_BUSY = 4'd4;
    localparam [3:0] ST_IDL_DONE = 4'd5;
    localparam [3:0] ST_CHECK_ID = 4'd6;
    localparam [3:0] ST_IDLE     = 4'd7;
    localparam [3:0] ST_WR_REQ   = 4'd8;
    localparam [3:0] ST_WR_BUSY  = 4'd9;
    localparam [3:0] ST_WR_DONE  = 4'd10;
    localparam [3:0] ST_ERROR    = 4'd11;
    localparam [3:0] ST_RESET_WAIT = 4'd12;
    localparam [3:0] ST_RETRY_WAIT = 4'd13;
    localparam integer RESET_WAIT_CYCLES = 119048; // 5 ms at 23.809524 MHz
    localparam [1:0] MAX_RETRIES = 2'd3;

    reg  [3:0]  state;
    reg         iic_req;
    reg  [7:0]  wr_cnt;
    reg  [7:0]  rd_cnt;
    reg  [31:0] wr_data;
    reg  [8:0]  reg_index;
    reg  [16:0] reset_wait_cnt;
    reg         ae_table_active;
    reg  [1:0]  retry_count;
    reg  [3:0]  retry_state;
    wire        iic_busy;
    wire        iic_bus_error;
    wire [7:0]  rd_data;

    wire [23:0] init_reg_data;
    wire [8:0]  init_reg_size;
    wire [23:0] ae_reg_data;
    wire [8:0]  ae_reg_size;
    wire [23:0] gain_value;
    wire [23:0] selected_reg_data = ae_table_active ? ae_reg_data : init_reg_data;
    wire [8:0]  selected_reg_size = ae_table_active ? ae_reg_size : init_reg_size;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            state            <= ST_IDH_REQ;
            iic_req          <= 1'b0;
            wr_cnt           <= 8'd3;
            rd_cnt           <= 8'd1;
            wr_data          <= 32'd0;
            reg_index        <= 9'd0;
            reset_wait_cnt   <= 17'd0;
            ae_table_active  <= 1'b0;
            retry_count      <= 2'd0;
            retry_state      <= ST_IDH_REQ;
            O_cfg_done       <= 1'b0;
            O_ae_cfg_done    <= 1'b0;
            O_sensor_id      <= 16'd0;
            O_sensor_id_ok   <= 1'b0;
            O_iic_error      <= 1'b0;
            O_fail_index     <= 8'd0;
        end else begin
            // The bus reports NACK only after STOP. Retry the same transaction;
            // a persistent fault must never advance the register table.
            if (iic_bus_error) begin
                O_fail_index  <= reg_index[7:0];
                O_ae_cfg_done <= 1'b0;
                iic_req       <= 1'b0;
                if (retry_count < MAX_RETRIES) begin
                    retry_count <= retry_count + 1'b1;
                    reset_wait_cnt <= 17'd0;
                    case (state)
                        ST_IDH_BUSY, ST_IDH_DONE: retry_state <= ST_IDH_REQ;
                        ST_IDL_BUSY, ST_IDL_DONE: retry_state <= ST_IDL_REQ;
                        default: retry_state <= ST_WR_REQ;
                    endcase
                    state <= ST_RETRY_WAIT;
                end else begin
                    O_iic_error <= 1'b1;
                    O_cfg_done <= 1'b0;
                    state <= ST_ERROR;
                end
            end else case (state)
                ST_IDH_REQ: if (!iic_busy) begin
                    wr_data <= {8'h00, 8'h07, 8'h31, CAM_ID};
                    wr_cnt <= 8'd3;
                    rd_cnt <= 8'd1;
                    iic_req <= 1'b1;
                    state <= ST_IDH_BUSY;
                end
                ST_IDH_BUSY: if (iic_busy) begin
                    iic_req <= 1'b0;
                    state <= ST_IDH_DONE;
                end
                ST_IDH_DONE: if (!iic_busy) begin
                    O_sensor_id[15:8] <= rd_data;
                    retry_count <= 2'd0;
                    state <= ST_IDL_REQ;
                end
                ST_IDL_REQ: if (!iic_busy) begin
                    wr_data <= {8'h00, 8'h08, 8'h31, CAM_ID};
                    wr_cnt <= 8'd3;
                    rd_cnt <= 8'd1;
                    iic_req <= 1'b1;
                    state <= ST_IDL_BUSY;
                end
                ST_IDL_BUSY: if (iic_busy) begin
                    iic_req <= 1'b0;
                    state <= ST_IDL_DONE;
                end
                ST_IDL_DONE: if (!iic_busy) begin
                    O_sensor_id[7:0] <= rd_data;
                    retry_count <= 2'd0;
                    state <= ST_CHECK_ID;
                end
                ST_CHECK_ID: begin
                    if ((O_sensor_id == 16'hee4b) ||
                        (O_sensor_id == 16'h9e4b)) begin
                        O_sensor_id_ok <= 1'b1;
                        reg_index <= 9'd0;
                        ae_table_active <= 1'b0;
                        state <= ST_IDLE;
                    end else begin
                        state <= ST_ERROR;
                    end
                end
                ST_IDLE: begin
                    if (!O_cfg_done) begin
                        if (reg_index == init_reg_size) begin
                            O_cfg_done <= 1'b1;
                            O_ae_cfg_done <= 1'b1;
                        end else begin
                            state <= ST_WR_REQ;
                        end
                    end else if (ae_table_active) begin
                        if (reg_index == ae_reg_size) begin
                            ae_table_active <= 1'b0;
                            O_ae_cfg_done <= 1'b1;
                        end else begin
                            state <= ST_WR_REQ;
                        end
                    end else if (I_ae_req) begin
                        ae_table_active <= 1'b1;
                        O_ae_cfg_done <= 1'b0;
                        reg_index <= 9'd0;
                    end
                end
                ST_WR_REQ: if (!iic_busy) begin
                    wr_data[7:0]   <= CAM_ID;
                    wr_data[15:8]  <= selected_reg_data[23:16];
                    wr_data[23:16] <= selected_reg_data[15:8];
                    wr_data[31:24] <= selected_reg_data[7:0];
                    wr_cnt <= 8'd4;
                    rd_cnt <= 8'd0;
                    iic_req <= 1'b1;
                    state <= ST_WR_BUSY;
                end
                ST_WR_BUSY: if (iic_busy) begin
                    iic_req <= 1'b0;
                    state <= ST_WR_DONE;
                end
                ST_WR_DONE: if (!iic_busy) begin
                    retry_count <= 2'd0;
                    reg_index <= reg_index + 1'b1;
                    if (!ae_table_active && (reg_index == 9'd0)) begin
                        reset_wait_cnt <= 17'd0;
                        state <= ST_RESET_WAIT;
                    end else begin
                        state <= ST_IDLE;
                    end
                end
                ST_RESET_WAIT: begin
                    if (reset_wait_cnt == RESET_WAIT_CYCLES - 1) begin
                        state <= ST_IDLE;
                    end else begin
                        reset_wait_cnt <= reset_wait_cnt + 1'b1;
                    end
                end
                ST_RETRY_WAIT: begin
                    if (reset_wait_cnt == RESET_WAIT_CYCLES - 1) begin
                        state <= retry_state;
                    end else begin
                        reset_wait_cnt <= reset_wait_cnt + 1'b1;
                    end
                end
                ST_ERROR: begin
                    iic_req <= 1'b0;
                    O_cfg_done <= 1'b0;
                    O_ae_cfg_done <= 1'b0;
                end
                default: state <= ST_ERROR;
            endcase
        end
    end

    sc520_i2c #(
        .CLK_DIV(CLK_DIV)
    ) u_i2c (
        .I_clk(I_clk),
        .I_rstn(I_rst_n),
        .O_iic_scl(O_cam_scl),
        .IO_iic_sda(IO_cam_sda),
        .I_wr_data(wr_data),
        .I_wr_cnt(wr_cnt),
        .O_rd_data(rd_data),
        .I_rd_cnt(rd_cnt),
        .I_iic_req(iic_req),
        .O_iic_busy(iic_busy),
        .O_iic_bus_error(iic_bus_error)
    );

    // Supplied SC520CS 1280x720@60 table, with 0x3220=0x81 and
    // 0x3222=0x00 for free-running output without an external FSIN trigger.
    uics520reg_720p60 u_init_regs (
        .REG_INDEX(reg_index),
        .REG_DATA(init_reg_data),
        .REG_SIZE(init_reg_size)
    );

    SC520GainTbl u_gain (
        .I_AG(I_ag),
        .O(gain_value)
    );

    uics520regAE u_ae_regs (
        .REG_INDEX(reg_index),
        .REG_DATA(ae_reg_data),
        .REG_SIZE(ae_reg_size),
        .I_AE(I_ae),
        .I_AG(gain_value)
    );
endmodule

// SC520 uses four-byte writes and a repeated START for single-byte ID reads.
// All state and bus outputs use I_clk; the divider is a clock enable.
module sc520_i2c #(
    parameter integer CLK_DIV = 239
) (
    input  wire        I_clk,
    input  wire        I_rstn,
    input  wire [31:0] I_wr_data,
    input  wire [7:0]  I_wr_cnt,
    input  wire [7:0]  I_rd_cnt,
    input  wire        I_iic_req,
    output reg         O_iic_scl,
    inout  wire        IO_iic_sda,
    output reg  [7:0]  O_rd_data,
    output reg         O_iic_busy,
    output reg         O_iic_bus_error
);
    localparam integer QUARTER_CYCLES =
        ((CLK_DIV + 4) / 4 < 3) ? 3 : (CLK_DIV + 4) / 4;
    localparam [3:0] BUS_IDLE    = 4'd0;
    localparam [3:0] BUS_START   = 4'd1;
    localparam [3:0] BUS_WRITE   = 4'd2;
    localparam [3:0] BUS_ACK     = 4'd3;
    localparam [3:0] BUS_RESTART = 4'd4;
    localparam [3:0] BUS_READ    = 4'd5;
    localparam [3:0] BUS_NACK    = 4'd6;
    localparam [3:0] BUS_STOP    = 4'd7;
    localparam [3:0] BUS_FREE    = 4'd8;

    reg [3:0] state;
    reg [15:0] divider;
    reg [1:0] phase;
    reg [2:0] bit_index;
    reg [1:0] write_index;
    reg [31:0] write_data;
    reg [7:0] write_count;
    reg [7:0] tx_byte;
    reg read_requested;
    reg read_address;
    reg transaction_error;
    reg boundary_hold;
    reg sda_low;
    (* async_reg = "true" *) reg sda_meta;
    (* async_reg = "true" *) reg sda_sync;

    assign IO_iic_sda = sda_low ? 1'b0 : 1'bz;

    always @(posedge I_clk or negedge I_rstn) begin
        if (!I_rstn) begin
            sda_meta <= 1'b1;
            sda_sync <= 1'b1;
        end else begin
            sda_meta <= IO_iic_sda;
            sda_sync <= sda_meta;
        end
    end

    always @(posedge I_clk or negedge I_rstn) begin
        if (!I_rstn) begin
            state <= BUS_IDLE;
            divider <= 16'd0;
            phase <= 2'd0;
            bit_index <= 3'd7;
            write_index <= 2'd0;
            write_data <= 32'd0;
            write_count <= 8'd0;
            tx_byte <= 8'd0;
            read_requested <= 1'b0;
            read_address <= 1'b0;
            transaction_error <= 1'b0;
            boundary_hold <= 1'b0;
            sda_low <= 1'b0;
            O_iic_scl <= 1'b1;
            O_rd_data <= 8'd0;
            O_iic_busy <= 1'b0;
            O_iic_bus_error <= 1'b0;
        end else begin
            O_iic_bus_error <= 1'b0;
            if (state == BUS_IDLE) begin
                divider <= 16'd0;
                phase <= 2'd0;
                if (I_iic_req) begin
                    write_data <= I_wr_data;
                    write_count <= I_wr_cnt;
                    tx_byte <= I_wr_data[7:0];
                    read_requested <= (I_rd_cnt != 0);
                    read_address <= 1'b0;
                    transaction_error <= 1'b0;
                    boundary_hold <= 1'b0;
                    bit_index <= 3'd7;
                    write_index <= 2'd0;
                    O_rd_data <= 8'd0;
                    O_iic_busy <= 1'b1;
                    state <= BUS_START;
                end
            end else if (divider == QUARTER_CYCLES - 1) begin
                divider <= 16'd0;
                phase <= phase + 1'b1;
                // Data changes one quarter after SCL falls. ACK/data are
                // sampled halfway through the high interval, after input sync.
                case (state)
                    BUS_START: begin
                        if (phase == 0) sda_low <= 1'b1;
                        if (phase == 2) O_iic_scl <= 1'b0;
                        if (phase == 3) state <= BUS_WRITE;
                    end
                    BUS_WRITE: begin
                        if (phase == 0) O_iic_scl <= 1'b0;
                        if (phase == 1) sda_low <= !tx_byte[bit_index];
                        if (phase == 2) O_iic_scl <= 1'b1;
                        if (phase == 3) begin
                            if (bit_index == 0) state <= BUS_ACK;
                            else bit_index <= bit_index - 1'b1;
                        end
                    end
                    BUS_ACK: begin
                        if (phase == 0) O_iic_scl <= 1'b0;
                        if (phase == 1) sda_low <= 1'b0;
                        if (phase == 2) O_iic_scl <= 1'b1;
                        if (phase == 3) begin
                            bit_index <= 3'd7;
                            if (sda_sync) begin
                                transaction_error <= 1'b1;
                                state <= BUS_STOP;
                            end else if (read_address) begin
                                state <= BUS_READ;
                            end else if (write_index < write_count - 1'b1) begin
                                write_index <= write_index + 1'b1;
                                tx_byte <= write_data[((write_index + 1)*8) +: 8];
                                state <= BUS_WRITE;
                            end else if (read_requested) begin
                                tx_byte <= {write_data[7:1], 1'b1};
                                read_address <= 1'b1;
                                state <= BUS_RESTART;
                            end else begin
                                state <= BUS_STOP;
                            end
                        end
                    end
                    BUS_RESTART: begin
                        if (phase == 0 && !boundary_hold) O_iic_scl <= 1'b0;
                        if (phase == 1) sda_low <= boundary_hold;
                        if (phase == 2 && !boundary_hold) O_iic_scl <= 1'b1;
                        if (phase == 3) begin
                            // Extra quarters satisfy START setup/hold at 100 kHz.
                            boundary_hold <= !boundary_hold;
                            if (boundary_hold) state <= BUS_WRITE;
                        end
                    end
                    BUS_READ: begin
                        if (phase == 0) O_iic_scl <= 1'b0;
                        if (phase == 1) sda_low <= 1'b0;
                        if (phase == 2) O_iic_scl <= 1'b1;
                        if (phase == 3) begin
                            O_rd_data[bit_index] <= sda_sync;
                            if (bit_index == 0) state <= BUS_NACK;
                            else bit_index <= bit_index - 1'b1;
                        end
                    end
                    BUS_NACK: begin
                        if (phase == 0) O_iic_scl <= 1'b0;
                        if (phase == 1) sda_low <= 1'b0;
                        if (phase == 2) O_iic_scl <= 1'b1;
                        if (phase == 3) state <= BUS_STOP;
                    end
                    BUS_STOP: begin
                        if (phase == 0 && !boundary_hold) O_iic_scl <= 1'b0;
                        if (phase == 1) sda_low <= !boundary_hold;
                        if (phase == 2 && !boundary_hold) O_iic_scl <= 1'b1;
                        if (phase == 3) begin
                            boundary_hold <= !boundary_hold;
                            if (boundary_hold) state <= BUS_FREE;
                        end
                    end
                    BUS_FREE: if (phase == 3) begin
                        O_iic_busy <= 1'b0;
                        O_iic_bus_error <= transaction_error;
                        state <= BUS_IDLE;
                    end
                    default: begin
                        transaction_error <= 1'b1;
                        state <= BUS_STOP;
                    end
                endcase
            end else begin
                divider <= divider + 1'b1;
            end
        end
    end
endmodule

