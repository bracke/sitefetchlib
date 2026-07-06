with Ada.Task_Identification;

package body Sitefetch.Engine.Run_Control is
   use type Ada.Task_Identification.Task_Id;

   protected Fetch_Run_Gate is
      procedure Try_Acquire (Acquired : out Boolean);
      procedure Release;
   private
      Owner : Ada.Task_Identification.Task_Id := Ada.Task_Identification.Null_Task_Id;
      Depth : Natural := 0;
   end Fetch_Run_Gate;

   procedure Acquire_Fetch_Run;

   protected body Fetch_Run_Gate is
      procedure Try_Acquire (Acquired : out Boolean) is
         Current : constant Ada.Task_Identification.Task_Id := Ada.Task_Identification.Current_Task;
      begin
         if Depth = 0 then
            Owner := Current;
            Depth := 1;
            Acquired := True;
         elsif Owner = Current then
            Depth := Depth + 1;
            Acquired := True;
         else
            Acquired := False;
         end if;
      end Try_Acquire;

      procedure Release is
      begin
         if Depth > 1 then
            Depth := Depth - 1;
         else
            Depth := 0;
            Owner := Ada.Task_Identification.Null_Task_Id;
         end if;
      end Release;
   end Fetch_Run_Gate;

   procedure Acquire_Fetch_Run is
      Acquired : Boolean := False;
   begin
      while not Acquired loop
         Fetch_Run_Gate.Try_Acquire (Acquired);
         if not Acquired then
            delay 0.01;
         end if;
      end loop;
   end Acquire_Fetch_Run;

   overriding procedure Initialize (Guard : in out Fetch_Run_Guard) is
      pragma Unreferenced (Guard);
   begin
      Acquire_Fetch_Run;
   end Initialize;

   overriding procedure Finalize (Guard : in out Fetch_Run_Guard) is
      pragma Unreferenced (Guard);
   begin
      Fetch_Run_Gate.Release;
   end Finalize;
end Sitefetch.Engine.Run_Control;
