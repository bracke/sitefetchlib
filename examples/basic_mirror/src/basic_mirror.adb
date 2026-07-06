with Ada.Environment_Variables;
with Ada.Text_IO;

with Sitefetch;
with Sitefetch.Crawler;

procedure Basic_Mirror is
   Statistics : Sitefetch.Fetch_Statistics;
   Options    : Sitefetch.Fetch_Options := Sitefetch.Default_Fetch_Options;
   Success    : Boolean := False;
begin
   Options.Crawl.Max_Pages := 250;
   Options.Crawl.Max_Depth := 4;
   Options.Crawl.Robots := Sitefetch.Robots_Respect;
   Options.Cache.Mode := Sitefetch.Cache_Revalidate;
   Options.Safety.Write_Durability := Sitefetch.Write_Durability_Sync_Data_And_Directory;

   --  This checked example mirrors the README code while avoiding accidental
   --  network and filesystem work during normal builds and smoke runs.
   if Ada.Environment_Variables.Value ("SITEFETCHLIB_RUN_EXAMPLE", "0") = "1" then
      Success := Sitefetch.Crawler.Fetch_Website
        (URL              => "https://example.com/",
         Target_Directory => "mirror",
         Statistics       => Statistics,
         Options          => Options);

      if not Success then
         Ada.Text_IO.Put_Line
           ("failed URLs:" & Natural'Image (Natural (Statistics.Failed_Downloads.Length)));
      end if;
   end if;
end Basic_Mirror;
