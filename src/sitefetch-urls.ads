--  Support level: public support API.
--
--  URL normalization, crawl-boundary, and local-path mapping helpers shared by
--  the public Sitefetch helpers and the crawl engine.

package Sitefetch.URLs is
   function Starts_With (Item : String; Prefix : String) return Boolean;

   function Starts_With_Case_Insensitive (Item : String; Prefix : String) return Boolean;

   function To_Lower (Item : String) return String;

   function Strip_Fragment (URL : String) return String;

   function Has_Explicit_Scheme (Reference : String) return Boolean;

   function Is_HTTP_URL (URL : String) return Boolean;

   function Is_Fetchable_Reference (Reference : String) return Boolean;

   function Scheme_Of (URL : String) return String;

   function Authority_Start (URL : String) return Natural;

   function Authority_End (URL : String; Start_At : Positive) return Natural;

   function Path_Start (URL : String) return Natural;

   function Path_Only (URL : String) return String;

   function Origin_Of (URL : String) return String;

   function Directory_Of (URL : String) return String;

   function Without_Query_Or_Fragment (Text : String) return String;

   function Query_Only (Text : String) return String;

   function Normalize_Path (Path_Text : String) return String;

   function Ensure_HTTP_Scheme (URL : String) return String;

   function Domain_Of (URL : String) return String;

   function Is_In_Domain
     (Root_Domain : String;
      Candidate   : String;
      Policy      : Domain_Policy := Domain_Exact_And_Subdomains) return Boolean;

   function Is_Same_Domain (Root_URL : String; Candidate : String) return Boolean;

   function Resolve_URL (Base_URL : String; Reference : String) return String;

   function Canonical_URL (URL : String) return String;

   function Local_Path_For_URL (URL : String) return String;

   function Extension_Of (URL : String) return String;
end Sitefetch.URLs;
