# sitefetchlib API

This document summarizes the public API surface for applications embedding `sitefetchlib`.
The package specs remain the source of truth for exact type and subprogram declarations.

## Support Levels

- `Sitefetch`: stable production records and shared result/configuration types.
- `Sitefetch.Crawler`: stable production crawler entry points for new embedded callers.
- `Sitefetch.Crawl`, `Sitefetch.HTTP`, `Sitefetch.Cache`, `Sitefetch.Safety`, and
  `Sitefetch.Diagnostics`: focused stable production policy packages.
- `Sitefetch.Client_Config`: public support API for callers that want the same reusable
  `Http_Client` defaults as sitefetchlib.
- `Sitefetch.URLs` and `Sitefetch.Content`: public support helper packages for URL normalization,
  local path mapping, and content/MIME classification. The root `Sitefetch` helper functions use
  these packages.
- `Sitefetch.Domains`: public support API for callers that need sitefetchlib's current host and
  crawl-boundary helper behavior. It validates ASCII host labels and IP literals, rejects raw
  non-ASCII or malformed host text, and is not a general-purpose domain policy library.
- `Sitefetch.Testing`: testing and fixture API for deterministic tests and injected fetch adapters.
  It is not the production embedding surface.
- `Sitefetch.Documents`: private helper package for link extraction and document rewriting because
  `Link_List` remains a root-private representation detail. Use root helpers for that behavior.
- `Sitefetch.Engine`: private internal crawl engine behind production and testing adapters. It
  no longer owns URL/content/document helper implementations and may change freely.

## Stable Production Packages

New embedded callers should import the focused crawler and policy packages:

```ada
with Sitefetch;
with Sitefetch.Cache;
with Sitefetch.Crawl;
with Sitefetch.Crawler;
```

Primary entry points:

- `Sitefetch.Crawler.Fetch_Website`: fetches a bounded website mirror into a target directory.
- `Sitefetch.Crawler.Fetch_Website_With_Structured_Progress`: same production crawl path with structured
  progress records.


Primary configuration and result types:

- `Sitefetch.Fetch_Options`
- `Sitefetch.Crawl.Policy`
- `Sitefetch.HTTP.Policy`
- `Sitefetch.Cache.Policy`
- `Sitefetch.Safety.Policy`
- `Sitefetch.Diagnostics.Policy`
- `Sitefetch.Fetch_Statistics`
- `Sitefetch.Progress_Callback`
- `Sitefetch.Structured_Progress_Callback`

Support helper packages and root helper functions:

- `Sitefetch.URLs` is the public support package for URL normalization, crawl-boundary checks,
  resolution, canonicalization, and mirror local-path mapping. Root helpers such as
  `Sitefetch.Ensure_HTTP_Scheme`, `Domain_Of`, `Resolve_URL`, `Canonical_URL`, and
  `Local_Path_For_URL` delegate there.
- `Sitefetch.Content` is the public support package for URL extension and MIME/content
  classification. Root helpers such as `Sitefetch.Is_Dangerous_File_Type`,
  `Is_Safe_Asset_File_Type`, `Should_Download_To_File`, and `Should_Parse_Content_Type` delegate
  there.
- `Sitefetch.Extract_Links` and `Rewrite_Document` delegate to private `Sitefetch.Documents`; the
  package stays private so callers do not depend on `Link_List` internals.

## Basic Call Pattern

```ada
with Sitefetch;
with Sitefetch.Cache;
with Sitefetch.Crawl;
with Sitefetch.Crawler;

procedure Mirror is
   Statistics : Sitefetch.Fetch_Statistics;
   Options    : Sitefetch.Fetch_Options := Sitefetch.Default_Fetch_Options;
   Success    : Boolean;
begin
   Options.Crawl.Max_Pages := 250;
   Options.Crawl.Max_Depth := 4;
   Options.Crawl.Robots := Sitefetch.Crawl.Respect_Robots;
   Options.Cache.Mode := Sitefetch.Cache.Revalidate;

   Success := Sitefetch.Crawler.Fetch_Website
     (URL              => "https://example.com/",
      Target_Directory => "mirror",
      Statistics       => Statistics,
      Options          => Options);

   if not Success then
      -- Inspect Statistics.Failed_Downloads for per-URL failure details.
      null;
   end if;
end Mirror;
```

