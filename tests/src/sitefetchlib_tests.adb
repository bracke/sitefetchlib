with Ada.Command_Line;

with AUnit;
with AUnit.Reporter.Text;
with AUnit.Run;

with Sitefetchlib_Test_Suite;

procedure Sitefetchlib_Tests is
   use type AUnit.Status;

   function Runner is new AUnit.Run.Test_Runner_With_Status (Sitefetchlib_Test_Suite.All_Tests);

   Reporter : AUnit.Reporter.Text.Text_Reporter;
   Status   : AUnit.Status;
begin
   Status := Runner (Reporter);
   if Status = AUnit.Failure then
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
end Sitefetchlib_Tests;
