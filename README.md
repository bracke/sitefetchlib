# sitefetchlib

`sitefetchlib` is the reusable Ada library crate behind the `sitefetch` command-line program. It
contains the crawler, URL/domain policy, link extraction, document rewriting, direct-download,
robots, retry, cache, diagnostics, and write-safety behavior.

The sibling `sitefetch` crate is the CLI wrapper. See `../sitefetch/README.md` for command-line
usage, localized terminal output, summaries, and cross-crate validation.

## Stable API

For a focused embedding reference, see `docs/API.md`.

The stable production API is split between the root `Sitefetch` records and focused child packages:

- `Sitefetch.Crawler.Fetch_Website` fetches a bounded website mirror into a target directory.
- `Sitefetch.Crawler.Fetch_Website_With_Structured_Progress` reports progress through structured records.
- `Sitefetch.Fetch_Options` groups crawl, HTTP, cache, safety, and diagnostics policy records.
- `Sitefetch.Crawl`, `Sitefetch.HTTP`, `Sitefetch.Cache`, `Sitefetch.Safety`, and `Sitefetch.Diagnostics` expose focused policy aliases and constants.
- `Sitefetch.Fetch_Statistics` reports attempts, writes, bytes, skips, failures, and failed URLs.


Support levels:

- `Sitefetch`: stable production records and shared result/configuration types for embedders.
- `Sitefetch.Crawler`: stable production crawler entry points.
- `Sitefetch.Crawl`, `Sitefetch.HTTP`, `Sitefetch.Cache`, `Sitefetch.Safety`, and
  `Sitefetch.Diagnostics`: stable production policy packages.
- `Sitefetch.Client_Config`: public support API for callers that want sitefetchlib's reusable
  `Http_Client` defaults.
- `Sitefetch.URLs` and `Sitefetch.Content`: public support helper packages that own URL
  normalization/local-path mapping and content/MIME classification used by the root helper
  functions and the crawler engine.
- `Sitefetch.Domains`: public support API for callers that need sitefetchlib's current host and
  crawl-boundary helpers. It uses normalized hosts, dot-boundary matching, and an embedded common
  public-suffix table; it is not a full PSL/IDNA domain policy library.
- `Sitefetch.Testing`: testing and fixture API for deterministic tests and injected fetch adapters;
  not the production embedding surface.
- `Sitefetch.Documents`: private helper package for link extraction and document rewriting because
  `Link_List` remains a root-private representation detail. Use the root `Sitefetch.Extract_Links`
  and `Sitefetch.Rewrite_Document` helpers instead of importing it directly.
- `Sitefetch.Engine`: private internal crawl orchestration used behind production and testing entry
  points. It no longer owns URL/content/document helper implementations; unsupported for consumers
  and free to change.

## Depending On It

For a local checkout next to an application crate, add `sitefetchlib` to `alire.toml`:

```toml
[[depends-on]]
sitefetchlib = "*"

[[pins]]
sitefetchlib = { path = "../sitefetchlib" }
```

When the crate is published to an index, the `[[pins]]` entry can be removed and Alire can resolve
`sitefetchlib` normally.

## Toolchain

Every active crate manifest pins GNAT 15 through Alire:

```toml
[[depends-on]]
gnat_native = "=15.2.1"
```

Do not run plain system GNAT, GPRBuild, GNATprove, GNATdoc, or related `gnat*`
tools from `PATH`. Build, prove, and inspect the compiler through Alire so the
pinned toolchain is selected:

```sh
alr exec -- gnatls --version
alr exec -- gprbuild -P sitefetchlib.gpr
alr exec -- gnatprove -P sitefetchlib.gpr --level=4
```

The version command must report `GNATLS 15.x`. The `check_sitefetchlib` release
checker enforces this and verifies that the root crate, release template, test
crates, public API smoke crate, and checked examples keep the exact
`gnat_native = "=15.2.1"` dependency.

## Domain Policy

`Sitefetch.Domains` is the documented support boundary for host checks used by the crawler. The
policy treats exact hosts and dot-boundary subdomains as internal, treats literal IP and single-label
roots as exact-only, and uses an embedded common public-suffix table to avoid crossing into suffix
roots such as `co.uk` or hosted-service boundaries such as `github.io`.

