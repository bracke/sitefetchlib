with Ada.Strings.Unbounded;

--  Support level: private internal implementation.
--
--  Shared crawl engine used by Sitefetch.Crawler and Sitefetch.Testing. The
--  root Sitefetch package keeps stable records/options/helper declarations;
--  production and injected crawl behavior lives here.

private package Sitefetch.Engine is

   type Simple_Fetcher_Access is access function
     (Fetch_URL     : String;
      Document_Text : out Ada.Strings.Unbounded.Unbounded_String) return Boolean;

   type Final_Fetcher_Access is access function
     (Fetch_URL     : String;
      Document_Text : out Ada.Strings.Unbounded.Unbounded_String;
      Final_URL     : out Ada.Strings.Unbounded.Unbounded_String) return Boolean;

   type Direct_Downloader_Access is access function
     (Fetch_URL      : String;
      Target_Path    : String;
      Final_URL      : out Ada.Strings.Unbounded.Unbounded_String;
      Failure_Reason : out Ada.Strings.Unbounded.Unbounded_String;
      Bytes_Written  : out Natural) return Boolean;

   type Parallel_Fetcher_Access is access function
     (Fetch_URL      : String;
      Document_Text  : out Ada.Strings.Unbounded.Unbounded_String;
      Final_URL      : out Ada.Strings.Unbounded.Unbounded_String;
      Failure_Reason : out Ada.Strings.Unbounded.Unbounded_String) return Boolean;
   function Fetch_Website
     (URL              : String;
      Target_Directory : String;
      Statistics       : out Fetch_Statistics;
      Progress         : Progress_Callback := null;
      Options          : Fetch_Options := Default_Fetch_Options) return Boolean;

   function Fetch_Website_With_Structured_Progress
     (URL              : String;
      Target_Directory : String;
      Statistics       : out Fetch_Statistics;
      Progress         : Structured_Progress_Callback;
      Options          : Fetch_Options := Default_Fetch_Options) return Boolean;
   function Fetch_Website_With_Simple_Injected_Fetcher
     (URL              : String;
      Target_Directory : String;
      Fetcher          : Simple_Fetcher_Access;
      Statistics       : out Fetch_Statistics;
      Progress         : Progress_Callback) return Boolean;

   function Fetch_Website_With_Final_Fetcher
     (URL              : String;
      Target_Directory : String;
      Fetcher          : Final_Fetcher_Access;
      Statistics       : out Fetch_Statistics;
      Progress         : Progress_Callback;
      Options          : Fetch_Options) return Boolean;

   function Fetch_Website_With_Final_Injected_Download
     (URL              : String;
      Target_Directory : String;
      Fetcher          : Final_Fetcher_Access;
      Downloader       : Direct_Downloader_Access;
      Statistics       : out Fetch_Statistics;
      Progress         : Progress_Callback) return Boolean;

   function Fetch_Website_With_Parallel_Fetcher
     (URL              : String;
      Target_Directory : String;
      Fetcher          : Parallel_Fetcher_Access;
      Statistics       : out Fetch_Statistics;
      Progress         : Progress_Callback) return Boolean;

   function Fetch_Website_With_Parallel_Injected_Download
     (URL              : String;
      Target_Directory : String;
      Fetcher          : Parallel_Fetcher_Access;
      Downloader       : Direct_Downloader_Access;
      Statistics       : out Fetch_Statistics;
      Progress         : Progress_Callback;
      Options          : Fetch_Options) return Boolean;

end Sitefetch.Engine;
