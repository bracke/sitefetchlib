--  Support level: public support API.
--
--  This child package exposes sitefetchlib's host-normalization and crawl
--  boundary helpers. It documents and tests sitefetchlib's current host/public
--  suffix behavior, but it is narrower than the Sitefetch.Crawler API and
--  is not a general-purpose domain policy library. Host matching is based on
--  URL-parser normalization, exact host equality, dot-boundary suffix checks,
--  ASCII host-label validation, and an embedded common public-suffix table; it
--  is not full PSL or IDNA policy. Raw non-ASCII host text is rejected instead
--  of being implicitly IDNA-normalized. Callers that need broad web-crawler
--  isolation should layer a dedicated domain/public-suffix component above this
--  package.

package Sitefetch.Domains is
   --  Return the normalized host used by sitefetch domain policy, or an empty
   --  string when the parsed host is not a valid ASCII DNS name or IP literal.
   --  This package does not convert Unicode host text to punycode; callers that
   --  need IDNA behavior should provide normalized ASCII/punycode hosts.
   function Normalized_Host (URL : String) return String;

   --  Return the public suffix for an already normalized host.
   --
   --  Host must be lower-case ASCII host text already accepted by the URL host
   --  validator. This helper is SPARK-enabled so the deterministic suffix table
   --  logic can be checked separately from URL parsing and host validation.
   function Public_Suffix_For_Normalized_Host (Host : String) return String
     with SPARK_Mode => On;

   --  Return the registrable domain for an already normalized host.
   --
   --  Host must be lower-case ASCII host text already accepted by the URL host
   --  validator. Literal IP hosts, public suffixes, and single-label roots
   --  return an empty string.
   function Registrable_Domain_For_Normalized_Host (Host : String) return String
     with SPARK_Mode => On;

   --  Test whether Candidate_Host is inside Root_Host under Policy.
   --
   --  Both inputs must be normalized ASCII DNS host names. IP-like host text
   --  is treated as exact-only. This is the SPARK-enabled
   --  host-policy core used by Is_Internal after URL parsing and validation.
   function Is_Internal_Host
     (Root_Host     : String;
      Candidate_Host : String;
      Policy        : Domain_Policy := Domain_Exact_And_Subdomains) return Boolean
     with SPARK_Mode => On;

   --  Return the public suffix for Host using sitefetch's embedded common-rule table.
   --  Literal IP hosts are terminal and return themselves. The table covers common
   --  multi-label and hosted-service suffixes; unknown names fall back to the last label.
   --  This is a crawl-boundary heuristic, not a complete Mozilla PSL snapshot.
   function Public_Suffix (Host : String) return String;

   --  Return the registrable domain for Host, or an empty string when Host is
   --  a literal IP, itself a public suffix, or cannot be split into suffix plus
   --  registrable label.
   function Registrable_Domain (Host : String) return String;

   --  Test whether Candidate_URL is inside Root_Host under Policy.
   --  Subdomain traversal is enabled only when Root_Host has a registrable
   --  domain; public-suffix, hosted-service suffix, IP literal, and single-label
   --  roots are exact-only. Parent-domain traversal is capped at Root_Host's
   --  registrable domain.
   function Is_Internal
     (Root_Host     : String;
      Candidate_URL : String;
      Policy        : Domain_Policy := Domain_Exact_And_Subdomains) return Boolean;
end Sitefetch.Domains;
