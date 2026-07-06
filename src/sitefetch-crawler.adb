with Sitefetch.Engine;

package body Sitefetch.Crawler is
   function Fetch_Website
     (URL              : String;
      Target_Directory : String;
      Statistics       : out Fetch_Statistics;
      Progress         : Progress_Callback := null;
      Options          : Fetch_Options := Default_Fetch_Options) return Boolean is
   begin
      return Sitefetch.Engine.Fetch_Website
        (URL, Target_Directory, Statistics, Progress, Options);
   end Fetch_Website;

   function Fetch_Website_With_Structured_Progress
     (URL              : String;
      Target_Directory : String;
      Statistics       : out Fetch_Statistics;
      Progress         : Structured_Progress_Callback;
      Options          : Fetch_Options := Default_Fetch_Options) return Boolean is
   begin
      return Sitefetch.Engine.Fetch_Website_With_Structured_Progress
        (URL, Target_Directory, Statistics, Progress, Options);
   end Fetch_Website_With_Structured_Progress;
end Sitefetch.Crawler;
