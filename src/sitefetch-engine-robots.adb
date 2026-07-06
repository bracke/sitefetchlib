with Ada.Calendar;
with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Strings.Fixed;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded;

with Sitefetch.URLs;

package body Sitefetch.Engine.Robots is
   use Ada.Strings.Unbounded;
   use Sitefetch.URLs;
   use type Ada.Calendar.Time;

   function Ignore_Robots return Robots_Rules is
     (Enabled        => False,
      Directives     => Robots_Directive_Vectors.Empty_Vector,
      Crawl_Delay_MS => 0,
      Sitemaps       => String_Vectors.Empty_Vector,
      Source_URL     => Null_Unbounded_String);

   function Fail_Closed_Robots return Robots_Rules is
      Rules : Robots_Rules := Ignore_Robots;
   begin
      Rules.Enabled := True;
      Rules.Directives.Append
        (Robots_Directive'
           (Kind   => Robots_Disallow,
            Prefix => To_Unbounded_String ("/")));
      return Rules;
   end Fail_Closed_Robots;

   package Robots_Rules_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => String,
      Element_Type    => Robots_Rules,
      Hash            => Ada.Strings.Hash,
      Equivalent_Keys => "=");

   package Origin_Time_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => String,
      Element_Type    => Ada.Calendar.Time,
      Hash            => Ada.Strings.Hash,
      Equivalent_Keys => "=");

   protected Robots_Cache is
      procedure Lookup (Origin : String; Found : out Boolean; Rules : out Robots_Rules);
      procedure Store (Origin : String; Rules : Robots_Rules);
      procedure Clear;
   private
      Entries : Robots_Rules_Maps.Map;
   end Robots_Cache;

   protected Crawl_Delay_Scheduler is
      procedure Reserve
        (Origin       : String;
         Delay_MS     : Natural;
         Wait_Seconds : out Duration);
      procedure Clear;
   private
      Next_Start_By_Origin : Origin_Time_Maps.Map;
   end Crawl_Delay_Scheduler;

   protected body Robots_Cache is
      procedure Lookup (Origin : String; Found : out Boolean; Rules : out Robots_Rules) is
      begin
         Found := Entries.Contains (Origin);
         if Found then
            Rules := Entries.Element (Origin);
         else
            Rules := Ignore_Robots;
         end if;
      end Lookup;

      procedure Store (Origin : String; Rules : Robots_Rules) is
      begin
         Entries.Include (Origin, Rules);
      end Store;

      procedure Clear is
      begin
         Entries.Clear;
      end Clear;
   end Robots_Cache;

   protected body Crawl_Delay_Scheduler is
      procedure Reserve
        (Origin       : String;
         Delay_MS     : Natural;
         Wait_Seconds : out Duration)
      is
         Now_Time   : constant Ada.Calendar.Time := Ada.Calendar.Clock;
         Delay_Time : constant Duration := Duration (Long_Float (Delay_MS) / 1000.0);
         Next_Time  : Ada.Calendar.Time;
      begin
         Wait_Seconds := 0.0;
         if Origin = "" or else Delay_MS = 0 then
            return;
         end if;

         if Next_Start_By_Origin.Contains (Origin) then
            Next_Time := Next_Start_By_Origin.Element (Origin);
            if Next_Time > Now_Time then
               Wait_Seconds := Next_Time - Now_Time;
               Next_Start_By_Origin.Replace (Origin, Next_Time + Delay_Time);
            else
               Next_Start_By_Origin.Replace (Origin, Now_Time + Delay_Time);
            end if;
         else
            Next_Start_By_Origin.Insert (Origin, Now_Time + Delay_Time);
         end if;
      end Reserve;

      procedure Clear is
      begin
         Next_Start_By_Origin.Clear;
      end Clear;
   end Crawl_Delay_Scheduler;


   procedure Lookup_Cached_Robots
     (Origin : String;
      Found  : out Boolean;
      Rules  : out Robots_Rules) is
   begin
      Robots_Cache.Lookup (Origin, Found, Rules);
   end Lookup_Cached_Robots;

   procedure Store_Cached_Robots (Origin : String; Rules : Robots_Rules) is
   begin
      Robots_Cache.Store (Origin, Rules);
   end Store_Cached_Robots;

   procedure Clear_Robots_Cache is
   begin
      Robots_Cache.Clear;
   end Clear_Robots_Cache;

   procedure Reserve_Request_Delay
     (URL          : String;
      Limits       : Fetch_Options;
      Wait_Seconds : out Duration) is
   begin
      Crawl_Delay_Scheduler.Reserve
        (Origin_Of (URL), Limits.HTTP.Request_Delay_MS, Wait_Seconds);
   end Reserve_Request_Delay;

   procedure Clear_Crawl_Delay_Scheduler is
   begin
      Crawl_Delay_Scheduler.Clear;
   end Clear_Crawl_Delay_Scheduler;

   function Directive_Name (Line : String) return String is
   begin
      for Index_Value in Line'Range loop
         if Line (Index_Value) = ':' then
            return To_Lower
              (Ada.Strings.Fixed.Trim
                 (Line (Line'First .. Index_Value - 1), Ada.Strings.Both));
         end if;
      end loop;
      return "";
   end Directive_Name;

   function Directive_Value (Line : String) return String is
   begin
      for Index_Value in Line'Range loop
         if Line (Index_Value) = ':' then
            if Index_Value = Line'Last then
               return "";
            else
               return Ada.Strings.Fixed.Trim
                 (Line (Index_Value + 1 .. Line'Last), Ada.Strings.Both);
            end if;
         end if;
      end loop;
      return "";
   end Directive_Value;

   function Strip_Robots_Comment (Line : String) return String is
   begin
      for Index_Value in Line'Range loop
         if Line (Index_Value) = '#' then
            if Index_Value = Line'First then
               return "";
            else
               return Line (Line'First .. Index_Value - 1);
            end if;
         end if;
      end loop;
      return Line;
   end Strip_Robots_Comment;

   function User_Agent_Matches (Pattern : String; Agent : String; Match_Star : Boolean) return Boolean is
      Lower_Pattern : constant String := To_Lower (Pattern);
      Lower_Agent   : constant String := To_Lower (Agent);
   begin
      if Match_Star then
         return Lower_Pattern = "*";
      else
         return Lower_Pattern /= "*"
           and then Ada.Strings.Fixed.Index (Lower_Agent, Lower_Pattern) > 0;
      end if;
   end User_Agent_Matches;

   procedure Append_Robots_Directive
     (Rules : in out Robots_Rules;
      Kind  : Robots_Directive_Kind;
      Value : String)
   is
   begin
      if Value /= "" then
         Rules.Directives.Append
           (Robots_Directive'
              (Kind   => Kind,
               Prefix => To_Unbounded_String (Value)));
      end if;
   end Append_Robots_Directive;

   function Parse_Crawl_Delay_MS (Value : String; Delay_MS : out Natural) return Boolean is
      Seconds_Text : constant String := Ada.Strings.Fixed.Trim (Value, Ada.Strings.Both);
      Whole        : Natural := 0;
      Fraction     : Natural := 0;
      Fraction_Digits       : Natural := 0;
      Seen_Dot     : Boolean := False;
   begin
      Delay_MS := 0;
      if Seconds_Text = "" then
         return False;
      end if;

      for Ch of Seconds_Text loop
         if Ch = '.' and then not Seen_Dot then
            Seen_Dot := True;
         elsif Ch in '0' .. '9' then
            if Seen_Dot then
               if Fraction_Digits < 3 then
                  Fraction := Fraction * 10 + Character'Pos (Ch) - Character'Pos ('0');
                  Fraction_Digits := Fraction_Digits + 1;
               end if;
            else
               if Whole > Natural'Last / 10 then
                  return False;
               end if;
               Whole := Whole * 10 + Character'Pos (Ch) - Character'Pos ('0');
            end if;
         else
            return False;
         end if;
      end loop;

      while Fraction_Digits < 3 loop
         Fraction := Fraction * 10;
         Fraction_Digits := Fraction_Digits + 1;
      end loop;

      if Whole > Natural'Last / 1_000 then
         Delay_MS := Natural'Last;
      elsif Fraction > Natural'Last - Whole * 1_000 then
         Delay_MS := Natural'Last;
      else
         Delay_MS := Whole * 1_000 + Fraction;
      end if;
      return True;
   end Parse_Crawl_Delay_MS;

   procedure Parse_Robots_For_Agent
     (Text        : String;
      Agent       : String;
      Match_Star  : Boolean;
      Found_Match : out Boolean;
      Rules       : in out Robots_Rules)
   is
      Current_Applies : Boolean := False;
      In_Group        : Boolean := False;
      Group_Has_Rules : Boolean := False;
      Delay_MS        : Natural := 0;

      procedure Finish_Group is
      begin
         Current_Applies := False;
         In_Group := False;
         Group_Has_Rules := False;
      end Finish_Group;

      procedure Process_Line (Raw_Line : String) is
         Line  : constant String := Ada.Strings.Fixed.Trim
           (Strip_Robots_Comment (Raw_Line), Ada.Strings.Both);
         Name  : constant String := Directive_Name (Line);
         Value : constant String := Directive_Value (Line);
      begin
         if Line = "" then
            Finish_Group;
         elsif Name = "user-agent" then
            if Group_Has_Rules then
               Finish_Group;
            end if;

            In_Group := True;
            if User_Agent_Matches (Value, Agent, Match_Star) then
               Current_Applies := True;
               Found_Match := True;
            end if;
         elsif Name = "allow" then
            if In_Group then
               Group_Has_Rules := True;
               if Current_Applies then
                  Append_Robots_Directive (Rules, Robots_Allow, Value);
               end if;
            end if;
         elsif Name = "disallow" then
            if In_Group then
               Group_Has_Rules := True;
               if Current_Applies then
                  Append_Robots_Directive (Rules, Robots_Disallow, Value);
               end if;
            end if;
         elsif Name = "crawl-delay" then
            if In_Group then
               Group_Has_Rules := True;
               if Current_Applies and then Parse_Crawl_Delay_MS (Value, Delay_MS) then
                  if Rules.Crawl_Delay_MS = 0 or else Delay_MS > Rules.Crawl_Delay_MS then
                     Rules.Crawl_Delay_MS := Delay_MS;
                  end if;
               end if;
            end if;
         elsif Name = "sitemap" then
            if Value /= "" then
               Rules.Sitemaps.Append (Value);
            end if;
         else
            null;
         end if;
      end Process_Line;

      Start : Positive := Text'First;
   begin
      Found_Match := False;
      if Text = "" then
         return;
      end if;

      for Index_Value in Text'Range loop
         if Text (Index_Value) = Character'Val (10) then
            if Index_Value > Start then
               Process_Line (Text (Start .. Index_Value - 1));
            else
               Process_Line ("");
            end if;
            Start := Index_Value + 1;
         end if;
      end loop;

      if Start <= Text'Last then
         Process_Line (Text (Start .. Text'Last));
      end if;
   end Parse_Robots_For_Agent;

   procedure Parse_Robots
     (Text       : String;
      User_Agent : String;
      Rules      : in out Robots_Rules)
   is
      Exact_Found : Boolean := False;
      Star_Found  : Boolean := False;
      Sitemaps    : Link_List;
   begin
      Rules.Directives.Clear;
      Rules.Sitemaps.Clear;
      Rules.Crawl_Delay_MS := 0;
      Parse_Robots_For_Agent (Text, User_Agent, False, Exact_Found, Rules);
      Sitemaps := Rules.Sitemaps;
      if not Exact_Found then
         Rules.Directives.Clear;
         Rules.Sitemaps := Sitemaps;
         Rules.Crawl_Delay_MS := 0;
         Parse_Robots_For_Agent (Text, User_Agent, True, Star_Found, Rules);
      end if;
   end Parse_Robots;

   function Robots_Target_Of (URL : String) return String is
      Start_At : constant Natural := Authority_Start (URL);
      First    : Natural := 0;
      Last     : Natural := URL'Last;
   begin
      if Start_At = 0 then
         return Path_Only (URL);
      end if;

      for Index_Value in Start_At .. URL'Last loop
         if URL (Index_Value) = '/' or else URL (Index_Value) = '?' then
            First := Index_Value;
            exit;
         end if;
      end loop;

      if First = 0 then
         return "/";
      end if;

      for Index_Value in First .. URL'Last loop
         if URL (Index_Value) = '#' then
            Last := Index_Value - 1;
            exit;
         end if;
      end loop;

      if URL (First) = '?' then
         return "/" & URL (First .. Last);
      else
         return URL (First .. Last);
      end if;
   end Robots_Target_Of;

   function Robots_Pattern_Matches (Pattern : String; Target : String) return Boolean is
      function Match_At (Pattern_Pos : Natural; Target_Pos : Natural) return Boolean is
      begin
         if Pattern_Pos > Pattern'Last then
            return True;
         elsif Pattern (Pattern_Pos) = '$' and then Pattern_Pos = Pattern'Last then
            return Target_Pos > Target'Last;
         elsif Pattern (Pattern_Pos) = '*' then
            for Next_Target in Target_Pos .. Target'Last + 1 loop
               if Match_At (Pattern_Pos + 1, Next_Target) then
                  return True;
               end if;
            end loop;
            return False;
         elsif Target_Pos <= Target'Last and then Pattern (Pattern_Pos) = Target (Target_Pos) then
            return Match_At (Pattern_Pos + 1, Target_Pos + 1);
         else
            return False;
         end if;
      end Match_At;
   begin
      return Pattern /= "" and then Match_At (Pattern'First, Target'First);
   end Robots_Pattern_Matches;

   function Robots_Allows (Rules : Robots_Rules; URL : String) return Boolean is
      Target_Text  : constant String := Robots_Target_Of (URL);
      Best_Length  : Natural := 0;
      Best_Allows  : Boolean := True;
      Match_Length : Natural;
   begin
      if not Rules.Enabled then
         return True;
      end if;

      for Rule of Rules.Directives loop
         declare
            Pattern : constant String := To_String (Rule.Prefix);
         begin
            if Robots_Pattern_Matches (Pattern, Target_Text) then
               Match_Length := Pattern'Length;
               if Match_Length > Best_Length
                 or else (Match_Length = Best_Length and then Rule.Kind = Robots_Allow)
               then
                  Best_Length := Match_Length;
                  Best_Allows := Rule.Kind = Robots_Allow;
               end if;
            end if;
         end;
      end loop;

      return Best_Allows;
   end Robots_Allows;

   function Apply_Robots_Delay (Limits : Fetch_Options; Robots : Robots_Rules) return Fetch_Options is
      Result : Fetch_Options := Limits;
   begin
      if Robots.Enabled and then Robots.Crawl_Delay_MS > Result.HTTP.Request_Delay_MS then
         Result.HTTP.Request_Delay_MS := Robots.Crawl_Delay_MS;
      end if;
      return Result;
   end Apply_Robots_Delay;

end Sitefetch.Engine.Robots;
