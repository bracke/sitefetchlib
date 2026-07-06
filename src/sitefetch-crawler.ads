--  Support level: stable production API.
--
--  Focused production crawler entry points. New embedded callers import this
--  package and the policy child packages; the root Sitefetch package contains
--  shared records and types, not public fetch entry points.

package Sitefetch.Crawler is
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
end Sitefetch.Crawler;
