-------------------------------------------------------------------------------
-- File       : Pgp2bAxi.vhd
-- Company    : SLAC National Accelerator Laboratory
-- Created    : 2009-05-27
-- Last update: 2017-03-28
-------------------------------------------------------------------------------
-- Description:
-- AXI-Lite block to manage the PGP3 interface.
--
-------------------------------------------------------------------------------
-- This file is part of 'SLAC Firmware Standard Library'.
-- It is subject to the license terms in the LICENSE.txt file found in the 
-- top-level directory of this distribution and at: 
--    https://confluence.slac.stanford.edu/display/ppareg/LICENSE.html. 
-- No part of 'SLAC Firmware Standard Library', including this file, 
-- may be copied, modified, propagated, or distributed except according to 
-- the terms contained in the LICENSE.txt file.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use IEEE.STD_LOGIC_ARITH.all;
use IEEE.STD_LOGIC_UNSIGNED.all;

use work.StdRtlPkg.all;
use work.AxiLitePkg.all;
use work.Pgp3Pkg.all;

entity Pgp3AxiL is
   generic (
      TPD_G              : time                  := 1 ns;
      COMMON_TX_CLK_G    : boolean               := false;  -- Set to true if axiClk and pgpTxClk are the same clock
      COMMON_RX_CLK_G    : boolean               := false;  -- Set to true if axiClk and pgpRxClk are the same clock
      WRITE_EN_G         : boolean               := false;  -- Set to false when on remote end of a link
      AXI_CLK_FREQ_G     : real                  := 125.0E+6;
      STATUS_CNT_WIDTH_G : natural range 1 to 32 := 32;
      ERROR_CNT_WIDTH_G  : natural range 1 to 32 := 4;
      AXI_ERROR_RESP_G   : slv(1 downto 0)       := AXI_RESP_DECERR_C);
   port (

      -- TX PGP Interface (pgpTxClk)
      pgpTxClk : in  sl;
      pgpTxRst : in  sl;
      pgpTxIn  : out Pgp3TxInType;
      pgpTxOut : in  Pgp3TxOutType;
      locTxIn  : in  Pgp3TxInType := PGP3_TX_IN_INIT_C;

      -- RX PGP Interface (pgpRxClk)
      pgpRxClk : in  sl;
      pgpRxRst : in  sl;
      pgpRxIn  : out Pgp3RxInType;
      pgpRxOut : in  Pgp3RxOutType;
      locRxIn  : in  Pgp3RxInType := PGP3_RX_IN_INIT_C;

      -- Status Bus (axilClk domain)
      statusWord : out slv(63 downto 0);
      statusSend : out sl;

      -- AXI-Lite Register Interface (axilClk domain)
      axilClk         : in  sl;
      axilRst         : in  sl;
      axilReadMaster  : in  AxiLiteReadMasterType;
      axilReadSlave   : out AxiLiteReadSlaveType;
      axilWriteMaster : in  AxiLiteWriteMasterType;
      axilWriteSlave  : out AxiLiteWriteSlaveType
      );
end Pgp3AxiL;

architecture rtl of Pgp3AxiL is

   constant STATUS_OUT_TOP_C : integer := ite(STATUS_CNT_WIDTH_G > 7, 7, STATUS_CNT_WIDTH_G-1);

   subtype ErrorCountSlv is slv(ERROR_CNT_WIDTH_G-1 downto 0);
   type ErrorCountSlvArray is array (natural range <>) of ErrorCountSlv;

   constant RX_ERROR_COUNTERS_C : integer := 40;
   constant TX_ERROR_COUNTERS_C : integer := 36;

   subtype StatusCountSlv is slv(STATUS_CNT_WIDTH_G-1 downto 0);
   type StatusCountSlvArray is array (natural range <>) of StatusCountSlv;

   constant RX_STATUS_COUNTERS_C : integer := 1;
   constant TX_STATUS_COUNTERS_C : integer := 1;

   -- Local signals
   signal rxStatusSend : sl;

   signal rxErrorOut     : slv(RX_ERROR_COUNTERS_C-1 downto 0);
   signal rxErrorCntOut  : SlVectorArray(RX_ERROR_COUNTERS_C-1 downto 0, ERROR_CNT_WIDTH_G-1 downto 0);
   signal rxStatusCntOut : SlVectorArray(RX_STATUS_COUNTERS_C-1 downto 0, STATUS_CNT_WIDTH_G-1 downto 0);

   signal txErrorOut     : slv(TX_ERROR_COUNTERS_C-1 downto 0);
   signal txErrorCntOut  : SlVectorArray(TX_ERROR_COUNTERS_C-1 downto 0, ERROR_CNT_WIDTH_G-1 downto 0);
   signal txStatusCntOut : SlVectorArray(TX_STATUS_COUNTERS_C-1 downto 0, STATUS_CNT_WIDTH_G-1 downto 0);

   signal rxErrorIrqEn : slv(RX_ERROR_COUNTERS_C-1 downto 0);