A checked version of this pattern lives in `examples/basic_mirror`. It compiles and runs without
network work by default; set `SITEFETCHLIB_RUN_EXAMPLE=1` to run the mirror intentionally.
`examples/structured_progress` demonstrates `Fetch_Website_With_Structured_Progress` with the same
network-free default. Callbacks passed as `Structured_Progress_Callback` should be library-level or
otherwise live at a compatible accessibility level; the checked example uses a package-level
callback for this reason. `examples/url_content_helpers` is an offline checked example for the
`Sitefetch.URLs` and `Sitefetch.Content` helper packages.

## URL and Content Helpers

`Sitefetch.URLs` and `Sitefetch.Content` are public support packages for callers that need the same
normalization and classification rules as the crawler. They are useful for preflight checks,
external queues, or applications that want to store crawler-compatible local paths before invoking a
mirror run.

```ada
with Sitefetch;
with Sitefetch.Content;
with Sitefetch.URLs;

procedure Classify_Resource is
   Root       : constant String := "https://example.com/docs/";
   Reference  : constant String := "../assets/manual.pdf#download";
   Resolved   : constant String := Sitefetch.URLs.Resolve_URL (Root, Reference);
   Canonical  : constant String := Sitefetch.URLs.Canonical_URL (Resolved);
   Local_Path : constant String := Sitefetch.URLs.Local_Path_For_URL (Canonical);
   In_Scope   : constant Boolean :=
     Sitefetch.URLs.Is_In_Domain
       (Root_Domain => Sitefetch.URLs.Domain_Of (Root),
        Candidate   => Sitefetch.URLs.Domain_Of (Canonical),
        Policy      => Sitefetch.Domain_Exact_And_Subdomains);
   Store_As_File : constant Boolean := Sitefetch.Content.Should_Download_To_File (Canonical);
begin
   if In_Scope and then Store_As_File then
      -- Local_Path is the same mirror-relative path shape used by sitefetchlib.
      null;
   end if;
end Classify_Resource;
```

Use `Canonical_URL` before deduplicating queue entries, `Resolve_URL` before applying crawl-scope
checks to document references, and `Local_Path_For_URL` when external code needs paths compatible
with sitefetchlib's rewritten links. `Sitefetch.Domains` remains the documented boundary for the
underlying host policy; the URL helpers expose the crawler-facing convenience layer.
For callers that already have normalized ASCII host text, `Sitefetch.Domains` also exposes `Public_Suffix_For_Normalized_Host`, `Registrable_Domain_For_Normalized_Host`, and `Is_Internal_Host`. These helpers are the SPARK-enabled deterministic host-policy core; parser-backed wrappers such as `Normalized_Host` and `Is_Internal` remain ordinary Ada because they depend on URL parsing and host validation helpers.


For response bodies, classify with both URL and content-type information when available:

```ada
if Sitefetch.Content.Should_Parse_Content_Type ("text/html; charset=utf-8") then
   -- Buffer as text and extract/rewrite links.
   null;
elsif Sitefetch.Content.Should_Download_To_File ("https://example.com/report.pdf") then
   -- Treat as a passive downloaded resource.
   null;
end if;
```

`Should_Parse_Content_Type` treats missing content type as parseable for compatibility, accepts text,
JSON/XML, and SVG-style structured media types, and rejects known passive binary media such as PDFs,
images, audio, video, and fonts. `Should_Download_To_File` is URL-extension based and is best used as
a fallback or preflight rule when response headers are not available yet.

## Compression Boundary

`HttpClient` owns HTTP `Content-Encoding` decompression for production requests, including gzip,
deflate, decoded-body limits, malformed compressed bodies, and streaming decoded reads.
`sitefetchlib` configures that behavior through HttpClient client configuration and uses decoded
responses after transport handling.

`sitefetchlib` owns crawler-level compression policy: the `Accept-Encoding` request value,
`Vary: Accept-Encoding` cache validation, and gzip sitemap-resource inflation for files such as
`sitemap.xml.gz`. Gzip sitemap inflation is resource parsing, not HTTP transport decompression.

