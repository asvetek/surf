-------------------------------------------------------------------------------
-- File       : AxiTranFilter.vhd
-- Company    : SLAC National Accelerator Laboratory
-- Created    : 2018-06-13
-------------------------------------------------------------------------------
-- Description: Block to only allow one transaction at a time.
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
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

use work.StdRtlPkg.all;
use work.ArbiterPkg.all;
use work.AxiPkg.all;

entity AxiTranFilter is
   generic (
      TPD_G : time := 1 ns
      );
   port (

      -- Clock and reset
      axiClk : in sl;
      axiRst : in sl;

      -- Slaves
      sAxiReadMaster  : in AxiReadMasterType;
      sAxiReadSlave   : out AxiReadSlaveType;
      sAxiWriteMaster : in AxiWriteMasterType;
      sAxiWriteSlave  : out AxiWriteSlaveType;

      -- Master
      mAxiReadMaster  : out AxiReadMasterType;
      mAxiReadSlave   : in AxiReadSlaveType;
      mAxiWriteMaster : out AxiWriteMasterType;
      mAxiWriteSlave  : in AxiWriteSlaveType
      );
end AxiTranFilter;

architecture structure of AxiTranFilter is

   --------------------------
   -- Address Path
   --------------------------

   type StateType is (S_IDLE_C, S_WSTART_C, S_WWAIT_C, S_RSTART_C, S_RWAIT_C);

   type RegType is record
      state        : StateType;
      readMaster   : AxiReadMasterType;
      writeMaster  : AxiWriteMasterType;
      readSlave    : AxiReadSlaveType;
      writeSlave   : AxiWriteSlaveType;
   end record RegType;

   constant REG_INIT_C : RegType := (
      state        => S_IDLE_C,
      readMaster   => AXI_READ_MASTER_INIT_C,
      writeMaster  => AXI_WRITE_MASTER_INIT_C,
      readSlave    => AXI_READ_SLAVE_INIT_C,
      writeSlave   => AXI_WRITE_SLAVE_INIT_C
      );

   signal r : RegType := REG_INIT_C;
   signal rin : RegType;

begin

   comb : process (axiRst, r, sAxiReadMaster, sAxiWriteMaster, mAxiReadSlave, mAxiWriteSlave) is
      variable v : RegType;
   begin
      v := r;

      -- Most signals connect through
      v.readMaster  := sAxiReadMaster;
      v.WriteMaster := sAxiWriteMaster;
      v.readSlave   := mAxiReadSlave;
      v.WriteSlave  := mAxiWriteSlave;

      -- Block transaction starts by default
      v.readMaster.arvalid  := '0';
      v.WriteMaster.awvalid := '0';
      v.readSlave.arready   := '0';
      v.WriteSlave.awready  := '0';

      -- State machine
      case r.state is

         -- IDLE
         when S_IDLE_C =>

            if sAxiReadMaster.arvalid = '1' then
               v.state := S_RSTART_C;
            elsif sAxiWriteMaster.awvalid = '1' then
               v.state := S_WSTART_C;
            end if;

         when S_WSTART_C =>
            v.writeMaster.awvalid := sAxiWriteMaster.awvalid;
            v.writeSlave.awready  := mAxiWriteSlave.awready;

            if sAxiWriteMaster.awvalid = '1' and mAxiWriteSlave.awready = '1' then
               v.state := S_WWAIT_C;
            end if;

         when S_RSTART_C =>
            v.readMaster.arvalid := sAxiReadMaster.arvalid;
            v.readSlave.arready  := mAxiReadSlave.arready;

            if sAxiReadMaster.arvalid = '1' and mAxiReadSlave.arready = '1' then
               v.state := S_RWAIT_C;
            end if;

         when S_WWAIT_C =>
            if mAxiWriteSlave.bvalid = '1' then
               v.state := S_IDLE_C;
            end if;

         when S_RWAIT_C =>
            if mAxiReadSlave.rvalid = '1' and mAxiReadSlave.rlast = '1' then
               v.state := S_IDLE_C;
            end if;

         when others =>
            v.state := S_IDLE_C;

      end case;

      mAxiReadMaster  <= v.readMaster;
      mAxiWriteMaster <= v.writeMaster;
      sAxiReadSlave   <= v.readSlave;
      sAxiWriteSlave  <= v.WriteSlave;

      if axiRst = '1' then
         v := REG_INIT_C;
      end if;

      rin <= v;

   end process comb;

   seq : process (axiClk) is
   begin
      if (rising_edge(axiClk)) then
         r <= rin after TPD_G;
      end if;
   end process seq;

end structure;

