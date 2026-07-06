with Ada.Finalization;

--  Support level: private internal implementation.
--
--  Crawl-run lifecycle coordination. The guard serializes concurrent
--  Fetch_Website runs in one process while allowing same-task reentrancy.

private package Sitefetch.Engine.Run_Control is
   type Fetch_Run_Guard is new Ada.Finalization.Limited_Controlled with private;

private
   type Fetch_Run_Guard is new Ada.Finalization.Limited_Controlled with null record;

   overriding procedure Initialize (Guard : in out Fetch_Run_Guard);
   overriding procedure Finalize (Guard : in out Fetch_Run_Guard);
end Sitefetch.Engine.Run_Control;
