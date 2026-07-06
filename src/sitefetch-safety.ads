--  Support level: stable production API.
--
--  File safety and write-durability policy aliases.

package Sitefetch.Safety is
   subtype Policy is Safety_Policy;
   subtype Mode is Safety_Mode;
   subtype Durability_Mode is Write_Durability_Mode;

   Default_Mode     : constant Mode := Safety_Default;
   Skip_Dangerous   : constant Mode := Safety_Skip_Dangerous;
   Assets_Only_Safe : constant Mode := Safety_Assets_Only_Safe;

   Default_Durability       : constant Durability_Mode := Write_Durability_Default;
   Flush_Temp_File          : constant Durability_Mode := Write_Durability_Flush_Temp_File;
   Sync_Data_And_Directory  : constant Durability_Mode := Write_Durability_Sync_Data_And_Directory;

   Default : constant Policy := (others => <>);
end Sitefetch.Safety;
