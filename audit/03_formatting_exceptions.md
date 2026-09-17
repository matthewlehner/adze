# Issue 3 — Formatting / I/O failures can raise instead of returning `{:error, _}`

## Problem

Adze's write operations generally return `{:ok, result} | {:error, reason}` tuples, but internally they call functions that can raise:

- `Code.format_string!/2` in `Adze.Move.reformat/1` and `Adze.Extract.reformat/2`.
- `Sourceror.to_string/2` in `Adze.ProjectRewrite.render/1` and `Adze.Extract.render_node/1`.
- `File.write!/2` / `File.rename!/2` in `Adze.ProjectRewrite.write!/1`.

If a mechanical transform ever produces syntactically invalid AST, the user gets a raw exception traceback instead of a structured error tuple. This breaks the public contract and makes CLI usage less friendly.

## Severity

🟡 Medium — the failure is loud and unlikely in normal use, but it leaks abstraction and complicates error handling for consumers.

## Location

- `lib/adze/move.ex` — `reformat/1` (`Code.format_string!/2`)
- `lib/adze/extract.ex` — `reformat/2` (`Code.format_string!/2`), `render_node/1` (`Sourceror.to_string/2`)
- `lib/adze/project_rewrite.ex` — `render/1` (`Sourceror.to_string/2`), `write!/1` (`File.write!/2`, `File.rename!/2`)
- `lib/adze/extract_private.ex` — `extract_private!/2` (<after formatting> then `File.write!/2`)

## Proposed fix

1. **Formatter wrapping**: Wrap `Code.format_string!/2` in a `try/rescue` and return `{:error, {:format, exception}}` when it fails.
2. **Renderer wrapping**: Wrap `Sourceror.to_string/2` similarly, returning `{:error, {:render, exception}}`.
3. **Call-site handling**: Update `Adze.Move.mv/2`, `Adze.Extract.extract/2`, `Adze.ExtractPrivate.extract_private/2`, and related bang variants to propagate these tuple errors instead of letting exceptions escape.
4. **File I/O**: `ProjectRewrite.write!/1` already has `!` in its name, so raising is acceptable there, but consider adding a non-raising `write/1` wrapper that converts `File.Error` to `{:error, {:file_write, reason}}`.
5. **CLI**: Ensure `Adze.CLI` catches the new error shapes and prints a useful message via `die/1`.

## Acceptance criteria

- [ ] Add a test that deliberately passes malformed/incomplete source to `Move.mv/2` and asserts `{:error, {:format, _}}` (or similar) rather than an exception.
- [ ] Add a test that causes `Extract.extract/2` to produce invalid AST and asserts a clean error tuple.
- [ ] The existing public `mv!`, `extract!`, and `extract_private!` functions should still either succeed or return `{:error, reason}`; exceptions should only escape for truly unrecoverable programmer errors.
- [ ] All 273 existing tests pass.
- [ ] `mix compile --warnings-as-errors` passes.