--   signal txFlush         : sl;
--   signal rxFlush         : sl;
--   signal rxReset         : sl;
   signal syncFlowCntlDis : sl;

   type RegType is record
      countReset     : sl;
      loopBack       : slv(2 downto 0);
      flowCntlDis    : sl;
      txDisable      : sl;
      autoStatus     : sl;
      axilWriteSlave : AxiLiteWriteSlaveType;
      axilReadSlave  : AxiLiteReadSlaveType;
   end record RegType;

   constant REG_INIT_C : RegType := (
      countReset     => '0',
      loopBack       => (others => '0'),
      flowCntlDis    => '0',
      txDisable      => '0',
      autoStatus     => '0',
      axilWriteSlave => AXI_LITE_WRITE_SLAVE_INIT_C,
      axilReadSlave  => AXI_LITE_READ_SLAVE_INIT_C
      );

   signal r   : RegType := REG_INIT_C;
   signal rin : RegType;

   type RxStatusType is record
      phyRxActive        : sl;
      locLinkReady       : sl;
      remLinkReady       : sl;
      cellErrorCount     : ErrorCountSlv;
      linkDownCount      : ErrorCountSlv;
      linkErrorCount     : ErrorCountSlv;
      remRxOverflow      : slv(15 downto 0);
      remRxOverflowCnt   : ErrorCountSlvArray(15 downto 0);
      frameErrCount      : ErrorCountSlv;
      frameCount         : StatusCountSlv;
      remRxPause         : slv(15 downto 0);
      rxClkFreq          : slv(31 downto 0);
      rxOpCodeCount      : ErrorCountSlv;
      rxOpCodeDataLast   : slv(55 downto 0);
      rxOpCodeNumberLast : slv(2 downto 0);
   end record RxStatusType;

   signal rxStatusSync : RxStatusType;

   type TxStatusType is record
      phyTxActive        : sl;
      linkReady          : sl;
      locOverflow        : slv(15 downto 0);
      locOverflowCnt     : ErrorCountSlvArray(15 downto 0);
      locPause           : slv(15 downto 0);
      frameErrCount      : ErrorCountSlv;
      frameCount         : StatusCountSlv;
      txClkFreq          : slv(31 downto 0);
      txOpCodeCount      : ErrorCountSlv;
      txOpCodeDataLast   : slv(55 downto 0);
      txOpCodeNumberLast : slv(2 downto 0);
   end record TxStatusType;

   signal txStatusSync : TxStatusType;

