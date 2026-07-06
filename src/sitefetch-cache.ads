--  Support level: stable production API.
--
--  Cache mode, freshness, Vary, resource strategy, and integrity policy aliases.

package Sitefetch.Cache is
   subtype Policy is Cache_Policy;
   subtype Mode is Cache_Mode;
   subtype Resource_Strategy is Cache_Resource_Strategy;
   subtype Hash_Algorithm is Cache_Hash_Algorithm;
   subtype Vary_Allow_List is Cache_Vary_Allow_List;

   Ignore     : constant Mode := Cache_Ignore;
   Revalidate : constant Mode := Cache_Revalidate;
   Refresh    : constant Mode := Cache_Refresh;
   Offline    : constant Mode := Cache_Offline;

   All_Resources  : constant Resource_Strategy := Cache_All_Resources;
   Documents_Only : constant Resource_Strategy := Cache_Documents_Only;
   Downloads_Only : constant Resource_Strategy := Cache_Downloads_Only;

   FNV1a_64 : constant Hash_Algorithm := Cache_Hash_FNV1a_64;
   SHA256   : constant Hash_Algorithm := Cache_Hash_SHA256;
   No_Hash  : constant Hash_Algorithm := Cache_Hash_None;

   Default : constant Policy := (others => <>);
end Sitefetch.Cache;
