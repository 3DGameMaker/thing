/*
 * Copyright (c) 2024 Your Name
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_example (
    // Inputs
    input  wire [7:0] ui_in,    // Dedicated inputs
    input  wire [7:0] uio_in,   // IOs: Input path
    input  wire       ena,      // Global enable (always 1 when powered)
    input  wire       clk,      // Clock (25.175 MHz for VGA)
    input  wire       rst_n,    // Reset - active low

    // Outputs
    output wire [7:0] uo_out,   // Dedicated outputs
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe    // IOs: Enable path (0=input, 1=output)
);

  // ============================================================
  // VGA Timing Parameters (640x480 @ 60Hz)
  // ============================================================
  // Horizontal timing (pixels)
  localparam H_ACTIVE  = 640;
  localparam H_FRONT   = 16;
  localparam H_SYNC    = 96;
  localparam H_BACK    = 48;
  localparam H_TOTAL   = H_ACTIVE + H_FRONT + H_SYNC + H_BACK; // 800
  
  // Vertical timing (lines)
  localparam V_ACTIVE  = 480;
  localparam V_FRONT   = 10;
  localparam V_SYNC    = 2;
  localparam V_BACK    = 33;
  localparam V_TOTAL   = V_ACTIVE + V_FRONT + V_SYNC + V_BACK; // 525
  
  // Mouse cursor size
  localparam CURSOR_SIZE = 8;

  // ============================================================
  // Signal Declarations
  // ============================================================
  // VGA timing signals
  reg [9:0] h_counter;  // Horizontal counter (0-799)
  reg [9:0] v_counter;  // Vertical counter (0-524)
  wire h_sync, v_sync;
  wire h_active, v_active;
  wire video_active;
  
  // Mouse position
  reg [9:0] mouse_x = 320;  // Start in middle of screen
  reg [9:0] mouse_y = 240;
  
  // PS/2 signals
  reg [3:0] ps2_clk_filter;
  reg ps2_clk_prev;
  reg [10:0] ps2_data_reg;  // 1 start + 8 data + 1 parity + 1 stop
  reg [3:0] ps2_bit_count;
  reg ps2_receiving;
  wire ps2_clk;
  wire ps2_data;
  
  // Mouse packet decoding
  reg [1:0] mouse_packet_count;
  reg [7:0] mouse_packet [0:2];  // 3-byte mouse packet
  reg [8:0] mouse_x_movement;
  reg [8:0] mouse_y_movement;
  reg mouse_left_btn;
  reg mouse_middle_btn;
  reg mouse_right_btn;
  
  // Pixel generation
  reg [2:0] red, green;
  reg [1:0] blue;
  wire [9:0] pixel_x, pixel_y;
  wire mouse_pixel;
  
  // ============================================================
  // PS/2 Input Handling
  // ============================================================
  assign ps2_clk = uio_in[0];   // PS/2 clock on uio_in[0]
  assign ps2_data = uio_in[1];  // PS/2 data on uio_in[1]
  
  // Debounce PS/2 clock
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ps2_clk_filter <= 4'hF;
      ps2_clk_prev <= 1'b1;
    end else begin
      ps2_clk_filter <= {ps2_clk_filter[2:0], ps2_clk};
      ps2_clk_prev <= &ps2_clk_filter;  // Stable high when all bits are 1
    end
  end
  
  // PS/2 receiver (falling edge of debounced clock)
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ps2_receiving <= 1'b0;
      ps2_bit_count <= 4'd0;
      ps2_data_reg <= 11'd0;
      mouse_packet_count <= 2'd0;
    end else begin
      // Detect falling edge of PS/2 clock
      if (ps2_clk_prev && !(&ps2_clk_filter)) begin
        if (!ps2_receiving) begin
          // Wait for start bit (data low)
          if (!ps2_data) begin
            ps2_receiving <= 1'b1;
            ps2_bit_count <= 4'd0;
            ps2_data_reg <= 11'd0;
          end
        end else begin
          // Shift in data bits (LSB first)
          ps2_data_reg <= {ps2_data, ps2_data_reg[10:1]};
          ps2_bit_count <= ps2_bit_count + 1'b1;
          
          // Check if we've received 11 bits (start + 8 data + parity + stop)
          if (ps2_bit_count == 4'd10) begin
            ps2_receiving <= 1'b0;
            
            // Verify parity and stop bit (simplified - just store the data)
            if (ps2_data_reg[0] == 1'b0 &&  // start bit should be 0
                ps2_data_reg[10] == 1'b1) begin  // stop bit should be 1
              
              // Store the byte (8 data bits are in ps2_data_reg[9:2])
              mouse_packet[mouse_packet_count] <= ps2_data_reg[9:2];
              
              if (mouse_packet_count == 2'd2) begin
                // Complete 3-byte packet received
                mouse_packet_count <= 2'd0;
                
                // Decode mouse packet
                // Byte 0: Y overflow, X overflow, Y sign, X sign, always 1, Middle btn, Right btn, Left btn
                mouse_x_movement <= {mouse_packet[0][4] ? 9'h1FF : 9'h000, mouse_packet[1]};
                mouse_y_movement <= {mouse_packet[0][5] ? 9'h1FF : 9'h000, mouse_packet[2]};
                mouse_left_btn <= mouse_packet[0][0];
                mouse_right_btn <= mouse_packet[0][1];
                mouse_middle_btn <= mouse_packet[0][2];
              end else begin
                mouse_packet_count <= mouse_packet_count + 1'b1;
              end
            end
          end
        end
      end
    end
  end
  
  // Update mouse position based on movement
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mouse_x <= 320;
      mouse_y <= 240;
    end else if (mouse_packet_count == 2'd2 && mouse_packet[0][3]) begin
      // Update position when we have a complete packet
      // Note: This is simplified - real implementation would need to handle overflow
      mouse_x <= mouse_x + $signed(mouse_x_movement[8:0]);
      mouse_y <= mouse_y - $signed(mouse_y_movement[8:0]);  // Y is inverted in VGA
      
      // Keep cursor within screen bounds
      if (mouse_x < 0) mouse_x <= 0;
      if (mouse_x >= H_ACTIVE - CURSOR_SIZE) mouse_x <= H_ACTIVE - CURSOR_SIZE;
      if (mouse_y < 0) mouse_y <= 0;
      if (mouse_y >= V_ACTIVE - CURSOR_SIZE) mouse_y <= V_ACTIVE - CURSOR_SIZE;
    end
  end

  // ============================================================
  // VGA Timing Generation
  // ============================================================
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      h_counter <= 10'd0;
      v_counter <= 10'd0;
    end else begin
      // Horizontal counter
      if (h_counter == H_TOTAL - 1) begin
        h_counter <= 10'd0;
        // Vertical counter
        if (v_counter == V_TOTAL - 1) begin
          v_counter <= 10'd0;
        end else begin
          v_counter <= v_counter + 1'b1;
        end
      end else begin
        h_counter <= h_counter + 1'b1;
      end
    end
  end
  
  // Horizontal sync
  assign h_sync = (h_counter >= (H_ACTIVE + H_FRONT) && 
                   h_counter < (H_ACTIVE + H_FRONT + H_SYNC)) ? 1'b0 : 1'b1;
  
  // Vertical sync
  assign v_sync = (v_counter >= (V_ACTIVE + V_FRONT) && 
                   v_counter < (V_ACTIVE + V_FRONT + V_SYNC)) ? 1'b0 : 1'b1;
  
  // Active video region
  assign h_active = (h_counter < H_ACTIVE);
  assign v_active = (v_counter < V_ACTIVE);
  assign video_active = h_active && v_active;
  
  // Current pixel position
  assign pixel_x = h_active ? h_counter : 10'd0;
  assign pixel_y = v_active ? v_counter : 10'd0;

  // ============================================================
  // Mouse Cursor Generation
  // ============================================================
  // Simple crosshair cursor
  assign mouse_pixel = video_active && 
                       (pixel_x >= mouse_x && pixel_x < mouse_x + CURSOR_SIZE &&
                        pixel_y >= mouse_y && pixel_y < mouse_y + CURSOR_SIZE) &&
                       ((pixel_x - mouse_x == CURSOR_SIZE/2) || 
                        (pixel_y - mouse_y == CURSOR_SIZE/2) ||
                        (pixel_x - mouse_x == pixel_y - mouse_y) ||
                        (pixel_x - mouse_x + pixel_y - mouse_y == CURSOR_SIZE - 1));

  // ============================================================
  // Pixel Color Generation
  // ============================================================
  always @(*) begin
    if (!video_active) begin
      // Blanking region - black
      {red, green, blue} = 8'b000_000_00;
    end else if (mouse_pixel) begin
      // Mouse cursor - white
      {red, green, blue} = 8'b111_111_11;
    end else if (pixel_x < 100) begin
      // Left region - red
      {red, green, blue} = 8'b111_000_00;
    end else if (pixel_x < 200) begin
      // Left-middle region - green
      {red, green, blue} = 8'b000_111_00;
    end else if (pixel_x < 300) begin
      // Middle region - blue
      {red, green, blue} = 8'b000_000_11;
    end else if (pixel_x < 400) begin
      // Right-middle region - yellow
      {red, green, blue} = 8'b111_111_00;
    end else if (pixel_x < 500) begin
      // Right region - cyan
      {red, green, blue} = 8'b000_111_11;
    end else begin
      // Far right region - magenta
      {red, green, blue} = 8'b111_000_11;
    end
  end

  // ============================================================
  // Output Assignments
  // ============================================================
  // VGA outputs (using uo_out as VGA signals)
  assign uo_out[0] = red[0];      // Red bit 0
  assign uo_out[1] = red[1];      // Red bit 1
  assign uo_out[2] = red[2];      // Red bit 2
  assign uo_out[3] = green[0];    // Green bit 0
  assign uo_out[4] = green[1];    // Green bit 1
  assign uo_out[5] = green[2];    // Green bit 2
  assign uo_out[6] = blue[0];     // Blue bit 0
  assign uo_out[7] = blue[1];     // Blue bit 1
  
  // Bidirectional pins configuration
  // uio_out[0:1] - PS/2 outputs (if needed for mouse reset/control)
  // uio_out[2]   - Horizontal sync
  // uio_out[3]   - Vertical sync
  assign uio_out[0] = 1'b0;        // PS/2 output (unused)
  assign uio_out[1] = 1'b0;        // PS/2 output (unused)
  assign uio_out[2] = h_sync;      // VGA HSYNC
  assign uio_out[3] = v_sync;      // VGA VSYNC
  assign uio_out[4] = 1'b0;
  assign uio_out[5] = 1'b0;
  assign uio_out[6] = 1'b0;
  assign uio_out[7] = 1'b0;
  
  // Pin direction control
  // uio_oe[0:1] = 0 (PS/2 inputs)
  // uio_oe[2:3] = 1 (VGA sync outputs)
  // uio_oe[4:7] = 0 (unused inputs)
  assign uio_oe = 8'b00001100;  // Bits 2-3 are outputs, rest are inputs

  // ============================================================
  // Unused Signals (to prevent warnings)
  // ============================================================
  wire _unused = &{ena, mouse_middle_btn, mouse_right_btn, 1'b0};

endmodule

`default_nettype wire
