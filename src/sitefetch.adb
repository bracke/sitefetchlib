with Sitefetch.Content;
with Sitefetch.Documents;
with Sitefetch.URLs;

package body Sitefetch is
   function Ensure_HTTP_Scheme (URL : String) return String is
   begin
      return Sitefetch.URLs.Ensure_HTTP_Scheme (URL);
   end Ensure_HTTP_Scheme;

   function Domain_Of (URL : String) return String is
   begin
      return Sitefetch.URLs.Domain_Of (URL);
   end Domain_Of;

   function Is_Same_Domain (Root_URL : String; Candidate : String) return Boolean is
   begin
      return Sitefetch.URLs.Is_Same_Domain (Root_URL, Candidate);
   end Is_Same_Domain;

   function Resolve_URL (Base_URL : String; Reference : String) return String is
   begin
      return Sitefetch.URLs.Resolve_URL (Base_URL, Reference);
   end Resolve_URL;

   function Canonical_URL (URL : String) return String is
   begin
      return Sitefetch.URLs.Canonical_URL (URL);
   end Canonical_URL;

   function Local_Path_For_URL (URL : String) return String is
   begin
      return Sitefetch.URLs.Local_Path_For_URL (URL);
   end Local_Path_For_URL;

   function Is_Dangerous_File_Type (URL : String) return Boolean is
   begin
      return Sitefetch.Content.Is_Dangerous_File_Type (URL);
   end Is_Dangerous_File_Type;

   function Is_Safe_Asset_File_Type (URL : String) return Boolean is
   begin
      return Sitefetch.Content.Is_Safe_Asset_File_Type (URL);
   end Is_Safe_Asset_File_Type;

   function Should_Download_To_File (URL : String) return Boolean is
   begin
      return Sitefetch.Content.Should_Download_To_File (URL);
   end Should_Download_To_File;

   function Should_Parse_Content_Type (Content_Type : String) return Boolean is
   begin
      return Sitefetch.Content.Should_Parse_Content_Type (Content_Type);
   end Should_Parse_Content_Type;

   function Extract_Links (Document_Text : String) return Link_List is
   begin
      return Sitefetch.Documents.Extract_Links (Document_Text);
   end Extract_Links;

   function Rewrite_Document
     (Document_Text : String;
      Page_URL      : String;
      Root_URL      : String) return String is
   begin
      return Sitefetch.Documents.Rewrite_Document (Document_Text, Page_URL, Root_URL);
   end Rewrite_Document;
end Sitefetch;