This is intentionally a crawler heuristic, not a complete domain-isolation layer. It is not a
vendored full Public Suffix List snapshot, and it does not perform Unicode-to-punycode IDNA
conversion. Raw non-ASCII host text and malformed DNS labels are rejected for crawl-boundary checks;
punycode host labels are matched as ordinary normalized ASCII labels.

When callers already have normalized ASCII host text, use `Public_Suffix_For_Normalized_Host`, `Registrable_Domain_For_Normalized_Host`, and `Is_Internal_Host` to exercise the deterministic host-policy core directly. Those helpers are SPARK-enabled; URL parsing and host validation wrappers remain ordinary Ada.

## Compression Boundary

HTTP response compression is owned by `HttpClient`. Production `sitefetchlib` clients enable
HttpClient's decoded response view, so `Content-Encoding: gzip` and `Content-Encoding: deflate`
are decoded by HttpClient before sitefetchlib classifies, rewrites, caches, or writes response
bodies. HttpClient also owns malformed compressed-body handling, decoded-body limits, and streaming
decompression.

`sitefetchlib` owns the crawler policy around compression: it sets the production `Accept-Encoding`
header, persists the effective request value in cache sidecars for `Vary: Accept-Encoding`, and
compares that value before reusing cached entries. It also has one resource-level decompression
case of its own: gzip sitemap files such as `sitemap.xml.gz` are fetched as resources and inflated
by sitefetchlib so sitemap links can be discovered. That is separate from HTTP `Content-Encoding`
transport decompression.

## Cache Policy

`Options.Cache.Mode` controls whether sitefetchlib reads existing sidecars, writes new sidecars,
and starts network requests:

| Mode | Behavior |
| --- | --- |
| `Cache_Ignore` | Do not read or write `.sitefetch_http_cache` sidecars. Every resource is fetched normally. |
| `Cache_Revalidate` | Read and write sidecars. Fresh valid entries are reused locally; stale entries with `ETag` or `Last-Modified` use conditional requests; stale entries without validators are refreshed from the network. |
| `Cache_Refresh` | Ignore existing sidecars for reuse and fetch from the network, but write updated sidecars for future runs. |
| `Cache_Offline` | Never intentionally fetch from the network for cache misses. Only fresh, valid local entries are usable; missing, stale, corrupt, version-rejected, or `Vary`-mismatched entries fail the resource. |

Freshness comes from `Cache-Control` and `Expires`; `Max_Stale_MS` allows bounded stale reuse but
does not override `no-cache` or `must-revalidate`. `Resource_Strategy` scopes sidecar reads and
writes to all resources, only buffered documents, or only streamed downloads.

Before reusing a sidecar, sitefetchlib can verify the local file against persisted `Local-Size` and
`Local-Hash` metadata. `Verify_Local_Content` enables those checks by default. `Hash_Algorithm`
selects FNV1a-64, SHA-256, or no hash; with `Cache_Hash_None`, size metadata is still checked when
local verification is enabled. `Require_Metadata_Version` rejects sidecars that do not carry the
current `Cache-Version`; by default older sidecars without a version are accepted when otherwise
usable.

`Vary_Allow` is an allow-list, not a wildcard cache key. `Vary: *` and unrecognized fields are
rejected. The supported request metadata comparisons are `User-Agent`, `Accept-Language`, and
`Accept-Encoding`; each must be allowed and must match the request value persisted in the sidecar.

## Cache Diagnostics

When diagnostics are enabled, cache progress reports use these event meanings:

| Event | Meaning |
| --- | --- |
| `Progress_Cache_Reused` | A valid local cache entry was reused. |
| `Progress_Cache_Revalidate` | A conditional request is being attempted with cached validators. |
| `Progress_Cache_Rejected` | Cache metadata was checked but could not be reused. |

Common `Progress_Cache_Rejected` reasons include `cache sidecar missing`, `local file missing`,
`local size mismatch`, `local hash mismatch`, `metadata version mismatch`, `Vary ... not allowed`,
`Vary ... mismatch`, `cache stale without validators`, `offline cache entry missing`,
`offline cache entry stale`, `offline cached file unreadable`, and `offline partial cache entry unusable`. Structured progress records
expose the normalized cache decision in `Cache_Decision`; CLI JSONL renders the
same value as `cache_decision`. The CLI final JSON summary counts `cache_hits`,
`cache_revalidations`, and `cache_rejections`, and includes `cache_rejection_reasons` as an object
mapping each aggregated rejection reason string to its count. The object is `{}` when no cache
rejections were reported. The sibling CLI crate owns the machine-readable JSON output compatibility
contract; see `../sitefetch/README.md` for JSONL ordering, summary field stability, and the full
final summary field list.

