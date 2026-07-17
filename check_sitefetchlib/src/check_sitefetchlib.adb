with Ada.Command_Line;
with Ada.Directories;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;

with GNAT.OS_Lib;

with Project_Tools.Alire_Manifests;
with Project_Tools.Files;
with Project_Tools.Processes;
with Project_Tools.Release_Checks;
with Project_Tools.Text;
with Project_Tools.Tree_Checks;

procedure Check_Sitefetchlib is
   use Ada.Text_IO;
   use GNAT.OS_Lib;

   --  --level=4 is the full proof; -j0 parallelises and --timeout caps each VC
   --  so the check terminates instead of hitting the 6-hour CI job limit.
   Gnatprove_Check_Args : constant Argument_List :=
     (1 => new String'("exec"),
      2 => new String'("--"),
      3 => new String'("gnatprove"),
      4 => new String'("-P"),
      5 => new String'("sitefetchlib.gpr"),
      6 => new String'("--level=4"),
      7 => new String'("-j0"),
      8 => new String'("--timeout=60"));

   GNAT_Version_Check_Args : constant Argument_List :=
     (1 => new String'("exec"),
      2 => new String'("--"),
      3 => new String'("gnatls"),
      4 => new String'("--version"));

   function Root_Directory return String is
      Current : constant String := Ada.Directories.Current_Directory;
   begin
      if Ada.Directories.Exists (Current & "/docs/API.md") then
         return Current;
      elsif Ada.Directories.Exists (Current & "/../docs/API.md") then
         return Current & "/..";
      else
         Put_Line (Standard_Error, "sitefetchlib root not found from " & Current);
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         raise Program_Error;
      end if;
   end Root_Directory;

   Root   : constant String := Root_Directory;
   Checks : constant Project_Tools.Release_Checks.Checker :=
     Project_Tools.Release_Checks.Create (Root);

   function Alr_Path return String is
   begin
      Project_Tools.Processes.Require_Command
        ("alr",
         "alr executable not found on PATH",
         Quiet => False);
      return Project_Tools.Processes.Locate_Command ("alr");
   end Alr_Path;

   procedure Run_Gnatprove_Check is
   begin
      Project_Tools.Release_Checks.Run
        (Label   => "run sitefetchlib GNATprove release check",
         Dir     => Root,
         Program => Alr_Path,
         Args    => Gnatprove_Check_Args,
         Quiet   => False);
   end Run_Gnatprove_Check;

   procedure Require_Alire_GNAT_15 is
      Output : Unbounded_String;
      Status : Integer;
   begin
      Status :=
        Project_Tools.Processes.Run_Status
          (Label   => "verify Alire-selected GNAT 15 toolchain",
           Dir     => Root,
           Program => Alr_Path,
           Args    => GNAT_Version_Check_Args,
           Output  => Output,
           Quiet   => False);

      if Status /= 0 then
         Put_Line (Standard_Error, "alr exec -- gnatls --version failed");
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         raise Program_Error;
      elsif not Project_Tools.Text.Contains (To_String (Output), "GNATLS 15.") then
         Put_Line
           (Standard_Error,
            "sitefetchlib must build with Alire-selected GNAT 15, got: " & To_String (Output));
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         raise Program_Error;
      end if;
   end Require_Alire_GNAT_15;

   procedure Require_Text (Relative_Path : String; Text : String) is
   begin
      Project_Tools.Release_Checks.Require_Text (Checks, Relative_Path, Text);
   end Require_Text;

   procedure Require_GNAT_15_Manifest (Relative_Path : String) is
   begin
      Require_Text (Relative_Path, "gnat_native = ""=15.2.1""");
   end Require_GNAT_15_Manifest;

   procedure Check_Release_Template is
   begin
      Project_Tools.Alire_Manifests.Require_Pin_Free_Crate_Manifest
        (Root & "/sitefetchlib.alire.release.toml", "sitefetchlib");
      Project_Tools.Alire_Manifests.Require_Release_Dependencies
        (Root & "/sitefetchlib.alire.release.toml",
         [To_Unbounded_String ("httpclient"),
          To_Unbounded_String ("regexp"),
          To_Unbounded_String ("zlib")]);
   end Check_Release_Template;

   procedure Check_Generated_Artifacts is
      Hygiene_Errors : Natural := 0;
   begin
      Project_Tools.Tree_Checks.Check_No_Generated_Python (Hygiene_Errors, Root & "/src");
      Project_Tools.Tree_Checks.Check_No_Generated_Python (Hygiene_Errors, Root & "/docs");
      Project_Tools.Tree_Checks.Check_No_Generated_Python (Hygiene_Errors, Root & "/examples");
      Project_Tools.Tree_Checks.Check_No_Generated_Python (Hygiene_Errors, Root & "/tests/src");
      if Hygiene_Errors /= 0 then
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         raise Program_Error;
      end if;
   end Check_Generated_Artifacts;

   procedure Require_Checked_Example (Relative_Path : String) is
   begin
      Require_Text ("docs/API.md", Relative_Path);

      if not Ada.Directories.Exists (Root & "/" & Relative_Path) then
         Put_Line (Standard_Error, "documented checked example does not exist: " & Relative_Path);
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         raise Program_Error;
      end if;
   end Require_Checked_Example;

   procedure Require_All_Checked_Examples_Documented is
      API_Content : constant String := Project_Tools.Files.Read_Raw_File (Root & "/docs/API.md");
      Search      : Ada.Directories.Search_Type;
      Dir_Entry   : Ada.Directories.Directory_Entry_Type;
      Filter      : constant Ada.Directories.Filter_Type :=
        (Ada.Directories.Ordinary_File => False,
         Ada.Directories.Directory     => True,
         Ada.Directories.Special_File  => False);
   begin
      Ada.Directories.Start_Search
        (Search    => Search,
         Directory => Root & "/examples",
         Pattern   => "",
         Filter    => Filter);

      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Dir_Entry);

         declare
            Example_Name : constant String := Ada.Directories.Simple_Name (Dir_Entry);
            Example_Path : constant String := "examples/" & Example_Name;
         begin
            if Example_Name /= "." and then Example_Name /= ".."
              and then Ada.Directories.Exists (Root & "/" & Example_Path & "/alire.toml")
              and then not Project_Tools.Text.Contains (API_Content, Example_Path)
            then
               Put_Line (Standard_Error, "checked example missing from docs/API.md: " & Example_Path);
               Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
               raise Program_Error;
            end if;
         end;
      end loop;

      Ada.Directories.End_Search (Search);
   exception
      when others =>
         Ada.Directories.End_Search (Search);
         raise;
   end Require_All_Checked_Examples_Documented;
begin
   Require_Alire_GNAT_15;
   Require_GNAT_15_Manifest ("alire.toml");
   Require_GNAT_15_Manifest ("sitefetchlib.alire.release.toml");
   Require_GNAT_15_Manifest ("tests/alire.toml");
   Require_GNAT_15_Manifest ("check_sitefetchlib/alire.toml");
   Require_GNAT_15_Manifest ("public_api_smoke/alire.toml");
   Require_GNAT_15_Manifest ("examples/basic_mirror/alire.toml");
   Require_GNAT_15_Manifest ("examples/structured_progress/alire.toml");
   Require_GNAT_15_Manifest ("examples/url_content_helpers/alire.toml");

   Require_Text ("README.md", "docs/API.md");
   Require_Text ("README.md", "sitefetchlib.alire.release.toml");
   Require_Text ("README.md", "SPARK Release Check");
   Require_Text ("README.md", "docs/SPARK.md");
   Require_Text ("README.md", "gnat_native = ""=15.2.1""");
   Require_Text ("README.md", "alr exec -- gnatls --version");
   Require_Text ("README.md", "Do not run plain system GNAT");
   Require_Text ("README.md", "alr exec -- gnatprove -P sitefetchlib.gpr --level=4");
   Require_Text ("README.md", "Most sitefetchlib crawler implementation");
   Require_Text ("README.md", "examples/structured_progress");
   Require_Text ("README.md", "Fetch_Website_With_Structured_Progress");
   Require_Text ("README.md", "package-level callback");
   Require_Text ("README.md", "cache_rejections");
   Require_Text ("README.md", "Progress_Cache_Rejected");
   Require_Text ("README.md", ".sitefetch_http_cache");
   Require_Text ("README.md", "Checked examples");
   Require_Text ("README.md", "executables = [""...""]");
   Require_Text ("README.md", "run without network");
   Require_Text ("README.md", "docs/API.md");

   Require_Text ("docs/API.md", "Sitefetch");
   Require_Text ("docs/API.md", "Sitefetch.Crawler");
   Require_Text ("docs/API.md", "Sitefetch.Crawl");
   Require_Text ("docs/API.md", "Sitefetch.HTTP");
   Require_Text ("docs/API.md", "Sitefetch.Cache");
   Require_Text ("docs/API.md", "Sitefetch.Safety");
   Require_Text ("docs/API.md", "Sitefetch.Diagnostics");
   Require_Text ("docs/API.md", "Sitefetch.Client_Config");
   Require_Text ("docs/API.md", "Sitefetch.Domains");
   Require_Text ("docs/API.md", "Public_Suffix_For_Normalized_Host");
   Require_Text ("docs/API.md", "Is_Internal_Host");
   Require_Text ("docs/API.md", "Sitefetch.Testing");
   Require_Text ("docs/API.md", "Sitefetch.Engine");
   Require_Text ("docs/API.md", "stable production records");
   Require_Text ("docs/API.md", "public support API");
   Require_Text ("docs/API.md", "testing and fixture API");
   Require_Text ("docs/API.md", "private internal crawl engine");
   Require_Checked_Example ("examples/basic_mirror");
   Require_Checked_Example ("examples/structured_progress");
   Require_Checked_Example ("examples/url_content_helpers");
   Require_All_Checked_Examples_Documented;
   Check_Release_Template;
   Check_Generated_Artifacts;
   Require_Text ("docs/API.md", "Fetch_Website_With_Structured_Progress");
   Require_Text ("docs/API.md", "package-level");
   Require_Text ("docs/API.md", "cache_rejections");
   Require_Text ("docs/API.md", "Progress_Cache_Rejected");
   Require_Text ("docs/API.md", ".sitefetch_http_cache");
   Require_Text ("docs/API.md", "Checked examples");
   Require_Text ("docs/API.md", "executables = [""...""]");
   Require_Text ("docs/API.md", "run without network");

   Require_Text ("src/sitefetch.ads", "Support level: stable production API.");
   Require_Text ("src/sitefetch-crawler.ads", "Support level: stable production API.");
   Require_Text ("src/sitefetch-crawl.ads", "Support level: stable production API.");
   Require_Text ("src/sitefetch-http.ads", "Support level: stable production API.");
   Require_Text ("src/sitefetch-cache.ads", "Support level: stable production API.");
   Require_Text ("src/sitefetch-safety.ads", "Support level: stable production API.");
   Require_Text ("src/sitefetch-diagnostics.ads", "Support level: stable production API.");
   Require_Text ("src/sitefetch-client_config.ads", "Support level: public support API.");
   Require_Text ("src/sitefetch-urls.ads", "Support level: public support API.");
   Require_Text ("src/sitefetch-content.ads", "Support level: public support API.");
   Require_Text ("src/sitefetch-domains.ads", "Support level: public support API.");
   Require_Text ("src/sitefetch-testing.ads", "Support level: testing and fixture API.");
   Require_Text ("src/sitefetch-documents.ads", "Support level: private internal implementation.");
   Require_Text ("src/sitefetch-engine.ads", "Support level: private internal implementation.");

   Require_Text ("docs/SPARK.md", "Sitefetch.Domains");
   Require_Text ("docs/SPARK.md", "Public_Suffix_For_Normalized_Host");
   Require_Text ("docs/SPARK.md", "Normalized_Host");

   Run_Gnatprove_Check;

   Project_Tools.Tree_Checks.Require_No_Nonempty_Stderr (Root & "/obj");
   Project_Tools.Tree_Checks.Require_No_Nonempty_Stderr (Root & "/tests/obj");
   Project_Tools.Tree_Checks.Require_No_Nonempty_Stderr (Root & "/check_sitefetchlib/obj");
   Project_Tools.Tree_Checks.Require_No_Nonempty_Stderr (Root & "/public_api_smoke/obj");
   Project_Tools.Tree_Checks.Require_No_Nonempty_Stderr (Root & "/examples/basic_mirror/obj");
   Project_Tools.Tree_Checks.Require_No_Nonempty_Stderr (Root & "/examples/structured_progress/obj");
   Project_Tools.Tree_Checks.Require_No_Nonempty_Stderr (Root & "/examples/url_content_helpers/obj");

   Put_Line ("sitefetchlib release check passed.");
exception
   when Program_Error =>
      null;
end Check_Sitefetchlib;
