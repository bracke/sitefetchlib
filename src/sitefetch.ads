--  Support level: stable production API.
--
--  This root package contains the stable production records, options,
--  statistics, and callback types for applications that depend on sitefetchlib.
--  Production crawler entry points live in Sitefetch.Crawler. Additive options
--  and statistics fields may be added over time.

with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Unbounded;

package Sitefetch is
   type Failed_Download is record
      URL    : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.Null_Unbounded_String;
      Reason : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.Null_Unbounded_String;
   end record;

   package Failed_Download_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => Failed_Download);

   Default_Worker_Count : constant Positive := 8;
   Max_Worker_Count     : constant Positive := 64;

   type Safety_Mode is
     (Safety_Default,
      Safety_Skip_Dangerous,
      Safety_Assets_Only_Safe);

   type Domain_Policy is
     (Domain_Exact_And_Subdomains,
      Domain_Include_Parents);

   type Head_Policy is
     (Head_Page_Like,
      Head_Ambiguous_Only,
      Head_Disabled);

   type Robots_Policy is
     (Robots_Ignore,
      Robots_Respect);

   type Robots_Failure_Policy is
     (Robots_Fail_Open,
      Robots_Fail_Closed);

   type Cache_Mode is
     (Cache_Ignore,
      Cache_Revalidate,
      Cache_Refresh,
      Cache_Offline);

   type Cache_Resource_Strategy is
     (Cache_All_Resources,
      Cache_Documents_Only,
      Cache_Downloads_Only);

   type Cache_Hash_Algorithm is
     (Cache_Hash_FNV1a_64,
      Cache_Hash_SHA256,
      Cache_Hash_None);

   type Diagnostics_Mode is
     (Diagnostics_Quiet,
      Diagnostics_Verbose);

   type Write_Durability_Mode is
     (Write_Durability_Default,
      Write_Durability_Flush_Temp_File,
      Write_Durability_Sync_Data_And_Directory);

   Default_User_Agent : constant String := "sitefetch/0.1";
   Default_Accept_Encoding : constant String := "gzip, deflate";

   type Crawl_Policy is record
      Max_Pages    : Natural := 1_000;
      Max_Depth    : Natural := 0;
      --  Stop taking or queueing more work after this many accumulated bytes.
      --  Built-in direct downloads are capped before completion with the
      --  remaining byte budget; injected download callbacks are rejected if
      --  their reported byte count exceeds the remaining budget. Buffered
      --  documents are counted after they are written. Use zero for unlimited.
      Max_Bytes    : Natural := 0;
      Max_Failures : Natural := 0;
      Workers      : Positive := Default_Worker_Count;
      --  Limit concurrently active production HTTP workers per host. This
      --  crawler keeps same-host/subdomain work in one queue, so the limit is
      --  applied by clamping the production worker pool. Use zero for no
      --  additional per-host cap beyond Workers.
      Max_Per_Host_Connections : Natural := 0;
      --  Crawl exact root host and dot-boundary subdomains by default. Set
      --  Domain_Include_Parents to also treat the registrable parent domain as
      --  internal when the root host is a subdomain.
      Domain       : Domain_Policy := Domain_Exact_And_Subdomains;
      --  Robots_Respect fetches /robots.txt for the effective root origin,
      --  applies matching user-agent groups, longest-match Allow/Disallow
      --  rules, Crawl-delay through the per-origin request scheduler, and
      --  same-origin Sitemap URLs. The root URL itself is still fetched.
      --  Robots_Ignore preserves local mirroring
      --  behavior.
      Robots       : Robots_Policy := Robots_Ignore;
      --  Choose how Robots_Respect behaves when robots.txt cannot be fetched
      --  or returns a non-2xx response. Fail-open keeps crawling and reports a
      --  diagnostic; fail-closed blocks discovered links for that origin.
      Robots_Failure : Robots_Failure_Policy := Robots_Fail_Open;
      --  Limit sitemap-to-sitemap recursion discovered from robots Sitemap
      --  entries. Ordinary pages listed by a sitemap are still eligible at
      --  this depth. Use zero for unlimited sitemap recursion.
      Max_Sitemap_Depth : Natural := 2;
   end record;

   type HTTP_Policy is record
      --  Number of additional production HTTP attempts after an initial
      --  Http_Client failure. Injected testing callbacks are not retried.
      Max_Retries  : Natural := 0;
      --  Initial retry delay in milliseconds. Each subsequent retry doubles
      --  this delay. Use zero for immediate retries.
      Retry_Delay_MS : Natural := 0;
      --  Add deterministic per-URL jitter up to this many milliseconds to
      --  retry delays. Use zero for no jitter.
      Retry_Jitter_MS : Natural := 0;
      --  Retry transient HTTP response statuses such as 408, 429, and common
      --  5xx service failures. Ordinary permanent 4xx responses are not retried.
      Retry_HTTP_Statuses : Boolean := True;
      --  Minimum delay between production HTTP request starts for the same
      --  origin. Use zero for no delay.
      Request_Delay_MS : Natural := 0;
      --  User-Agent header for production HTTP clients.
      User_Agent : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.To_Unbounded_String (Default_User_Agent);
      --  Optional Accept-Language header for production HTTP clients. Empty
      --  means the header is not sent by sitefetchlib.
      Accept_Language : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.Null_Unbounded_String;
      --  Accept-Encoding header for production HTTP clients. The default
      --  matches Http_Client's decompression advertisement and is persisted in
      --  cache sidecars for Vary comparisons.
      Accept_Encoding : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.To_Unbounded_String (Default_Accept_Encoding);
      --  Control production HEAD preflights used to classify page-like URLs
      --  before buffering. Head_Page_Like probes all page-like candidates,
      --  Head_Ambiguous_Only probes only extensionless non-directory paths,
      --  and Head_Disabled uses extension and GET response metadata only.
      Head         : Head_Policy := Head_Page_Like;
   end record;

   type Cache_Vary_Allow_List is record
      User_Agent      : Boolean := True;
      Accept_Language : Boolean := False;
      Accept_Encoding : Boolean := False;
   end record;

   type Cache_Policy is record
      --  Cache_Revalidate stores cache sidecars next to written files. Fresh
      --  entries from Cache-Control max-age or Expires are reused locally;
      --  stale or must-revalidate entries use conditional requests when ETag
      --  or Last-Modified validators are available. Cache_Refresh bypasses
      --  existing sidecars and refreshes from the network. Cache_Offline only
      --  uses locally valid sidecars and never starts a network request.
      Mode : Cache_Mode := Cache_Ignore;
      --  Allow reuse of stale entries for this many milliseconds after their
      --  freshness lifetime expires. Does not override no-cache or
      --  must-revalidate. Use zero to reject stale local reuse.
      Max_Stale_MS : Natural := 0;
      --  Vary fields accepted for cache reuse. Allowed fields are compared
      --  against request header values persisted in cache metadata; Vary: *
      --  and unrecognized fields are always rejected.
      Vary_Allow : Cache_Vary_Allow_List := (others => <>);
      --  Choose which resource classes use cache metadata. Documents covers
      --  buffered, parseable responses; downloads covers streamed assets and
      --  partial resume sidecars.
      Resource_Strategy : Cache_Resource_Strategy := Cache_All_Resources;
      --  Hash algorithm used for Local-Hash integrity metadata. SHA-256 is
      --  available for stronger corruption detection; Cache_Hash_None verifies
      --  Local-Size only when Verify_Local_Content is enabled.
      Hash_Algorithm : Cache_Hash_Algorithm := Cache_Hash_FNV1a_64;
      --  Reject cache sidecars that do not carry the current Cache-Version.
      --  The default preserves older sidecars; enable this for strict cache
      --  invalidation across metadata format changes.
      Require_Metadata_Version : Boolean := False;
      --  Verify cached local files against persisted Local-Size and
      --  Local-Hash before reuse. Disable only when callers prefer trusting
      --  existing files over detecting local corruption.
      Verify_Local_Content : Boolean := True;
   end record;

   type Safety_Policy is record
      Mode : Safety_Mode := Safety_Default;
      --  Write_Durability_Flush_Temp_File flushes text temp files before
      --  atomic install. Write_Durability_Sync_Data_And_Directory also asks
      --  Http_Client to fsync completed files and best-effort fsync parent
      --  directories after atomic rename where the platform supports it.
      --  This covers buffered documents, rewritten documents, cache sidecars,
      --  and production streamed downloads.
      Write_Durability : Write_Durability_Mode := Write_Durability_Default;
   end record;

   type Diagnostics_Policy is record
      Mode : Diagnostics_Mode := Diagnostics_Quiet;
   end record;

   type Fetch_Options is record
      Crawl  : Crawl_Policy := (others => <>);
      HTTP   : HTTP_Policy := (others => <>);
      Cache  : Cache_Policy := (others => <>);
      Safety      : Safety_Policy := (others => <>);
      Diagnostics : Diagnostics_Policy := (others => <>);
   end record;

   Default_Fetch_Options : constant Fetch_Options := (others => <>);

   type Fetch_Statistics is record
      Attempted           : Natural := 0;
      Written             : Natural := 0;
      Skipped_External    : Natural := 0;
      Skipped_Unsupported : Natural := 0;
      Skipped_Limit       : Natural := 0;
      Bytes_Written       : Natural := 0;
      Failed              : Natural := 0;
      Failed_Downloads    : Failed_Download_Vectors.Vector;
      Failed_URL          : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.Null_Unbounded_String;
      Failed_Reason       : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.Null_Unbounded_String;
   end record;

   type Progress_Event is
     (Progress_Fetching,
      Progress_Written,
      Progress_Skipped_External,
      Progress_Skipped_Unsupported,
      Progress_Warning_Dangerous,
      Progress_Skipped_Dangerous,
      Progress_Already_Visited,
      Progress_Skipped_Limit,
      Progress_Cache_Revalidate,
      Progress_Cache_Reused,
      Progress_Cache_Rejected,
      Progress_Resume_Attempt,
      Progress_Retry,
      Progress_Robots_Allowed,
      Progress_Robots_Disallowed,
      Progress_Robots_Loaded,
      Progress_Robots_Failed,
      Progress_Failed,
      Progress_Redirected);

   type Progress_Callback is access procedure
     (Event : Progress_Event;
      URL   : String);

   type Progress_Record is record
      Event  : Progress_Event := Progress_Fetching;
      URL    : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.Null_Unbounded_String;
      Reason : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.Null_Unbounded_String;
      Local_Path : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.Null_Unbounded_String;
      Bytes_Written : Natural := 0;
      Depth         : Natural := 0;
      Status_Code   : Natural := 0;
      Retry_Attempt : Natural := 0;
      Cache_Decision : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.Null_Unbounded_String;
      Robots_Source : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.Null_Unbounded_String;
      Final_URL : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.Null_Unbounded_String;
      Source_ID : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.Null_Unbounded_String;
      Redirect_Hops : Natural := 0;
      Redirect_Chain : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.Null_Unbounded_String;
      Redirect_Status_Codes : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.Null_Unbounded_String;
      Redirect_Target_URLs : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.Null_Unbounded_String;
      Redirect_Locations : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.Null_Unbounded_String;
   end record;

   type Structured_Progress_Callback is access procedure
     (Progress : Progress_Record);

   --  Return URL with an explicit HTTP or HTTPS scheme.
   --
   --  @param URL User supplied URL or host/path.
   --  @return URL unchanged when it already starts with http:// or https://,
   --          otherwise prefixed with http://.
   function Ensure_HTTP_Scheme (URL : String) return String;

