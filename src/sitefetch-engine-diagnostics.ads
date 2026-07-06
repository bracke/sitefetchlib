with Ada.Strings.Unbounded;

with Http_Client.Diagnostics;
with Http_Client.Errors;

--  Support level: private internal implementation.
--
--  Structured progress metadata and redirect diagnostic state for the crawl
--  engine. The engine remains responsible for deciding which events to emit.

private package Sitefetch.Engine.Diagnostics is
   function Reason_Start (Text : String) return Natural;

   function Retry_Attempt_From_Reason (Reason : String) return Natural;

   function Status_Code_From_Reason (Reason : String) return Natural;

   function Cache_Decision_For (Event : Progress_Event)
     return Ada.Strings.Unbounded.Unbounded_String;

   function Robots_Source_For (Event : Progress_Event)
     return Ada.Strings.Unbounded.Unbounded_String;

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
      Redirect_Locations    : String := "");

   procedure Clear_Metadata;

   procedure Emit_Progress
     (Progress : Progress_Callback;
      Event    : Progress_Event;
      URL      : String);

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
      Redirect_Locations    : String := "");

   procedure Emit_Diagnostic
     (Progress               : Progress_Callback;
      Limits                 : Fetch_Options;
      Event                  : Progress_Event;
      URL                    : String;
      Local_Path             : String := "";
      Robots_Source_Override : String := "");

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
      Redirect_Locations    : String := "");

   function Structured_Record (Event : Progress_Event; Text : String) return Progress_Record;

   procedure Set_Structured_Progress (Progress : Structured_Progress_Callback);

   procedure Clear_Structured_Progress;

   procedure Structured_Progress_Adapter (Event : Progress_Event; URL : String);

   procedure Begin_Redirect_Request;

   procedure Snapshot_And_Clear_Redirects
     (Status_Codes : out Ada.Strings.Unbounded.Unbounded_String;
      Target_URLs  : out Ada.Strings.Unbounded.Unbounded_String;
      Locations    : out Ada.Strings.Unbounded.Unbounded_String);

   procedure Redirect_Diagnostics_Observer
     (Event  : Http_Client.Diagnostics.Diagnostic_Event;
      Status : out Http_Client.Errors.Result_Status);
end Sitefetch.Engine.Diagnostics;
