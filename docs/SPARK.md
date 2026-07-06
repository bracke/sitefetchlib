# SPARK Coverage

`sitefetchlib` uses SPARK selectively. The crawler and HTTP execution paths are ordinary Ada because they use filesystem state, network clients, callbacks, tasking, and runtime I/O.

## Enabled Units

`Sitefetch.Domains` contains the current SPARK-enabled public support surface:

- `Public_Suffix_For_Normalized_Host`
- `Registrable_Domain_For_Normalized_Host`
- `Is_Internal_Host`

These helpers operate on already normalized ASCII DNS host text and treat IP-like host text as exact-only. They isolate the deterministic public-suffix and crawl-boundary policy from URL parsing and host validation, so GNATprove can analyze that logic directly.

## Deliberately Outside SPARK

The following `Sitefetch.Domains` wrappers remain outside SPARK:

- `Normalized_Host`
- `Public_Suffix`
- `Registrable_Domain`
- `Is_Internal`

Those routines call `Sitefetch.Domain_Of` and `Http_Client.URI` helpers to parse URLs, reject raw non-ASCII authority text, validate ASCII host syntax, and classify IP literals. Those dependencies currently expose effects that are not suitable for SPARK proof in this crate.

## Release Check

Every release must run:

```sh
alr exec -- gnatprove -P sitefetchlib.gpr --level=4
```

Run GNATprove through Alire only. The active manifests pin
`gnat_native = "=15.2.1"`, and `alr exec -- gnatls --version` must report
`GNATLS 15.x` before proof or release checks are valid.

The level-2 run exercises flow analysis and proof for SPARK-enabled units. Low-priority proof warnings may still appear for unconstrained string result bounds in normalized-host helpers; they are tracked as proof precision work and are not a claim of full functional proof for the crawler.
