//
// Copyright 2016 Ettus Research LLC
//


//
// Wrap XGE MAC so that:
//
// *) Signals are crossed between the MAC's own 156.25MHz clock domain and the
// main FPGA clock domain.
// *) 6 byte Padding is added at RX, including metadata so that IP headers become aligned.
// *) 6 Byte padding is stripped at TX, so that Eth header data starts immediately.
// *) TX & RX can buffer at least an MTU sized packet
// *) On TX, to not start an Ethernet Tx until a complete packet is present in the
// last Tx FIFO so that the MAC doesn't underrun.
//

//
// Copyright 2016 Ettus Research
//

module n310_xge_mac_wrapper #(
   parameter PORTNUM = 8'd0
) (
   // XGMII
   input         xgmii_clk,
   output [63:0] xgmii_txd,
   output [7:0]  xgmii_txc,
   input  [63:0] xgmii_rxd,
   input  [7:0]  xgmii_rxc,
   // Client FIFO Interfaces
   input         sys_clk,
   input         sys_rst,          // From sys_clk domain.
   output [63:0] rx_tdata,
   output [3:0]  rx_tuser,
   output        rx_tlast,
   output        rx_tvalid,
   input         rx_tready,
   input  [63:0] tx_tdata,
   input  [3:0]  tx_tuser,                // Bit[3] (error) is ignored for now.
   input         tx_tlast,
   input         tx_tvalid,
   output        tx_tready,
   // Control and Status
   input         phy_ready,
   input         ctrl_tx_enable,
   output        status_crc_error,
   output        status_fragment_error,
   output        status_txdfifo_ovflow,
   output        status_txdfifo_udflow,
   output        status_rxdfifo_ovflow,
   output        status_rxdfifo_udflow,
   output        status_pause_frame_rx,
   output        status_local_fault,
   output        status_remote_fault
);

   //
   // Generate 156MHz synchronized sys_rst localy
   //

   wire xgmii_reset, ctrl_tx_enable_xclk;
   synchronizer #(
      .INITIAL_VAL(1'b1), .STAGES(3)
   ) xgmii_reset_sync_i (
      .clk(xgmii_clk), .rst(1'b0 /* no reset */), .in(!phy_ready || sys_rst), .out(xgmii_reset)
   );

   synchronizer #(
      .INITIAL_VAL(1'b1), .STAGES(3)
   ) tx_enabled_sync_i (
      .clk(xgmii_clk), .rst(1'b0 /* no reset */), .in(ctrl_tx_enable), .out(ctrl_tx_enable_xclk)
   );

   //
   // 10G MAC
   //
   wire [63:0] eth_rx_data;
   wire        eth_rx_avail;
   wire        eth_rx_eof;
   wire        eth_rx_err;
   wire [2:0]  eth_rx_occ;
   wire        eth_rx_sof;
   wire        eth_rx_valid;
   wire        eth_rx_ren;

   wire        eth_tx_full;
   wire [63:0] eth_tx_data;
   wire        eth_tx_eof;
   wire [2:0]  eth_tx_occ;
   wire        eth_tx_sof;
   wire        eth_tx_valid;

   n310_xge_mac xge_mac (
      // Clocks and Resets
      .clk_156m25             (xgmii_clk),
      .clk_xgmii_rx           (xgmii_clk),
      .clk_xgmii_tx           (xgmii_clk),
      .reset_156m25_n         (~xgmii_reset),
      .reset_xgmii_rx_n       (~xgmii_reset),
      .reset_xgmii_tx_n       (~xgmii_reset),
      // XGMII
      .xgmii_txc              (xgmii_txc[7:0]),
      .xgmii_txd              (xgmii_txd[63:0]),
      .xgmii_rxc              (xgmii_rxc[7:0]),
      .xgmii_rxd              (xgmii_rxd[63:0]),
      // Packet interface
      .pkt_rx_avail           (eth_rx_avail),
      .pkt_rx_data            (eth_rx_data),
      .pkt_rx_eop             (eth_rx_eof),
      .pkt_rx_err             (eth_rx_err),
      .pkt_rx_mod             (eth_rx_occ),
      .pkt_rx_sop             (eth_rx_sof),
      .pkt_rx_val             (eth_rx_valid),
      .pkt_tx_full            (eth_tx_full),
      // Inputs
      .pkt_rx_ren             (eth_rx_ren),
      .pkt_tx_data            (eth_tx_data),
      .pkt_tx_eop             (eth_tx_eof),
      .pkt_tx_mod             (eth_tx_occ),
      .pkt_tx_sop             (eth_tx_sof),
      .pkt_tx_val             (eth_tx_valid),
      // Control and Status
      .ctrl_tx_enable         (ctrl_tx_enable_xclk),
      .status_crc_error       (status_crc_error),
      .status_fragment_error  (status_fragment_error),
      .status_txdfifo_ovflow  (status_txdfifo_ovflow),
      .status_txdfifo_udflow  (status_txdfifo_udflow),
      .status_rxdfifo_ovflow  (status_rxdfifo_ovflow),
      .status_rxdfifo_udflow  (status_rxdfifo_udflow),
      .status_pause_frame_rx  (status_pause_frame_rx),
      .status_local_fault     (status_local_fault),
      .status_remote_fault    (status_remote_fault)
   );

   ///////////////////////////////////////////////////////////////////////////////////////
     // RX FIFO Chain
   ///////////////////////////////////////////////////////////////////////////////////////
   wire [63:0] rx_tdata_int;
   wire [3:0]  rx_tuser_int;
   wire        rx_tlast_int;
   wire        rx_tvalid_int;
   wire        rx_tready_int;

   //
   // Logic to drive pkt_rx_ren on XGE MAC
   //
   xge_handshake xge_handshake (
      .clk(xgmii_clk),
      .reset(xgmii_reset),
      .pkt_rx_ren(eth_rx_ren),
      .pkt_rx_avail(eth_rx_avail),
      .pkt_rx_eop(eth_rx_eof)
   );

   //
   // Add pad of 6 empty bytes before MAC addresses of new Rxed packet so that IP
   // headers are alligned. Also put metadata in first octet of pad that shows
   // ingress port.
   //
   xge64_to_axi64  #(.LABEL(PORTNUM)) xge64_to_axi64 (
      .clk(xgmii_clk),
      .reset(xgmii_reset),
      .clear(1'b0),
      .datain(eth_rx_data),
      .occ(eth_rx_occ),
      .sof(eth_rx_sof),
      .eof(eth_rx_eof),
      .err(eth_rx_err),
      .valid(eth_rx_valid),
      .axis_tdata(rx_tdata_int),
      .axis_tuser(rx_tuser_int),
      .axis_tlast(rx_tlast_int),
      .axis_tvalid(rx_tvalid_int),
      .axis_tready(rx_tready_int)
   );

   //
   // Large FIFO must be able to run input side at 64b@156MHz to sustain 10Gb Rx.
   //
   axis_2clk_fifo #( .WIDTH(69), .MODE("BRAM512"), .PIPELINE("NONE") ) rxfifo_2clk (
      .s_axis_areset(xgmii_reset),
      .s_axis_aclk(xgmii_clk),
      .s_axis_tdata({rx_tlast_int, rx_tuser_int, rx_tdata_int}),
      .s_axis_tvalid(rx_tvalid_int),
      .s_axis_tready(rx_tready_int),
      .m_axis_aclk(sys_clk),
      .m_axis_tdata({rx_tlast, rx_tuser, rx_tdata}),
      .m_axis_tvalid(rx_tvalid),
      .m_axis_tready(rx_tready)
   );


   ///////////////////////////////////////////////////////////////////////////////////////
   // TX FIFO Chain
   ///////////////////////////////////////////////////////////////////////////////////////

   wire [63:0] tx_tdata_int;
   wire [3:0]  tx_tuser_int;
   wire        tx_tlast_int;
   wire        tx_tvalid_int;
   wire        tx_tready_int;

   wire [63:0] tx_tdata_int2;
   wire [3:0]  tx_tuser_int2;
   wire        tx_tlast_int2;
   wire        tx_tvalid_int2;
   wire        tx_tready_int2;

   wire        tx_tvalid_int3;
   wire        tx_tready_int3;
   wire        tx_sof_int3;
   wire        enable_tx;

   axis_2clk_fifo #( .WIDTH(69), .MODE("BRAM512"), .PIPELINE("NONE") ) txfifo_2clk_1x (
      .s_axis_areset(sys_rst),
      .s_axis_aclk(sys_clk),
      .s_axis_tdata({tx_tlast, tx_tuser, tx_tdata}),
      .s_axis_tvalid(tx_tvalid),
      .s_axis_tready(tx_tready),
      .m_axis_aclk(xgmii_clk),
      .m_axis_tdata({tx_tlast_int, tx_tuser_int, tx_tdata_int}),
      .m_axis_tvalid(tx_tvalid_int),
      .m_axis_tready(tx_tready_int)
   );

   //
   // Strip the 6 octet ethernet padding we used internally.
   // Put SOF into bit[3] of tuser.
   //
   axi64_to_xge64 axi64_to_xge64 (
      .clk(xgmii_clk),
      .reset(xgmii_reset),
      .clear(1'b0),
      .s_axis_tdata(tx_tdata_int),
      .s_axis_tuser(tx_tuser_int),
      .s_axis_tlast(tx_tlast_int),
      .s_axis_tvalid(tx_tvalid_int),
      .s_axis_tready(tx_tready_int),
      .m_axis_tdata(tx_tdata_int2),
      .m_axis_tuser(tx_tuser_int2),
      .m_axis_tlast(tx_tlast_int2),
      .m_axis_tvalid(tx_tvalid_int2),
      .m_axis_tready(tx_tready_int2)
   );

   //
   // Large FIFO can hold a max sized ethernet packet.
   //
   axi_fifo #(.WIDTH(64+4+1), .SIZE(10)) txfifo_2 (
      .clk(xgmii_clk), .reset(xgmii_reset), .clear(1'b0),
      .i_tdata({tx_tlast_int2, tx_tuser_int2, tx_tdata_int2}),
      .i_tvalid(tx_tvalid_int2),
      .i_tready(tx_tready_int2),
      .o_tvalid(tx_tvalid_int3),
      .o_tready(tx_tready_int3),
      .o_tdata({eth_tx_eof,tx_sof_int3,eth_tx_occ,eth_tx_data}),
      .space(), .occupied()
   );

   //
   // Monitor number of Ethernet packets in tx_fifo2
   //
   axi_count_packets_in_fifo axi_count_packets_in_fifo (
      .clk(xgmii_clk),
      .reset(xgmii_reset),
      .in_axis_tvalid(tx_tvalid_int2),
      .in_axis_tready(tx_tready_int2),
      .in_axis_tlast(tx_tlast_int2),
      .out_axis_tvalid(tx_tvalid_int3),
      .out_axis_tready(tx_tready_int3),
      .out_axis_tlast(eth_tx_eof),
      .pkt_tx_full(eth_tx_full),
      .enable_tx(enable_tx)
   );

   //
   //
   // Supress FIFO flags to stop overflow of MAC in Tx direction
   //
   assign eth_tx_valid     = tx_tvalid_int3 & enable_tx;
   assign tx_tready_int3   = enable_tx;
   assign eth_tx_sof       = tx_sof_int3 & enable_tx;


endmodule