begin


   ---------------------------------------
   -- Receive Status
   ---------------------------------------

   -- OpCode Capture
   U_RxOpCodeSync : entity work.SynchronizerFifo
      generic map (
         TPD_G        => TPD_G,
         BRAM_EN_G    => false,
         DATA_WIDTH_G => 59,
         ADDR_WIDTH_G => 2)
      port map (
         rst                => r.countReset,
         wr_clk             => pgpRxClk,
         wr_en              => pgpRxOut.opCodeEn,
         din(55 downto 0)   => pgpRxOut.opCodeData,
         din(58 downto 56)  => pgpRxOut.opCodeNumber,
         rd_clk             => axilClk,
         dout(55 downto 0)  => rxStatusSync.rxOpCodeDataLast,
         dout(58 downto 56) => rxStatusSync.rxOpCodeNumberLast);

   -- Errror counters and non counted values
   U_RxError : entity work.SyncStatusVector
      generic map (
         TPD_G           => TPD_G,
         RST_POLARITY_G  => '1',
         COMMON_CLK_G    => COMMON_RX_CLK_G,
         RELEASE_DELAY_G => 3,
         IN_POLARITY_G   => "1",
         OUT_POLARITY_G  => '1',
         USE_DSP48_G     => "no",
         SYNTH_CNT_G     => X"0000FFFF7C",
         CNT_RST_EDGE_G  => false,
         CNT_WIDTH_G     => ERROR_CNT_WIDTH_G,
         WIDTH_G         => RX_ERROR_COUNTERS_C)
      port map (
         statusIn(0)            => pgpRxOut.phyRxActive,
         statusIn(1)            => pgpRxOut.linkReady,
         statusIn(2)            => pgpRxOut.frameRxErr,
         statusIn(3)            => pgpRxOut.cellError,
         statusIn(4)            => pgpRxOut.linkDown,
         statusIn(5)            => pgpRxOut.linkError,
         statusIn(6)            => pgpRxOut.opCodeEn,
         statusIn(7)            => pgpRxOut.remRxLinkReady,
         statusIn(23 downto 8)  => pgpRxOut.remRxOverflow,
         statusIn(39 downto 24) => pgpRxOut.remRxPause,
         statusOut              => rxErrorOut,
         cntRstIn               => r.countReset,
         rollOverEnIn           => (others => '0'),
         cntOut                 => rxErrorCntOut,
         irqEnIn                => rxErrorIrqEn,
         irqOut                 => rxStatusSend,
         wrClk                  => pgpRxClk,
         wrRst                  => pgpRxRst,
         rdClk                  => axilClk,
         rdRst                  => axilRst
         );

   U_RxErrorIrqEn : process (r.autoStatus)
   begin
      rxErrorIrqEn     <= (others => '0');
      rxErrorIrqEn(1)  <= r.autoStatus;
      rxErrorIrqEn(4)  <= r.autoStatus;
      rxErrorIrqEn(5)  <= r.autoStatus;
      rxErrorIrqEn(6)  <= r.autoStatus;
      rxErrorIrqEn(7)  <= r.autoStatus;
      rxErrorIrqEn(8)  <= r.autoStatus;
      rxErrorIrqEn(13) <= r.autoStatus;
      rxErrorIrqEn(14) <= r.autoStatus;
      rxErrorIrqEn(16) <= r.autoStatus;
   end process;

   -- map status
   rxStatusSync.phyRxActive   <= rxErrorOut(0);
   rxStatusSync.locLinkReady  <= rxErrorOut(1);
   rxStatusSync.remLinkReady  <= rxErrorOut(7);
   rxStatusSync.remRxOverflow <= rxErrorOut(23 downto 8);
   rxStatusSync.remRxPause    <= rxErrorOut(39 downto 24);

   -- Map counters
   rxStatusSync.frameErrCount  <= muxSlVectorArray(rxErrorCntOut, 2);
   rxStatusSync.cellErrorCount <= muxSlVectorArray(rxErrorCntOut, 3);
   rxStatusSync.linkDownCount  <= muxSlVectorArray(rxErrorCntOut, 4);
   rxStatusSync.linkErrorCount <= muxSlVectorArray(rxErrorCntOut, 5);
   rxStatusSync.rxOpCodeCount  <= muxSlVectorArray(rxErrorCntOut, 6);
   REM_OVERFLOW_CNT : for i in 15 downto 0 generate
      rxStatusSync.remRxOverflowCnt(i) <= muxSlVectorArray(rxErrorCntOut, i+8);
   end generate REM_OVERFLOW_CNT;

   -- Status counters
   U_RxStatus : entity work.SyncStatusVector
      generic map (
         TPD_G           => TPD_G,
         RST_POLARITY_G  => '1',
         COMMON_CLK_G    => COMMON_RX_CLK_G,
         RELEASE_DELAY_G => 3,
         IN_POLARITY_G   => "1",
         OUT_POLARITY_G  => '1',
         USE_DSP48_G     => "no",
         SYNTH_CNT_G     => "1",
         CNT_RST_EDGE_G  => false,
         CNT_WIDTH_G     => STATUS_CNT_WIDTH_G,
         WIDTH_G         => RX_STATUS_COUNTERS_C)
      port map (
         statusIn(0)  => pgpRxOut.frameRx,
         statusOut    => open,
         cntRstIn     => r.countReset,
         rollOverEnIn => (others => '1'),
         cntOut       => rxStatusCntOut,
         irqEnIn      => (others => '0'),
         irqOut       => open,
         wrClk        => pgpRxClk,
         wrRst        => pgpRxRst,
         rdClk        => axilClk,
         rdRst        => axilRst
         );

   rxStatusSync.frameCount <= muxSlVectorArray(rxStatusCntOut, 0);

   U_RxClkFreq : entity work.SyncClockFreq
      generic map (
         TPD_G             => TPD_G,
         USE_DSP48_G       => "no",
         REF_CLK_FREQ_G    => AXI_CLK_FREQ_G,
         REFRESH_RATE_G    => 100.0,
         CLK_LOWER_LIMIT_G => 159.0E+6,
         CLK_UPPER_LIMIT_G => 161.0E+6,
         CNT_WIDTH_G       => 32)
      port map (
         freqOut     => rxStatusSync.rxClkFreq,
         freqUpdated => open,
         locked      => open,
         tooFast     => open,
         tooSlow     => open,
         clkIn       => pgpRxClk,
         locClk      => axilClk,
         refClk      => axilClk
         );


   ---------------------------------------
   -- Transmit Status
   ---------------------------------------

   -- OpCode Capture
   U_TxOpCodeSync : entity work.SynchronizerFifo
      generic map (
         TPD_G        => TPD_G,
         BRAM_EN_G    => false,
         DATA_WIDTH_G => 59,
         ADDR_WIDTH_G => 2)
      port map (
         rst                => r.countReset,
         wr_clk             => pgpTxClk,
         wr_en              => locTxIn.opCodeEn,
         din(55 downto 0)   => locTxIn.opCodeData,
         din(58 downto 56)  => locTxIn.opCodeNumber,
         rd_clk             => axilClk,
         dout(55 downto 0)  => txStatusSync.txOpCodeDataLast,
         dout(58 downto 56) => txStatusSync.txOpCodeNumberLast);

   -- Errror counters and non counted values
   U_TxError : entity work.SyncStatusVector
      generic map (
         TPD_G           => TPD_G,
         RST_POLARITY_G  => '1',
         COMMON_CLK_G    => COMMON_TX_CLK_G,
         RELEASE_DELAY_G => 3,
         IN_POLARITY_G   => "1",
         OUT_POLARITY_G  => '1',
         USE_DSP48_G     => "no",
         SYNTH_CNT_G     => X"0000FFFFE",
         CNT_RST_EDGE_G  => false,
         CNT_WIDTH_G     => ERROR_CNT_WIDTH_G,
         WIDTH_G         => TX_ERROR_COUNTERS_C)
      port map (
         statusIn(0)            => pgpTxOut.phyTxActive,
         statusIn(1)            => pgpTxOut.linkReady,
         statusIn(2)            => pgpTxOut.frameTxErr,
         statusIn(3)            => locTxIn.opCodeEn,
         statusIn(19 downto 4)  => pgpTxOut.locOverflow,
         statusIn(35 downto 20) => pgpTxOut.locPause,
         statusOut              => txErrorOut,
         cntRstIn               => r.countReset,
         rollOverEnIn           => (others => '0'),
         cntOut                 => txErrorCntOut,
         irqEnIn                => (others => '0'),
         irqOut                 => open,
         wrClk                  => pgpTxClk,
         wrRst                  => pgpTxRst,
         rdClk                  => axilClk,
         rdRst                  => axilRst
         );

   -- Map Status
   txStatusSync.phyTxActive <= txErrorOut(0);
   txStatusSync.linkReady   <= txErrorOut(1);
   txStatusSync.locOverFlow <= txErrorOut(19 downto 4);
   txStatusSync.locPause    <= txErrorOut(35 downto 20);

   -- Map counters
   txStatusSync.frameErrCount <= muxSlVectorArray(txErrorCntOut, 2);
   txStatusSync.txOpCodeCount <= muxSlVectorArray(txErrorCntOut, 3);
   LOC_OVERFLOW_CNT : for i in 15 downto 0 generate
      txStatusSync.locOverflowCnt(i) <= muxSlVectorArray(txErrorCntOut, i+4);
   end generate LOC_OVERFLOW_CNT;

   -- Status counters
   U_TxStatus : entity work.SyncStatusVector
      generic map (
         TPD_G           => TPD_G,
         RST_POLARITY_G  => '1',
         COMMON_CLK_G    => COMMON_TX_CLK_G,
         RELEASE_DELAY_G => 3,
         IN_POLARITY_G   => "1",
         OUT_POLARITY_G  => '1',
         USE_DSP48_G     => "no",
         SYNTH_CNT_G     => "1",
         CNT_RST_EDGE_G  => false,
         CNT_WIDTH_G     => STATUS_CNT_WIDTH_G,
         WIDTH_G         => 1)
      port map (
         statusIn(0)  => pgpTxOut.frameTx,
         statusOut    => open,
         cntRstIn     => r.countReset,
         rollOverEnIn => (others => '1'),
         cntOut       => txStatusCntOut,
         irqEnIn      => (others => '0'),
         irqOut       => open,
         wrClk        => pgpTxClk,
         wrRst        => pgpTxRst,
         rdClk        => axilClk,
         rdRst        => axilRst
         );

   txStatusSync.frameCount <= muxSlVectorArray(txStatusCntOut, 0);

   U_TxClkFreq : entity work.SyncClockFreq
      generic map (
         TPD_G             => TPD_G,
         USE_DSP48_G       => "no",
         REF_CLK_FREQ_G    => AXI_CLK_FREQ_G,
         REFRESH_RATE_G    => 100.0,
         CLK_LOWER_LIMIT_G => 159.0E+6,
         CLK_UPPER_LIMIT_G => 161.0E+6,
         CNT_WIDTH_G       => 32)
      port map (
         freqOut     => txStatusSync.txClkFreq,
         freqUpdated => open,
         locked      => open,
         tooFast     => open,
         tooSlow     => open,
         clkIn       => pgpTxClk,
         locClk      => axilClk,
         refClk      => axilClk
         );

   -------------------------------------
   -- Tx Control Sync
   -------------------------------------

   -- Sync flow cntl disable
   U_FlowCntlDis : entity work.Synchronizer
      generic map (
         TPD_G          => TPD_G,
         RST_POLARITY_G => '1',
         OUT_POLARITY_G => '1',
         RST_ASYNC_G    => false,
         STAGES_G       => 2,
         INIT_G         => "0")
      port map (
         clk     => pgpTxClk,
         rst     => pgpTxRst,
         dataIn  => r.flowCntlDis,
         dataOut => syncFlowCntlDis
         );


   -- Set tx input
