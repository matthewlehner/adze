# Rules for working with adze

adze is a structural refactoring tool for Elixir, built on Sourceror
and Igniter. It exposes a CLI (`mix adze ...`) and a library API
(`Adze.*`). The CLI reference lives in the skill file — this document
covers the library API, error handling, conventions, and edge cases.

> **Guiding principle.** adze does mechanical work. You decide what to
> do. The compiler catches mistakes.

## Library API

All modules follow a three-tier convention:

1. **`action(source_string, opts)`** — pure function, no I/O.
2. **`action_file(path, opts)`** — reads file, dry-run (no writes).
3. **`action!(path, opts)`** — reads, computes, writes to disk.

All return `{:ok, result} | {:error, term}`.

### `Adze.Outline`

```elixir
Adze.Outline.outline(source, opts \\ [])    # parse source string → structural map
Adze.Outline.outline_file(path)             # read file → structural map
```

### `Adze.Extract`

```elixir
Adze.Extract.extract(source, opts)      # pure: compute extraction from source string
Adze.Extract.extract_file(path, opts)   # dry-run: read file, return diffs
Adze.Extract.extract!(path, opts)       # write: apply extraction to disk
```

Options: `definition:`, `module:`, `path:` (override target), `from_module:` (disambiguate).

Result includes: `source_diff`, `target_content`, `caller_diffs`, `dropped_directives`, `notices`.

### `Adze.Move`

```elixir
Adze.Move.mv(source, opts)        # pure: reorder within source string
Adze.Move.mv_file(path, opts)     # dry-run
Adze.Move.mv!(path, opts)         # write
```

Options: `definition:`, `before:`.

### `Adze.Rename`

```elixir
Adze.Rename.rename(opts)     # dry-run: compute project-wide rename diffs
Adze.Rename.rename!(opts)    # write: apply rename across the project
```

Options: `from:`, `to:`, `force:` (override surviving references check).

### `Adze.ExtractPrivate`

```elixir
Adze.ExtractPrivate.extract_private(source, opts)       # pure: flip def → defp
Adze.ExtractPrivate.extract_private_file(path, opts)    # dry-run
Adze.ExtractPrivate.extract_private!(path, opts)        # write
```

Options: `definition:`. Runs `FindCallers` internally — refuses if external callers exist.

### `Adze.FindCallers`

```elixir
Adze.FindCallers.find_callers(target_spec, opts \\ [])
```

`target_spec` is `"MyApp.Foo.bar/2"` or `"MyApp.Foo.bar"` (any arity).
Returns per-file caller lists with line numbers and snippets.

### `Adze.Deps`

```elixir
Adze.Deps.deps(source, opts \\ [])    # intra-module call graph from source string
Adze.Deps.deps_file(path)             # read file → call graph
```

## Common error shapes

All errors are tagged tuples. Match on the tag, not the message:

| Error | Meaning | Fix |
|-------|---------|-----|
| `{:error, :not_found}` | `--definition` or `--target` doesn't resolve | Check spelling, arity, module scope |
| `{:error, {:ambiguous_attribute, info}}` | Unknown attribute in a definition group | Add to `:include_attrs` config |
| `{:error, {:ambiguous_source_module, info}}` | Same def name in multiple modules in one file | Pass `--from-module` / `from_module:` |
| `{:error, {:cross_module_move, info}}` | `mv` can't span modules | Use `extract` instead |
| `{:error, {:target_exists, path}}` | Extract target file already exists | Delete file or pick different `--module` |
| `{:error, {:typep_referenced, info}}` | Extracted function's `@spec` uses a `@typep` | Widen `@typep` to `@type` first |
| `{:error, {:surviving_references, refs}}` | Rename post-check found un-rewritten refs | Fix by hand or pass `--force` |
| `{:error, :cannot_be_private}` | `defdelegate` has no private form | Don't privatize delegates |
| `{:error, {:issues, [...]}}` | Igniter refused to write | Read the issue list for details |
| `{:error, {:format, exception}}` | `Code.format_string!/2` failed on the transformed source | Usually a bad `formatter_opts:` value; check the exception |
| `{:error, {:render, exception}}` | `Sourceror.to_string/2` failed on the rewritten AST | Indicates a mechanical-transform bug; file an issue |
| `{:error, {:file_write, reason}}` | Writing the result to disk failed | Check permissions / disk space |

## Conventions

### Directive policy for `extract`

`alias` is copied to the target only when its binding is referenced in
the closure. `use` / `import` / `require` are **never** copied — they
appear in `dropped_directives`. This is intentional:

- A missing directive → compile error (loud, fixable).
- An extra `use` → silent macro execution (dangerous).

Read `dropped_directives` from the dry-run, add back what the target
needs, then run `extract!`.

### Custom attachable attributes

Libraries like Oban (`@job`), Decorator (`@decorate`), Absinthe
(`@desc`) introduce attributes that attach to the next def. Without
config, write ops may return `{:error, {:ambiguous_attribute, ...}}`.

```elixir
# config/config.exs
config :adze, include_attrs: [:job, :decorate, :desc]
```

Merged with adze's built-in allowlist (`@doc`, `@spec`, `@impl`,
`@deprecated`, `@since`, `@typedoc`).

### Formatter integration

adze reads your `.formatter.exs` (including `import_deps`) so generated
code matches project style. It also reads `elixirc_paths` to know which
directories to scan for callers.

### `--mix-root` caveat

The `--mix-root PATH` flag changes `cwd` but does **not** switch Mix's
loaded project. Always run from the project root directly.

### `find-callers` limitations

Won't detect:
- Unqualified calls via `import Mod`
- Dynamic dispatch (`apply/3`, `Module.concat/2`)
- String-literal module references

`extract-private!` inherits these blind spots. When in doubt, run
`mix compile --warnings-as-errors` after the flip.

### After every write op

```bash
mix compile --warnings-as-errors
mix test
```

The compiler catches what adze can't statically verify.
