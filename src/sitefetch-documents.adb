with Ada.Characters.Handling;
with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Containers.Indefinite_Hashed_Sets;
with Ada.Strings.Fixed;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded;

with Regexp;

with Sitefetch.URLs;

package body Sitefetch.Documents is
   use Ada.Strings.Unbounded;
   use Sitefetch.URLs;
   use type Regexp.Compile_Status;
   use type Regexp.Match_Status;

   package URL_Sets is new Ada.Containers.Indefinite_Hashed_Sets
     (Element_Type        => String,
      Hash                => Ada.Strings.Hash,
      Equivalent_Elements => "=");

   package URL_Path_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => String,
      Element_Type    => String,
      Hash            => Ada.Strings.Hash,
      Equivalent_Keys => "=");

   function Earlier_Link_Match (Left : Link_Match; Right : Link_Match) return Boolean is
     (Left.Position < Right.Position
      or else (Left.Position = Right.Position and then Left.Value_First < Right.Value_First));

   package Link_Match_Sorting is new Link_Match_Vectors.Generic_Sorting
     ("<" => Earlier_Link_Match);

   Href_Double_Regexp : constant Regexp.Compile_Result :=
     Regexp.Compile ("\shref\s*=\s*""[^""<]*""");
   Href_Single_Regexp : constant Regexp.Compile_Result :=
     Regexp.Compile ("\shref\s*=\s*'[^'<]*'");
   Src_Double_Regexp : constant Regexp.Compile_Result :=
     Regexp.Compile ("\ssrc\s*=\s*""[^""<]*""");
   Src_Single_Regexp : constant Regexp.Compile_Result :=
     Regexp.Compile ("\ssrc\s*=\s*'[^'<]*'");
   Srcset_Double_Regexp : constant Regexp.Compile_Result :=
     Regexp.Compile ("\ssrcset\s*=\s*""[^""<]*""");
   Srcset_Single_Regexp : constant Regexp.Compile_Result :=
     Regexp.Compile ("\ssrcset\s*=\s*'[^'<]*'");


   function Hex_Value (Item : Character) return Natural is
   begin
      if Item in '0' .. '9' then
         return Character'Pos (Item) - Character'Pos ('0');
      elsif Item in 'A' .. 'F' then
         return Character'Pos (Item) - Character'Pos ('A') + 10;
      elsif Item in 'a' .. 'f' then
         return Character'Pos (Item) - Character'Pos ('a') + 10;
      else
         return 16;
      end if;
   end Hex_Value;

   procedure Append_UTF8 (Target : in out Unbounded_String; Code_Point : Natural) is
   begin
      if Code_Point <= 16#7F# then
         Append (Target, Character'Val (Code_Point));
      elsif Code_Point <= 16#7FF# then
         Append (Target, Character'Val (16#C0# + Code_Point / 64));
         Append (Target, Character'Val (16#80# + Code_Point mod 64));
      elsif Code_Point <= 16#FFFF# then
         Append (Target, Character'Val (16#E0# + Code_Point / 4_096));
         Append (Target, Character'Val (16#80# + (Code_Point / 64) mod 64));
         Append (Target, Character'Val (16#80# + Code_Point mod 64));
      else
         Append (Target, Character'Val (16#F0# + Code_Point / 262_144));
         Append (Target, Character'Val (16#80# + (Code_Point / 4_096) mod 64));
         Append (Target, Character'Val (16#80# + (Code_Point / 64) mod 64));
         Append (Target, Character'Val (16#80# + Code_Point mod 64));
      end if;
   end Append_UTF8;

   function Entity_Code_Point (Entity : String; Value : out Natural) return Boolean is
      Start_Index : Positive;
      Base        : Natural := 10;
      Name        : constant String := To_Lower (Entity);
   begin
      Value := 0;

      if Name = "amp" then
         Value := Character'Pos ('&');
         return True;
      elsif Name = "lt" then
         Value := Character'Pos ('<');
         return True;
      elsif Name = "gt" then
         Value := Character'Pos ('>');
         return True;
      elsif Name = "quot" then
         Value := Character'Pos ('"');
         return True;
      elsif Name = "apos" then
         Value := Character'Pos (Character'Val (39));
         return True;
      elsif Entity'Length < 2 or else Entity (Entity'First) /= '#' then
         return False;
      end if;

      Start_Index := Entity'First + 1;
      if Start_Index <= Entity'Last and then Entity (Start_Index) in 'x' | 'X' then
         Base := 16;
         Start_Index := Start_Index + 1;
      end if;

      if Start_Index > Entity'Last then
         return False;
      end if;

      for Index_Value in Start_Index .. Entity'Last loop
         declare
            Digit : constant Natural := Hex_Value (Entity (Index_Value));
         begin
            if Digit >= Base then
               return False;
            elsif Value > (16#10FFFF# - Digit) / Base then
               return False;
            end if;

            Value := Value * Base + Digit;
         end;
      end loop;

      return Value <= 16#10FFFF# and then not (Value in 16#D800# .. 16#DFFF#);
   end Entity_Code_Point;

   function Decode_HTML_Entities (Text : String) return String is
      Result      : Unbounded_String := Null_Unbounded_String;
      Index_Value : Natural := Text'First;
      Code_Point  : Natural;
   begin
      while Index_Value <= Text'Last loop
         if Text (Index_Value) = '&' then
            declare
               Semi : Natural := 0;
            begin
               for Candidate in Index_Value + 1 .. Natural'Min (Text'Last, Index_Value + 32) loop
                  if Text (Candidate) = ';' then
                     Semi := Candidate;
                     exit;
                  elsif Text (Candidate) = '&' then
                     exit;
                  end if;
               end loop;

               if Semi /= 0
                 and then Entity_Code_Point (Text (Index_Value + 1 .. Semi - 1), Code_Point)
               then
                  Append_UTF8 (Result, Code_Point);
                  Index_Value := Semi + 1;
               else
                  Append (Result, Text (Index_Value));
                  Index_Value := Index_Value + 1;
               end if;
            end;
         else
            Append (Result, Text (Index_Value));
            Index_Value := Index_Value + 1;
         end if;
      end loop;

      return To_String (Result);
   end Decode_HTML_Entities;

   procedure Insert_Match
     (Matches     : in out Link_Match_Vectors.Vector;
      Position    : Natural;
      Value_First : Natural;
      Value_Last  : Natural;
      Reference   : String)
   is
      Decoded_Reference : constant String := Decode_HTML_Entities (Reference);
      Item              : constant Link_Match :=
        (Position    => Position,
         Value_First => Value_First,
         Value_Last  => Value_Last,
         Reference   => To_Unbounded_String (Decoded_Reference));
   begin
      if Decoded_Reference = "" then
         return;
      end if;

      Matches.Append (Item);
   end Insert_Match;

   procedure Extract_With_Pattern
     (Document_Text : String;
      Compiled      : Regexp.Compile_Result;
      Matches       : in out Link_Match_Vectors.Vector)
   is
      Options  : constant Regexp.Match_Options := (Case_Sensitive => False, others => <>);
      Found    : Regexp.Match_Result;
      From     : Positive := 1;
   begin
      if Compiled.Status /= Regexp.Compile_Ok then
         return;
      end if;

      while From <= Document_Text'Length loop
         Found := Regexp.Find_From (Compiled.Expression, Document_Text, From, Options);
         exit when Found.Status /= Regexp.Match_Ok;

         declare
            Match_Text : constant String := Document_Text
              (Document_Text'First + Found.First - 1 .. Document_Text'First + Found.Last - 1);
            Quote      : Character := Character'Val (0);
            Start_At   : Natural := 0;
         begin
            for Index_Value in Match_Text'Range loop
               if Match_Text (Index_Value) = '"'
                 or else Match_Text (Index_Value) = Character'Val (39)
               then
                  Quote := Match_Text (Index_Value);
                  Start_At := Index_Value + 1;
                  exit;
               end if;
            end loop;

            if Start_At /= 0 then
               for Index_Value in Start_At .. Match_Text'Last loop
                  if Match_Text (Index_Value) = Quote then
                     if Index_Value > Start_At then
                        Insert_Match
                          (Matches,
                           Found.First,
                           Start_At - Document_Text'First + 1,
                           Index_Value - Document_Text'First,
                           Match_Text (Start_At .. Index_Value - 1));
                     end if;
                     exit;
                  end if;
               end loop;
            end if;
         end;

         From := Found.Last + 1;
      end loop;
   end Extract_With_Pattern;

   procedure Extract_Srcset_With_Pattern
     (Document_Text : String;
      Compiled      : Regexp.Compile_Result;
      Matches       : in out Link_Match_Vectors.Vector)
   is
      Options  : constant Regexp.Match_Options := (Case_Sensitive => False, others => <>);
      Found    : Regexp.Match_Result;
      From     : Positive := 1;
   begin
      if Compiled.Status /= Regexp.Compile_Ok then
         return;
      end if;

      while From <= Document_Text'Length loop
         Found := Regexp.Find_From (Compiled.Expression, Document_Text, From, Options);
         exit when Found.Status /= Regexp.Match_Ok;

         declare
            Match_Text : constant String := Document_Text
              (Document_Text'First + Found.First - 1 .. Document_Text'First + Found.Last - 1);
            Quote      : Character := Character'Val (0);
            Value_First : Natural := 0;
            Value_Last  : Natural := 0;
            Index_Value : Natural;
         begin
            for Scan in Match_Text'Range loop
               if Match_Text (Scan) = '"' or else Match_Text (Scan) = Character'Val (39) then
                  Quote := Match_Text (Scan);
                  Value_First := Scan + 1;
                  exit;
               end if;
            end loop;

            if Value_First /= 0 then
               for Scan in Value_First .. Match_Text'Last loop
                  if Match_Text (Scan) = Quote then
                     Value_Last := Scan - 1;
                     exit;
                  end if;
               end loop;
            end if;

            if Value_First /= 0 and then Value_Last >= Value_First then
               Index_Value := Value_First;
               while Index_Value <= Value_Last loop
                  while Index_Value <= Value_Last
                    and then (Match_Text (Index_Value) = ' '
                              or else Match_Text (Index_Value) = Character'Val (9)
                              or else Match_Text (Index_Value) = Character'Val (10)
                              or else Match_Text (Index_Value) = Character'Val (13)
                              or else Match_Text (Index_Value) = ',')
                  loop
                     Index_Value := Index_Value + 1;
                  end loop;

                  exit when Index_Value > Value_Last;

                  declare
                     URL_First : constant Natural := Index_Value;
                     URL_Last  : Natural := Index_Value;
                  begin
                     while URL_Last <= Value_Last
                       and then Match_Text (URL_Last) /= ' '
                       and then Match_Text (URL_Last) /= Character'Val (9)
                       and then Match_Text (URL_Last) /= Character'Val (10)
                       and then Match_Text (URL_Last) /= Character'Val (13)
                       and then Match_Text (URL_Last) /= ','
                     loop
                        URL_Last := URL_Last + 1;
                     end loop;

                     Insert_Match
                       (Matches,
                        Found.First,
                        URL_First - Document_Text'First + 1,
                        URL_Last - Document_Text'First,
                        Match_Text (URL_First .. URL_Last - 1));

                     Index_Value := URL_Last;
                     while Index_Value <= Value_Last and then Match_Text (Index_Value) /= ',' loop
                        Index_Value := Index_Value + 1;
                     end loop;
                  end;
               end loop;
            end if;
         end;

         From := Found.Last + 1;
      end loop;
   end Extract_Srcset_With_Pattern;


   function Is_ASCII_Whitespace (Item : Character) return Boolean is
     (Item = ' ' or else Item = Character'Val (9)
      or else Item = Character'Val (10) or else Item = Character'Val (13)
      or else Item = Character'Val (12));

   function Lower_Equals_At
     (Text     : String;
      Position : Natural;
      Token    : String) return Boolean
   is
   begin
      if Position < Text'First or else Position + Token'Length - 1 > Text'Last then
         return False;
      end if;

      for Offset in Natural range 0 .. Token'Length - 1 loop
         if Ada.Characters.Handling.To_Lower (Text (Position + Offset))
           /= Ada.Characters.Handling.To_Lower (Token (Token'First + Offset))
         then
            return False;
         end if;
      end loop;

      return True;
   end Lower_Equals_At;

   function Is_Hex_Digit (Item : Character) return Boolean is
     (Item in '0' .. '9' or else Item in 'A' .. 'F' or else Item in 'a' .. 'f');

   function Is_CSS_Name_Character (Item : Character) return Boolean is
     (Item in 'A' .. 'Z' or else Item in 'a' .. 'z' or else Item in '0' .. '9'
      or else Item = '_' or else Item = '-');

   function CSS_Unescape (Text : String) return String is
      Result      : Unbounded_String := Null_Unbounded_String;
      Index_Value : Natural := Text'First;
   begin
      while Index_Value <= Text'Last loop
         if Text (Index_Value) = '\' then
            if Index_Value = Text'Last then
               Index_Value := Index_Value + 1;
            elsif Text (Index_Value + 1) = Character'Val (10)
              or else Text (Index_Value + 1) = Character'Val (12)
              or else Text (Index_Value + 1) = Character'Val (13)
            then
               Index_Value := Index_Value + 2;
               if Index_Value <= Text'Last
                 and then Text (Index_Value - 1) = Character'Val (13)
                 and then Text (Index_Value) = Character'Val (10)
               then
                  Index_Value := Index_Value + 1;
               end if;
            elsif Is_Hex_Digit (Text (Index_Value + 1)) then
               declare
                  Cursor     : Natural := Index_Value + 1;
                  Code_Point : Natural := 0;
                  Count      : Natural := 0;
               begin
                  while Cursor <= Text'Last
                    and then Count < 6
                    and then Is_Hex_Digit (Text (Cursor))
                  loop
                     Code_Point := Code_Point * 16 + Hex_Value (Text (Cursor));
                     Cursor := Cursor + 1;
                     Count := Count + 1;
                  end loop;

                  if Code_Point <= 16#10FFFF# and then not (Code_Point in 16#D800# .. 16#DFFF#) then
                     Append_UTF8 (Result, Code_Point);
                  end if;

                  if Cursor <= Text'Last and then Is_ASCII_Whitespace (Text (Cursor)) then
                     Cursor := Cursor + 1;
                  end if;

                  Index_Value := Cursor;
               end;
            else
               Append (Result, Text (Index_Value + 1));
               Index_Value := Index_Value + 2;
            end if;
         else
            Append (Result, Text (Index_Value));
            Index_Value := Index_Value + 1;
         end if;
      end loop;

      return To_String (Result);
   end CSS_Unescape;

   function Starts_With_Case_Insensitive_Text (Text : String; Prefix : String) return Boolean is
   begin
      if Text'Length < Prefix'Length then
         return False;
      end if;

      for Offset in Natural range 0 .. Prefix'Length - 1 loop
         if Ada.Characters.Handling.To_Lower (Text (Text'First + Offset))
           /= Ada.Characters.Handling.To_Lower (Prefix (Prefix'First + Offset))
         then
            return False;
         end if;
      end loop;

      return True;
   end Starts_With_Case_Insensitive_Text;

   function Is_CSS_Data_URL (Reference : String) return Boolean is
      Decoded : constant String := Ada.Strings.Fixed.Trim (CSS_Unescape (Reference), Ada.Strings.Both);
   begin
      return Starts_With_Case_Insensitive_Text (Decoded, "data:");
   end Is_CSS_Data_URL;

   function Is_CSS_Fragment_URL (Reference : String) return Boolean is
      Decoded : constant String := Ada.Strings.Fixed.Trim (CSS_Unescape (Reference), Ada.Strings.Both);
   begin
      return Decoded'Length > 0 and then Decoded (Decoded'First) = '#';
   end Is_CSS_Fragment_URL;

   function CSS_Token_Boundary_Before (Document_Text : String; Position : Natural) return Boolean is
   begin
      return Position <= Document_Text'First
        or else not Is_CSS_Name_Character (Document_Text (Position - 1));
   end CSS_Token_Boundary_Before;

   function CSS_Identifier_Token_At
     (Document_Text : String;
      Position      : Natural;
      Identifier    : String;
      After         : out Natural) return Boolean;

   procedure Insert_CSS_Match
     (Matches     : in out Link_Match_Vectors.Vector;
      Position    : Natural;
      Value_First : Natural;
      Value_Last  : Natural;
      Reference   : String)
   is
      Trimmed_First : Natural := Reference'First;
      Trimmed_Last  : Natural := Reference'Last;
   begin
      while Trimmed_First <= Trimmed_Last and then Is_ASCII_Whitespace (Reference (Trimmed_First)) loop
         Trimmed_First := Trimmed_First + 1;
      end loop;
      while Trimmed_Last >= Trimmed_First and then Is_ASCII_Whitespace (Reference (Trimmed_Last)) loop
         Trimmed_Last := Trimmed_Last - 1;
      end loop;

      if Trimmed_Last < Trimmed_First
        or else Is_CSS_Data_URL (Reference (Trimmed_First .. Trimmed_Last))
        or else Is_CSS_Fragment_URL (Reference (Trimmed_First .. Trimmed_Last))
      then
         return;
      end if;

      Insert_Match
        (Matches,
         Position,
         Value_First + Trimmed_First - Reference'First,
         Value_Last - (Reference'Last - Trimmed_Last),
         CSS_Unescape (Reference (Trimmed_First .. Trimmed_Last)));
   end Insert_CSS_Match;

   procedure Skip_CSS_Escape (Document_Text : String; Cursor : in out Natural) is
   begin
      if Cursor >= Document_Text'Last then
         Cursor := Document_Text'Last + 1;
      elsif Document_Text (Cursor + 1) = Character'Val (13)
        and then Cursor + 2 <= Document_Text'Last
        and then Document_Text (Cursor + 2) = Character'Val (10)
      then
         Cursor := Cursor + 3;
      else
         Cursor := Cursor + 2;
      end if;
   end Skip_CSS_Escape;

   procedure Skip_CSS_Comment (Document_Text : String; Cursor : in out Natural) is
   begin
      Cursor := Cursor + 2;
      while Cursor < Document_Text'Last loop
         if Document_Text (Cursor) = '*' and then Document_Text (Cursor + 1) = '/' then
            Cursor := Cursor + 2;
            return;
         end if;
         Cursor := Cursor + 1;
      end loop;
      Cursor := Document_Text'Last + 1;
   end Skip_CSS_Comment;

   procedure Skip_CSS_String (Document_Text : String; Cursor : in out Natural) is
      Quote : constant Character := Document_Text (Cursor);
   begin
      Cursor := Cursor + 1;
      while Cursor <= Document_Text'Last loop
         if Document_Text (Cursor) = '\' then
            Skip_CSS_Escape (Document_Text, Cursor);
         elsif Document_Text (Cursor) = Quote then
            Cursor := Cursor + 1;
            return;
         else
            Cursor := Cursor + 1;
         end if;
      end loop;
   end Skip_CSS_String;

   procedure Skip_CSS_Space_And_Comments (Document_Text : String; Cursor : in out Natural) is
   begin
      loop
         while Cursor <= Document_Text'Last and then Is_ASCII_Whitespace (Document_Text (Cursor)) loop
            Cursor := Cursor + 1;
         end loop;

         exit when Cursor >= Document_Text'Last
           or else Document_Text (Cursor) /= '/'
           or else Document_Text (Cursor + 1) /= '*';

         Skip_CSS_Comment (Document_Text, Cursor);
      end loop;
   end Skip_CSS_Space_And_Comments;

   function CSS_Identifier_At
     (Document_Text : String;
      Position      : Natural;
      Identifier    : String;
      After         : out Natural) return Boolean
   is
      Cursor : Natural := Position;
      Decoded : Unbounded_String := Null_Unbounded_String;
   begin
      After := Position;
      if Position < Document_Text'First or else Position > Document_Text'Last then
         return False;
      end if;

      while Cursor <= Document_Text'Last loop
         if Is_CSS_Name_Character (Document_Text (Cursor)) then
            Append (Decoded, Ada.Characters.Handling.To_Lower (Document_Text (Cursor)));
            Cursor := Cursor + 1;
         elsif Document_Text (Cursor) = '\' and then Cursor < Document_Text'Last then
            declare
               Escape_First : constant Natural := Cursor;
            begin
               Cursor := Cursor + 1;
               if Is_Hex_Digit (Document_Text (Cursor)) then
                  declare
                     Count : Natural := 0;
                  begin
                     while Cursor <= Document_Text'Last
                       and then Count < 6
                       and then Is_Hex_Digit (Document_Text (Cursor))
                     loop
                        Cursor := Cursor + 1;
                        Count := Count + 1;
                     end loop;
                     if Cursor <= Document_Text'Last and then Is_ASCII_Whitespace (Document_Text (Cursor)) then
                        Cursor := Cursor + 1;
                     end if;
                  end;
               else
                  Cursor := Cursor + 1;
               end if;
               Append
                 (Decoded,
                  Ada.Characters.Handling.To_Lower
                    (CSS_Unescape (Document_Text (Escape_First .. Cursor - 1))));
            end;
         else
            exit;
         end if;
      end loop;

      if To_String (Decoded) /= Identifier then
         return False;
      end if;

      After := Cursor;
      return True;
   end CSS_Identifier_At;

   function CSS_Identifier_Token_At
     (Document_Text : String;
      Position      : Natural;
      Identifier    : String;
      After         : out Natural) return Boolean
   is
   begin
      return CSS_Token_Boundary_Before (Document_Text, Position)
        and then CSS_Identifier_At (Document_Text, Position, Identifier, After);
   end CSS_Identifier_Token_At;

   procedure Extract_CSS_String
     (Document_Text : String;
      At_Position   : Natural;
      Cursor_In_Out : in out Natural;
      Matches       : in out Link_Match_Vectors.Vector)
   is
      Quote     : constant Character := Document_Text (Cursor_In_Out);
      URL_First : constant Natural := Cursor_In_Out + 1;
      URL_Last  : Natural := 0;
      Cursor    : Natural := URL_First;
   begin
      while Cursor <= Document_Text'Last loop
         if Document_Text (Cursor) = '\' then
            Skip_CSS_Escape (Document_Text, Cursor);
         elsif Document_Text (Cursor) = Quote then
            URL_Last := Cursor - 1;
            Cursor := Cursor + 1;
            exit;
         else
            Cursor := Cursor + 1;
         end if;
      end loop;

      if URL_Last >= URL_First then
         Insert_CSS_Match
           (Matches,
            At_Position - Document_Text'First + 1,
            URL_First - Document_Text'First + 1,
            URL_Last - Document_Text'First + 1,
            Document_Text (URL_First .. URL_Last));
      end if;

      Cursor_In_Out := Cursor;
   end Extract_CSS_String;

   procedure Skip_CSS_Balanced_Function (Document_Text : String; Cursor : in out Natural) is
      Depth : Natural := 0;
   begin
      while Cursor <= Document_Text'Last loop
         if Cursor < Document_Text'Last
           and then Document_Text (Cursor) = '/'
           and then Document_Text (Cursor + 1) = '*'
         then
            Skip_CSS_Comment (Document_Text, Cursor);
         elsif Document_Text (Cursor) = '"' or else Document_Text (Cursor) = Character'Val (39) then
            Skip_CSS_String (Document_Text, Cursor);
         elsif Document_Text (Cursor) = '(' then
            Depth := Depth + 1;
            Cursor := Cursor + 1;
         elsif Document_Text (Cursor) = ')' then
            Cursor := Cursor + 1;
            exit when Depth = 0;
            Depth := Depth - 1;
            exit when Depth = 0;
         else
            Cursor := Cursor + 1;
         end if;
      end loop;
   end Skip_CSS_Balanced_Function;

   function Skip_CSS_Custom_Property_Declaration
     (Document_Text : String;
      Cursor        : in out Natural) return Boolean
   is
      Probe : Natural := Cursor;
   begin
      if Probe + 1 > Document_Text'Last
        or else Document_Text (Probe) /= '-'
        or else Document_Text (Probe + 1) /= '-'
        or else not CSS_Token_Boundary_Before (Document_Text, Probe)
      then
         return False;
      end if;

      Probe := Probe + 2;
      while Probe <= Document_Text'Last and then Is_CSS_Name_Character (Document_Text (Probe)) loop
         Probe := Probe + 1;
      end loop;
      while Probe <= Document_Text'Last and then Is_ASCII_Whitespace (Document_Text (Probe)) loop
         Probe := Probe + 1;
      end loop;

      if Probe > Document_Text'Last or else Document_Text (Probe) /= ':' then
         return False;
      end if;

      Cursor := Probe + 1;
      while Cursor <= Document_Text'Last loop
         if Cursor < Document_Text'Last
           and then Document_Text (Cursor) = '/'
           and then Document_Text (Cursor + 1) = '*'
         then
            Skip_CSS_Comment (Document_Text, Cursor);
         elsif Document_Text (Cursor) = '"' or else Document_Text (Cursor) = Character'Val (39) then
            Skip_CSS_String (Document_Text, Cursor);
         elsif Document_Text (Cursor) = '(' then
            Skip_CSS_Balanced_Function (Document_Text, Cursor);
         elsif Document_Text (Cursor) = ';' then
            Cursor := Cursor + 1;
            return True;
         elsif Document_Text (Cursor) = '}' then
            Cursor := Cursor + 1;
            return True;
         else
            Cursor := Cursor + 1;
         end if;
      end loop;

      return True;
   end Skip_CSS_Custom_Property_Declaration;

   procedure Extract_CSS_URL_Function
     (Document_Text  : String;
      Function_Start : Natural;
      Cursor_In_Out  : in out Natural;
      Matches        : in out Link_Match_Vectors.Vector)
   is
      Cursor : Natural;
      After  : Natural := Function_Start;
   begin
      if not CSS_Identifier_Token_At (Document_Text, Function_Start, "url", After) then
         Cursor_In_Out := Function_Start + 1;
         return;
      end if;

      Cursor := After;
      Skip_CSS_Space_And_Comments (Document_Text, Cursor);
      if Cursor > Document_Text'Last or else Document_Text (Cursor) /= '(' then
         Cursor_In_Out := Function_Start + 1;
         return;
      end if;

      Cursor := Cursor + 1;
      Skip_CSS_Space_And_Comments (Document_Text, Cursor);

      declare
         Quote          : Character := Character'Val (0);
         URL_First      : Natural := Cursor;
         URL_Last       : Natural := 0;
         Depth          : Natural := 0;
         Raw_Has_Nested : Boolean := False;
      begin
         if Cursor <= Document_Text'Last
           and then (Document_Text (Cursor) = '"' or else Document_Text (Cursor) = Character'Val (39))
         then
            Quote := Document_Text (Cursor);
            URL_First := Cursor + 1;
            Cursor := URL_First;
            while Cursor <= Document_Text'Last loop
               if Document_Text (Cursor) = '\' then
                  Cursor := Natural'Min (Document_Text'Last + 1, Cursor + 2);
               elsif Document_Text (Cursor) = Quote then
                  URL_Last := Cursor - 1;
                  Cursor := Cursor + 1;
                  exit;
               else
                  Cursor := Cursor + 1;
               end if;
            end loop;
         else
            while Cursor <= Document_Text'Last loop
               if Cursor < Document_Text'Last
                 and then Document_Text (Cursor) = '/'
                 and then Document_Text (Cursor + 1) = '*'
               then
                  exit;
               elsif Document_Text (Cursor) = '\' then
                  Cursor := Natural'Min (Document_Text'Last + 1, Cursor + 2);
               elsif Document_Text (Cursor) = '(' then
                  Raw_Has_Nested := True;
                  Depth := Depth + 1;
                  Cursor := Cursor + 1;
               elsif Document_Text (Cursor) = ')' then
                  if Depth = 0 then
                     URL_Last := Cursor - 1;
                     exit;
                  else
                     Depth := Depth - 1;
                     Cursor := Cursor + 1;
                  end if;
               else
                  Cursor := Cursor + 1;
               end if;
            end loop;
         end if;

         if URL_Last >= URL_First and then not Raw_Has_Nested then
            Insert_CSS_Match
              (Matches,
               Function_Start - Document_Text'First + 1,
               URL_First - Document_Text'First + 1,
               URL_Last - Document_Text'First + 1,
               Document_Text (URL_First .. URL_Last));
         end if;
      end;

      Skip_CSS_Space_And_Comments (Document_Text, Cursor);
      if Cursor <= Document_Text'Last and then Document_Text (Cursor) = ')' then
         Cursor := Cursor + 1;
      end if;
      Cursor_In_Out := Cursor;
   end Extract_CSS_URL_Function;

   procedure Extract_CSS_Import
     (Document_Text : String;
      Import_Start  : Natural;
      Cursor_In_Out : in out Natural;
      Matches       : in out Link_Match_Vectors.Vector)
   is
      Cursor : Natural;
      After  : Natural := Import_Start + 1;
      Found  : Boolean := False;
   begin
      if not CSS_Identifier_Token_At (Document_Text, Import_Start + 1, "import", After) then
         Cursor_In_Out := Import_Start + 1;
         return;
      end if;

      Cursor := After;
      while Cursor <= Document_Text'Last loop
         Skip_CSS_Space_And_Comments (Document_Text, Cursor);
         exit when Cursor > Document_Text'Last
           or else Document_Text (Cursor) = ';'
           or else Document_Text (Cursor) = '{';

         if Document_Text (Cursor) = '"' or else Document_Text (Cursor) = Character'Val (39) then
            if not Found then
               Extract_CSS_String (Document_Text, Import_Start, Cursor, Matches);
               Found := True;
            else
               Skip_CSS_String (Document_Text, Cursor);
            end if;
         else
            declare
               Identifier_After : Natural := Cursor;
            begin
               if CSS_Identifier_Token_At (Document_Text, Cursor, "url", Identifier_After) then
                  if not Found then
                     Extract_CSS_URL_Function (Document_Text, Cursor, Cursor, Matches);
                     Found := True;
                  else
                     Cursor := Identifier_After;
                     Skip_CSS_Space_And_Comments (Document_Text, Cursor);
                     if Cursor <= Document_Text'Last and then Document_Text (Cursor) = '(' then
                        Skip_CSS_Balanced_Function (Document_Text, Cursor);
                     end if;
                  end if;
               elsif Identifier_After > Cursor then
                  Cursor := Identifier_After;
                  Skip_CSS_Space_And_Comments (Document_Text, Cursor);
                  if Cursor <= Document_Text'Last and then Document_Text (Cursor) = '(' then
                     Skip_CSS_Balanced_Function (Document_Text, Cursor);
                  end if;
               else
                  Cursor := Cursor + 1;
               end if;
            end;
         end if;
      end loop;

      if Cursor <= Document_Text'Last and then Document_Text (Cursor) = ';' then
         Cursor := Cursor + 1;
      end if;
      Cursor_In_Out := Cursor;
   end Extract_CSS_Import;

   procedure Extract_CSS_Matches
     (Document_Text : String;
      Matches       : in out Link_Match_Vectors.Vector)
   is
      Cursor : Natural := Document_Text'First;
      After  : Natural := Document_Text'First;
   begin
      while Cursor <= Document_Text'Last loop
         if Skip_CSS_Custom_Property_Declaration (Document_Text, Cursor) then
            null;
         elsif Cursor < Document_Text'Last
           and then Document_Text (Cursor) = '/'
           and then Document_Text (Cursor + 1) = '*'
         then
            Skip_CSS_Comment (Document_Text, Cursor);
         elsif Document_Text (Cursor) = '"' or else Document_Text (Cursor) = Character'Val (39) then
            Skip_CSS_String (Document_Text, Cursor);
         elsif Document_Text (Cursor) = '@'
           and then CSS_Identifier_Token_At (Document_Text, Cursor + 1, "import", After)
         then
            Extract_CSS_Import (Document_Text, Cursor, Cursor, Matches);
         elsif CSS_Identifier_Token_At (Document_Text, Cursor, "url", After) then
            Extract_CSS_URL_Function (Document_Text, Cursor, Cursor, Matches);
         else
            Cursor := Cursor + 1;
         end if;
      end loop;
   end Extract_CSS_Matches;

   procedure Extract_CSS_URL_Matches
     (Document_Text : String;
      Matches       : in out Link_Match_Vectors.Vector)
   is
   begin
      Extract_CSS_Matches (Document_Text, Matches);
   end Extract_CSS_URL_Matches;

   procedure Extract_CSS_Import_Matches
     (Document_Text : String;
      Matches       : in out Link_Match_Vectors.Vector)
   is
      pragma Unreferenced (Document_Text, Matches);
   begin
      null;
   end Extract_CSS_Import_Matches;

   function XML_Tag_End (Document_Text : String; Tag_Start : Natural) return Natural is
      Cursor : Natural := Tag_Start + 1;
      Quote  : Character := Character'Val (0);
   begin
      while Cursor <= Document_Text'Last loop
         if Quote /= Character'Val (0) then
            if Document_Text (Cursor) = Quote then
               Quote := Character'Val (0);
            end if;
         elsif Document_Text (Cursor) = '"' or else Document_Text (Cursor) = Character'Val (39) then
            Quote := Document_Text (Cursor);
         elsif Document_Text (Cursor) = '>' then
            return Cursor;
         end if;
         Cursor := Cursor + 1;
      end loop;
      return 0;
   end XML_Tag_End;

   function Is_XML_Name_Character (Item : Character) return Boolean is
     (Item in 'A' .. 'Z' or else Item in 'a' .. 'z' or else Item in '0' .. '9'
      or else Item = '_' or else Item = '-' or else Item = '.' or else Item = ':');

   function XML_Local_Name_Is
     (Document_Text : String;
      Name_First    : Natural;
      Name_Last     : Natural;
      Expected      : String) return Boolean
   is
      Local_First : Natural := Name_First;
   begin
      if Name_First = 0 or else Name_Last < Name_First then
         return False;
      end if;

      for Cursor in reverse Name_First .. Name_Last loop
         if Document_Text (Cursor) = ':' then
            Local_First := Cursor + 1;
            exit;
         end if;
      end loop;

      return Local_First <= Name_Last
        and then Name_Last - Local_First + 1 = Expected'Length
        and then Lower_Equals_At (Document_Text, Local_First, Expected);
   end XML_Local_Name_Is;

   procedure XML_Tag_Name_Range
     (Document_Text : String;
      Tag_Start     : Natural;
      Is_Closing    : out Boolean;
      Name_First    : out Natural;
      Name_Last     : out Natural)
   is
      Cursor : Natural := Tag_Start + 1;
   begin
      Is_Closing := False;
      Name_First := 0;
      Name_Last := 0;

      while Cursor <= Document_Text'Last and then Is_ASCII_Whitespace (Document_Text (Cursor)) loop
         Cursor := Cursor + 1;
      end loop;

      if Cursor <= Document_Text'Last and then Document_Text (Cursor) = '/' then
         Is_Closing := True;
         Cursor := Cursor + 1;
      end if;

      while Cursor <= Document_Text'Last and then Is_ASCII_Whitespace (Document_Text (Cursor)) loop
         Cursor := Cursor + 1;
      end loop;

      if Cursor > Document_Text'Last or else not Is_XML_Name_Character (Document_Text (Cursor)) then
         return;
      end if;

      Name_First := Cursor;
      while Cursor <= Document_Text'Last and then Is_XML_Name_Character (Document_Text (Cursor)) loop
         Cursor := Cursor + 1;
      end loop;
      Name_Last := Cursor - 1;
   end XML_Tag_Name_Range;

   function XML_Special_End
     (Document_Text : String;
      Start_Pos     : Natural) return Natural
   is
      Cursor : Natural;
   begin
      if Start_Pos + 3 <= Document_Text'Last
        and then Document_Text (Start_Pos + 1) = '!'
        and then Document_Text (Start_Pos + 2) = '-'
        and then Document_Text (Start_Pos + 3) = '-'
      then
         Cursor := Start_Pos + 4;
         while Cursor + 2 <= Document_Text'Last loop
            if Document_Text (Cursor) = '-'
              and then Document_Text (Cursor + 1) = '-'
              and then Document_Text (Cursor + 2) = '>'
            then
               return Cursor + 2;
            end if;
            Cursor := Cursor + 1;
         end loop;
         return Document_Text'Last;
      elsif Start_Pos + 8 <= Document_Text'Last
        and then Document_Text (Start_Pos + 1) = '!'
        and then Document_Text (Start_Pos + 2) = '['
        and then Lower_Equals_At (Document_Text, Start_Pos + 3, "cdata[")
      then
         Cursor := Start_Pos + 9;
         while Cursor + 2 <= Document_Text'Last loop
            if Document_Text (Cursor) = ']'
              and then Document_Text (Cursor + 1) = ']'
              and then Document_Text (Cursor + 2) = '>'
            then
               return Cursor + 2;
            end if;
            Cursor := Cursor + 1;
         end loop;
         return Document_Text'Last;
      elsif Start_Pos + 1 <= Document_Text'Last and then Document_Text (Start_Pos + 1) = '?' then
         Cursor := Start_Pos + 2;
         while Cursor + 1 <= Document_Text'Last loop
            if Document_Text (Cursor) = '?' and then Document_Text (Cursor + 1) = '>' then
               return Cursor + 1;
            end if;
            Cursor := Cursor + 1;
         end loop;
         return Document_Text'Last;
      elsif Start_Pos + 1 <= Document_Text'Last and then Document_Text (Start_Pos + 1) = '!' then
         declare
            Quote         : Character := Character'Val (0);
            Bracket_Depth : Natural := 0;
         begin
            Cursor := Start_Pos + 2;
            while Cursor <= Document_Text'Last loop
               if Quote /= Character'Val (0) then
                  if Document_Text (Cursor) = Quote then
                     Quote := Character'Val (0);
                  end if;
               elsif Document_Text (Cursor) = '"' or else Document_Text (Cursor) = Character'Val (39) then
                  Quote := Document_Text (Cursor);
               elsif Document_Text (Cursor) = '[' then
                  Bracket_Depth := Bracket_Depth + 1;
               elsif Document_Text (Cursor) = ']' and then Bracket_Depth > 0 then
                  Bracket_Depth := Bracket_Depth - 1;
               elsif Document_Text (Cursor) = '>' and then Bracket_Depth = 0 then
                  return Cursor;
               end if;
               Cursor := Cursor + 1;
            end loop;
            return Document_Text'Last;
         end;
      else
         return 0;
      end if;
   end XML_Special_End;

   function XML_Tag_Is_Self_Closing
     (Document_Text : String;
      Tag_Start     : Natural;
      Tag_End       : Natural) return Boolean
   is
      Cursor : Natural := Tag_End;
   begin
      if Tag_End = 0 or else Tag_End <= Tag_Start then
         return False;
      end if;

      Cursor := Tag_End - 1;
      while Cursor > Tag_Start and then Is_ASCII_Whitespace (Document_Text (Cursor)) loop
         Cursor := Cursor - 1;
      end loop;

      return Cursor > Tag_Start and then Document_Text (Cursor) = '/';
   end XML_Tag_Is_Self_Closing;

   function Is_XML_CDATA_Start (Document_Text : String; Start_Pos : Natural) return Boolean is
   begin
      return Start_Pos + 8 <= Document_Text'Last
        and then Document_Text (Start_Pos) = '<'
        and then Document_Text (Start_Pos + 1) = '!'
        and then Document_Text (Start_Pos + 2) = '['
        and then Lower_Equals_At (Document_Text, Start_Pos + 3, "cdata[");
   end Is_XML_CDATA_Start;

   procedure Append_XML_Entity_Decoded
     (Output : in out Unbounded_String;
      Entity : String)
   is
      Value : Natural := 0;
   begin
      if Entity = "amp" then
         Append (Output, '&');
      elsif Entity = "lt" then
         Append (Output, '<');
      elsif Entity = "gt" then
         Append (Output, '>');
      elsif Entity = "quot" then
         Append (Output, '"');
      elsif Entity = "apos" then
         Append (Output, Character'Val (39));
      elsif Entity'Length > 1 and then Entity (Entity'First) = '#' then
         if Entity'Length > 2
           and then (Entity (Entity'First + 1) = 'x' or else Entity (Entity'First + 1) = 'X')
         then
            for Cursor in Entity'First + 2 .. Entity'Last loop
               declare
                  Ch    : constant Character := Entity (Cursor);
                  Digit : Natural;
               begin
                  if Ch in '0' .. '9' then
                     Digit := Character'Pos (Ch) - Character'Pos ('0');
                  elsif Ch in 'a' .. 'f' then
                     Digit := 10 + Character'Pos (Ch) - Character'Pos ('a');
                  elsif Ch in 'A' .. 'F' then
                     Digit := 10 + Character'Pos (Ch) - Character'Pos ('A');
                  else
                     Append (Output, '&' & Entity & ';');
                     return;
                  end if;

                  if Value > (Natural'Last - Digit) / 16 then
                     Append (Output, '&' & Entity & ';');
                     return;
                  end if;
                  Value := Value * 16 + Digit;
               end;
            end loop;
         else
            for Cursor in Entity'First + 1 .. Entity'Last loop
               declare
                  Ch : constant Character := Entity (Cursor);
               begin
                  if Ch not in '0' .. '9' then
                     Append (Output, '&' & Entity & ';');
                     return;
                  elsif Value > (Natural'Last - (Character'Pos (Ch) - Character'Pos ('0'))) / 10 then
                     Append (Output, '&' & Entity & ';');
                     return;
                  end if;
                  Value := Value * 10 + Character'Pos (Ch) - Character'Pos ('0');
               end;
            end loop;
         end if;

         if Value <= Character'Pos (Character'Last) then
            Append (Output, Character'Val (Value));
         else
            Append (Output, '&' & Entity & ';');
         end if;
      else
         Append (Output, '&' & Entity & ';');
      end if;
   end Append_XML_Entity_Decoded;

   function XML_Decode_Text (Text : String) return String is
      Output : Unbounded_String;
      Cursor : Natural := Text'First;
   begin
      while Cursor <= Text'Last loop
         if Text (Cursor) = '&' then
            declare
               Semi : Natural := Cursor + 1;
            begin
               while Semi <= Text'Last and then Text (Semi) /= ';' loop
                  Semi := Semi + 1;
               end loop;

               if Semi <= Text'Last and then Semi > Cursor + 1 then
                  Append_XML_Entity_Decoded (Output, Text (Cursor + 1 .. Semi - 1));
                  Cursor := Semi + 1;
               else
                  Append (Output, Text (Cursor));
                  Cursor := Cursor + 1;
               end if;
            end;
         else
            Append (Output, Text (Cursor));
            Cursor := Cursor + 1;
         end if;
      end loop;

      return To_String (Output);
   end XML_Decode_Text;

   function Trimmed_Decoded_XML_Text (Text : String) return String is
      Decoded : constant String := XML_Decode_Text (Text);
   begin
      return Ada.Strings.Fixed.Trim (Decoded, Ada.Strings.Both);
   end Trimmed_Decoded_XML_Text;

   procedure Extract_XML_Loc_Matches
     (Document_Text : String;
      Matches       : in out Link_Match_Vectors.Vector)
   is
      Cursor              : Natural := Document_Text'First;
      Depth               : Natural := 0;
      URLSet_Depth        : Natural := 0;
      Sitemap_Index_Depth : Natural := 0;
      URL_Depth           : Natural := 0;
      Sitemap_Depth       : Natural := 0;
      In_Loc              : Boolean := False;
      Loc_Tag_Start       : Natural := 0;
      Loc_Value_First     : Natural := 0;
      Loc_Value_Last      : Natural := 0;
      Loc_Text            : Unbounded_String := Null_Unbounded_String;

      procedure Append_Loc_Text (First_Pos : Natural; Last_Pos : Natural) is
      begin
         if In_Loc and then First_Pos <= Last_Pos then
            if Loc_Value_First = 0 then
               Loc_Value_First := First_Pos;
            end if;
            Loc_Value_Last := Last_Pos;
            Append (Loc_Text, Document_Text (First_Pos .. Last_Pos));
         end if;
      end Append_Loc_Text;

      procedure Finish_Loc is
         Value : constant String := Trimmed_Decoded_XML_Text (To_String (Loc_Text));
      begin
         if In_Loc and then Value /= "" and then Loc_Value_First /= 0 then
            Insert_Match
              (Matches,
               Loc_Tag_Start - Document_Text'First + 1,
               Loc_Value_First - Document_Text'First + 1,
               Loc_Value_Last - Document_Text'First + 1,
               Value);
         end if;

         In_Loc := False;
         Loc_Tag_Start := 0;
         Loc_Value_First := 0;
         Loc_Value_Last := 0;
         Loc_Text := Null_Unbounded_String;
      end Finish_Loc;
   begin
      while Cursor <= Document_Text'Last loop
         if Document_Text (Cursor) /= '<' then
            declare
               Text_First : constant Natural := Cursor;
            begin
               while Cursor <= Document_Text'Last and then Document_Text (Cursor) /= '<' loop
                  Cursor := Cursor + 1;
               end loop;
               Append_Loc_Text (Text_First, Cursor - 1);
            end;
         else
            declare
               Special_End : constant Natural := XML_Special_End (Document_Text, Cursor);
            begin
               if Special_End /= 0 then
                  if Is_XML_CDATA_Start (Document_Text, Cursor) and then Special_End >= Cursor + 12 then
                     Append_Loc_Text (Cursor + 9, Special_End - 3);
                  end if;
                  Cursor := Special_End + 1;
               else
                  declare
                     Tag_End      : constant Natural := XML_Tag_End (Document_Text, Cursor);
                     Is_Closing   : Boolean;
                     Name_First   : Natural;
                     Name_Last    : Natural;
                     Self_Closing : Boolean;
                     Element_Depth : constant Natural := Depth + 1;
                  begin
                     exit when Tag_End = 0;
                     XML_Tag_Name_Range (Document_Text, Cursor, Is_Closing, Name_First, Name_Last);
                     Self_Closing := XML_Tag_Is_Self_Closing (Document_Text, Cursor, Tag_End);

                     if Name_First /= 0 then
                        if Is_Closing then
                           if In_Loc and then XML_Local_Name_Is (Document_Text, Name_First, Name_Last, "loc") then
                              Finish_Loc;
                           elsif XML_Local_Name_Is (Document_Text, Name_First, Name_Last, "url")
                             and then URL_Depth = Depth
                           then
                              URL_Depth := 0;
                           elsif XML_Local_Name_Is (Document_Text, Name_First, Name_Last, "sitemap")
                             and then Sitemap_Depth = Depth
                           then
                              Sitemap_Depth := 0;
                           elsif XML_Local_Name_Is (Document_Text, Name_First, Name_Last, "urlset")
                             and then URLSet_Depth = Depth
                           then
                              URLSet_Depth := 0;
                           elsif XML_Local_Name_Is (Document_Text, Name_First, Name_Last, "sitemapindex")
                             and then Sitemap_Index_Depth = Depth
                           then
                              Sitemap_Index_Depth := 0;
                           end if;

                           if Depth > 0 then
                              Depth := Depth - 1;
                           end if;
                        else
                           if XML_Local_Name_Is (Document_Text, Name_First, Name_Last, "urlset") then
                              URLSet_Depth := Element_Depth;
                           elsif XML_Local_Name_Is (Document_Text, Name_First, Name_Last, "sitemapindex") then
                              Sitemap_Index_Depth := Element_Depth;
                           elsif XML_Local_Name_Is (Document_Text, Name_First, Name_Last, "url")
                             and then URLSet_Depth > 0
                           then
                              URL_Depth := Element_Depth;
                           elsif XML_Local_Name_Is (Document_Text, Name_First, Name_Last, "sitemap")
                             and then Sitemap_Index_Depth > 0
                           then
                              Sitemap_Depth := Element_Depth;
                           elsif XML_Local_Name_Is (Document_Text, Name_First, Name_Last, "loc")
                             and then not In_Loc
                             and then ((URLSet_Depth > 0 and then URL_Depth > 0)
                                       or else (Sitemap_Index_Depth > 0 and then Sitemap_Depth > 0))
                           then
                              In_Loc := True;
                              Loc_Tag_Start := Cursor;
                              Loc_Value_First := 0;
                              Loc_Value_Last := 0;
                              Loc_Text := Null_Unbounded_String;
                              if Self_Closing then
                                 Finish_Loc;
                              end if;
                           end if;

                           if not Self_Closing then
                              Depth := Element_Depth;
                           end if;
                        end if;
                     end if;

                     Cursor := Tag_End + 1;
                  end;
               end if;
            end;
         end if;
      end loop;
   end Extract_XML_Loc_Matches;

   type Link_Attribute_Hints is record
      Has_Href   : Boolean := False;
      Has_Src    : Boolean := False;
      Has_Srcset : Boolean := False;
      Has_CSS_URL    : Boolean := False;
      Has_CSS_Import : Boolean := False;
      Has_XML_Loc    : Boolean := False;
   end record;

   function Link_Attribute_Hints_For (Document_Text : String) return Link_Attribute_Hints is
      Current : Character;
      Next_1  : Character;
      Next_2  : Character;
      Next_3  : Character;
      Hints   : Link_Attribute_Hints;
   begin
      if Document_Text'Length < 3 then
         return Hints;
      end if;

      for Index_Value in Document_Text'First .. Document_Text'Last - 2 loop
         exit when Hints.Has_Href and then Hints.Has_Src
           and then Hints.Has_Srcset and then Hints.Has_CSS_URL
           and then Hints.Has_CSS_Import and then Hints.Has_XML_Loc;

         Current := Ada.Characters.Handling.To_Lower (Document_Text (Index_Value));
         Next_1 := Ada.Characters.Handling.To_Lower (Document_Text (Index_Value + 1));
         Next_2 := Ada.Characters.Handling.To_Lower (Document_Text (Index_Value + 2));

         if Current = 's' and then Next_1 = 'r' and then Next_2 = 'c' then
            Hints.Has_Src := True;
            if Index_Value <= Document_Text'Last - 5
              and then Ada.Characters.Handling.To_Lower (Document_Text (Index_Value + 3)) = 's'
              and then Ada.Characters.Handling.To_Lower (Document_Text (Index_Value + 4)) = 'e'
              and then Ada.Characters.Handling.To_Lower (Document_Text (Index_Value + 5)) = 't'
            then
               Hints.Has_Srcset := True;
            end if;
         elsif Current = 'u' and then Next_1 = 'r' and then Next_2 = 'l' then
            Hints.Has_CSS_URL := True;
         elsif Current = '@'
           and then Index_Value <= Document_Text'Last - 6
           and then Lower_Equals_At (Document_Text, Index_Value + 1, "import")
         then
            Hints.Has_CSS_Import := True;
         elsif Current = 'l' and then Next_1 = 'o' and then Next_2 = 'c' then
            Hints.Has_XML_Loc := True;
         elsif Current = 'h' and then Index_Value <= Document_Text'Last - 3 then
            Next_3 := Ada.Characters.Handling.To_Lower (Document_Text (Index_Value + 3));
            if Next_1 = 'r' and then Next_2 = 'e' and then Next_3 = 'f' then
               Hints.Has_Href := True;
            end if;
         end if;
      end loop;

      return Hints;
   end Link_Attribute_Hints_For;

   procedure Extract_Link_Matches
     (Document_Text : String;
      Matches       : in out Link_Match_Vectors.Vector)
   is
      Hints : constant Link_Attribute_Hints := Link_Attribute_Hints_For (Document_Text);
   begin
      Matches.Clear;
      if not Hints.Has_Href and then not Hints.Has_Src
        and then not Hints.Has_Srcset and then not Hints.Has_CSS_URL
        and then not Hints.Has_CSS_Import and then not Hints.Has_XML_Loc
      then
         return;
      end if;

      if Hints.Has_Href then
         Extract_With_Pattern (Document_Text, Href_Double_Regexp, Matches);
         Extract_With_Pattern (Document_Text, Href_Single_Regexp, Matches);
      end if;

      if Hints.Has_Srcset then
         Extract_Srcset_With_Pattern (Document_Text, Srcset_Double_Regexp, Matches);
         Extract_Srcset_With_Pattern (Document_Text, Srcset_Single_Regexp, Matches);
      end if;

      if Hints.Has_Src then
         Extract_With_Pattern (Document_Text, Src_Double_Regexp, Matches);
         Extract_With_Pattern (Document_Text, Src_Single_Regexp, Matches);
      end if;

      if Hints.Has_CSS_URL or else Hints.Has_CSS_Import then
         Extract_CSS_Matches (Document_Text, Matches);
      end if;

      if Hints.Has_XML_Loc then
         Extract_XML_Loc_Matches (Document_Text, Matches);
      end if;

      if Natural (Matches.Length) > 1 then
         Link_Match_Sorting.Sort (Matches);
      end if;
   end Extract_Link_Matches;

   function Links_From_Matches (Matches : Link_Match_Vectors.Vector) return Link_List is
      Links : Link_List;
      Seen  : URL_Sets.Set;
   begin
      for Item of Matches loop
         declare
            Reference : constant String := To_String (Item.Reference);
         begin
            if Reference /= "" and then not Seen.Contains (Reference) then
               Links.Append (Reference);
               Seen.Include (Reference);
            end if;
         end;
      end loop;

      return Links;
   end Links_From_Matches;

   function Extract_Links (Document_Text : String) return Link_List is
      Matches : Link_Match_Vectors.Vector;
   begin
      Extract_Link_Matches (Document_Text, Matches);
      return Links_From_Matches (Matches);
   end Extract_Links;

   procedure Split_Path (Path_Text : String; Parts : in out String_Vectors.Vector) is
      First : Positive := Path_Text'First;
   begin
      Parts.Clear;
      for Index_Value in Path_Text'Range loop
         if Path_Text (Index_Value) = '/' then
            if Index_Value > First then
               Parts.Append (Path_Text (First .. Index_Value - 1));
            end if;
            First := Index_Value + 1;
         end if;
      end loop;

      if First <= Path_Text'Last then
         Parts.Append (Path_Text (First .. Path_Text'Last));
      end if;
   end Split_Path;

   function Relative_Local_Path_From_Local (From_Local : String; To_Local : String) return String is
      From_Parts : String_Vectors.Vector;
      To_Parts   : String_Vectors.Vector;
      Common     : Natural := 0;
      Result     : Unbounded_String := Null_Unbounded_String;
   begin
      Split_Path (From_Local, From_Parts);
      Split_Path (To_Local, To_Parts);

      if not From_Parts.Is_Empty then
         From_Parts.Delete_Last;
      end if;

      while Common < Natural (From_Parts.Length) and then Common < Natural (To_Parts.Length) loop
         exit when From_Parts.Element (Positive (Common + 1)) /= To_Parts.Element (Positive (Common + 1));
         Common := Common + 1;
      end loop;

      for Index_Value in Common + 1 .. Natural (From_Parts.Length) loop
         Append (Result, "../");
      end loop;

      for Index_Value in Common + 1 .. Natural (To_Parts.Length) loop
         if Length (Result) > 0 and then Element (Result, Length (Result)) /= '/' then
            Append (Result, "/");
         end if;
         Append (Result, To_Parts.Element (Positive (Index_Value)));
      end loop;

      if Length (Result) = 0 then
         return To_Local;
      end if;

      return To_String (Result);
   end Relative_Local_Path_From_Local;

   function Relative_Local_Path (From_URL : String; To_URL : String) return String is
   begin
      return Relative_Local_Path_From_Local
        (Local_Path_For_URL (From_URL), Local_Path_For_URL (To_URL));
   end Relative_Local_Path;

   function Rewrite_Document_With_Matches
     (Document_Text : String;
      Page_URL      : String;
      Root_URL      : String;
      Matches       : Link_Match_Vectors.Vector;
      Policy        : Domain_Policy := Domain_Exact_And_Subdomains) return String
   is
      Result            : Unbounded_String := Null_Unbounded_String;
      Current           : Natural := 1;
      Root_Domain       : constant String := Domain_Of (Root_URL);
      Page_Local        : constant String := Local_Path_For_URL (Page_URL);
      Replacement_Cache : URL_Path_Maps.Map;
      Target_Path_Cache : URL_Path_Maps.Map;
   begin
      for Item of Matches loop
         declare
            Reference        : constant String := To_String (Item.Reference);
            Replacement_Text : Unbounded_String := Null_Unbounded_String;
         begin
            if Replacement_Cache.Contains (Reference) then
               Replacement_Text := To_Unbounded_String (Replacement_Cache.Element (Reference));
            else
               declare
                  Computed : Unbounded_String := Null_Unbounded_String;
               begin
                  if Is_Fetchable_Reference (Reference) then
                     declare
                        Absolute_URL : constant String :=
                          Canonical_URL (Resolve_URL (Page_URL, Reference));
                     begin
                        if Is_In_Domain (Root_Domain, Absolute_URL, Policy) then
                           declare
                              Target_Local : Unbounded_String := Null_Unbounded_String;
                           begin
                              if Target_Path_Cache.Contains (Absolute_URL) then
                                 Target_Local := To_Unbounded_String
                                   (Target_Path_Cache.Element (Absolute_URL));
                              else
                                 Target_Local := To_Unbounded_String (Local_Path_For_URL (Absolute_URL));
                                 Target_Path_Cache.Include (Absolute_URL, To_String (Target_Local));
                              end if;

                              Computed := To_Unbounded_String
                                (Relative_Local_Path_From_Local (Page_Local, To_String (Target_Local)));
                           end;
                        end if;
                     end;
                  end if;

                  Replacement_Cache.Include (Reference, To_String (Computed));
                  Replacement_Text := Computed;
               end;
            end if;

            if Length (Replacement_Text) > 0 and then Item.Value_First >= Current then
               if Current < Item.Value_First then
                  Append
                    (Result,
                     Document_Text
                       (Document_Text'First + Current - 1 .. Document_Text'First + Item.Value_First - 2));
               end if;

               Append (Result, To_String (Replacement_Text));
               Current := Item.Value_Last + 1;
            end if;
         end;
      end loop;

      if Current <= Document_Text'Length then
         Append (Result, Document_Text (Document_Text'First + Current - 1 .. Document_Text'Last));
      end if;

      return To_String (Result);
   end Rewrite_Document_With_Matches;

   function Has_Rewriteable_Match
     (Page_URL : String;
      Root_URL : String;
      Matches  : Link_Match_Vectors.Vector;
      Policy   : Domain_Policy := Domain_Exact_And_Subdomains) return Boolean
   is
      Root_Domain : constant String := Domain_Of (Root_URL);
   begin
      for Item of Matches loop
         declare
            Reference : constant String := To_String (Item.Reference);
         begin
            if Is_Fetchable_Reference (Reference) then
               declare
                  Absolute_URL : constant String := Canonical_URL (Resolve_URL (Page_URL, Reference));
               begin
                  if Is_In_Domain (Root_Domain, Absolute_URL, Policy) then
                     return True;
                  end if;
               end;
            end if;
         end;
      end loop;

      return False;
   end Has_Rewriteable_Match;

   function Document_Text_For_Write
     (Document_Text : String;
      Page_URL      : String;
      Root_URL      : String;
      Matches       : Link_Match_Vectors.Vector;
      Policy        : Domain_Policy := Domain_Exact_And_Subdomains) return String
   is
   begin
      if Has_Rewriteable_Match (Page_URL, Root_URL, Matches, Policy) then
         return Rewrite_Document_With_Matches (Document_Text, Page_URL, Root_URL, Matches, Policy);
      else
         return Document_Text;
      end if;
   end Document_Text_For_Write;

   function Rewrite_Document
     (Document_Text : String;
      Page_URL      : String;
      Root_URL      : String) return String
   is
      Matches : Link_Match_Vectors.Vector;
   begin
      Extract_Link_Matches (Document_Text, Matches);
      return Rewrite_Document_With_Matches (Document_Text, Page_URL, Root_URL, Matches);
   end Rewrite_Document;

end Sitefetch.Documents;
