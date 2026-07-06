with Ada.Calendar;
with Ada.Containers.Indefinite_Hashed_Sets;
with Ada.Containers.Vectors;
with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Interfaces;

with Http_Client.Clients;
with Http_Client.Crypto;
with Http_Client.Errors;
with Http_Client.Headers;
with Http_Client.Decompression;
with Http_Client.Diagnostics;
with Http_Client.Requests;
with Http_Client.Retry;
with Http_Client.Responses;
with Http_Client.Types;
with Http_Client.URI;
with Regexp;
with Zlib;

with Sitefetch.Client_Config;
with Sitefetch.Engine.Cache;
with Sitefetch.Domains;
with Sitefetch.Content;
with Sitefetch.Engine.Diagnostics;
with Sitefetch.Documents;
with Sitefetch.Engine.Files;
with Sitefetch.Engine.HTTP;
with Sitefetch.Engine.Robots;
with Sitefetch.Engine.Run_Control;
with Sitefetch.Engine.State;
with Sitefetch.URLs;

package body Sitefetch.Engine is
   use Ada.Strings.Unbounded;
   use Sitefetch.Engine.Cache;
   use Sitefetch.Content;
   use Sitefetch.Engine.Diagnostics;
   use Sitefetch.Documents;
   use Sitefetch.Engine.HTTP;
   use Sitefetch.Engine.Robots;
   use Sitefetch.Engine.Run_Control;
   use Sitefetch.Engine.State;
   use Sitefetch.URLs;

   use type Simple_Fetcher_Access;
   use type Final_Fetcher_Access;
   use type Direct_Downloader_Access;
   use type Parallel_Fetcher_Access;
   use type Ada.Calendar.Time;
   use type Ada.Directories.File_Kind;
   use type Ada.Directories.File_Size;
   use type Http_Client.Errors.Result_Status;
   use type Zlib.Status_Code;

   function Inflate_GZip_Text (Text : String; Inflated : out Unbounded_String) return Boolean is
      Input  : Zlib.Byte_Array (0 .. Text'Length - 1);
      Status : Zlib.Status_Code;
   begin
      Inflated := Null_Unbounded_String;
      if Text = "" then
         return False;
      end if;

      for Offset in Input'Range loop
         Input (Offset) := Zlib.Byte (Character'Pos (Text (Text'First + Offset)));
      end loop;

      declare
         Output : constant Zlib.Byte_Array :=
           Zlib.Inflate_With_Header (Input, Zlib.GZip, Zlib.Multi_Member, Status);
      begin
         if Status /= Zlib.Ok then
            return False;
         end if;

         for Item of Output loop
            Append (Inflated, Character'Val (Natural (Item)));
         end loop;
      end;

      return True;
   exception
      when others =>
         Inflated := Null_Unbounded_String;
         return False;
   end Inflate_GZip_Text;

   procedure Write_Document_With_Optional_Rewrite
     (Path_Text     : String;
      Document_Text : String;
      Page_URL      : String;
      Root_URL      : String;
      Matches       : Link_Match_Vectors.Vector;
      Policy        : Domain_Policy := Domain_Exact_And_Subdomains;
      Durability    : Write_Durability_Mode := Write_Durability_Default)
   is
   begin
      Sitefetch.Engine.Files.Write_Text
        (Path_Text,
         Document_Text_For_Write (Document_Text, Page_URL, Root_URL, Matches, Policy),
         Durability);
   end Write_Document_With_Optional_Rewrite;


   function With_Reason (URL : String; Reason : String) return String;


   function Download_Staging_Path (Target_Path : String; Limits : Fetch_Options) return String is
   begin
      if Cache_Reads_Downloads (Limits) then
         return Partial_Download_Path (Target_Path);
      else
         return Sitefetch.Engine.Files.Available_Sibling_Path (Target_Path, ".sitefetch_download");
      end if;
   end Download_Staging_Path;

   function Usable_Cache_Metadata
     (Target_Path : String;
      Limits      : Fetch_Options;
      Progress    : Progress_Callback := null;
      URL         : String := "") return Cache_Metadata
   is
      Metadata : constant Cache_Metadata :=
        Sitefetch.Engine.Cache.Read_Cache_Metadata
          (Target_Path, Limits.Cache.Verify_Local_Content, Limits.Cache.Hash_Algorithm);
      Reject_Reason : Unbounded_String;
   begin
      if Sitefetch.Engine.Cache.Cache_Metadata_Usable (Metadata, Limits, Reject_Reason) then
         return Metadata;
      else
         Emit_Diagnostic (Progress, Limits, Progress_Cache_Rejected,
            With_Reason ((if URL = "" then Target_Path else URL), To_String (Reject_Reason)), Target_Path);
         return (others => <>);
      end if;
   end Usable_Cache_Metadata;


   function Safety_Skips_Download (Limits : Fetch_Options; URL : String) return Boolean is
   begin
      case Limits.Safety.Mode is
         when Safety_Default =>
            return False;
         when Safety_Skip_Dangerous =>
            return Is_Dangerous_File_Type (URL);
         when Safety_Assets_Only_Safe =>
            return not Is_Safe_Asset_File_Type (URL);
      end case;
   end Safety_Skips_Download;

   procedure Emit_Dangerous_Download_If_Needed
     (Progress : Progress_Callback; Limits : Fetch_Options; URL : String)
   is
   begin
      if Limits.Safety.Mode = Safety_Default and then Is_Dangerous_File_Type (URL) then
         Emit_Progress (Progress, Progress_Warning_Dangerous, URL);
      end if;
   end Emit_Dangerous_Download_If_Needed;


   function Status_Reason (Status : Http_Client.Errors.Result_Status) return String is
   begin
      return Ada.Strings.Fixed.Trim
        (Http_Client.Errors.Result_Status'Image (Status), Ada.Strings.Both);
   end Status_Reason;

   function With_Reason (URL : String; Reason : String) return String is
   begin
      if Reason = "" then
         return URL;
      else
         return URL & " (" & Reason & ")";
      end if;
   end With_Reason;


   function Byte_Limit_Reason (Max_Bytes : Natural) return String is
   begin
      return "byte limit exceeded: max " & Natural'Image (Max_Bytes) & " bytes";
   end Byte_Limit_Reason;

   function Natural_Image (Value : Natural) return String is
   begin
      return Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Left);
   end Natural_Image;


   function HTTP_Fetch_Final
     (Item           : Http_Client.Clients.Client;
      URL            : String;
      Target_Path    : String;
      Document_Text  : out Unbounded_String;
      Final_URL      : out Unbounded_String;
      Failure_Reason : out Unbounded_String;
      Parse_Content  : out Boolean;
      Not_Modified          : out Boolean;
      Redirect_Hops         : out Natural;
      Redirect_Status_Codes : out Unbounded_String;
      Redirect_Target_URLs  : out Unbounded_String;
      Redirect_Locations    : out Unbounded_String;
      Response_Info         : out Http_Client.Responses.Response;
      Progress       : Progress_Callback;
      Limits         : Fetch_Options) return Boolean
   is
      use type Http_Client.Errors.Result_Status;
      use type Http_Client.Types.Status_Code;

      Result : Http_Client.Clients.Client_Result;
      Status : Http_Client.Errors.Result_Status := Http_Client.Errors.Internal_Error;
      Metadata : constant Cache_Metadata :=
        (if Cache_Reads_Documents (Limits) and then Target_Path /= ""
         then Usable_Cache_Metadata (Target_Path, Limits, Progress, URL)
         else (others => <>));
   begin
      Not_Modified := False;
      Redirect_Hops := 0;
      Redirect_Status_Codes := Null_Unbounded_String;
      Redirect_Target_URLs := Null_Unbounded_String;
      Redirect_Locations := Null_Unbounded_String;
      Response_Info := Http_Client.Responses.Default_Response;

      if Metadata.Exists and then Cache_Metadata_Fresh (Metadata, Limits) then
         Emit_Diagnostic (Progress, Limits, Progress_Cache_Reused, URL, Target_Path);
         if Length (Metadata.Final_URL) > 0 then
            Final_URL := Metadata.Final_URL;
         else
            Final_URL := To_Unbounded_String (URL);
         end if;

         if Target_Path = "" or else not Sitefetch.Engine.Files.Read_Text_File (Target_Path, Document_Text) then
            Emit_Diagnostic
              (Progress, Limits, Progress_Cache_Rejected,
               With_Reason (URL, "offline cached file unreadable"), Target_Path);
            Document_Text := Null_Unbounded_String;
            Final_URL := Null_Unbounded_String;
            Failure_Reason := To_Unbounded_String ("offline cached file unreadable");
            Parse_Content := False;
            Not_Modified := False;
            return False;
         end if;

         Failure_Reason := Null_Unbounded_String;
         Parse_Content := Should_Parse_Content_Type (To_String (Metadata.Content_Type));
         Not_Modified := True;
         return True;
      elsif Limits.Cache.Mode = Cache_Offline then
         declare
            Reason : constant String :=
              (if Metadata.Exists then "offline cache entry stale"
               else "offline cache entry missing");
         begin
            Emit_Diagnostic
              (Progress, Limits, Progress_Cache_Rejected,
               With_Reason (URL, Reason), Target_Path);
            Document_Text := Null_Unbounded_String;
            Final_URL := Null_Unbounded_String;
            Failure_Reason := To_Unbounded_String (Reason);
            Parse_Content := False;
            Not_Modified := False;
            return False;
         end;
      elsif Metadata.Exists and then Cache_Metadata_Has_Validators (Metadata) then
         Emit_Diagnostic (Progress, Limits, Progress_Cache_Revalidate, URL, Target_Path);
         declare
            URI     : Http_Client.URI.URI_Reference;
            Request : Http_Client.Requests.Request;
            Headers : Http_Client.Headers.Header_List := Http_Client.Headers.Empty;
         begin
            if Http_Client.URI.Parse (URL, URI) /= Http_Client.Errors.Ok then
               Status := Http_Client.Errors.Invalid_URI;
            else
               Add_Cache_Validators (Headers, Metadata);
               Status := Http_Client.Requests.Create
                 (Method  => Http_Client.Types.GET,
                  URI     => URI,
                  Item    => Request,
                  Headers => Headers);
               if Status = Http_Client.Errors.Ok then
                  for Attempt in Natural range 0 .. Limits.HTTP.Max_Retries loop
                     Delay_Before_Request (URL, Limits);
                     Begin_Redirect_Request;
                     Status := Http_Client.Clients.Execute (Item, Request, Result);
                     Snapshot_And_Clear_Redirects
                       (Redirect_Status_Codes, Redirect_Target_URLs, Redirect_Locations);
                     if Status = Http_Client.Errors.Ok then
                        declare
                           Response_Status : constant Http_Client.Types.Status_Code :=
                             Http_Client.Responses.Status_Code (Response_From_Client_Result (Result));
                        begin
                           exit when not Retryable_HTTP_Status (Limits, Response_Status)
                             or else Attempt >= Limits.HTTP.Max_Retries;
                           Emit_Diagnostic (Progress,
                              Limits,
                              Progress_Retry,
                              With_Reason
                                (URL,
                                 "attempt " & Natural_Image (Attempt + 1)
                                 & " after " & HTTP_Status_Reason (Response_Status)));
                           Delay_Before_Retry (Limits, Attempt + 1, URL);
                        end;
                     else
                        exit when Attempt >= Limits.HTTP.Max_Retries
                          or else not Retryable_HTTP_Failure (Limits, Status);
                        Emit_Diagnostic (Progress,
                           Limits,
                           Progress_Retry,
                           With_Reason
                             (URL,
                              "attempt " & Natural_Image (Attempt + 1)
                              & " after " & Status_Reason (Status)));
                        Delay_Before_Retry (Limits, Attempt + 1, URL);
                     end if;
                  end loop;
               end if;
            end if;
         end;
      else
         if Metadata.Exists then
            Emit_Diagnostic (Progress, Limits, Progress_Cache_Rejected,
               With_Reason (URL, "cache stale without validators"), Target_Path);
         end if;
         for Attempt in Natural range 0 .. Limits.HTTP.Max_Retries loop
            Delay_Before_Request (URL, Limits);
            Begin_Redirect_Request;
            Status := Http_Client.Clients.Get (Item, URL, Result);
            Snapshot_And_Clear_Redirects
           (Redirect_Status_Codes, Redirect_Target_URLs, Redirect_Locations);
            if Status = Http_Client.Errors.Ok then
               declare
                  Response_Status : constant Http_Client.Types.Status_Code :=
                    Http_Client.Responses.Status_Code (Response_From_Client_Result (Result));
               begin
                  exit when not Retryable_HTTP_Status (Limits, Response_Status)
                    or else Attempt >= Limits.HTTP.Max_Retries;
                  Emit_Diagnostic (Progress,
                     Limits,
                     Progress_Retry,
                     With_Reason
                       (URL,
                        "attempt " & Natural_Image (Attempt + 1)
                        & " after " & HTTP_Status_Reason (Response_Status)));
                  Delay_Before_Retry (Limits, Attempt + 1, URL);
               end;
            else
               exit when Attempt >= Limits.HTTP.Max_Retries
                 or else not Retryable_HTTP_Failure (Limits, Status);
               Emit_Diagnostic (Progress,
                  Limits,
                  Progress_Retry,
                  With_Reason
                    (URL,
                     "attempt " & Natural_Image (Attempt + 1)
                     & " after " & Status_Reason (Status)));
               Delay_Before_Retry (Limits, Attempt + 1, URL);
            end if;
         end loop;
      end if;

      if Status /= Http_Client.Errors.Ok then
         Document_Text := Null_Unbounded_String;
         Final_URL := Null_Unbounded_String;
         Failure_Reason := To_Unbounded_String (Status_Reason (Status));
         Parse_Content := False;
         return False;
      end if;

      Response_Info := Response_From_Client_Result (Result);
      Redirect_Hops := Result.Redirect_Count;
      Final_URL := To_Unbounded_String (Http_Client.Clients.Final_URL (Result));
      if Length (Final_URL) = 0 then
         Final_URL := To_Unbounded_String (URL);
      end if;

      if Retryable_HTTP_Status (Limits, Http_Client.Responses.Status_Code (Response_Info)) then
         Document_Text := Null_Unbounded_String;
         Failure_Reason :=
           To_Unbounded_String (HTTP_Status_Reason (Http_Client.Responses.Status_Code (Response_Info)));
         Parse_Content := False;
         return False;
      end if;

      if Http_Client.Responses.Status_Code (Response_Info) = 304 then
         Emit_Diagnostic (Progress, Limits, Progress_Cache_Reused, URL, Target_Path);
         if Length (Metadata.Final_URL) > 0 then
            Final_URL := Metadata.Final_URL;
         end if;

         if Target_Path = "" or else not Sitefetch.Engine.Files.Read_Text_File (Target_Path, Document_Text) then
            Document_Text := Null_Unbounded_String;
            Failure_Reason := To_Unbounded_String ("cached file unavailable after 304");
            Parse_Content := False;
            Not_Modified := False;
            return False;
         end if;

         Failure_Reason := Null_Unbounded_String;
         Parse_Content := True;
         Not_Modified := True;
         return True;
      end if;

      Document_Text := To_Unbounded_String (Http_Client.Clients.Response_Text (Result));

      if Is_Compressed_Sitemap_URL (URL) then
         declare
            Inflated_Text : Unbounded_String;
         begin
            if Inflate_GZip_Text (To_String (Document_Text), Inflated_Text) then
               Document_Text := Inflated_Text;
               Parse_Content := True;
            else
               Document_Text := Null_Unbounded_String;
               Failure_Reason := To_Unbounded_String ("gzip sitemap decompression failed");
               Parse_Content := False;
               return False;
            end if;
         end;
      elsif Result.Used_Decoded_View then
         Parse_Content := Should_Parse_Content_Type
           (Http_Client.Responses.Media_Type
              (Http_Client.Decompression.Original_Response (Result.Decoded_Response)));
      else
         Parse_Content := Should_Parse_Content_Type
           (Http_Client.Responses.Media_Type (Result.Response));
      end if;

      Failure_Reason := Null_Unbounded_String;
      return True;
   end HTTP_Fetch_Final;

   function HTTP_Download_Final
     (Item           : in out Http_Client.Clients.Client;
      URL            : String;
      Target_Path    : String;
      Download_Path  : String;
      Max_Bytes      : Natural;
      Final_URL      : out Unbounded_String;
      Failure_Reason : out Unbounded_String;
      Bytes_Written  : out Natural;
      Not_Modified          : out Boolean;
      Redirect_Hops         : out Natural;
      Redirect_Status_Codes : out Unbounded_String;
      Redirect_Target_URLs  : out Unbounded_String;
      Redirect_Locations    : out Unbounded_String;
      Response_Info         : out Http_Client.Responses.Response;
      Progress       : Progress_Callback;
      Limits         : Fetch_Options) return Boolean
   is
      use type Http_Client.Errors.Result_Status;
      use type Http_Client.Types.Status_Code;
      use type Http_Client.Clients.Resume_Fallback_Action;

      Options : Http_Client.Clients.Download_Options := Http_Client.Clients.Default_Download_Options;
      Result  : Http_Client.Clients.Download_Result;
      Status  : Http_Client.Errors.Result_Status := Http_Client.Errors.Internal_Error;
      Target_Metadata : constant Cache_Metadata :=
        (if Cache_Reads_Downloads (Limits)
         then Usable_Cache_Metadata (Target_Path, Limits, Progress, URL)
         else (others => <>));
      Partial_Metadata : constant Cache_Metadata :=
        (if Cache_Reads_Downloads (Limits)
         then Usable_Cache_Metadata (Download_Path, Limits, Progress, URL)
         else (others => <>));
      Metadata : constant Cache_Metadata :=
        (if Target_Metadata.Exists then Target_Metadata else Partial_Metadata);
      Partial_Size : constant Natural := Existing_File_Size (Download_Path);
      Resume_Mode  : constant Boolean := Limits.Cache.Mode = Cache_Revalidate;
      Resume_Token : constant Unbounded_String := Resume_Validator (Metadata);
      Can_Resume   : constant Boolean := Resume_Mode
        and then Partial_Metadata.Exists
        and then Partial_Size > 0
        and then Length (Resume_Token) > 0;
   begin
      Not_Modified := False;
      Redirect_Hops := 0;
      Redirect_Status_Codes := Null_Unbounded_String;
      Redirect_Target_URLs := Null_Unbounded_String;
      Redirect_Locations := Null_Unbounded_String;
      Response_Info := Http_Client.Responses.Default_Response;
      Options.Durability :=
        (case Limits.Safety.Write_Durability is
            when Write_Durability_Default => Http_Client.Clients.File_Durability_Default,
            when Write_Durability_Flush_Temp_File => Http_Client.Clients.File_Durability_Flush_Temp_File,
            when Write_Durability_Sync_Data_And_Directory =>
              Http_Client.Clients.File_Durability_Sync_Data_And_Directory);
      Http_Client.Clients.Configure_Resumable_Download
        (Options             => Options,
         Resume_Mode         => Resume_Mode,
         Can_Resume          => Can_Resume,
         Resume_If_Range     => Resume_Token,
         Partial_Size        => Partial_Size,
         Remaining_Max_Bytes => Max_Bytes);
      if Can_Resume then
         Emit_Diagnostic (Progress,
            Limits,
            Progress_Resume_Attempt,
            With_Reason (URL, Natural_Image (Partial_Size) & " existing bytes"),
            Target_Path);
      end if;

      if Target_Metadata.Exists and then Cache_Metadata_Fresh (Target_Metadata, Limits) then
         Emit_Diagnostic (Progress, Limits, Progress_Cache_Reused, URL, Target_Path);
         if Length (Target_Metadata.Final_URL) > 0 then
            Final_URL := Target_Metadata.Final_URL;
         else
            Final_URL := To_Unbounded_String (URL);
         end if;
         Failure_Reason := Null_Unbounded_String;
         Bytes_Written := 0;
         Not_Modified := True;
         return True;
      elsif Limits.Cache.Mode = Cache_Offline then
         declare
            Reason : constant String :=
              (if Target_Metadata.Exists then "offline cache entry stale"
               elsif Partial_Metadata.Exists then "offline partial cache entry unusable"
               else "offline cache entry missing");
         begin
            Emit_Diagnostic
              (Progress, Limits, Progress_Cache_Rejected,
               With_Reason (URL, Reason), Target_Path);
            Final_URL := Null_Unbounded_String;
            Failure_Reason := To_Unbounded_String (Reason);
            Bytes_Written := 0;
            Not_Modified := False;
            return False;
         end;
      elsif Metadata.Exists and then Cache_Metadata_Has_Validators (Metadata) then
         Emit_Diagnostic (Progress, Limits, Progress_Cache_Revalidate, URL, Target_Path);
         declare
            URI      : Http_Client.URI.URI_Reference;
            Request  : Http_Client.Requests.Request;
            Headers  : Http_Client.Headers.Header_List := Http_Client.Headers.Empty;
            Head_Result : Http_Client.Clients.Client_Result;
         begin
            if Http_Client.URI.Parse (URL, URI) = Http_Client.Errors.Ok then
               Add_Cache_Validators (Headers, Metadata);
               Status := Http_Client.Requests.Create
                 (Method  => Http_Client.Types.HEAD,
                  URI     => URI,
                  Item    => Request,
                  Headers => Headers);
               if Status = Http_Client.Errors.Ok then
                  Delay_Before_Request (URL, Limits);
                  Begin_Redirect_Request;
                  Status := Http_Client.Clients.Execute (Item, Request, Head_Result);
                  Snapshot_And_Clear_Redirects
                    (Redirect_Status_Codes, Redirect_Target_URLs, Redirect_Locations);
                  if Status = Http_Client.Errors.Ok then
                     Response_Info := Response_From_Client_Result (Head_Result);
                     Redirect_Hops := Head_Result.Redirect_Count;
                     if Http_Client.Responses.Status_Code (Response_Info) = 304 then
                        Emit_Diagnostic (Progress, Limits, Progress_Cache_Reused, URL, Target_Path);
                        Final_URL := To_Unbounded_String (Http_Client.Clients.Final_URL (Head_Result));
                        if Length (Final_URL) = 0 then
                           Final_URL := To_Unbounded_String (URL);
                        end if;
                        Failure_Reason := Null_Unbounded_String;
                        Bytes_Written := 0;
                        Not_Modified := True;
                        return True;
                     end if;
                  end if;
               end if;
            end if;
         end;
      end if;

      if Metadata.Exists and then not Cache_Metadata_Has_Validators (Metadata) then
         Emit_Diagnostic (Progress, Limits, Progress_Cache_Rejected,
            With_Reason (URL, "cache stale without validators"), Target_Path);
      end if;

      for Attempt in Natural range 0 .. Limits.HTTP.Max_Retries loop
         Delay_Before_Request (URL, Limits);
         Begin_Redirect_Request;
         Status := Http_Client.Clients.Download_To_File
           (Item    => Item,
            URL     => URL,
            Path    => Download_Path,
            Result  => Result,
            Options => Options);
         Snapshot_And_Clear_Redirects
           (Redirect_Status_Codes, Redirect_Target_URLs, Redirect_Locations);
         if Status = Http_Client.Errors.Ok then
            exit when not Retryable_HTTP_Status (Limits, Result.HTTP_Status_Code)
              or else Attempt >= Limits.HTTP.Max_Retries;
            if not Resume_Mode then
               Sitefetch.Engine.Files.Delete_File_If_Present (Download_Path);
            end if;
            Emit_Diagnostic (Progress,
               Limits,
               Progress_Retry,
               With_Reason
                 (URL,
                  "attempt " & Natural_Image (Attempt + 1)
                  & " after " & HTTP_Status_Reason (Result.HTTP_Status_Code)));
            Delay_Before_Retry (Limits, Attempt + 1, URL);
         else
            if not Resume_Mode then
               Sitefetch.Engine.Files.Delete_File_If_Present (Download_Path);
            end if;
            exit when Attempt >= Limits.HTTP.Max_Retries
              or else not Retryable_HTTP_Failure (Limits, Status);
            Emit_Diagnostic (Progress,
               Limits,
               Progress_Retry,
               With_Reason
                 (URL,
                  "attempt " & Natural_Image (Attempt + 1)
                  & " after " & Status_Reason (Status)));
            Delay_Before_Retry (Limits, Attempt + 1, URL);
         end if;
      end loop;

      if Http_Client.Clients.Resume_Fallback_For (Status, Result, Resume_Mode)
        = Http_Client.Clients.Retry_Without_Resume
      then
         Sitefetch.Engine.Files.Delete_File_If_Present (Download_Path);
         Sitefetch.Engine.Files.Delete_File_If_Present (Cache_Metadata_Path (Download_Path));
         Http_Client.Clients.Configure_Full_Retry_After_Resume_Failure (Options, Max_Bytes);

         Delay_Before_Request (URL, Limits);
         Begin_Redirect_Request;
         Status := Http_Client.Clients.Download_To_File
           (Item    => Item,
            URL     => URL,
            Path    => Download_Path,
            Result  => Result,
            Options => Options);
         Snapshot_And_Clear_Redirects
           (Redirect_Status_Codes, Redirect_Target_URLs, Redirect_Locations);
      end if;

      if Status /= Http_Client.Errors.Ok then
         if not Resume_Mode then
            Sitefetch.Engine.Files.Delete_File_If_Present (Download_Path);
         end if;
         Response_Info := Result.Response;
         Redirect_Hops := Result.Redirect_Count;
         Final_URL := Null_Unbounded_String;
         Failure_Reason := To_Unbounded_String (Status_Reason (Status));
         Bytes_Written := 0;
         return False;
      elsif Retryable_HTTP_Status (Limits, Result.HTTP_Status_Code) then
         if not Resume_Mode then
            Sitefetch.Engine.Files.Delete_File_If_Present (Download_Path);
         end if;
         Response_Info := Result.Response;
         Redirect_Hops := Result.Redirect_Count;
         Final_URL := Null_Unbounded_String;
         Failure_Reason := To_Unbounded_String (HTTP_Status_Reason (Result.HTTP_Status_Code));
         Bytes_Written := 0;
         return False;
      end if;

      Response_Info := Result.Response;
      Redirect_Hops := Result.Redirect_Count;
      Final_URL := To_Unbounded_String (Http_Client.URI.Image (Result.Final_URI));
      if Length (Final_URL) = 0 then
         Final_URL := To_Unbounded_String (URL);
      end if;

      Failure_Reason := Null_Unbounded_String;
      Bytes_Written := Result.Bytes_Written;
      return True;
   end HTTP_Download_Final;

   procedure Begin_Fetch_Run is
   begin
      Sitefetch.Engine.Files.Clear_Directory_Cache;
      Sitefetch.Engine.Robots.Clear_Robots_Cache;
      Sitefetch.Engine.Robots.Clear_Crawl_Delay_Scheduler;
   end Begin_Fetch_Run;

   procedure Mark_Safety_Skipped
     (State     : in out Fetch_State;
      Progress  : Progress_Callback;
      URL       : String;
      Depth     : Natural := 0;
      Has_Depth : Boolean := False)
   is
   begin
      State.Mark_Unsupported;
      Emit_Progress_Detailed
        (Progress, Progress_Skipped_Dangerous, URL,
         Depth => Depth, Has_Depth => Has_Depth,
         Final_URL => URL);
   end Mark_Safety_Skipped;

   procedure Enqueue_Robots_Sitemaps
     (State      : in out Fetch_State;
      Root_URL   : String;
      Robots     : Robots_Rules;
      Limits     : Fetch_Options;
      Progress   : Progress_Callback)
   is
      Root_Domain : constant String := Domain_Of (Root_URL);
      Status      : Claim_Status;
   begin
      if not Robots.Enabled then
         return;
      end if;

      for Sitemap_URL of Robots.Sitemaps loop
         declare
            Absolute_URL : constant String := Canonical_URL (Resolve_URL (Root_URL, Sitemap_URL));
         begin
            if Is_In_Domain (Root_Domain, Absolute_URL, Limits.Crawl.Domain) then
               State.Claim_URL (Absolute_URL, 1, Status);
               case Status is
                  when Claimed =>
                     State.Enqueue (Absolute_URL, 1, Work_Document);
                  when Already_Visited =>
                     Emit_Progress_Detailed
                       (Progress, Progress_Already_Visited, Absolute_URL,
                        Depth => 1, Has_Depth => True,
                        Final_URL => Absolute_URL);
                  when Document_Limit_Reached =>
                     Emit_Progress_Detailed
                       (Progress, Progress_Skipped_Limit, Absolute_URL,
                        Depth => 1, Has_Depth => True,
                        Final_URL => Absolute_URL);
               end case;
            else
               State.Mark_External;
               Emit_Progress_Detailed
                 (Progress, Progress_Skipped_External, Absolute_URL,
                  Depth => 1, Has_Depth => True,
                  Final_URL => Absolute_URL);
            end if;
         end;
      end loop;
   end Enqueue_Robots_Sitemaps;

   function Load_Robots
     (Item     : Http_Client.Clients.Client;
      Root_URL : String;
      Limits   : Fetch_Options;
      Progress : Progress_Callback) return Robots_Rules
   is
      use type Http_Client.Types.Status_Code;

      Rules          : Robots_Rules := Ignore_Robots;
      Cached_Rules   : Robots_Rules := Ignore_Robots;
      Cache_Found    : Boolean := False;
      Origin         : constant String := Origin_Of (Root_URL);
      Robots_URL     : constant String := Origin & "/robots.txt";
      Document_Text  : Unbounded_String;
      Final_URL_Text : Unbounded_String;
      Failure_Reason : Unbounded_String;
      Parse_Content  : Boolean := False;
      Not_Modified   : Boolean := False;
      Redirect_Hops         : Natural := 0;
      Redirect_Status_Codes : Unbounded_String := Null_Unbounded_String;
      Redirect_Target_URLs  : Unbounded_String := Null_Unbounded_String;
      Redirect_Locations    : Unbounded_String := Null_Unbounded_String;
      Response_Info         : Http_Client.Responses.Response;
   begin
      if Limits.Crawl.Robots = Robots_Ignore then
         return Rules;
      end if;

      Rules.Enabled := True;
      if Origin = "" then
         return Rules;
      end if;

      Sitefetch.Engine.Robots.Lookup_Cached_Robots (Origin, Cache_Found, Cached_Rules);
      if Cache_Found then
         return Cached_Rules;
      end if;

      Rules.Source_URL := To_Unbounded_String (Robots_URL);

      if HTTP_Fetch_Final
        (Item, Robots_URL, "", Document_Text, Final_URL_Text, Failure_Reason,
         Parse_Content, Not_Modified, Redirect_Hops, Redirect_Status_Codes,
         Redirect_Target_URLs, Redirect_Locations, Response_Info, Progress, Limits)
      then
         if Http_Client.Responses.Status_Code (Response_Info) >= 200
           and then Http_Client.Responses.Status_Code (Response_Info) <= 299
         then
            Parse_Robots (To_String (Document_Text), To_String (Limits.HTTP.User_Agent), Rules);
            Emit_Diagnostic (Progress, Limits, Progress_Robots_Loaded, Robots_URL);
         else
            Emit_Diagnostic (Progress, Limits, Progress_Robots_Failed,
               With_Reason
                 (Robots_URL,
                  "HTTP_" & Natural_Image (Natural (Http_Client.Responses.Status_Code (Response_Info)))));
            if Limits.Crawl.Robots_Failure = Robots_Fail_Closed then
               Rules := Fail_Closed_Robots;
            Rules.Source_URL := To_Unbounded_String (Robots_URL);
               Rules.Source_URL := To_Unbounded_String (Robots_URL);
            end if;
         end if;
      else
         Emit_Diagnostic (Progress, Limits, Progress_Robots_Failed,
            With_Reason (Robots_URL, To_String (Failure_Reason)));
         if Limits.Crawl.Robots_Failure = Robots_Fail_Closed then
            Rules := Fail_Closed_Robots;
         end if;
      end if;

      Sitefetch.Engine.Robots.Store_Cached_Robots (Origin, Rules);
      return Rules;
   end Load_Robots;

   procedure Process_Links_With_Matches
     (State      : in out Fetch_State;
      Page_URL   : String;
      Root_URL   : String;
      Matches    : Link_Match_Vectors.Vector;
      Progress   : Progress_Callback;
      Limits     : Fetch_Options;
      Page_Depth : Natural;
      Robots     : Robots_Rules)
   is
      Seen        : URL_Sets.Set;
      Root_Domain : constant String := Domain_Of (Root_URL);
   begin
      for Item of Matches loop
         declare
            Reference : constant String := To_String (Item.Reference);
         begin
            if Reference = "" or else Seen.Contains (Reference) then
               null;
            else
               Seen.Include (Reference);

               if not Is_Fetchable_Reference (Reference) then
                  State.Mark_Unsupported;
                  Emit_Progress_Detailed (Progress, Progress_Skipped_Unsupported, Reference,
               Depth => Page_Depth + 1, Has_Depth => True);
               else
                  declare
                     Absolute_URL : constant String := Canonical_URL (Resolve_URL (Page_URL, Reference));
                     Status       : Claim_Status;
                  begin
                     if Is_In_Domain (Root_Domain, Absolute_URL, Limits.Crawl.Domain) then
                        if not Robots_Allows (Robots, Absolute_URL) then
                           Emit_Diagnostic (Progress, Limits, Progress_Robots_Disallowed, Absolute_URL,
                              Robots_Source_Override => To_String (Robots.Source_URL));
                           State.Mark_Unsupported;
                           Emit_Progress_Detailed
                             (Progress, Progress_Skipped_Unsupported, Absolute_URL,
                              Depth => Page_Depth + 1, Has_Depth => True,
                              Final_URL => Absolute_URL,
                              Robots_Source => To_String (Robots.Source_URL));
                        else
                           if Robots.Enabled then
                              Emit_Diagnostic (Progress, Limits, Progress_Robots_Allowed, Absolute_URL,
                                 Robots_Source_Override => To_String (Robots.Source_URL));
                           end if;

                           if Limits.Crawl.Max_Sitemap_Depth > 0
                             and then Page_Depth >= Limits.Crawl.Max_Sitemap_Depth
                             and then Is_Sitemap_URL (Page_URL)
                             and then Is_Sitemap_URL (Absolute_URL)
                           then
                              State.Mark_Limited;
                              Emit_Progress_Detailed
                                (Progress, Progress_Skipped_Limit, Absolute_URL,
                                 Depth => Page_Depth + 1, Has_Depth => True,
                                 Final_URL => Absolute_URL);
                           else
                              declare
                                 Direct_Download : constant Boolean := Should_Download_To_File (Absolute_URL);
                              begin
                                 if Direct_Download and then Safety_Skips_Download (Limits, Absolute_URL) then
                                    Mark_Safety_Skipped
                                      (State, Progress, Absolute_URL, Page_Depth + 1, True);
                                 else
                                    State.Claim_URL (Absolute_URL, Page_Depth + 1, Status);
                                    case Status is
                                       when Claimed =>
                                          State.Enqueue
                                            (Absolute_URL,
                                             Page_Depth + 1,
                                             (if Direct_Download then Work_Download else Work_Document));
                                       when Already_Visited =>
                                          Emit_Progress_Detailed
                                            (Progress, Progress_Already_Visited, Absolute_URL,
                                             Depth => Page_Depth + 1, Has_Depth => True,
                                             Final_URL => Absolute_URL);
                                       when Document_Limit_Reached =>
                                          Emit_Progress_Detailed
                                            (Progress, Progress_Skipped_Limit, Absolute_URL,
                                             Depth => Page_Depth + 1, Has_Depth => True,
                                             Final_URL => Absolute_URL);
                                    end case;
                                 end if;
                              end;
                           end if;
                        end if;
                     else
                        State.Mark_External;
                        Emit_Progress_Detailed (Progress, Progress_Skipped_External, Absolute_URL,
                     Depth => Page_Depth + 1, Has_Depth => True);
                     end if;
                  end;
               end if;
            end if;
         end;
      end loop;
   end Process_Links_With_Matches;

   procedure Process_Links
     (State      : in out Fetch_State;
      Page_URL   : String;
      Root_URL   : String;
      Content    : String;
      Progress   : Progress_Callback;
      Page_Depth : Natural)
   is
      Matches : Link_Match_Vectors.Vector;
   begin
      Extract_Link_Matches (Content, Matches);
      Process_Links_With_Matches
        (State, Page_URL, Root_URL, Matches, Progress, Default_Fetch_Options, Page_Depth, Ignore_Robots);
   end Process_Links;

   function Recursive_Limit_Reached
     (Visited    : Link_List;
      Statistics : Fetch_Statistics;
      Limits     : Fetch_Options;
      Depth      : Natural) return Boolean
   is
   begin
      return (Limits.Crawl.Max_Pages > 0 and then Natural (Visited.Length) >= Limits.Crawl.Max_Pages)
        or else (Limits.Crawl.Max_Depth > 0 and then Depth > Limits.Crawl.Max_Depth)
        or else (Limits.Crawl.Max_Failures > 0 and then Statistics.Failed >= Limits.Crawl.Max_Failures)
        or else (Limits.Crawl.Max_Bytes > 0 and then Statistics.Bytes_Written >= Limits.Crawl.Max_Bytes);
   end Recursive_Limit_Reached;

   function Effective_Final_URL (Current_URL : String; Final_URL : Unbounded_String) return String is
   begin
      if Length (Final_URL) = 0 then
         return Current_URL;
      else
         return Canonical_URL (To_String (Final_URL));
      end if;
   end Effective_Final_URL;

   function Effective_Root_URL (Root_URL : String; Effective_URL : String) return String is
   begin
      if Root_URL = "" then
         return Effective_URL;
      else
         return Root_URL;
      end if;
   end Effective_Root_URL;

   procedure Mark_Redirected_URL
     (State         : in out Fetch_State;
      Current_URL   : String;
      Effective_URL : String)
   is
   begin
      if Effective_URL /= Current_URL then
         State.Mark_Visited (Effective_URL);
      end if;
   end Mark_Redirected_URL;

   procedure Mark_Redirected_URL
     (Visited       : in out Link_List;
      Visited_Set   : in out URL_Sets.Set;
      Current_URL   : String;
      Effective_URL : String)
   is
   begin
      if Effective_URL /= Current_URL and then not Visited_Set.Contains (Effective_URL) then
         Visited.Append (Effective_URL);
         Visited_Set.Include (Effective_URL);
      end if;
   end Mark_Redirected_URL;

   function Response_Status_Code (Response_Info : Http_Client.Responses.Response) return Natural is
   begin
      return Natural (Http_Client.Responses.Status_Code (Response_Info));
   exception
      when others =>
         return 0;
   end Response_Status_Code;

   function Write_State_Document
     (State            : in out Fetch_State;
      Target_Directory : String;
      Document_Text    : String;
      Effective_URL    : String;
      Root_URL         : String;
      Progress         : Progress_Callback;
      Limits           : Fetch_Options;
      Depth            : Natural;
      Parse_Content    : Boolean;
      Follow_Links     : Boolean;
      Robots           : Robots_Rules;
      Response_Info    : Http_Client.Responses.Response;
      Cached_Not_Modified : Boolean := False) return Boolean
   is
      Target_Path : constant String :=
        Sitefetch.Engine.Files.Join_Path
          (Target_Directory, Local_Path_For_URL (Effective_URL));
   begin
      if Parse_Content then
         declare
            Matches : Link_Match_Vectors.Vector;
         begin
            Extract_Link_Matches (Document_Text, Matches);

            if Cached_Not_Modified then
               State.Mark_Written (0);
               Emit_Progress_Detailed (Progress, Progress_Written, Effective_URL, 0, True, Depth, True,
                  Status_Code => Response_Status_Code (Response_Info),
                  Local_Path  => Target_Path);
            else
               Write_Document_With_Optional_Rewrite
                 (Target_Path, Document_Text, Effective_URL, Root_URL, Matches,
                  Limits.Crawl.Domain, Limits.Safety.Write_Durability);
               State.Mark_Written (Document_Text'Length);
               Emit_Progress_Detailed
                 (Progress, Progress_Written, Effective_URL, Document_Text'Length,
                  True, Depth, True,
                  Status_Code => Response_Status_Code (Response_Info),
                  Local_Path  => Target_Path);
               if Cache_Writes_Documents (Limits) then
                  Write_Cache_Metadata (Target_Path, Effective_URL, Effective_URL, Response_Info, Limits);
               end if;
            end if;

            if Follow_Links then
               Process_Links_With_Matches
                 (State, Effective_URL, Root_URL, Matches, Progress, Limits, Depth, Robots);
            end if;
         end;
      else
         Sitefetch.Engine.Files.Write_Text (Target_Path, Document_Text, Limits.Safety.Write_Durability);
         State.Mark_Written (Document_Text'Length);
         Emit_Progress_Detailed (Progress, Progress_Written, Effective_URL, Document_Text'Length, True, Depth, True,
            Status_Code => Response_Status_Code (Response_Info),
            Local_Path  => Target_Path);
         if Cache_Writes_Documents (Limits) then
            Write_Cache_Metadata (Target_Path, Effective_URL, Effective_URL, Response_Info, Limits);
         end if;
      end if;

      return True;
   exception
      when others =>
         declare
            Reason : constant String := Sitefetch.Engine.Files.Write_Failure_Reason (Target_Path);
         begin
            State.Mark_Failed (Effective_URL, Reason);
            Emit_Progress_Detailed (Progress, Progress_Failed, With_Reason (Effective_URL, Reason),
               Depth => Depth, Has_Depth => True,
               Local_Path => Target_Path);
            return False;
         end;
   end Write_State_Document;

   function Write_Recursive_Document
     (Statistics       : in out Fetch_Statistics;
      Target_Directory : String;
      Document_Text    : String;
      Effective_URL    : String;
      Root_URL         : String;
      Progress         : Progress_Callback;
      Parse_Content    : Boolean;
      Matches          : in out Link_Match_Vectors.Vector;
      Policy           : Domain_Policy := Domain_Exact_And_Subdomains;
      Depth            : Natural := 0) return Boolean
   is
      Target_Path : constant String :=
        Sitefetch.Engine.Files.Join_Path
          (Target_Directory, Local_Path_For_URL (Effective_URL));
   begin
      if Parse_Content then
         Extract_Link_Matches (Document_Text, Matches);
         Write_Document_With_Optional_Rewrite
           (Target_Path, Document_Text, Effective_URL, Root_URL, Matches, Policy);
      else
         Matches.Clear;
         Sitefetch.Engine.Files.Write_Text (Target_Path, Document_Text);
      end if;

      Statistics.Written := Statistics.Written + 1;
      Statistics.Bytes_Written := Statistics.Bytes_Written + Document_Text'Length;
      Emit_Progress_Detailed (Progress, Progress_Written, Effective_URL, Document_Text'Length, True, Depth, True,
         Local_Path => Target_Path);
      return True;
   exception
      when others =>
         declare
            Reason : constant String := Sitefetch.Engine.Files.Write_Failure_Reason (Target_Path);
         begin
            Matches.Clear;
            Record_Failure (Statistics, Effective_URL, Reason);
            Emit_Progress_Detailed (Progress, Progress_Failed, With_Reason (Effective_URL, Reason),
               Depth => Depth, Has_Depth => True,
               Local_Path => Target_Path);
            return False;
         end;
   end Write_Recursive_Document;

   function Move_State_Download
     (State            : in out Fetch_State;
      Target_Directory : String;
      Download_Path    : String;
      Current_URL      : String;
      Final_URL        : Unbounded_String;
      Progress         : Progress_Callback;
      Limits           : Fetch_Options;
      Response_Info    : Http_Client.Responses.Response;
      Bytes_Written    : Natural := 0;
      Reserved_Bytes   : Natural := 0;
      Depth                 : Natural := 0;
      Redirect_Hops         : Natural := 0;
      Redirect_Status_Codes : String := "";
      Redirect_Target_URLs  : String := "";
      Redirect_Locations    : String := "") return Boolean
   is
      Effective_URL : constant String := Effective_Final_URL (Current_URL, Final_URL);
      Target_Path   : constant String :=
        Sitefetch.Engine.Files.Join_Path
          (Target_Directory, Local_Path_For_URL (Effective_URL));
   begin
      Mark_Redirected_URL (State, Current_URL, Effective_URL);
      Emit_Redirected (Progress, Current_URL, Effective_URL, Depth, True,
         Response_Status_Code (Response_Info), Redirect_Hops, Redirect_Status_Codes,
         Redirect_Target_URLs, Redirect_Locations);
      Sitefetch.Engine.Files.Move_File_If_Needed (Download_Path, Target_Path);
      State.Mark_Written (Bytes_Written, Reserved_Bytes);
      Emit_Progress_Detailed (Progress, Progress_Written, Effective_URL, Bytes_Written, True, Depth, True,
         Status_Code => Response_Status_Code (Response_Info),
         Local_Path  => Target_Path);
      if Cache_Writes_Downloads (Limits) then
         Write_Cache_Metadata (Target_Path, Current_URL, Effective_URL, Response_Info, Limits);
      end if;
      return True;
   exception
      when others =>
         declare
            Reason : constant String := Sitefetch.Engine.Files.Write_Failure_Reason (Target_Path);
         begin
            State.Release_Download_Budget (Reserved_Bytes);
            Sitefetch.Engine.Files.Delete_File_If_Present (Download_Path);
            State.Mark_Failed (Effective_URL, Reason);
            Emit_Progress_Detailed (Progress, Progress_Failed, With_Reason (Effective_URL, Reason),
               Depth => Depth, Has_Depth => True,
            Local_Path => Target_Path);
            return False;
         end;
   end Move_State_Download;

   function Move_Recursive_Download
     (Visited          : in out Link_List;
      Visited_Set      : in out URL_Sets.Set;
      Statistics       : in out Fetch_Statistics;
      Target_Directory : String;
      Download_Path    : String;
      Current_URL      : String;
      Final_URL        : Unbounded_String;
      Progress         : Progress_Callback;
      Bytes_Written    : Natural := 0;
      Depth            : Natural := 0) return Boolean
   is
      Effective_URL : constant String := Effective_Final_URL (Current_URL, Final_URL);
      Target_Path   : constant String :=
        Sitefetch.Engine.Files.Join_Path
          (Target_Directory, Local_Path_For_URL (Effective_URL));
   begin
      Mark_Redirected_URL (Visited, Visited_Set, Current_URL, Effective_URL);
      Sitefetch.Engine.Files.Move_File_If_Needed (Download_Path, Target_Path);
      Statistics.Written := Statistics.Written + 1;
      if Bytes_Written > Natural'Last - Statistics.Bytes_Written then
         Statistics.Bytes_Written := Natural'Last;
      else
         Statistics.Bytes_Written := Statistics.Bytes_Written + Bytes_Written;
      end if;
      Emit_Progress_Detailed (Progress, Progress_Written, Effective_URL, Bytes_Written, True, Depth, True,
         Local_Path => Target_Path);
      return True;
   exception
      when others =>
         declare
            Reason : constant String := Sitefetch.Engine.Files.Write_Failure_Reason (Target_Path);
         begin
            Sitefetch.Engine.Files.Delete_File_If_Present (Download_Path);
            Record_Failure (Statistics, Effective_URL, Reason);
            Emit_Progress_Detailed (Progress, Progress_Failed, With_Reason (Effective_URL, Reason),
               Depth => Depth, Has_Depth => True);
            return False;
         end;
   end Move_Recursive_Download;

   function Download_State_HTTP
     (State            : in out Fetch_State;
      Item             : in out Http_Client.Clients.Client;
      Target_Directory : String;
      Current_URL      : String;
      Progress         : Progress_Callback;
      Limits           : Fetch_Options;
      Depth            : Natural := 0) return Boolean
   is
      Target_Path      : constant String :=
        Sitefetch.Engine.Files.Join_Path
          (Target_Directory, Local_Path_For_URL (Current_URL));
      Download_Path    : constant String := Download_Staging_Path (Target_Path, Limits);
      Final_URL_Text   : Unbounded_String;
      Failure_Reason   : Unbounded_String;
      Downloaded_Bytes : Natural := 0;
      Reserved_Bytes   : Natural := 0;
      Not_Modified     : Boolean := False;
      Redirect_Hops         : Natural := 0;
      Redirect_Status_Codes : Unbounded_String := Null_Unbounded_String;
      Redirect_Target_URLs  : Unbounded_String := Null_Unbounded_String;
      Redirect_Locations    : Unbounded_String := Null_Unbounded_String;
      Response_Info         : Http_Client.Responses.Response;
   begin
      Emit_Dangerous_Download_If_Needed (Progress, Limits, Current_URL);
      State.Mark_Attempted;
      State.Reserve_Download_Budget (Reserved_Bytes);

      if Download_Path = "" then
         State.Release_Download_Budget (Reserved_Bytes);
         State.Mark_Failed (Current_URL, Sitefetch.Engine.Files.Write_Failure_Reason (Target_Path));
         Emit_Progress_Detailed (Progress,
            Progress_Failed,
            With_Reason (Current_URL, Sitefetch.Engine.Files.Write_Failure_Reason (Target_Path)),
            Depth => Depth,
            Has_Depth => True,
            Local_Path => Target_Path);
         return False;
      elsif Limits.Crawl.Max_Bytes > 0 and then Reserved_Bytes = 0 then
         State.Mark_Limited;
         Emit_Progress_Detailed (Progress, Progress_Skipped_Limit, Current_URL, Depth => Depth, Has_Depth => True,
            Local_Path => Target_Path);
         return False;
      elsif not HTTP_Download_Final
        (Item,
         Current_URL,
         Target_Path,
         Download_Path,
         Reserved_Bytes,
         Final_URL_Text,
         Failure_Reason,
         Downloaded_Bytes,
         Not_Modified,
         Redirect_Hops,
         Redirect_Status_Codes,
         Redirect_Target_URLs,
         Redirect_Locations,
         Response_Info,
         Progress,
         Limits)
      then
         State.Release_Download_Budget (Reserved_Bytes);
         if Cache_Reads_Downloads (Limits) and then Cache_Writes_Downloads (Limits) then
            Write_Cache_Metadata
              (Download_Path, Current_URL, Current_URL, Response_Info, Limits, Resume_Safe => True);
         end if;
         State.Mark_Failed (Current_URL, To_String (Failure_Reason));
         Emit_Progress_Detailed (Progress, Progress_Failed, With_Reason (Current_URL, To_String (Failure_Reason)),
            Depth => Depth, Has_Depth => True,
            Local_Path => Target_Path);
         return False;
      elsif Not_Modified then
         State.Mark_Written (0, Reserved_Bytes);
         Emit_Progress_Detailed (Progress, Progress_Written, Current_URL, 0, True, Depth, True,
            Status_Code => Response_Status_Code (Response_Info),
            Local_Path  => Target_Path);
         return True;
      else
         return Move_State_Download
           (State,
            Target_Directory,
            Download_Path,
            Current_URL,
            Final_URL_Text,
            Progress,
            Limits,
            Response_Info,
            Downloaded_Bytes,
            Reserved_Bytes,
            Depth,
            Redirect_Hops,
            To_String (Redirect_Status_Codes),
            To_String (Redirect_Target_URLs),
            To_String (Redirect_Locations));
      end if;
   end Download_State_HTTP;

   procedure Configure_Reusable_Client
     (Item   : in out Http_Client.Clients.Client;
      Status : out Http_Client.Errors.Result_Status;
      Limits : Fetch_Options)
   is
      Configuration : Http_Client.Clients.Client_Configuration :=
        Sitefetch.Client_Config.Reusable_Configuration (To_String (Limits.HTTP.User_Agent));
      Diagnostics : constant Http_Client.Diagnostics.Context_Access :=
        new Http_Client.Diagnostics.Diagnostics_Context;
      Ignored : Http_Client.Errors.Result_Status;
   begin
      Http_Client.Diagnostics.Initialize
        (Diagnostics.all, Observer => Redirect_Diagnostics_Observer'Access);
      Configuration.Execution.Diagnostics := Diagnostics;
      if Length (Limits.HTTP.Accept_Language) > 0 then
         Ignored := Http_Client.Headers.Set
           (Configuration.Default_Headers, "Accept-Language", To_String (Limits.HTTP.Accept_Language));
      end if;
      Ignored := Http_Client.Headers.Set
        (Configuration.Default_Headers, "Accept-Encoding", Effective_Accept_Encoding (Limits));
      pragma Unreferenced (Ignored);
      Status := Http_Client.Clients.Initialize (Item, Configuration);
   end Configure_Reusable_Client;

   function Effective_HTTP_Workers (Limits : Fetch_Options; Worker_Count : Positive) return Positive is
   begin
      if Limits.Crawl.Max_Per_Host_Connections = 0 then
         return Worker_Count;
      else
         return Positive'Max
           (1, Positive'Min (Worker_Count, Positive'Min
              (Max_Worker_Count, Positive (Limits.Crawl.Max_Per_Host_Connections))));
      end if;
   end Effective_HTTP_Workers;

   procedure Fetch_Parallel_HTTP
     (State            : in out Fetch_State;
      Root_URL         : String;
      Target_Directory : String;
      Progress         : Progress_Callback;
      Limits           : Fetch_Options;
      Worker_Count     : Positive;
      Robots           : Robots_Rules)
   is
      Worker_Total : constant Positive := Effective_HTTP_Workers (Limits, Worker_Count);

      task type Worker;

      task body Worker is
         use type Http_Client.Errors.Result_Status;

         Item           : Http_Client.Clients.Client;
         Status         : Http_Client.Errors.Result_Status;
         Work_URL       : Unbounded_String;
         Work_Depth     : Natural := 0;
         Work_Type      : Work_Kind := Work_Document;
         Has_Work       : Boolean;
         Current_URL    : Unbounded_String;
         Content_Text   : Unbounded_String;
         Final_URL_Text : Unbounded_String;
         Effective_URL  : Unbounded_String;
         Failure_Reason  : Unbounded_String;
         Parse_Content   : Boolean := True;
         Not_Modified    : Boolean := False;
         Redirect_Hops         : Natural := 0;
         Redirect_Status_Codes : Unbounded_String := Null_Unbounded_String;
         Redirect_Target_URLs  : Unbounded_String := Null_Unbounded_String;
         Redirect_Locations    : Unbounded_String := Null_Unbounded_String;
         Response_Info         : Http_Client.Responses.Response;
         Reserved_Bytes  : Natural := 0;
      begin
         Configure_Reusable_Client (Item, Status, Limits);
         if Status /= Http_Client.Errors.Ok then
            State.Mark_Attempted;
            State.Mark_Failed (Root_URL, Status_Reason (Status));
         else
            loop
               State.Next_URL (Work_URL, Work_Depth, Work_Type, Has_Work);
               exit when not Has_Work;

               Current_URL := Work_URL;
               Emit_Progress_Detailed (Progress, Progress_Fetching, To_String (Current_URL),
               Depth => Work_Depth, Has_Depth => True);

               if Work_Type = Work_Download then
                  if not Download_State_HTTP
                    (State, Item, Target_Directory, To_String (Current_URL), Progress, Limits, Work_Depth)
                  then
                     null;
                  end if;
               else
                  declare
                     Probe_URL      : Unbounded_String;
                     Probe_Download : Boolean := False;
                     Probe_Known    : constant Boolean := Limits.Cache.Mode /= Cache_Offline
                       and then Should_Probe_With_HEAD (Limits, To_String (Current_URL))
                       and then HTTP_Probe_Download_Decision
                         (Item, To_String (Current_URL), Probe_URL, Probe_Download, Limits);
                  begin
                     if Probe_Known and then Probe_Download then
                        if Safety_Skips_Download (Limits, To_String (Probe_URL)) then
                           Mark_Safety_Skipped
                             (State, Progress, To_String (Probe_URL), Work_Depth, True);
                        elsif not Download_State_HTTP
                          (State, Item, Target_Directory, To_String (Current_URL), Progress, Limits, Work_Depth)
                        then
                           null;
                        end if;
                     else
                        State.Mark_Attempted;
                        if not HTTP_Fetch_Final
                          (Item,
                           To_String (Current_URL),
                           Sitefetch.Engine.Files.Join_Path
                             (Target_Directory,
                              Local_Path_For_URL (To_String (Current_URL))),
                           Content_Text,
                           Final_URL_Text,
                           Failure_Reason,
                           Parse_Content,
                           Not_Modified,
                           Redirect_Hops,
                           Redirect_Status_Codes,
                           Redirect_Target_URLs,
                           Redirect_Locations,
                           Response_Info,
                           Progress,
                           Limits)
                        then
                           State.Mark_Failed (To_String (Current_URL), To_String (Failure_Reason));
                           Emit_Progress_Detailed
                             (Progress, Progress_Failed,
                              With_Reason (To_String (Current_URL), To_String (Failure_Reason)),
                              Depth => Work_Depth, Has_Depth => True,
                              Final_URL => To_String (Current_URL),
                              Local_Path =>
                                Sitefetch.Engine.Files.Join_Path
                                  (Target_Directory, Local_Path_For_URL (To_String (Current_URL))));
                        else
                           Effective_URL := To_Unbounded_String
                             (Effective_Final_URL (To_String (Current_URL), Final_URL_Text));
                           Mark_Redirected_URL (State, To_String (Current_URL), To_String (Effective_URL));
                           Emit_Redirected
                             (Progress, To_String (Current_URL), To_String (Effective_URL),
                              Work_Depth, True, Response_Status_Code (Response_Info),
                              Redirect_Hops, To_String (Redirect_Status_Codes),
                              To_String (Redirect_Target_URLs),
                              To_String (Redirect_Locations));
                           if not Write_State_Document
                             (State,
                              Target_Directory,
                              To_String (Content_Text),
                              To_String (Effective_URL),
                              Root_URL,
                              Progress,
                              Limits,
                              Work_Depth,
                              Parse_Content,
                              True,
                              Robots,
                              Response_Info,
                              Not_Modified)
                           then
                              null;
                           end if;
                        end if;
                     end if;
                  end;
               end if;

               State.Complete_URL;
            end loop;
         end if;
      end Worker;

      Workers : array (Positive range 1 .. Worker_Total) of Worker;
      pragma Unreferenced (Workers);
   begin
      null;
   end Fetch_Parallel_HTTP;

   procedure Fetch_Parallel_Injected
     (State            : in out Fetch_State;
      Root_URL         : String;
      Target_Directory : String;
      Fetcher          : Parallel_Fetcher_Access;
      Downloader       : Direct_Downloader_Access;
      Progress         : Progress_Callback;
      Limits           : Fetch_Options;
      Worker_Count     : Positive)
   is
      Worker_Total : constant Positive := Positive'Min (Worker_Count, Max_Worker_Count);

      task type Worker;

      task body Worker is
         Work_URL       : Unbounded_String;
         Work_Depth     : Natural := 0;
         Work_Type      : Work_Kind := Work_Document;
         Has_Work       : Boolean;
         Current_URL    : Unbounded_String;
         Content_Text   : Unbounded_String;
         Final_URL_Text : Unbounded_String;
         Effective_URL  : Unbounded_String;
         Failure_Reason : Unbounded_String;
         Downloaded_Bytes : Natural := 0;
         Reserved_Bytes  : Natural := 0;
      begin
         loop
            State.Next_URL (Work_URL, Work_Depth, Work_Type, Has_Work);
            exit when not Has_Work;

            Current_URL := Work_URL;
            Emit_Progress_Detailed (Progress, Progress_Fetching, To_String (Current_URL),
               Depth => Work_Depth, Has_Depth => True);

            if Work_Type = Work_Download and then Downloader /= null then
               declare
                  Target_Path : constant String :=
                    Sitefetch.Engine.Files.Join_Path (Target_Directory, Local_Path_For_URL (To_String (Current_URL)));
                  Download_Path : constant String :=
                    Sitefetch.Engine.Files.Available_Sibling_Path (Target_Path, ".sitefetch_download");
               begin
                  Emit_Dangerous_Download_If_Needed (Progress, Limits, To_String (Current_URL));
                  Downloaded_Bytes := 0;
                  State.Mark_Attempted;
                  State.Reserve_Download_Budget (Reserved_Bytes);
                  if Download_Path = "" then
                     State.Release_Download_Budget (Reserved_Bytes);
                     Failure_Reason := To_Unbounded_String (Sitefetch.Engine.Files.Write_Failure_Reason (Target_Path));
                     State.Mark_Failed (To_String (Current_URL), To_String (Failure_Reason));
                     Emit_Progress_Detailed
                       (Progress, Progress_Failed,
                        With_Reason (To_String (Current_URL), To_String (Failure_Reason)),
                        Depth => Work_Depth, Has_Depth => True,
                        Final_URL => To_String (Current_URL),
                        Local_Path => Target_Path);
                  elsif Limits.Crawl.Max_Bytes > 0 and then Reserved_Bytes = 0 then
                     State.Mark_Limited;
                     Emit_Progress_Detailed
                       (Progress, Progress_Skipped_Limit, To_String (Current_URL),
                        Depth => Work_Depth, Has_Depth => True,
                        Final_URL => To_String (Current_URL),
                        Local_Path => Target_Path);
                  elsif not Downloader
                    (To_String (Current_URL),
                     Download_Path,
                     Final_URL_Text,
                     Failure_Reason,
                     Downloaded_Bytes)
                  then
                     State.Release_Download_Budget (Reserved_Bytes);
                     Sitefetch.Engine.Files.Delete_File_If_Present (Download_Path);
                     State.Mark_Failed (To_String (Current_URL), To_String (Failure_Reason));
                     Emit_Progress_Detailed
                       (Progress, Progress_Failed,
                        With_Reason (To_String (Current_URL), To_String (Failure_Reason)),
                        Depth => Work_Depth, Has_Depth => True,
                        Final_URL => To_String (Current_URL),
                        Local_Path => Target_Path);
                  elsif Limits.Crawl.Max_Bytes > 0 and then Downloaded_Bytes > Reserved_Bytes then
                     State.Release_Download_Budget (Reserved_Bytes);
                     Sitefetch.Engine.Files.Delete_File_If_Present (Download_Path);
                     Failure_Reason := To_Unbounded_String (Byte_Limit_Reason (Limits.Crawl.Max_Bytes));
                     State.Mark_Failed (To_String (Current_URL), To_String (Failure_Reason));
                     Emit_Progress_Detailed
                       (Progress, Progress_Failed,
                        With_Reason (To_String (Current_URL), To_String (Failure_Reason)),
                        Depth => Work_Depth, Has_Depth => True,
                        Final_URL => To_String (Current_URL),
                        Local_Path => Target_Path);
                  else
                     if not Move_State_Download
                       (State,
                        Target_Directory,
                        Download_Path,
                        To_String (Current_URL),
                        Final_URL_Text,
                        Progress,
                        Limits,
                        Http_Client.Responses.Default_Response,
                        Downloaded_Bytes,
                        Reserved_Bytes,
                        Work_Depth)
                     then
                        null;
                     end if;
                  end if;
               end;
            else
               State.Mark_Attempted;
               if not Fetcher (To_String (Current_URL), Content_Text, Final_URL_Text, Failure_Reason) then
                  State.Mark_Failed (To_String (Current_URL), To_String (Failure_Reason));
                  Emit_Progress_Detailed
                    (Progress, Progress_Failed,
                     With_Reason (To_String (Current_URL), To_String (Failure_Reason)),
                     Depth => Work_Depth, Has_Depth => True,
                     Final_URL => To_String (Current_URL),
                     Local_Path =>
                       Sitefetch.Engine.Files.Join_Path
                         (Target_Directory, Local_Path_For_URL (To_String (Current_URL))));
               else
                  Effective_URL := To_Unbounded_String
                    (Effective_Final_URL (To_String (Current_URL), Final_URL_Text));
                  Mark_Redirected_URL (State, To_String (Current_URL), To_String (Effective_URL));
                  Emit_Redirected (Progress, To_String (Current_URL), To_String (Effective_URL), Work_Depth, True);
                  if not Write_State_Document
                    (State,
                     Target_Directory,
                     To_String (Content_Text),
                     To_String (Effective_URL),
                     Root_URL,
                     Progress,
                     Limits,
                     Work_Depth,
                     True,
                     True,
                     Ignore_Robots,
                     Http_Client.Responses.Default_Response)
                  then
                     null;
                  end if;
               end if;
            end if;

            State.Complete_URL;
         end loop;
      end Worker;

      Workers : array (Positive range 1 .. Worker_Total) of Worker;
      pragma Unreferenced (Workers);
   begin
      null;
   end Fetch_Parallel_Injected;

   function Fetch_Recursive
     (Page_URL         : String;
      Root_URL         : String;
      Target_Directory : String;
      Fetcher          : not null access function
        (Fetch_URL     : String;
         Document_Text : out Unbounded_String) return Boolean;
      Visited          : in out Link_List;
      Visited_Set      : in out URL_Sets.Set;
      Statistics       : in out Fetch_Statistics;
      Progress         : Progress_Callback;
      Limits           : Fetch_Options;
      Depth            : Natural) return Boolean
   is
      Current_URL  : constant String := Canonical_URL (Page_URL);
      Root_Domain  : constant String := Domain_Of (Root_URL);
      Content_Text : Unbounded_String;
      Matches      : Link_Match_Vectors.Vector;
      Links        : Link_List;
      Wrote_Root   : Boolean := False;
   begin
      if Visited_Set.Contains (Current_URL) then
         Emit_Progress_Detailed (Progress, Progress_Already_Visited, Current_URL,
            Depth => Depth, Has_Depth => True);
         return True;
      elsif Recursive_Limit_Reached (Visited, Statistics, Limits, Depth) then
         Statistics.Skipped_Limit := Statistics.Skipped_Limit + 1;
         Emit_Progress_Detailed (Progress, Progress_Skipped_Limit, Current_URL,
            Depth => Depth, Has_Depth => True);
         return True;
      end if;

      Visited.Append (Current_URL);
      Visited_Set.Include (Current_URL);
      Statistics.Attempted := Statistics.Attempted + 1;
      Emit_Progress_Detailed (Progress, Progress_Fetching, Current_URL, Depth => Depth, Has_Depth => True);
      if not Fetcher (Current_URL, Content_Text) then
         Record_Failure (Statistics, Current_URL);
         Emit_Progress_Detailed (Progress, Progress_Failed, Current_URL,
            Depth => Depth, Has_Depth => True,
            Local_Path =>
              Sitefetch.Engine.Files.Join_Path
                (Target_Directory, Local_Path_For_URL (Current_URL)));
         return False;
      end if;

      Wrote_Root := Write_Recursive_Document
        (Statistics,
         Target_Directory,
         To_String (Content_Text),
         Current_URL,
         Root_URL,
         Progress,
         True,
         Matches,
         Limits.Crawl.Domain,
         Depth);
      if not Wrote_Root then
         return False;
      end if;

      Links := Links_From_Matches (Matches);
      for Reference of Links loop
         if not Is_Fetchable_Reference (Reference) then
            Statistics.Skipped_Unsupported := Statistics.Skipped_Unsupported + 1;
            Emit_Progress_Detailed (Progress, Progress_Skipped_Unsupported, Reference,
               Depth => Depth + 1, Has_Depth => True);
         else
            declare
               Absolute_URL : constant String := Canonical_URL (Resolve_URL (Current_URL, Reference));
            begin
               if Is_In_Domain (Root_Domain, Absolute_URL, Limits.Crawl.Domain) then
                  Wrote_Root := Fetch_Recursive
                    (Absolute_URL,
                     Root_URL,
                     Target_Directory,
                     Fetcher,
                     Visited,
                     Visited_Set,
                     Statistics,
                     Progress,
                     Limits,
                     Depth + 1) and then Wrote_Root;
               else
                  Statistics.Skipped_External := Statistics.Skipped_External + 1;
                  Emit_Progress_Detailed (Progress, Progress_Skipped_External, Absolute_URL,
                     Depth => Depth + 1, Has_Depth => True);
               end if;
            end;
         end if;
      end loop;

      return Wrote_Root;
   end Fetch_Recursive;

   function Fetch_Recursive_HTTP
     (Item             : Http_Client.Clients.Client;
      Page_URL         : String;
      Root_URL         : String;
      Target_Directory : String;
      Visited          : in out Link_List;
      Visited_Set      : in out URL_Sets.Set;
      Statistics       : in out Fetch_Statistics;
      Progress         : Progress_Callback;
      Limits           : Fetch_Options;
      Depth            : Natural) return Boolean
   is
      Current_URL      : constant String := Canonical_URL (Page_URL);
      Content_Text     : Unbounded_String;
      Final_URL_Text   : Unbounded_String;
      Effective_URL    : Unbounded_String;
      Effective_Root   : Unbounded_String;
      Matches          : Link_Match_Vectors.Vector;
      Links            : Link_List;
      Failure_Reason   : Unbounded_String;
      Parse_Content    : Boolean := True;
      Not_Modified     : Boolean := False;
      Redirect_Hops         : Natural := 0;
      Redirect_Status_Codes : Unbounded_String := Null_Unbounded_String;
      Redirect_Target_URLs  : Unbounded_String := Null_Unbounded_String;
      Redirect_Locations    : Unbounded_String := Null_Unbounded_String;
      Response_Info         : Http_Client.Responses.Response;
      Wrote_Document   : Boolean := False;
   begin
      if Visited_Set.Contains (Current_URL) then
         Emit_Progress_Detailed (Progress, Progress_Already_Visited, Current_URL,
            Depth => Depth, Has_Depth => True);
         return True;
      elsif Recursive_Limit_Reached (Visited, Statistics, Limits, Depth) then
         Statistics.Skipped_Limit := Statistics.Skipped_Limit + 1;
         Emit_Progress_Detailed (Progress, Progress_Skipped_Limit, Current_URL,
            Depth => Depth, Has_Depth => True);
         return True;
      end if;

      Visited.Append (Current_URL);
      Visited_Set.Include (Current_URL);
      Statistics.Attempted := Statistics.Attempted + 1;
      Emit_Progress_Detailed (Progress, Progress_Fetching, Current_URL, Depth => Depth, Has_Depth => True);

      if not HTTP_Fetch_Final
        (Item, Current_URL, Sitefetch.Engine.Files.Join_Path (Target_Directory, Local_Path_For_URL (Current_URL)),
         Content_Text, Final_URL_Text, Failure_Reason, Parse_Content, Not_Modified,
         Redirect_Hops, Redirect_Status_Codes, Redirect_Target_URLs, Redirect_Locations,
         Response_Info, Progress, Limits)
      then
         Record_Failure (Statistics, Current_URL, To_String (Failure_Reason));
         Emit_Progress_Detailed (Progress, Progress_Failed, With_Reason (Current_URL, To_String (Failure_Reason)),
            Depth => Depth, Has_Depth => True,
            Status_Code => Response_Status_Code (Response_Info),
            Local_Path =>
              Sitefetch.Engine.Files.Join_Path
                (Target_Directory, Local_Path_For_URL (Current_URL)));
         return False;
      end if;

      if Not_Modified then
         Statistics.Written := Statistics.Written + 1;
         Emit_Progress_Detailed (Progress, Progress_Written, Current_URL, 0, True, Depth, True,
            Status_Code => Response_Status_Code (Response_Info),
            Local_Path =>
              Sitefetch.Engine.Files.Join_Path
                (Target_Directory, Local_Path_For_URL (Current_URL)));
         return True;
      end if;

      Effective_URL := To_Unbounded_String (Effective_Final_URL (Current_URL, Final_URL_Text));
      Mark_Redirected_URL (Visited, Visited_Set, Current_URL, To_String (Effective_URL));
      Emit_Redirected (Progress, Current_URL, To_String (Effective_URL), Depth, True,
         Response_Status_Code (Response_Info), Redirect_Hops, To_String (Redirect_Status_Codes),
         To_String (Redirect_Target_URLs), To_String (Redirect_Locations));
      Effective_Root := To_Unbounded_String (Effective_Root_URL (Root_URL, To_String (Effective_URL)));

      Wrote_Document := Write_Recursive_Document
        (Statistics,
         Target_Directory,
         To_String (Content_Text),
         To_String (Effective_URL),
         To_String (Effective_Root),
         Progress,
         Parse_Content,
         Matches,
         Limits.Crawl.Domain,
         Depth);
      if not Wrote_Document then
         return False;
      end if;

      if not Parse_Content then
         return Wrote_Document;
      end if;

      declare
         Effective_URL_Text : constant String := To_String (Effective_URL);
         Effective_Root_Text : constant String := To_String (Effective_Root);
         Effective_Root_Domain : constant String := Domain_Of (Effective_Root_Text);
      begin
         Links := Links_From_Matches (Matches);
         for Reference of Links loop
            if not Is_Fetchable_Reference (Reference) then
               Statistics.Skipped_Unsupported := Statistics.Skipped_Unsupported + 1;
               Emit_Progress_Detailed (Progress, Progress_Skipped_Unsupported, Reference,
               Depth => Depth + 1, Has_Depth => True);
            else
               declare
                  Absolute_URL : constant String :=
                    Canonical_URL (Resolve_URL (Effective_URL_Text, Reference));
               begin
                  if Is_In_Domain (Effective_Root_Domain, Absolute_URL, Limits.Crawl.Domain) then
                     if Should_Download_To_File (Absolute_URL)
                       and then Safety_Skips_Download (Limits, Absolute_URL)
                     then
                        Statistics.Skipped_Unsupported := Statistics.Skipped_Unsupported + 1;
                        Emit_Progress_Detailed (Progress, Progress_Skipped_Dangerous, Absolute_URL,
                           Depth => Depth + 1, Has_Depth => True,
                           Local_Path =>
                             Sitefetch.Engine.Files.Join_Path
                               (Target_Directory, Local_Path_For_URL (Absolute_URL)));
                     else
                        Wrote_Document := Fetch_Recursive_HTTP
                       (Item,
                        Absolute_URL,
                        Effective_Root_Text,
                        Target_Directory,
                        Visited,
                        Visited_Set,
                        Statistics,
                        Progress,
                        Limits,
                        Depth + 1) and then Wrote_Document;
                     end if;
                  else
                     Statistics.Skipped_External := Statistics.Skipped_External + 1;
                     Emit_Progress_Detailed (Progress, Progress_Skipped_External, Absolute_URL,
                     Depth => Depth + 1, Has_Depth => True);
                  end if;
               end;
            end if;
         end loop;
      end;

      return Wrote_Document;
   end Fetch_Recursive_HTTP;

   function Fetch_Recursive_Final
     (Page_URL         : String;
      Root_URL         : String;
      Target_Directory : String;
      Fetcher          : Final_Fetcher_Access;
      Downloader       : Direct_Downloader_Access;
      Visited          : in out Link_List;
      Visited_Set      : in out URL_Sets.Set;
      Statistics       : in out Fetch_Statistics;
      Progress         : Progress_Callback;
      Limits           : Fetch_Options;
      Depth            : Natural) return Boolean
   is
      Current_URL      : constant String := Canonical_URL (Page_URL);
      Content_Text     : Unbounded_String;
      Final_URL_Text   : Unbounded_String;
      Effective_URL    : Unbounded_String;
      Effective_Root   : Unbounded_String;
      Matches          : Link_Match_Vectors.Vector;
      Links            : Link_List;
      Failure_Reason   : Unbounded_String;
      Wrote_Document   : Boolean := False;
   begin
      if Visited_Set.Contains (Current_URL) then
         Emit_Progress_Detailed (Progress, Progress_Already_Visited, Current_URL,
            Depth => Depth, Has_Depth => True);
         return True;
      elsif Recursive_Limit_Reached (Visited, Statistics, Limits, Depth) then
         Statistics.Skipped_Limit := Statistics.Skipped_Limit + 1;
         Emit_Progress_Detailed (Progress, Progress_Skipped_Limit, Current_URL,
            Depth => Depth, Has_Depth => True);
         return True;
      end if;

      Visited.Append (Current_URL);
      Visited_Set.Include (Current_URL);

      if Downloader /= null and then Should_Download_To_File (Current_URL)
        and then Safety_Skips_Download (Limits, Current_URL)
      then
         Statistics.Skipped_Unsupported := Statistics.Skipped_Unsupported + 1;
         Emit_Progress_Detailed (Progress, Progress_Skipped_Dangerous, Current_URL,
            Depth => Depth, Has_Depth => True,
            Local_Path =>
              Sitefetch.Engine.Files.Join_Path
                (Target_Directory, Local_Path_For_URL (Current_URL)));
         return True;
      end if;

      Statistics.Attempted := Statistics.Attempted + 1;
      Emit_Progress_Detailed (Progress, Progress_Fetching, Current_URL, Depth => Depth, Has_Depth => True);

      if Downloader /= null and then Should_Download_To_File (Current_URL) then
         Emit_Dangerous_Download_If_Needed (Progress, Limits, Current_URL);
         declare
            Target_Path : constant String :=
        Sitefetch.Engine.Files.Join_Path
          (Target_Directory, Local_Path_For_URL (Current_URL));
            Download_Path : constant String :=
              Sitefetch.Engine.Files.Available_Sibling_Path
                (Target_Path, ".sitefetch_download");
            Downloaded_Bytes : Natural := 0;
         begin
            Downloaded_Bytes := 0;
            if Download_Path = "" then
               Failure_Reason := To_Unbounded_String (Sitefetch.Engine.Files.Write_Failure_Reason (Target_Path));
               Record_Failure (Statistics, Current_URL, To_String (Failure_Reason));
               Emit_Progress_Detailed (Progress, Progress_Failed, With_Reason (Current_URL, To_String (Failure_Reason)),
                  Depth => Depth, Has_Depth => True,
                  Local_Path => Target_Path);
               return False;
            elsif not Downloader (Current_URL, Download_Path, Final_URL_Text, Failure_Reason, Downloaded_Bytes) then
               Sitefetch.Engine.Files.Delete_File_If_Present (Download_Path);
               Record_Failure (Statistics, Current_URL, To_String (Failure_Reason));
               Emit_Progress_Detailed (Progress, Progress_Failed, With_Reason (Current_URL, To_String (Failure_Reason)),
                  Bytes_Written => Downloaded_Bytes, Has_Bytes => True,
                  Depth => Depth, Has_Depth => True,
                  Local_Path => Target_Path);
               return False;
            end if;

            return Move_Recursive_Download
              (Visited,
               Visited_Set,
               Statistics,
               Target_Directory,
               Download_Path,
               Current_URL,
               Final_URL_Text,
               Progress,
               Downloaded_Bytes,
               Depth);
         end;
      end if;

      if not Fetcher (Current_URL, Content_Text, Final_URL_Text) then
         Record_Failure (Statistics, Current_URL);
         Emit_Progress_Detailed (Progress, Progress_Failed, Current_URL,
            Depth => Depth, Has_Depth => True,
            Local_Path =>
              Sitefetch.Engine.Files.Join_Path
                (Target_Directory, Local_Path_For_URL (Current_URL)));
         return False;
      end if;

      Effective_URL := To_Unbounded_String (Effective_Final_URL (Current_URL, Final_URL_Text));
      Mark_Redirected_URL (Visited, Visited_Set, Current_URL, To_String (Effective_URL));
      Emit_Redirected (Progress, Current_URL, To_String (Effective_URL), Depth, True);
      Effective_Root := To_Unbounded_String (Effective_Root_URL (Root_URL, To_String (Effective_URL)));

      Wrote_Document := Write_Recursive_Document
        (Statistics,
         Target_Directory,
         To_String (Content_Text),
         To_String (Effective_URL),
         To_String (Effective_Root),
         Progress,
         True,
         Matches,
         Limits.Crawl.Domain,
         Depth);
      if not Wrote_Document then
         return False;
      end if;

      declare
         Effective_URL_Text : constant String := To_String (Effective_URL);
         Effective_Root_Text : constant String := To_String (Effective_Root);
         Effective_Root_Domain : constant String := Domain_Of (Effective_Root_Text);
      begin
         Links := Links_From_Matches (Matches);
         for Reference of Links loop
            if not Is_Fetchable_Reference (Reference) then
               Statistics.Skipped_Unsupported := Statistics.Skipped_Unsupported + 1;
               Emit_Progress_Detailed (Progress, Progress_Skipped_Unsupported, Reference,
               Depth => Depth + 1, Has_Depth => True);
            else
               declare
                  Absolute_URL : constant String :=
                    Canonical_URL (Resolve_URL (Effective_URL_Text, Reference));
               begin
                  if Is_In_Domain (Effective_Root_Domain, Absolute_URL, Limits.Crawl.Domain) then
                     if Should_Download_To_File (Absolute_URL)
                       and then Safety_Skips_Download (Limits, Absolute_URL)
                     then
                        Statistics.Skipped_Unsupported := Statistics.Skipped_Unsupported + 1;
                        Emit_Progress_Detailed (Progress, Progress_Skipped_Dangerous, Absolute_URL,
                           Depth => Depth + 1, Has_Depth => True,
                           Local_Path =>
                             Sitefetch.Engine.Files.Join_Path
                               (Target_Directory, Local_Path_For_URL (Absolute_URL)));
                     else
                        Wrote_Document := Fetch_Recursive_Final
                       (Absolute_URL,
                        Effective_Root_Text,
                        Target_Directory,
                        Fetcher,
                        Downloader,
                        Visited,
                        Visited_Set,
                        Statistics,
                        Progress,
                        Limits,
                        Depth + 1) and then Wrote_Document;
                     end if;
                  else
                     Statistics.Skipped_External := Statistics.Skipped_External + 1;
                     Emit_Progress_Detailed (Progress, Progress_Skipped_External, Absolute_URL,
                     Depth => Depth + 1, Has_Depth => True);
                  end if;
               end;
            end if;
         end loop;
      end;

      return Wrote_Document;
   end Fetch_Recursive_Final;

   function Fetch_Website_With_Parallel_Fetcher_And_Downloader
     (URL              : String;
      Target_Directory : String;
      Fetcher          : Parallel_Fetcher_Access;
      Downloader       : not null Direct_Downloader_Access;
      Statistics       : out Fetch_Statistics;
      Progress         : Progress_Callback;
      Options          : Fetch_Options)
      return Boolean;

   function Fetch_Website_With_Parallel_Fetcher
     (URL              : String;
      Target_Directory : String;
      Fetcher          : Parallel_Fetcher_Access;
      Statistics       : out Fetch_Statistics;
      Progress         : Progress_Callback)
      return Boolean
   is
      Root_URL       : constant String := Canonical_URL (URL);
      State          : Fetch_State;
      Claim_Result   : Claim_Status;
      Content_Text   : Unbounded_String;
      Final_URL_Text : Unbounded_String;
      Effective_Root : Unbounded_String;
      Failure_Reason : Unbounded_String;
      Guard          : Fetch_Run_Guard;
      pragma Unreferenced (Guard);
   begin
      Begin_Fetch_Run;
      Statistics := (others => <>);
      State.Configure_Limits (Default_Fetch_Options);
      State.Claim_URL (Root_URL, 0, Claim_Result);
      Emit_Progress_Detailed (Progress, Progress_Fetching, Root_URL, Depth => 0, Has_Depth => True);

      State.Mark_Attempted;
      if not Fetcher (Root_URL, Content_Text, Final_URL_Text, Failure_Reason) then
         State.Mark_Failed (Root_URL, To_String (Failure_Reason));
         Statistics := State.Snapshot;
         Emit_Progress_Detailed (Progress, Progress_Failed, With_Reason (Root_URL, To_String (Failure_Reason)),
            Depth => 0, Has_Depth => True,
            Final_URL => To_String (Final_URL_Text),
            Local_Path => Sitefetch.Engine.Files.Join_Path (Target_Directory, Local_Path_For_URL (Root_URL)));
         return False;
      end if;


      Effective_Root := To_Unbounded_String (Effective_Final_URL (Root_URL, Final_URL_Text));
      Mark_Redirected_URL (State, Root_URL, To_String (Effective_Root));
      Emit_Redirected (Progress, Root_URL, To_String (Effective_Root), 0, True);
      if not Write_State_Document
        (State,
         Target_Directory,
         To_String (Content_Text),
         To_String (Effective_Root),
         To_String (Effective_Root),
         Progress,
         Default_Fetch_Options,
         0,
         True,
         True,
         Ignore_Robots,
         Http_Client.Responses.Default_Response)
      then
         Statistics := State.Snapshot;
         return False;
      end if;

      Fetch_Parallel_Injected
        (State, To_String (Effective_Root), Target_Directory, Fetcher, null, Progress,
         Default_Fetch_Options, Default_Fetch_Options.Crawl.Workers);

      Statistics := State.Snapshot;
      return Statistics.Failed = 0;
   end Fetch_Website_With_Parallel_Fetcher;

   function Fetch_Website_With_Parallel_Fetcher_And_Downloader
     (URL              : String;
      Target_Directory : String;
      Fetcher          : Parallel_Fetcher_Access;
      Downloader       : not null Direct_Downloader_Access;
      Statistics       : out Fetch_Statistics;
      Progress         : Progress_Callback)
      return Boolean
   is
   begin
      return Fetch_Website_With_Parallel_Fetcher_And_Downloader
        (URL, Target_Directory, Fetcher, Downloader, Statistics, Progress, Default_Fetch_Options);
   end Fetch_Website_With_Parallel_Fetcher_And_Downloader;

   function Fetch_Website_With_Parallel_Fetcher_And_Downloader
     (URL              : String;
      Target_Directory : String;
      Fetcher          : Parallel_Fetcher_Access;
      Downloader       : not null Direct_Downloader_Access;
      Statistics       : out Fetch_Statistics;
      Progress         : Progress_Callback;
      Options          : Fetch_Options)
      return Boolean
   is
      Limits         : constant Fetch_Options := Options;
      Root_URL       : constant String := Canonical_URL (URL);
      State          : Fetch_State;
      Claim_Result   : Claim_Status;
      Content_Text   : Unbounded_String;
      Final_URL_Text : Unbounded_String;
      Effective_Root : Unbounded_String;
      Failure_Reason : Unbounded_String;
      Downloaded_Bytes : Natural := 0;
      Target_Path    : constant String :=
        Sitefetch.Engine.Files.Join_Path
          (Target_Directory, Local_Path_For_URL (Root_URL));
      Download_Path  : constant String :=
        Sitefetch.Engine.Files.Available_Sibling_Path
          (Target_Path, ".sitefetch_download");
      Guard          : Fetch_Run_Guard;
      pragma Unreferenced (Guard);
   begin
      Begin_Fetch_Run;
      Statistics := (others => <>);
      State.Configure_Limits (Limits);
      State.Claim_URL (Root_URL, 0, Claim_Result);
      Emit_Progress_Detailed (Progress, Progress_Fetching, Root_URL, Depth => 0, Has_Depth => True);

      if Should_Download_To_File (Root_URL) then
         if Safety_Skips_Download (Limits, Root_URL) then
            Mark_Safety_Skipped (State, Progress, Root_URL, 0, True);
            Statistics := State.Snapshot;
            return True;
         end if;

         Emit_Dangerous_Download_If_Needed (Progress, Limits, Root_URL);
         Downloaded_Bytes := 0;
         State.Mark_Attempted;
         State.Reserve_Download_Budget (Downloaded_Bytes);
         if Download_Path = "" then
            State.Release_Download_Budget (Downloaded_Bytes);
            Failure_Reason := To_Unbounded_String (Sitefetch.Engine.Files.Write_Failure_Reason (Target_Path));
            State.Mark_Failed (Root_URL, To_String (Failure_Reason));
            Statistics := State.Snapshot;
            Emit_Progress_Detailed
              (Progress, Progress_Failed, With_Reason (Root_URL, To_String (Failure_Reason)),
               Depth => 0, Has_Depth => True,
               Final_URL => Root_URL,
               Local_Path => Target_Path);
            return False;
         elsif Limits.Crawl.Max_Bytes > 0 and then Downloaded_Bytes = 0 then
            State.Mark_Limited;
            Statistics := State.Snapshot;
            Emit_Progress_Detailed
              (Progress, Progress_Skipped_Limit, Root_URL,
               Depth => 0, Has_Depth => True,
               Final_URL => Root_URL,
               Local_Path => Target_Path);
            return False;
         end if;

         declare
            Reserved_Bytes : constant Natural := Downloaded_Bytes;
         begin
            Downloaded_Bytes := 0;
            if not Downloader (Root_URL, Download_Path, Final_URL_Text, Failure_Reason, Downloaded_Bytes) then
               State.Release_Download_Budget (Reserved_Bytes);
               Sitefetch.Engine.Files.Delete_File_If_Present (Download_Path);
               State.Mark_Failed (Root_URL, To_String (Failure_Reason));
               Statistics := State.Snapshot;
               Emit_Progress_Detailed
              (Progress, Progress_Failed, With_Reason (Root_URL, To_String (Failure_Reason)),
               Depth => 0, Has_Depth => True,
               Final_URL => Root_URL,
               Local_Path => Target_Path);
               return False;
            elsif Limits.Crawl.Max_Bytes > 0 and then Downloaded_Bytes > Reserved_Bytes then
               State.Release_Download_Budget (Reserved_Bytes);
               Sitefetch.Engine.Files.Delete_File_If_Present (Download_Path);
               Failure_Reason := To_Unbounded_String (Byte_Limit_Reason (Limits.Crawl.Max_Bytes));
               State.Mark_Failed (Root_URL, To_String (Failure_Reason));
               Statistics := State.Snapshot;
               Emit_Progress_Detailed
              (Progress, Progress_Failed, With_Reason (Root_URL, To_String (Failure_Reason)),
               Depth => 0, Has_Depth => True,
               Final_URL => Root_URL,
               Local_Path => Target_Path);
               return False;
            end if;

            if not Move_State_Download
              (State,
               Target_Directory,
               Download_Path,
               Root_URL,
               Final_URL_Text,
               Progress,
               Limits,
               Http_Client.Responses.Default_Response,
               Downloaded_Bytes,
               Reserved_Bytes)
            then
               Statistics := State.Snapshot;
               return False;
            end if;
         end;

         Statistics := State.Snapshot;
         return Statistics.Failed = 0;
      end if;

      State.Mark_Attempted;
      if not Fetcher (Root_URL, Content_Text, Final_URL_Text, Failure_Reason) then
         State.Mark_Failed (Root_URL, To_String (Failure_Reason));
         Statistics := State.Snapshot;
         Emit_Progress_Detailed (Progress, Progress_Failed, With_Reason (Root_URL, To_String (Failure_Reason)),
            Depth => 0, Has_Depth => True,
            Final_URL => To_String (Final_URL_Text),
            Local_Path => Sitefetch.Engine.Files.Join_Path (Target_Directory, Local_Path_For_URL (Root_URL)));
         return False;
      end if;

      Effective_Root := To_Unbounded_String (Effective_Final_URL (Root_URL, Final_URL_Text));
      Mark_Redirected_URL (State, Root_URL, To_String (Effective_Root));
      Emit_Redirected (Progress, Root_URL, To_String (Effective_Root), 0, True);
      if not Write_State_Document
        (State,
         Target_Directory,
         To_String (Content_Text),
         To_String (Effective_Root),
         To_String (Effective_Root),
         Progress,
         Limits,
         0,
         True,
         True,
         Ignore_Robots,
         Http_Client.Responses.Default_Response)
      then
         Statistics := State.Snapshot;
         return False;
      end if;

      Fetch_Parallel_Injected
        (State, To_String (Effective_Root), Target_Directory, Fetcher, Downloader, Progress,
         Limits, Limits.Crawl.Workers);

      Statistics := State.Snapshot;
      return Statistics.Failed = 0;
   end Fetch_Website_With_Parallel_Fetcher_And_Downloader;

   function Fetch_Website_With_Final_Fetcher
     (URL              : String;
      Target_Directory : String;
      Fetcher          : Final_Fetcher_Access;
      Statistics       : out Fetch_Statistics;
      Progress         : Progress_Callback)
      return Boolean
   is
      Root_URL : constant String := Canonical_URL (URL);
      Visited     : Link_List;
      Visited_Set : URL_Sets.Set;
      Result   : Boolean;
      Guard    : Fetch_Run_Guard;
      pragma Unreferenced (Guard);
   begin
      Begin_Fetch_Run;
      Statistics := (others => <>);
      Result := Fetch_Recursive_Final
        (Root_URL,
         "",
         Target_Directory,
         Fetcher,
         null,
         Visited,
         Visited_Set,
         Statistics,
         Progress,
         Default_Fetch_Options,
         0);
      return Result and then Statistics.Failed = 0;
   end Fetch_Website_With_Final_Fetcher;

   function Fetch_Website_With_Final_Fetcher
     (URL              : String;
      Target_Directory : String;
      Fetcher          : Final_Fetcher_Access;
      Statistics       : out Fetch_Statistics;
      Progress         : Progress_Callback;
      Options          : Fetch_Options)
      return Boolean
   is
      Limits   : constant Fetch_Options := Options;
      Root_URL : constant String := Canonical_URL (URL);
      Visited     : Link_List;
      Visited_Set : URL_Sets.Set;
      Result   : Boolean;
      Guard    : Fetch_Run_Guard;
      pragma Unreferenced (Guard);
   begin
      Begin_Fetch_Run;
      Statistics := (others => <>);
      Result := Fetch_Recursive_Final
        (Root_URL,
         "",
         Target_Directory,
         Fetcher,
         null,
         Visited,
         Visited_Set,
         Statistics,
         Progress,
         Limits,
         0);
      return Result and then Statistics.Failed = 0;
   end Fetch_Website_With_Final_Fetcher;

   function Fetch_Website_With_Final_Fetcher_And_Downloader
     (URL              : String;
      Target_Directory : String;
      Fetcher          : Final_Fetcher_Access;
      Downloader       : not null Direct_Downloader_Access;
      Statistics       : out Fetch_Statistics;
      Progress         : Progress_Callback)
      return Boolean
   is
      Root_URL : constant String := Canonical_URL (URL);
      Visited     : Link_List;
      Visited_Set : URL_Sets.Set;
      Result   : Boolean;
      Guard    : Fetch_Run_Guard;
      pragma Unreferenced (Guard);
   begin
      Begin_Fetch_Run;
      Statistics := (others => <>);
      Result := Fetch_Recursive_Final
        (Root_URL,
         "",
         Target_Directory,
         Fetcher,
         Downloader,
         Visited,
         Visited_Set,
         Statistics,
         Progress,
         Default_Fetch_Options,
         0);
      return Result and then Statistics.Failed = 0;
   end Fetch_Website_With_Final_Fetcher_And_Downloader;

   function Fetch_Website_With_Fetcher
     (URL              : String;
      Target_Directory : String;
      Fetcher          : not null access function
        (Fetch_URL     : String;
         Document_Text : out Unbounded_String) return Boolean;
      Statistics       : out Fetch_Statistics;
      Progress         : Progress_Callback)
      return Boolean
   is
      Root_URL : constant String := Canonical_URL (URL);
      Visited     : Link_List;
      Visited_Set : URL_Sets.Set;
      Result   : Boolean;
      Guard    : Fetch_Run_Guard;
      pragma Unreferenced (Guard);
   begin
      Begin_Fetch_Run;
      Statistics := (others => <>);
      Result := Fetch_Recursive
        (Root_URL,
         Root_URL,
         Target_Directory,
         Fetcher,
         Visited,
         Visited_Set,
         Statistics,
         Progress,
         Default_Fetch_Options,
         0);
      return Result and then Statistics.Failed = 0;
   end Fetch_Website_With_Fetcher;

   function Fetch_Website_With_Fetcher
     (URL              : String;
      Target_Directory : String;
      Fetcher          : not null access function
        (Fetch_URL     : String;
         Document_Text : out Unbounded_String) return Boolean;
      Statistics       : out Fetch_Statistics)
      return Boolean
   is
   begin
      return Fetch_Website_With_Fetcher (URL, Target_Directory, Fetcher, Statistics, null);
   end Fetch_Website_With_Fetcher;

   function Fetch_Website_With_Fetcher
     (URL              : String;
      Target_Directory : String;
      Fetcher          : not null access function
        (Fetch_URL     : String;
         Document_Text : out Unbounded_String) return Boolean)
      return Boolean
   is
      Statistics : Fetch_Statistics;
   begin
      return Fetch_Website_With_Fetcher (URL, Target_Directory, Fetcher, Statistics);
   end Fetch_Website_With_Fetcher;

   function Fetch_Website_With_Simple_Injected_Fetcher
     (URL              : String;
      Target_Directory : String;
      Fetcher          : Simple_Fetcher_Access;
      Statistics       : out Fetch_Statistics;
      Progress         : Progress_Callback) return Boolean
   is
   begin
      if Fetcher = null then
         return False;
      end if;

      return Fetch_Website_With_Fetcher
        (URL, Target_Directory, Simple_Fetcher_Access (Fetcher), Statistics, Progress);
   end Fetch_Website_With_Simple_Injected_Fetcher;

   function Fetch_Website_With_Final_Injected_Download
     (URL              : String;
      Target_Directory : String;
      Fetcher          : Final_Fetcher_Access;
      Downloader       : Direct_Downloader_Access;
      Statistics       : out Fetch_Statistics;
      Progress         : Progress_Callback) return Boolean
   is
   begin
      if Fetcher = null or else Downloader = null then
         return False;
      end if;

      return Fetch_Website_With_Final_Fetcher_And_Downloader
        (URL, Target_Directory, Fetcher, Downloader, Statistics, Progress);
   end Fetch_Website_With_Final_Injected_Download;

   function Fetch_Website_With_Parallel_Injected_Download
     (URL              : String;
      Target_Directory : String;
      Fetcher          : Parallel_Fetcher_Access;
      Downloader       : Direct_Downloader_Access;
      Statistics       : out Fetch_Statistics;
      Progress         : Progress_Callback;
      Options          : Fetch_Options) return Boolean
   is
   begin
      if Fetcher = null or else Downloader = null then
         return False;
      end if;

      return Fetch_Website_With_Parallel_Fetcher_And_Downloader
        (URL, Target_Directory, Fetcher, Downloader, Statistics, Progress, Options);
   end Fetch_Website_With_Parallel_Injected_Download;

   function Fetch_Website
     (URL              : String;
      Target_Directory : String;
      Statistics       : out Fetch_Statistics;
      Progress         : Progress_Callback := null;
      Options          : Fetch_Options := Default_Fetch_Options) return Boolean
   is
      use type Http_Client.Errors.Result_Status;

      Limits          : constant Fetch_Options := Options;

      Item            : Http_Client.Clients.Client;
      Status          : Http_Client.Errors.Result_Status;
      Root_URL        : constant String := Canonical_URL (URL);
      State           : Fetch_State;
      Claim_Result    : Claim_Status;
      Content_Text    : Unbounded_String;
      Final_URL_Text  : Unbounded_String;
      Effective_Root  : Unbounded_String;
      Failure_Reason  : Unbounded_String;
      Parse_Content   : Boolean := True;
      Not_Modified    : Boolean := False;
      Redirect_Hops         : Natural := 0;
      Redirect_Status_Codes : Unbounded_String := Null_Unbounded_String;
      Redirect_Target_URLs  : Unbounded_String := Null_Unbounded_String;
      Redirect_Locations    : Unbounded_String := Null_Unbounded_String;
      Response_Info         : Http_Client.Responses.Response;
      Guard          : Fetch_Run_Guard;
      pragma Unreferenced (Guard);
   begin
      Begin_Fetch_Run;
      Statistics := (others => <>);
      Configure_Reusable_Client (Item, Status, Limits);
      if Status /= Http_Client.Errors.Ok then
         Statistics.Attempted := 1;
         Record_Failure (Statistics, Root_URL, Status_Reason (Status));
         Emit_Progress_Detailed (Progress, Progress_Failed, With_Reason (Root_URL, Status_Reason (Status)),
            Depth => 0, Has_Depth => True,
            Local_Path => Sitefetch.Engine.Files.Join_Path (Target_Directory, Local_Path_For_URL (Root_URL)));
         return False;
      end if;

      State.Configure_Limits (Limits);
      State.Claim_URL (Root_URL, 0, Claim_Result);
      if Should_Download_To_File (Root_URL) and then Safety_Skips_Download (Limits, Root_URL) then
         Mark_Safety_Skipped (State, Progress, Root_URL);
         Statistics := State.Snapshot;
         return True;
      end if;

      Emit_Progress_Detailed (Progress, Progress_Fetching, Root_URL, Depth => 0, Has_Depth => True);

      if Should_Download_To_File (Root_URL) then
         if not Download_State_HTTP (State, Item, Target_Directory, Root_URL, Progress, Limits) then
            Statistics := State.Snapshot;
            return False;
         end if;

         Statistics := State.Snapshot;
         return Statistics.Failed = 0;
      end if;

      declare
         Probe_URL      : Unbounded_String;
         Probe_Download : Boolean := False;
         Probe_Known    : constant Boolean := Limits.Cache.Mode /= Cache_Offline
           and then Should_Probe_With_HEAD (Limits, Root_URL)
           and then HTTP_Probe_Download_Decision (Item, Root_URL, Probe_URL, Probe_Download, Limits);
      begin
         if Probe_Known and then Probe_Download then
            if Safety_Skips_Download (Limits, To_String (Probe_URL)) then
               Mark_Safety_Skipped (State, Progress, To_String (Probe_URL));
               Statistics := State.Snapshot;
               return True;
            elsif not Download_State_HTTP (State, Item, Target_Directory, Root_URL, Progress, Limits) then
               Statistics := State.Snapshot;
               return False;
            else
               Statistics := State.Snapshot;
               return Statistics.Failed = 0;
            end if;
         end if;
      end;

      State.Mark_Attempted;
      if not HTTP_Fetch_Final
        (Item, Root_URL, Sitefetch.Engine.Files.Join_Path (Target_Directory, Local_Path_For_URL (Root_URL)),
         Content_Text, Final_URL_Text, Failure_Reason, Parse_Content, Not_Modified,
         Redirect_Hops, Redirect_Status_Codes, Redirect_Target_URLs, Redirect_Locations,
         Response_Info, Progress, Limits)
      then
         State.Mark_Failed (Root_URL, To_String (Failure_Reason));
         Statistics := State.Snapshot;
         Emit_Progress_Detailed (Progress, Progress_Failed, With_Reason (Root_URL, To_String (Failure_Reason)),
            Depth => 0, Has_Depth => True,
            Status_Code => Response_Status_Code (Response_Info),
            Final_URL => To_String (Final_URL_Text),
            Local_Path => Sitefetch.Engine.Files.Join_Path (Target_Directory, Local_Path_For_URL (Root_URL)));
         return False;
      end if;

      Effective_Root := To_Unbounded_String (Effective_Final_URL (Root_URL, Final_URL_Text));
      Mark_Redirected_URL (State, Root_URL, To_String (Effective_Root));
      Emit_Redirected (Progress, Root_URL, To_String (Effective_Root), 0, True,
         Response_Status_Code (Response_Info), Redirect_Hops, To_String (Redirect_Status_Codes),
         To_String (Redirect_Target_URLs), To_String (Redirect_Locations));
      declare
         Robots           : constant Robots_Rules :=
           Load_Robots (Item, To_String (Effective_Root), Limits, Progress);
         Effective_Limits : constant Fetch_Options := Apply_Robots_Delay (Limits, Robots);
      begin
      if not Write_State_Document
        (State,
         Target_Directory,
         To_String (Content_Text),
         To_String (Effective_Root),
         To_String (Effective_Root),
         Progress,
         Effective_Limits,
         0,
         Parse_Content,
         Parse_Content,
         Robots,
         Response_Info,
         Not_Modified)
      then
         Statistics := State.Snapshot;
         return False;
      end if;

      if Parse_Content then
         Enqueue_Robots_Sitemaps (State, To_String (Effective_Root), Robots, Effective_Limits, Progress);
         Fetch_Parallel_HTTP
           (State,
            To_String (Effective_Root),
            Target_Directory,
            Progress,
            Effective_Limits,
            Effective_Limits.Crawl.Workers,
            Robots);
      end if;
      end;

      Statistics := State.Snapshot;
      return Statistics.Failed = 0;
   end Fetch_Website;

   function Fetch_Website_With_Structured_Progress
     (URL              : String;
      Target_Directory : String;
      Statistics       : out Fetch_Statistics;
      Progress         : Structured_Progress_Callback;
      Options          : Fetch_Options := Default_Fetch_Options) return Boolean
   is
      Result : Boolean;
      Guard  : Fetch_Run_Guard;
      pragma Unreferenced (Guard);
   begin
      Set_Structured_Progress (Progress);
      begin
         Result := Fetch_Website
           (URL, Target_Directory, Statistics,
            (if Progress = null then Progress_Callback'(null)
             else Structured_Progress_Adapter'Access),
            Options);
      exception
         when others =>
            Clear_Structured_Progress;
            raise;
      end;
      Clear_Structured_Progress;
      return Result;
   end Fetch_Website_With_Structured_Progress;

end Sitefetch.Engine;
