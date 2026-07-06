with Ada.Characters.Handling;
with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded;

with Http_Client.Errors;
with Http_Client.URI;

with Sitefetch.Domains;

package body Sitefetch.URLs is
   use Ada.Strings.Unbounded;
   use type Http_Client.Errors.Result_Status;

   package URL_Path_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => String,
      Element_Type    => String,
      Hash            => Ada.Strings.Hash,
      Equivalent_Keys => "=");

   protected Local_Path_Cache is
      procedure Lookup (URL : String; Found : out Boolean; Path : out Unbounded_String);
      procedure Store (URL : String; Path : String);
   private
      Entries : URL_Path_Maps.Map;
   end Local_Path_Cache;


   protected body Local_Path_Cache is
      procedure Lookup (URL : String; Found : out Boolean; Path : out Unbounded_String) is
      begin
         Found := Entries.Contains (URL);
         if Found then
            Path := To_Unbounded_String (Entries.Element (URL));
         else
            Path := Null_Unbounded_String;
         end if;
      end Lookup;

      procedure Store (URL : String; Path : String) is
      begin
         Entries.Include (URL, Path);
      end Store;
   end Local_Path_Cache;

   function Starts_With (Item : String; Prefix : String) return Boolean is
   begin
      return Item'Length >= Prefix'Length
        and then Item (Item'First .. Item'First + Prefix'Length - 1) = Prefix;
   end Starts_With;

   function Starts_With_Case_Insensitive (Item : String; Prefix : String) return Boolean is
   begin
      if Item'Length < Prefix'Length then
         return False;
      end if;

      for Offset in 0 .. Prefix'Length - 1 loop
         if Ada.Characters.Handling.To_Lower (Item (Item'First + Offset))
           /= Ada.Characters.Handling.To_Lower (Prefix (Prefix'First + Offset))
         then
            return False;
         end if;
      end loop;

      return True;
   end Starts_With_Case_Insensitive;

   function To_Lower (Item : String) return String is
      Result_Text : String (Item'Range);
   begin
      for Index_Value in Item'Range loop
         Result_Text (Index_Value) := Ada.Characters.Handling.To_Lower (Item (Index_Value));
      end loop;

      return Result_Text;
   end To_Lower;

   function Strip_Fragment (URL : String) return String is
   begin
      for Index_Value in URL'Range loop
         if URL (Index_Value) = '#' then
            if Index_Value = URL'First then
               return "";
            end if;

            return URL (URL'First .. Index_Value - 1);
         end if;
      end loop;

      return URL;
   end Strip_Fragment;

   function Has_Explicit_Scheme (Reference : String) return Boolean is
   begin
      for Index_Value in Reference'Range loop
         if Reference (Index_Value) = ':' then
            return Index_Value > Reference'First;
         elsif Reference (Index_Value) = '/' or else Reference (Index_Value) = '?'
           or else Reference (Index_Value) = '#'
         then
            return False;
         end if;
      end loop;

      return False;
   end Has_Explicit_Scheme;

   function Is_HTTP_URL (URL : String) return Boolean is
   begin
      return Starts_With_Case_Insensitive (URL, "http://")
        or else Starts_With_Case_Insensitive (URL, "https://");
   end Is_HTTP_URL;

   function Is_Fetchable_Reference (Reference : String) return Boolean is
   begin
      if Reference = "" or else Reference (Reference'First) = '#' then
         return False;
      elsif Starts_With (Reference, "//") then
         return True;
      elsif Has_Explicit_Scheme (Reference) then
         return Is_HTTP_URL (Reference);
      else
         return True;
      end if;
   end Is_Fetchable_Reference;

   function Parse_Absolute_HTTP_URL
     (URL  : String;
      Item : out Http_Client.URI.URI_Reference) return Boolean
   is
      use type Http_Client.Errors.Result_Status;
   begin
      return Http_Client.URI.Parse
        ((if Is_HTTP_URL (URL) then URL else "http://" & URL), Item) = Http_Client.Errors.Ok;
   end Parse_Absolute_HTTP_URL;

   function Scheme_Of (URL : String) return String is
      Parsed : Http_Client.URI.URI_Reference;
   begin
      if Parse_Absolute_HTTP_URL (URL, Parsed) then
         return Http_Client.URI.Scheme (Parsed);
      elsif Starts_With_Case_Insensitive (URL, "https://") then
         return "https";
      elsif Starts_With_Case_Insensitive (URL, "http://") then
         return "http";
      else
         return "http";
      end if;
   end Scheme_Of;

   function Authority_Start (URL : String) return Natural is
   begin
      if URL'Length < 3 then
         return 0;
      end if;

      for Index_Value in URL'First .. URL'Last - 2 loop
         if URL (Index_Value .. Index_Value + 2) = "://" then
            return Index_Value + 3;
         end if;
      end loop;

      return 0;
   end Authority_Start;

   function Authority_End (URL : String; Start_At : Positive) return Natural is
   begin
      for Index_Value in Start_At .. URL'Last loop
         if URL (Index_Value) = '/' or else URL (Index_Value) = '?'
           or else URL (Index_Value) = '#'
         then
            return Index_Value - 1;
         end if;
      end loop;

      return URL'Last;
   end Authority_End;

   function Path_Start (URL : String) return Natural is
      Start_At : constant Natural := Authority_Start (URL);
   begin
      if Start_At = 0 then
         return 0;
      end if;

      for Index_Value in Start_At .. URL'Last loop
         if URL (Index_Value) = '/' then
            return Index_Value;
         elsif URL (Index_Value) = '?' or else URL (Index_Value) = '#' then
            return 0;
         end if;
      end loop;

      return 0;
   end Path_Start;

   function Path_Only (URL : String) return String is
      Parsed   : Http_Client.URI.URI_Reference;
      Start_At : constant Natural := Path_Start (URL);
   begin
      if Parse_Absolute_HTTP_URL (URL, Parsed) then
         return Http_Client.URI.Path (Parsed);
      elsif Start_At = 0 then
         return "/";
      end if;

      for Index_Value in Start_At .. URL'Last loop
         if URL (Index_Value) = '?' or else URL (Index_Value) = '#' then
            if Index_Value = Start_At then
               return "/";
            end if;

            return URL (Start_At .. Index_Value - 1);
         end if;
      end loop;

      return URL (Start_At .. URL'Last);
   end Path_Only;

   function Origin_Of (URL : String) return String is
      Parsed   : Http_Client.URI.URI_Reference;
      Start_At : constant Natural := Authority_Start (URL);
   begin
      if Parse_Absolute_HTTP_URL (URL, Parsed) then
         return Http_Client.URI.Scheme (Parsed) & "://" & Http_Client.URI.Host_Header_Value (Parsed);
      elsif Start_At = 0 then
         return "";
      end if;

      return Scheme_Of (URL) & "://" & URL (Start_At .. Authority_End (URL, Start_At));
   end Origin_Of;

   function Directory_Of (URL : String) return String is
      Path_Text : constant String := Path_Only (URL);
   begin
      for Index_Value in reverse Path_Text'Range loop
         if Path_Text (Index_Value) = '/' then
            return Path_Text (Path_Text'First .. Index_Value);
         end if;
      end loop;

      return "/";
   end Directory_Of;

   function Without_Query_Or_Fragment (Text : String) return String is
   begin
      for Index_Value in Text'Range loop
         if Text (Index_Value) = '?' or else Text (Index_Value) = '#' then
            if Index_Value = Text'First then
               return "";
            end if;

            return Text (Text'First .. Index_Value - 1);
         end if;
      end loop;

      return Text;
   end Without_Query_Or_Fragment;

   function Query_Only (Text : String) return String is
      Parsed : Http_Client.URI.URI_Reference;
   begin
      if Parse_Absolute_HTTP_URL (Text, Parsed) then
         if Http_Client.URI.Has_Query (Parsed) then
            return "?" & Http_Client.URI.Query (Parsed);
         else
            return "";
         end if;
      end if;

      for Index_Value in Text'Range loop
         if Text (Index_Value) = '?' then
            for End_Index in Index_Value + 1 .. Text'Last loop
               if Text (End_Index) = '#' then
                  return Text (Index_Value .. End_Index - 1);
               end if;
            end loop;

            return Text (Index_Value .. Text'Last);
         elsif Text (Index_Value) = '#' then
            return "";
         end if;
      end loop;

      return "";
   end Query_Only;

   function Normalize_Path (Path_Text : String) return String is
      Parts  : String_Vectors.Vector;
      First  : Positive := Path_Text'First;
      Result : Unbounded_String := Null_Unbounded_String;

      procedure Add_Part (First_Index : Positive; Last_Index : Natural) is
      begin
         if Last_Index < First_Index then
            return;
         end if;

         declare
            Part_Text : constant String := Path_Text (First_Index .. Last_Index);
         begin
            if Part_Text = "" or else Part_Text = "." then
               return;
            elsif Part_Text = ".." then
               if not Parts.Is_Empty then
                  Parts.Delete_Last;
               end if;
            else
               Parts.Append (Part_Text);
            end if;
         end;
      end Add_Part;
   begin
      for Index_Value in Path_Text'Range loop
         if Path_Text (Index_Value) = '/' then
            Add_Part (First, Index_Value - 1);
            First := Index_Value + 1;
         end if;
      end loop;

      if First <= Path_Text'Last then
         Add_Part (First, Path_Text'Last);
      end if;

      if Parts.Is_Empty then
         return "/";
      end if;

      for Part_Text of Parts loop
         Append (Result, "/");
         Append (Result, Part_Text);
      end loop;

      if Path_Text (Path_Text'Last) = '/' then
         Append (Result, "/");
      end if;

      return To_String (Result);
   end Normalize_Path;

   function Ensure_HTTP_Scheme (URL : String) return String is
   begin
      if Is_HTTP_URL (URL) then
         return URL;
      else
         return "http://" & URL;
      end if;
   end Ensure_HTTP_Scheme;

   function Normalize_Host_Name (Host : String) return String is
      Lower : constant String := To_Lower (Host);
      Last  : Natural := Lower'Last;
   begin
      while Last >= Lower'First and then Lower (Last) = '.' loop
         Last := Last - 1;
      end loop;

      if Last < Lower'First then
         return "";
      else
         return Lower (Lower'First .. Last);
      end if;
   end Normalize_Host_Name;

   function Domain_Of (URL : String) return String is
      Parsed     : Http_Client.URI.URI_Reference;
      Normal_URL : constant String := Ensure_HTTP_Scheme (URL);
      Start_At   : constant Natural := Authority_Start (Normal_URL);
      Finish_At  : Natural;
      Host_First : Natural;
      Host_Last  : Natural;
   begin
      if Parse_Absolute_HTTP_URL (URL, Parsed) then
         return Normalize_Host_Name (Http_Client.URI.Host (Parsed));
      elsif Start_At = 0 then
         return "";
      end if;

      Finish_At := Authority_End (Normal_URL, Start_At);
      if Finish_At < Start_At then
         return "";
      end if;

      Host_First := Start_At;
      for Index_Value in reverse Start_At .. Finish_At loop
         if Normal_URL (Index_Value) = '@' then
            Host_First := Index_Value + 1;
            exit;
         end if;
      end loop;

      Host_Last := Finish_At;
      for Index_Value in Host_First .. Finish_At loop
         if Normal_URL (Index_Value) = ':' then
            Host_Last := Index_Value - 1;
            exit;
         end if;
      end loop;

      if Host_Last < Host_First then
         return "";
      end if;

      return Normalize_Host_Name (Normal_URL (Host_First .. Host_Last));
   end Domain_Of;

   function Is_Child_Of (Child_Domain : String; Parent_Domain : String) return Boolean is
   begin
      return Child_Domain'Length > Parent_Domain'Length
        and then Child_Domain
          (Child_Domain'Last - Parent_Domain'Length .. Child_Domain'Last) = "." & Parent_Domain;
   end Is_Child_Of;

   function Is_In_Domain
     (Root_Domain : String;
      Candidate   : String;
      Policy      : Domain_Policy := Domain_Exact_And_Subdomains) return Boolean is
   begin
      return Sitefetch.Domains.Is_Internal (Root_Domain, Candidate, Policy);
   end Is_In_Domain;

   function Is_Same_Domain (Root_URL : String; Candidate : String) return Boolean is
   begin
      return Is_In_Domain (Domain_Of (Root_URL), Candidate);
   end Is_Same_Domain;

   function Resolve_URL (Base_URL : String; Reference : String) return String is
      Clean_Reference : constant String := Strip_Fragment (Reference);
      Base_Absolute   : constant String := Ensure_HTTP_Scheme (Base_URL);
      Prefix_Text     : constant String := Origin_Of (Base_Absolute);
      Path_Text       : Unbounded_String;
      Query_Text      : Unbounded_String;
   begin
      if Clean_Reference = "" then
         return Strip_Fragment (Base_Absolute);
      elsif Starts_With_Case_Insensitive (Clean_Reference, "http://")
        or else Starts_With_Case_Insensitive (Clean_Reference, "https://")
      then
         return Clean_Reference;
      elsif Starts_With (Clean_Reference, "//") then
         return Scheme_Of (Base_Absolute) & ":" & Clean_Reference;
      elsif Starts_With (Clean_Reference, "/") then
         for Index_Value in Clean_Reference'Range loop
            if Clean_Reference (Index_Value) = '?' then
               Query_Text := To_Unbounded_String (Clean_Reference (Index_Value .. Clean_Reference'Last));
               exit;
            end if;
         end loop;

         return Prefix_Text
           & Normalize_Path (Without_Query_Or_Fragment (Clean_Reference))
           & To_String (Query_Text);
      elsif Starts_With (Clean_Reference, "?") then
         return Prefix_Text & Path_Only (Base_Absolute) & Clean_Reference;
      else
         for Index_Value in Clean_Reference'Range loop
            if Clean_Reference (Index_Value) = '?' then
               Query_Text := To_Unbounded_String (Clean_Reference (Index_Value .. Clean_Reference'Last));
               if Index_Value > Clean_Reference'First then
                  Path_Text := To_Unbounded_String
                    (Clean_Reference (Clean_Reference'First .. Index_Value - 1));
               end if;
               exit;
            end if;
         end loop;

         if Length (Query_Text) = 0 then
            Path_Text := To_Unbounded_String (Clean_Reference);
         end if;

         return Prefix_Text
           & Normalize_Path (Directory_Of (Base_Absolute) & To_String (Path_Text))
           & To_String (Query_Text);
      end if;
   end Resolve_URL;

   function Canonical_URL (URL : String) return String is
      Clean_URL : constant String := Strip_Fragment (Ensure_HTTP_Scheme (URL));
      Parsed    : Http_Client.URI.URI_Reference;
      Start_At  : constant Natural := Authority_Start (Clean_URL);
      Path_Text : Unbounded_String := Null_Unbounded_String;
      Query_Text : Unbounded_String := Null_Unbounded_String;
   begin
      if Parse_Absolute_HTTP_URL (Clean_URL, Parsed) then
         declare
            Raw_Path : constant String := Http_Client.URI.Path (Parsed);
         begin
            if Raw_Path = "" then
               Path_Text := To_Unbounded_String ("/");
            else
               Path_Text := To_Unbounded_String (Normalize_Path (Raw_Path));
            end if;

            if Http_Client.URI.Has_Query (Parsed) then
               Query_Text := To_Unbounded_String ("?" & Http_Client.URI.Query (Parsed));
            end if;

            return Http_Client.URI.Scheme (Parsed) & "://"
              & Http_Client.URI.Host_Header_Value (Parsed)
              & To_String (Path_Text)
              & To_String (Query_Text);
         end;
      elsif Start_At = 0 then
         return Clean_URL;
      end if;

      for Index_Value in Start_At .. Clean_URL'Last loop
         if Clean_URL (Index_Value) = '?' then
            Query_Text := To_Unbounded_String (Clean_URL (Index_Value .. Clean_URL'Last));
            return Origin_Of (Clean_URL) & "/" & To_String (Query_Text);
         elsif Clean_URL (Index_Value) = '/' then
            return Origin_Of (Clean_URL)
              & Normalize_Path (Without_Query_Or_Fragment (Clean_URL (Index_Value .. Clean_URL'Last)))
              & Query_Only (Clean_URL);
         end if;
      end loop;

      return Origin_Of (Clean_URL) & "/";
   end Canonical_URL;

   function Safe_Character (Item : Character) return Character is
   begin
      if Item in 'a' .. 'z' or else Item in 'A' .. 'Z' or else Item in '0' .. '9'
        or else Item = '.' or else Item = '_' or else Item = '-'
      then
         return Item;
      else
         return '_';
      end if;
   end Safe_Character;

   function Is_Windows_Device_Name (Segment_Text : String) return Boolean is
      Lower_Text : constant String := To_Lower (Segment_Text);
      Base_Text  : Unbounded_String := Null_Unbounded_String;
   begin
      for Item of Lower_Text loop
         exit when Item = '.';
         Append (Base_Text, Item);
      end loop;

      declare
         Base : constant String := To_String (Base_Text);
      begin
         if Base in "con" | "prn" | "aux" | "nul" then
            return True;
         elsif Base'Length = 4 and then (Base (Base'First .. Base'First + 2) = "com"
           or else Base (Base'First .. Base'First + 2) = "lpt")
         then
            return Base (Base'Last) in '1' .. '9';
         else
            return False;
         end if;
      end;
   end Is_Windows_Device_Name;

   function Has_Uppercase (Segment_Text : String) return Boolean is
   begin
      for Item of Segment_Text loop
         if Item in 'A' .. 'Z' then
            return True;
         end if;
      end loop;

      return False;
   end Has_Uppercase;

   function Hex_Digit (Value : Natural) return Character is
   begin
      if Value < 10 then
         return Character'Val (Character'Pos ('0') + Value);
      else
         return Character'Val (Character'Pos ('a') + Value - 10);
      end if;
   end Hex_Digit;

   function Collision_Suffix (Segment_Text : String) return String is
      Hash   : Natural := 0;
      Result : String (1 .. 4);
   begin
      for Item of Segment_Text loop
         Hash := (Hash * 33 + Character'Pos (Item)) mod 65_536;
      end loop;

      Result (1) := Hex_Digit (Hash / 4_096);
      Result (2) := Hex_Digit ((Hash / 256) mod 16);
      Result (3) := Hex_Digit ((Hash / 16) mod 16);
      Result (4) := Hex_Digit (Hash mod 16);
      return Result;
   end Collision_Suffix;

   function With_Collision_Suffix (Base_Text : String; Segment_Text : String) return String is
   begin
      return Base_Text & "__" & Collision_Suffix (Segment_Text);
   end With_Collision_Suffix;

   function With_Query_Suffix (Path_Text : String; Query_Text : String) return String is
      Suffix      : constant String := "__q" & Collision_Suffix (Query_Text);
      Slash_After : Natural := Path_Text'First;
      Dot_Index   : Natural := 0;
   begin
      if Query_Text = "" then
         return Path_Text;
      end if;

      for Index_Value in reverse Path_Text'Range loop
         if Path_Text (Index_Value) = '/' then
            Slash_After := Index_Value + 1;
            exit;
         end if;
      end loop;

      for Index_Value in reverse Slash_After .. Path_Text'Last loop
         if Path_Text (Index_Value) = '.' then
            Dot_Index := Index_Value;
            exit;
         end if;
      end loop;

      if Dot_Index > Slash_After and then Dot_Index < Path_Text'Last then
         return Path_Text (Path_Text'First .. Dot_Index - 1) & Suffix
           & Path_Text (Dot_Index .. Path_Text'Last);
      else
         return Path_Text & Suffix;
      end if;
   end With_Query_Suffix;

   function Sanitize_Segment (Segment_Text : String) return String is
      Result : Unbounded_String := Null_Unbounded_String;
   begin
      if Segment_Text = "" then
         return "";
      elsif Segment_Text = "." or else Segment_Text = ".." then
         return With_Collision_Suffix ("_", Segment_Text);
      end if;

      for Item of Segment_Text loop
         Append (Result, Safe_Character (Item));
      end loop;

      declare
         Before_Trim    : constant String := To_String (Result);
         Is_Device_Name : constant Boolean := Is_Windows_Device_Name (Before_Trim);
      begin
         while Length (Result) > 0
           and then (Element (Result, Length (Result)) = '.' or else Element (Result, Length (Result)) = ' ')
         loop
            Replace_Element (Result, Length (Result), '_');
         end loop;

         declare
            Safe_Text : constant String := (if Is_Device_Name then "_" & To_String (Result)
                                           else To_String (Result));
         begin
            if Safe_Text = "" then
               return With_Collision_Suffix ("_", Segment_Text);
            elsif Safe_Text /= Segment_Text or else Has_Uppercase (Segment_Text) or else Is_Device_Name then
               return With_Collision_Suffix (Safe_Text, Segment_Text);
            else
               return Safe_Text;
            end if;
         end;
      end;
   end Sanitize_Segment;

   function Compute_Local_Path_For_URL (URL : String) return String is
      Normal_URL : constant String := Ensure_HTTP_Scheme (URL);
      Raw_Path   : constant String := Path_Only (Normal_URL);
      Clean      : constant String := Without_Query_Or_Fragment (Raw_Path);
      Query      : constant String := Query_Only (Normal_URL);
      Result   : Unbounded_String := Null_Unbounded_String;
      Segment  : Unbounded_String := Null_Unbounded_String;

      procedure Flush_Segment is
         Text      : constant String := To_String (Segment);
         Safe_Text : constant String := Sanitize_Segment (Text);
      begin
         if Safe_Text /= "" then
            Append (Result, Safe_Text);
         end if;

         Segment := Null_Unbounded_String;
      end Flush_Segment;
   begin
      for Index_Value in Clean'Range loop
         if Clean (Index_Value) = '/' then
            Flush_Segment;
            if Length (Result) > 0 and then Element (Result, Length (Result)) /= '/' then
               Append (Result, "/");
            end if;
         else
            Append (Segment, Clean (Index_Value));
         end if;
      end loop;

      Flush_Segment;

      if Length (Result) = 0 or else Clean (Clean'Last) = '/' then
         if Length (Result) > 0 and then Element (Result, Length (Result)) /= '/' then
            Append (Result, "/");
         end if;
         Append (Result, "index.html");
      end if;

      return With_Query_Suffix (To_String (Result), Query);
   end Compute_Local_Path_For_URL;

   function Local_Path_For_URL (URL : String) return String is
      Found       : Boolean;
      Cached_Path : Unbounded_String;
      Computed    : Unbounded_String;
   begin
      Local_Path_Cache.Lookup (URL, Found, Cached_Path);
      if Found then
         return To_String (Cached_Path);
      end if;

      Computed := To_Unbounded_String (Compute_Local_Path_For_URL (URL));
      Local_Path_Cache.Store (URL, To_String (Computed));
      return To_String (Computed);
   end Local_Path_For_URL;

   function Extension_Of (URL : String) return String is
      Path_Text : constant String := Path_Only (Ensure_HTTP_Scheme (URL));
      Clean     : constant String := Without_Query_Or_Fragment (Path_Text);
   begin
      for Index_Value in reverse Clean'Range loop
         if Clean (Index_Value) = '.' then
            if Index_Value < Clean'Last then
               return To_Lower (Clean (Index_Value + 1 .. Clean'Last));
            else
               return "";
            end if;
         elsif Clean (Index_Value) = '/' then
            return "";
         end if;
      end loop;

      return "";
   end Extension_Of;

end Sitefetch.URLs;
