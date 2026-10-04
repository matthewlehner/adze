# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Upgrading to 0.2.0

Upgrade with `mix igniter.upgrade adze` instead of `mix deps.update adze`.
It runs the new `adze.upgrade` task, which:

- refreshes the adze skill files and the adze section of `AGENTS.md`,
  which still tell agents to use the removed `!` commands;
- lists every `mix adze mv!` / `extract!` / `rename!` / `extract-private!`
  left in your own files (Makefiles, scripts, CI workflows, your own agent
  notes) with its file and line. It doesn't rewrite them. Drop the `!`, and
  add `--dry-run` where a script relied on the old preview-only default.

If you upgraded with `mix deps.update`, or use adze as a path dependency
(`igniter.upgrade` can't read the old version), run
`mix igniter.install adze` to refresh the files, then search for `adze \w+!`
yourself.

### Added

- `mix adze.upgrade`, run by `mix igniter.upgrade adze`. Every upgrade
  re-runs the installer; version-specific steps flag anything else that
  needs changing.

### Fixed

- `ls`: a multi-line `alias Foo.{Bar, Baz}` renders on one line listing
  every member, instead of spilling raw source across several lines.
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

- Removed `usage-rules.md` from the package. The skill covers agent use;
  the library API, error shapes and conventions are in the moduledocs.
- CLI write ops (`mv`, `extract`, `rename`, `extract-private`) now write by
  default. Pass `--dry-run` to preview. The `!` forms (`mv!`, `extract!`,
  `rename!`, `extract-private!`) are removed and exit with a pointer to the
  new behaviour. The library API (`Adze.mv/2`, `Adze.mv!/2`, …) is unchanged.
- Agent docs (skill, agents snippet) no longer tell agents to dry-run before
  every write.
- `skill.md` is about half the size (9.7 KB → 4.8 KB): one entry per op,
  no recipes that repeat the op descriptions, and refusal details left to
  the error messages.
- `ls` (text): adjacent clauses of one function render as a single line
  spanning all of them, e.g. `p mv_error/2   L346–386  (10 clauses)`. JSON
  output still has one entry per clause.
- CLI write ops print a summary by default — files touched with +/- line
  counts, plus dropped directives, promotions and warnings — instead of
  every diff and the whole new file. `--diff` prints the full output;
  `--dry-run` still does. JSON output is unchanged.
- `mix adze.install` always installs both skills (`.claude/skills/` and
  `.agents/skills/`); the `--claude` / `--codex` flags are gone (passing
  them is harmless). It now writes its instructions to `AGENTS.md`. Since
  Claude Code ignores `AGENTS.md` when a `CLAUDE.md` exists, an existing
  `CLAUDE.md` (or `.claude/CLAUDE.md`) gets an `@AGENTS.md` import instead,
  and the adze section 0.1.0 wrote into it is removed. It never creates a
  `CLAUDE.md` or edits `CLAUDE.local.md`.
- The `AGENTS.md` section is shorter (when to reach for adze, plus the
  exact skill paths); the skill carries the full reference. The installer
  no longer suggests `mix usage_rules.sync`, which duplicated the skill.

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