--   pgpTxIn.flush        <= locTxIn.flush or txFlush;
   pgpTxIn.opCodeEn     <= locTxIn.opCodeEn;
   pgpTxIn.opCodeData   <= locTxIn.opCodeData;
   pgpTxIn.opCodeNumber <= locTxIn.opCodeNumber;
   pgpTxIn.flowCntlDis  <= locTxIn.flowCntlDis or syncFlowCntlDis;

   -- Set rx input
   pgpRxIn.loopback <= locRxIn.loopback or r.loopBack;

   ------------------------------------
   -- AXI Registers
   ------------------------------------

   -- Sync
   process (axilClk) is
   begin
      if (rising_edge(axilClk)) then
         r <= rin after TPD_G;
      end if;
   end process;

   -- Async
   process (axilRst, axilReadMaster, axilWriteMaster, r, rxStatusSync, txStatusSync) is
      variable v      : RegType;
      variable axilEp : AxiLiteEndpointType;
   begin
      v := r;

      axiSlaveWaitTxn(axilEp, axilWriteMaster, axilReadMaster, v.axilWriteSlave, v.axilReadSlave);

      axiSlaveRegister(axilEp, X"00", 0, v.countReset);
      axiSlaveRegister(axilEp, X"04", 0, v.autoStatus);

      ----------------------------------------------------------------------------------------------
      -- RX
      ----------------------------------------------------------------------------------------------

      if (WRITE_EN_G) then
