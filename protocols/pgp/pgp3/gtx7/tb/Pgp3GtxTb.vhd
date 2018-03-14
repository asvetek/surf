-------------------------------------------------------------------------------
-- Title      : Testbench for Pgp3 with Gtx7
-------------------------------------------------------------------------------
-- Company    : SLAC National Accelerator Laboratory
-- Platform   : 
-- Standard   : VHDL'93/02
-------------------------------------------------------------------------------
-- Description: 
-------------------------------------------------------------------------------
-- This file is part of SURF. It is subject to
-- the license terms in the LICENSE.txt file found in the top-level directory
-- of this distribution and at:
--    https://confluence.slac.stanford.edu/display/ppareg/LICENSE.html.
-- No part of SURF, including this file, may be
-- copied, modified, propagated, or distributed except according to the terms
-- contained in the LICENSE.txt file.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use ieee.std_logic_arith.all;

use work.StdRtlPkg.all;
use work.AxiLitePkg.all;
use work.AxiStreamPkg.all;
use work.SsiPkg.all;
use work.Pgp3Pkg.all;

----------------------------------------------------------------------------------------------------

entity Pgp3Gtx7Tb is

end entity Pgp3Gtx7Tb;

----------------------------------------------------------------------------------------------------

architecture tb of Pgp3Gtx7Tb is

   -- component generics
   constant TPD_G               : time    := 1 ns;
   constant TX_CELL_WORDS_MAX_G : integer := 256;
   constant NUM_VC_G            : integer := 4;
   constant SKP_INTERVAL_G      : integer := 5000;
   constant SKP_BURST_SIZE_G    : integer := 8;

   constant MUX_MODE_G                   : string               := "INDEXED";  -- Or "ROUTED"
   constant MUX_TDEST_ROUTES_G           : Slv8Array            := (0 => "--------");  -- Only used in ROUTED mode
   constant MUX_TDEST_LOW_G              : integer range 0 to 7 := 0;
   constant MUX_INTERLEAVE_EN_G          : boolean              := true;
   constant MUX_INTERLEAVE_ON_NOTVALID_G : boolean              := false;

   constant PACKETIZER_IN_AXIS_CFG_C : AxiStreamConfigType := (
      TSTRB_EN_C    => false,
      TDATA_BYTES_C => 8,
      TDEST_BITS_C  => 8,
      TID_BITS_C    => 8,
      TKEEP_MODE_C  => TKEEP_COMP_C,
      TUSER_BITS_C  => 8,
      TUSER_MODE_C  => TUSER_FIRST_LAST_C);

   constant RX_AXIS_CFG_C : AxiStreamConfigType := (
      TSTRB_EN_C    => false,
      TDATA_BYTES_C => 4,
      TDEST_BITS_C  => 8,
      TID_BITS_C    => 8,
      TKEEP_MODE_C  => TKEEP_COMP_C,
      TUSER_BITS_C  => 2,
      TUSER_MODE_C  => TUSER_FIRST_LAST_C);

   -- Clocking
   signal rxClk : sl;
   signal rxRst : sl;

   signal axisClk : sl;                 -- [in]
   signal axisRst : sl;                 -- [in]

   -- TX
   signal pgpTxIn        : Pgp3TxInType := PGP3_TX_IN_INIT_C;
   signal pgpTxOut       : Pgp3TxOutType;
   signal pgpTxMasters   : AxiStreamMasterArray(NUM_VC_G-1 downto 0);  -- [in]
   signal pgpTxSlaves    : AxiStreamSlaveArray(NUM_VC_G-1 downto 0);   -- [out]
   signal pgpTxCtrl      : AxiStreamCtrlArray(NUM_VC_G-1 downto 0);
   -- status from rx to tx
   signal locRxLinkReady : sl;
   signal remRxFifoCtrl  : AxiStreamCtrlArray(NUM_VC_G-1 downto 0);
   signal remRxLinkReady : sl;
   -- Tx phy out
   signal phyTxData      : slv(63 downto 0);
   signal phyTxHeader    : slv(1 downto 0);

   signal phyRxData   : slv(63 downto 0);
   signal phyRxHeader : slv(1 downto 0);

   signal pgpRxIn      : Pgp3RxInType                            := PGP3_RX_IN_INIT_C;
   signal pgpRxOut     : Pgp3RxOutType;
   signal pgpRxMasters : AxiStreamMasterArray(NUM_VC_G-1 downto 0);
   signal pgpRxCtrl    : AxiStreamCtrlArray(NUM_VC_G-1 downto 0) := (others => AXI_STREAM_CTRL_UNUSED_C);

