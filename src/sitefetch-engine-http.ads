with Ada.Strings.Unbounded;

with Http_Client.Clients;
with Http_Client.Errors;
with Http_Client.Responses;
with Http_Client.Retry;
with Http_Client.Types;

--  Support level: private internal implementation.
--
--  HTTP transport support helpers for retry/backoff, request pacing, response
--  normalization, and HEAD probing. Full fetch/download orchestration remains
--  in Sitefetch.Engine while cache/write concerns are still engine-owned.

private package Sitefetch.Engine.HTTP is
   function Response_From_Client_Result
     (Result : Http_Client.Clients.Client_Result) return Http_Client.Responses.Response;

   function Retry_Options_For (Limits : Fetch_Options) return Http_Client.Retry.Retry_Options;

   procedure Delay_Before_Retry (Limits : Fetch_Options; Retry_Number : Positive; URL : String);

   function Retryable_HTTP_Status (Limits : Fetch_Options; Status : Http_Client.Types.Status_Code) return Boolean;

   function Retryable_HTTP_Failure
     (Limits : Fetch_Options; Status : Http_Client.Errors.Result_Status) return Boolean;

   function HTTP_Status_Reason (Status : Http_Client.Types.Status_Code) return String;

   procedure Delay_Before_Request (URL : String; Limits : Fetch_Options);

   function HTTP_Probe_Download_Decision
     (Item            : Http_Client.Clients.Client;
      URL             : String;
      Effective_URL   : out Ada.Strings.Unbounded.Unbounded_String;
      Should_Download : out Boolean;
      Limits          : Fetch_Options) return Boolean;
end Sitefetch.Engine.HTTP;
