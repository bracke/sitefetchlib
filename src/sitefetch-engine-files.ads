with Ada.Strings.Unbounded;

--  Support level: private internal implementation.
--
--  File/path helpers for the crawl engine: directory creation caching,
--  sibling temp path selection, atomic installs, text reads/writes, and
--  best-effort cleanup.

private package Sitefetch.Engine.Files is
   procedure Clear_Directory_Cache;

   function Containing_Path (Path_Text : String) return String;

   procedure Ensure_Directory (Directory : String);

   function Next_Temp_Path_Suffix return String;

   function Available_Sibling_Path (Base_Path : String; Purpose_Suffix : String) return String;

   procedure Delete_Ordinary_File_If_Present (Path_Text : String);

   procedure Atomic_Install_File (Source_Path : String; Target_Path : String);

   procedure Write_Text
     (Path_Text    : String;
      Content_Text : String;
      Durability   : Write_Durability_Mode := Write_Durability_Default);

   function Read_Text_File
     (Path_Text    : String;
      Content_Text : out Ada.Strings.Unbounded.Unbounded_String) return Boolean;

   procedure Move_File_If_Needed (Source_Path : String; Target_Path : String);

   function Join_Path (Left_Text : String; Right_Text : String) return String;

   function Write_Failure_Reason (Path : String) return String;

   procedure Delete_File_If_Present (Path_Text : String);
end Sitefetch.Engine.Files;