## Cache Sidecars

Cache sidecars use the `.sitefetch_http_cache` suffix and are implementation metadata for
sitefetchlib's incremental mirror behavior. They are not a stable public file format. Embedders may
inspect them for diagnostics, but should not depend on their exact field set or edit them directly
outside tests and debugging.

Current sidecars can include `Cache-Version`, `URL`, `Final-URL`, `ETag`, `ETag-Weak`,
`Last-Modified`, `Content-Type`, `Content-Length`, `Cache-Control`, `Expires`, `Vary`,
`Request-User-Agent`, `Request-Accept-Language`, `Request-Accept-Encoding`, `Resume-Safe`,
`Local-Size`, `Local-Hash-Algorithm`, and `Local-Hash`. Size and hash fields are used for local
corruption detection when `Cache.Verify_Local_Content` is enabled. `Cache.Require_Metadata_Version`
can be enabled to reject sidecars without the current metadata version.


## Example

```ada
with Ada.Strings.Unbounded;

with Sitefetch;
with Sitefetch.Cache;
with Sitefetch.Crawl;
with Sitefetch.Crawler;
with Sitefetch.Safety;

procedure Mirror is
   Statistics : Sitefetch.Fetch_Statistics;
   Options    : Sitefetch.Fetch_Options := Sitefetch.Default_Fetch_Options;
   Success    : Boolean;
begin
   Options.Crawl.Max_Pages := 250;
   Options.Crawl.Max_Depth := 4;
   Options.Crawl.Robots := Sitefetch.Crawl.Respect_Robots;
   Options.Cache.Mode := Sitefetch.Cache.Revalidate;
   Options.HTTP.Accept_Language := Ada.Strings.Unbounded.To_Unbounded_String ("en-US");
   Options.Safety.Write_Durability := Sitefetch.Safety.Sync_Data_And_Directory;

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

A checked version of this pattern lives in `examples/basic_mirror`. `Sync_Data_And_Directory` is
optional and asks HttpClient to fsync completed files and best-effort fsync parent directories after
atomic renames where supported. The example builds the README-style `Fetch_Website` call and only
performs network/filesystem mirror work when explicitly requested:

```sh
cd examples/basic_mirror
alr build
./bin/basic_mirror
SITEFETCHLIB_RUN_EXAMPLE=1 ./bin/basic_mirror
```

`examples/structured_progress` shows the same guarded pattern with
`Sitefetch.Crawler.Fetch_Website_With_Structured_Progress` and a callback that inspects fields such
as `Event`, `URL`, `Reason`, `Cache_Decision`, and `Bytes_Written`. Callbacks passed as
`Structured_Progress_Callback` should be library-level or otherwise live at a compatible
accessibility level; the checked example uses a package-level callback for this reason.
`examples/url_content_helpers` is an offline checked example for resolving/canonicalizing URLs,
checking crawl scope, deriving mirror local paths, and classifying parse-vs-download behavior.

## Build

`sitefetchlib` is an Alire library crate. Its project file is `sitefetchlib.gpr`.

Local path dependencies are pinned in `alire.toml` for this sibling checkout:

- `httpclient` at `../HttpClient`
- `regexp` at `../regexp`
- `zlib` at `../zlib`

These pins are development workspace metadata, not release dependency metadata. Before publishing or tagging a release archive, verify that public dependency declarations resolve from the intended Alire index or release source archive and that local `[[pins]]` entries are removed from the release manifest, or are kept only in an explicitly documented maintainer workspace overlay. Use `sitefetchlib.alire.release.toml` as the pin-free publish-manifest template for the library crate. The sibling `sitefetch` crate's `bin/check_split` tool audits that the committed development pins, release template, and this release-handling note stay in sync.

Build with:

```sh
alr build
```

## Generated Build Outputs

This split treats Alire workspace state and build products as generated local output. The `alire/`,
`config/`, `bin/`, `obj/`, and `lib/` directories are ignored for the CLI, library, test, smoke,
and example crates. `alr build` and `../sitefetch/bin/check_split` recreate these directories as
needed.

It is safe to remove those generated directories when stale binder, object, or library output makes
recursive searches noisy. After cleanup, run `alr build` in `../sitefetch` to recreate
`bin/check_split`, then run `../sitefetch/bin/check_split` for full cross-crate validation. For
source audits, prefer scanning `src/`, test source directories, docs, and example source files
instead of unrestricted recursive searches over build output directories.

## Tests

For full cross-crate validation from the sibling `sitefetch` CLI checkout, run:

```sh
cd ../sitefetch
alr build
./bin/check_split
```

This builds the CLI crate, library crate, both test suites, the public API smoke crate, and every
checked example crate discovered under `examples/*/alire.toml`.

Checked examples are direct children of `examples/`, have an `alire.toml`, declare exactly one
executable with `executables = ["..."]`, run without network or mirror filesystem work by default,
and are mentioned in `docs/API.md`. Examples that perform real crawling should require an explicit
opt-in such as an environment variable.

The library test suite itself lives in the `tests` subcrate and uses AUnit. It covers library
behavior: URL/domain helpers, link extraction, document rewriting, content classification, injected
fetch engine behavior, parallel workers, direct downloads, failures, production HTTP fixtures, cache,
resume, robots, retries, and HTTP client configuration.

Run only the library suite with:

```sh
cd tests
alr build
./bin/sitefetchlib_tests
```

The `public_api_smoke` subcrate is a downstream-style compile smoke test. It depends on
`sitefetchlib` and imports the stable root, crawler, and focused policy packages, so it catches accidental public API
drift toward CLI or testing-only packages. It intentionally avoids network and filesystem work when
run.

```sh
cd public_api_smoke
alr build
./bin/sitefetchlib_public_api_smoke
```

## Documentation Check

`check_sitefetchlib` is an Ada utility crate that verifies the focused API docs, README link, and
package-level support comments stay aligned. It uses the sibling `project_tools` crate for
shared text/file requirement helpers and is also run by the sibling split checker.

```sh
cd check_sitefetchlib
alr build
./bin/check_sitefetchlib
```

The checker validates API/documentation contracts, checked examples, the pin-free release manifest template, release-source hygiene, and the GNATprove release check.

## SPARK Release Check

Run the project-closure SPARK check through Alire so GNATprove can resolve the sibling `httpclient`,
`regexp`, and `zlib` projects:

```sh
alr exec -- gnatprove -P sitefetchlib.gpr --level=4
```

This is the GNATprove release check required before a sitefetchlib release. Most sitefetchlib crawler implementation units are intentionally outside SPARK mode because they use filesystem, HTTP, callbacks, and runtime I/O. The level-2 check exercises flow analysis and proof for SPARK-enabled units; URL parsing wrappers remain outside SPARK where they depend on non-SPARK HTTP/URI helpers. See `docs/SPARK.md` for the current coverage boundary.

## Project Layout

```text
sitefetchlib/
  src/sitefetch.ads          stable root records and shared types
  src/sitefetch.adb          root helper wrappers
  src/sitefetch-urls.ads     public URL/local-path helper implementation owner
  src/sitefetch-content.ads  public content/MIME helper implementation owner
  src/sitefetch-documents.ads
                             private document extraction/rewrite implementation owner
  src/sitefetch-client_config.ads
                             public HTTP client configuration helper
  src/sitefetch-domains.ads  public host/domain policy helper
  src/sitefetch-testing.ads  testing and fixture API
  src/sitefetch-engine.ads   private internal crawl orchestration
  tests/                     AUnit library behavior test suite
  docs/API.md                focused embedding API reference
  check_sitefetchlib/        Ada API docs contract checker
  public_api_smoke/          downstream compile smoke test for `Sitefetch`
  examples/basic_mirror/     checked README-style example
  examples/structured_progress/
                             checked structured diagnostics example
  sitefetchlib.gpr           library GNAT project file
  alire.toml                 library Alire crate metadata

../sitefetch/                CLI wrapper crate and `bin/check_split`
```

## Relationship To sitefetch

Use `sitefetchlib` when embedding the crawler in another Ada program. Use the sibling `sitefetch`
crate when you want the ready-made command-line executable.
