--  Support level: public support API.
--
--  This child package exposes the reusable Http_Client configuration used by
--  sitefetchlib. It is intended for callers that deliberately want matching
--  HTTP client defaults. Sitefetch.Crawler remains the stable
--  production crawler API.

with Http_Client.Clients;

package Sitefetch.Client_Config is
   --  Return the reusable HTTP client configuration used by sitefetch downloads.
   --
   --  @param User_Agent Optional User-Agent header value. Empty leaves the
   --         Http_Client default unchanged.
   --  @return Client configuration with connection reuse enabled and HTTP/2 preferred.
   function Reusable_Configuration
     (User_Agent : String := "") return Http_Client.Clients.Client_Configuration;
end Sitefetch.Client_Config;