begin

   process is
   begin
      wait for 600 us;
      pgpTxIn.disable <= '1';
      wait for 100 us;
      pgpTxIn.disable <= '0';
      wait;
   end process;
              

   U_ClkRst_1 : entity work.ClkRst
      generic map (
         CLK_PERIOD_G      => 10 ns,
         CLK_DELAY_G       => 1 ns,
         RST_START_DELAY_G => 0 ns,
         RST_HOLD_TIME_G   => 5 us,
         SYNC_RESET_G      => true)
      port map (
         clkP => axisClk,
         rst  => axisRst);

   PRBS_GEN : for i in 0 to NUM_VC_G-1 generate
      U_SsiPrbsTx_1 : entity work.SsiPrbsTx
         generic map (
            TPD_G                      => TPD_G,
            GEN_SYNC_FIFO_G            => true,
            PRBS_INCREMENT_G           => true,
            MASTER_AXI_STREAM_CONFIG_G => PACKETIZER_IN_AXIS_CFG_C)
         port map (
            mAxisClk     => axisClk,          -- [in]
            mAxisRst     => axisRst,          -- [in]
            mAxisMaster  => pgpTxMasters(i),  -- [out]
            mAxisSlave   => pgpTxSlaves(i),   -- [in]
            locClk       => axisClk,          -- [in]
            locRst       => axisRst,          -- [in]
            trig         => '1',              -- [in]
            packetLength => X"0000FFFF",      -- [in]
            forceEofe    => '0',              -- [in]
            busy         => open,             -- [out]
            tDest        => toSlv(i, 8),      -- [in]
            tId          => X"00");           -- [in]
   end generate PRBS_GEN;

   -------------------------------------------------------------------------------------------------
   -- PGP3 Transmit
   -------------------------------------------------------------------------------------------------
   U_Pgp3Tx_1 : entity work.Pgp3Tx
      generic map (
         TPD_G                        => TPD_G,
         NUM_VC_G                     => NUM_VC_G,
         TX_CELL_WORDS_MAX_G          => TX_CELL_WORDS_MAX_G,
         SKP_INTERVAL_G               => SKP_INTERVAL_G,
         SKP_BURST_SIZE_G             => SKP_BURST_SIZE_G,
         MUX_MODE_G                   => MUX_MODE_G,
         MUX_TDEST_ROUTES_G           => MUX_TDEST_ROUTES_G,
         MUX_TDEST_LOW_G              => MUX_TDEST_LOW_G,
         MUX_INTERLEAVE_EN_G          => MUX_INTERLEAVE_EN_G,
         MUX_INTERLEAVE_ON_NOTVALID_G => MUX_INTERLEAVE_ON_NOTVALID_G)
      port map (
         pgpTxClk       => axisClk,         -- [in]
         pgpTxRst       => axisRst,         -- [in]
         pgpTxIn        => pgpTxIn,         -- [in]
         pgpTxOut       => pgpTxOut,        -- [out]
         pgpTxMasters   => pgpTxMasters,    -- [in]
         pgpTxSlaves    => pgpTxSlaves,     -- [out]
         pgpTxCtrl      => pgpTxCtrl,       -- [out]
         locRxFifoCtrl  => pgpRxCtrl,       -- [in]
         locRxLinkReady => locRxLinkReady,  -- [in]
         remRxFifoCtrl  => remRxFifoCtrl,   -- [in]
         remRxLinkReady => remRxLinkReady,  -- [in]
         phyTxReady     => '1',             -- [in]
         phyTxData      => phyTxData,       -- [out]
         phyTxHeader    => phyTxHeader);    -- [out]

   phyRxHeader <= phyTxHeader;
   phyRxData   <= phyTxData;

   U_Pgp3Rx_1 : entity work.Pgp3Rx
      generic map (
         TPD_G    => TPD_G,
         NUM_VC_G => NUM_VC_G)
      port map (
         pgpRxClk         => axisClk,         -- [in]
         pgpRxRst         => axisRst,         -- [in]
         pgpRxIn          => pgpRxIn,         -- [in]
         pgpRxOut         => pgpRxOut,        -- [out]
         pgpRxMasters     => pgpRxMasters,    -- [out]
         pgpRxCtrl        => pgpRxCtrl,       -- [in]
         remRxFifoCtrl    => remRxFifoCtrl,   -- [out]
         remRxLinkReady   => remRxLinkReady,  -- [out]
         locRxLinkReady   => locRxLinkReady,  -- [out]
         phyRxClk         => '0',             -- [in]
         phyRxReady       => '1',             -- [in]
         phyRxInit        => open,            -- [out]
         phyRxHeaderValid => '1',             -- [in]
         phyRxHeader      => phyRxHeader,     -- [in]
         phyRxDataValid   => "11",            -- [in]
         phyRxData        => phyRxData,       -- [in]
         phyRxStartSeq    => '0',             -- [in]
         phyRxSlip        => open);           -- [out]



   U_Gtx7Core_1: entity work.Gtx7Core
      generic map (
         TPD_G                    => TPD_G,
         SIM_GTRESET_SPEEDUP_G    => SIM_GTRESET_SPEEDUP_G,
         SIM_VERSION_G            => SIM_VERSION_G,
         SIMULATION_G             => SIMULATION_G,
         STABLE_CLOCK_PERIOD_G    => STABLE_CLOCK_PERIOD_G,
         CPLL_REFCLK_SEL_G        => CPLL_REFCLK_SEL_G,
         CPLL_FBDIV_G             => CPLL_FBDIV_G,
         CPLL_FBDIV_45_G          => CPLL_FBDIV_45_G,
         CPLL_REFCLK_DIV_G        => CPLL_REFCLK_DIV_G,
         RXOUT_DIV_G              => RXOUT_DIV_G,
         TXOUT_DIV_G              => TXOUT_DIV_G,
         RX_CLK25_DIV_G           => RX_CLK25_DIV_G,
         TX_CLK25_DIV_G           => TX_CLK25_DIV_G,
         PMA_RSV_G                => PMA_RSV_G,
         RX_OS_CFG_G              => RX_OS_CFG_G,
         RXCDR_CFG_G              => RXCDR_CFG_G,
         TX_PLL_G                 => TX_PLL_G,
         RX_PLL_G                 => RX_PLL_G,
         TX_EXT_DATA_WIDTH_G      => TX_EXT_DATA_WIDTH_G,
         TX_INT_DATA_WIDTH_G      => TX_INT_DATA_WIDTH_G,
         TX_8B10B_EN_G            => TX_8B10B_EN_G,
         TX_GEARBOX_EN_G          => TX_GEARBOX_EN_G,
         RX_EXT_DATA_WIDTH_G      => RX_EXT_DATA_WIDTH_G,
         RX_INT_DATA_WIDTH_G      => RX_INT_DATA_WIDTH_G,
         RX_8B10B_EN_G            => RX_8B10B_EN_G,
         RX_GEARBOX_EN_G          => RX_GEARBOX_EN_G,
         RX_GEARBOX_SEQUENCE_G    => RX_GEARBOX_SEQUENCE_G,
         RX_GEARBOX_MODE_G        => RX_GEARBOX_MODE_G,
         TX_BUF_EN_G              => TX_BUF_EN_G,
         TX_OUTCLK_SRC_G          => TX_OUTCLK_SRC_G,
         TX_DLY_BYPASS_G          => TX_DLY_BYPASS_G,
         TX_PHASE_ALIGN_G         => TX_PHASE_ALIGN_G,
         TX_BUF_ADDR_MODE_G       => TX_BUF_ADDR_MODE_G,
         RX_BUF_EN_G              => RX_BUF_EN_G,
         RX_OUTCLK_SRC_G          => RX_OUTCLK_SRC_G,
         RX_USRCLK_SRC_G          => RX_USRCLK_SRC_G,
         RX_DLY_BYPASS_G          => RX_DLY_BYPASS_G,
         RX_DDIEN_G               => RX_DDIEN_G,
         RX_BUF_ADDR_MODE_G       => RX_BUF_ADDR_MODE_G,
         RX_ALIGN_MODE_G          => RX_ALIGN_MODE_G,
         ALIGN_COMMA_DOUBLE_G     => ALIGN_COMMA_DOUBLE_G,
         ALIGN_COMMA_ENABLE_G     => ALIGN_COMMA_ENABLE_G,
         ALIGN_COMMA_WORD_G       => ALIGN_COMMA_WORD_G,
         ALIGN_MCOMMA_DET_G       => ALIGN_MCOMMA_DET_G,
         ALIGN_MCOMMA_VALUE_G     => ALIGN_MCOMMA_VALUE_G,
         ALIGN_MCOMMA_EN_G        => ALIGN_MCOMMA_EN_G,
         ALIGN_PCOMMA_DET_G       => ALIGN_PCOMMA_DET_G,
         ALIGN_PCOMMA_VALUE_G     => ALIGN_PCOMMA_VALUE_G,
         ALIGN_PCOMMA_EN_G        => ALIGN_PCOMMA_EN_G,
         SHOW_REALIGN_COMMA_G     => SHOW_REALIGN_COMMA_G,
         RXSLIDE_MODE_G           => RXSLIDE_MODE_G,
         FIXED_COMMA_EN_G         => FIXED_COMMA_EN_G,
         FIXED_ALIGN_COMMA_0_G    => FIXED_ALIGN_COMMA_0_G,
         FIXED_ALIGN_COMMA_1_G    => FIXED_ALIGN_COMMA_1_G,
         FIXED_ALIGN_COMMA_2_G    => FIXED_ALIGN_COMMA_2_G,
         FIXED_ALIGN_COMMA_3_G    => FIXED_ALIGN_COMMA_3_G,
         RX_DISPERR_SEQ_MATCH_G   => RX_DISPERR_SEQ_MATCH_G,
         DEC_MCOMMA_DETECT_G      => DEC_MCOMMA_DETECT_G,
         DEC_PCOMMA_DETECT_G      => DEC_PCOMMA_DETECT_G,
         DEC_VALID_COMMA_ONLY_G   => DEC_VALID_COMMA_ONLY_G,
         CBCC_DATA_SOURCE_SEL_G   => CBCC_DATA_SOURCE_SEL_G,
         CLK_COR_SEQ_2_USE_G      => CLK_COR_SEQ_2_USE_G,
         CLK_COR_KEEP_IDLE_G      => CLK_COR_KEEP_IDLE_G,
         CLK_COR_MAX_LAT_G        => CLK_COR_MAX_LAT_G,
         CLK_COR_MIN_LAT_G        => CLK_COR_MIN_LAT_G,
         CLK_COR_PRECEDENCE_G     => CLK_COR_PRECEDENCE_G,
         CLK_COR_REPEAT_WAIT_G    => CLK_COR_REPEAT_WAIT_G,
         CLK_COR_SEQ_LEN_G        => CLK_COR_SEQ_LEN_G,
         CLK_COR_SEQ_1_ENABLE_G   => CLK_COR_SEQ_1_ENABLE_G,
         CLK_COR_SEQ_1_1_G        => CLK_COR_SEQ_1_1_G,
         CLK_COR_SEQ_1_2_G        => CLK_COR_SEQ_1_2_G,
         CLK_COR_SEQ_1_3_G        => CLK_COR_SEQ_1_3_G,
         CLK_COR_SEQ_1_4_G        => CLK_COR_SEQ_1_4_G,
         CLK_CORRECT_USE_G        => CLK_CORRECT_USE_G,
         CLK_COR_SEQ_2_ENABLE_G   => CLK_COR_SEQ_2_ENABLE_G,
         CLK_COR_SEQ_2_1_G        => CLK_COR_SEQ_2_1_G,
         CLK_COR_SEQ_2_2_G        => CLK_COR_SEQ_2_2_G,
         CLK_COR_SEQ_2_3_G        => CLK_COR_SEQ_2_3_G,
         CLK_COR_SEQ_2_4_G        => CLK_COR_SEQ_2_4_G,
         RX_CHAN_BOND_EN_G        => RX_CHAN_BOND_EN_G,
         RX_CHAN_BOND_MASTER_G    => RX_CHAN_BOND_MASTER_G,
         CHAN_BOND_KEEP_ALIGN_G   => CHAN_BOND_KEEP_ALIGN_G,
         CHAN_BOND_MAX_SKEW_G     => CHAN_BOND_MAX_SKEW_G,
         CHAN_BOND_SEQ_LEN_G      => CHAN_BOND_SEQ_LEN_G,
         CHAN_BOND_SEQ_1_1_G      => CHAN_BOND_SEQ_1_1_G,
         CHAN_BOND_SEQ_1_2_G      => CHAN_BOND_SEQ_1_2_G,
         CHAN_BOND_SEQ_1_3_G      => CHAN_BOND_SEQ_1_3_G,
         CHAN_BOND_SEQ_1_4_G      => CHAN_BOND_SEQ_1_4_G,
         CHAN_BOND_SEQ_1_ENABLE_G => CHAN_BOND_SEQ_1_ENABLE_G,
         CHAN_BOND_SEQ_2_1_G      => CHAN_BOND_SEQ_2_1_G,
         CHAN_BOND_SEQ_2_2_G      => CHAN_BOND_SEQ_2_2_G,
         CHAN_BOND_SEQ_2_3_G      => CHAN_BOND_SEQ_2_3_G,
         CHAN_BOND_SEQ_2_4_G      => CHAN_BOND_SEQ_2_4_G,
         CHAN_BOND_SEQ_2_ENABLE_G => CHAN_BOND_SEQ_2_ENABLE_G,
         CHAN_BOND_SEQ_2_USE_G    => CHAN_BOND_SEQ_2_USE_G,
         FTS_DESKEW_SEQ_ENABLE_G  => FTS_DESKEW_SEQ_ENABLE_G,
         FTS_LANE_DESKEW_CFG_G    => FTS_LANE_DESKEW_CFG_G,
         FTS_LANE_DESKEW_EN_G     => FTS_LANE_DESKEW_EN_G,
         RX_EQUALIZER_G           => RX_EQUALIZER_G,
         RX_DFE_KL_CFG2_G         => RX_DFE_KL_CFG2_G,
         RX_CM_TRIM_G             => RX_CM_TRIM_G,
         RX_DFE_LPM_CFG_G         => RX_DFE_LPM_CFG_G,
         RXDFELFOVRDEN_G          => RXDFELFOVRDEN_G,
         RXDFEXYDEN_G             => RXDFEXYDEN_G)
      port map (
         stableClkIn          => stableClkIn,           -- [in]
         cPllRefClkIn         => cPllRefClkIn,          -- [in]
         cPllLockOut          => cPllLockOut,           -- [out]
         qPllRefClkIn         => qPllRefClkIn,          -- [in]
         qPllClkIn            => qPllClkIn,             -- [in]
         qPllLockIn           => qPllLockIn,            -- [in]
         qPllRefClkLostIn     => qPllRefClkLostIn,      -- [in]
         qPllResetOut         => qPllResetOut,          -- [out]
         gtRxRefClkBufg       => gtRxRefClkBufg,        -- [in]
         gtTxP                => gtTxP,                 -- [out]
         gtTxN                => gtTxN,                 -- [out]
         gtRxP                => gtRxP,                 -- [in]
         gtRxN                => gtRxN,                 -- [in]
         rxOutClkOut          => rxOutClkOut,           -- [out]
         rxUsrClkIn           => rxUsrClkIn,            -- [in]
         rxUsrClk2In          => rxUsrClk2In,           -- [in]
         rxUserRdyOut         => rxUserRdyOut,          -- [out]
         rxMmcmResetOut       => rxMmcmResetOut,        -- [out]
         rxMmcmLockedIn       => rxMmcmLockedIn,        -- [in]
         rxUserResetIn        => rxUserResetIn,         -- [in]
         rxResetDoneOut       => rxResetDoneOut,        -- [out]
         rxDataValidIn        => rxDataValidIn,         -- [in]
         rxSlideIn            => rxSlideIn,             -- [in]
         rxDataOut            => rxDataOut,             -- [out]
         rxCharIsKOut         => rxCharIsKOut,          -- [out]
         rxDecErrOut          => rxDecErrOut,           -- [out]
         rxDispErrOut         => rxDispErrOut,          -- [out]
         rxPolarityIn         => rxPolarityIn,          -- [in]
         rxBufStatusOut       => rxBufStatusOut,        -- [out]
         rxGearboxDataValid   => rxGearboxDataValid,    -- [out]
         rxGearboxSlip        => rxGearboxSlip,         -- [in]
         rxGearboxHeader      => rxGearboxHeader,       -- [out]
         rxGearboxHeaderValid => rxGearboxHeaderValid,  -- [out]
         rxGearboxStartOfSeq  => rxGearboxStartOfSeq,   -- [out]
         rxChBondLevelIn      => rxChBondLevelIn,       -- [in]
         rxChBondIn           => rxChBondIn,            -- [in]
         rxChBondOut          => rxChBondOut,           -- [out]
         txOutClkOut          => txOutClkOut,           -- [out]
         txUsrClkIn           => txUsrClkIn,            -- [in]
         txUsrClk2In          => txUsrClk2In,           -- [in]
         txUserRdyOut         => txUserRdyOut,          -- [out]
         txMmcmResetOut       => txMmcmResetOut,        -- [out]
         txMmcmLockedIn       => txMmcmLockedIn,        -- [in]
         txUserResetIn        => txUserResetIn,         -- [in]
         txResetDoneOut       => txResetDoneOut,        -- [out]
         txDataIn             => txDataIn,              -- [in]
         txCharIsKIn          => txCharIsKIn,           -- [in]
         txBufStatusOut       => txBufStatusOut,        -- [out]
         txPolarityIn         => txPolarityIn,          -- [in]
         txGearboxReady       => txGearboxReady,        -- [out]
         txGearboxHeader      => txGearboxHeader,       -- [in]
         txGearboxSequence    => txGearboxSequence,     -- [in]
         txGearboxStartSeq    => txGearboxStartSeq,     -- [in]
         txPowerDown          => txPowerDown,           -- [in]
         rxPowerDown          => rxPowerDown,           -- [in]
         loopbackIn           => loopbackIn,            -- [in]
         txPreCursor          => txPreCursor,           -- [in]
         txPostCursor         => txPostCursor,          -- [in]
         txDiffCtrl           => txDiffCtrl,            -- [in]
         drpClk               => drpClk,                -- [in]
         drpRdy               => drpRdy,                -- [out]
         drpEn                => drpEn,                 -- [in]
         drpWe                => drpWe,                 -- [in]
         drpAddr              => drpAddr,               -- [in]
         drpDi                => drpDi,                 -- [in]
         drpDo                => drpDo);                -- [out]

end architecture tb;

----------------------------------------------------------------------------------------------------
