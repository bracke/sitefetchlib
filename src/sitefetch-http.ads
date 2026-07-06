--  Support level: stable production API.
--
--  HTTP retry, request pacing, User-Agent, and HEAD-probe policy aliases.

package Sitefetch.HTTP is
   subtype Policy is HTTP_Policy;
   subtype Head_Mode is Head_Policy;

   Probe_Page_Like      : constant Head_Mode := Head_Page_Like;
   Probe_Ambiguous_Only : constant Head_Mode := Head_Ambiguous_Only;
   Disable_Head         : constant Head_Mode := Head_Disabled;

   Default_User_Agent_Text : constant String := Default_User_Agent;
   Default : constant Policy := (others => <>);
end Sitefetch.HTTP;
