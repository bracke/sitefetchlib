with Ada.Strings.Fixed;

with Sitefetch.URLs;

package body Sitefetch.Content is
   use Sitefetch.URLs;

   function Has_Suffix (Item : String; Suffix : String) return Boolean is
   begin
      return Item'Length >= Suffix'Length
        and then Item (Item'Last - Suffix'Length + 1 .. Item'Last) = Suffix;
   end Has_Suffix;

   function Is_Sitemap_URL (URL : String) return Boolean is
      Extension : constant String := Extension_Of (URL);
      Path_Text : constant String :=
        To_Lower (Without_Query_Or_Fragment (Path_Only (Ensure_HTTP_Scheme (URL))));
   begin
      return (Extension in "xml" | "gz" or else Extension = "")
        and then Ada.Strings.Fixed.Index (Path_Text, "sitemap") > 0;
   end Is_Sitemap_URL;

   function Is_Compressed_Sitemap_URL (URL : String) return Boolean is
   begin
      return Extension_Of (URL) = "gz" and then Is_Sitemap_URL (URL);
   end Is_Compressed_Sitemap_URL;

   function Is_Page_Like_URL (URL : String) return Boolean is
      Extension : constant String := Extension_Of (URL);
      Path_Text : constant String := Without_Query_Or_Fragment (Path_Only (Ensure_HTTP_Scheme (URL)));
   begin
      return Extension = ""
        or else Extension in "htm" | "html" | "xhtml"
        or else (Path_Text'Length > 0 and then Path_Text (Path_Text'Last) = '/');
   end Is_Page_Like_URL;

   function Is_Text_Asset_URL (URL : String) return Boolean is
      Extension : constant String := Extension_Of (URL);
   begin
      return Extension in "css" | "js" | "mjs" | "json" | "xml"
        or else Extension in "rss" | "atom" | "txt" | "svg";
   end Is_Text_Asset_URL;

   function Is_Dangerous_File_Type (URL : String) return Boolean is
      Extension : constant String := Extension_Of (URL);
   begin
      return Extension in "exe" | "msi" | "dmg" | "pkg" | "deb" | "rpm" | "appimage"
        or else Extension in "sh" | "bash" | "zsh" | "ps1" | "bat" | "cmd" | "vbs" | "hta" | "jar"
        or else Extension in "docm" | "dotm" | "xlsm" | "xlam" | "pptm" | "potm" | "ppsm"
        or else Extension in "zip" | "tar" | "tgz" | "bz2" | "xz" | "7z" | "rar"
        or else (Extension = "gz" and then not Is_Compressed_Sitemap_URL (URL))
        or else Extension in "iso" | "img" | "vhd" | "vhdx" | "swf" | "wasm";
   end Is_Dangerous_File_Type;

   function Is_Safe_Asset_File_Type (URL : String) return Boolean is
      Extension : constant String := Extension_Of (URL);
   begin
      return Extension in "avif" | "bmp" | "gif" | "ico" | "jpeg" | "jpg" | "png" | "tif" | "tiff"
        or else Extension in "webp" | "m4v" | "mkv" | "mov" | "mp4" | "mpeg" | "mpg" | "ogv" | "webm"
        or else Extension in "wmv" | "mp3" | "m4a" | "aac" | "ogg" | "oga" | "opus" | "wav" | "flac"
        or else Extension in "weba" | "mid" | "midi" | "woff" | "woff2" | "ttf" | "otf" | "eot";
   end Is_Safe_Asset_File_Type;

   function Should_Download_To_File (URL : String) return Boolean is
      Extension : constant String := Extension_Of (URL);
   begin
      return Extension in "avif" | "bmp" | "gif" | "ico" | "jpeg" | "jpg" | "png" | "tif" | "tiff"
        or else Extension in "webp" | "m4v" | "mkv" | "mov" | "mp4" | "mpeg" | "mpg" | "ogv" | "webm" | "wmv"
        or else Extension in "pdf" | "doc" | "docx" | "docm" | "dot" | "dotx" | "dotm" | "odf" | "odg"
        or else Extension in "odp" | "ods" | "odt" | "pot" | "potx" | "potm" | "pps" | "ppsx" | "ppsm"
        or else Extension in "ppt" | "pptx" | "pptm" | "rtf" | "xls" | "xlsx" | "xlsm" | "xlam"
        or else Extension in "zip" | "tar" | "tgz" | "bz2" | "xz" | "7z" | "rar"
        or else (Extension = "gz" and then not Is_Compressed_Sitemap_URL (URL))
        or else Extension in "mp3" | "m4a" | "aac" | "ogg" | "oga" | "opus" | "wav" | "flac" | "weba"
        or else Extension in "mid" | "midi" | "woff" | "woff2" | "ttf" | "otf" | "eot" | "wasm"
        or else Extension in "exe" | "msi" | "dmg" | "pkg" | "deb" | "rpm" | "appimage" | "sh" | "bash"
        or else Extension in "zsh" | "ps1" | "bat" | "cmd" | "vbs" | "hta" | "jar" | "swf"
        or else Extension in "iso" | "img" | "vhd" | "vhdx" | "bin" | "dat" | "epub" | "mobi" | "azw" | "azw3"
        or else Extension in "glb" | "gltf" | "obj" | "fbx" | "stl" | "dae" | "dwg" | "dxf";
   end Should_Download_To_File;

   function Base_Content_Type (Content_Type : String) return String is
      Trimmed : constant String := Ada.Strings.Fixed.Trim (Content_Type, Ada.Strings.Both);
   begin
      for Index_Value in Trimmed'Range loop
         if Trimmed (Index_Value) = ';' then
            if Index_Value = Trimmed'First then
               return "";
            else
               return To_Lower
                 (Ada.Strings.Fixed.Trim
                    (Trimmed (Trimmed'First .. Index_Value - 1), Ada.Strings.Both));
            end if;
         end if;
      end loop;

      return To_Lower (Trimmed);
   end Base_Content_Type;

   function Should_Probe_With_HEAD (Limits : Fetch_Options; URL : String) return Boolean is
      Extension : constant String := Extension_Of (URL);
      Path_Text : constant String := Without_Query_Or_Fragment (Path_Only (Ensure_HTTP_Scheme (URL)));
   begin
      if Is_Compressed_Sitemap_URL (URL) then
         return False;
      end if;

      case Limits.HTTP.Head is
         when Head_Page_Like =>
            return True;
         when Head_Ambiguous_Only =>
            return Extension = ""
              and then Path_Text'Length > 0
              and then Path_Text (Path_Text'Last) /= '/';
         when Head_Disabled =>
            return False;
      end case;
   end Should_Probe_With_HEAD;

   function Is_Parseable_Content_Type (Media_Type : String) return Boolean is
   begin
      return Starts_With (Media_Type, "text/")
        or else Media_Type in "application/javascript" | "application/ecmascript"
          | "application/json" | "application/ld+json" | "application/x-javascript"
          | "application/xhtml+xml" | "application/xml" | "image/svg+xml"
        or else Has_Suffix (Media_Type, "+json")
        or else Has_Suffix (Media_Type, "+xml");
   end Is_Parseable_Content_Type;

   function Is_Passive_Binary_Content_Type (Media_Type : String) return Boolean is
   begin
      return Media_Type in "application/octet-stream" | "application/pdf"
        or else Starts_With (Media_Type, "image/")
        or else Starts_With (Media_Type, "audio/")
        or else Starts_With (Media_Type, "video/")
        or else Starts_With (Media_Type, "font/")
        or else Media_Type in "application/font-woff" | "application/font-woff2"
          | "application/vnd.ms-fontobject" | "application/x-font-ttf"
          | "application/x-font-otf" | "application/x-font-woff"
          | "application/x-font-woff2";
   end Is_Passive_Binary_Content_Type;

   function Should_Parse_Content_Type (Content_Type : String) return Boolean is
      Media_Type : constant String := Base_Content_Type (Content_Type);
   begin
      if Media_Type = "" then
         return True;
      elsif Is_Parseable_Content_Type (Media_Type) then
         return True;
      elsif Is_Passive_Binary_Content_Type (Media_Type) then
         return False;
      else
         return False;
      end if;
   end Should_Parse_Content_Type;

end Sitefetch.Content;
