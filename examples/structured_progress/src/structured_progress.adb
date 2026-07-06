with Ada.Environment_Variables;
with Ada.Text_IO;

with Sitefetch;
with Sitefetch.Cache;
with Sitefetch.Crawl;
with Sitefetch.Crawler;
with Structured_Progress_Example;

procedure Structured_Progress is
   Statistics : Sitefetch.Fetch_Statistics;
   Options    : Sitefetch.Fetch_Options := Sitefetch.Default_Fetch_Options;
   Success    : Boolean := False;

begin
   Options.Crawl.Max_Pages := 25;
   Options.Crawl.Max_Depth := 2;
   Options.Crawl.Robots := Sitefetch.Crawl.Respect_Robots;
   Options.Cache.Mode := Sitefetch.Cache.Revalidate;
   Options.Diagnostics.Mode := Sitefetch.Diagnostics_Verbose;

   --  This checked example compiles the structured diagnostics API while
   --  avoiding accidental network and filesystem work during smoke runs.
   if Ada.Environment_Variables.Value ("SITEFETCHLIB_RUN_EXAMPLE", "0") = "1" then
      Success := Sitefetch.Crawler.Fetch_Website_With_Structured_Progress
        (URL              => "https://example.com/",
         Target_Directory => "mirror",
         Statistics       => Statistics,
         Progress         => Structured_Progress_Example.Report'Access,
         Options          => Options);

      if not Success then
         Ada.Text_IO.Put_Line
           ("failed URLs:" & Natural'Image (Natural (Statistics.Failed_Downloads.Length)));
      end if;
   end if;
end Structured_Progress;
