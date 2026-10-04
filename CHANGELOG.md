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
- `extract`: files that already contained the text `__adze_keep__` (a
  string, a comment) are no longer silently edited by the pipe-protection
  pass.
- `extract`: `@doc false` on a promoted def goes directly above the def,
  not under a detached comment with a blank line in between.
- `find-callers`: `__MODULE__.Inner.f()` resolves against the enclosing
  module even when an alias shadows its first segment, and no longer
  creates atoms from module labels.
- `extract_private/2` no longer requires an unused `:path` option, so the
  documented `Adze.extract_private(source, definition: ...)` works.
- `mix adze.install` reads `skill.md` from the adze package (embedded at
  compile time), so it works in umbrella apps and with a custom
  `deps_path`.
- Re-running `mix adze.install` after upgrading adze now refreshes the adze
  section in `AGENTS.md` (found by its `## adze` heading) instead of
  keeping the old one. The skill files are always overwritten.
- Concurrent rewrites against different `mix_root`s no longer race on the
  (VM-global) working directory.

### Changed

- `mix adze.install` always installs both skills (`.claude/skills/` and
  `.agents/skills/`); the `--claude` / `--codex` flags are gone (passing
  them is harmless). It now writes its instructions to `AGENTS.md`. Since
  Claude Code ignores `AGENTS.md` when a `CLAUDE.md` exists, an existing
  `CLAUDE.md` (or `.claude/CLAUDE.md`) gets an `@AGENTS.md` import instead,
  and the adze section 0.1.0 wrote into it is removed. It never creates a
  `CLAUDE.md` or edits `CLAUDE.local.md`.

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