--         axiSlaveRegister(axilEp, X"04", 0, v.resetRx);
--         axiSlaveRegister(axilEp, X"08", 0, v.flush);
         axiSlaveRegister(axilEp, X"08", 0, v.loopback);
      else
         axiSlaveRegisterR(axilEp, X"08", 0, r.loopback);
      end if;


      -- Rx Status regs
      axiSlaveRegisterR(axilEp, X"10", 0, rxStatusSync.phyRxActive);
      axiSlaveRegisterR(axilEp, X"10", 1, rxStatusSync.locLinkReady);
      axiSlaveRegisterR(axilEp, X"10", 2, rxStatusSync.remLinkReady);

      axiSlaveRegisterR(axilEp, X"14", 0, rxStatusSync.cellErrorCount);
      axiSlaveRegisterR(axilEp, X"18", 0, rxStatusSync.linkDownCount);
      axiSlaveRegisterR(axilEp, X"1C", 0, rxStatusSync.linkErrorCount);

      axiSlaveRegisterR(axilEp, X"20", 0, rxStatusSync.remRxOverflow);
      axiSlaveRegisterR(axilEp, X"20", 16, rxStatusSync.remRxPause);

      axiSlaveRegisterR(axilEp, X"24", 0, rxStatusSync.frameCount);
      axiSlaveRegisterR(axilEp, X"28", 0, rxStatusSync.frameErrCount);
      axiSlaveRegisterR(axilEp, X"2C", 0, rxStatusSync.rxClkFreq);

      axiSlaveRegisterR(axilEp, X"30", 0, rxStatusSync.rxOpCodeCount);
      axiSlaveRegisterR(axilEp, X"34", 0, rxStatusSync.rxOpCodeDataLast);
      axiSlaveRegisterR(axilEp, X"34", 56, rxStatusSync.rxOpCodeNumberLast);

      for i in 0 to 15 loop
         axiSlaveRegisterR(axilEp, X"40"+toSlv(i*4, 8), 0, rxStatusSync.remRxOverflowCnt(i));
      end loop;



      ----------------------------------------------------------------------------------------------
      -- TX
      ----------------------------------------------------------------------------------------------
      if (WRITE_EN_G) then
         axiSlaveRegister(axilEp, X"80", 0, v.flowCntlDis);
         axiSlaveRegister(axilEp, X"80", 1, v.txDisable);
      else
         axiSlaveRegisterR(axilEp, X"80", 0, r.flowCntlDis);
         axiSlaveRegisterR(axilEp, X"80", 1, r.txDisable);
      end if;

      axiSlaveRegisterR(axilEp, X"84", 0, txStatusSync.phyTxActive);
      axiSlaveRegisterR(axilEp, X"84", 1, txStatusSync.linkReady);

      axiSlaveRegisterR(axilEp, X"8C", 0, txStatusSync.locOverflow);
      axiSlaveRegisterR(axilEp, X"8C", 16, txStatusSync.locPause);

      axiSlaveRegisterR(axilEp, X"90", 0, txStatusSync.frameCount);
      axiSlaveRegisterR(axilEp, X"94", 0, txStatusSync.frameErrCount);
      axiSlaveRegisterR(axilEp, X"9C", 0, txStatusSync.txClkFreq);

      axiSlaveRegisterR(axilEp, X"A0", 0, txStatusSync.txOpCodeCount);
      axiSlaveRegisterR(axilEp, X"A4", 0, txStatusSync.txOpCodeDataLast);
      axiSlaveRegisterR(axilEp, X"A4", 56, txStatusSync.txOpCodeNumberLast);


      for i in 0 to 15 loop
         axiSlaveRegisterR(axilEp, X"B0"+toSlv(i*4, 8), 0, txStatusSync.locOverflowCnt(i));
      end loop;


      axiSlaveDefault(axilEp, v.axilWriteSlave, v.axilReadSlave, AXI_ERROR_RESP_G);


      -- Reset
      if (axilRst = '1') then
         v := REG_INIT_C;
      end if;

      -- Next register assignment
      rin <= v;

      -- Outputs
      axilReadSlave  <= r.axilReadSlave;
      axilWriteSlave <= r.axilWriteSlave;

   end process;


---------------------------------------
-- Status Vector
---------------------------------------
-- statusSend <= rxStatusSend;

-- U_StatusWord : process (rxStatusSync)
-- begin
--    statusWord <= (others => '0');

--    statusWord(ERROR_CNT_WIDTH_G-1+24 downto 24) <= rxStatusSync.linkDownCount;
--    statusWord(ERROR_CNT_WIDTH_G-1+16 downto 16) <= rxStatusSync.frameErrCount;
--    statusWord(ERROR_CNT_WIDTH_G-1+8 downto 8)   <= rxStatusSync.cellErrorCount;

--    statusWord(7 downto 6) <= (others => '0');
--    statusWord(5)          <= rxStatusSync.remLinkReady;
--    statusWord(4)          <= rxStatusSync.locLinkReady;
--    statusWord(3 downto 0) <= rxStatusSync.remOverflow;
-- end process;

end architecture rtl;
