--  Support level: stable production API.
--
--  Diagnostics policy aliases for embedded callers.

package Sitefetch.Diagnostics is
   subtype Policy is Diagnostics_Policy;
   subtype Mode is Diagnostics_Mode;

   Quiet   : constant Mode := Diagnostics_Quiet;
   Verbose : constant Mode := Diagnostics_Verbose;

   Default : constant Policy := (others => <>);
end Sitefetch.Diagnostics;