private
   package String_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => String);

   subtype Link_List is String_Vectors.Vector;

   --  Internal helpers intentionally kept out of the root visible API.  Test
   --  fixtures exercise them through Sitefetch.Testing.
   --  Extract the normalized host name from URL.
   --
   --  @param URL Absolute URL to inspect.
   --  @return Lower-case host name without port, user info, path, query, or
   --          fragment. Returns an empty string when no authority is present.
   --          This is URL-parser host normalization, not public-suffix
   --          registrable-domain normalization.
   function Domain_Of (URL : String) return String;

   --  Test whether Candidate has the same host as Root_URL or is a host-suffix child of it.
   --
   --  @param Root_URL Absolute root URL for the website being fetched.
   --  @param Candidate Absolute candidate URL.
   --  @return True when Candidate has the same normalized host as Root_URL or a
   --          dot-boundary subdomain of it, with public-suffix-style boundaries
   --          enforced by Sitefetch.Domains' embedded common suffix table.
   function Is_Same_Domain (Root_URL : String; Candidate : String) return Boolean;

   --  Resolve Reference against Base_URL.
   --
   --  @param Base_URL Absolute URL of the containing document.
   --  @param Reference Absolute, scheme-relative, root-relative, or relative
   --         reference found in a document.
   --  @return Absolute URL with fragments removed.
   function Resolve_URL (Base_URL : String; Reference : String) return String;

   --  Return the normalized absolute URL used for crawl identity.
   function Canonical_URL (URL : String) return String;

   --  Convert URL into the local path used for storing its document.
   --
   --  @param URL Absolute URL to map.
   --  @return Relative local path. Empty paths and directory paths map to
   --          index.html.
   function Local_Path_For_URL (URL : String) return String;

   --  Test whether URL uses an extension that may carry active or installable content.
   --
   --  @param URL Absolute or relative URL to classify.
   --  @return True when URL has an executable, script, macro document, archive,
   --          disk image, or similar extension that should be treated cautiously.
   function Is_Dangerous_File_Type (URL : String) return Boolean;

   --  Test whether URL uses a direct-download extension accepted by the strict safe mode.
   --
   --  @param URL Absolute or relative URL to classify.
   --  @return True when URL is a common passive image, media, or font asset.
   function Is_Safe_Asset_File_Type (URL : String) return Boolean;

   --  Test whether URL should be streamed directly to file by extension.
   --
   --  @param URL Absolute or relative URL to classify.
   --  @return True when URL has a raster image, audio, video, archive, font, ebook,
   --          executable, PDF, office-document, or other binary asset extension.
   --          SVG is kept parseable so links inside it can be rewritten.
   function Should_Download_To_File (URL : String) return Boolean;

   --  Test whether an in-memory response body should be parsed for links by media type.
   --
   --  @param Content_Type Content-Type header value or media type.
   --  @return True when Content_Type is missing, text/*, or a known text-like
   --          application type such as JSON, XML, JavaScript, or SVG. Passive
   --          binary types such as application/octet-stream, application/pdf,
   --          raster images, audio/video, and fonts are not parsed.
   function Should_Parse_Content_Type (Content_Type : String) return Boolean;

   --  Find links and references in a document.
   --
   --  @param Document_Text Document source text to scan.
   --  @return Unique attribute references from href and src attributes.
   function Extract_Links (Document_Text : String) return Link_List;

   --  Rewrite same-domain and subdomain references in a document to local file references.
   --
   --  @param Document_Text Document source text to rewrite.
   --  @param Page_URL Absolute URL of Document_Text.
   --  @param Root_URL Absolute root URL of the fetched website.
   --  @return Document text with same-domain and subdomain references rewritten to local
   --          paths. External references are preserved.
   function Rewrite_Document
     (Document_Text : String;
      Page_URL      : String;
      Root_URL      : String) return String;


end Sitefetch;
