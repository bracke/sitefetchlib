with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Strings.Fixed;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded;
with Ada.Task_Identification;

with Sitefetch.URLs;

package body Sitefetch.Engine.Diagnostics is
   use Ada.Strings.Unbounded;

   Current_Structured_Progress : Structured_Progress_Callback := null;

   type Progress_Metadata is record
      Bytes_Written         : Natural := 0;
      Depth                 : Natural := 0;
      Status_Code           : Natural := 0;
      Retry_Attempt         : Natural := 0;
      Cache_Decision        : Unbounded_String := Null_Unbounded_String;
      Robots_Source         : Unbounded_String := Null_Unbounded_String;
      Final_URL             : Unbounded_String := Null_Unbounded_String;
      Source_ID             : Unbounded_String := Null_Unbounded_String;
      Local_Path            : Unbounded_String := Null_Unbounded_String;
      Redirect_Hops         : Natural := 0;
      Redirect_Chain        : Unbounded_String := Null_Unbounded_String;
      Redirect_Status_Codes : Unbounded_String := Null_Unbounded_String;
      Redirect_Target_URLs  : Unbounded_String := Null_Unbounded_String;
      Redirect_Locations    : Unbounded_String := Null_Unbounded_String;
      Has_Bytes             : Boolean := False;
      Has_Depth             : Boolean := False;
   end record;

   package Progress_Metadata_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => String,
      Element_Type    => Progress_Metadata,
      Hash            => Ada.Strings.Hash,
      Equivalent_Keys => "=");

   protected Structured_Metadata is
      procedure Set (Metadata : Progress_Metadata);
      procedure Snapshot (Metadata : out Progress_Metadata);
      procedure Clear;
   private
      Entries : Progress_Metadata_Maps.Map;
   end Structured_Metadata;

   function Current_Task_Key return String is
     (Ada.Task_Identification.Image (Ada.Task_Identification.Current_Task));

   protected body Structured_Metadata is
      procedure Set (Metadata : Progress_Metadata) is
      begin
         Entries.Include (Current_Task_Key, Metadata);
      end Set;

      procedure Snapshot (Metadata : out Progress_Metadata) is
         Key : constant String := Current_Task_Key;
      begin
         if Entries.Contains (Key) then
            Metadata := Entries.Element (Key);
         else
            Metadata := (others => <>);
         end if;
      end Snapshot;

      procedure Clear is
         Key : constant String := Current_Task_Key;
      begin
         if Entries.Contains (Key) then
            Entries.Delete (Key);
         end if;
      end Clear;
   end Structured_Metadata;

   type Redirect_Diagnostic_Metadata is record
      Status_Codes : Unbounded_String := Null_Unbounded_String;
      Target_URLs  : Unbounded_String := Null_Unbounded_String;
      Locations    : Unbounded_String := Null_Unbounded_String;
   end record;

   package Redirect_Diagnostic_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => String,
      Element_Type    => Redirect_Diagnostic_Metadata,
      Hash            => Ada.Strings.Hash,
      Equivalent_Keys => "=");

   protected Redirect_Diagnostics is
      procedure Begin_Request;
      procedure Record_Hop (Status_Code : Natural; Target_URL : String; Location : String);
      procedure Snapshot_And_Clear
        (Status_Codes : out Unbounded_String;
         Target_URLs  : out Unbounded_String;
         Locations    : out Unbounded_String);
   private
      Entries : Redirect_Diagnostic_Maps.Map;
   end Redirect_Diagnostics;

   protected body Redirect_Diagnostics is
      procedure Begin_Request is
      begin
         Entries.Include
           (Current_Task_Key,
            (Status_Codes => Null_Unbounded_String,
             Target_URLs  => Null_Unbounded_String,
             Locations    => Null_Unbounded_String));
      end Begin_Request;

      procedure Append_Field (Field : in out Unbounded_String; Value : String; Separator : String) is
      begin
         if Length (Field) > 0 then
            Append (Field, Separator);
         end if;
         Append (Field, Value);
      end Append_Field;

      procedure Record_Hop (Status_Code : Natural; Target_URL : String; Location : String) is
         Key      : constant String := Current_Task_Key;
         Metadata : Redirect_Diagnostic_Metadata;
      begin
         if Entries.Contains (Key) then
            Metadata := Entries.Element (Key);
         else
            Metadata :=
              (Status_Codes => Null_Unbounded_String,
               Target_URLs  => Null_Unbounded_String,
               Locations    => Null_Unbounded_String);
         end if;

         Append_Field
           (Metadata.Status_Codes,
            Ada.Strings.Fixed.Trim (Natural'Image (Status_Code), Ada.Strings.Left),
            ", ");
         Append_Field (Metadata.Target_URLs, Target_URL, " | ");
         Append_Field (Metadata.Locations, Location, " | ");
         Entries.Include (Key, Metadata);
      end Record_Hop;

      procedure Snapshot_And_Clear
        (Status_Codes : out Unbounded_String;
         Target_URLs  : out Unbounded_String;
         Locations    : out Unbounded_String)
      is
         Key : constant String := Current_Task_Key;
      begin
         if Entries.Contains (Key) then
            Status_Codes := Entries.Element (Key).Status_Codes;
            Target_URLs := Entries.Element (Key).Target_URLs;
            Locations := Entries.Element (Key).Locations;
            Entries.Delete (Key);
         else
            Status_Codes := Null_Unbounded_String;
            Target_URLs := Null_Unbounded_String;
            Locations := Null_Unbounded_String;
         end if;
      end Snapshot_And_Clear;
   end Redirect_Diagnostics;

   function Reason_Start (Text : String) return Natural is
   begin
      if Text'Length < 3 or else Text (Text'Last) /= ')' then
         return 0;
      end if;

      for Index_Value in reverse Text'First .. Text'Last - 2 loop
         if Text (Index_Value) = ' ' and then Text (Index_Value + 1) = '(' then
            return Index_Value;
         end if;
      end loop;

      return 0;
   end Reason_Start;

   function Retry_Attempt_From_Reason (Reason : String) return Natural is
      Prefix : constant String := "attempt ";
      First  : Natural := Reason'First + Prefix'Length;
      Value  : Natural := 0;
   begin
      if Reason'Length <= Prefix'Length
        or else Reason (Reason'First .. Reason'First + Prefix'Length - 1) /= Prefix
      then
         return 0;
      end if;

      while First <= Reason'Last and then Reason (First) in '0' .. '9' loop
         if Value > (Natural'Last - Character'Pos (Reason (First)) + Character'Pos ('0')) / 10 then
            return 0;
         end if;
         Value := Value * 10 + Character'Pos (Reason (First)) - Character'Pos ('0');
         First := First + 1;
      end loop;

      return Value;
   end Retry_Attempt_From_Reason;

   function Status_Code_From_Reason (Reason : String) return Natural is
      Marker : constant String := "HTTP_";
      Start  : constant Natural := Ada.Strings.Fixed.Index (Reason, Marker);
      Cursor : Natural;
      Value  : Natural := 0;
   begin
      if Start = 0 then
         return 0;
      end if;

      Cursor := Start + Marker'Length;
      while Cursor <= Reason'Last and then Reason (Cursor) in '0' .. '9' loop
         if Value > (Natural'Last - Character'Pos (Reason (Cursor)) + Character'Pos ('0')) / 10 then
            return 0;
         end if;
         Value := Value * 10 + Character'Pos (Reason (Cursor)) - Character'Pos ('0');
         Cursor := Cursor + 1;
      end loop;

      return Value;
   end Status_Code_From_Reason;

   function Cache_Decision_For (Event : Progress_Event) return Unbounded_String is
   begin
      case Event is
         when Progress_Cache_Revalidate =>
            return To_Unbounded_String ("revalidate");
         when Progress_Cache_Reused =>
            return To_Unbounded_String ("reused");
         when Progress_Cache_Rejected =>
            return To_Unbounded_String ("rejected");
         when others =>
            return Null_Unbounded_String;
      end case;
   end Cache_Decision_For;

   function Robots_Source_For (Event : Progress_Event) return Unbounded_String is
   begin
      case Event is
         when Progress_Robots_Allowed | Progress_Robots_Disallowed
            | Progress_Robots_Loaded | Progress_Robots_Failed =>
            return To_Unbounded_String ("robots.txt");
         when others =>
            return Null_Unbounded_String;
      end case;
   end Robots_Source_For;

   function Default_Final_URL_For
     (Event    : Progress_Event;
      URL_Text : String) return Unbounded_String
   is
   begin
      case Event is
         when Progress_Fetching | Progress_Written | Progress_Failed
            | Progress_Cache_Reused | Progress_Cache_Revalidate | Progress_Cache_Rejected
            | Progress_Resume_Attempt | Progress_Retry =>
            return To_Unbounded_String (URL_Text);
         when others =>
            return Null_Unbounded_String;
      end case;
   end Default_Final_URL_For;

   function Default_Source_ID return Unbounded_String is
   begin
      return To_Unbounded_String (Current_Task_Key);
   end Default_Source_ID;

   procedure Set_Metadata
     (Bytes_Written         : Natural := 0;
      Has_Bytes             : Boolean := False;
      Depth                 : Natural := 0;
      Has_Depth             : Boolean := False;
      Status_Code           : Natural := 0;
      Retry_Attempt         : Natural := 0;
      Cache_Decision        : String := "";
      Robots_Source         : String := "";
      Final_URL             : String := "";
      Source_ID             : String := "";
      Local_Path            : String := "";
      Redirect_Hops         : Natural := 0;
      Redirect_Chain        : String := "";
      Redirect_Status_Codes : String := "";
      Redirect_Target_URLs  : String := "";
      Redirect_Locations    : String := "")
   is
   begin
      Structured_Metadata.Set
        ((Bytes_Written         => Bytes_Written,
          Depth                 => Depth,
          Status_Code           => Status_Code,
          Retry_Attempt         => Retry_Attempt,
          Cache_Decision        => To_Unbounded_String (Cache_Decision),
          Robots_Source         => To_Unbounded_String (Robots_Source),
          Final_URL             => To_Unbounded_String (Final_URL),
          Source_ID             => To_Unbounded_String (Source_ID),
          Local_Path            => To_Unbounded_String (Local_Path),
          Redirect_Hops         => Redirect_Hops,
          Redirect_Chain        => To_Unbounded_String (Redirect_Chain),
          Redirect_Status_Codes => To_Unbounded_String (Redirect_Status_Codes),
          Redirect_Target_URLs  => To_Unbounded_String (Redirect_Target_URLs),
          Redirect_Locations    => To_Unbounded_String (Redirect_Locations),
          Has_Bytes             => Has_Bytes,
          Has_Depth             => Has_Depth));
   end Set_Metadata;

   procedure Clear_Metadata is
   begin
      Structured_Metadata.Clear;
   end Clear_Metadata;

   function Natural_Image (Value : Natural) return String is
   begin
      return Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Left);
   end Natural_Image;

   procedure Emit_Progress
     (Progress : Progress_Callback;
      Event    : Progress_Event;
      URL      : String) is
   begin
      if Progress /= null then
         begin
            Progress (Event, URL);
         exception
            when others =>
               Clear_Metadata;
               raise;
         end;
      end if;
      Clear_Metadata;
   end Emit_Progress;

   procedure Emit_Progress_Detailed
     (Progress              : Progress_Callback;
      Event                 : Progress_Event;
      URL                   : String;
      Bytes_Written         : Natural := 0;
      Has_Bytes             : Boolean := False;
      Depth                 : Natural := 0;
      Has_Depth             : Boolean := False;
      Status_Code           : Natural := 0;
      Retry_Attempt         : Natural := 0;
      Cache_Decision        : String := "";
      Robots_Source         : String := "";
      Final_URL             : String := "";
      Source_ID             : String := "";
      Local_Path            : String := "";
      Redirect_Hops         : Natural := 0;
      Redirect_Chain        : String := "";
      Redirect_Status_Codes : String := "";
      Redirect_Target_URLs  : String := "";
      Redirect_Locations    : String := "")
   is
   begin
      Set_Metadata
        (Bytes_Written         => Bytes_Written,
         Has_Bytes             => Has_Bytes,
         Depth                 => Depth,
         Has_Depth             => Has_Depth,
         Status_Code           => Status_Code,
         Retry_Attempt         => Retry_Attempt,
         Cache_Decision        => Cache_Decision,
         Robots_Source         => Robots_Source,
         Final_URL             => Final_URL,
         Source_ID             => Source_ID,
         Local_Path            => Local_Path,
         Redirect_Hops         => Redirect_Hops,
         Redirect_Chain        => Redirect_Chain,
         Redirect_Status_Codes => Redirect_Status_Codes,
         Redirect_Target_URLs  => Redirect_Target_URLs,
         Redirect_Locations    => Redirect_Locations);
      Emit_Progress (Progress, Event, URL);
   end Emit_Progress_Detailed;

   procedure Emit_Diagnostic
     (Progress               : Progress_Callback;
      Limits                 : Fetch_Options;
      Event                  : Progress_Event;
      URL                    : String;
      Local_Path             : String := "";
      Robots_Source_Override : String := "")
   is
      Split       : constant Natural := Reason_Start (URL);
      URL_Text    : constant String :=
        (if Split > URL'First then URL (URL'First .. Split - 1) else URL);
      Reason_Text : constant String :=
        (if Split > URL'First then URL (Split + 2 .. URL'Last - 1) else "");
      Cache_Text  : constant String := To_String (Cache_Decision_For (Event));
      Robots_Text : constant String :=
        (if Robots_Source_Override /= "" then Robots_Source_Override
         elsif Event = Progress_Robots_Loaded or else Event = Progress_Robots_Failed then URL_Text
         else To_String (Robots_Source_For (Event)));
   begin
      if Limits.Diagnostics.Mode = Diagnostics_Verbose then
         Emit_Progress_Detailed
           (Progress,
            Event,
            URL,
            Status_Code    => Status_Code_From_Reason (Reason_Text),
            Retry_Attempt  => Retry_Attempt_From_Reason (Reason_Text),
            Cache_Decision => Cache_Text,
            Robots_Source  => Robots_Text,
            Local_Path     => Local_Path);
      end if;
   end Emit_Diagnostic;

   procedure Emit_Redirected
     (Progress              : Progress_Callback;
      Current_URL           : String;
      Effective_URL         : String;
      Depth                 : Natural := 0;
      Has_Depth             : Boolean := False;
      Status_Code           : Natural := 0;
      Redirect_Hops         : Natural := 0;
      Redirect_Status_Codes : String := "";
      Redirect_Target_URLs  : String := "";
      Redirect_Locations    : String := "")
   is
      Actual_Hops : constant Natural := (if Redirect_Hops = 0 then 1 else Redirect_Hops);
      Hop_Detail  : constant String :=
        (if Redirect_Status_Codes = "" then "" else ": " & Redirect_Status_Codes);
      Chain       : constant String :=
        (if Actual_Hops = 1 then Current_URL & " -> " & Effective_URL
         else Current_URL & " --[" & Natural_Image (Actual_Hops) & " redirects"
              & Hop_Detail & "]--> " & Effective_URL);
   begin
      if Effective_URL /= Current_URL then
         Emit_Progress_Detailed
           (Progress,
            Progress_Redirected,
            Current_URL,
            Depth                 => Depth,
            Has_Depth             => Has_Depth,
            Status_Code           => Status_Code,
            Final_URL             => Effective_URL,
            Source_ID             => Current_URL,
            Redirect_Hops         => Actual_Hops,
            Redirect_Chain        => Chain,
            Redirect_Status_Codes => Redirect_Status_Codes,
            Redirect_Target_URLs  => Redirect_Target_URLs,
            Redirect_Locations    => Redirect_Locations);
      end if;
   end Emit_Redirected;

   function Structured_Record (Event : Progress_Event; Text : String) return Progress_Record is
      Split       : constant Natural := Reason_Start (Text);
      URL_Text    : constant String :=
        (if Split > Text'First then Text (Text'First .. Split - 1) else Text);
      Reason_Text : constant String :=
        (if Split > Text'First then Text (Split + 2 .. Text'Last - 1) else "");
      Metadata    : Progress_Metadata;
   begin
      Structured_Metadata.Snapshot (Metadata);
      return Progress_Record'
        (Event          => Event,
         URL            => To_Unbounded_String (URL_Text),
         Reason         => To_Unbounded_String (Reason_Text),
         Local_Path     =>
           (if Length (Metadata.Local_Path) > 0 then Metadata.Local_Path
            elsif URL_Text = "" then Null_Unbounded_String
            else To_Unbounded_String (Sitefetch.URLs.Local_Path_For_URL (URL_Text))),
         Bytes_Written  => (if Metadata.Has_Bytes then Metadata.Bytes_Written else 0),
         Depth          => (if Metadata.Has_Depth then Metadata.Depth else 0),
         Status_Code    =>
           (if Metadata.Status_Code /= 0 then Metadata.Status_Code
            else Status_Code_From_Reason (Reason_Text)),
         Retry_Attempt  =>
           (if Metadata.Retry_Attempt /= 0 then Metadata.Retry_Attempt
            else Retry_Attempt_From_Reason (Reason_Text)),
         Cache_Decision =>
           (if Length (Metadata.Cache_Decision) > 0 then Metadata.Cache_Decision
            else Cache_Decision_For (Event)),
         Robots_Source  =>
           (if Length (Metadata.Robots_Source) > 0 then Metadata.Robots_Source
            else Robots_Source_For (Event)),
         Final_URL      =>
           (if Length (Metadata.Final_URL) > 0 then Metadata.Final_URL
            else Default_Final_URL_For (Event, URL_Text)),
         Source_ID      =>
           (if Length (Metadata.Source_ID) > 0 then Metadata.Source_ID
            else Default_Source_ID),
         Redirect_Hops         => Metadata.Redirect_Hops,
         Redirect_Chain        => Metadata.Redirect_Chain,
         Redirect_Status_Codes => Metadata.Redirect_Status_Codes,
         Redirect_Target_URLs  => Metadata.Redirect_Target_URLs,
         Redirect_Locations    => Metadata.Redirect_Locations);
   end Structured_Record;

   procedure Set_Structured_Progress (Progress : Structured_Progress_Callback) is
   begin
      Current_Structured_Progress := Progress;
   end Set_Structured_Progress;

   procedure Clear_Structured_Progress is
   begin
      Current_Structured_Progress := null;
   end Clear_Structured_Progress;

   procedure Structured_Progress_Adapter (Event : Progress_Event; URL : String) is
   begin
      if Current_Structured_Progress /= null then
         Current_Structured_Progress (Structured_Record (Event, URL));
      end if;
   end Structured_Progress_Adapter;

   procedure Begin_Redirect_Request is
   begin
      Redirect_Diagnostics.Begin_Request;
   end Begin_Redirect_Request;

   procedure Snapshot_And_Clear_Redirects
     (Status_Codes : out Unbounded_String;
      Target_URLs  : out Unbounded_String;
      Locations    : out Unbounded_String) is
   begin
      Redirect_Diagnostics.Snapshot_And_Clear (Status_Codes, Target_URLs, Locations);
   end Snapshot_And_Clear_Redirects;

   procedure Redirect_Diagnostics_Observer
     (Event  : Http_Client.Diagnostics.Diagnostic_Event;
      Status : out Http_Client.Errors.Result_Status)
   is
      use type Http_Client.Diagnostics.Event_Kind;
   begin
      Status := Http_Client.Errors.Ok;
      if Event.Kind = Http_Client.Diagnostics.Redirect_Decision then
         declare
            Message_Text : constant String := Http_Client.Diagnostics.Text (Event.Message);
            Break_Pos    : Natural := 0;
            Target_URL   : Unbounded_String := To_Unbounded_String (Message_Text);
            Location     : Unbounded_String :=
              To_Unbounded_String (Http_Client.Diagnostics.Text (Event.Header_Value));
         begin
            for Index_Value in Message_Text'Range loop
               if Message_Text (Index_Value) = Character'Val (10) then
                  Break_Pos := Index_Value;
                  exit;
               end if;
            end loop;

            if Break_Pos > Message_Text'First then
               Target_URL := To_Unbounded_String (Message_Text (Message_Text'First .. Break_Pos - 1));
               if Length (Location) = 0 and then Break_Pos < Message_Text'Last then
                  Location := To_Unbounded_String (Message_Text (Break_Pos + 1 .. Message_Text'Last));
               end if;
            end if;

            Redirect_Diagnostics.Record_Hop
              (Event.Status_Code, To_String (Target_URL), To_String (Location));
         end;
      end if;
   end Redirect_Diagnostics_Observer;
end Sitefetch.Engine.Diagnostics;
