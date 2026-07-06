with Ada.Text_IO;

with Sitefetch;
with Sitefetch.Content;
with Sitefetch.URLs;

procedure URL_Content_Helpers is
   Root       : constant String := "https://example.com/docs/guide/index.html";
   Reference  : constant String := "../assets/manual.pdf#download";
   Resolved   : constant String := Sitefetch.URLs.Resolve_URL (Root, Reference);
   Canonical  : constant String := Sitefetch.URLs.Canonical_URL (Resolved);
   Local_Path : constant String := Sitefetch.URLs.Local_Path_For_URL (Canonical);
   In_Scope   : constant Boolean :=
     Sitefetch.URLs.Is_In_Domain
       (Root_Domain => Sitefetch.URLs.Domain_Of (Root),
        Candidate   => Sitefetch.URLs.Domain_Of (Canonical),
        Policy      => Sitefetch.Domain_Exact_And_Subdomains);
   Parse_HTML : constant Boolean :=
     Sitefetch.Content.Should_Parse_Content_Type ("text/html; charset=utf-8");
   Parse_PDF : constant Boolean :=
     Sitefetch.Content.Should_Parse_Content_Type ("application/pdf");
   Download_PDF : constant Boolean :=
     Sitefetch.Content.Should_Download_To_File (Canonical);
begin
   pragma Assert (Resolved = "https://example.com/docs/assets/manual.pdf");
   pragma Assert (Canonical = "https://example.com/docs/assets/manual.pdf");
   pragma Assert (Sitefetch.URLs.Domain_Of (Canonical) = "example.com");
   pragma Assert (In_Scope);
   pragma Assert (Local_Path = "docs/assets/manual.pdf");
   pragma Assert (Parse_HTML);
   pragma Assert (not Parse_PDF);
   pragma Assert (Download_PDF);

   Ada.Text_IO.Put_Line ("resolved=" & Resolved);
   Ada.Text_IO.Put_Line ("canonical=" & Canonical);
   Ada.Text_IO.Put_Line ("local_path=" & Local_Path);
   Ada.Text_IO.Put_Line ("download_pdf=" & Boolean'Image (Download_PDF));
end URL_Content_Helpers;
