--  Support level: testing and fixture API.
--
--  This package intentionally exposes internal helpers and injected fetcher
--  adapters for deterministic tests. It is useful for sitefetchlib's own tests
--  and downstream fixture suites, but production embedders should use the root
--  Sitefetch package instead. Compatibility can change with test needs.

with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Unbounded;

package Sitefetch.Testing is
   package String_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => String);

   subtype Link_List is String_Vectors.Vector;

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

   type Fetch_Mode is
     (Fetch_Simple,
      Fetch_Final,
      Fetch_Parallel);

   type Fetch_Callbacks is record
      Mode             : Fetch_Mode := Fetch_Final;
      Simple_Fetcher   : Simple_Fetcher_Access := null;
      Final_Fetcher    : Final_Fetcher_Access := null;
      Parallel_Fetcher : Parallel_Fetcher_Access := null;
      Downloader       : Direct_Downloader_Access := null;
   end record;

   function Domain_Of (URL : String) return String;

   function Is_Same_Domain (Root_URL : String; Candidate : String) return Boolean;

   function Resolve_URL (Base_URL : String; Reference : String) return String;

   function Canonical_URL (URL : String) return String;

   function Local_Path_For_URL (URL : String) return String;

   function Is_Dangerous_File_Type (URL : String) return Boolean;

   function Is_Safe_Asset_File_Type (URL : String) return Boolean;

   function Should_Download_To_File (URL : String) return Boolean;

   function Should_Parse_Content_Type (Content_Type : String) return Boolean;

   function Extract_Links (Document_Text : String) return Link_List;

   function Rewrite_Document
     (Document_Text : String;
      Page_URL      : String;
      Root_URL      : String) return String;

   function Fetch_Website
     (URL              : String;
      Target_Directory : String;
      Callbacks        : Fetch_Callbacks) return Boolean;

   function Fetch_Website
     (URL              : String;
      Target_Directory : String;
      Callbacks        : Fetch_Callbacks;
      Statistics       : out Fetch_Statistics;
      Progress         : Progress_Callback := null;
      Options          : Fetch_Options := Default_Fetch_Options) return Boolean;
end Sitefetch.Testing;
