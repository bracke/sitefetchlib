with Ada.Strings.Unbounded;
with Ada.Text_IO;

package body Structured_Progress_Example is
   use Ada.Strings.Unbounded;

   procedure Report (Progress : Sitefetch.Progress_Record) is
   begin
      Ada.Text_IO.Put_Line
        (Sitefetch.Progress_Event'Image (Progress.Event)
         & " url=" & To_String (Progress.URL)
         & " reason=" & To_String (Progress.Reason)
         & " cache=" & To_String (Progress.Cache_Decision)
         & " bytes=" & Natural'Image (Progress.Bytes_Written));
   end Report;
end Structured_Progress_Example;
