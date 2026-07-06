--  Support level: stable production API.
--
--  Crawl and domain policy aliases for applications that want a focused
--  import instead of taking every policy name from the root Sitefetch package.

package Sitefetch.Crawl is
   subtype Policy is Crawl_Policy;
   subtype Domain_Mode is Domain_Policy;
   subtype Robots_Mode is Robots_Policy;
   subtype Robots_Failure_Mode is Robots_Failure_Policy;

   Default_Workers : constant Positive := Default_Worker_Count;
   Max_Workers     : constant Positive := Max_Worker_Count;

   Exact_And_Subdomains : constant Domain_Mode := Domain_Exact_And_Subdomains;
   Include_Parents      : constant Domain_Mode := Domain_Include_Parents;

   Ignore_Robots  : constant Robots_Mode := Robots_Ignore;
   Respect_Robots : constant Robots_Mode := Robots_Respect;

   Robots_Open_On_Failure   : constant Robots_Failure_Mode := Robots_Fail_Open;
   Robots_Closed_On_Failure : constant Robots_Failure_Mode := Robots_Fail_Closed;

   Default : constant Policy := (others => <>);
end Sitefetch.Crawl;
