with Ada.Directories;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with AUnit.Assertions;
with AUnit.Simple_Test_Cases;
with AUnit.Test_Suites;

with Project_Tools.Files;

with Http_Client.Clients;
with Http_Client.Headers;
with GNAT.Sockets;
with Zlib;

with Sitefetch;
with Sitefetch.Crawler;
with Sitefetch.Client_Config;
with Sitefetch.Domains;
with Sitefetch.Testing;

with Sitefetchlib_Production_HTTP_Tests;

package body Sitefetchlib_Test_Suite is
   use Ada.Strings.Unbounded;
   use AUnit.Assertions;
   use type Sitefetch.Progress_Event;
   use type Zlib.Status_Code;

   type URL_Test is new AUnit.Simple_Test_Cases.Test_Case with null record;
   overriding function Name (Item : URL_Test) return AUnit.Message_String;
   overriding procedure Run_Test (Item : in out URL_Test);

   type Link_Extraction_Test is new AUnit.Simple_Test_Cases.Test_Case with null record;
   overriding function Name (Item : Link_Extraction_Test) return AUnit.Message_String;
   overriding procedure Run_Test (Item : in out Link_Extraction_Test);

   type Rewrite_Test is new AUnit.Simple_Test_Cases.Test_Case with null record;
   overriding function Name (Item : Rewrite_Test) return AUnit.Message_String;
   overriding procedure Run_Test (Item : in out Rewrite_Test);

   type Classification_Test is new AUnit.Simple_Test_Cases.Test_Case with null record;
   overriding function Name (Item : Classification_Test) return AUnit.Message_String;
   overriding procedure Run_Test (Item : in out Classification_Test);

   type Client_Config_Test is new AUnit.Simple_Test_Cases.Test_Case with null record;
   overriding function Name (Item : Client_Config_Test) return AUnit.Message_String;
   overriding procedure Run_Test (Item : in out Client_Config_Test);

   type Fetch_Engine_Test is new AUnit.Simple_Test_Cases.Test_Case with null record;
   overriding function Name (Item : Fetch_Engine_Test) return AUnit.Message_String;
   overriding procedure Run_Test (Item : in out Fetch_Engine_Test);

   type Parallel_Fetch_Test is new AUnit.Simple_Test_Cases.Test_Case with null record;
   overriding function Name (Item : Parallel_Fetch_Test) return AUnit.Message_String;
   overriding procedure Run_Test (Item : in out Parallel_Fetch_Test);

   type Direct_Download_Test is new AUnit.Simple_Test_Cases.Test_Case with null record;
   overriding function Name (Item : Direct_Download_Test) return AUnit.Message_String;
   overriding procedure Run_Test (Item : in out Direct_Download_Test);

   type Fake_Mode_Type is
     (Complete_Site,
      Cycle_Site,
      Missing_Root,
      Multiple_Missing_Links,
      Special_Refs);

   type Parallel_Mode_Type is
     (Parallel_Deduplicate,
      Parallel_Failure,
      Parallel_Final_Root);

   type Download_Mode_Type is
     (Download_Succeeds,
      Download_Fails,
      Download_Dangerous,
      Download_Byte_Limit);

   Current_Mode          : Fake_Mode_Type := Complete_Site;
   Current_Download_Mode : Download_Mode_Type := Download_Succeeds;
   Fetch_Count           : Natural := 0;
   Download_Count        : Natural := 0;
   Progress_Failed_Count : Natural := 0;
   Progress_Warning_Count : Natural := 0;
   Progress_Safety_Count : Natural := 0;
   Progress_Cache_Rejected_Count : Natural := 0;
   Progress_Cache_Revalidate_Count : Natural := 0;
   Last_Cache_Rejected_Progress : Unbounded_String := Null_Unbounded_String;
   Structured_Written_Count : Natural := 0;
   Last_Structured_Written_URL : Unbounded_String := Null_Unbounded_String;
   Last_Structured_Written_Local_Path : Unbounded_String := Null_Unbounded_String;
   Last_Structured_Written_Final_URL : Unbounded_String := Null_Unbounded_String;
   Last_Structured_Written_Bytes : Natural := 0;
   Last_Structured_Written_Depth : Natural := 0;
   Last_Failed_Progress  : Unbounded_String := Null_Unbounded_String;
   Last_Written_Progress : Unbounded_String := Null_Unbounded_String;
   Last_Download_URL     : Unbounded_String := Null_Unbounded_String;
   Last_Download_Path    : Unbounded_String := Null_Unbounded_String;
   External_Fetched      : Boolean := False;
   Special_Fetched       : Boolean := False;
   Priority_Page_Fetched : Boolean := False;
   Priority_Download_After_Page : Boolean := False;

   Download_Root_Document : constant String := "<a href=""/files/report.pdf"">report</a>";
   Download_Parallel_Document : constant String :=
     "<a href=""/files/report.pdf"">report</a><a href=""/ok.html"">ok</a>";
   Download_Byte_Limit_Document : constant String :=
     "<a href=""/files/report.pdf"">report</a><a href=""/files/extra.pdf"">extra</a>";
   Download_Ok_Text : constant String := "ok";
   Downloaded_Report_Text : constant String := "downloaded report";
   Downloaded_Extra_Report_Text : constant String := "downloaded extra report";
   Downloaded_Root_Report_Text : constant String := "downloaded root report";
   Downloaded_Tool_Text : constant String := "downloaded tool";

   function Simple_Callbacks
     (Fetcher : Sitefetch.Testing.Simple_Fetcher_Access)
      return Sitefetch.Testing.Fetch_Callbacks is
     ((Mode           => Sitefetch.Testing.Fetch_Simple,
       Simple_Fetcher => Fetcher,
       others         => <>));

   function Final_Callbacks
     (Fetcher    : Sitefetch.Testing.Final_Fetcher_Access;
      Downloader : Sitefetch.Testing.Direct_Downloader_Access := null)
      return Sitefetch.Testing.Fetch_Callbacks is
     ((Mode          => Sitefetch.Testing.Fetch_Final,
       Final_Fetcher => Fetcher,
       Downloader    => Downloader,
       others        => <>));

   function Parallel_Callbacks
     (Fetcher    : Sitefetch.Testing.Parallel_Fetcher_Access;
      Downloader : Sitefetch.Testing.Direct_Downloader_Access := null)
      return Sitefetch.Testing.Fetch_Callbacks is
     ((Mode             => Sitefetch.Testing.Fetch_Parallel,
       Parallel_Fetcher => Fetcher,
       Downloader       => Downloader,
       others           => <>));

   procedure Delete_Tree_If_Present (Path : String) is
   begin
      Project_Tools.Files.Delete_Tree (Path);
   end Delete_Tree_If_Present;

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

   function Contains_Fragment (Text : String; Fragment : String) return Boolean is
   begin
      return Fragment'Length = 0 or else Ada.Strings.Fixed.Index (Text, Fragment) > 0;
   end Contains_Fragment;

   procedure Remove_Metadata_Line (Path : String; Prefix : String) is
      Input  : constant String := Read_File (Path);
      Output : Unbounded_String := Null_Unbounded_String;
      First  : Natural := Input'First;
      Last   : Natural;
   begin
      while First <= Input'Last loop
         Last := First;
         while Last <= Input'Last and then Input (Last) /= Character'Val (10) loop
            Last := Last + 1;
         end loop;

         declare
            Line_Last : constant Natural := (if Last <= Input'Last then Last - 1 else Input'Last);
            Line      : constant String :=
              (if Line_Last >= First then Input (First .. Line_Last) else "");
         begin
            if Line'Length < Prefix'Length
              or else Line (Line'First .. Line'First + Prefix'Length - 1) /= Prefix
            then
               Append (Output, Line);
               Append (Output, Character'Val (10));
            end if;
         end;

         First := Last + 1;
      end loop;

      Write_Test_File (Path, To_String (Output));
   end Remove_Metadata_Line;

   procedure Reset_Structured_Progress is
   begin
      Structured_Written_Count := 0;
      Last_Structured_Written_URL := Null_Unbounded_String;
      Last_Structured_Written_Local_Path := Null_Unbounded_String;
      Last_Structured_Written_Final_URL := Null_Unbounded_String;
      Last_Structured_Written_Bytes := 0;
      Last_Structured_Written_Depth := 0;
   end Reset_Structured_Progress;

   procedure Record_Structured_Progress (Progress : Sitefetch.Progress_Record) is
   begin
      if Progress.Event = Sitefetch.Progress_Written then
         Structured_Written_Count := Structured_Written_Count + 1;
         Last_Structured_Written_URL := Progress.URL;
         Last_Structured_Written_Local_Path := Progress.Local_Path;
         Last_Structured_Written_Final_URL := Progress.Final_URL;
         Last_Structured_Written_Bytes := Progress.Bytes_Written;
         Last_Structured_Written_Depth := Progress.Depth;
      end if;
   end Record_Structured_Progress;

   procedure Record_Progress (Event : Sitefetch.Progress_Event; URL : String) is
   begin
      case Event is
         when Sitefetch.Progress_Failed =>
            Progress_Failed_Count := Progress_Failed_Count + 1;
            Last_Failed_Progress := To_Unbounded_String (URL);
         when Sitefetch.Progress_Written =>
            Last_Written_Progress := To_Unbounded_String (URL);
         when Sitefetch.Progress_Warning_Dangerous =>
            Progress_Warning_Count := Progress_Warning_Count + 1;
         when Sitefetch.Progress_Skipped_Dangerous =>
            Progress_Safety_Count := Progress_Safety_Count + 1;
         when Sitefetch.Progress_Cache_Rejected =>
            Progress_Cache_Rejected_Count := Progress_Cache_Rejected_Count + 1;
            Last_Cache_Rejected_Progress := To_Unbounded_String (URL);
         when Sitefetch.Progress_Cache_Revalidate =>
            Progress_Cache_Revalidate_Count := Progress_Cache_Revalidate_Count + 1;
         when others =>
            null;
      end case;
   end Record_Progress;

   procedure Reset_Fake (Mode : Fake_Mode_Type) is
   begin
      Current_Mode := Mode;
      Fetch_Count := 0;
      External_Fetched := False;
      Special_Fetched := False;
   end Reset_Fake;

   procedure Reset_Download_Fake (Mode : Download_Mode_Type) is
   begin
      Current_Download_Mode := Mode;
      Fetch_Count := 0;
      Download_Count := 0;
      Progress_Failed_Count := 0;
      Progress_Warning_Count := 0;
      Progress_Safety_Count := 0;
      Progress_Cache_Rejected_Count := 0;
      Progress_Cache_Revalidate_Count := 0;
      Last_Cache_Rejected_Progress := Null_Unbounded_String;
      Last_Failed_Progress := Null_Unbounded_String;
      Last_Written_Progress := Null_Unbounded_String;
      Last_Download_URL := Null_Unbounded_String;
      Last_Download_Path := Null_Unbounded_String;
      Priority_Page_Fetched := False;
      Priority_Download_After_Page := False;
   end Reset_Download_Fake;

   protected type Cache_Fixture_Control is
      entry Wait_Ready (Port : out GNAT.Sockets.Port_Type);
      procedure Set_Port (Port : GNAT.Sockets.Port_Type);
      procedure Stop;
      procedure Record_Request (Path : String);
      function Stopped return Boolean;
      function Fresh_Count return Natural;
      function Vary_Count return Natural;
      function Stale_Count return Natural;
      function Download_Fresh_Count return Natural;
      function Download_Stale_Count return Natural;
      function Download_Partial_Count return Natural;
   private
      Ready       : Boolean := False;
      Stop_Flag   : Boolean := False;
      Listen_Port : GNAT.Sockets.Port_Type := 0;
      Fresh_Requests : Natural := 0;
      Vary_Requests  : Natural := 0;
      Stale_Requests : Natural := 0;
      Download_Fresh_Requests : Natural := 0;
      Download_Stale_Requests : Natural := 0;
      Download_Partial_Requests : Natural := 0;
   end Cache_Fixture_Control;

   protected body Cache_Fixture_Control is
      entry Wait_Ready (Port : out GNAT.Sockets.Port_Type) when Ready is
      begin
         Port := Listen_Port;
      end Wait_Ready;

      procedure Set_Port (Port : GNAT.Sockets.Port_Type) is
      begin
         Listen_Port := Port;
         Ready := True;
      end Set_Port;

      procedure Stop is
      begin
         Stop_Flag := True;
      end Stop;

      procedure Record_Request (Path : String) is
      begin
         if Path = "/cache-fresh.html" then
            Fresh_Requests := Fresh_Requests + 1;
         elsif Path = "/cache-vary.html" then
            Vary_Requests := Vary_Requests + 1;
         elsif Path = "/cache-stale-no-validator.html" then
            Stale_Requests := Stale_Requests + 1;
         elsif Path = "/cache-fresh.pdf" then
            Download_Fresh_Requests := Download_Fresh_Requests + 1;
         elsif Path = "/cache-stale.pdf" then
            Download_Stale_Requests := Download_Stale_Requests + 1;
         elsif Path = "/cache-partial.pdf" then
            Download_Partial_Requests := Download_Partial_Requests + 1;
         end if;
      end Record_Request;

      function Stopped return Boolean is
      begin
         return Stop_Flag;
      end Stopped;

      function Fresh_Count return Natural is
      begin
         return Fresh_Requests;
      end Fresh_Count;

      function Vary_Count return Natural is
      begin
         return Vary_Requests;
      end Vary_Count;

      function Stale_Count return Natural is
      begin
         return Stale_Requests;
      end Stale_Count;

      function Download_Fresh_Count return Natural is
      begin
         return Download_Fresh_Requests;
      end Download_Fresh_Count;

      function Download_Stale_Count return Natural is
      begin
         return Download_Stale_Requests;
      end Download_Stale_Count;

      function Download_Partial_Count return Natural is
      begin
         return Download_Partial_Requests;
      end Download_Partial_Count;
   end Cache_Fixture_Control;

   task type Cache_Fixture_Server (Control : not null access Cache_Fixture_Control);

   task body Cache_Fixture_Server is
      use type Ada.Streams.Stream_Element_Offset;
      use type GNAT.Sockets.Selector_Status;

      CRLF       : constant String := Character'Val (13) & Character'Val (10);
      Cache_Body : constant String := "stale cache";
      Fresh_Body : constant String := "fresh cache";
      Vary_Body  : constant String := "vary cache";
      Fresh_Download_Body  : constant String := "fresh download";
      Stale_Download_Body  : constant String := "stale download";
      Partial_Download_Body : constant String := "partial download";
      Server     : GNAT.Sockets.Socket_Type;
      Client     : GNAT.Sockets.Socket_Type;
      Address    : GNAT.Sockets.Sock_Addr_Type;
      Peer       : GNAT.Sockets.Sock_Addr_Type;
      Status     : GNAT.Sockets.Selector_Status;
      Idle_Count : Natural := 0;

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
            & "Content-Length: " & Ada.Strings.Fixed.Trim (Natural'Image (Body_Text'Length), Ada.Strings.Both) & CRLF
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

      procedure Handle (Socket : GNAT.Sockets.Socket_Type) is
         Request : constant String := Request_Text (Socket);
         Method  : constant String := Request_Method (Request);
         Path    : constant String := Request_Path (Request);
      begin
         Control.Record_Request (Path);
         if Path = "/cache-stale-no-validator.html" then
            Respond
              (Socket, Method, "HTTP/1.1 200 OK", "text/html", Cache_Body,
               "Cache-Control: max-age=0" & CRLF);
         elsif Path = "/cache-fresh.html" then
            Respond
              (Socket, Method, "HTTP/1.1 200 OK", "text/html", Fresh_Body,
               "Cache-Control: max-age=3600" & CRLF);
         elsif Path = "/cache-vary.html" then
            Respond
              (Socket, Method, "HTTP/1.1 200 OK", "text/html", Vary_Body,
               "Cache-Control: max-age=3600" & CRLF
               & "Vary: Accept-Language" & CRLF);
         elsif Path = "/cache-fresh.pdf" then
            Respond
              (Socket, Method, "HTTP/1.1 200 OK", "application/pdf", Fresh_Download_Body,
               "Cache-Control: max-age=3600" & CRLF);
         elsif Path = "/cache-stale.pdf" then
            Respond
              (Socket, Method, "HTTP/1.1 200 OK", "application/pdf", Stale_Download_Body,
               "Cache-Control: max-age=0" & CRLF);
         elsif Path = "/cache-partial.pdf" then
            Respond
              (Socket, Method, "HTTP/1.1 200 OK", "application/pdf", Partial_Download_Body,
               "Cache-Control: max-age=3600" & CRLF
               & "ETag: ""partial-v1""" & CRLF);
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
   end Cache_Fixture_Server;

   function Fake_Fetch (URL : String; Document_Text : out Unbounded_String) return Boolean is
   begin
      Fetch_Count := Fetch_Count + 1;
      if URL = "https://external.example/x" then
         External_Fetched := True;
         Document_Text := Null_Unbounded_String;
         return False;
      elsif URL = "https://special.example/mailto:team@example.com"
        or else URL = "https://special.example/javascript:void_0_"
        or else URL = "https://special.example/data:text_plain_demo"
      then
         Special_Fetched := True;
         Document_Text := Null_Unbounded_String;
         return False;
      end if;

      case Current_Mode is
         when Complete_Site =>
            if URL = "https://example.com" or else URL = "https://example.com/" then
               Document_Text := To_Unbounded_String
                 ("<a href=""/about.html"">about</a>"
                  & "<link href=""https://example.com/assets/app.css"">"
                  & "<script src=""https://assets.example.com/sub/app.js""></script>"
                  & "<a href=""https://external.example/x"">external</a>");
               return True;
            elsif URL = "https://example.com/about.html" then
               Document_Text := To_Unbounded_String ("<a href=""/"">home</a><img src=""/img/logo.png"">");
               return True;
            elsif URL = "https://example.com/assets/app.css" then
               Document_Text := To_Unbounded_String ("body {}");
               return True;
            elsif URL = "https://assets.example.com/sub/app.js" then
               Document_Text := To_Unbounded_String ("asset");
               return True;
            elsif URL = "https://example.com/img/logo.png" then
               Document_Text := To_Unbounded_String ("image-bytes");
               return True;
            end if;
         when Cycle_Site =>
            if URL = "https://cycle.example/" then
               Document_Text := To_Unbounded_String ("<a href=""/a.html"">a</a>");
               return True;
            elsif URL = "https://cycle.example/a.html" then
               Document_Text := To_Unbounded_String ("<a href=""/"">home</a>");
               return True;
            end if;
         when Missing_Root =>
            null;
         when Multiple_Missing_Links =>
            if URL = "https://multi-missing.example/" then
               Document_Text := To_Unbounded_String
                 ("<a href=""/missing-one.html"">missing one</a>"
                  & "<a href=""/inside.html"">inside</a>"
                  & "<a href=""/missing-two.html"">missing two</a>");
               return True;
            elsif URL = "https://multi-missing.example/inside.html" then
               Document_Text := To_Unbounded_String ("inside");
               return True;
            end if;
         when Special_Refs =>
            if URL = "https://special.example/" or else URL = "https://special.example" then
               Document_Text := To_Unbounded_String
                 ("<a href=""#top"">top</a>"
                  & "<a href=""mailto:team@example.com"">mail</a>"
                  & "<a href=""javascript:void(0)"">script</a>"
                  & "<img src=""data:text/plain,demo"">"
                  & "<a href=""/inside.html"">inside</a>");
               return True;
            elsif URL = "https://special.example/inside.html" then
               Document_Text := To_Unbounded_String ("inside");
               return True;
            end if;
      end case;

      Document_Text := Null_Unbounded_String;
      return False;
   end Fake_Fetch;

   function Fake_Final_Fetch
     (URL           : String;
      Document_Text : out Unbounded_String;
      Final_URL     : out Unbounded_String) return Boolean
   is
   begin
      Fetch_Count := Fetch_Count + 1;
      Final_URL := To_Unbounded_String (URL);
      if URL = "https://redirect.example/" then
         Document_Text := To_Unbounded_String
           ("<a href=""/about.html"">about</a>"
            & "<a href=""https://redirect.example/old.html"">old</a>");
         Final_URL := To_Unbounded_String ("https://www.redirect.example/start/");
         return True;
      elsif URL = "https://www.redirect.example/about.html" then
         Document_Text := To_Unbounded_String ("about");
         return True;
      elsif URL = "https://redirect.example/old.html" then
         Document_Text := To_Unbounded_String ("old");
         return True;
      end if;
      Document_Text := Null_Unbounded_String;
      Final_URL := Null_Unbounded_String;
      return False;
   end Fake_Final_Fetch;

   function Real_World_Fixture_Fetch
     (URL           : String;
      Document_Text : out Unbounded_String;
      Final_URL     : out Unbounded_String) return Boolean
   is
   begin
      Fetch_Count := Fetch_Count + 1;
      Final_URL := To_Unbounded_String (URL);
      if URL = "https://fixtures.example/" then
         Final_URL := To_Unbounded_String ("https://www.fixtures.example/start/");
         Document_Text := To_Unbounded_String
           ("<link href=""/style.css"">"
            & "<img srcset=""/img/small.png 1x, /img/large.png 2x"">"
            & "<link href=""/sitemap-index.xml"">"
            & "<a href=""/asset?id=1"">one</a><a href=""/asset?id=2"">two</a>");
         return True;
      elsif URL = "https://www.fixtures.example/style.css" then
         Document_Text := To_Unbounded_String
           ("@import ""/theme.css"";.hero{background:url('/img/bg.png')}@font-face{src:url(/font)}");
         return True;
      elsif URL = "https://www.fixtures.example/theme.css" then
         Document_Text := To_Unbounded_String (".theme{color:blue}");
         return True;
      elsif URL = "https://www.fixtures.example/sitemap-index.xml" then
         Document_Text := To_Unbounded_String
           ("<?xml version=""1.0""?><sm:sitemapindex xmlns:sm=""http://www.sitemaps.org/schemas/sitemap/0.9"">"
            & "<sm:sitemap><sm:loc>https://www.fixtures.example/sitemap-pages.xml"
            & "?from=index&amp;lang=en</sm:loc></sm:sitemap>"
            & "<sm:sitemap><sm:loc>https://www.fixtures.example/sitemap-compressed.xml.gz"
            & "</sm:loc></sm:sitemap>"
            & "</sm:sitemapindex>");
         return True;
      elsif URL = "https://www.fixtures.example/sitemap-pages.xml?from=index&lang=en" then
         Document_Text := To_Unbounded_String
           ("<?xml version=""1.0""?><urlset xmlns=""http://www.sitemaps.org/schemas/sitemap/0.9"">"
            & "<url><loc><![CDATA[https://www.fixtures.example/from-sitemap.html]]></loc></url></urlset>");
         return True;
      elsif URL = "https://www.fixtures.example/sitemap-compressed.xml.gz" then
         Document_Text := To_Unbounded_String
           (GZip_Text
              ("<?xml version=""1.0""?><urlset xmlns=""http://www.sitemaps.org/schemas/sitemap/0.9"">"
               & "<url><loc>https://www.fixtures.example/from-gzip-sitemap.html</loc></url></urlset>"));
         return True;
      elsif URL = "https://www.fixtures.example/from-sitemap.html"
        or else URL = "https://www.fixtures.example/from-gzip-sitemap.html"
        or else URL = "https://www.fixtures.example/img/small.png"
        or else URL = "https://www.fixtures.example/img/large.png"
        or else URL = "https://www.fixtures.example/img/bg.png"
        or else URL = "https://www.fixtures.example/font"
        or else URL = "https://www.fixtures.example/asset?id=1"
        or else URL = "https://www.fixtures.example/asset?id=2"
      then
         Document_Text := To_Unbounded_String ("asset:" & URL);
         return True;
      elsif URL = "https://writefail.example/" then
         Document_Text := To_Unbounded_String ("<a href=""/blocker/file.html"">blocked</a>");
         return True;
      elsif URL = "https://writefail.example/blocker/file.html" then
         Document_Text := To_Unbounded_String ("blocked");
         return True;
      end if;
      Document_Text := Null_Unbounded_String;
      Final_URL := Null_Unbounded_String;
      return False;
   end Real_World_Fixture_Fetch;

   protected Parallel_Fake is
      procedure Reset (Mode : Parallel_Mode_Type);
      procedure Fetch
        (URL            : String;
         Document_Text  : out Unbounded_String;
         Final_URL      : out Unbounded_String;
         Failure_Reason : out Unbounded_String;
         Success        : out Boolean);
      function Count (URL : String) return Natural;
   private
      Current_Parallel_Mode : Parallel_Mode_Type := Parallel_Deduplicate;
      Root_Count    : Natural := 0;
      A_Count       : Natural := 0;
      B_Count       : Natural := 0;
      Shared_Count  : Natural := 0;
      Missing_Count : Natural := 0;
      Ok_Count      : Natural := 0;
   end Parallel_Fake;

   protected body Parallel_Fake is
      procedure Reset (Mode : Parallel_Mode_Type) is
      begin
         Current_Parallel_Mode := Mode;
         Root_Count := 0;
         A_Count := 0;
         B_Count := 0;
         Shared_Count := 0;
         Missing_Count := 0;
         Ok_Count := 0;
      end Reset;

      procedure Fetch
        (URL            : String;
         Document_Text  : out Unbounded_String;
         Final_URL      : out Unbounded_String;
         Failure_Reason : out Unbounded_String;
         Success        : out Boolean)
      is
      begin
         Final_URL := To_Unbounded_String (URL);
         Failure_Reason := Null_Unbounded_String;
         Success := True;
         if URL = "https://parallel.example/" then
            Root_Count := Root_Count + 1;
            case Current_Parallel_Mode is
               when Parallel_Deduplicate =>
                  Document_Text := To_Unbounded_String
                    ("<a href=""/a.html"">a</a><a href=""/b.html"">b</a>");
               when Parallel_Failure =>
                  Document_Text := To_Unbounded_String
                    ("<a href=""/missing.html"">missing</a><a href=""/ok.html"">ok</a>");
               when Parallel_Final_Root =>
                  Final_URL := To_Unbounded_String ("https://www.parallel.example/start/");
                  Document_Text := To_Unbounded_String
                    ("<a href=""/inside.html"">inside</a>"
                     & "<a href=""https://parallel.example/old.html"">old</a>");
            end case;
         elsif URL = "https://parallel.example/a.html" then
            A_Count := A_Count + 1;
            Document_Text := To_Unbounded_String ("<a href=""/shared.html"">shared</a>");
         elsif URL = "https://parallel.example/b.html" then
            B_Count := B_Count + 1;
            Document_Text := To_Unbounded_String ("<a href=""/shared.html"">shared</a>");
         elsif URL = "https://parallel.example/shared.html" then
            Shared_Count := Shared_Count + 1;
            Document_Text := To_Unbounded_String ("shared");
         elsif URL = "https://parallel.example/ok.html" then
            Ok_Count := Ok_Count + 1;
            Document_Text := To_Unbounded_String ("ok");
         elsif URL = "https://parallel.example/missing.html" then
            Missing_Count := Missing_Count + 1;
            Document_Text := Null_Unbounded_String;
            Failure_Reason := To_Unbounded_String ("MISSING_PARALLEL");
            Success := False;
         elsif URL = "https://www.parallel.example/inside.html" then
            A_Count := A_Count + 1;
            Final_URL := To_Unbounded_String ("https://www.parallel.example/renamed/inside.html");
            Document_Text := To_Unbounded_String ("<a href=""https://parallel.example/old.html"">old</a>");
         else
            Document_Text := Null_Unbounded_String;
            Failure_Reason := To_Unbounded_String ("UNEXPECTED_PARALLEL_URL");
            Success := False;
         end if;
      end Fetch;

      function Count (URL : String) return Natural is
      begin
         if URL = "https://parallel.example/shared.html" then
            return Shared_Count;
         elsif URL = "https://parallel.example/missing.html" then
            return Missing_Count;
         elsif URL = "https://parallel.example/ok.html" then
            return Ok_Count;
         elsif URL = "https://parallel.example/" then
            return Root_Count;
         elsif URL = "https://parallel.example/a.html" then
            return A_Count;
         elsif URL = "https://parallel.example/b.html" then
            return B_Count;
         else
            return 0;
         end if;
      end Count;
   end Parallel_Fake;

   function Parallel_Fetch
     (Fetch_URL      : String;
      Document_Text  : out Unbounded_String;
      Final_URL      : out Unbounded_String;
      Failure_Reason : out Unbounded_String) return Boolean
   is
      Success : Boolean;
   begin
      Parallel_Fake.Fetch (Fetch_URL, Document_Text, Final_URL, Failure_Reason, Success);
      return Success;
   end Parallel_Fetch;

   function Fake_Parallel_Download_Fetch
     (URL            : String;
      Document_Text  : out Unbounded_String;
      Final_URL      : out Unbounded_String;
      Failure_Reason : out Unbounded_String) return Boolean
   is
   begin
      Fetch_Count := Fetch_Count + 1;
      Final_URL := To_Unbounded_String (URL);
      Failure_Reason := Null_Unbounded_String;
      if URL = "https://download.example/" then
         if Current_Download_Mode = Download_Dangerous then
            Document_Text := To_Unbounded_String ("<a href=""/files/tool.exe"">tool</a><a href=""/ok.html"">ok</a>");
         elsif Current_Download_Mode = Download_Byte_Limit then
            Document_Text := To_Unbounded_String (Download_Byte_Limit_Document);
         else
            Document_Text := To_Unbounded_String (Download_Parallel_Document);
         end if;
         return True;
      elsif URL = "https://download.example/ok.html" then
         Document_Text := To_Unbounded_String (Download_Ok_Text);
         Priority_Page_Fetched := True;
         return True;
      end if;
      Document_Text := Null_Unbounded_String;
      Failure_Reason := To_Unbounded_String ("UNEXPECTED_PARALLEL_DOWNLOAD_FETCH");
      return False;
   end Fake_Parallel_Download_Fetch;

   function Fake_Download_Final_Fetch
     (URL           : String;
      Document_Text : out Unbounded_String;
      Final_URL     : out Unbounded_String) return Boolean
   is
   begin
      Fetch_Count := Fetch_Count + 1;
      Final_URL := To_Unbounded_String (URL);
      if URL = "https://download.example/" then
         if Current_Download_Mode = Download_Dangerous then
            Document_Text := To_Unbounded_String ("<a href=""/files/tool.exe"">tool</a>");
         elsif Current_Download_Mode = Download_Fails then
            Document_Text := To_Unbounded_String ("<a href=""/files/broken.pdf"">broken</a>");
         else
            Document_Text := To_Unbounded_String (Download_Root_Document);
         end if;
         return True;
      end if;
      Document_Text := Null_Unbounded_String;
      Final_URL := Null_Unbounded_String;
      return False;
   end Fake_Download_Final_Fetch;

   function Fake_Direct_Downloader
     (Fetch_URL      : String;
      Target_Path    : String;
      Final_URL      : out Unbounded_String;
      Failure_Reason : out Unbounded_String;
      Bytes_Written  : out Natural) return Boolean
   is
   begin
      Download_Count := Download_Count + 1;
      Last_Download_URL := To_Unbounded_String (Fetch_URL);
      Last_Download_Path := To_Unbounded_String (Target_Path);
      Bytes_Written := 0;

      if Current_Download_Mode in Download_Succeeds | Download_Byte_Limit
        and then Fetch_URL = "https://download.example/files/report.pdf"
      then
         if Current_Download_Mode = Download_Byte_Limit then
            Priority_Download_After_Page := Priority_Page_Fetched;
         end if;
         Write_Test_File (Target_Path, Downloaded_Report_Text);
         Bytes_Written := Downloaded_Report_Text'Length;
         Final_URL := To_Unbounded_String ("https://download.example/assets/final-report.pdf");
         Failure_Reason := Null_Unbounded_String;
         return True;
      elsif Current_Download_Mode = Download_Byte_Limit
        and then Fetch_URL = "https://download.example/files/extra.pdf"
      then
         Write_Test_File (Target_Path, Downloaded_Extra_Report_Text);
         Bytes_Written := Downloaded_Extra_Report_Text'Length;
         Final_URL := To_Unbounded_String (Fetch_URL);
         Failure_Reason := Null_Unbounded_String;
         return True;
      elsif Current_Download_Mode = Download_Succeeds
        and then Fetch_URL = "https://download.example/root.pdf"
      then
         Write_Test_File (Target_Path, Downloaded_Root_Report_Text);
         Bytes_Written := Downloaded_Root_Report_Text'Length;
         Final_URL := To_Unbounded_String ("https://download.example/assets/root-final.pdf");
         Failure_Reason := Null_Unbounded_String;
         return True;
      elsif Current_Download_Mode = Download_Dangerous
        and then Fetch_URL = "https://download.example/files/tool.exe"
      then
         Write_Test_File (Target_Path, Downloaded_Tool_Text);
         Bytes_Written := Downloaded_Tool_Text'Length;
         Final_URL := To_Unbounded_String (Fetch_URL);
         Failure_Reason := Null_Unbounded_String;
         return True;
      elsif Current_Download_Mode = Download_Fails
        and then Fetch_URL = "https://download.example/files/broken.pdf"
      then
         Final_URL := Null_Unbounded_String;
         Failure_Reason := To_Unbounded_String ("BROKEN_DOWNLOAD");
         return False;
      end if;

      Final_URL := Null_Unbounded_String;
      Failure_Reason := To_Unbounded_String ("UNEXPECTED_DOWNLOAD");
      return False;
   end Fake_Direct_Downloader;

   overriding function Name (Item : URL_Test) return AUnit.Message_String is
   begin
      pragma Unreferenced (Item);
      return AUnit.Format ("URL and domain helpers");
   end Name;

   overriding function Name (Item : Link_Extraction_Test) return AUnit.Message_String is
   begin
      pragma Unreferenced (Item);
      return AUnit.Format ("Link extraction");
   end Name;

   overriding function Name (Item : Rewrite_Test) return AUnit.Message_String is
   begin
      pragma Unreferenced (Item);
      return AUnit.Format ("Document rewriting");
   end Name;

   overriding function Name (Item : Classification_Test) return AUnit.Message_String is
   begin
      pragma Unreferenced (Item);
      return AUnit.Format ("Content classification");
   end Name;

   overriding function Name (Item : Client_Config_Test) return AUnit.Message_String is
   begin
      pragma Unreferenced (Item);
      return AUnit.Format ("HTTP client configuration");
   end Name;

   overriding function Name (Item : Fetch_Engine_Test) return AUnit.Message_String is
   begin
      pragma Unreferenced (Item);
      return AUnit.Format ("Fetch engine integration");
   end Name;

   overriding function Name (Item : Parallel_Fetch_Test) return AUnit.Message_String is
   begin
      pragma Unreferenced (Item);
      return AUnit.Format ("Parallel fetch integration");
   end Name;

   overriding function Name (Item : Direct_Download_Test) return AUnit.Message_String is
   begin
      pragma Unreferenced (Item);
      return AUnit.Format ("Direct download integration");
   end Name;

   overriding procedure Run_Test (Item : in out URL_Test) is
      pragma Unreferenced (Item);
   begin
      Assert (Sitefetch.Ensure_HTTP_Scheme ("example.com") = "http://example.com",
              "missing scheme receives http");
      Assert (Sitefetch.Testing.Domain_Of ("https://Example.COM:443/path") = "example.com",
              "domain is normalized");
      Assert (Sitefetch.Testing.Domain_Of ("https://user:pass@Example.COM:443/path") = "example.com",
              "userinfo is removed from domain");
      Assert (Sitefetch.Testing.Resolve_URL ("https://example.com/a/b/page.html", "../asset.css")
              = "https://example.com/a/asset.css",
              "relative URL resolves against base path");
      Assert (Sitefetch.Testing.Canonical_URL ("HTTPS://Example.COM:443/a/./b/../c.html#frag")
              = "https://example.com/a/c.html",
              "canonical URL normalizes scheme host path and fragment");
      Assert (Sitefetch.Testing.Local_Path_For_URL ("https://example.com/assets/app.css?x=1")
              = "assets/app__q9265.css",
              "query is included as a collision-resistant local path suffix");
      Assert (Sitefetch.Testing.Local_Path_For_URL ("https://example.com/docs/") = "docs/index.html",
              "directory URLs map to index documents");
      Assert (Sitefetch.Domains.Public_Suffix ("www.example.co.uk") = "co.uk",
              "multi-label public suffix is recognized");
      Assert (Sitefetch.Domains.Registrable_Domain ("www.example.co.uk") = "example.co.uk",
              "registrable domain is derived above public suffix");
      Assert (Sitefetch.Domains.Public_Suffix_For_Normalized_Host ("www.example.co.uk") = "co.uk",
              "normalized-host suffix helper recognizes multi-label suffix");
      Assert
        (Sitefetch.Domains.Registrable_Domain_For_Normalized_Host ("www.example.co.uk")
         = "example.co.uk",
         "normalized-host registrable helper derives domain above suffix");
      Assert
        (Sitefetch.Domains.Is_Internal_Host
           ("example.com", "assets.example.com", Sitefetch.Domain_Exact_And_Subdomains),
         "normalized-host internal helper accepts subdomains");
      Assert
        (not Sitefetch.Domains.Is_Internal_Host
           ("192.0.2.1", "x.192.0.2.1", Sitefetch.Domain_Exact_And_Subdomains),
         "normalized-host helper treats IP-like roots as exact-only");
      Assert
        (not Sitefetch.Domains.Is_Internal
           ("co.uk", "https://example.co.uk/a", Sitefetch.Domain_Exact_And_Subdomains),
         "public suffix roots are exact-only");
      Assert
        (Sitefetch.Domains.Is_Internal
           ("example.com", "https://assets.example.com/a", Sitefetch.Domain_Exact_And_Subdomains),
         "subdomain of registrable root is internal");
      Assert
        (not Sitefetch.Domains.Is_Internal
           ("example.com", "https://example.com.evil.test/a", Sitefetch.Domain_Exact_And_Subdomains),
         "deceptive host suffix is external");
      Assert
        (Sitefetch.Domains.Is_Internal
           ("EXAMPLE.COM", "https://Assets.Example.Com/a", Sitefetch.Domain_Exact_And_Subdomains),
         "domain policy is case-insensitive after normalization");
      Assert
        (Sitefetch.Domains.Is_Internal
           ("xn--bcher-kva.example", "https://img.xn--bcher-kva.example/a",
            Sitefetch.Domain_Exact_And_Subdomains),
         "punycode hosts use ordinary dot-boundary matching");
      Assert
        (not Sitefetch.Domains.Is_Internal
           ("xn--bcher-kva.example", "https://xn--bcher-kva.example.evil.test/a",
            Sitefetch.Domain_Exact_And_Subdomains),
         "punycode deceptive host suffix is external");
      Assert
        (not Sitefetch.Domains.Is_Internal
           ("b" & Character'Val (195) & Character'Val (188) & "cher.example",
            "https://img.xn--bcher-kva.example/a",
            Sitefetch.Domain_Exact_And_Subdomains),
         "raw non-ASCII root host is rejected instead of IDNA-normalized implicitly");
      Assert
        (not Sitefetch.Domains.Is_Internal
           ("xn--bcher-kva.example",
            "https://b" & Character'Val (195) & Character'Val (188) & "cher.example/a",
            Sitefetch.Domain_Exact_And_Subdomains),
         "raw non-ASCII candidate host is rejected instead of IDNA-normalized implicitly");
      Assert (Sitefetch.Domains.Public_Suffix ("bad_host.example") = "",
              "public suffix rejects malformed DNS host labels");
      Assert (Sitefetch.Domains.Registrable_Domain ("bad_host.example") = "",
              "registrable domain rejects malformed DNS host labels");
      Assert
        (not Sitefetch.Domains.Is_Internal
           ("example.com", "https://bad_host.example.com/a", Sitefetch.Domain_Exact_And_Subdomains),
         "candidate host with underscore is external");
      Assert
        (not Sitefetch.Domains.Is_Internal
           ("example.com", "https://-bad.example.com/a", Sitefetch.Domain_Exact_And_Subdomains),
         "candidate host with leading hyphen label is external");
      Assert
        (not Sitefetch.Domains.Is_Internal
           ("example.com", "https://bad-.example.com/a", Sitefetch.Domain_Exact_And_Subdomains),
         "candidate host with trailing hyphen label is external");
      Assert
        (not Sitefetch.Domains.Is_Internal
           ("example.com", "https://bad..example.com/a", Sitefetch.Domain_Exact_And_Subdomains),
         "candidate host with empty label is external");
      Assert
        (Sitefetch.Domains.Is_Internal
           ("192.0.2.1", "http://192.0.2.1/a", Sitefetch.Domain_Exact_And_Subdomains),
         "IPv4 literal root matches itself");
      Assert
        (not Sitefetch.Domains.Is_Internal
           ("192.0.2.1", "http://x.192.0.2.1/a", Sitefetch.Domain_Exact_And_Subdomains),
         "IPv4 literal root is exact-only");
      Assert
        (Sitefetch.Domains.Is_Internal
           ("http://[2001:db8::1]/", "http://[2001:db8::1]/a",
            Sitefetch.Domain_Exact_And_Subdomains),
         "IPv6 literal root matches itself");
      Assert
        (not Sitefetch.Domains.Is_Internal
           ("github.io", "https://user.github.io/a", Sitefetch.Domain_Exact_And_Subdomains),
         "hosted-service suffix root is exact-only");
      Assert (Sitefetch.Domains.Registrable_Domain ("user.github.io") = "user.github.io",
              "hosted-service tenant is registrable");
      Assert
        (not Sitefetch.Domains.Is_Internal
           ("user.github.io", "https://other.github.io/a", Sitefetch.Domain_Exact_And_Subdomains),
         "hosted-service sibling tenant is external");
      Assert
        (Sitefetch.Domains.Is_Internal
           ("user.github.io", "https://assets.user.github.io/a",
            Sitefetch.Domain_Exact_And_Subdomains),
         "hosted-service tenant subdomain is internal");
      Assert
        (not Sitefetch.Domains.Is_Internal
           ("www.example.co.uk", "https://example.co.uk/a", Sitefetch.Domain_Exact_And_Subdomains),
         "parent registrable domain is external by default");
      Assert
        (Sitefetch.Domains.Is_Internal
           ("www.example.co.uk", "https://example.co.uk/a", Sitefetch.Domain_Include_Parents),
         "parent registrable domain can be opted in");
      Assert
        (not Sitefetch.Domains.Is_Internal
           ("www.example.co.uk", "https://other.example.co.uk/a", Sitefetch.Domain_Include_Parents),
         "parent traversal does not include sibling subdomains");
      Assert
        (Sitefetch.Domains.Is_Internal
           ("localhost", "http://localhost/a", Sitefetch.Domain_Exact_And_Subdomains),
         "single-label root matches itself");
      Assert
        (not Sitefetch.Domains.Is_Internal
           ("localhost", "http://x.localhost/a", Sitefetch.Domain_Exact_And_Subdomains),
         "single-label root is exact-only");
   end Run_Test;

   overriding procedure Run_Test (Item : in out Link_Extraction_Test) is
      pragma Unreferenced (Item);
   begin
      declare
         Links : constant Sitefetch.Testing.Link_List :=
           Sitefetch.Testing.Extract_Links
             ("<a href=""/a.html"">"
              & "<img srcset=""/small.png 1x, /large.png 2x"">"
              & "<style>@import ""/base.css"";.hero{background:url('/hero.webp')}"
              & "/* url(/ignored.png) */</style>"
              & "<?xml version=""1.0""?><urlset><url><loc>/page.xml</loc></url></urlset>");
      begin
         Assert (Natural (Links.Length) = 6, "HTML srcset CSS and sitemap links extract");
         Assert (Links.Element (1) = "/a.html", "href extracts");
         Assert (Links.Element (2) = "/small.png", "first srcset candidate extracts");
         Assert (Links.Element (3) = "/large.png", "second srcset candidate extracts");
         Assert (Links.Element (4) = "/base.css", "CSS import extracts");
         Assert (Links.Element (5) = "/hero.webp", "CSS URL extracts");
         Assert (Links.Element (6) = "/page.xml", "sitemap loc extracts");
      end;

      declare
         Links : constant Sitefetch.Testing.Link_List :=
           Sitefetch.Testing.Extract_Links
             ("<style>@import ""/split\" & Character'Val (13) & Character'Val (10)
              & "-theme.css"";.x{background:url(""/bg\" & Character'Val (13) & Character'Val (10)
              & ".png"")}</style>");
      begin
         Assert (Natural (Links.Length) = 2, "CSS escaped CRLF continuations extract");
         Assert (Links.Element (1) = "/split-theme.css", "CSS import continuation decodes");
         Assert (Links.Element (2) = "/bg.png", "CSS URL continuation decodes");
      end;

      declare
         Links : constant Sitefetch.Testing.Link_List :=
           Sitefetch.Testing.Extract_Links
             ("<style>.a{background:url('/ok.png')}"
              & ".b{background:image-set(url(""/nested.png"") 1x)}"
              & ".c{background:url(var(--dynamic-image))}"
              & ".d{background:url(#fragment)}"
              & ".e{background:url(data:image/png;base64,abc)}"
              & ".f{--my-url:url('/ignored-custom-property.png')}"
              & ".g{xurl('/ignored-identifier.png')}</style>");
      begin
         Assert (Natural (Links.Length) = 2, "CSS tokenizer avoids non-fetchable and false-positive URLs");
         Assert (Links.Element (1) = "/ok.png", "CSS tokenizer extracts ordinary url function");
         Assert (Links.Element (2) = "/nested.png", "CSS tokenizer extracts nested url token");
      end;

      declare
         Links : constant Sitefetch.Testing.Link_List :=
           Sitefetch.Testing.Extract_Links
             ("<?xml version=""1.0""?><sm:sitemapindex xmlns:sm=""http://www.sitemaps.org/schemas/sitemap/0.9"">"
              & "<sm:sitemap><sm:loc>https://example.com/sitemap-pages.xml?x=1&amp;y=2</sm:loc></sm:sitemap>"
              & "</sm:sitemapindex>"
              & "<urlset xmlns=""http://www.sitemaps.org/schemas/sitemap/0.9"">"
              & "<url><loc><![CDATA[/from-cdata.html?ok=1&raw=2]]></loc></url>"
              & "<metadata><loc>/ignored-outside-url.html</loc></metadata>"
              & "</urlset>");
      begin
         Assert (Natural (Links.Length) = 2, "namespaced sitemap XML extracts only scoped locs");
         Assert
           (Links.Element (1) = "https://example.com/sitemap-pages.xml?x=1&y=2",
            "sitemap XML entity references decode in loc text");
         Assert
           (Links.Element (2) = "/from-cdata.html?ok=1&raw=2",
            "sitemap XML CDATA loc text extracts");
      end;

      declare
         Links : constant Sitefetch.Testing.Link_List :=
           Sitefetch.Testing.Extract_Links
             ("<a href=""/same.html""><img src=""/same.html""><a href=''><script src='/app.js'>");
      begin
         Assert (Natural (Links.Length) = 2, "duplicates and empty links are skipped");
         Assert (Links.Element (1) = "/same.html", "first duplicate occurrence is preserved");
         Assert (Links.Element (2) = "/app.js", "later unique source is retained");
      end;

      declare
         Bulk_Document : Unbounded_String := Null_Unbounded_String;
         Links         : Sitefetch.Testing.Link_List;
      begin
         for Index_Value in 0 .. 19 loop
            Append (Bulk_Document, "<a href=""/bulk/");
            Append (Bulk_Document, Character'Val (Character'Pos ('a') + Index_Value));
            Append (Bulk_Document, ".html"">bulk</a>");
         end loop;
         Links := Sitefetch.Testing.Extract_Links (To_String (Bulk_Document));
         Assert (Natural (Links.Length) = 20, "bulk document extracts all generated links");
         Assert (Links.Element (1) = "/bulk/a.html", "bulk first link order is preserved");
         Assert (Links.Element (20) = "/bulk/t.html", "bulk last link order is preserved");
      end;
   end Run_Test;

   overriding procedure Run_Test (Item : in out Rewrite_Test) is
      pragma Unreferenced (Item);
      Rewritten : constant String := Sitefetch.Testing.Rewrite_Document
        ("<a href=""https://example.com/docs/"">docs</a>"
         & "<script src=""https://assets.example.com/app.js""></script>"
         & "<a href=""https://elsewhere.example/"">offsite</a>"
         & "<img src=""/images/logo.png"">",
         "https://example.com/index.html",
         "https://example.com");
   begin
      Assert
        (Rewritten
         = "<a href=""docs/index.html"">docs</a>"
         & "<script src=""app.js""></script>"
         & "<a href=""https://elsewhere.example/"">offsite</a>"
         & "<img src=""images/logo.png"">",
         "same-domain and subdomain references are local while offsite references remain absolute");

      declare
         Query_Rewritten : constant String := Sitefetch.Testing.Rewrite_Document
           ("<a href=""../about.html#team"">about</a>"
            & "<a href=""?page=2"">page</a>"
            & "<script src=""//example.com/assets/app.js""></script>",
            "https://example.com/docs/current/index.html",
            "https://example.com");
      begin
         Assert
           (Query_Rewritten
            = "<a href=""../about.html"">about</a>"
            & "<a href=""index__q338b.html"">page</a>"
            & "<script src=""../../assets/app.js""></script>",
            "relative, query-only, and internal scheme-relative references are local");
      end;
   end Run_Test;

   overriding procedure Run_Test (Item : in out Classification_Test) is
      pragma Unreferenced (Item);
   begin
      Assert (Sitefetch.Testing.Should_Download_To_File ("https://example.com/report.PDF?x=1"),
              "PDF streams to file");
      Assert (not Sitefetch.Testing.Should_Download_To_File ("https://example.com/app.css"),
              "CSS is parsed in memory");
      Assert (Sitefetch.Testing.Should_Parse_Content_Type ("text/html; charset=utf-8"),
              "HTML content type is parseable");
      Assert (Sitefetch.Testing.Should_Parse_Content_Type ("image/svg+xml"),
              "SVG content type remains parseable");
      Assert (not Sitefetch.Testing.Should_Parse_Content_Type ("application/pdf"),
              "PDF content type is passive binary");
      Assert (not Sitefetch.Testing.Is_Safe_Asset_File_Type ("https://example.com/report.pdf"),
              "PDF is not allowed by strict asset-safe mode");
   end Run_Test;

   overriding procedure Run_Test (Item : in out Client_Config_Test) is
      pragma Unreferenced (Item);

      use type Http_Client.Clients.Protocol_Selection_Policy;

      Default_Config : constant Http_Client.Clients.Client_Configuration :=
        Sitefetch.Client_Config.Reusable_Configuration;
      Custom_Config : constant Http_Client.Clients.Client_Configuration :=
        Sitefetch.Client_Config.Reusable_Configuration ("sitefetchlib-test");
   begin
      Assert (Default_Config.Pooling.Enabled, "reusable configuration enables pooling");
      Assert (Default_Config.Execution.Protocol_Policy = Http_Client.Clients.Prefer_HTTP_2,
              "reusable configuration prefers HTTP/2");
      Assert (Http_Client.Headers.Get (Custom_Config.Default_Headers, "User-Agent") = "sitefetchlib-test",
              "custom user-agent is installed");
   end Run_Test;


   overriding procedure Run_Test (Item : in out Fetch_Engine_Test) is
      pragma Unreferenced (Item);
      Statistics : Sitefetch.Fetch_Statistics;
   begin
      declare
         Target : constant String := "lib-test-output-complete";
      begin
         Delete_Tree_If_Present (Target);
         Reset_Fake (Complete_Site);
         Assert
           (Sitefetch.Testing.Fetch_Website
              ("https://example.com/", Target, Simple_Callbacks (Fake_Fetch'Access), Statistics),
            "complete fake website fetch succeeds");
         Assert (Fetch_Count = 5, "root and four internal documents are fetched exactly once");
         Assert (not External_Fetched, "external link is not fetched");
         Assert (Statistics.Attempted = 5 and then Statistics.Written = 5, "recursive stats count written work");
         Assert (Ada.Directories.Exists (Target & "/index.html"), "root document is written");
         Assert (Ada.Directories.Exists (Target & "/about.html"), "linked document is written");
         Assert (Ada.Directories.Exists (Target & "/assets/app.css"), "stylesheet is written");
         Assert (Ada.Directories.Exists (Target & "/sub/app.js"), "subdomain asset is written");
         Assert
           (Read_File (Target & "/index.html")
            = "<a href=""about.html"">about</a>"
            & "<link href=""assets/app.css"">"
            & "<script src=""sub/app.js""></script>"
            & "<a href=""https://external.example/x"">external</a>",
            "root references are rewritten before writing");
         Delete_Tree_If_Present (Target);
      end;

      declare
         Target : constant String := "lib-test-output-cycle";
      begin
         Delete_Tree_If_Present (Target);
         Reset_Fake (Cycle_Site);
         Assert
           (Sitefetch.Testing.Fetch_Website
              ("https://cycle.example/", Target, Simple_Callbacks (Fake_Fetch'Access), Statistics),
            "cyclic fake website fetch succeeds");
         Assert (Fetch_Count = 2, "cycle does not refetch visited URLs");
         Assert (Ada.Directories.Exists (Target & "/a.html"), "cycle linked page is written");
         Delete_Tree_If_Present (Target);
      end;

      declare
         Target : constant String := "lib-test-output-missing-root";
      begin
         Delete_Tree_If_Present (Target);
         Reset_Fake (Missing_Root);
         Assert
           (not Sitefetch.Testing.Fetch_Website
              ("https://missing.example/", Target, Simple_Callbacks (Fake_Fetch'Access), Statistics),
            "missing root fails fetch");
         Assert (Statistics.Failed = 1, "missing root is counted as failure");
         Assert (not Ada.Directories.Exists (Target), "missing root writes nothing");
      end;

      declare
         Target : constant String := "lib-test-output-multiple-missing";
      begin
         Delete_Tree_If_Present (Target);
         Reset_Fake (Multiple_Missing_Links);
         Assert
           (not Sitefetch.Testing.Fetch_Website
              ("https://multi-missing.example/", Target, Simple_Callbacks (Fake_Fetch'Access), Statistics),
            "multiple missing linked documents fail fetch");
         Assert (Statistics.Failed = 2, "all failed links are counted");
         Assert (Natural (Statistics.Failed_Downloads.Length) = 2, "failure list retains both links");
         Assert (Ada.Directories.Exists (Target & "/inside.html"), "successful sibling is still written");
         Delete_Tree_If_Present (Target);
      end;

      declare
         Target : constant String := "lib-test-output-special";
      begin
         Delete_Tree_If_Present (Target);
         Reset_Fake (Special_Refs);
         Assert
           (Sitefetch.Testing.Fetch_Website
              ("https://special.example", Target, Simple_Callbacks (Fake_Fetch'Access), Statistics),
            "special references do not fail fetch");
         Assert (Fetch_Count = 2, "only root and HTTP child are fetched");
         Assert (not Special_Fetched, "unsupported schemes and fragments are not fetched");
         Assert
           (Read_File (Target & "/index.html")
            = "<a href=""#top"">top</a>"
            & "<a href=""mailto:team@example.com"">mail</a>"
            & "<a href=""javascript:void(0)"">script</a>"
            & "<img src=""data:text/plain,demo"">"
            & "<a href=""inside.html"">inside</a>",
            "unsupported references are preserved and HTTP child is local");
         Delete_Tree_If_Present (Target);
      end;

      declare
         Target : constant String := "lib-test-output-final-url";
      begin
         Delete_Tree_If_Present (Target);
         Fetch_Count := 0;
         Assert
           (Sitefetch.Testing.Fetch_Website
              ("https://redirect.example/", Target, Final_Callbacks (Fake_Final_Fetch'Access), Statistics),
            "fetch succeeds after root final URL is reported");
         Assert (Fetch_Count = 2, "default domain policy fetches final root and child");
         Assert (Statistics.Skipped_External = 1, "parent-domain link is skipped by default");
         Assert (Ada.Directories.Exists (Target & "/start/index.html"), "final root path is written");
         Assert (not Ada.Directories.Exists (Target & "/old.html"), "parent-domain link is not fetched by default");
         Assert
           (Read_File (Target & "/start/index.html")
            = "<a href=""../about.html"">about</a>"
            & "<a href=""https://redirect.example/old.html"">old</a>",
            "parent-domain link is preserved when skipped");

         declare
            Parent_Options : Sitefetch.Fetch_Options := Sitefetch.Default_Fetch_Options;
         begin
            Parent_Options.Crawl.Domain := Sitefetch.Domain_Include_Parents;
            Fetch_Count := 0;
            Assert
              (Sitefetch.Testing.Fetch_Website
                 ("https://redirect.example/", Target, Final_Callbacks (Fake_Final_Fetch'Access),
                  Statistics, null, Parent_Options),
               "fetch succeeds with parent-domain traversal enabled");
         end;
         Assert (Fetch_Count = 3, "parent-domain policy fetches parent-domain link");
         Assert (Ada.Directories.Exists (Target & "/old.html"), "parent-domain link is fetched when enabled");
         Delete_Tree_If_Present (Target);
      end;

      declare
         Target  : constant String := "lib-test-output-crawl-limits";
         Options : Sitefetch.Fetch_Options := Sitefetch.Default_Fetch_Options;
      begin
         Delete_Tree_If_Present (Target);
         Options.Crawl.Max_Pages := 1;
         Fetch_Count := 0;
         Assert
           (Sitefetch.Testing.Fetch_Website
              ("https://redirect.example/", Target, Final_Callbacks (Fake_Final_Fetch'Access),
               Statistics, null, Options),
            "page-limited fetch succeeds");
         Assert (Fetch_Count = 1, "max pages one fetches only root");
         Assert (Statistics.Skipped_Limit = 1, "page-limited child is counted");
         Assert (Statistics.Skipped_External = 1, "parent-domain link remains external");
         Delete_Tree_If_Present (Target);
      end;

      declare
         Target    : constant String := "lib-test-output-real-world";
         Asset_One : constant String := Sitefetch.Testing.Local_Path_For_URL
           ("https://www.fixtures.example/asset?id=1");
         Asset_Two : constant String := Sitefetch.Testing.Local_Path_For_URL
           ("https://www.fixtures.example/asset?id=2");
      begin
         Delete_Tree_If_Present (Target);
         Fetch_Count := 0;
         Assert
           (Sitefetch.Testing.Fetch_Website
              ("https://fixtures.example/", Target, Final_Callbacks (Real_World_Fixture_Fetch'Access), Statistics),
            "real-world fixture crawl succeeds");
         Assert (Statistics.Failed = 0, "real-world fixture has no failures");
         Assert
           (Fetch_Count = 14,
            "fixture discovers CSS, srcset, sitemap, gzip sitemap, no-extension, and query assets");
         Assert (Ada.Directories.Exists (Target & "/theme.css"), "CSS import is fetched");
         Assert (Ada.Directories.Exists (Target & "/sitemap-pages__q0b60.xml"), "sitemap index entry is fetched");
         Assert (Ada.Directories.Exists (Target & "/sitemap-compressed.xml.gz"), "compressed sitemap is fetched");
         Assert (Ada.Directories.Exists (Target & "/from-sitemap.html"), "sitemap loc page is fetched");
         Assert (Ada.Directories.Exists (Target & "/from-gzip-sitemap.html"), "compressed sitemap loc page is fetched");
         Assert (Asset_One /= Asset_Two, "query variants map to distinct local paths");
         Assert (Ada.Directories.Exists (Target & "/" & Asset_One), "first query variant is written");
         Assert (Ada.Directories.Exists (Target & "/" & Asset_Two), "second query variant is written");
         Assert
           (Read_File (Target & "/style.css")
            = "@import ""theme.css"";.hero{background:url('img/bg.png')}@font-face{src:url(font)}",
            "stylesheet rewrites CSS import and URL references");
         Delete_Tree_If_Present (Target);
      end;

      declare
         Target  : constant String := "lib-test-output-structured-progress-fields";
         Control : aliased Cache_Fixture_Control;
         Server  : Cache_Fixture_Server (Control'Access);
         Port    : GNAT.Sockets.Port_Type;
         URL     : Unbounded_String;
         Options : Sitefetch.Fetch_Options := Sitefetch.Default_Fetch_Options;
      begin
         Control.Wait_Ready (Port);
         URL := To_Unbounded_String
           ("http://127.0.0.1:"
            & Ada.Strings.Fixed.Trim (Natural'Image (Natural (Port)), Ada.Strings.Both)
            & "/cache-stale-no-validator.html");
         Delete_Tree_If_Present (Target);
         Reset_Structured_Progress;

         Options.Crawl.Workers := 1;
         Options.Cache.Mode := Sitefetch.Cache_Ignore;
         Assert
           (Sitefetch.Crawler.Fetch_Website_With_Structured_Progress
              (To_String (URL), Target, Statistics, Record_Structured_Progress'Access, Options),
            "sitefetchlib structured progress fixture succeeds");
         Assert (Structured_Written_Count > 0, "structured progress captures a written event");
         Assert
           (To_String (Last_Structured_Written_URL) = To_String (URL),
            "structured written event records URL");
         Assert
           (To_String (Last_Structured_Written_Local_Path) = Target & "/cache-stale-no-validator.html",
            "structured written event records local path");
         Assert
           (To_String (Last_Structured_Written_Final_URL) = To_String (URL),
            "structured written event records final URL");
         Assert (Last_Structured_Written_Bytes = 11, "structured written event records bytes written");
         Assert (Last_Structured_Written_Depth = 0, "structured written event records depth");

         Control.Stop;
         Delete_Tree_If_Present (Target);
      exception
         when others =>
            Control.Stop;
            Delete_Tree_If_Present (Target);
            raise;
      end;

      declare
         Target  : constant String := "lib-test-output-cache-stale-no-validator";
         Control : aliased Cache_Fixture_Control;
         Server  : Cache_Fixture_Server (Control'Access);
         Port    : GNAT.Sockets.Port_Type;
         URL     : Unbounded_String;
         Options : Sitefetch.Fetch_Options := Sitefetch.Default_Fetch_Options;
      begin
         Control.Wait_Ready (Port);
         URL := To_Unbounded_String
           ("http://127.0.0.1:"
            & Ada.Strings.Fixed.Trim (Natural'Image (Natural (Port)), Ada.Strings.Both)
            & "/cache-stale-no-validator.html");
         Delete_Tree_If_Present (Target);

         Options.Crawl.Workers := 1;
         Options.HTTP.Head := Sitefetch.Head_Disabled;
         Options.Cache.Mode := Sitefetch.Cache_Revalidate;
         Options.Diagnostics.Mode := Sitefetch.Diagnostics_Verbose;
         Assert
           (Sitefetch.Crawler.Fetch_Website (To_String (URL), Target, Statistics, null, Options),
            "sitefetchlib production cache fixture warms stale no-validator entry");

         Progress_Cache_Rejected_Count := 0;
         Progress_Cache_Revalidate_Count := 0;
         Assert
           (Sitefetch.Crawler.Fetch_Website (To_String (URL), Target, Statistics, Record_Progress'Access, Options),
            "sitefetchlib stale no-validator cache refresh succeeds");
         Assert
           (Progress_Cache_Revalidate_Count = 0,
            "sitefetchlib stale no-validator cache does not report conditional revalidation");
         Assert
           (Progress_Cache_Rejected_Count > 0,
            "sitefetchlib stale no-validator cache reports rejection");
         Assert
           (Read_File (Target & "/cache-stale-no-validator.html") = "stale cache",
            "sitefetchlib stale no-validator cache refreshes content");

         Options.Cache.Mode := Sitefetch.Cache_Offline;
         Progress_Cache_Rejected_Count := 0;
         Progress_Cache_Revalidate_Count := 0;
         Last_Cache_Rejected_Progress := Null_Unbounded_String;
         Assert
           (not Sitefetch.Crawler.Fetch_Website
              (To_String (URL), Target, Statistics, Record_Progress'Access, Options),
            "sitefetchlib offline stale no-validator cache fails");
         Assert
           (Progress_Cache_Rejected_Count > 0,
            "sitefetchlib offline stale no-validator cache reports rejection");
         Assert
           (Contains_Fragment
              (To_String (Last_Cache_Rejected_Progress), "offline cache entry stale"),
            "sitefetchlib offline stale document reports precise rejection reason");

         Control.Stop;
         Delete_Tree_If_Present (Target);
      exception
         when others =>
            Control.Stop;
            Delete_Tree_If_Present (Target);
            raise;
      end;

      declare
         Target  : constant String := "lib-test-output-cache-policy";
         Control : aliased Cache_Fixture_Control;
         Server  : Cache_Fixture_Server (Control'Access);
         Port    : GNAT.Sockets.Port_Type;
         Base    : Unbounded_String;
         Fresh_URL : Unbounded_String;
         Vary_URL  : Unbounded_String;
         Fresh_Download_URL  : Unbounded_String;
         Stale_Download_URL  : Unbounded_String;
         Partial_Download_URL : Unbounded_String;
         Options : Sitefetch.Fetch_Options := Sitefetch.Default_Fetch_Options;
         Count_Before : Natural;
      begin
         Control.Wait_Ready (Port);
         Base := To_Unbounded_String
           ("http://127.0.0.1:"
            & Ada.Strings.Fixed.Trim (Natural'Image (Natural (Port)), Ada.Strings.Both));
         Fresh_URL := To_Unbounded_String (To_String (Base) & "/cache-fresh.html");
         Vary_URL := To_Unbounded_String (To_String (Base) & "/cache-vary.html");
         Fresh_Download_URL := To_Unbounded_String (To_String (Base) & "/cache-fresh.pdf");
         Stale_Download_URL := To_Unbounded_String (To_String (Base) & "/cache-stale.pdf");
         Partial_Download_URL := To_Unbounded_String (To_String (Base) & "/cache-partial.pdf");
         Delete_Tree_If_Present (Target);

         Options.Crawl.Workers := 1;
         Options.Cache.Mode := Sitefetch.Cache_Revalidate;
         Options.Diagnostics.Mode := Sitefetch.Diagnostics_Verbose;
         Assert
           (Sitefetch.Crawler.Fetch_Website (To_String (Fresh_URL), Target, Statistics, null, Options),
            "fresh cache policy fixture warms entry");
         Assert (Control.Fresh_Count > 0, "fresh cache warmup reaches fixture server");

         Count_Before := Control.Fresh_Count;
         Options.Cache.Mode := Sitefetch.Cache_Offline;
         Assert
           (Sitefetch.Crawler.Fetch_Website
              (To_String (Fresh_URL), Target, Statistics,
               Record_Progress'Access, Options),
            "offline mode reuses fresh valid cache entry");
         Assert
           (Control.Fresh_Count = Count_Before,
            "offline fresh cache reuse does not contact fixture server");

         declare
            Missing_URL : constant String := To_String (Base) & "/cache-missing.html";
         begin
            Progress_Cache_Rejected_Count := 0;
            Last_Cache_Rejected_Progress := Null_Unbounded_String;
            Assert
              (not Sitefetch.Crawler.Fetch_Website
                 (Missing_URL, Target, Statistics, Record_Progress'Access, Options),
               "offline mode rejects missing document cache entry");
            Assert
              (Progress_Cache_Rejected_Count > 0,
               "offline missing document emits cache rejection");
            Assert
              (Contains_Fragment
                 (To_String (Last_Cache_Rejected_Progress), "offline cache entry missing"),
               "offline missing document reports precise cache rejection reason");
         end;

         Options.Cache.Mode := Sitefetch.Cache_Refresh;
         Assert
           (Sitefetch.Crawler.Fetch_Website (To_String (Fresh_URL), Target, Statistics, null, Options),
            "refresh mode refetches fresh cache entry");
         Assert
           (Control.Fresh_Count > Count_Before,
            "refresh mode bypasses fresh local sidecar");

         Count_Before := Control.Fresh_Count;
         Write_Test_File (Target & "/cache-fresh.html", "locally corrupted");
         Options.Cache.Mode := Sitefetch.Cache_Revalidate;
         Progress_Cache_Rejected_Count := 0;
         Assert
           (Sitefetch.Crawler.Fetch_Website
              (To_String (Fresh_URL), Target, Statistics,
               Record_Progress'Access, Options),
            "revalidate mode refreshes cache after local corruption");
         Assert
           (Progress_Cache_Rejected_Count > 0,
            "local corruption rejects cache sidecar before refresh");
         Assert
           (Control.Fresh_Count > Count_Before,
            "local corruption forces network refresh");

         Count_Before := Control.Fresh_Count;
         Remove_Metadata_Line
           (Target & "/cache-fresh.html.sitefetch_http_cache", "Cache-Version: ");
         Options.Cache.Require_Metadata_Version := True;
         Progress_Cache_Rejected_Count := 0;
         Assert
           (Sitefetch.Crawler.Fetch_Website
              (To_String (Fresh_URL), Target, Statistics,
               Record_Progress'Access, Options),
            "required metadata version rejects old sidecar then refreshes");
         Assert
           (Progress_Cache_Rejected_Count > 0,
            "missing metadata version emits cache rejection");
         Assert
           (Control.Fresh_Count > Count_Before,
            "missing metadata version forces network refresh");

         Options := Sitefetch.Default_Fetch_Options;
         Options.Crawl.Workers := 1;
         Options.HTTP.Head := Sitefetch.Head_Disabled;
         Options.Cache.Mode := Sitefetch.Cache_Revalidate;
         Options.Diagnostics.Mode := Sitefetch.Diagnostics_Verbose;
         Options.Cache.Vary_Allow.Accept_Language := True;
         Options.HTTP.Accept_Language := To_Unbounded_String ("en");
         Assert
           (Sitefetch.Crawler.Fetch_Website (To_String (Vary_URL), Target, Statistics, null, Options),
            "vary cache fixture warms with accepted request header");

         Count_Before := Control.Vary_Count;
         Options.Cache.Mode := Sitefetch.Cache_Offline;
         Assert
           (Sitefetch.Crawler.Fetch_Website
              (To_String (Vary_URL), Target, Statistics,
               Record_Progress'Access, Options),
            "offline mode reuses Vary cache when request header matches");
         Assert
           (Control.Vary_Count = Count_Before,
            "matching Vary header reuses cache without network");

         Options.HTTP.Accept_Language := To_Unbounded_String ("da");
         Progress_Cache_Rejected_Count := 0;
         Assert
           (not Sitefetch.Crawler.Fetch_Website
              (To_String (Vary_URL), Target, Statistics,
               Record_Progress'Access, Options),
            "offline mode rejects Vary cache when request header differs");
         Assert
           (Progress_Cache_Rejected_Count > 0,
            "Vary request mismatch emits cache rejection");
         Assert
           (Control.Vary_Count = Count_Before,
            "offline Vary mismatch does not contact fixture server");

         Options.Cache.Mode := Sitefetch.Cache_Revalidate;
         Assert
           (Sitefetch.Crawler.Fetch_Website (To_String (Vary_URL), Target, Statistics, null, Options),
            "revalidate mode refreshes Vary mismatch from network");
         Assert
           (Control.Vary_Count > Count_Before,
            "Vary mismatch forces network refresh outside offline mode");

         Options := Sitefetch.Default_Fetch_Options;
         Options.Crawl.Workers := 1;
         Options.Cache.Mode := Sitefetch.Cache_Revalidate;
         Options.Diagnostics.Mode := Sitefetch.Diagnostics_Verbose;
         Assert
           (Sitefetch.Crawler.Fetch_Website
              (To_String (Fresh_Download_URL), Target, Statistics, null, Options),
            "fresh download cache fixture warms entry");
         Assert
           (Control.Download_Fresh_Count > 0,
            "fresh download warmup reaches fixture server");

         Count_Before := Control.Download_Fresh_Count;
         Options.Cache.Mode := Sitefetch.Cache_Offline;
         Assert
           (Sitefetch.Crawler.Fetch_Website
              (To_String (Fresh_Download_URL), Target, Statistics,
               Record_Progress'Access, Options),
            "offline mode reuses fresh cached download");
         Assert
           (Control.Download_Fresh_Count = Count_Before,
            "offline fresh download reuse does not contact fixture server");
         Assert
           (Read_File (Target & "/cache-fresh.pdf") = "fresh download",
            "offline fresh download keeps cached file content");

         Options.Cache.Mode := Sitefetch.Cache_Revalidate;
         Assert
           (Sitefetch.Crawler.Fetch_Website
              (To_String (Stale_Download_URL), Target, Statistics, null, Options),
            "stale download cache fixture warms entry");
         Count_Before := Control.Download_Stale_Count;
         Options.Cache.Mode := Sitefetch.Cache_Offline;
         Progress_Cache_Rejected_Count := 0;
         Last_Cache_Rejected_Progress := Null_Unbounded_String;
         Assert
           (not Sitefetch.Crawler.Fetch_Website
              (To_String (Stale_Download_URL), Target, Statistics,
               Record_Progress'Access, Options),
            "offline mode rejects stale cached download");
         Assert
           (Progress_Cache_Rejected_Count > 0,
            "offline stale download emits cache rejection");
         Assert
           (Contains_Fragment
              (To_String (Last_Cache_Rejected_Progress), "offline cache entry stale"),
            "offline stale download reports precise cache rejection reason");
         Assert
           (Control.Download_Stale_Count = Count_Before,
            "offline stale download rejection does not contact fixture server");

         Options.Cache.Mode := Sitefetch.Cache_Revalidate;
         Assert
           (Sitefetch.Crawler.Fetch_Website
              (To_String (Partial_Download_URL), Target, Statistics, null, Options),
            "partial download cache fixture warms entry");
         declare
            Final_Path   : constant String := Target & "/cache-partial.pdf";
            Partial_Path : constant String := Final_Path & ".sitefetch_part";
            Final_Meta   : constant String := Final_Path & ".sitefetch_http_cache";
            Partial_Meta : constant String := Partial_Path & ".sitefetch_http_cache";
         begin
            if Ada.Directories.Exists (Partial_Path) then
               Ada.Directories.Delete_File (Partial_Path);
            end if;
            if Ada.Directories.Exists (Partial_Meta) then
               Ada.Directories.Delete_File (Partial_Meta);
            end if;
            Ada.Directories.Rename (Final_Path, Partial_Path);
            Ada.Directories.Rename (Final_Meta, Partial_Meta);
         end;
         Count_Before := Control.Download_Partial_Count;
         Options.Cache.Mode := Sitefetch.Cache_Offline;
         Progress_Cache_Rejected_Count := 0;
         Last_Cache_Rejected_Progress := Null_Unbounded_String;
         Assert
           (not Sitefetch.Crawler.Fetch_Website
              (To_String (Partial_Download_URL), Target, Statistics,
               Record_Progress'Access, Options),
            "offline mode rejects partial-only cached download");
         Assert
           (Contains_Fragment
              (To_String (Last_Cache_Rejected_Progress),
               "offline partial cache entry unusable"),
            "offline partial cached download reports precise cache rejection reason");
         Assert
           (Control.Download_Partial_Count = Count_Before,
            "offline partial cached download does not attempt resume request");

         Control.Stop;
         Delete_Tree_If_Present (Target);
      exception
         when others =>
            Control.Stop;
            Delete_Tree_If_Present (Target);
            raise;
      end;

      declare
         Target : constant String := "lib-test-output-write-failure";
      begin
         Delete_Tree_If_Present (Target);
         Write_Test_File (Target & "/blocker", "not a directory");
         Assert
           (not Sitefetch.Testing.Fetch_Website
              ("https://writefail.example/", Target, Final_Callbacks (Real_World_Fixture_Fetch'Access), Statistics),
            "recursive write failure returns false");
         Assert (Statistics.Failed = 1, "write failure is counted once");
         Assert (Contains_Fragment (To_String (Statistics.Failed_Reason), "write failed:"),
                 "write failure records reason");
         Delete_Tree_If_Present (Target);
      end;
   end Run_Test;

   overriding procedure Run_Test (Item : in out Parallel_Fetch_Test) is
      pragma Unreferenced (Item);
      Statistics : Sitefetch.Fetch_Statistics;
   begin
      declare
         Target : constant String := "lib-test-output-parallel-dedup";
      begin
         Delete_Tree_If_Present (Target);
         Parallel_Fake.Reset (Parallel_Deduplicate);
         Assert
           (Sitefetch.Testing.Fetch_Website
              ("https://parallel.example/", Target, Parallel_Callbacks (Parallel_Fetch'Access), Statistics),
            "parallel injected fetch succeeds");
         Assert (Statistics.Attempted = 4 and then Statistics.Written = 4, "parallel deduplicates attempts");
         Assert (Parallel_Fake.Count ("https://parallel.example/shared.html") = 1, "shared link fetched once");
         Assert (Ada.Directories.Exists (Target & "/shared.html"), "shared link is written");
         Delete_Tree_If_Present (Target);
      end;

      declare
         Target : constant String := "lib-test-output-parallel-failure";
      begin
         Delete_Tree_If_Present (Target);
         Parallel_Fake.Reset (Parallel_Failure);
         Progress_Failed_Count := 0;
         Assert
           (not Sitefetch.Testing.Fetch_Website
              ("https://parallel.example/", Target, Parallel_Callbacks (Parallel_Fetch'Access),
               Statistics, Record_Progress'Access),
            "parallel linked failure reports overall failure");
         Assert (Statistics.Attempted = 3, "parallel failure counts root and two links");
         Assert (Statistics.Written = 2, "parallel failure writes successful work");
         Assert (Statistics.Failed = 1, "parallel failure counts failed sibling");
         Assert (To_String (Statistics.Failed_Reason) = "MISSING_PARALLEL", "parallel failure retains reason");
         Assert (Progress_Failed_Count = 1, "parallel failure emits failed progress");
         Assert (Ada.Directories.Exists (Target & "/ok.html"), "successful sibling is written");
         Delete_Tree_If_Present (Target);
      end;

      declare
         Target : constant String := "lib-test-output-parallel-final";
      begin
         Delete_Tree_If_Present (Target);
         Parallel_Fake.Reset (Parallel_Final_Root);
         Assert
           (Sitefetch.Testing.Fetch_Website
              ("https://parallel.example/", Target, Parallel_Callbacks (Parallel_Fetch'Access), Statistics),
            "parallel injected fetch uses final root URL");
         Assert (Statistics.Attempted = 2, "parallel final root counts root and final-domain page");
         Assert (Statistics.Skipped_External = 2, "parent-domain links are skipped by default");
         Assert (Ada.Directories.Exists (Target & "/start/index.html"), "parallel final root is written");
         Assert (Ada.Directories.Exists (Target & "/renamed/inside.html"), "final URL path is written");
         Assert (not Ada.Directories.Exists (Target & "/old.html"), "parent-domain page is skipped");
         Delete_Tree_If_Present (Target);
      end;
   end Run_Test;

   overriding procedure Run_Test (Item : in out Direct_Download_Test) is
      pragma Unreferenced (Item);
      Statistics : Sitefetch.Fetch_Statistics;
   begin
      declare
         Target : constant String := "lib-test-output-direct-download";
      begin
         Delete_Tree_If_Present (Target);
         Reset_Download_Fake (Download_Succeeds);
         Assert
           (Sitefetch.Testing.Fetch_Website
              ("https://download.example/", Target,
               Final_Callbacks (Fake_Download_Final_Fetch'Access, Fake_Direct_Downloader'Access),
               Statistics, Record_Progress'Access),
            "direct linked download succeeds");
         Assert (Fetch_Count = 1, "only root document is fetched into memory");
         Assert (Download_Count = 1, "direct resource uses downloader callback");
         Assert (Statistics.Attempted = 2 and then Statistics.Written = 2, "root and direct resource are counted");
         Assert (Statistics.Bytes_Written = Download_Root_Document'Length + Downloaded_Report_Text'Length,
                 "bytes include document and downloaded file");
         Assert (To_String (Last_Download_URL) = "https://download.example/files/report.pdf",
                 "downloader receives resolved resource URL");
         Assert (Ada.Directories.Exists (Target & "/assets/final-report.pdf"), "download uses final URL path");
         Assert (not Ada.Directories.Exists (To_String (Last_Download_Path)), "staging path is removed");
         Assert (To_String (Last_Written_Progress) = "https://download.example/assets/final-report.pdf",
                 "written progress reports final direct URL");
         Delete_Tree_If_Present (Target);
      end;

      declare
         Target : constant String := "lib-test-output-root-direct-download";
      begin
         Delete_Tree_If_Present (Target);
         Reset_Download_Fake (Download_Succeeds);
         Assert
           (Sitefetch.Testing.Fetch_Website
              ("https://download.example/root.pdf", Target,
               Final_Callbacks (Fake_Download_Final_Fetch'Access, Fake_Direct_Downloader'Access),
               Statistics, Record_Progress'Access),
            "root direct download succeeds");
         Assert (Fetch_Count = 0, "root direct download is not buffered as text");
         Assert (Download_Count = 1, "root direct download uses downloader");
         Assert (Statistics.Bytes_Written = Downloaded_Root_Report_Text'Length, "root direct bytes are counted");
         Assert (Ada.Directories.Exists (Target & "/assets/root-final.pdf"), "root direct uses final path");
         Delete_Tree_If_Present (Target);
      end;

      declare
         Target : constant String := "lib-test-output-parallel-download";
      begin
         Delete_Tree_If_Present (Target);
         Reset_Download_Fake (Download_Succeeds);
         Assert
           (Sitefetch.Testing.Fetch_Website
              ("https://download.example/", Target,
               Parallel_Callbacks (Fake_Parallel_Download_Fetch'Access, Fake_Direct_Downloader'Access),
               Statistics),
            "parallel linked direct download succeeds");
         Assert (Fetch_Count = 2 and then Download_Count = 1, "parallel downloads file and fetches HTML sibling");
         Assert (Statistics.Attempted = 3 and then Statistics.Written = 3, "parallel direct stats include sibling");
         Assert (Ada.Directories.Exists (Target & "/ok.html"), "HTML sibling is written");
         Delete_Tree_If_Present (Target);
      end;

      declare
         Target  : constant String := "lib-test-output-download-byte-limit";
         Options : Sitefetch.Fetch_Options := Sitefetch.Default_Fetch_Options;
      begin
         Delete_Tree_If_Present (Target);
         Reset_Download_Fake (Download_Byte_Limit);
         Options.Crawl.Workers := 1;
         Options.Crawl.Max_Bytes := Download_Byte_Limit_Document'Length + Downloaded_Report_Text'Length;
         Assert
           (Sitefetch.Testing.Fetch_Website
              ("https://download.example/", Target,
               Parallel_Callbacks (Fake_Parallel_Download_Fetch'Access, Fake_Direct_Downloader'Access),
               Statistics, null, Options),
            "byte-limited direct download succeeds at cap");
         Assert (Statistics.Bytes_Written = Options.Crawl.Max_Bytes, "direct download reaches byte cap exactly");
         Assert (Download_Count = 1, "byte cap stops second queued direct download");
         Delete_Tree_If_Present (Target);
      end;

      declare
         Target  : constant String := "lib-test-output-download-over-cap";
         Options : Sitefetch.Fetch_Options := Sitefetch.Default_Fetch_Options;
      begin
         Delete_Tree_If_Present (Target);
         Reset_Download_Fake (Download_Byte_Limit);
         Options.Crawl.Workers := 1;
         Options.Crawl.Max_Failures := 1;
         Options.Crawl.Max_Bytes := Download_Byte_Limit_Document'Length + Downloaded_Report_Text'Length - 1;
         Assert
           (not Sitefetch.Testing.Fetch_Website
              ("https://download.example/", Target,
               Parallel_Callbacks (Fake_Parallel_Download_Fetch'Access, Fake_Direct_Downloader'Access),
               Statistics, null, Options),
            "oversized direct download fails byte cap");
         Assert (Statistics.Bytes_Written = Download_Byte_Limit_Document'Length,
                 "oversized direct download bytes are not counted");
         Assert (Statistics.Failed = 1, "oversized direct download is recorded as failed");
         Assert (Contains_Fragment (To_String (Statistics.Failed_Reason), "byte limit exceeded"),
                 "oversized direct download records byte limit reason");
         Assert (not Ada.Directories.Exists (Target & "/assets/final-report.pdf"),
                 "oversized download is not moved to final path");
         Delete_Tree_If_Present (Target);
      end;

      declare
         Target : constant String := "lib-test-output-dangerous-download";
      begin
         Delete_Tree_If_Present (Target);
         Reset_Download_Fake (Download_Dangerous);
         Assert
           (Sitefetch.Testing.Fetch_Website
              ("https://download.example/", Target,
               Parallel_Callbacks (Fake_Parallel_Download_Fetch'Access, Fake_Direct_Downloader'Access),
               Statistics, Record_Progress'Access),
            "default safety downloads dangerous direct resource with warning");
         Assert (Download_Count = 1, "dangerous file is downloaded in default safety mode");
         Assert (Progress_Warning_Count = 1, "dangerous download emits warning");
         Assert (Ada.Directories.Exists (Target & "/files/tool.exe"), "dangerous file is written");
         Delete_Tree_If_Present (Target);
      end;

      declare
         Target  : constant String := "lib-test-output-skip-dangerous";
         Options : Sitefetch.Fetch_Options := Sitefetch.Default_Fetch_Options;
      begin
         Delete_Tree_If_Present (Target);
         Reset_Download_Fake (Download_Dangerous);
         Options.Safety.Mode := Sitefetch.Safety_Skip_Dangerous;
         Assert
           (Sitefetch.Testing.Fetch_Website
              ("https://download.example/", Target,
               Final_Callbacks (Fake_Download_Final_Fetch'Access), Statistics, Record_Progress'Access, Options),
            "skip-dangerous mode skips dangerous linked resource");
         Assert (Fetch_Count = 1, "skip-dangerous does not fetch dangerous URL");
         Assert (Statistics.Skipped_Unsupported = 1, "skip-dangerous counts skipped file");
         Assert (Progress_Safety_Count = 1, "skip-dangerous emits safety skip progress");
         Assert (not Ada.Directories.Exists (Target & "/files/tool.exe"), "skipped dangerous file is not written");
         Delete_Tree_If_Present (Target);
      end;

      declare
         Target : constant String := "lib-test-output-direct-download-failure";
      begin
         Delete_Tree_If_Present (Target);
         Reset_Download_Fake (Download_Fails);
         Assert
           (not Sitefetch.Testing.Fetch_Website
              ("https://download.example/", Target,
               Final_Callbacks (Fake_Download_Final_Fetch'Access, Fake_Direct_Downloader'Access),
               Statistics, Record_Progress'Access),
            "failed direct download makes fetch fail");
         Assert (Statistics.Failed = 1, "failed direct download is counted");
         Assert (To_String (Statistics.Failed_Reason) = "BROKEN_DOWNLOAD", "failed direct reason is retained");
         Assert (To_String (Last_Failed_Progress) = "https://download.example/files/broken.pdf (BROKEN_DOWNLOAD)",
                 "failed progress includes direct download reason");
         Delete_Tree_If_Present (Target);
      end;
   end Run_Test;

   function All_Tests return AUnit.Test_Suites.Access_Test_Suite is
      Result : constant AUnit.Test_Suites.Access_Test_Suite := new AUnit.Test_Suites.Test_Suite;
   begin
      Sitefetchlib_Production_HTTP_Tests.Add_Tests (Result);
      Result.Add_Test (new URL_Test);
      Result.Add_Test (new Link_Extraction_Test);
      Result.Add_Test (new Rewrite_Test);
      Result.Add_Test (new Classification_Test);
      Result.Add_Test (new Client_Config_Test);
      Result.Add_Test (new Fetch_Engine_Test);
      Result.Add_Test (new Parallel_Fetch_Test);
      Result.Add_Test (new Direct_Download_Test);
      return Result;
   end All_Tests;
end Sitefetchlib_Test_Suite;
