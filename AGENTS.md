# Agent instructions

Development version 0.1.0-dev.

This repository is the reusable Ada website mirroring library behind the
`sitefetch` command-line crate. These instructions are intended for AI coding
agents and other automated maintainers.

## Toolchain policy

- This repository enforces GNAT 15 through Alire with
  `gnat_native = "=15.2.1"` in every active crate manifest.
- Do not run plain system GNAT or GPR tools from `PATH`.
- Run compiler, builder, prover, and documentation tools through Alire, for
  example `alr exec -- gnatls --version`,
  `alr exec -- gprbuild -P sitefetchlib.gpr`, and
  `alr exec -- gnatprove -P sitefetchlib.gpr --level=4`.
- If `alr exec -- gnatls --version` does not report `GNATLS 15.x`, stop and fix
  the Alire toolchain before building or testing.

## Public contract

- Consumer code should depend on the stable `Sitefetch` root records and the
  documented focused public packages.
- `docs/API.md` is the public embedding reference.
- `Sitefetch.Testing` is for deterministic tests and fixture-driven consumers,
  not the production crawl surface.
- `Sitefetch.Documents` and `Sitefetch.Engine` are private implementation
  details.

## Build and validation

Preferred validation:

```sh
alr build
cd tests && alr build && ./bin/sitefetchlib_tests
cd public_api_smoke && alr build && ./bin/sitefetchlib_public_api_smoke
cd check_sitefetchlib && alr build && ./bin/check_sitefetchlib
cd examples/basic_mirror && alr build
cd examples/structured_progress && alr build
cd examples/url_content_helpers && alr build
alr exec -- gnatprove -P sitefetchlib.gpr --level=4
```

When GNAT/GPRBuild/GNATprove are unavailable through Alire, state that clearly
and run static checks that the environment supports.

## Coding rules

- Ada 2022 style; keep lines at or below 120 characters.
- Do not use Ada reserved words as identifiers, regardless of case.
- Do not add `goto`.
- Keep crawler/filesystem/network behavior deterministic under test fixtures.
- Do not introduce dependencies on system zlib, Python-generated fixtures, Git,
  `version`, or direct system GNAT tool discovery.

## Documentation rules

Any public behavior change must update:

- package GNATdoc comments for affected public specs;
- `docs/API.md`;
- relevant focused docs in `docs/`;
- `README.md`;
- checked examples and `examples` documentation when example behavior changes;
- checker expectations in `check_sitefetchlib` when release policy changes.
