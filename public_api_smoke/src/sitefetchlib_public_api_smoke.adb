with Ada.Strings.Unbounded;

with Sitefetch;
with Sitefetch.Cache;
with Sitefetch.Content;
with Sitefetch.Crawl;
with Sitefetch.Crawler;
with Sitefetch.Diagnostics;
with Sitefetch.HTTP;
with Sitefetch.URLs;
with Sitefetch.Safety;
with Sitefetchlib_Public_API_Smoke_Callbacks;

procedure Sitefetchlib_Public_API_Smoke is
   use Ada.Strings.Unbounded;
   use type Sitefetch.Structured_Progress_Callback;

   Statistics : Sitefetch.Fetch_Statistics;
   Options    : Sitefetch.Fetch_Options := Sitefetch.Default_Fetch_Options;

   Canonical : constant String :=
     Sitefetch.URLs.Canonical_URL ("https://Example.COM/a/../b/index.html#part");
   Local_Path : constant String :=
     Sitefetch.URLs.Local_Path_For_URL ("https://example.com/assets/app.css?v=1");

   Structured : Sitefetch.Structured_Progress_Callback :=
     Sitefetchlib_Public_API_Smoke_Callbacks.Structured_Progress'Access;
   Legacy     : Sitefetch.Progress_Callback := null;
   Success    : Boolean := False;
begin
   Options.Crawl.Max_Pages := 1;
   Options.Crawl.Max_Depth := 0;
   Options.Crawl.Max_Bytes := 0;
   Options.Crawl.Max_Failures := 1;
   Options.Crawl.Workers := 1;
   Options.Crawl.Domain := Sitefetch.Crawl.Exact_And_Subdomains;
   Options.Crawl.Robots := Sitefetch.Crawl.Ignore_Robots;
   Options.Crawl.Robots_Failure := Sitefetch.Crawl.Robots_Open_On_Failure;
   Options.Crawl.Max_Sitemap_Depth := 1;

   Options.HTTP.Max_Retries := 0;
   Options.HTTP.Retry_Delay_MS := 0;
   Options.HTTP.Retry_Jitter_MS := 0;
   Options.HTTP.Retry_HTTP_Statuses := True;
   Options.HTTP.Request_Delay_MS := 0;
   Options.HTTP.User_Agent := To_Unbounded_String (Sitefetch.HTTP.Default_User_Agent_Text);
   Options.HTTP.Head := Sitefetch.HTTP.Disable_Head;

   Options.Cache.Mode := Sitefetch.Cache.Ignore;
   Options.Cache.Max_Stale_MS := 0;
   Options.Cache.Resource_Strategy := Sitefetch.Cache.All_Resources;
   Options.Cache.Hash_Algorithm := Sitefetch.Cache.FNV1a_64;
   Options.Cache.Require_Metadata_Version := False;
   Options.Cache.Verify_Local_Content := True;

   Options.Safety.Mode := Sitefetch.Safety.Default_Mode;
   Options.Safety.Write_Durability := Sitefetch.Safety.Default_Durability;
   Options.Diagnostics.Mode := Sitefetch.Diagnostics.Quiet;

   Statistics := (others => <>);

   --  Keep calls unreachable so this smoke binary compiles the production API
   --  surface without doing network or filesystem work when executed.
   if False then
      Success := Sitefetch.Crawler.Fetch_Website
        (URL              => Sitefetch.Ensure_HTTP_Scheme ("example.com"),
         Target_Directory => "mirror",
         Statistics       => Statistics,
         Progress         => Legacy,
         Options          => Options);

      Success := Sitefetch.Crawler.Fetch_Website_With_Structured_Progress
        (URL              => "https://example.com/",
         Target_Directory => "mirror",
         Statistics       => Statistics,
         Progress         => Structured,
         Options          => Options);
   end if;

   pragma Assert (Canonical = "https://example.com/b/index.html");
   pragma Assert (Sitefetch.URLs.Domain_Of ("https://Example.COM:443/path") = "example.com");
   pragma Assert (Sitefetch.URLs.Is_In_Domain ("example.com", "docs.example.com"));
   pragma Assert (Local_Path'Length > 0);

   pragma Assert (Sitefetch.Content.Should_Download_To_File ("https://example.com/file.pdf"));
   pragma Assert (not Sitefetch.Content.Should_Download_To_File ("https://example.com/index.html"));
   pragma Assert (Sitefetch.Content.Should_Parse_Content_Type ("text/html; charset=utf-8"));
   pragma Assert (not Sitefetch.Content.Should_Parse_Content_Type ("application/pdf"));

   pragma Assert (not Success);
   pragma Assert (Structured /= null);
end Sitefetchlib_Public_API_Smoke;
