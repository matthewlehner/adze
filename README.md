# Adze

[![Hex.pm](https://img.shields.io/hexpm/v/adze.svg)](https://hex.pm/packages/adze)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/adze)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

AI coding agents waste context window reading 2000-line files, then fumble
multi-edit refactors across a codebase. Adze fixes both problems.

**Adze parses Elixir source as AST, returns a structural skeleton with exact
line ranges (~50 tokens instead of the whole file), and lets the agent read
only the bytes it needs.** When it's time to refactor, the same AST machinery
performs safe mechanical transforms — extract, rename, reorder — that would be
tedious and error-prone as multi-edits.

Built on [Sourceror](https://hex.pm/packages/sourceror) and
[Igniter](https://hex.pm/packages/igniter).

## Getting Started

### Recommended: install with agent integration

```bash
mix igniter.install adze
```

This adds the dependency *and* sets up skill files so your agent knows to reach
for `mix adze` instead of hand-editing:

| Platform | Skill path | Config patched |
|----------|-----------|----------------|
| Claude Code | `.claude/skills/adze/SKILL.md` | `CLAUDE.md` |
| Codex / Pi / OpenCode | `.agents/skills/adze/SKILL.md` | `AGENTS.md` |

Target a single platform with `--claude` or `--codex`.

### Manual install

Add `adze` as a dev dependency:

```elixir
def deps do
  [
    {:adze, "~> 0.1.0", only: :dev}
  ]
end
```

Then `mix deps.get`.

> Adze runs as a Mix task inside your project. It reads
> `Mix.Project.config()` (formatter opts, `elixirc_paths`) so it must
> run inside a loaded Mix project — there's no standalone binary.

#### Setting up agent integration manually

After fetching deps, copy the skill file and add a reference to your
agent config:

**Claude Code:**

```bash
mkdir -p .claude/skills/adze
cp deps/adze/skill.md .claude/skills/adze/SKILL.md
```

**Codex / Pi / OpenCode:**

```bash
mkdir -p .agents/skills/adze
cp deps/adze/skill.md .agents/skills/adze/SKILL.md
```

Then add the following to your `CLAUDE.md` or `AGENTS.md` (create it if
it doesn't exist):

```markdown
## adze — structural Elixir refactoring

For Elixir codebase exploration: ALWAYS run `mix adze ls --file PATH` before
reading `.ex` files or spawning exploration agents. Measured: ~150x more
token-efficient than reading full files (maps a 2000-line module in ~50 tokens
with exact line ranges, vs reading the whole file). Returns in milliseconds.
Use the outline to identify the line range you need, then Read only that range.

For structural edits (rename, extract, move, privatize): ALWAYS use `mix adze`
instead of multi-edit. The tool does AST-aware rewrites across the entire project
in one pass — no missed call sites, no broken aliases, no formatting drift.

Key commands:
- `mix adze ls --file PATH` — structural outline with line ranges (~50 tokens per file)
- `mix adze find-callers --target Mod.fun/N` — project-wide caller search (resolves aliases, pipes, captures)
- `mix adze rename! --from Old --to New` — rename a module across the entire project
- `mix adze extract! --file PATH --definition fun/N --module New.Mod` — extract function + private closure into new module
- `mix adze mv! --file PATH --definition fun/N --before other/M` — reorder defs within a module
- `mix adze extract-private! --file PATH --definition fun/N` — flip def → defp after verifying no external callers

Always dry-run first (no `!`), then apply with `!`. Run `mix compile --warnings-as-errors` after writes.

Full reference (flags, caveats, workflows): see the adze skill file in this project's skills directory.
```

### usage_rules (optional, richer context)

If you use [usage_rules](https://hex.pm/packages/usage_rules) for your
`AGENTS.md`:

```bash
mix usage_rules.sync AGENTS.md adze
```

This pulls the full usage-rules reference (error shapes, API details,
conventions) into your rules file for any agent that reads it.

## When to Reach for Adze

| You're about to… | Use this instead |
|------------------|------------------|
| Read an Elixir file > 200 lines | `mix adze ls --file PATH` first, then read only the line range you need |
| Multi-edit a `defmodule` rename across the project | `mix adze rename! --from Old --to New` |
| Copy a function + its private helpers into a new module by hand | `mix adze extract! --file ... --definition fun/N --module New.Module` |
| Reorder defs inside a module with multi-edit | `mix adze mv! --file ... --definition fun/N --before other/M` |
| Grep for callers of `Mod.fun` across the project | `mix adze find-callers --target Mod.fun/N` |
| Convert a `def` to `defp` after eyeballing call sites | `mix adze extract-private! --file ... --definition fun/N` |
| Eyeball a module's `alias`/`import`/`use` clauses | `mix adze aliases --file PATH` |

If none of these match, fall back to standard read/edit/grep.

## Quick Start

```bash
# Map a file's structure (agent reads ~50 tokens instead of the whole file)
mix adze ls --file lib/my_app/accounts.ex

# Find all callers of a function across the project
mix adze find-callers --target MyApp.Accounts.register/1

# Extract a function + its private helpers into a new module
mix adze extract! --file lib/my_app/accounts.ex --definition register/1 --module MyApp.Registration
```

## Command Reference

### Read-only (safe, never writes)

| Command | Description |
|---------|-------------|
| `mix adze ls --file PATH` | Structural outline with line ranges |
| `mix adze deps --file PATH` | Intra-module call graph (caller → callees) |
| `mix adze ls-deps --file PATH --definition fun/N` | Transitive dependency tree from one function |
| `mix adze ls-extract --file PATH --definition fun/N` | Private closure that would move with a function |
| `mix adze aliases --file PATH` | All `alias`/`import`/`require`/`use` per module |
| `mix adze find-callers --target Mod.fun/N` | Project-wide callers (resolves aliases, pipes, captures) |

### Write (refactoring)

Every write op has a **dry-run** variant (no `!`, prints a diff) and a
**bang** variant (`!`, writes to disk). Always preview first.

| Command | Description |
|---------|-------------|
| `mix adze mv! --file PATH --definition fun/N --before other/M` | Reorder a definition within a module |
| `mix adze extract! --file PATH --definition fun/N --module New.Mod` | Extract function + closure into a new module |
| `mix adze rename! --from Old.Mod --to New.Mod` | Rename a module across the entire project |
| `mix adze extract-private! --file PATH --definition fun/N` | Flip `def` → `defp` when no external callers exist |

<details>
<summary>Example output: <code>mix adze ls</code></summary>

```
$ mix adze ls --file lib/sample.ex
# lib/sample.ex
defmodule Sample   L1–40
  @moduledoc   L2–4
  use GenServer   L6
  alias Sample.Inner   L7
  import Enum   L8
  @behaviour "GenServer"   L11
  defstruct [:id, :name, :count]   L14
  @spec :greet   L16
    greet/1 when …   L17–19
    greet/1   L21
  p internal/1   L23
  m debug/1   L25–29
  g is_pos/1 when …   L31
  d child_call/1   L33

  defmodule Inner   L35–39
      hello/0   L37
    p helper/1   L38
```

Legend: `p` = `defp`, `m` = `defmacro`, `g` = `defguard`, `d` = `defdelegate`.

</details>

## Configuration

### Custom attachable attributes

Some libraries introduce attributes that semantically belong to the next
`def` (e.g. Oban's `@job`, Decorator's `@decorate`, Absinthe's `@desc`).
Tell adze to treat them as part of the definition group:

```elixir
# config/config.exs
config :adze, include_attrs: [:job, :decorate, :desc]
```

### Output format

Every command accepts `--format json` for programmatic consumption.
Text (default) is optimized for humans and LLMs reading inline.

## How It Works

Elixir is homoiconic — source code is data. Sourceror gives us a zipper
over the AST with formatting and comments preserved. Every structural
operation is a tree walk, not string manipulation.

Single-file analysis (outline, deps, aliases) uses raw Sourceror.
Project-wide operations (rename, extract caller rewriting, find-callers)
use Igniter for safe multi-file rewrites with formatting preservation.

## Limitations

`find-callers` (and by extension `extract-private!`) resolves qualified calls,
pipe variants, and `&Mod.fun/n` captures — including alias resolution. It
**won't find:**

- Unqualified calls via `import`
- Dynamic dispatch (`apply/3`, `Kernel.apply/3`)
- String-literal module references (`"Elixir.MyApp.Foo"`)

When in doubt, run `mix compile --warnings-as-errors` after any write op.
The compiler catches what adze can't.

## Documentation

Full API documentation is available on [HexDocs](https://hexdocs.pm/adze).

## Prior Art & Acknowledgments

Adze exists because of the tools it builds on and the project that showed
the way:

- **[clj-surgeon](https://github.com/realgenekim/clj-surgeon)** by Gene Kim
  ([@realgenekim](https://github.com/realgenekim)) — the direct inspiration.
  Gene watched Claude Code spend 45 minutes refactoring a 5,000-line Clojure
  file and asked: *"What would the ideal tool be to help you manipulate
  beautiful homoiconic EDN files?"* The answer was 13 ops in ~1,500 lines of
  Clojure, built in one session. Adze is the Elixir port of that idea:
  same philosophy (outline-first exploration, AST-aware refactoring, the tool
  does bookkeeping while the AI decides what to do), adapted for Elixir's
  ecosystem.

- **[Sourceror](https://hex.pm/packages/sourceror)** by Dorgan
  ([@doorgan](https://github.com/doorgan)) — the foundation. Every single-file
  operation in adze is a tree walk on the zipper that Sourceror provides.
  Comments and formatting are preserved because Sourceror tracks them in AST
  metadata. Without it, adze would need a custom parser.

- **[Igniter](https://hex.pm/packages/igniter)** by Zach Daniel
  ([@zachdaniel](https://github.com/zachdaniel)) — the project-wide rewrite
  engine. Cross-file operations (rename, extract caller rewriting, find-callers)
  use Igniter for safe multi-file rewrites with formatter preservation. The
  installer task uses Igniter's code generation framework.

The guiding principle, borrowed directly from clj-surgeon:

> **The tool does the mechanical work. The AI decides what to do. The compiler
> catches mistakes. The AI fixes what the compiler reports.**

## License

[MIT](LICENSE)
