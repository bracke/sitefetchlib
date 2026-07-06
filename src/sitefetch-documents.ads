with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

--  Support level: private internal implementation.
--
--  Document link extraction and rewrite helpers shared by the public Sitefetch
--  helpers and the crawl engine.

private package Sitefetch.Documents is
   type Link_Match is record
      Position        : Natural := 0;
      Value_First     : Natural := 0;
      Value_Last      : Natural := 0;
      Reference       : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.Null_Unbounded_String;
   end record;

   package Link_Match_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Link_Match);

   function Decode_HTML_Entities (Text : String) return String;

   procedure Extract_Link_Matches
     (Document_Text : String;
      Matches       : in out Link_Match_Vectors.Vector);

   function Links_From_Matches (Matches : Link_Match_Vectors.Vector) return Link_List;

   function Extract_Links (Document_Text : String) return Link_List;

   function Document_Text_For_Write
     (Document_Text : String;
      Page_URL      : String;
      Root_URL      : String;
      Matches       : Link_Match_Vectors.Vector;
      Policy        : Domain_Policy := Domain_Exact_And_Subdomains) return String;

   function Rewrite_Document
     (Document_Text : String;
      Page_URL      : String;
      Root_URL      : String) return String;
end Sitefetch.Documents;
