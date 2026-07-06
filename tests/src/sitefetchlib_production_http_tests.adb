with Ada.Calendar;
with Ada.Directories;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with GNAT.Sockets;

with AUnit;
with AUnit.Assertions;
with AUnit.Simple_Test_Cases;
with AUnit.Test_Suites;

with Project_Tools.Files;

with Sitefetch;
with Sitefetch.Crawler;
with Zlib;

package body Sitefetchlib_Production_HTTP_Tests is
   use Ada.Strings.Unbounded;
   use type Ada.Calendar.Time;
   use AUnit.Assertions;
   use type Sitefetch.Progress_Event;
   use type Zlib.Status_Code;

   type Production_HTTP_Fixture_Test is new AUnit.Simple_Test_Cases.Test_Case with null record;
   overriding function Name (Item : Production_HTTP_Fixture_Test) return AUnit.Message_String;
   overriding procedure Run_Test (Item : in out Production_HTTP_Fixture_Test);

   Structured_Progress_Count : Natural := 0;
   Last_Structured_Event     : Sitefetch.Progress_Event := Sitefetch.Progress_Fetching;
   Last_Structured_URL       : Unbounded_String := Null_Unbounded_String;
   Last_Structured_Reason    : Unbounded_String := Null_Unbounded_String;
   Last_Structured_Written_URL : Unbounded_String := Null_Unbounded_String;
   Last_Structured_Written_Bytes : Natural := 0;
   Last_Structured_Written_Depth : Natural := 0;
   Last_Structured_Written_Status : Natural := 0;
   Last_Structured_Written_Local_Path : Unbounded_String := Null_Unbounded_String;
   Last_Structured_Written_Final_URL : Unbounded_String := Null_Unbounded_String;
   Last_Structured_Written_Source_ID : Unbounded_String := Null_Unbounded_String;
   Last_Structured_Failed_Local_Path : Unbounded_String := Null_Unbounded_String;
   Last_Structured_Failed_Final_URL : Unbounded_String := Null_Unbounded_String;
   Last_Structured_Failed_Source_ID : Unbounded_String := Null_Unbounded_String;
   Last_Structured_Failed_Status : Natural := 0;
   Last_Structured_Retry_URL : Unbounded_String := Null_Unbounded_String;
   Last_Structured_Retry_Final_URL : Unbounded_String := Null_Unbounded_String;
   Last_Structured_Retry_Source_ID : Unbounded_String := Null_Unbounded_String;
   Last_Structured_Retry_Attempt : Natural := 0;
   Last_Structured_Retry_Status : Natural := 0;
   Last_Structured_Cache_URL : Unbounded_String := Null_Unbounded_String;
   Last_Structured_Cache_Decision : Unbounded_String := Null_Unbounded_String;
   Last_Structured_Cache_Local_Path : Unbounded_String := Null_Unbounded_String;
   Last_Structured_Robots_URL : Unbounded_String := Null_Unbounded_String;
   Last_Structured_Robots_Source : Unbounded_String := Null_Unbounded_String;
   Last_Structured_Final_URL : Unbounded_String := Null_Unbounded_String;
   Last_Structured_Source_ID : Unbounded_String := Null_Unbounded_String;
   Last_Structured_Redirect_Hops : Natural := 0;
   Last_Structured_Redirect_Chain : Unbounded_String := Null_Unbounded_String;
   Last_Structured_Redirect_Status_Codes : Unbounded_String := Null_Unbounded_String;
   Last_Structured_Redirect_Target_URLs : Unbounded_String := Null_Unbounded_String;
   Last_Structured_Redirect_Locations : Unbounded_String := Null_Unbounded_String;
   Last_Structured_Redirect_Status : Natural := 0;

   procedure Delete_Tree_If_Present (Path : String) is
   begin
      Project_Tools.Files.Delete_Tree (Path);
   end Delete_Tree_If_Present;

   function Read_File (Path : String) return String is
      File   : Ada.Text_IO.File_Type;
      Buffer : String (1 .. 1_024);
      Last   : Natural;
      Result : Unbounded_String := Null_Unbounded_String;
   begin
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
      while not Ada.Text_IO.End_Of_File (File) loop
         Ada.Text_IO.Get_Line (File, Buffer, Last);
         if Last > 0 then
            Append (Result, Buffer (1 .. Last));
         end if;
      end loop;
      Ada.Text_IO.Close (File);
      return To_String (Result);
   end Read_File;

   function Containing_Test_Path (Path : String) return String is
   begin
      for Index_Value in reverse Path'Range loop
         if Path (Index_Value) = '/' then
            if Index_Value = Path'First then
               return ".";
            end if;

            return Path (Path'First .. Index_Value - 1);
         end if;
      end loop;

      return ".";
   end Containing_Test_Path;


   function Has_Generated_Atomic_Artifact
     (Directory : String; Base_Name : String) return Boolean
   is
      Search : Ada.Directories.Search_Type;
      Item   : Ada.Directories.Directory_Entry_Type;
      Name   : Unbounded_String;
   begin
      if not Ada.Directories.Exists (Directory) then
         return False;
      end if;

      Ada.Directories.Start_Search
        (Search, Directory, Base_Name & ".sitefetch_*",
         (Ada.Directories.Ordinary_File => True,
          Ada.Directories.Directory => True,
          Ada.Directories.Special_File => True));
      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Item);
         Name := To_Unbounded_String (Ada.Directories.Simple_Name (Item));
         if Ada.Strings.Fixed.Index (To_String (Name), Base_Name & ".sitefetch_tmp.sitefetch_") = 1
           or else Ada.Strings.Fixed.Index (To_String (Name), Base_Name & ".sitefetch_old.sitefetch_") = 1
           or else Ada.Strings.Fixed.Index (To_String (Name), Base_Name & ".sitefetch_download.sitefetch_") = 1
         then
            Ada.Directories.End_Search (Search);
            return True;
         end if;
      end loop;
      Ada.Directories.End_Search (Search);
      return False;
   exception
      when others =>
         if Ada.Directories.More_Entries (Search) then
            Ada.Directories.End_Search (Search);
         end if;
         return False;
   end Has_Generated_Atomic_Artifact;

   procedure Write_Test_File (Path : String; Content : String) is
      File      : Ada.Text_IO.File_Type;
      Directory : constant String := Containing_Test_Path (Path);
   begin
      if Directory /= "." then
         Ada.Directories.Create_Path (Directory);
      end if;

      Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Path);
      Ada.Text_IO.Put (File, Content);
      Ada.Text_IO.Close (File);
   end Write_Test_File;

   procedure Write_Binary_Test_File (Path : String; Content : String) is
      use Ada.Streams;

      File      : Ada.Streams.Stream_IO.File_Type;
      Directory : constant String := Containing_Test_Path (Path);
      Data      : Stream_Element_Array (1 .. Stream_Element_Offset (Content'Length));
   begin
      if Directory /= "." then
         Ada.Directories.Create_Path (Directory);
      end if;

      for Index in Data'Range loop
         Data (Index) :=
           Stream_Element (Character'Pos (Content (Content'First + Natural (Index - Data'First))));
      end loop;

      Ada.Streams.Stream_IO.Create (File, Ada.Streams.Stream_IO.Out_File, Path);
      Ada.Streams.Stream_IO.Write (File, Data);
      Ada.Streams.Stream_IO.Close (File);
   end Write_Binary_Test_File;

   type Progress_Event_Counts is array (Sitefetch.Progress_Event) of Natural;

   protected Parallel_Progress is
      procedure Reset;
      procedure Capture (Event : Sitefetch.Progress_Event);
      function Count (Event : Sitefetch.Progress_Event) return Natural;
   private
      Counts : Progress_Event_Counts := (others => 0);
   end Parallel_Progress;

   protected body Parallel_Progress is
      procedure Reset is
      begin
         Counts := (others => 0);
      end Reset;

      procedure Capture (Event : Sitefetch.Progress_Event) is
      begin
         Counts (Event) := Counts (Event) + 1;
      end Capture;

      function Count (Event : Sitefetch.Progress_Event) return Natural is
      begin
         return Counts (Event);
      end Count;
   end Parallel_Progress;

   procedure Record_Parallel_Progress (Event : Sitefetch.Progress_Event; URL : String) is
      pragma Unreferenced (URL);
   begin
      Parallel_Progress.Capture (Event);
   end Record_Parallel_Progress;

   procedure Record_Structured_Progress (Progress : Sitefetch.Progress_Record) is
   begin
      Structured_Progress_Count := Structured_Progress_Count + 1;
      Last_Structured_Event := Progress.Event;
      Last_Structured_URL := Progress.URL;
      Last_Structured_Reason := Progress.Reason;
      if Progress.Event = Sitefetch.Progress_Written then
         Last_Structured_Written_URL := Progress.URL;
         Last_Structured_Written_Bytes := Progress.Bytes_Written;
         Last_Structured_Written_Depth := Progress.Depth;
         Last_Structured_Written_Status := Progress.Status_Code;
         Last_Structured_Written_Local_Path := Progress.Local_Path;
         Last_Structured_Written_Final_URL := Progress.Final_URL;
         Last_Structured_Written_Source_ID := Progress.Source_ID;
      elsif Progress.Event = Sitefetch.Progress_Failed then
         Last_Structured_Failed_Local_Path := Progress.Local_Path;
         Last_Structured_Failed_Final_URL := Progress.Final_URL;
         Last_Structured_Failed_Source_ID := Progress.Source_ID;
         Last_Structured_Failed_Status := Progress.Status_Code;
      elsif Progress.Event = Sitefetch.Progress_Retry then
         Last_Structured_Retry_URL := Progress.URL;
         Last_Structured_Retry_Final_URL := Progress.Final_URL;
         Last_Structured_Retry_Source_ID := Progress.Source_ID;
         Last_Structured_Retry_Attempt := Progress.Retry_Attempt;
         Last_Structured_Retry_Status := Progress.Status_Code;
      elsif Progress.Event = Sitefetch.Progress_Cache_Reused
        or else Progress.Event = Sitefetch.Progress_Cache_Revalidate
      then
         if Progress.Event = Sitefetch.Progress_Cache_Revalidate
           or else Length (Last_Structured_Cache_Decision) = 0
         then
            Last_Structured_Cache_URL := Progress.URL;
            Last_Structured_Cache_Decision := Progress.Cache_Decision;
            Last_Structured_Cache_Local_Path := Progress.Local_Path;
         end if;
      elsif Progress.Event = Sitefetch.Progress_Robots_Loaded
        or else Progress.Event = Sitefetch.Progress_Robots_Failed
        or else Progress.Event = Sitefetch.Progress_Robots_Allowed
        or else Progress.Event = Sitefetch.Progress_Robots_Disallowed
      then
         Last_Structured_Robots_URL := Progress.URL;
         Last_Structured_Robots_Source := Progress.Robots_Source;
      elsif Progress.Event = Sitefetch.Progress_Redirected then
         Last_Structured_Final_URL := Progress.Final_URL;
         Last_Structured_Source_ID := Progress.Source_ID;
         Last_Structured_Redirect_Hops := Progress.Redirect_Hops;
         Last_Structured_Redirect_Chain := Progress.Redirect_Chain;
         Last_Structured_Redirect_Status_Codes := Progress.Redirect_Status_Codes;
         Last_Structured_Redirect_Target_URLs := Progress.Redirect_Target_URLs;
         Last_Structured_Redirect_Locations := Progress.Redirect_Locations;
         Last_Structured_Redirect_Status := Progress.Status_Code;
      end if;
   end Record_Structured_Progress;

   function Contains_Fragment (Text : String; Fragment : String) return Boolean is
   begin
      if Fragment'Length = 0 then
         return True;
      elsif Text'Length < Fragment'Length then
         return False;
      end if;

      for Index_Value in Text'First .. Text'Last - Fragment'Length + 1 loop
         if Text (Index_Value .. Index_Value + Fragment'Length - 1) = Fragment then
            return True;
         end if;
      end loop;

      return False;
   end Contains_Fragment;

   overriding function Name (Item : Production_HTTP_Fixture_Test) return AUnit.Message_String is
      pragma Unreferenced (Item);
   begin
      return AUnit.Format ("Production HTTP fixture crawl");
   end Name;


   Fixture_Binary_Body   : constant String := "BINARY-NOEXT";
   Fixture_Redirect_Body : constant String := "REDIRECT-BINARY";
   Fixture_Fallback_Body : constant String := "HEAD-FALLBACK";
   Fixture_Mismatch_Body : constant String := "MISMATCH-BINARY";
   Fixture_SVG_Body      : constant String := "<svg><a href=""/svg-linked"">next</a></svg>";
   Fixture_Font_Body     : constant String := "FONT-NOEXT";
   Fixture_PDF_Body      : constant String := "PDF-NOEXT";
   Fixture_Missing_Body  : constant String := "<a href=""/missing-child"">child</a>";
   Fixture_Reset_Body    : constant String := "RESET-PARTIAL";
   Fixture_Truncated_Body : constant String := "TRUNCATED-PARTIAL";
   Fixture_Write_Fail_Body : constant String := "WRITE-FAIL-BODY";
   Fixture_Flaky_Body   : constant String := "FLAKY-OK";
   Fixture_Cache_Body   : constant String := "CACHE-BINARY";
   Fixture_Text_Lie_Body : constant String := "<a href=""/text-lie-child"">child</a>";
   Fixture_Resume_Body  : constant String := "RESUME-RANGE-BODY";
   Fixture_Changed_Resume_Body : constant String := "CHANGED-RANGE-BODY";
   Fixture_Short_Resume_Body   : constant String := "SHORT-RANGE-BODY";

   function Trimmed_Image (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   protected type Fixture_Control is
      entry Wait_Ready (Port : out GNAT.Sockets.Port_Type);
      procedure Set_Port (Port : GNAT.Sockets.Port_Type);
      procedure Set_Peer_Port (Port : GNAT.Sockets.Port_Type);
      function Peer_URL return String;
      procedure Stop;
      function Stopped return Boolean;
      procedure Count (Method : String; Path : String);
      function Request_Count (Method : String; Path : String) return Natural;
      function Delay_Child_Count return Natural;
      function Delay_Child_Gap_MS (Index : Positive) return Natural;
      procedure Set_Robots_Fail (Value : Boolean);
      function Robots_Should_Fail return Boolean;
   private
      Ready       : Boolean := False;
      Stop_Flag   : Boolean := False;
      Listen_Port : GNAT.Sockets.Port_Type := 0;
      Peer_Port   : GNAT.Sockets.Port_Type := 0;
      Head_Root   : Natural := 0;
      Get_Root    : Natural := 0;
      Head_Robots : Natural := 0;
      Get_Robots  : Natural := 0;
      Head_Binary : Natural := 0;
      Get_Binary  : Natural := 0;
      Head_Redirect : Natural := 0;
      Get_Redirect  : Natural := 0;
      Head_Final    : Natural := 0;
      Get_Final     : Natural := 0;
      Head_405      : Natural := 0;
      Get_405       : Natural := 0;
      Head_Mismatch : Natural := 0;
      Get_Mismatch  : Natural := 0;
      Head_Big      : Natural := 0;
      Get_Big       : Natural := 0;
      Head_Flaky    : Natural := 0;
      Get_Flaky     : Natural := 0;
      Head_Status_Transient : Natural := 0;
      Get_Status_Transient  : Natural := 0;
      Head_Status_Permanent : Natural := 0;
      Get_Status_Permanent  : Natural := 0;
      Head_Structured_Status : Natural := 0;
      Get_Structured_Status  : Natural := 0;
      Head_Resume   : Natural := 0;
      Get_Resume    : Natural := 0;
      Head_Cross_Loop_B : Natural := 0;
      Get_Cross_Loop_B  : Natural := 0;
      Delay_Children : Natural := 0;
      Delay_Child_1  : Ada.Calendar.Time := Ada.Calendar.Time_Of (1901, 1, 1);
      Delay_Child_2  : Ada.Calendar.Time := Ada.Calendar.Time_Of (1901, 1, 1);
      Delay_Child_3  : Ada.Calendar.Time := Ada.Calendar.Time_Of (1901, 1, 1);
      Robots_Fail   : Boolean := False;
   end Fixture_Control;

   protected body Fixture_Control is
      entry Wait_Ready (Port : out GNAT.Sockets.Port_Type) when Ready is
      begin
         Port := Listen_Port;
      end Wait_Ready;

      procedure Set_Port (Port : GNAT.Sockets.Port_Type) is
      begin
         Listen_Port := Port;
         Ready := True;
      end Set_Port;

      procedure Set_Peer_Port (Port : GNAT.Sockets.Port_Type) is
      begin
         Peer_Port := Port;
      end Set_Peer_Port;

      function Peer_URL return String is
      begin
         return "http://127.0.0.1:" & Trimmed_Image (Natural (Peer_Port));
      end Peer_URL;

      procedure Stop is
      begin
         Stop_Flag := True;
      end Stop;

      function Stopped return Boolean is
      begin
         return Stop_Flag;
      end Stopped;

      procedure Count (Method : String; Path : String) is
      begin
         if Method = "HEAD" and then Path = "/" then
            Head_Root := Head_Root + 1;
         elsif Method = "GET" and then Path = "/" then
            Get_Root := Get_Root + 1;
         elsif Method = "HEAD" and then Path = "/robots.txt" then
            Head_Robots := Head_Robots + 1;
         elsif Method = "GET" and then Path = "/robots.txt" then
            Get_Robots := Get_Robots + 1;
         elsif Method = "HEAD" and then Path = "/binary" then
            Head_Binary := Head_Binary + 1;
         elsif Method = "GET" and then Path = "/binary" then
            Get_Binary := Get_Binary + 1;
         elsif Method = "HEAD" and then Path = "/redirect-bin" then
            Head_Redirect := Head_Redirect + 1;
         elsif Method = "GET" and then Path = "/redirect-bin" then
            Get_Redirect := Get_Redirect + 1;
         elsif Method = "HEAD" and then Path = "/final.bin" then
            Head_Final := Head_Final + 1;
         elsif Method = "GET" and then Path = "/final.bin" then
            Get_Final := Get_Final + 1;
         elsif Method = "HEAD" and then Path = "/head-405" then
            Head_405 := Head_405 + 1;
         elsif Method = "GET" and then Path = "/head-405" then
            Get_405 := Get_405 + 1;
         elsif Method = "HEAD" and then Path = "/mismatch" then
            Head_Mismatch := Head_Mismatch + 1;
         elsif Method = "GET" and then Path = "/mismatch" then
            Get_Mismatch := Get_Mismatch + 1;
         elsif Method = "HEAD" and then Path = "/big" then
            Head_Big := Head_Big + 1;
         elsif Method = "GET" and then Path = "/big" then
            Get_Big := Get_Big + 1;
         elsif Method = "HEAD" and then Path = "/flaky.bin" then
            Head_Flaky := Head_Flaky + 1;
         elsif Method = "GET" and then Path = "/flaky.bin" then
            Get_Flaky := Get_Flaky + 1;
         elsif Method = "HEAD" and then Path = "/status-transient.bin" then
            Head_Status_Transient := Head_Status_Transient + 1;
         elsif Method = "GET" and then Path = "/status-transient.bin" then
            Get_Status_Transient := Get_Status_Transient + 1;
         elsif Method = "HEAD" and then Path = "/status-permanent.bin" then
            Head_Status_Permanent := Head_Status_Permanent + 1;
         elsif Method = "GET" and then Path = "/status-permanent.bin" then
            Get_Status_Permanent := Get_Status_Permanent + 1;
         elsif Method = "HEAD" and then Path = "/structured-status-transient.bin" then
            Head_Structured_Status := Head_Structured_Status + 1;
         elsif Method = "GET" and then Path = "/structured-status-transient.bin" then
            Get_Structured_Status := Get_Structured_Status + 1;
         elsif Method = "HEAD" and then Path = "/resume.bin" then
            Head_Resume := Head_Resume + 1;
         elsif Method = "GET" and then Path = "/resume.bin" then
            Get_Resume := Get_Resume + 1;
         elsif Method = "HEAD" and then Path = "/cross-loop-b.bin" then
            Head_Cross_Loop_B := Head_Cross_Loop_B + 1;
         elsif Method = "GET" and then Path = "/cross-loop-b.bin" then
            Get_Cross_Loop_B := Get_Cross_Loop_B + 1;
         elsif Method = "GET"
           and then Path in "/delay-child-1.html" | "/delay-child-2.html" | "/delay-child-3.html"
         then
            Delay_Children := Delay_Children + 1;
            if Delay_Children = 1 then
               Delay_Child_1 := Ada.Calendar.Clock;
            elsif Delay_Children = 2 then
               Delay_Child_2 := Ada.Calendar.Clock;
            elsif Delay_Children = 3 then
               Delay_Child_3 := Ada.Calendar.Clock;
            end if;
         end if;
      end Count;

      procedure Set_Robots_Fail (Value : Boolean) is
      begin
         Robots_Fail := Value;
      end Set_Robots_Fail;

      function Robots_Should_Fail return Boolean is
      begin
         return Robots_Fail;
      end Robots_Should_Fail;

      function Request_Count (Method : String; Path : String) return Natural is
      begin
         if Method = "HEAD" and then Path = "/" then
            return Head_Root;
         elsif Method = "GET" and then Path = "/" then
            return Get_Root;
         elsif Method = "HEAD" and then Path = "/robots.txt" then
            return Head_Robots;
         elsif Method = "GET" and then Path = "/robots.txt" then
            return Get_Robots;
         elsif Method = "HEAD" and then Path = "/binary" then
            return Head_Binary;
         elsif Method = "GET" and then Path = "/binary" then
            return Get_Binary;
         elsif Method = "HEAD" and then Path = "/redirect-bin" then
            return Head_Redirect;
         elsif Method = "GET" and then Path = "/redirect-bin" then
            return Get_Redirect;
         elsif Method = "HEAD" and then Path = "/final.bin" then
            return Head_Final;
         elsif Method = "GET" and then Path = "/final.bin" then
            return Get_Final;
         elsif Method = "HEAD" and then Path = "/head-405" then
            return Head_405;
         elsif Method = "GET" and then Path = "/head-405" then
            return Get_405;
         elsif Method = "HEAD" and then Path = "/mismatch" then
            return Head_Mismatch;
         elsif Method = "GET" and then Path = "/mismatch" then
            return Get_Mismatch;
         elsif Method = "HEAD" and then Path = "/big" then
            return Head_Big;
         elsif Method = "GET" and then Path = "/big" then
            return Get_Big;
         elsif Method = "HEAD" and then Path = "/flaky.bin" then
            return Head_Flaky;
         elsif Method = "GET" and then Path = "/flaky.bin" then
            return Get_Flaky;
         elsif Method = "HEAD" and then Path = "/status-transient.bin" then
            return Head_Status_Transient;
         elsif Method = "GET" and then Path = "/status-transient.bin" then
            return Get_Status_Transient;
         elsif Method = "HEAD" and then Path = "/status-permanent.bin" then
            return Head_Status_Permanent;
         elsif Method = "GET" and then Path = "/status-permanent.bin" then
            return Get_Status_Permanent;
         elsif Method = "HEAD" and then Path = "/structured-status-transient.bin" then
            return Head_Structured_Status;
         elsif Method = "GET" and then Path = "/structured-status-transient.bin" then
            return Get_Structured_Status;
         elsif Method = "HEAD" and then Path = "/resume.bin" then
            return Head_Resume;
         elsif Method = "GET" and then Path = "/resume.bin" then
            return Get_Resume;
         elsif Method = "HEAD" and then Path = "/cross-loop-b.bin" then
            return Head_Cross_Loop_B;
         elsif Method = "GET" and then Path = "/cross-loop-b.bin" then
            return Get_Cross_Loop_B;
         else
            return 0;
         end if;
      end Request_Count;

      function Delay_Child_Count return Natural is
      begin
         return Delay_Children;
      end Delay_Child_Count;

      function Delay_Child_Gap_MS (Index : Positive) return Natural is
         Gap : Duration := 0.0;
      begin
         if Index = 1 and then Delay_Children >= 2 then
            Gap := Delay_Child_2 - Delay_Child_1;
         elsif Index = 2 and then Delay_Children >= 3 then
            Gap := Delay_Child_3 - Delay_Child_2;
         end if;

         if Gap <= 0.0 then
            return 0;
         else
            return Natural (Long_Float (Gap) * 1000.0);
         end if;
      end Delay_Child_Gap_MS;
   end Fixture_Control;

   task type Fixture_Server (Control : not null access Fixture_Control);

   task body Fixture_Server is
      use type Ada.Streams.Stream_Element_Offset;
      use type GNAT.Sockets.Selector_Status;

      CRLF : constant String := Character'Val (13) & Character'Val (10);
      Root_Body : constant String :=
        "<a href=""/binary"">binary</a><a href=""/redirect-bin"">redirect</a>"
        & "<a href=""/head-405"">fallback</a><a href=""/mismatch"">mismatch</a>"
        & "<a href=""/icon.svg"">svg</a><a href=""/fontfile"">font</a>"
        & "<a href=""/pdf-doc"">pdf</a><a href=""/missing-type"">missing</a>";
      Robots_Root_Body : constant String :=
        "<a href=""/robots-allowed.html"">allowed</a>"
        & "<a href=""/robots-blocked.html"">blocked</a>"
        & "<a href=""/robots-private/allowed.html"">allowed private</a>"
        & "<a href=""/robots-private/blocked.html"">blocked private</a>"
        & "<a href=""/robots-wild/blocked.tmp"">wild blocked</a>"
        & "<a href=""/robots-wild/allowed.txt"">wild allowed</a>"
        & "<a href=""/robots-anchor/exact"">anchor blocked</a>"
        & "<a href=""/robots-anchor/exactly"">anchor allowed</a>";
      Redirected_Robots_Root_Body : constant String :=
        "<a href=""/robots-allowed.html"">allowed</a>"
        & "<a href=""/robots-blocked.html"">blocked</a>";
      Robots_Body : constant String :=
        "User-agent: other" & Character'Val (10)
        & "Disallow: /" & Character'Val (10)
        & Character'Val (10)
        & "User-agent: sitefetch-test" & Character'Val (10)
        & "Disallow: /robots-blocked.html" & Character'Val (10)
        & "Disallow: /robots-private" & Character'Val (10)
        & "Allow: /robots-private/allowed.html" & Character'Val (10)
        & "Disallow: /robots-wild/*.tmp" & Character'Val (10)
        & "Disallow: /robots-anchor/exact$" & Character'Val (10)
        & "Crawl-delay: 0" & Character'Val (10)
        & "Sitemap: /robots-sitemap.xml" & Character'Val (10)
        & Character'Val (10)
        & "User-agent: *" & Character'Val (10)
        & "Disallow: /robots-allowed.html" & Character'Val (10);
      Cache_Root_Body : constant String := "<a href=""/cache-child.html"">child</a>";
      Delay_Root_Body : constant String :=
        "<a href=""/delay-child-1.html"">one</a>"
        & "<a href=""/delay-child-2.html"">two</a>"
        & "<a href=""/delay-child-3.html"">three</a>";
      Malformed_CSS_Body : constant String :=
        ".bad{background:url('/malformed-css-a.png'}"
        & ".next{background:url(""/malformed-css-b.png"")}"
        & "/* url(/ignored-malformed-css.png) */";
      Malformed_Sitemap_Body : constant String :=
        "<?xml version=""1.0""?><urlset>"
        & "<url><loc>/malformed-sitemap-before.html</loc>"
        & "<!-- <loc>/ignored-malformed-sitemap.html</loc> -->"
        & "<url><loc>/malformed-sitemap-after.html</loc></url>"
        & "<url><loc>/malformed-sitemap-unclosed.html";
      Binary_Body   : String renames Fixture_Binary_Body;
      Redirect_Body : String renames Fixture_Redirect_Body;
      Fallback_Body : String renames Fixture_Fallback_Body;
      Mismatch_Body : String renames Fixture_Mismatch_Body;
      SVG_Body      : String renames Fixture_SVG_Body;
      Font_Body     : String renames Fixture_Font_Body;
      PDF_Body      : String renames Fixture_PDF_Body;
      Missing_Body  : String renames Fixture_Missing_Body;
      Big_Body      : constant String := "0123456789AB";
      Resume_Body   : String renames Fixture_Resume_Body;
      Changed_Resume_Body : String renames Fixture_Changed_Resume_Body;
      Short_Resume_Body   : String renames Fixture_Short_Resume_Body;
      Server        : GNAT.Sockets.Socket_Type;
      Client        : GNAT.Sockets.Socket_Type;
      Address       : GNAT.Sockets.Sock_Addr_Type;
      Peer          : GNAT.Sockets.Sock_Addr_Type;
      Status        : GNAT.Sockets.Selector_Status;
      Idle_Count    : Natural := 0;

      function Trimmed_Image (Value : Natural) return String is
        (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

      function Request_Text (Socket : GNAT.Sockets.Socket_Type) return String is
         Buffer : Ada.Streams.Stream_Element_Array (1 .. 4096);
         Last   : Ada.Streams.Stream_Element_Offset;
         Result : Unbounded_String := Null_Unbounded_String;
      begin
         GNAT.Sockets.Receive_Socket (Socket, Buffer, Last);
         for Index in Buffer'First .. Last loop
            Append (Result, Character'Val (Integer (Buffer (Index))));
         end loop;
         return To_String (Result);
      end Request_Text;

      function Request_Method (Request : String) return String is
      begin
         for Index in Request'Range loop
            if Request (Index) = ' ' then
               return Request (Request'First .. Index - 1);
            end if;
         end loop;
         return "";
      end Request_Method;

      function Request_Path (Request : String) return String is
         First_Space  : Natural := 0;
         Second_Space : Natural := 0;
      begin
         for Index in Request'Range loop
            if Request (Index) = ' ' then
               if First_Space = 0 then
                  First_Space := Index;
               else
                  Second_Space := Index;
                  exit;
               end if;
            end if;
         end loop;

         if First_Space = 0 or else Second_Space <= First_Space + 1 then
            return "";
         else
            return Request (First_Space + 1 .. Second_Space - 1);
         end if;
      end Request_Path;

      procedure Send_Text (Socket : GNAT.Sockets.Socket_Type; Text : String) is
         Data : Ada.Streams.Stream_Element_Array
           (1 .. Ada.Streams.Stream_Element_Offset (Text'Length));
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         for Index in Text'Range loop
            Data (Ada.Streams.Stream_Element_Offset (Index - Text'First + 1)) :=
              Ada.Streams.Stream_Element (Character'Pos (Text (Index)));
         end loop;
         GNAT.Sockets.Send_Socket (Socket, Data, Last);
      end Send_Text;

      procedure Respond
        (Socket       : GNAT.Sockets.Socket_Type;
         Method       : String;
         Status_Line  : String;
         Content_Type : String;
         Body_Text    : String;
         Extra        : String := "")
      is
         Headers : Unbounded_String := To_Unbounded_String
           (Status_Line & CRLF
            & "Content-Length: " & Trimmed_Image (Body_Text'Length) & CRLF
            & "Connection: close" & CRLF);
      begin
         if Content_Type /= "" then
            Append (Headers, "Content-Type: " & Content_Type & CRLF);
         end if;
         if Extra /= "" then
            Append (Headers, Extra);
         end if;
         Append (Headers, CRLF);
         if Method /= "HEAD" then
            Append (Headers, Body_Text);
         end if;
         Send_Text (Socket, To_String (Headers));
      end Respond;

      function To_Zlib_Bytes (Text : String) return Zlib.Byte_Array is
         Result : Zlib.Byte_Array (0 .. Text'Length - 1);
      begin
         for Offset in Result'Range loop
            Result (Offset) := Zlib.Byte (Character'Pos (Text (Text'First + Offset)));
         end loop;
         return Result;
      end To_Zlib_Bytes;

      function To_Binary_String (Bytes : Zlib.Byte_Array) return String is
         Result : String (1 .. Bytes'Length);
         Index  : Positive := Result'First;
      begin
         for Item of Bytes loop
            Result (Index) := Character'Val (Natural (Item));
            Index := Index + 1;
         end loop;
         return Result;
      end To_Binary_String;

      function GZip_Text (Text : String) return String is
         Status : Zlib.Status_Code;
         Bytes  : constant Zlib.Byte_Array := Zlib.GZip (To_Zlib_Bytes (Text), Zlib.Stored, Status);
      begin
         Assert (Status = Zlib.Ok, "gzip fixture generation succeeds");
         return To_Binary_String (Bytes);
      end GZip_Text;

      procedure Respond_Short_Body
        (Socket          : GNAT.Sockets.Socket_Type;
         Method          : String;
         Body_Text       : String;
         Declared_Length : Natural)
      is
         Response : Unbounded_String := To_Unbounded_String
           ("HTTP/1.1 200 OK" & CRLF
            & "Content-Type: application/octet-stream" & CRLF
            & "Content-Length: " & Trimmed_Image (Declared_Length) & CRLF
            & "Connection: close" & CRLF & CRLF);
      begin
         if Method /= "HEAD" then
            Append (Response, Body_Text);
         end if;
         Send_Text (Socket, To_String (Response));
      end Respond_Short_Body;

      procedure Respond_Broken_Chunk
        (Socket    : GNAT.Sockets.Socket_Type;
         Method    : String;
         Body_Text : String)
      is
         Response : Unbounded_String := To_Unbounded_String
           ("HTTP/1.1 200 OK" & CRLF
            & "Content-Type: application/octet-stream" & CRLF
            & "Transfer-Encoding: chunked" & CRLF
            & "Connection: close" & CRLF & CRLF);
      begin
         if Method /= "HEAD" then
            Append (Response, "20" & CRLF & Body_Text);
         end if;
         Send_Text (Socket, To_String (Response));
      end Respond_Broken_Chunk;

      procedure Respond_Broken_Chunk_With_Extra
        (Socket    : GNAT.Sockets.Socket_Type;
         Method    : String;
         Body_Text : String;
         Extra     : String)
      is
         Response : Unbounded_String := To_Unbounded_String
           ("HTTP/1.1 200 OK" & CRLF
            & "Content-Type: application/octet-stream" & CRLF
            & "Transfer-Encoding: chunked" & CRLF
            & Extra
            & "Connection: close" & CRLF & CRLF);
      begin
         if Method /= "HEAD" then
            Append (Response, "20" & CRLF & Body_Text);
         end if;
         Send_Text (Socket, To_String (Response));
      end Respond_Broken_Chunk_With_Extra;

      procedure Respond_Range
        (Socket    : GNAT.Sockets.Socket_Type;
         Method    : String;
         Body_Text : String;
         Request   : String)
      is
         Range_Pos : constant Natural := Ada.Strings.Fixed.Index (Request, "Range: bytes=");
         Start_Pos : Natural := 0;
         End_Pos   : Natural := 0;
         Start     : Natural := 0;
      begin
         if Range_Pos > 0 then
            Start_Pos := Range_Pos + 13;
            End_Pos := Start_Pos;
            while End_Pos <= Request'Last and then Request (End_Pos) in '0' .. '9' loop
               End_Pos := End_Pos + 1;
            end loop;
            if End_Pos > Start_Pos then
               Start := Natural'Value (Request (Start_Pos .. End_Pos - 1));
            end if;
         end if;

         if Range_Pos > 0 and then Start < Body_Text'Length then
            declare
               Chunk : constant String := Body_Text (Body_Text'First + Start .. Body_Text'Last);
               Last_Byte : constant Natural := Body_Text'Length - 1;
            begin
               declare
                  Response : Unbounded_String := To_Unbounded_String
                    ("HTTP/1.1 206 Partial Content" & CRLF
                     & "Content-Range: bytes " & Trimmed_Image (Start) & "-"
                     & Trimmed_Image (Last_Byte) & "/" & Trimmed_Image (Body_Text'Length)
                     & CRLF & CRLF);
               begin
                  if Method /= "HEAD" then
                     Append (Response, Chunk);
                  end if;
                  Send_Text (Socket, To_String (Response));
               end;
            end;
         else
            Respond
              (Socket,
               Method,
               "HTTP/1.1 200 OK",
               "application/octet-stream",
               Body_Text,
               "ETag: resume-v1" & CRLF);
         end if;
      end Respond_Range;

      procedure Respond_Range_Or_416
        (Socket    : GNAT.Sockets.Socket_Type;
         Method    : String;
         Body_Text : String;
         Request   : String)
      is
         Range_Pos : constant Natural := Ada.Strings.Fixed.Index (Request, "Range: bytes=");
         Start_Pos : Natural := 0;
         End_Pos   : Natural := 0;
         Start     : Natural := 0;
      begin
         if Range_Pos > 0 then
            Start_Pos := Range_Pos + 13;
            End_Pos := Start_Pos;
            while End_Pos <= Request'Last and then Request (End_Pos) in '0' .. '9' loop
               End_Pos := End_Pos + 1;
            end loop;
            if End_Pos > Start_Pos then
               Start := Natural'Value (Request (Start_Pos .. End_Pos - 1));
            end if;
         end if;

         if Range_Pos > 0 and then Start >= Body_Text'Length then
            Respond
              (Socket, Method, "HTTP/1.1 416 Range Not Satisfiable", "", "",
               "Content-Range: bytes */" & Trimmed_Image (Body_Text'Length) & CRLF);
         else
            Respond_Range (Socket, Method, Body_Text, Request);
         end if;
      end Respond_Range_Or_416;

      procedure Respond_If_Range_Changed
        (Socket    : GNAT.Sockets.Socket_Type;
         Method    : String;
         Body_Text : String;
         Request   : String)
      is
      begin
         if Ada.Strings.Fixed.Index (Request, "Range: bytes=") > 0
           and then Ada.Strings.Fixed.Index (Request, "If-Range: old-resume-v1") > 0
         then
            Respond
              (Socket, Method, "HTTP/1.1 200 OK", "application/octet-stream", Body_Text,
               "ETag: changed-resume-v2" & CRLF);
         else
            Respond_Range (Socket, Method, Body_Text, Request);
         end if;
      end Respond_If_Range_Changed;


      procedure Handle (Socket : GNAT.Sockets.Socket_Type) is
         Request : constant String := Request_Text (Socket);
         Method  : constant String := Request_Method (Request);
         Path    : constant String := Request_Path (Request);
      begin
         Control.Count (Method, Path);
         if Path = "/" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "text/html", Root_Body);
         elsif Path = "/robots.txt" and then Control.Robots_Should_Fail then
            Respond (Socket, Method, "HTTP/1.1 503 Service Unavailable", "text/plain", "robots unavailable");
         elsif Path = "/robots.txt" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "text/plain", Robots_Body);
         elsif Path = "/robots-root.html" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "text/html", Robots_Root_Body);
         elsif Path = "/redirect-to-peer-robots.html" then
            Respond
              (Socket, Method, "HTTP/1.1 302 Found", "", "",
               "Location: " & Control.Peer_URL & "/redirected-robots-root.html" & CRLF);
         elsif Path = "/redirected-robots-root.html" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "text/html", Redirected_Robots_Root_Body);
         elsif Path = "/robots-allowed.html" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "text/html", "allowed");
         elsif Path = "/robots-blocked.html" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "text/html", "blocked");
         elsif Path = "/robots-private/allowed.html" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "text/html", "allowed private");
         elsif Path = "/robots-private/blocked.html" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "text/html", "blocked private");
         elsif Path = "/robots-wild/blocked.tmp" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "text/html", "wild blocked");
         elsif Path = "/robots-wild/allowed.txt" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "text/html", "wild allowed");
         elsif Path = "/robots-anchor/exact" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "text/html", "anchor blocked");
         elsif Path = "/robots-anchor/exactly" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "text/html", "anchor allowed");
         elsif Path = "/robots-sitemap.xml" then
            Respond
              (Socket,
               Method,
               "HTTP/1.1 200 OK",
               "application/xml",
               "<?xml version=""1.0""?><urlset>"
               & "<url><loc>/robots-sitemap-child.html</loc></url>"
               & "<url><loc>/robots-sitemap-level-2.xml</loc></url>"
               & "<url><loc>/robots-sitemap-compressed.xml.gz</loc></url>"
               & "</urlset>");
         elsif Path = "/robots-sitemap-compressed.xml.gz" then
            Respond
              (Socket, Method, "HTTP/1.1 200 OK", "application/gzip",
               GZip_Text
                 ("<?xml version=""1.0""?><urlset>"
                  & "<url><loc>/robots-sitemap-gzip-child.html</loc></url>"
                  & "</urlset>"));
         elsif Path = "/robots-sitemap-gzip-child.html" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "text/html", "gzip sitemap child");
         elsif Path = "/robots-sitemap-level-2.xml" then
            Respond
              (Socket,
               Method,
               "HTTP/1.1 200 OK",
               "application/xml",
               "<?xml version=""1.0""?><urlset>"
               & "<url><loc>/robots-sitemap-depth-page.html</loc></url>"
               & "<url><loc>/robots-sitemap-level-3.xml</loc></url>"
               & "</urlset>");
         elsif Path = "/robots-sitemap-level-3.xml" then
            Respond
              (Socket, Method, "HTTP/1.1 200 OK", "application/xml",
               "<?xml version=""1.0""?><urlset><url><loc>/robots-sitemap-too-deep.html</loc></url></urlset>");
         elsif Path = "/robots-sitemap-depth-page.html" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "text/html", "sitemap depth page");
         elsif Path = "/robots-sitemap-too-deep.html" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "text/html", "too deep");
         elsif Path = "/robots-sitemap-child.html" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "text/html", "sitemap child");
         elsif Path = "/cache-root.html"
           and then Ada.Strings.Fixed.Index (Request, "If-None-Match: cache-root-v1") > 0
         then
            Respond (Socket, Method, "HTTP/1.1 304 Not Modified", "", "", "ETag: cache-root-v1" & CRLF);
         elsif Path = "/cache-root.html" then
            Respond
              (Socket, Method, "HTTP/1.1 200 OK", "text/html", Cache_Root_Body,
               "ETag: cache-root-v1" & CRLF
               & "Cache-Control: max-age=60" & CRLF
               & "Expires: Wed, 21 Oct 2037 07:28:00 GMT" & CRLF);
         elsif Path = "/cache-child.html" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "text/html", "cache child");
         elsif Path = "/delay-root.html" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "text/html", Delay_Root_Body);
         elsif Path in "/delay-child-1.html" | "/delay-child-2.html" | "/delay-child-3.html" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "text/html", "delay child");
         elsif Path = "/malformed.css" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "text/css", Malformed_CSS_Body);
         elsif Path = "/malformed-css-a.png" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "image/png", "CSS-A");
         elsif Path = "/malformed-css-b.png" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "image/png", "CSS-B");
         elsif Path = "/ignored-malformed-css.png" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "image/png", "CSS-IGNORED");
         elsif Path = "/malformed-sitemap.xml" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "application/xml", Malformed_Sitemap_Body);
         elsif Path = "/malformed-sitemap-before.html" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "text/html", "sitemap before");
         elsif Path = "/malformed-sitemap-after.html" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "text/html", "sitemap after");
         elsif Path = "/malformed-sitemap-unclosed.html" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "text/html", "sitemap unclosed");
         elsif Path = "/ignored-malformed-sitemap.html" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "text/html", "sitemap ignored");
         elsif Path = "/cache-must.html"
           and then Ada.Strings.Fixed.Index (Request, "If-None-Match: cache-must-v1") > 0
         then
            Respond (Socket, Method, "HTTP/1.1 304 Not Modified", "", "", "ETag: cache-must-v1" & CRLF);
         elsif Path = "/cache-must.html" then
            Respond
              (Socket, Method, "HTTP/1.1 200 OK", "text/html", "must cache",
               "ETag: cache-must-v1" & CRLF
               & "Cache-Control: max-age=3600, must-revalidate" & CRLF);
         elsif Path = "/cache-stale-no-validator.html" then
            Respond
              (Socket, Method, "HTTP/1.1 200 OK", "text/html", "stale cache",
               "Cache-Control: max-age=0" & CRLF);
         elsif Path = "/cache-vary-lang.html" then
            Respond
              (Socket, Method, "HTTP/1.1 200 OK", "text/html", "vary lang",
               "ETag: cache-vary-lang-v1" & CRLF
               & "Cache-Control: max-age=3600" & CRLF
               & "Vary: Accept-Language" & CRLF);
         elsif Path = "/cache-vary-combo.html" then
            Respond
              (Socket, Method, "HTTP/1.1 200 OK", "text/html", "vary combo",
               "ETag: cache-vary-combo-v1" & CRLF
               & "Cache-Control: max-age=3600" & CRLF
               & "Vary: Accept-Language, Accept-Encoding" & CRLF);
         elsif Path = "/cache.bin" and then Method = "HEAD"
           and then Ada.Strings.Fixed.Index (Request, "If-None-Match: cache-bin-v1") > 0
         then
            Respond
              (Socket, Method, "HTTP/1.1 304 Not Modified", "", "",
               "ETag: cache-bin-v1" & CRLF);
         elsif Path = "/cache.bin" then
            Respond
              (Socket, Method, "HTTP/1.1 200 OK", "application/octet-stream",
               Fixture_Cache_Body,
               "ETag: cache-bin-v1" & CRLF
               & "Cache-Control: max-age=60" & CRLF
               & "Expires: Wed, 21 Oct 2037 07:28:00 GMT" & CRLF
               & "Vary: User-Agent" & CRLF);
         elsif Path = "/resume.bin" then
            Respond_Range (Socket, Method, Resume_Body, Request);
         elsif Path = "/resume-changed.bin" then
            Respond_If_Range_Changed (Socket, Method, Changed_Resume_Body, Request);
         elsif Path = "/resume-416-complete.bin" then
            Respond_Range_Or_416 (Socket, Method, Resume_Body, Request);
         elsif Path = "/resume-oversized.bin" then
            Respond_Range_Or_416 (Socket, Method, Short_Resume_Body, Request);
         elsif Path = "/binary" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "application/octet-stream", Binary_Body);
         elsif Path = "/redirect-bin" then
            Respond
              (Socket, Method, "HTTP/1.1 302 Found", "", "",
               "Location: /final.bin" & CRLF);
         elsif Path = "/redirect-hop-1" then
            Respond
              (Socket, Method, "HTTP/1.1 302 Found", "", "",
               "Location: /redirect-hop-2" & CRLF);
         elsif Path = "/redirect-hop-2" then
            Respond
              (Socket, Method, "HTTP/1.1 301 Moved Permanently", "", "",
               "Location: /final.bin" & CRLF);
         elsif Path = "/redirect-page-hop-1" then
            Respond
              (Socket, Method, "HTTP/1.1 302 Found", "", "",
               "Location: /redirect-page-hop-2" & CRLF);
         elsif Path = "/redirect-page-hop-2" then
            Respond
              (Socket, Method, "HTTP/1.1 301 Moved Permanently", "", "",
               "Location: /redirect-final.html" & CRLF);
         elsif Path = "/redirect-final.html" then
            Respond
              (Socket, Method, "HTTP/1.1 200 OK", "text/html",
               "<html><body>redirect final</body></html>");
         elsif Path = "/loop-a" then
            Respond
              (Socket, Method, "HTTP/1.1 302 Found", "", "",
               "Location: /loop-b" & CRLF);
         elsif Path = "/loop-b" then
            Respond
              (Socket, Method, "HTTP/1.1 302 Found", "", "",
               "Location: /loop-a" & CRLF);
         elsif Path = "/cross-loop-a.bin" then
            Respond
              (Socket, Method, "HTTP/1.1 302 Found", "", "",
               "Location: " & Control.Peer_URL & "/cross-loop-b.bin" & CRLF);
         elsif Path = "/cross-loop-b.bin" then
            Respond
              (Socket, Method, "HTTP/1.1 302 Found", "", "",
               "Location: " & Control.Peer_URL & "/cross-loop-a.bin" & CRLF);
         elsif Path = "/final.bin" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "application/octet-stream", Redirect_Body);
         elsif Path = "/head-405" and then Method = "HEAD" then
            Respond (Socket, Method, "HTTP/1.1 405 Method Not Allowed", "", "");
         elsif Path = "/head-405" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "image/png", Fallback_Body);
         elsif Path = "/mismatch" and then Method = "HEAD" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "text/html", "");
         elsif Path = "/mismatch" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "application/octet-stream", Mismatch_Body);
         elsif Path = "/text-lie" and then Method = "HEAD" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "application/octet-stream", "");
         elsif Path = "/text-lie" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "text/html", Fixture_Text_Lie_Body);
         elsif Path = "/text-lie-child" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "text/html", "text lie child");
         elsif Path = "/icon.svg" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "image/svg+xml", SVG_Body);
         elsif Path = "/svg-linked" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "text/html", "svg child");
         elsif Path = "/fontfile" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "font/woff2", Font_Body);
         elsif Path = "/pdf-doc" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "application/pdf", PDF_Body);
         elsif Path = "/missing-type" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "", Missing_Body);
         elsif Path = "/missing-child" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "text/html", "missing child");
         elsif Path = "/reset.bin" then
            Respond_Broken_Chunk (Socket, Method, Fixture_Reset_Body);
         elsif Path = "/truncated.bin" then
            Respond_Short_Body (Socket, Method, Fixture_Truncated_Body, Fixture_Truncated_Body'Length + 16);
         elsif Path = "/redirect-to-failure.bin" then
            Respond
              (Socket, Method, "HTTP/1.1 302 Found", "", "",
               "Location: /truncated.bin" & CRLF);
         elsif Path = "/blocked/file.bin" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "application/octet-stream", Fixture_Write_Fail_Body);
         elsif Path = "/partial-strong.bin" then
            Respond_Broken_Chunk_With_Extra
              (Socket, Method, Fixture_Reset_Body, "ETag: partial-strong-v1" & CRLF);
         elsif Path = "/partial-weak.bin" then
            Respond_Broken_Chunk_With_Extra
              (Socket, Method, Fixture_Reset_Body, "ETag: W/""partial-weak-v1""" & CRLF);
         elsif Path = "/flaky.bin" and then Control.Request_Count ("GET", "/flaky.bin") = 1 then
            Respond_Broken_Chunk (Socket, Method, Fixture_Reset_Body);
         elsif Path = "/flaky.bin" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "application/octet-stream", Fixture_Flaky_Body);
         elsif Path = "/status-transient.bin"
           and then Control.Request_Count ("GET", "/status-transient.bin") = 1
         then
            Respond
              (Socket, Method, "HTTP/1.1 503 Service Unavailable",
               "application/octet-stream", "temporary unavailable");
         elsif Path = "/status-transient.bin" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "application/octet-stream", "STATUS-OK");
         elsif Path = "/structured-status-transient.bin"
           and then Control.Request_Count ("GET", "/structured-status-transient.bin") = 1
         then
            Respond
              (Socket, Method, "HTTP/1.1 503 Service Unavailable",
               "application/octet-stream", "temporary unavailable");
         elsif Path = "/structured-status-transient.bin" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "application/octet-stream", "STRUCTURED-OK");
         elsif Path = "/status-permanent.bin" then
            Respond (Socket, Method, "HTTP/1.1 404 Not Found", "application/octet-stream", "missing forever");
         elsif Path = "/big" then
            Respond (Socket, Method, "HTTP/1.1 200 OK", "application/octet-stream", Big_Body);
         else
            Respond (Socket, Method, "HTTP/1.1 404 Not Found", "text/plain", "missing");
         end if;
      end Handle;
   begin
      GNAT.Sockets.Initialize;
      GNAT.Sockets.Create_Socket (Server);
      Address.Addr := GNAT.Sockets.Inet_Addr ("127.0.0.1");
      Address.Port := 0;
      GNAT.Sockets.Bind_Socket (Server, Address);
      GNAT.Sockets.Listen_Socket (Server);
      Control.Set_Port (GNAT.Sockets.Get_Socket_Name (Server).Port);

      loop
         exit when Control.Stopped;
         GNAT.Sockets.Accept_Socket (Server, Client, Peer, 0.20, Status => Status);
         if Status = GNAT.Sockets.Completed then
            Idle_Count := 0;
            begin
               Handle (Client);
            exception
               when others =>
                  null;
            end;
            GNAT.Sockets.Close_Socket (Client);
         else
            Idle_Count := Idle_Count + 1;
            exit when Idle_Count > 25;
         end if;
      end loop;

      GNAT.Sockets.Close_Socket (Server);
   exception
      when others =>
         Control.Stop;
   end Fixture_Server;

   overriding procedure Run_Test (Item : in out Production_HTTP_Fixture_Test) is
      pragma Unreferenced (Item);
      Target     : constant String := "test-output-production-http";
      Malformed_CSS_Target : constant String := "test-output-production-malformed-css";
      Malformed_Sitemap_Target : constant String := "test-output-production-malformed-sitemap";
      Redirect_Loop_Target : constant String := "test-output-production-redirect-loop";
      Cross_Redirect_Loop_Target : constant String := "test-output-production-cross-redirect-loop";
      Text_Lie_Target : constant String := "test-output-production-text-lie";
      Crawl_Delay_Target : constant String := "test-output-production-crawl-delay";
      Policy_Target : constant String := "test-output-production-http-policy";
      Cap_Target : constant String := "test-output-production-http-cap";
      Reset_Target : constant String := "test-output-production-http-reset";
      Truncated_Target : constant String := "test-output-production-http-truncated";
      Structured_Target : constant String := "test-output-production-structured-progress";
      Structured_Cache_Target : constant String := "test-output-production-structured-cache";
      Redirect_Fail_Target : constant String := "test-output-production-http-redirect-failure";
      Write_Fail_Target : constant String := "test-output-production-http-stream-write-failure";
      Retry_Target : constant String := "test-output-production-http-retry";
      Robots_Target : constant String := "test-output-production-robots";
      Robots_Redirect_Target : constant String := "test-output-production-robots-redirect";
      Cache_Target  : constant String := "test-output-production-cache";
      Cache_Must_Target : constant String := "test-output-production-cache-must";
      Cache_Vary_Target : constant String := "test-output-production-cache-vary";
      Cache_Binary_Target : constant String := "test-output-production-cache-binary";
      Resume_Target : constant String := "test-output-production-resume";
      Resume_Changed_Target : constant String := "test-output-production-resume-changed";
      Resume_Complete_416_Target : constant String := "test-output-production-resume-416-complete";
      Resume_Oversized_Target : constant String := "test-output-production-resume-oversized";
      Resume_Corrupt_Partial_Target : constant String := "test-output-production-resume-corrupt-partial";
      Partial_Strong_Target : constant String := "test-output-production-partial-strong";
      Partial_Weak_Target : constant String := "test-output-production-partial-weak";
      Statistics : Sitefetch.Fetch_Statistics;
      Limits     : Sitefetch.Fetch_Options := Sitefetch.Default_Fetch_Options;
      Control    : aliased Fixture_Control;
      Peer_Control : aliased Fixture_Control;
      Server     : Fixture_Server (Control'Access);
      Peer_Server : Fixture_Server (Peer_Control'Access);
      Port       : GNAT.Sockets.Port_Type;
      Peer_Port  : GNAT.Sockets.Port_Type;
      Base_URL   : Unbounded_String;
   begin
      Control.Wait_Ready (Port);
      Peer_Control.Wait_Ready (Peer_Port);
      Control.Set_Peer_Port (Peer_Port);
      Peer_Control.Set_Peer_Port (Port);
      Base_URL := To_Unbounded_String
        ("http://127.0.0.1:" & Trimmed_Image (Natural (Port)));
      Delete_Tree_If_Present (Target);
      Limits.Crawl.Workers := 1;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/", Target, Statistics, null, Limits),
         "production fixture crawl succeeds");
      Assert (Statistics.Failed = 0, "production fixture has no failures");
      Assert (Ada.Directories.Exists (Target & "/binary"), "binary no-extension file is written");
      Assert (Read_File (Target & "/binary") = Fixture_Binary_Body, "binary no-extension content is preserved");
      Assert (Ada.Directories.Exists (Target & "/final.bin"), "redirected binary final file is written");
      Assert (Read_File (Target & "/final.bin") = Fixture_Redirect_Body, "redirected binary content is preserved");
      Assert (Ada.Directories.Exists (Target & "/head-405"), "HEAD fallback GET file is written");
      Assert (Read_File (Target & "/head-405") = Fixture_Fallback_Body, "HEAD fallback content is preserved");
      Assert (Ada.Directories.Exists (Target & "/mismatch"), "mismatched content-type file is written");
      Assert (Read_File (Target & "/mismatch") = Fixture_Mismatch_Body, "mismatched GET content is preserved");
      Assert (Ada.Directories.Exists (Target & "/icon.svg"), "SVG fixture is written");
      Assert
        (Read_File (Target & "/icon.svg") = "<svg><a href=""svg-linked"">next</a></svg>",
         "SVG fixture is parsed and rewritten as text");
      Assert (Ada.Directories.Exists (Target & "/svg-linked"), "link inside SVG is crawled");
      Assert (Ada.Directories.Exists (Target & "/fontfile"), "font MIME without extension is written");
      Assert (Read_File (Target & "/fontfile") = Fixture_Font_Body, "font MIME content is preserved");
      Assert (Ada.Directories.Exists (Target & "/pdf-doc"), "PDF MIME without extension is written");
      Assert (Read_File (Target & "/pdf-doc") = Fixture_PDF_Body, "PDF MIME content is preserved");
      Assert
        (Ada.Directories.Exists (Target & "/missing-child"),
         "missing Content-Type remains parseable for compatibility");
      Assert (Control.Request_Count ("HEAD", "/binary") = 1, "binary no-extension is probed with HEAD");
      Assert (Control.Request_Count ("GET", "/binary") = 1, "binary no-extension is downloaded with GET");
      Assert (Control.Request_Count ("HEAD", "/head-405") = 1, "HEAD fallback fixture is probed");
      Assert (Control.Request_Count ("GET", "/head-405") = 1, "HEAD fallback fixture uses GET");
      Delete_Tree_If_Present (Target);

      Delete_Tree_If_Present (Malformed_CSS_Target);
      Limits := Sitefetch.Default_Fetch_Options;
      Limits.Crawl.Workers := 1;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/malformed.css", Malformed_CSS_Target, Statistics, null, Limits),
         "production fixture crawls malformed CSS without over-extracting comments");
      Assert (Statistics.Failed = 0, "malformed CSS fixture has no failures");
      Assert
        (Ada.Directories.Exists (Malformed_CSS_Target & "/malformed-css-a.png"),
         "malformed CSS quoted URL before missing function close is crawled");
      Assert
        (Ada.Directories.Exists (Malformed_CSS_Target & "/malformed-css-b.png"),
         "malformed CSS recovers and crawls later URL");
      Assert
        (not Ada.Directories.Exists (Malformed_CSS_Target & "/ignored-malformed-css.png"),
         "malformed CSS does not extract URLs from comments");
      Delete_Tree_If_Present (Malformed_CSS_Target);

      Delete_Tree_If_Present (Malformed_Sitemap_Target);
      Limits := Sitefetch.Default_Fetch_Options;
      Limits.Crawl.Workers := 1;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/malformed-sitemap.xml", Malformed_Sitemap_Target,
            Statistics, null, Limits),
         "production fixture crawls malformed sitemap XML without over-extracting comments");
      Assert (Statistics.Failed = 0, "malformed sitemap fixture has no failures");
      Assert
        (Ada.Directories.Exists (Malformed_Sitemap_Target & "/malformed-sitemap-before.html"),
         "malformed sitemap extracts closed loc before malformed content");
      Assert
        (Ada.Directories.Exists (Malformed_Sitemap_Target & "/malformed-sitemap-after.html"),
         "malformed sitemap recovers and extracts later closed loc");
      Assert
        (not Ada.Directories.Exists (Malformed_Sitemap_Target & "/malformed-sitemap-unclosed.html"),
         "malformed sitemap ignores unterminated loc values");
      Assert
        (not Ada.Directories.Exists (Malformed_Sitemap_Target & "/ignored-malformed-sitemap.html"),
         "malformed sitemap does not extract loc values from comments");
      Delete_Tree_If_Present (Malformed_Sitemap_Target);

      Delete_Tree_If_Present (Redirect_Loop_Target);
      Limits := Sitefetch.Default_Fetch_Options;
      Limits.Crawl.Workers := 1;
      Assert
        (not Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/loop-a", Redirect_Loop_Target, Statistics, null, Limits),
         "production fixture fails redirect loops cleanly");
      Assert (Statistics.Failed = 1, "redirect loop records a single failure");
      Delete_Tree_If_Present (Redirect_Loop_Target);

      Delete_Tree_If_Present (Cross_Redirect_Loop_Target);
      Limits := Sitefetch.Default_Fetch_Options;
      Limits.Crawl.Workers := 1;
      Assert
        (not Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/cross-loop-a.bin", Cross_Redirect_Loop_Target,
            Statistics, null, Limits),
         "production fixture fails cross-origin redirect loops cleanly");
      Assert (Statistics.Failed = 1, "cross-origin redirect loop records a single failure");
      Assert
        (Peer_Control.Request_Count ("GET", "/cross-loop-b.bin") > 0
         or else Peer_Control.Request_Count ("HEAD", "/cross-loop-b.bin") > 0,
         "cross-origin redirect loop reaches the peer origin");
      Delete_Tree_If_Present (Cross_Redirect_Loop_Target);

      Delete_Tree_If_Present (Text_Lie_Target);
      Limits := Sitefetch.Default_Fetch_Options;
      Limits.Crawl.Workers := 1;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/text-lie", Text_Lie_Target, Statistics, null, Limits),
         "production fixture handles HEAD binary and GET text content-type lie");
      Assert (Statistics.Failed = 0, "text content-type lie fixture has no failures");
      Assert
        (Read_File (Text_Lie_Target & "/text-lie") = Fixture_Text_Lie_Body,
         "content-type lie writes the GET body as a passive download");
      Assert
        (not Ada.Directories.Exists (Text_Lie_Target & "/text-lie-child"),
         "content-type lie does not parse a download classified by HEAD as binary");
      Delete_Tree_If_Present (Text_Lie_Target);

      Delete_Tree_If_Present (Crawl_Delay_Target);
      Limits := Sitefetch.Default_Fetch_Options;
      Limits.Crawl.Workers := 4;
      Limits.HTTP.Head := Sitefetch.Head_Disabled;
      Limits.HTTP.Request_Delay_MS := 80;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/delay-root.html", Crawl_Delay_Target,
            Statistics, null, Limits),
         "production fixture crawls with concurrent workers and crawl-delay");
      Assert (Statistics.Failed = 0, "crawl-delay fixture has no failures");
      Assert (Control.Delay_Child_Count = 3, "crawl-delay fixture fetches all child pages");
      Assert
        (Control.Delay_Child_Gap_MS (1) >= 45,
         "crawl-delay spaces first two same-origin child requests");
      Assert
        (Control.Delay_Child_Gap_MS (2) >= 45,
         "crawl-delay spaces second and third same-origin child requests");
      Delete_Tree_If_Present (Crawl_Delay_Target);

      Delete_Tree_If_Present (Policy_Target);
      declare
         Before_Head_Root   : constant Natural := Control.Request_Count ("HEAD", "/");
         Before_Head_Binary : constant Natural := Control.Request_Count ("HEAD", "/binary");
      begin
         Limits := Sitefetch.Default_Fetch_Options;
         Limits.Crawl.Workers := 1;
         Limits.HTTP.Head := Sitefetch.Head_Ambiguous_Only;
         Assert
           (Sitefetch.Crawler.Fetch_Website
              (To_String (Base_URL) & "/", Policy_Target, Statistics, null, Limits),
            "ambiguous-only HEAD policy crawl succeeds");
         Assert
           (Control.Request_Count ("HEAD", "/") = Before_Head_Root,
            "ambiguous-only HEAD policy does not probe directory root");
         Assert
           (Control.Request_Count ("HEAD", "/binary") = Before_Head_Binary + 1,
            "ambiguous-only HEAD policy probes extensionless file path");
      end;
      Delete_Tree_If_Present (Policy_Target);

      Delete_Tree_If_Present (Policy_Target);
      declare
         Before_Head_Root   : constant Natural := Control.Request_Count ("HEAD", "/");
         Before_Head_Binary : constant Natural := Control.Request_Count ("HEAD", "/binary");
      begin
         Limits := Sitefetch.Default_Fetch_Options;
         Limits.Crawl.Workers := 1;
         Limits.HTTP.Head := Sitefetch.Head_Disabled;
         Assert
           (Sitefetch.Crawler.Fetch_Website
              (To_String (Base_URL) & "/", Policy_Target, Statistics, null, Limits),
            "disabled HEAD policy crawl succeeds");
         Assert
           (Control.Request_Count ("HEAD", "/") = Before_Head_Root,
            "disabled HEAD policy does not probe root");
         Assert
           (Control.Request_Count ("HEAD", "/binary") = Before_Head_Binary,
            "disabled HEAD policy does not probe extensionless file path");
      end;
      Delete_Tree_If_Present (Policy_Target);

      Delete_Tree_If_Present (Cap_Target);
      Write_Test_File (Cap_Target & "/big", "stale partial");
      Limits := Sitefetch.Default_Fetch_Options;
      Limits.Crawl.Max_Bytes := 4;
      Assert
        (not Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/big", Cap_Target, Statistics, null, Limits),
         "production fixture byte cap rejects oversized streamed download");
      Assert (Statistics.Failed = 1, "production fixture byte cap records failure");
      Assert (Statistics.Bytes_Written = 0, "production fixture byte cap does not count failed bytes");
      Assert
        (Read_File (Cap_Target & "/big") = "stale partial",
         "failed production streamed download preserves the previous target file");
      Assert (Control.Request_Count ("HEAD", "/big") = 1, "byte-cap fixture is probed with HEAD");
      Delete_Tree_If_Present (Cap_Target);

      Delete_Tree_If_Present (Reset_Target);
      Write_Test_File (Reset_Target & "/reset.bin", "stale reset partial");
      Limits := Sitefetch.Default_Fetch_Options;
      Assert
        (not Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/reset.bin", Reset_Target, Statistics, null, Limits),
         "production fixture mid-body connection reset fails streamed download");
      Assert (Statistics.Failed = 1, "mid-body reset records failure");
      Assert
        (Read_File (Reset_Target & "/reset.bin") = "stale reset partial",
         "mid-body reset preserves the previous target file");
      Delete_Tree_If_Present (Reset_Target);

      Delete_Tree_If_Present (Truncated_Target);
      Write_Test_File (Truncated_Target & "/truncated.bin", "stale truncated partial");
      Limits := Sitefetch.Default_Fetch_Options;
      Assert
        (not Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/truncated.bin", Truncated_Target, Statistics, null, Limits),
         "production fixture truncated fixed-length response fails streamed download");
      Assert (Statistics.Failed = 1, "truncated streamed response records failure");
      Assert
        (Read_File (Truncated_Target & "/truncated.bin") = "stale truncated partial",
         "truncated streamed response preserves the previous target file");
      Delete_Tree_If_Present (Truncated_Target);

      Delete_Tree_If_Present (Structured_Target);
      Structured_Progress_Count := 0;
      Last_Structured_Event := Sitefetch.Progress_Fetching;
      Last_Structured_URL := Null_Unbounded_String;
      Last_Structured_Reason := Null_Unbounded_String;
      Last_Structured_Written_URL := Null_Unbounded_String;
      Last_Structured_Written_Bytes := 0;
      Last_Structured_Written_Depth := 0;
      Last_Structured_Failed_Local_Path := Null_Unbounded_String;
      Last_Structured_Failed_Final_URL := Null_Unbounded_String;
      Last_Structured_Failed_Source_ID := Null_Unbounded_String;
      Last_Structured_Failed_Status := 0;
      Limits := Sitefetch.Default_Fetch_Options;
      Assert
        (not Sitefetch.Crawler.Fetch_Website_With_Structured_Progress
           (To_String (Base_URL) & "/truncated.bin", Structured_Target, Statistics,
            Record_Structured_Progress'Access, Limits),
         "production fixture reports structured progress for failed streamed download");
      Assert (Structured_Progress_Count > 0, "structured callback receives progress events");
      Assert
        (Last_Structured_Event = Sitefetch.Progress_Failed,
         "structured callback records failed event kind");
      Assert
        (To_String (Last_Structured_URL) = To_String (Base_URL) & "/truncated.bin",
         "structured callback separates failed URL");
      Assert
        (Length (Last_Structured_Reason) > 0,
         "structured callback separates failure reason");
      Assert
        (To_String (Last_Structured_Failed_Local_Path) = Structured_Target & "/truncated.bin",
         "structured callback reports failed streamed local path");
      Assert
        (To_String (Last_Structured_Failed_Final_URL) = To_String (Base_URL) & "/truncated.bin",
         "structured callback reports failed streamed final URL by default");
      Assert
        (Length (Last_Structured_Failed_Source_ID) > 0,
         "structured callback reports failed streamed source id by default");
      Assert
        (Last_Structured_Failed_Status = 0,
         "structured callback keeps failed streamed transport status explicit");
      Delete_Tree_If_Present (Structured_Target);

      Structured_Progress_Count := 0;
      Last_Structured_Final_URL := Null_Unbounded_String;
      Last_Structured_Source_ID := Null_Unbounded_String;
      Last_Structured_Redirect_Hops := 0;
      Last_Structured_Redirect_Chain := Null_Unbounded_String;
      Last_Structured_Redirect_Status_Codes := Null_Unbounded_String;
      Last_Structured_Redirect_Target_URLs := Null_Unbounded_String;
      Last_Structured_Redirect_Locations := Null_Unbounded_String;
      Last_Structured_Redirect_Status := 0;
      Limits := Sitefetch.Default_Fetch_Options;
      Limits.Crawl.Workers := 1;
      Assert
        (Sitefetch.Crawler.Fetch_Website_With_Structured_Progress
           (To_String (Base_URL) & "/redirect-page-hop-1", Structured_Target, Statistics,
            Record_Structured_Progress'Access, Limits),
         "structured progress redirect fixture succeeds");
      Assert
        (To_String (Last_Structured_Final_URL) = To_String (Base_URL) & "/redirect-final.html",
         "structured progress reports redirect final URL");
      Assert
        (To_String (Last_Structured_Source_ID) = To_String (Base_URL) & "/redirect-page-hop-1",
         "structured progress reports redirect source id");
      Assert
        (Last_Structured_Redirect_Hops = 2,
         "structured progress reports redirect hop count");
      Assert
        (Contains_Fragment (To_String (Last_Structured_Redirect_Chain), "/redirect-page-hop-1")
         and then Contains_Fragment (To_String (Last_Structured_Redirect_Chain), "2 redirects")
         and then Contains_Fragment (To_String (Last_Structured_Redirect_Chain), "302, 301")
         and then Contains_Fragment (To_String (Last_Structured_Redirect_Chain), "/redirect-final.html"),
         "structured progress reports redirect chain summary");
      Assert
        (To_String (Last_Structured_Redirect_Status_Codes) = "302, 301",
         "structured progress reports per-hop redirect status codes");
      Assert
        (Contains_Fragment (To_String (Last_Structured_Redirect_Target_URLs), "/redirect-page-hop-2")
         and then Contains_Fragment (To_String (Last_Structured_Redirect_Target_URLs), "/redirect-final.html"),
         "structured progress reports per-hop redirect target URLs");
      Assert
        (Contains_Fragment (To_String (Last_Structured_Redirect_Locations), "/redirect-page-hop-2")
         and then Contains_Fragment (To_String (Last_Structured_Redirect_Locations), "/redirect-final.html"),
         "structured progress reports raw Location headers");
      Assert
        (Last_Structured_Redirect_Status = 200,
         "structured progress reports final redirect status code");
      Delete_Tree_If_Present (Structured_Target);

      Structured_Progress_Count := 0;
      Last_Structured_Event := Sitefetch.Progress_Fetching;
      Last_Structured_URL := Null_Unbounded_String;
      Last_Structured_Reason := Null_Unbounded_String;
      Last_Structured_Written_URL := Null_Unbounded_String;
      Last_Structured_Written_Bytes := 0;
      Last_Structured_Written_Depth := 0;
      Last_Structured_Written_Local_Path := Null_Unbounded_String;
      Last_Structured_Written_Final_URL := Null_Unbounded_String;
      Last_Structured_Written_Source_ID := Null_Unbounded_String;
      Limits := Sitefetch.Default_Fetch_Options;
      Limits.Crawl.Workers := 1;
      Limits.Cache.Mode := Sitefetch.Cache_Revalidate;
      Assert
        (Sitefetch.Crawler.Fetch_Website_With_Structured_Progress
           (To_String (Base_URL) & "/cache-root.html", Structured_Target, Statistics,
            Record_Structured_Progress'Access, Limits),
         "structured progress fixture crawl succeeds");
      Assert
        (To_String (Last_Structured_Written_URL) = To_String (Base_URL) & "/cache-child.html",
         "structured progress records the linked page write");
      Assert
        (Last_Structured_Written_Bytes = 11,
         "structured progress reports exact written bytes");
      Assert
        (Last_Structured_Written_Depth = 1,
         "structured progress reports linked page depth");
      Assert
        (Last_Structured_Written_Status = 200,
         "structured progress reports write status code");
      Assert
        (To_String (Last_Structured_Written_Local_Path) = Structured_Target & "/cache-child.html",
         "structured progress reports written local path");
      Assert
        (To_String (Last_Structured_Written_Final_URL) = To_String (Base_URL) & "/cache-child.html",
         "structured progress reports written final URL by default");
      Assert
        (Length (Last_Structured_Written_Source_ID) > 0,
         "structured progress reports written source id by default");
      Delete_Tree_If_Present (Structured_Target);

      Delete_Tree_If_Present (Structured_Cache_Target);
      Limits.Diagnostics.Mode := Sitefetch.Diagnostics_Quiet;
      Assert
        (Sitefetch.Crawler.Fetch_Website_With_Structured_Progress
           (To_String (Base_URL) & "/cache-root.html", Structured_Cache_Target, Statistics,
            Record_Structured_Progress'Access, Limits),
         "structured progress cache warm fixture crawl succeeds");
      Structured_Progress_Count := 0;
      Last_Structured_Cache_URL := Null_Unbounded_String;
      Last_Structured_Cache_Decision := Null_Unbounded_String;
      Last_Structured_Cache_Local_Path := Null_Unbounded_String;
      Limits.Diagnostics.Mode := Sitefetch.Diagnostics_Verbose;
      Assert
        (Sitefetch.Crawler.Fetch_Website_With_Structured_Progress
           (To_String (Base_URL) & "/cache-root.html", Structured_Cache_Target, Statistics,
            Record_Structured_Progress'Access, Limits),
         "structured progress cached fixture crawl succeeds");
      Assert
        (To_String (Last_Structured_Cache_Decision) = "reused",
         "structured progress reports concrete cache reuse metadata");
      Assert
        (To_String (Last_Structured_Cache_URL) = To_String (Base_URL) & "/cache-child.html"
         or else To_String (Last_Structured_Cache_URL) = To_String (Base_URL) & "/cache-root.html",
         "structured progress reports cache decision URL");
      Assert
        (Contains_Fragment (To_String (Last_Structured_Cache_Local_Path), Structured_Cache_Target),
         "structured progress reports cache decision local path");
      Delete_Tree_If_Present (Structured_Cache_Target);

      Structured_Progress_Count := 0;
      Last_Structured_Retry_URL := Null_Unbounded_String;
      Last_Structured_Retry_Final_URL := Null_Unbounded_String;
      Last_Structured_Retry_Source_ID := Null_Unbounded_String;
      Last_Structured_Retry_Attempt := 0;
      Last_Structured_Retry_Status := 0;
      Limits := Sitefetch.Default_Fetch_Options;
      Limits.HTTP.Max_Retries := 1;
      Limits.HTTP.Retry_Delay_MS := 0;
      Limits.Diagnostics.Mode := Sitefetch.Diagnostics_Verbose;
      Assert
        (Sitefetch.Crawler.Fetch_Website_With_Structured_Progress
           (To_String (Base_URL) & "/structured-status-transient.bin", Structured_Target, Statistics,
            Record_Structured_Progress'Access, Limits),
         "structured progress retry fixture crawl succeeds");
      Assert (Last_Structured_Retry_Attempt = 1, "structured progress reports retry attempt");
      Assert (Last_Structured_Retry_Status = 503, "structured progress reports retry HTTP status");
      Assert
        (To_String (Last_Structured_Retry_URL) = To_String (Base_URL) & "/structured-status-transient.bin",
         "structured progress reports retry URL");
      Assert
        (To_String (Last_Structured_Retry_Final_URL) = To_String (Base_URL) & "/structured-status-transient.bin",
         "structured progress reports retry final URL by default");
      Assert
        (Length (Last_Structured_Retry_Source_ID) > 0,
         "structured progress reports retry source id by default");
      Delete_Tree_If_Present (Structured_Target);

      Structured_Progress_Count := 0;
      Last_Structured_Robots_URL := Null_Unbounded_String;
      Last_Structured_Robots_Source := Null_Unbounded_String;
      Limits := Sitefetch.Default_Fetch_Options;
      Limits.Crawl.Workers := 1;
      Limits.Crawl.Robots := Sitefetch.Robots_Respect;
      Limits.HTTP.User_Agent := To_Unbounded_String ("sitefetch-test");
      Limits.Diagnostics.Mode := Sitefetch.Diagnostics_Verbose;
      Assert
        (Sitefetch.Crawler.Fetch_Website_With_Structured_Progress
           (To_String (Base_URL) & "/robots-root.html", Structured_Target, Statistics,
            Record_Structured_Progress'Access, Limits),
         "structured progress robots fixture crawl succeeds");
      Assert
        (To_String (Last_Structured_Robots_Source) = To_String (Base_URL) & "/robots.txt",
         "structured progress reports concrete robots source URL");
      Assert
        (Contains_Fragment (To_String (Last_Structured_Robots_URL), "/robots-"),
         "structured progress reports robots decision URL");
      Delete_Tree_If_Present (Structured_Target);

      Delete_Tree_If_Present (Write_Fail_Target);
      Write_Test_File (Write_Fail_Target & "/blocked", "not a directory");
      Limits := Sitefetch.Default_Fetch_Options;
      Assert
        (not Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/blocked/file.bin", Write_Fail_Target, Statistics, null, Limits),
         "production fixture filesystem write failure fails streamed download");
      Assert (Statistics.Failed = 1, "streaming write failure records failure");
      Assert
        (Ada.Directories.Exists (Write_Fail_Target & "/blocked"),
         "streaming write failure preserves unrelated blocker file");
      Delete_Tree_If_Present (Write_Fail_Target);

      Delete_Tree_If_Present (Redirect_Fail_Target);
      Write_Test_File (Redirect_Fail_Target & "/redirect-to-failure.bin", "stale redirect partial");
      Limits := Sitefetch.Default_Fetch_Options;
      Assert
        (not Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/redirect-to-failure.bin", Redirect_Fail_Target, Statistics, null, Limits),
         "production fixture redirect-to-failure fails streamed download");
      Assert (Statistics.Failed = 1, "redirect-to-failure records failure");
      Assert
        (Read_File (Redirect_Fail_Target & "/redirect-to-failure.bin") = "stale redirect partial",
         "redirect-to-failure preserves the previous original target file");
      Assert
        (not Ada.Directories.Exists (Redirect_Fail_Target & "/truncated.bin"),
         "redirect-to-failure does not leave a final-target partial file");
      Delete_Tree_If_Present (Redirect_Fail_Target);

      Delete_Tree_If_Present (Retry_Target);
      Limits := Sitefetch.Default_Fetch_Options;
      Limits.HTTP.Max_Retries := 1;
      Limits.HTTP.Retry_Delay_MS := 0;
      Limits.Diagnostics.Mode := Sitefetch.Diagnostics_Verbose;
      Parallel_Progress.Reset;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/flaky.bin", Retry_Target, Statistics,
            Record_Parallel_Progress'Access, Limits),
         "production fixture retries transient streamed download failure");
      Assert (Statistics.Failed = 0, "retried streamed download has no failures");
      Assert (Control.Request_Count ("GET", "/flaky.bin") = 2, "flaky streamed download is attempted twice");
      Assert
        (Parallel_Progress.Count (Sitefetch.Progress_Retry) > 0,
         "verbose retry diagnostic is emitted");
      Assert (Read_File (Retry_Target & "/flaky.bin") = Fixture_Flaky_Body, "retried streamed download is written");
      Delete_Tree_If_Present (Retry_Target);

      Delete_Tree_If_Present (Retry_Target);
      Limits := Sitefetch.Default_Fetch_Options;
      Limits.HTTP.Max_Retries := 1;
      Limits.HTTP.Retry_Delay_MS := 0;
      Limits.Diagnostics.Mode := Sitefetch.Diagnostics_Verbose;
      Parallel_Progress.Reset;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/status-transient.bin", Retry_Target, Statistics,
            Record_Parallel_Progress'Access, Limits),
         "production fixture retries transient HTTP status downloads");
      Assert
        (Control.Request_Count ("GET", "/status-transient.bin") = 2,
         "transient HTTP status is attempted twice");
      Assert
        (Parallel_Progress.Count (Sitefetch.Progress_Retry) > 0,
         "transient HTTP status retry diagnostic is emitted");
      Assert (Read_File (Retry_Target & "/status-transient.bin") = "STATUS-OK", "status retry writes success body");
      Delete_Tree_If_Present (Retry_Target);

      Delete_Tree_If_Present (Retry_Target);
      Limits := Sitefetch.Default_Fetch_Options;
      Limits.HTTP.Max_Retries := 1;
      Limits.HTTP.Retry_Delay_MS := 0;
      Limits.Diagnostics.Mode := Sitefetch.Diagnostics_Verbose;
      Parallel_Progress.Reset;
      declare
         Permanent_Result : constant Boolean :=
           Sitefetch.Crawler.Fetch_Website
             (To_String (Base_URL) & "/status-permanent.bin", Retry_Target, Statistics,
              Record_Parallel_Progress'Access, Limits);
      begin
         pragma Unreferenced (Permanent_Result);
      end;
      Assert
        (Control.Request_Count ("GET", "/status-permanent.bin") = 1,
         "permanent HTTP status is not retried");
      Assert
        (Parallel_Progress.Count (Sitefetch.Progress_Retry) = 0,
         "permanent HTTP status does not emit retry diagnostic");
      Delete_Tree_If_Present (Retry_Target);

      Delete_Tree_If_Present (Robots_Target);
      Limits := Sitefetch.Default_Fetch_Options;
      Limits.Crawl.Workers := 1;
      Limits.Crawl.Robots := Sitefetch.Robots_Respect;
      Limits.HTTP.User_Agent := To_Unbounded_String ("sitefetch-test");
      Limits.Diagnostics.Mode := Sitefetch.Diagnostics_Verbose;
      Parallel_Progress.Reset;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/robots-root.html", Robots_Target, Statistics,
            Record_Parallel_Progress'Access, Limits),
         "production fixture respects robots disallow rules");
      Assert (Statistics.Failed = 0, "robots fixture has no failures");
      Assert (Statistics.Skipped_Unsupported = 4, "robots-disallowed URLs are counted as skipped");
      Assert
        (Parallel_Progress.Count (Sitefetch.Progress_Robots_Loaded) > 0,
         "verbose robots-loaded diagnostic is emitted");
      Assert
        (Parallel_Progress.Count (Sitefetch.Progress_Robots_Allowed) > 0,
         "verbose robots-allowed diagnostic is emitted");
      Assert
        (Parallel_Progress.Count (Sitefetch.Progress_Robots_Disallowed) > 0,
         "verbose robots-disallowed diagnostic is emitted");
      Assert (Ada.Directories.Exists (Robots_Target & "/robots-root.html"), "robots root is written");
      Assert (Ada.Directories.Exists (Robots_Target & "/robots-allowed.html"), "robots-allowed link is written");
      Assert
        (Ada.Directories.Exists (Robots_Target & "/robots-private/allowed.html"),
         "robots Allow rule overrides a broader Disallow");
      Assert
        (not Ada.Directories.Exists (Robots_Target & "/robots-private/blocked.html"),
         "robots longest Disallow blocks private sibling");
      Assert
        (not Ada.Directories.Exists (Robots_Target & "/robots-wild/blocked.tmp"),
         "robots wildcard Disallow blocks matching path");
      Assert
        (Ada.Directories.Exists (Robots_Target & "/robots-wild/allowed.txt"),
         "robots wildcard Disallow does not block nonmatching path");
      Assert
        (not Ada.Directories.Exists (Robots_Target & "/robots-anchor/exact"),
         "robots end-anchor Disallow blocks exact target");
      Assert
        (Ada.Directories.Exists (Robots_Target & "/robots-anchor/exactly"),
         "robots end-anchor Disallow does not block longer sibling");
      Assert
        (Ada.Directories.Exists (Robots_Target & "/robots-sitemap.xml"),
         "robots sitemap XML URL is queued");
      Assert
        (Ada.Directories.Exists (Robots_Target & "/robots-sitemap-child.html"),
         "robots sitemap content is crawled when same-origin");
      Assert
        (Ada.Directories.Exists (Robots_Target & "/robots-sitemap-compressed.xml.gz"),
         "compressed robots sitemap is fetched");
      Assert
        (Ada.Directories.Exists (Robots_Target & "/robots-sitemap-gzip-child.html"),
         "compressed robots sitemap content is decompressed and crawled");
      Assert
        (Ada.Directories.Exists (Robots_Target & "/robots-sitemap-level-2.xml"),
         "robots sitemap recursion allows sitemap URLs within the depth limit");
      Assert
        (Ada.Directories.Exists (Robots_Target & "/robots-sitemap-depth-page.html"),
         "robots sitemap recursion still allows ordinary pages at the depth limit");
      Assert
        (not Ada.Directories.Exists (Robots_Target & "/robots-sitemap-level-3.xml"),
         "robots sitemap recursion skips deeper sitemap indexes");
      Assert
        (Parallel_Progress.Count (Sitefetch.Progress_Skipped_Limit) > 0,
         "robots sitemap recursion limit is reported");
      Assert
        (not Ada.Directories.Exists (Robots_Target & "/robots-blocked.html"),
         "robots-disallowed link is not fetched or written");
      Delete_Tree_If_Present (Robots_Target);

      Delete_Tree_If_Present (Robots_Target);
      Control.Set_Robots_Fail (True);
      Limits := Sitefetch.Default_Fetch_Options;
      Limits.Crawl.Workers := 1;
      Limits.Crawl.Robots := Sitefetch.Robots_Respect;
      Limits.HTTP.User_Agent := To_Unbounded_String ("sitefetch-test");
      Limits.Diagnostics.Mode := Sitefetch.Diagnostics_Verbose;
      Parallel_Progress.Reset;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/robots-root.html", Robots_Target, Statistics,
            Record_Parallel_Progress'Access, Limits),
         "production fixture crawls fail-open when robots fetch fails");
      Control.Set_Robots_Fail (False);
      Assert
        (Parallel_Progress.Count (Sitefetch.Progress_Robots_Failed) > 0,
         "verbose robots-failed diagnostic is emitted");
      Assert (Statistics.Failed = 0, "robots fetch failure is not counted as a page failure");
      Assert
        (Ada.Directories.Exists (Robots_Target & "/robots-blocked.html"),
         "robots failure uses fail-open crawling with no parsed disallow rules");
      Delete_Tree_If_Present (Robots_Target);

      Delete_Tree_If_Present (Robots_Target);
      Control.Set_Robots_Fail (True);
      Limits := Sitefetch.Default_Fetch_Options;
      Limits.Crawl.Workers := 1;
      Limits.Crawl.Robots := Sitefetch.Robots_Respect;
      Limits.Crawl.Robots_Failure := Sitefetch.Robots_Fail_Closed;
      Limits.HTTP.User_Agent := To_Unbounded_String ("sitefetch-test");
      Limits.Diagnostics.Mode := Sitefetch.Diagnostics_Verbose;
      Parallel_Progress.Reset;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/robots-root.html", Robots_Target, Statistics,
            Record_Parallel_Progress'Access, Limits),
         "production fixture crawls root when robots failure is fail-closed");
      Control.Set_Robots_Fail (False);
      Assert
        (Parallel_Progress.Count (Sitefetch.Progress_Robots_Failed) > 0,
         "fail-closed robots failure diagnostic is emitted");
      Assert
        (Ada.Directories.Exists (Robots_Target & "/robots-root.html"),
         "fail-closed still writes the requested root document");
      Assert
        (not Ada.Directories.Exists (Robots_Target & "/robots-allowed.html"),
         "fail-closed blocks discovered links after robots failure");
      Delete_Tree_If_Present (Robots_Target);

      Delete_Tree_If_Present (Robots_Redirect_Target);
      Control.Set_Robots_Fail (True);
      Peer_Control.Set_Robots_Fail (False);
      declare
         Origin_Robots_Before : constant Natural := Control.Request_Count ("GET", "/robots.txt");
         Peer_Robots_Before   : constant Natural := Peer_Control.Request_Count ("GET", "/robots.txt");
      begin
         Limits := Sitefetch.Default_Fetch_Options;
         Limits.Crawl.Workers := 1;
         Limits.Crawl.Robots := Sitefetch.Robots_Respect;
         Limits.HTTP.User_Agent := To_Unbounded_String ("sitefetch-test");
         Limits.Diagnostics.Mode := Sitefetch.Diagnostics_Verbose;
         Parallel_Progress.Reset;
         Assert
           (Sitefetch.Crawler.Fetch_Website
              (To_String (Base_URL) & "/redirect-to-peer-robots.html",
               Robots_Redirect_Target, Statistics, Record_Parallel_Progress'Access, Limits),
            "redirected-origin robots fixture applies the final origin robots rules");
         Assert (Statistics.Failed = 0, "redirected-origin robots fixture has no failures");
         Assert
           (Control.Request_Count ("GET", "/robots.txt") = Origin_Robots_Before,
            "redirected-origin robots fixture does not fetch robots for the initial origin");
         Assert
           (Peer_Control.Request_Count ("GET", "/robots.txt") = Peer_Robots_Before + 1,
            "redirected-origin robots fixture fetches robots for the final origin");
         Assert
           (Ada.Directories.Exists (Robots_Redirect_Target & "/redirected-robots-root.html"),
            "redirected-origin robots fixture writes the final root document");
         Assert
           (Ada.Directories.Exists (Robots_Redirect_Target & "/robots-allowed.html"),
            "redirected-origin robots fixture allows final-origin allowed links");
         Assert
           (not Ada.Directories.Exists (Robots_Redirect_Target & "/robots-blocked.html"),
            "redirected-origin robots fixture blocks final-origin disallowed links");
         Assert
           (Parallel_Progress.Count (Sitefetch.Progress_Robots_Loaded) > 0,
            "redirected-origin robots fixture reports final-origin robots loading");
      end;
      Control.Set_Robots_Fail (False);
      Delete_Tree_If_Present (Robots_Redirect_Target);

      Delete_Tree_If_Present (Robots_Redirect_Target);
      Control.Set_Robots_Fail (False);
      Peer_Control.Set_Robots_Fail (True);
      declare
         Peer_Robots_Before : constant Natural := Peer_Control.Request_Count ("GET", "/robots.txt");
      begin
         Limits := Sitefetch.Default_Fetch_Options;
         Limits.Crawl.Workers := 1;
         Limits.Crawl.Robots := Sitefetch.Robots_Respect;
         Limits.Crawl.Robots_Failure := Sitefetch.Robots_Fail_Closed;
         Limits.HTTP.User_Agent := To_Unbounded_String ("sitefetch-test");
         Limits.Diagnostics.Mode := Sitefetch.Diagnostics_Verbose;
         Parallel_Progress.Reset;
         Assert
           (Sitefetch.Crawler.Fetch_Website
              (To_String (Base_URL) & "/redirect-to-peer-robots.html",
               Robots_Redirect_Target, Statistics, Record_Parallel_Progress'Access, Limits),
            "redirected-origin fail-closed robots fixture writes only the final root");
         Assert
           (Peer_Control.Request_Count ("GET", "/robots.txt") = Peer_Robots_Before + 1,
            "redirected-origin fail-closed fixture fetches robots from the final origin");
         Assert
           (Ada.Directories.Exists (Robots_Redirect_Target & "/redirected-robots-root.html"),
            "redirected-origin fail-closed fixture writes final root document");
         Assert
           (not Ada.Directories.Exists (Robots_Redirect_Target & "/robots-allowed.html"),
            "redirected-origin fail-closed fixture blocks discovered final-origin links");
         Assert
           (Parallel_Progress.Count (Sitefetch.Progress_Robots_Failed) > 0,
            "redirected-origin fail-closed fixture reports final-origin robots failure");
      end;
      Peer_Control.Set_Robots_Fail (False);
      Delete_Tree_If_Present (Robots_Redirect_Target);

      Delete_Tree_If_Present (Cache_Target);
      Limits := Sitefetch.Default_Fetch_Options;
      Limits.Crawl.Workers := 1;
      Limits.Cache.Mode := Sitefetch.Cache_Revalidate;
      Limits.Diagnostics.Mode := Sitefetch.Diagnostics_Verbose;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/cache-root.html", Cache_Target, Statistics, null, Limits),
         "production fixture writes cache metadata for buffered documents");
      Assert (Statistics.Bytes_Written > 0, "initial cache fixture writes bytes");
      Assert
        (Ada.Directories.Exists (Cache_Target & "/cache-root.html.sitefetch_http_cache"),
         "document cache metadata is written");
      if Ada.Directories.Exists (Cache_Target & "/cache-child.html") then
         Ada.Directories.Delete_File (Cache_Target & "/cache-child.html");
      end if;
      Parallel_Progress.Reset;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/cache-root.html", Cache_Target, Statistics,
            Record_Parallel_Progress'Access, Limits),
         "production fixture reuses fresh buffered document");
      Assert (Statistics.Bytes_Written = 11, "fresh cached root only counts re-fetched child bytes");
      Assert
        (Parallel_Progress.Count (Sitefetch.Progress_Cache_Revalidate) = 0,
         "fresh cache hit does not revalidate");
      Assert
        (Parallel_Progress.Count (Sitefetch.Progress_Cache_Reused) > 0,
         "verbose cache reuse diagnostic is emitted");
      Assert
        (Read_File (Cache_Target & "/cache-root.html") = "<a href=""cache-child.html"">child</a>",
         "fresh buffered document preserves intact cached file");
      Assert
        (Read_File (Cache_Target & "/cache-child.html") = "cache child",
         "304 buffered document reparses cached links and queues children");
      Write_Test_File (Cache_Target & "/cache-root.html", "corrupted cached document");
      if Ada.Directories.Exists (Cache_Target & "/cache-child.html") then
         Ada.Directories.Delete_File (Cache_Target & "/cache-child.html");
      end if;
      Parallel_Progress.Reset;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/cache-root.html", Cache_Target, Statistics,
            Record_Parallel_Progress'Access, Limits),
         "buffered cache corruption forces fresh document download");
      Assert
        (Read_File (Cache_Target & "/cache-root.html") = "<a href=""cache-child.html"">child</a>",
         "buffered cache corruption repair restores root document");
      Assert
        (Read_File (Cache_Target & "/cache-child.html") = "cache child",
         "buffered cache corruption repair reparses links and queues children");
      Assert
        (Parallel_Progress.Count (Sitefetch.Progress_Cache_Reused) = 0,
         "corrupt buffered document does not report cache reuse");
      Delete_Tree_If_Present (Cache_Target);

      Delete_Tree_If_Present (Cache_Must_Target);
      Parallel_Progress.Reset;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/cache-must.html", Cache_Must_Target, Statistics,
            Record_Parallel_Progress'Access, Limits),
         "production fixture writes must-revalidate cache metadata");
      Parallel_Progress.Reset;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/cache-must.html", Cache_Must_Target, Statistics,
            Record_Parallel_Progress'Access, Limits),
         "must-revalidate cached document still validates with origin");
      Assert (Statistics.Bytes_Written = 0, "must-revalidate 304 reports no bytes written");
      Assert
        (Parallel_Progress.Count (Sitefetch.Progress_Cache_Revalidate) > 0,
         "must-revalidate emits cache revalidation diagnostic");
      Assert
        (Parallel_Progress.Count (Sitefetch.Progress_Cache_Reused) > 0,
         "must-revalidate 304 emits cache reuse diagnostic");
      Delete_Tree_If_Present (Cache_Must_Target);

      Limits.Cache.Mode := Sitefetch.Cache_Revalidate;
      Delete_Tree_If_Present (Cache_Vary_Target);
      Parallel_Progress.Reset;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/cache-vary-lang.html", Cache_Vary_Target, Statistics,
            Record_Parallel_Progress'Access, Limits),
         "production fixture writes unsupported Vary cache metadata");
      Parallel_Progress.Reset;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/cache-vary-lang.html", Cache_Vary_Target, Statistics,
            Record_Parallel_Progress'Access, Limits),
         "unsupported Vary field forces fresh fetch");
      Assert (Statistics.Bytes_Written = 9, "unsupported Vary refresh writes bytes");
      Assert
        (Parallel_Progress.Count (Sitefetch.Progress_Cache_Reused) = 0,
         "unsupported Vary does not report cache reuse");
      Assert
        (Parallel_Progress.Count (Sitefetch.Progress_Cache_Rejected) > 0,
         "unsupported Vary reports cache rejection reason");
      Limits.Cache.Vary_Allow.Accept_Language := True;
      Parallel_Progress.Reset;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/cache-vary-lang.html", Cache_Vary_Target, Statistics,
            Record_Parallel_Progress'Access, Limits),
         "allowed Vary field permits fresh cache reuse");
      Assert (Statistics.Bytes_Written = 0, "allowed Vary reuse writes no bytes");
      Assert
        (Parallel_Progress.Count (Sitefetch.Progress_Cache_Reused) > 0,
         "allowed Vary reports cache reuse");
      declare
         Sidecar : constant String :=
           Read_File (Cache_Vary_Target & "/cache-vary-lang.html.sitefetch_http_cache");
      begin
         Assert
           (Ada.Strings.Fixed.Index (Sidecar, "Request-Accept-Language: ") > 0,
            "Vary sidecar records effective Accept-Language request value");
         Assert
           (Ada.Strings.Fixed.Index
              (Sidecar, "Request-Accept-Encoding: " & Sitefetch.Default_Accept_Encoding) > 0,
            "Vary sidecar records effective Accept-Encoding request value");
      end;

      Limits.HTTP.Accept_Language := To_Unbounded_String ("en-US");
      Parallel_Progress.Reset;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/cache-vary-lang.html", Cache_Vary_Target, Statistics,
            Record_Parallel_Progress'Access, Limits),
         "changed allowed Vary request header forces fresh fetch");
      Assert (Statistics.Bytes_Written = 9, "changed allowed Vary request header writes fresh bytes");
      Assert
        (Parallel_Progress.Count (Sitefetch.Progress_Cache_Reused) = 0,
         "changed allowed Vary request header does not report cache reuse");
      Assert
        (Parallel_Progress.Count (Sitefetch.Progress_Cache_Rejected) > 0,
         "changed allowed Vary request header reports cache rejection reason");
      Limits.HTTP.Accept_Language := Null_Unbounded_String;

      Write_Test_File
        (Cache_Vary_Target & "/cache-vary-lang.html.sitefetch_http_cache",
         "Cache-Version: 2" & Character'Val (10)
         & "URL: " & To_String (Base_URL) & "/cache-vary-lang.html" & Character'Val (10)
         & "Final-URL: " & To_String (Base_URL) & "/cache-vary-lang.html" & Character'Val (10)
         & "Content-Type: text/html" & Character'Val (10)
         & "ETag: cache-vary-lang-v1" & Character'Val (10)
         & "Cache-Control: max-age=3600" & Character'Val (10)
         & "Vary: Accept-Language" & Character'Val (10)
         & "Request-User-Agent: " & Sitefetch.Default_User_Agent & Character'Val (10)
         & "Request-Accept-Language: da-DK" & Character'Val (10)
         & "Request-Accept-Encoding: " & Sitefetch.Default_Accept_Encoding & Character'Val (10));
      Limits.Cache.Verify_Local_Content := False;
      Parallel_Progress.Reset;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/cache-vary-lang.html", Cache_Vary_Target, Statistics,
            Record_Parallel_Progress'Access, Limits),
         "mismatched allowed Vary request value forces fresh fetch");
      Assert (Statistics.Bytes_Written = 9, "mismatched Vary request value writes fresh bytes");
      Assert
        (Parallel_Progress.Count (Sitefetch.Progress_Cache_Reused) = 0,
         "mismatched Vary request value does not report cache reuse");
      Assert
        (Parallel_Progress.Count (Sitefetch.Progress_Cache_Rejected) > 0,
         "mismatched Vary request value reports cache rejection reason");
      Limits.Cache.Verify_Local_Content := True;
      Delete_Tree_If_Present (Cache_Vary_Target);

      Limits := Sitefetch.Default_Fetch_Options;
      Limits.Cache.Mode := Sitefetch.Cache_Revalidate;
      Limits.Diagnostics.Mode := Sitefetch.Diagnostics_Verbose;
      Limits.Cache.Vary_Allow.Accept_Language := True;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/cache-vary-combo.html", Cache_Vary_Target, Statistics, null, Limits),
         "combined Vary fixture first writes cache sidecar");
      Parallel_Progress.Reset;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/cache-vary-combo.html", Cache_Vary_Target, Statistics,
            Record_Parallel_Progress'Access, Limits),
         "unallowed combined Vary field forces fresh fetch");
      Assert (Statistics.Bytes_Written = 10, "unallowed combined Vary field writes fresh bytes");
      Assert
        (Parallel_Progress.Count (Sitefetch.Progress_Cache_Reused) = 0,
         "unallowed combined Vary field does not report cache reuse");
      Assert
        (Parallel_Progress.Count (Sitefetch.Progress_Cache_Rejected) > 0,
         "unallowed combined Vary field reports cache rejection reason");
      Limits.Cache.Vary_Allow.Accept_Encoding := True;
      Parallel_Progress.Reset;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/cache-vary-combo.html", Cache_Vary_Target, Statistics,
            Record_Parallel_Progress'Access, Limits),
         "allowed combined Vary fields permit cache reuse");
      Assert (Statistics.Bytes_Written = 0, "allowed combined Vary reuse writes no bytes");
      Assert
        (Parallel_Progress.Count (Sitefetch.Progress_Cache_Reused) > 0,
         "allowed combined Vary fields report cache reuse");
      Limits.HTTP.Accept_Encoding := To_Unbounded_String ("identity");
      Parallel_Progress.Reset;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/cache-vary-combo.html", Cache_Vary_Target, Statistics,
            Record_Parallel_Progress'Access, Limits),
         "changed allowed Accept-Encoding Vary value forces fresh fetch");
      Assert (Statistics.Bytes_Written = 10, "changed Accept-Encoding Vary value writes fresh bytes");
      Assert
        (Parallel_Progress.Count (Sitefetch.Progress_Cache_Reused) = 0,
         "changed Accept-Encoding Vary value does not report cache reuse");
      Assert
        (Parallel_Progress.Count (Sitefetch.Progress_Cache_Rejected) > 0,
         "changed Accept-Encoding Vary value reports cache rejection reason");
      Delete_Tree_If_Present (Cache_Vary_Target);

      Delete_Tree_If_Present (Cache_Vary_Target);
      Limits := Sitefetch.Default_Fetch_Options;
      Limits.Cache.Mode := Sitefetch.Cache_Offline;
      declare
         Before_Get : constant Natural := Control.Request_Count ("GET", "/cache-vary-lang.html");
         Before_Head : constant Natural := Control.Request_Count ("HEAD", "/cache-vary-lang.html");
      begin
         Assert
           (not Sitefetch.Crawler.Fetch_Website
              (To_String (Base_URL) & "/cache-vary-lang.html", Cache_Vary_Target, Statistics, null, Limits),
            "offline cache misses without a local sidecar");
         Assert (Statistics.Failed = 1, "offline cache miss records a failure");
         Assert
           (Control.Request_Count ("GET", "/cache-vary-lang.html") = Before_Get
            and then Control.Request_Count ("HEAD", "/cache-vary-lang.html") = Before_Head,
            "offline cache miss does not contact the origin");
      end;
      Delete_Tree_If_Present (Cache_Vary_Target);

      Limits := Sitefetch.Default_Fetch_Options;
      Limits.Cache.Mode := Sitefetch.Cache_Revalidate;
      Limits.Cache.Vary_Allow.Accept_Language := True;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/cache-vary-lang.html", Cache_Vary_Target, Statistics, null, Limits),
         "offline cache fixture first writes local cache");
      Limits.Cache.Mode := Sitefetch.Cache_Offline;
      declare
         Before_Get : constant Natural := Control.Request_Count ("GET", "/cache-vary-lang.html");
         Before_Head : constant Natural := Control.Request_Count ("HEAD", "/cache-vary-lang.html");
      begin
         Assert
           (Sitefetch.Crawler.Fetch_Website
              (To_String (Base_URL) & "/cache-vary-lang.html", Cache_Vary_Target, Statistics, null, Limits),
            "offline cache reuses fresh local document");
         Assert (Statistics.Bytes_Written = 0, "offline fresh reuse writes no bytes");
         Assert
           (Control.Request_Count ("GET", "/cache-vary-lang.html") = Before_Get
            and then Control.Request_Count ("HEAD", "/cache-vary-lang.html") = Before_Head,
            "offline cache reuse does not contact the origin");
      end;
      Delete_Tree_If_Present (Cache_Vary_Target);

      Delete_Tree_If_Present (Cache_Binary_Target);
      Limits := Sitefetch.Default_Fetch_Options;
      Limits.Cache.Mode := Sitefetch.Cache_Revalidate;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/cache.bin", Cache_Binary_Target, Statistics, null, Limits),
         "production fixture writes cache metadata for streamed downloads");
      Assert
        (Read_File (Cache_Binary_Target & "/cache.bin") = Fixture_Cache_Body,
         "initial cached binary is written");
      declare
         Sidecar : constant String := Read_File (Cache_Binary_Target & "/cache.bin.sitefetch_http_cache");
      begin
         Assert
           (Ada.Strings.Fixed.Index (Sidecar, "Cache-Version: 2") > 0,
            "binary cache sidecar records cache metadata version");
         Assert
           (Ada.Strings.Fixed.Index (Sidecar, "Content-Type: application/octet-stream") > 0,
            "binary cache sidecar records content type");
         Assert
           (Ada.Strings.Fixed.Index
              (Sidecar, "Content-Length: " & Ada.Strings.Fixed.Trim
                 (Natural'Image (Fixture_Cache_Body'Length), Ada.Strings.Both)) > 0,
            "binary cache sidecar records content length");
         Assert
           (Ada.Strings.Fixed.Index (Sidecar, "ETag-Weak: false") > 0,
            "binary cache sidecar records strong ETag distinction");
         Assert
           (Ada.Strings.Fixed.Index (Sidecar, "Cache-Control: max-age=60") > 0,
            "binary cache sidecar records Cache-Control");
         Assert
           (Ada.Strings.Fixed.Index (Sidecar, "Expires: Wed, 21 Oct 2037 07:28:00 GMT") > 0,
            "binary cache sidecar records Expires");
         Assert
           (Ada.Strings.Fixed.Index (Sidecar, "Vary: User-Agent") > 0,
            "binary cache sidecar records Vary");
         Assert
           (Ada.Strings.Fixed.Index (Sidecar, "Request-User-Agent: sitefetch/0.1") > 0,
            "binary cache sidecar records request User-Agent for Vary checks");
         Assert
           (Ada.Strings.Fixed.Index (Sidecar, "Request-Accept-Language: ") > 0,
            "binary cache sidecar records request Accept-Language for Vary checks");
         Assert
           (Ada.Strings.Fixed.Index
              (Sidecar, "Request-Accept-Encoding: " & Sitefetch.Default_Accept_Encoding) > 0,
            "binary cache sidecar records request Accept-Encoding for Vary checks");
         Assert
           (Ada.Strings.Fixed.Index (Sidecar, "Local-Size: " & Ada.Strings.Fixed.Trim
              (Natural'Image (Fixture_Cache_Body'Length), Ada.Strings.Both)) > 0,
            "binary cache sidecar records local file size");
         Assert
           (Ada.Strings.Fixed.Index (Sidecar, "Local-Hash: ") > 0,
            "binary cache sidecar records local file hash");
         Assert
           (Ada.Strings.Fixed.Index (Sidecar, "Local-Hash-Algorithm: fnv1a-64") > 0,
            "binary cache sidecar records local hash algorithm");
         Assert
           (Ada.Strings.Fixed.Index (Sidecar, "Resume-Safe: false") > 0,
            "final cache sidecar is not marked as a partial resume promise");
      end;

      if Ada.Directories.Exists (Cache_Binary_Target & "/cache.bin.sitefetch_http_cache") then
         Ada.Directories.Delete_File (Cache_Binary_Target & "/cache.bin.sitefetch_http_cache");
      end if;
      Ada.Directories.Create_Path (Cache_Binary_Target & "/cache.bin.sitefetch_http_cache");
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/cache.bin", Cache_Binary_Target, Statistics, null, Limits),
         "cache sidecar directory blocker does not fail streamed download refresh");
      Assert
        (Ada.Directories.Exists (Cache_Binary_Target & "/cache.bin.sitefetch_http_cache")
         and then Ada.Directories.Kind (Cache_Binary_Target & "/cache.bin.sitefetch_http_cache")
           in Ada.Directories.Directory,
         "cache sidecar directory blocker is not replaced by metadata write");
      Assert
        (Read_File (Cache_Binary_Target & "/cache.bin") = Fixture_Cache_Body,
         "cache sidecar blocker preserves refreshed binary content");
      if Ada.Directories.Exists (Cache_Binary_Target & "/cache.bin.sitefetch_http_cache") then
         if Ada.Directories.Kind (Cache_Binary_Target & "/cache.bin.sitefetch_http_cache")
           in Ada.Directories.Directory
         then
            Ada.Directories.Delete_Tree (Cache_Binary_Target & "/cache.bin.sitefetch_http_cache");
         else
            Ada.Directories.Delete_File (Cache_Binary_Target & "/cache.bin.sitefetch_http_cache");
         end if;
      end if;
      Limits.Cache.Mode := Sitefetch.Cache_Revalidate;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/cache.bin", Cache_Binary_Target, Statistics, null, Limits),
         "production fixture rewrites cache metadata after sidecar blocker is removed");
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/cache.bin", Cache_Binary_Target, Statistics, null, Limits),
         "production fixture reuses fresh streamed download");
      Assert (Statistics.Bytes_Written = 0, "fresh streamed download reports zero written bytes");
      Assert
        (Read_File (Cache_Binary_Target & "/cache.bin") = Fixture_Cache_Body,
         "fresh streamed download preserves intact cached file");

      Limits.Diagnostics.Mode := Sitefetch.Diagnostics_Verbose;
      Limits.HTTP.User_Agent := To_Unbounded_String ("sitefetch-vary-test");
      Parallel_Progress.Reset;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/cache.bin", Cache_Binary_Target, Statistics,
            Record_Parallel_Progress'Access, Limits),
         "Vary User-Agent mismatch forces fresh streamed download");
      Assert (Statistics.Bytes_Written = Fixture_Cache_Body'Length, "Vary mismatch writes fresh bytes");
      Assert
        (Parallel_Progress.Count (Sitefetch.Progress_Cache_Reused) = 0,
         "Vary mismatch does not report cache reuse");

      Limits.HTTP.User_Agent := To_Unbounded_String (Sitefetch.Default_User_Agent);
      Write_Test_File (Cache_Binary_Target & "/cache.bin", "corrupted cached binary");
      Parallel_Progress.Reset;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/cache.bin", Cache_Binary_Target, Statistics,
            Record_Parallel_Progress'Access, Limits),
         "local cache corruption forces fresh streamed download");
      Assert (Statistics.Bytes_Written = Fixture_Cache_Body'Length, "corruption repair writes fresh bytes");
      Assert
        (Read_File (Cache_Binary_Target & "/cache.bin") = Fixture_Cache_Body,
         "corruption repair restores cached binary");
      Assert
        (Parallel_Progress.Count (Sitefetch.Progress_Cache_Reused) = 0,
         "corrupt local file does not report cache reuse");

      Write_Test_File
        (Cache_Binary_Target & "/cache.bin.sitefetch_http_cache",
         "Cache-Version: 2" & Character'Val (10)
         & "URL: " & To_String (Base_URL) & "/cache.bin" & Character'Val (10)
         & "Final-URL: " & To_String (Base_URL) & "/cache.bin" & Character'Val (10)
         & "ETag: cache-bin-v1" & Character'Val (10)
         & "Cache-Control: max-age=60" & Character'Val (10)
         & "Vary: User-Agent" & Character'Val (10)
         & "Request-User-Agent: " & Sitefetch.Default_User_Agent & Character'Val (10));
      Write_Test_File (Cache_Binary_Target & "/cache.bin", Fixture_Cache_Body);
      Limits.Cache.Verify_Local_Content := True;
      Parallel_Progress.Reset;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/cache.bin", Cache_Binary_Target, Statistics,
            Record_Parallel_Progress'Access, Limits),
         "missing cache integrity fields force fresh streamed download");
      Assert (Statistics.Bytes_Written = Fixture_Cache_Body'Length,
              "missing integrity metadata writes fresh bytes");
      Assert
        (Parallel_Progress.Count (Sitefetch.Progress_Cache_Reused) = 0,
         "missing integrity metadata does not report cache reuse");

      Limits.Cache.Hash_Algorithm := Sitefetch.Cache_Hash_None;
      Limits.Cache.Mode := Sitefetch.Cache_Refresh;
      Parallel_Progress.Reset;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/cache.bin", Cache_Binary_Target, Statistics,
            Record_Parallel_Progress'Access, Limits),
         "size-only cache hash policy refreshes sidecar without local hash");
      declare
         Sidecar : constant String := Read_File (Cache_Binary_Target & "/cache.bin.sitefetch_http_cache");
      begin
         Assert
           (Ada.Strings.Fixed.Index (Sidecar, "Local-Size: " & Ada.Strings.Fixed.Trim
              (Natural'Image (Fixture_Cache_Body'Length), Ada.Strings.Both)) > 0,
            "size-only cache policy still records local size");
         Assert
           (Ada.Strings.Fixed.Index (Sidecar, "Local-Hash: Local-Hash-Algorithm: none") > 0,
            "size-only cache policy omits local hash value");
         Assert
           (Ada.Strings.Fixed.Index (Sidecar, "Local-Hash-Algorithm: none") > 0,
            "size-only cache policy records hash algorithm");
      end;
      Limits.Cache.Mode := Sitefetch.Cache_Revalidate;
      Parallel_Progress.Reset;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/cache.bin", Cache_Binary_Target, Statistics,
            Record_Parallel_Progress'Access, Limits),
         "size-only cache hash policy accepts matching local streamed download");
      Assert
        (Parallel_Progress.Count (Sitefetch.Progress_Cache_Reused) > 0,
         "size-only cache policy reports cache reuse");
      Assert (Statistics.Bytes_Written = 0, "size-only cache policy writes no repair bytes");

      Limits.Cache.Hash_Algorithm := Sitefetch.Cache_Hash_SHA256;
      Limits.Cache.Mode := Sitefetch.Cache_Refresh;
      Parallel_Progress.Reset;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/cache.bin", Cache_Binary_Target, Statistics,
            Record_Parallel_Progress'Access, Limits),
         "SHA-256 cache hash policy refreshes streamed download sidecar");
      declare
         Sidecar : constant String := Read_File (Cache_Binary_Target & "/cache.bin.sitefetch_http_cache");
      begin
         Assert
           (Ada.Strings.Fixed.Index (Sidecar, "Local-Hash-Algorithm: sha256") > 0,
            "SHA-256 cache policy records hash algorithm");
         Assert
           (Ada.Strings.Fixed.Index (Sidecar, "Local-Hash: Local-Hash-Algorithm") = 0,
            "SHA-256 cache policy records non-empty local hash");
      end;
      Limits.Cache.Mode := Sitefetch.Cache_Revalidate;
      Parallel_Progress.Reset;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/cache.bin", Cache_Binary_Target, Statistics,
            Record_Parallel_Progress'Access, Limits),
         "SHA-256 cache hash policy reuses matching local streamed download");
      Assert (Statistics.Bytes_Written = 0, "SHA-256 cache policy reuse writes no bytes");
      Assert
        (Parallel_Progress.Count (Sitefetch.Progress_Cache_Reused) > 0,
         "SHA-256 cache policy reports cache reuse");

      Limits.Cache.Hash_Algorithm := Sitefetch.Cache_Hash_FNV1a_64;
      Parallel_Progress.Reset;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/cache.bin", Cache_Binary_Target, Statistics,
            Record_Parallel_Progress'Access, Limits),
         "hash algorithm mismatch forces streamed download refresh");
      Assert (Statistics.Bytes_Written = Fixture_Cache_Body'Length,
              "hash algorithm mismatch writes fresh bytes");
      Assert
        (Parallel_Progress.Count (Sitefetch.Progress_Cache_Reused) = 0,
         "hash algorithm mismatch does not report cache reuse");

      Write_Test_File (Cache_Binary_Target & "/cache.bin", "trusted stale binary");
      Limits.Cache.Verify_Local_Content := False;
      Parallel_Progress.Reset;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/cache.bin", Cache_Binary_Target, Statistics,
            Record_Parallel_Progress'Access, Limits),
         "disabled local verification trusts existing cached streamed download");
      Assert (Statistics.Bytes_Written = 0, "disabled verification writes no repair bytes");
      Assert
        (Read_File (Cache_Binary_Target & "/cache.bin") = "trusted stale binary",
         "disabled verification preserves trusted local file");
      Assert
        (Parallel_Progress.Count (Sitefetch.Progress_Cache_Reused) > 0,
         "disabled verification reports cache reuse");
      Limits.Cache.Verify_Local_Content := True;

      Write_Test_File
        (Cache_Binary_Target & "/cache.bin.sitefetch_http_cache",
         "URL: " & To_String (Base_URL) & "/cache.bin" & Character'Val (10)
         & "Final-URL: " & To_String (Base_URL) & "/cache.bin" & Character'Val (10)
         & "ETag: cache-bin-v1" & Character'Val (10)
         & "Cache-Control: max-age=60" & Character'Val (10)
         & "Vary: User-Agent" & Character'Val (10)
         & "Request-User-Agent: " & Sitefetch.Default_User_Agent & Character'Val (10));
      Write_Test_File (Cache_Binary_Target & "/cache.bin", Fixture_Cache_Body);
      Limits.Cache.Require_Metadata_Version := True;
      Parallel_Progress.Reset;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/cache.bin", Cache_Binary_Target, Statistics,
            Record_Parallel_Progress'Access, Limits),
         "strict metadata version policy rejects unversioned sidecars");
      Assert (Statistics.Bytes_Written = Fixture_Cache_Body'Length,
              "strict metadata version rejection writes fresh bytes");
      Assert
        (Parallel_Progress.Count (Sitefetch.Progress_Cache_Reused) = 0,
         "strict metadata version rejection does not report cache reuse");
      Limits.Cache.Require_Metadata_Version := False;
      Delete_Tree_If_Present (Resume_Target);
      Limits := Sitefetch.Default_Fetch_Options;
      Limits.Cache.Mode := Sitefetch.Cache_Revalidate;
      Limits.Diagnostics.Mode := Sitefetch.Diagnostics_Verbose;
      Write_Binary_Test_File (Resume_Target & "/resume.bin.sitefetch_part", "RESUME-");
      Write_Test_File
        (Resume_Target & "/resume.bin.sitefetch_part.sitefetch_http_cache",
         "URL: " & To_String (Base_URL) & "/resume.bin" & Character'Val (10)
         & "Final-URL: " & To_String (Base_URL) & "/resume.bin" & Character'Val (10)
         & "ETag: resume-v1" & Character'Val (10)
         & "Last-Modified: " & Character'Val (10));
      Parallel_Progress.Reset;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/resume.bin", Resume_Target, Statistics,
            Record_Parallel_Progress'Access, Limits),
         "production fixture resumes partial streamed download");
      Assert
        (Parallel_Progress.Count (Sitefetch.Progress_Resume_Attempt) > 0,
         "verbose resume diagnostic is emitted");
      Assert
        (Read_File (Resume_Target & "/resume.bin") = Fixture_Resume_Body,
         "resumed streamed download completes final file");
      Assert
        (Statistics.Bytes_Written = Fixture_Resume_Body'Length - 7,
         "resumed streamed download counts only newly written bytes");
      Assert
        (not Ada.Directories.Exists (Resume_Target & "/resume.bin.sitefetch_part"),
         "resumed streamed download installs and removes partial file");
      Assert
        (Control.Request_Count ("GET", "/resume.bin") = 1,
         "resumed streamed download issues one GET request");
      Delete_Tree_If_Present (Resume_Target);

      Delete_Tree_If_Present (Resume_Changed_Target);
      Limits := Sitefetch.Default_Fetch_Options;
      Limits.Cache.Mode := Sitefetch.Cache_Revalidate;
      Write_Binary_Test_File (Resume_Changed_Target & "/resume-changed.bin.sitefetch_part", "CHANGED-");
      Write_Test_File
        (Resume_Changed_Target & "/resume-changed.bin.sitefetch_part.sitefetch_http_cache",
         "URL: " & To_String (Base_URL) & "/resume-changed.bin" & Character'Val (10)
         & "Final-URL: " & To_String (Base_URL) & "/resume-changed.bin" & Character'Val (10)
         & "ETag: old-resume-v1" & Character'Val (10)
         & "Last-Modified: " & Character'Val (10));
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/resume-changed.bin", Resume_Changed_Target, Statistics, null, Limits),
         "If-Range validator mismatch falls back to full streamed download");
      Assert
        (Read_File (Resume_Changed_Target & "/resume-changed.bin") = Fixture_Changed_Resume_Body,
         "If-Range mismatch replaces stale partial with full body");
      Assert
        (not Ada.Directories.Exists (Resume_Changed_Target & "/resume-changed.bin.sitefetch_part"),
         "If-Range mismatch installs final file and removes partial");
      Assert
        (Statistics.Bytes_Written = Fixture_Changed_Resume_Body'Length,
         "If-Range mismatch counts the full replacement body");
      Delete_Tree_If_Present (Resume_Changed_Target);

      Delete_Tree_If_Present (Resume_Complete_416_Target);
      Limits := Sitefetch.Default_Fetch_Options;
      Limits.Cache.Mode := Sitefetch.Cache_Revalidate;
      Write_Binary_Test_File
        (Resume_Complete_416_Target & "/resume-416-complete.bin.sitefetch_part", Fixture_Resume_Body);
      Write_Test_File
        (Resume_Complete_416_Target & "/resume-416-complete.bin.sitefetch_part.sitefetch_http_cache",
         "URL: " & To_String (Base_URL) & "/resume-416-complete.bin" & Character'Val (10)
         & "Final-URL: " & To_String (Base_URL) & "/resume-416-complete.bin" & Character'Val (10)
         & "ETag: resume-v1" & Character'Val (10)
         & "Last-Modified: " & Character'Val (10));
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/resume-416-complete.bin", Resume_Complete_416_Target, Statistics, null, Limits),
         "matching 416 treats complete partial as successful streamed download");
      Assert
        (Read_File (Resume_Complete_416_Target & "/resume-416-complete.bin") = Fixture_Resume_Body,
         "matching 416 installs already-complete partial");
      Assert (Statistics.Bytes_Written = 0, "matching 416 reports zero newly written bytes");
      Delete_Tree_If_Present (Resume_Complete_416_Target);

      Delete_Tree_If_Present (Resume_Oversized_Target);
      Limits := Sitefetch.Default_Fetch_Options;
      Limits.Cache.Mode := Sitefetch.Cache_Revalidate;
      Write_Binary_Test_File
        (Resume_Oversized_Target & "/resume-oversized.bin.sitefetch_part", Fixture_Short_Resume_Body & "-STALE");
      Write_Test_File
        (Resume_Oversized_Target & "/resume-oversized.bin.sitefetch_part.sitefetch_http_cache",
         "URL: " & To_String (Base_URL) & "/resume-oversized.bin" & Character'Val (10)
         & "Final-URL: " & To_String (Base_URL) & "/resume-oversized.bin" & Character'Val (10)
         & "ETag: resume-v1" & Character'Val (10)
         & "Last-Modified: " & Character'Val (10));
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/resume-oversized.bin", Resume_Oversized_Target, Statistics, null, Limits),
         "oversized stale partial recovers with a full streamed download after 416");
      Assert
        (Read_File (Resume_Oversized_Target & "/resume-oversized.bin") = Fixture_Short_Resume_Body,
         "oversized stale partial is replaced by full remote body");
      Assert
        (not Ada.Directories.Exists (Resume_Oversized_Target & "/resume-oversized.bin.sitefetch_part"),
         "oversized stale partial is removed after recovery");
      Assert
        (Statistics.Bytes_Written = Fixture_Short_Resume_Body'Length,
         "oversized stale partial recovery counts the full replacement body");
      Delete_Tree_If_Present (Resume_Oversized_Target);

      Delete_Tree_If_Present (Resume_Corrupt_Partial_Target);
      Limits := Sitefetch.Default_Fetch_Options;
      Limits.Cache.Mode := Sitefetch.Cache_Revalidate;
      Limits.Diagnostics.Mode := Sitefetch.Diagnostics_Verbose;
      Write_Binary_Test_File (Resume_Corrupt_Partial_Target & "/resume.bin.sitefetch_part", "RESUME-");
      Write_Test_File
        (Resume_Corrupt_Partial_Target & "/resume.bin.sitefetch_part.sitefetch_http_cache",
         "Cache-Version: 2" & Character'Val (10)
         & "URL: " & To_String (Base_URL) & "/resume.bin" & Character'Val (10)
         & "Final-URL: " & To_String (Base_URL) & "/resume.bin" & Character'Val (10)
         & "ETag: resume-v1" & Character'Val (10)
         & "ETag-Weak: false" & Character'Val (10)
         & "Resume-Safe: true" & Character'Val (10)
         & "Local-Size: 999" & Character'Val (10)
         & "Local-Hash: stale" & Character'Val (10));
      Parallel_Progress.Reset;
      Assert
        (Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/resume.bin", Resume_Corrupt_Partial_Target, Statistics,
            Record_Parallel_Progress'Access, Limits),
         "corrupt partial integrity metadata suppresses resume and downloads fresh body");
      Assert
        (Parallel_Progress.Count (Sitefetch.Progress_Resume_Attempt) = 0,
         "corrupt partial integrity metadata emits no resume attempt");
      Assert
        (Read_File (Resume_Corrupt_Partial_Target & "/resume.bin") = Fixture_Resume_Body,
         "corrupt partial integrity metadata recovers with complete final file");
      Assert
        (Statistics.Bytes_Written = Fixture_Resume_Body'Length,
         "corrupt partial integrity recovery counts the full replacement body");
      Delete_Tree_If_Present (Resume_Corrupt_Partial_Target);

      Delete_Tree_If_Present (Partial_Strong_Target);
      Limits := Sitefetch.Default_Fetch_Options;
      Limits.Cache.Mode := Sitefetch.Cache_Revalidate;
      Assert
        (not Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/partial-strong.bin", Partial_Strong_Target, Statistics, null, Limits),
         "failed partial with strong ETag records retryable sidecar");
      declare
         Sidecar : constant String :=
           Read_File (Partial_Strong_Target & "/partial-strong.bin.sitefetch_part.sitefetch_http_cache");
      begin
         Assert
           (Ada.Strings.Fixed.Index (Sidecar, "ETag: partial-strong-v1") > 0,
            "partial sidecar records strong ETag");
         Assert
           (Ada.Strings.Fixed.Index (Sidecar, "ETag-Weak: false") > 0,
            "partial sidecar records strong ETag status");
         Assert
           (Ada.Strings.Fixed.Index (Sidecar, "Resume-Safe: true") > 0,
            "strong validator partial sidecar is resume-safe");
      end;
      Delete_Tree_If_Present (Partial_Strong_Target);

      Delete_Tree_If_Present (Partial_Weak_Target);
      Limits := Sitefetch.Default_Fetch_Options;
      Limits.Cache.Mode := Sitefetch.Cache_Revalidate;
      Assert
        (not Sitefetch.Crawler.Fetch_Website
           (To_String (Base_URL) & "/partial-weak.bin", Partial_Weak_Target, Statistics, null, Limits),
         "failed partial with weak ETag records non-resume-safe sidecar");
      declare
         Sidecar : constant String :=
           Read_File (Partial_Weak_Target & "/partial-weak.bin.sitefetch_part.sitefetch_http_cache");
      begin
         Assert
           (Ada.Strings.Fixed.Index (Sidecar, "ETag: W/""partial-weak-v1""") > 0,
            "partial sidecar records weak ETag");
         Assert
           (Ada.Strings.Fixed.Index (Sidecar, "ETag-Weak: true") > 0,
            "partial sidecar records weak ETag status");
         Assert
           (Ada.Strings.Fixed.Index (Sidecar, "Resume-Safe: false") > 0,
            "weak ETag partial sidecar is not resume-safe");
      end;
      Delete_Tree_If_Present (Partial_Weak_Target);

      Delete_Tree_If_Present (Cache_Binary_Target);

      Control.Stop;
   end Run_Test;



   procedure Add_Tests (Suite : AUnit.Test_Suites.Access_Test_Suite) is
   begin
      Suite.Add_Test (new Production_HTTP_Fixture_Test);
   end Add_Tests;
end Sitefetchlib_Production_HTTP_Tests;
