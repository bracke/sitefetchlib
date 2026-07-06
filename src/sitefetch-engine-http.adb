with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Http_Client.Clients;
with Http_Client.Decompression;
with Http_Client.Errors;
with Http_Client.Retry;
with Http_Client.Responses;
with Http_Client.URI;

with Sitefetch.Content;
with Sitefetch.Engine.Robots;

package body Sitefetch.Engine.HTTP is
   use Ada.Strings.Unbounded;
   use Sitefetch.Content;

   function Response_From_Client_Result
     (Result : Http_Client.Clients.Client_Result) return Http_Client.Responses.Response is
   begin
      if Result.Used_Decoded_View then
         return Http_Client.Decompression.Original_Response (Result.Decoded_Response);
      else
         return Result.Response;
      end if;
   end Response_From_Client_Result;

   function Retry_Options_For (Limits : Fetch_Options) return Http_Client.Retry.Retry_Options is
      Attempts : constant Positive :=
        (if Limits.HTTP.Max_Retries >= Positive'Last - 1
         then Positive'Last
         else Positive (Limits.HTTP.Max_Retries + 1));
   begin
      return
        (Enable_Retries              => Limits.HTTP.Max_Retries > 0,
         Maximum_Attempts            => Attempts,
         Retry_Connect_Failures      => True,
         Retry_Read_Failures         => True,
         Retry_Write_Failures        => True,
         Retry_Timeouts              => True,
         Retry_5xx_Responses         => Limits.HTTP.Retry_HTTP_Statuses,
         Retry_429                   => Limits.HTTP.Retry_HTTP_Statuses,
         Retry_425                   => Limits.HTTP.Retry_HTTP_Statuses,
         Retry_408                   => Limits.HTTP.Retry_HTTP_Statuses,
         Base_Delay                  => Limits.HTTP.Retry_Delay_MS,
         Maximum_Delay               => Natural'Last,
         Backoff                     => Http_Client.Retry.Exponential_Delay,
         Respect_Retry_After         => False,
         Maximum_Retry_After         => 60_000,
         Allow_Non_Idempotent_Retry  => False,
         Retry_Transient_TLS_Failure => True,
         Delay_Hook                  => null);
   end Retry_Options_For;

   function Retry_Jitter_Milliseconds
     (Limits : Fetch_Options; Retry_Number : Positive; URL : String) return Natural
   is
      Hash_Value : Natural := Retry_Number;
   begin
      if Limits.HTTP.Retry_Jitter_MS = 0 then
         return 0;
      end if;

      for Item of URL loop
         Hash_Value := (Hash_Value * 33 + Character'Pos (Item)) mod (Limits.HTTP.Retry_Jitter_MS + 1);
      end loop;

      return Hash_Value;
   end Retry_Jitter_Milliseconds;

   function Retry_Delay_Milliseconds
     (Limits : Fetch_Options; Retry_Number : Positive; URL : String) return Natural
   is
      Base   : constant Natural :=
        Http_Client.Retry.Delay_For_Attempt (Retry_Number, Retry_Options_For (Limits));
      Jitter : constant Natural := Retry_Jitter_Milliseconds (Limits, Retry_Number, URL);
   begin
      if Base > Natural'Last - Jitter then
         return Natural'Last;
      else
         return Base + Jitter;
      end if;
   end Retry_Delay_Milliseconds;

   procedure Delay_Before_Retry (Limits : Fetch_Options; Retry_Number : Positive; URL : String) is
      Milliseconds : constant Natural := Retry_Delay_Milliseconds (Limits, Retry_Number, URL);
   begin
      if Milliseconds > 0 then
         delay Duration (Long_Float (Milliseconds) / 1000.0);
      end if;
   end Delay_Before_Retry;

   function Retryable_HTTP_Status (Limits : Fetch_Options; Status : Http_Client.Types.Status_Code) return Boolean is
   begin
      return Http_Client.Retry.Is_Retryable_Status_Code (Status, Retry_Options_For (Limits));
   end Retryable_HTTP_Status;

   function Retryable_HTTP_Failure
     (Limits : Fetch_Options; Status : Http_Client.Errors.Result_Status) return Boolean is
   begin
      return Http_Client.Retry.Is_Retryable_Failure (Status, Retry_Options_For (Limits));
   end Retryable_HTTP_Failure;

   function Natural_Image (Value : Natural) return String is
   begin
      return Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Left);
   end Natural_Image;

   function HTTP_Status_Reason (Status : Http_Client.Types.Status_Code) return String is
   begin
      return "HTTP_" & Natural_Image (Natural (Status));
   end HTTP_Status_Reason;

   procedure Delay_Before_Request (URL : String; Limits : Fetch_Options) is
      Wait_Seconds : Duration := 0.0;
   begin
      Sitefetch.Engine.Robots.Reserve_Request_Delay (URL, Limits, Wait_Seconds);
      if Wait_Seconds > 0.0 then
         delay Wait_Seconds;
      end if;
   end Delay_Before_Request;

   function HTTP_Probe_Download_Decision
     (Item            : Http_Client.Clients.Client;
      URL             : String;
      Effective_URL   : out Unbounded_String;
      Should_Download : out Boolean;
      Limits          : Fetch_Options) return Boolean
   is
      use type Http_Client.Errors.Result_Status;

      Result : Http_Client.Clients.Client_Result;
      Status : Http_Client.Errors.Result_Status;
      Media  : Unbounded_String := Null_Unbounded_String;
   begin
      Effective_URL := Null_Unbounded_String;
      Should_Download := False;

      Delay_Before_Request (URL, Limits);
      Status := Http_Client.Clients.Head (Item, URL, Result);
      if Status /= Http_Client.Errors.Ok then
         return False;
      end if;

      Effective_URL := To_Unbounded_String (Http_Client.URI.Image (Result.Final_URI));
      if Length (Effective_URL) = 0 then
         Effective_URL := To_Unbounded_String (URL);
      end if;

      Media := To_Unbounded_String (Http_Client.Responses.Media_Type (Result.Response));
      Should_Download := Should_Download_To_File (To_String (Effective_URL))
        or else (Length (Media) > 0
                 and then not Should_Parse_Content_Type (To_String (Media)));

      return Should_Download or else To_String (Effective_URL) /= URL;
   end HTTP_Probe_Download_Decision;

end Sitefetch.Engine.HTTP;
