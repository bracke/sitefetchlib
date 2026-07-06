with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

--  Support level: private internal implementation.
--
--  Robots.txt parsing, matching, cache, and crawl-delay scheduling helpers for
--  the crawl engine. HTTP loading and crawl-state sitemap enqueueing remain in
--  Sitefetch.Engine.

private package Sitefetch.Engine.Robots is
   use Ada.Strings.Unbounded;

   type Robots_Directive_Kind is (Robots_Allow, Robots_Disallow);

   type Robots_Directive is record
      Kind   : Robots_Directive_Kind := Robots_Disallow;
      Prefix : Unbounded_String := Null_Unbounded_String;
   end record;

   package Robots_Directive_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Robots_Directive);

   type Robots_Rules is record
      Enabled        : Boolean := False;
      Directives     : Robots_Directive_Vectors.Vector;
      Crawl_Delay_MS : Natural := 0;
      Sitemaps       : Link_List;
      Source_URL     : Unbounded_String := Null_Unbounded_String;
   end record;

   function Ignore_Robots return Robots_Rules;

   function Fail_Closed_Robots return Robots_Rules;

   procedure Lookup_Cached_Robots
     (Origin : String;
      Found  : out Boolean;
      Rules  : out Robots_Rules);

   procedure Store_Cached_Robots (Origin : String; Rules : Robots_Rules);

   procedure Clear_Robots_Cache;

   procedure Reserve_Request_Delay
     (URL          : String;
      Limits       : Fetch_Options;
      Wait_Seconds : out Duration);

   procedure Clear_Crawl_Delay_Scheduler;

   procedure Parse_Robots
     (Text       : String;
      User_Agent : String;
      Rules      : in out Robots_Rules);

   function Robots_Allows (Rules : Robots_Rules; URL : String) return Boolean;

   function Apply_Robots_Delay (Limits : Fetch_Options; Robots : Robots_Rules) return Fetch_Options;
end Sitefetch.Engine.Robots;
