with Http_Client.Connection_Pools;
with Http_Client.Errors;
with Http_Client.Headers;

package body Sitefetch.Client_Config is
   Max_In_Memory_Response_Bytes : constant Natural := 128 * 1_024 * 1_024;

   function Reusable_Configuration
     (User_Agent : String := "") return Http_Client.Clients.Client_Configuration
   is
      Configuration : Http_Client.Clients.Client_Configuration :=
        Http_Client.Clients.Default_Client_Configuration;
   begin
      Configuration.Pooling := Http_Client.Connection_Pools.Default_Pooling_Options;
      Configuration.Pooling.Enabled := True;
      Configuration.Execution.Protocol_Policy := Http_Client.Clients.Prefer_HTTP_2;
      Configuration.Execution.Max_Response_Size := Max_In_Memory_Response_Bytes;
      Configuration.Execution.Max_Body_Size := Max_In_Memory_Response_Bytes;
      Configuration.Decompression.Maximum_Decoded_Body_Size := Max_In_Memory_Response_Bytes;
      if User_Agent /= "" then
         declare
            Ignored : constant Http_Client.Errors.Result_Status :=
              Http_Client.Headers.Set
                (Configuration.Default_Headers, "User-Agent", User_Agent);
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
      end if;
      return Configuration;
   end Reusable_Configuration;
end Sitefetch.Client_Config;
