# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- `extract`: cross-file pipes whose real arity stays in the source are no
  longer rewritten.
- `extract`: refuses (instead of emitting uncompilable code) when the
  closure calls a public macro/guard that stays behind, when a moved
  macro/guard still has callers, or when another file `import`s / `use`s
  the source and could call a moved def (`use Source` counts when
  `Source` defines `__using__`).
- `deps`: calls in `when` guards now count as calls from the clause.
- `find-callers`: `__MODULE__.Inner.f()` resolves against the enclosing
  module even when an alias shadows its first segment, and no longer
  creates atoms from module labels.
- `extract_private/2` no longer requires an unused `:path` option, so the
  documented `Adze.extract_private(source, definition: ...)` works.

### Known limitations

- `extract` doesn't see imports whose module is only known at runtime
  (`import unquote(mod)` in a `__using__`, `use Base, Source`).

## [0.1.0] - 2026-05-22

### Added

- `mix adze ls` / `outline` — structural file outline with line ranges
- `mix adze deps` — intra-module call graph (caller → callees)
- `mix adze ls-deps` — transitive dependency tree from a definition
- `mix adze ls-extract` — private closure exclusively reachable from a definition
- `mix adze aliases` — per-module alias/import/require/use listing
- `mix adze find-callers` — project-wide caller search with alias resolution
- `mix adze mv` / `mv!` — reorder definitions within a module
- `mix adze extract` / `extract!` — extract a function + closure into a new module
- `mix adze rename` / `rename!` — rename a module across the entire project
- `mix adze extract-private` / `extract-private!` — flip `def` → `defp` when safe

[0.1.0]: https://github.com/matthewlehner/adze/releases/tag/v0.1.0
