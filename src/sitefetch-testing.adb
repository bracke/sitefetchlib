with Ada.Strings.Unbounded;
with Sitefetch.Engine;

package body Sitefetch.Testing is
   use Ada.Strings.Unbounded;
   use type Sitefetch.Engine.Simple_Fetcher_Access;
   use type Sitefetch.Engine.Final_Fetcher_Access;
   use type Sitefetch.Engine.Direct_Downloader_Access;
   use type Sitefetch.Engine.Parallel_Fetcher_Access;

   Unsupported_Combination : constant String :=
     "unsupported testing callback combination";

   procedure Record_Unsupported
     (URL        : String;
      Statistics : out Fetch_Statistics)
   is
   begin
      Statistics := (others => <>);
      Statistics.Failed := 1;
      Statistics.Failed_URL := To_Unbounded_String (URL);
      Statistics.Failed_Reason := To_Unbounded_String (Unsupported_Combination);
   end Record_Unsupported;

   function Domain_Of (URL : String) return String is
   begin
      return Sitefetch.Domain_Of (URL);
   end Domain_Of;

   function Is_Same_Domain (Root_URL : String; Candidate : String) return Boolean is
   begin
      return Sitefetch.Is_Same_Domain (Root_URL, Candidate);
   end Is_Same_Domain;

   function Resolve_URL (Base_URL : String; Reference : String) return String is
   begin
      return Sitefetch.Resolve_URL (Base_URL, Reference);
   end Resolve_URL;

   function Canonical_URL (URL : String) return String is
   begin
      return Sitefetch.Canonical_URL (URL);
   end Canonical_URL;

   function Local_Path_For_URL (URL : String) return String is
   begin
      return Sitefetch.Local_Path_For_URL (URL);
   end Local_Path_For_URL;

   function Is_Dangerous_File_Type (URL : String) return Boolean is
   begin
      return Sitefetch.Is_Dangerous_File_Type (URL);
   end Is_Dangerous_File_Type;

   function Is_Safe_Asset_File_Type (URL : String) return Boolean is
   begin
      return Sitefetch.Is_Safe_Asset_File_Type (URL);
   end Is_Safe_Asset_File_Type;

   function Should_Download_To_File (URL : String) return Boolean is
   begin
      return Sitefetch.Should_Download_To_File (URL);
   end Should_Download_To_File;

   function Should_Parse_Content_Type (Content_Type : String) return Boolean is
   begin
      return Sitefetch.Should_Parse_Content_Type (Content_Type);
   end Should_Parse_Content_Type;

   function Extract_Links (Document_Text : String) return Link_List is
      Internal : constant Sitefetch.Link_List := Sitefetch.Extract_Links (Document_Text);
      Result   : Link_List;
   begin
      for Link of Internal loop
         Result.Append (Link);
      end loop;

      return Result;
   end Extract_Links;

   function Rewrite_Document
     (Document_Text : String;
      Page_URL      : String;
      Root_URL      : String) return String is
   begin
      return Sitefetch.Rewrite_Document (Document_Text, Page_URL, Root_URL);
   end Rewrite_Document;

   function Fetch_Website
     (URL              : String;
      Target_Directory : String;
      Callbacks        : Fetch_Callbacks) return Boolean
   is
      Statistics : Fetch_Statistics;
   begin
      return Fetch_Website (URL, Target_Directory, Callbacks, Statistics);
   end Fetch_Website;

   function Fetch_Website
     (URL              : String;
      Target_Directory : String;
      Callbacks        : Fetch_Callbacks;
      Statistics       : out Fetch_Statistics;
      Progress         : Progress_Callback := null;
      Options          : Fetch_Options := Default_Fetch_Options) return Boolean
   is
      use type Fetch_Options;

      Simple_Fetcher   : constant Sitefetch.Engine.Simple_Fetcher_Access :=
        Sitefetch.Engine.Simple_Fetcher_Access (Callbacks.Simple_Fetcher);
      Final_Fetcher    : constant Sitefetch.Engine.Final_Fetcher_Access :=
        Sitefetch.Engine.Final_Fetcher_Access (Callbacks.Final_Fetcher);
      Parallel_Fetcher : constant Sitefetch.Engine.Parallel_Fetcher_Access :=
        Sitefetch.Engine.Parallel_Fetcher_Access (Callbacks.Parallel_Fetcher);
      Downloader       : constant Sitefetch.Engine.Direct_Downloader_Access :=
        Sitefetch.Engine.Direct_Downloader_Access (Callbacks.Downloader);
      Result           : Boolean := False;
   begin
      case Callbacks.Mode is
         when Fetch_Simple =>
            if Simple_Fetcher /= null
              and then Final_Fetcher = null
              and then Parallel_Fetcher = null
              and then Downloader = null
              and then Options = Default_Fetch_Options
            then
               Result := Sitefetch.Engine.Fetch_Website_With_Simple_Injected_Fetcher
                 (URL, Target_Directory, Simple_Fetcher, Statistics, Progress);
            end if;

         when Fetch_Final =>
            if Final_Fetcher /= null
              and then Simple_Fetcher = null
              and then Parallel_Fetcher = null
            then
               if Downloader = null then
                  Result := Sitefetch.Engine.Fetch_Website_With_Final_Fetcher
                    (URL, Target_Directory, Final_Fetcher, Statistics, Progress, Options);
               elsif Options = Default_Fetch_Options then
                  Result := Sitefetch.Engine.Fetch_Website_With_Final_Injected_Download
                    (URL, Target_Directory, Final_Fetcher, Downloader, Statistics, Progress);
               end if;
            end if;

         when Fetch_Parallel =>
            if Parallel_Fetcher /= null
              and then Simple_Fetcher = null
              and then Final_Fetcher = null
            then
               if Downloader = null and then Options = Default_Fetch_Options then
                  Result := Sitefetch.Engine.Fetch_Website_With_Parallel_Fetcher
                    (URL, Target_Directory, Parallel_Fetcher, Statistics, Progress);
               elsif Downloader /= null then
                  Result := Sitefetch.Engine.Fetch_Website_With_Parallel_Injected_Download
                    (URL, Target_Directory, Parallel_Fetcher, Downloader, Statistics, Progress, Options);
               end if;
            end if;
      end case;

      if not Result and then Statistics.Failed = 0 then
         Record_Unsupported (URL, Statistics);
      end if;

      return Result;
   end Fetch_Website;
end Sitefetch.Testing;
