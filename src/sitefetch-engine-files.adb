with Ada.Containers.Indefinite_Hashed_Sets;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Http_Client.Clients;
with Http_Client.Errors;

package body Sitefetch.Engine.Files is
   use Ada.Strings.Unbounded;
   use type Ada.Directories.File_Kind;
   use type Http_Client.Errors.Result_Status;

   package Path_Sets is new Ada.Containers.Indefinite_Hashed_Sets
     (Element_Type        => String,
      Hash                => Ada.Strings.Hash,
      Equivalent_Elements => "=");

   protected Directory_Creation_Cache is
      procedure Lookup (Path_Text : String; Found : out Boolean);
      procedure Store (Path_Text : String);
      procedure Clear;
   private
      Entries : Path_Sets.Set;
   end Directory_Creation_Cache;

   protected body Directory_Creation_Cache is
      procedure Lookup (Path_Text : String; Found : out Boolean) is
      begin
         Found := Entries.Contains (Path_Text);
      end Lookup;

      procedure Store (Path_Text : String) is
      begin
         Entries.Include (Path_Text);
      end Store;

      procedure Clear is
      begin
         Entries.Clear;
      end Clear;
   end Directory_Creation_Cache;

   protected Temp_Path_Counter is
      procedure Next (Value : out Natural);
   private
      Current : Natural := 0;
   end Temp_Path_Counter;

   protected body Temp_Path_Counter is
      procedure Next (Value : out Natural) is
      begin
         if Current = Natural'Last then
            Current := 1;
         else
            Current := Current + 1;
         end if;
         Value := Current;
      end Next;
   end Temp_Path_Counter;

   procedure Clear_Directory_Cache is
   begin
      Directory_Creation_Cache.Clear;
   end Clear_Directory_Cache;

   function Containing_Path (Path_Text : String) return String is
   begin
      for Index_Value in reverse Path_Text'Range loop
         if Path_Text (Index_Value) = '/' then
            if Index_Value = Path_Text'First then
               return ".";
            end if;

            return Path_Text (Path_Text'First .. Index_Value - 1);
         end if;
      end loop;

      return ".";
   end Containing_Path;

   procedure Ensure_Directory (Directory : String) is
      Found : Boolean;
   begin
      if Directory = "." then
         return;
      end if;

      Directory_Creation_Cache.Lookup (Directory, Found);
      if Found then
         return;
      end if;

      begin
         if Ada.Directories.Exists (Directory) then
            if Ada.Directories.Kind (Directory) /= Ada.Directories.Directory then
               raise Ada.Directories.Use_Error;
            end if;
         else
            Ada.Directories.Create_Path (Directory);
         end if;
      exception
         when Ada.Directories.Name_Error | Ada.Directories.Use_Error =>
            if not Ada.Directories.Exists (Directory)
              or else Ada.Directories.Kind (Directory) /= Ada.Directories.Directory
            then
               raise;
            end if;
      end;

      Directory_Creation_Cache.Store (Directory);
   end Ensure_Directory;

   function Next_Temp_Path_Suffix return String is
      Value : Natural;
   begin
      Temp_Path_Counter.Next (Value);
      return ".sitefetch_" & Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Left);
   end Next_Temp_Path_Suffix;

   function Available_Sibling_Path (Base_Path : String; Purpose_Suffix : String) return String is
      Attempt : Natural := 0;
   begin
      while Attempt < 1_000 loop
         Attempt := Attempt + 1;
         declare
            Candidate : constant String := Base_Path & Purpose_Suffix & Next_Temp_Path_Suffix;
         begin
            if not Ada.Directories.Exists (Candidate) then
               return Candidate;
            end if;
         end;
      end loop;

      return "";
   exception
      when others =>
         return "";
   end Available_Sibling_Path;

   procedure Delete_Ordinary_File_If_Present (Path_Text : String) is
      Status : constant Http_Client.Errors.Result_Status :=
        Http_Client.Clients.Delete_Ordinary_File_If_Present (Path_Text);
      pragma Unreferenced (Status);
   begin
      null;
   end Delete_Ordinary_File_If_Present;

   procedure Atomic_Install_File (Source_Path : String; Target_Path : String) is
      Status : constant Http_Client.Errors.Result_Status :=
        Http_Client.Clients.Install_File_Atomically
          (Source_Path        => Source_Path,
           Target_Path        => Target_Path,
           Backup_Suffix      => ".sitefetch_old",
           Create_Parent_Dirs => True);
   begin
      if Status /= Http_Client.Errors.Ok then
         raise Ada.Directories.Use_Error;
      end if;
   end Atomic_Install_File;

   procedure Write_Text
     (Path_Text    : String;
      Content_Text : String;
      Durability   : Write_Durability_Mode := Write_Durability_Default) is
      HTTP_Durability : constant Http_Client.Clients.File_Durability_Mode :=
        (case Durability is
            when Write_Durability_Default => Http_Client.Clients.File_Durability_Default,
            when Write_Durability_Flush_Temp_File => Http_Client.Clients.File_Durability_Flush_Temp_File,
            when Write_Durability_Sync_Data_And_Directory =>
              Http_Client.Clients.File_Durability_Sync_Data_And_Directory);
      Status : constant Http_Client.Errors.Result_Status :=
        Http_Client.Clients.Write_Text_File_Atomically
          (Path          => Path_Text,
           Content       => Content_Text,
           Temp_Suffix   => ".sitefetch_tmp",
           Backup_Suffix => ".sitefetch_old",
           Durability    => HTTP_Durability);
   begin
      if Status /= Http_Client.Errors.Ok then
         raise Ada.Directories.Use_Error;
      end if;
   end Write_Text;

   function Read_Text_File
     (Path_Text    : String;
      Content_Text : out Unbounded_String) return Boolean is
      Input_File : Ada.Text_IO.File_Type;
      Buffer     : String (1 .. 4_096);
      Last       : Natural;
   begin
      Content_Text := Null_Unbounded_String;
      Ada.Text_IO.Open (Input_File, Ada.Text_IO.In_File, Path_Text);
      while not Ada.Text_IO.End_Of_File (Input_File) loop
         Ada.Text_IO.Get_Line (Input_File, Buffer, Last);
         if Last > 0 then
            Append (Content_Text, Buffer (1 .. Last));
         end if;
      end loop;
      Ada.Text_IO.Close (Input_File);
      return True;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (Input_File) then
            Ada.Text_IO.Close (Input_File);
         end if;
         Content_Text := Null_Unbounded_String;
         return False;
   end Read_Text_File;

   procedure Move_File_If_Needed (Source_Path : String; Target_Path : String) is
   begin
      if Source_Path = Target_Path or else not Ada.Directories.Exists (Source_Path) then
         return;
      end if;

      Atomic_Install_File (Source_Path, Target_Path);
   end Move_File_If_Needed;

   function Join_Path (Left_Text : String; Right_Text : String) return String is
   begin
      if Left_Text = "" or else Left_Text = "." then
         return Right_Text;
      elsif Left_Text (Left_Text'Last) = '/' then
         return Left_Text & Right_Text;
      else
         return Left_Text & "/" & Right_Text;
      end if;
   end Join_Path;

   function Write_Failure_Reason (Path : String) return String is
   begin
      return "write failed: " & Path;
   end Write_Failure_Reason;

   procedure Delete_File_If_Present (Path_Text : String) is
   begin
      if Ada.Directories.Exists (Path_Text)
        and then Ada.Directories.Kind (Path_Text) = Ada.Directories.Ordinary_File
      then
         Ada.Directories.Delete_File (Path_Text);
      end if;
   exception
      when others =>
         null;
   end Delete_File_If_Present;
end Sitefetch.Engine.Files;