## Cache Policy

`Sitefetch.Cache.Policy` is the stable policy surface for incremental mirror cache behavior. Cache
metadata lives beside mirrored files as `.sitefetch_http_cache` sidecars; callers should configure
policy through `Fetch_Options.Cache` instead of editing sidecars.

Cache modes have these contracts:

- `Cache_Ignore`: no sidecar reads or writes.
- `Cache_Revalidate`: read and write sidecars; reuse fresh valid entries, conditionally revalidate
  stale entries with validators, and refresh stale entries without validators.
- `Cache_Refresh`: bypass existing sidecars for reuse, fetch from the network, and write fresh
  metadata.
- `Cache_Offline`: use only fresh valid local entries; fail resources whose sidecar or local file is
  missing, stale, locally corrupt, rejected by metadata version policy, or rejected by `Vary`.

Freshness is based on `Cache-Control` and `Expires`, with `Max_Stale_MS` allowing bounded stale reuse
where HTTP cache directives permit it. `Resource_Strategy` selects whether cache metadata applies to
all resources, documents only, or downloads only.

Integrity checks compare cached local files to persisted `Local-Size` and, unless disabled,
`Local-Hash`. `Verify_Local_Content` is enabled by default. `Hash_Algorithm` chooses FNV1a-64,
SHA-256, or no hash; no-hash mode still allows size-only verification. `Require_Metadata_Version`
can enforce the current sidecar metadata version for stricter invalidation.

`Vary_Allow` accepts only explicitly supported request fields. `User-Agent`, `Accept-Language`, and
`Accept-Encoding` are compared against the values persisted in the sidecar when those fields appear
in `Vary`; `Vary: *` and unsupported fields are rejected.

## Cache Diagnostics

Structured progress records expose cache decisions with `Progress_Cache_Reused`,
`Progress_Cache_Revalidate`, and `Progress_Cache_Rejected`. `Progress_Record.Cache_Decision` carries
`reused`, `revalidate`, or `rejected` for those events; `Progress_Record.Reason` carries rejection
text when available. Common rejection reasons include missing cache sidecars/files, local size or
hash mismatches, metadata version mismatches, rejected or changed `Vary` request headers, stale
entries without validators, offline missing or stale entries, unreadable cached files, and
partial-only offline download entries that cannot be resumed.

The sibling CLI maps these structured fields to JSONL `cache_decision`, final summary counters
`cache_hits`, `cache_revalidations`, and `cache_rejections`, and a final summary
`cache_rejection_reasons` object mapping each rejection reason string to its count. The object is
`{}` when no cache rejections were reported. The CLI crate owns the machine-readable JSON output
compatibility contract; see `../sitefetch/README.md` for JSONL ordering, summary field stability,
and the complete final summary field list.

## Cache Sidecars

The `.sitefetch_http_cache` files written next to mirrored resources are internal cache metadata,
not a stable public serialization format. They may contain response validators, freshness headers,
`Vary` request metadata, final URL, content length/type, resume-safety information, and local
size/hash integrity fields. Use the `Sitefetch.Cache.Policy` options to control cache behavior
instead of relying on sidecar contents. Sidecar fields may change across releases.

## Public API Smoke Test

`public_api_smoke` is a downstream-style compile smoke crate. It depends on `sitefetchlib` and
imports the stable root, crawler, and focused policy packages. It exists to catch accidental API drift toward CLI or
fixture-only packages.

## Full Split Validation

From the sibling CLI checkout:

```sh
cd ../sitefetch
alr build
./bin/check_split
```

That script builds the CLI crate, library crate, both test suites, `public_api_smoke`, and every
checked example crate discovered under `examples/*/alire.toml`. It may recreate
ignored generated directories such as `alire/`, `config/`, `bin/`, `obj/`, and `lib/`; remove those
safely when stale generated output pollutes searches, then rerun the validation command.

Checked examples follow a small convention enforced by the docs and split checkers: each example is
a direct child of `examples/`, contains an `alire.toml`, declares exactly one executable with
`executables = ["..."]`, run without network or mirror filesystem work by default, and is mentioned
in this API guide. Examples that need real crawling should guard it behind an explicit environment
variable or similar opt-in.
