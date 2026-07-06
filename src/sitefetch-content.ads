--  Support level: public support API.
--
--  Resource type and MIME/content classification helpers shared by the public
--  Sitefetch helpers and the crawl engine.

package Sitefetch.Content is
   function Is_Sitemap_URL (URL : String) return Boolean;

   function Is_Compressed_Sitemap_URL (URL : String) return Boolean;

   function Is_Page_Like_URL (URL : String) return Boolean;

   function Is_Text_Asset_URL (URL : String) return Boolean;

   function Is_Dangerous_File_Type (URL : String) return Boolean;

   function Is_Safe_Asset_File_Type (URL : String) return Boolean;

   function Should_Download_To_File (URL : String) return Boolean;

   function Base_Content_Type (Content_Type : String) return String;

   function Should_Probe_With_HEAD (Limits : Fetch_Options; URL : String) return Boolean;

   function Is_Parseable_Content_Type (Media_Type : String) return Boolean;

   function Is_Passive_Binary_Content_Type (Media_Type : String) return Boolean;

   function Should_Parse_Content_Type (Content_Type : String) return Boolean;
end Sitefetch.Content;
