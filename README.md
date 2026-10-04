# Adze

[![Hex.pm](https://img.shields.io/hexpm/v/adze.svg)](https://hex.pm/packages/adze)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/adze)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

AI coding agents waste context window reading 2000-line files, then fumble
multi-edit refactors across a codebase. Adze fixes both problems.

**Adze parses Elixir source as AST, returns a structural skeleton with exact
line ranges, and lets the agent read only the lines it needs.** When it's time to refactor, the same AST machinery
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

| Platform | Skill path |
|----------|-----------|
| Claude Code | `.claude/skills/adze/SKILL.md` |
| Codex / Pi / OpenCode | `.agents/skills/adze/SKILL.md` |

Both skills are always installed, since Claude Code only loads skills from
`.claude/skills/` and the other agents from `.agents/skills/`.

It also adds an adze section to `AGENTS.md` (creating it if needed). Codex, Pi
and OpenCode read `AGENTS.md`. Claude Code (v2.1.277+) reads it too, but only
when the project has no `CLAUDE.md`, `.claude/CLAUDE.md` or `CLAUDE.local.md`.
So if your project has a `CLAUDE.md`, the installer appends an `@AGENTS.md`
import to it (and removes the adze section older versions wrote there). It
never creates a `CLAUDE.md` and never edits `CLAUDE.local.md`; if that's your
only one, add the `@AGENTS.md` line yourself.

Re-run `mix igniter.install adze` after upgrading adze to refresh the skills
and the `AGENTS.md` section.

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

Then append the contents of
[`agents-snippet.md`](agents-snippet.md) (also at
`deps/adze/agents-snippet.md`) to your `AGENTS.md`, creating it if it
doesn't exist:

```bash
cat deps/adze/agents-snippet.md >> AGENTS.md
```

### usage_rules (for agents without skills)

The skill already gives agents the full reference when they need it. If your
agent doesn't load skills and you use
[usage_rules](https://hex.pm/packages/usage_rules), you can copy the reference
(error shapes, API details, conventions) into `AGENTS.md` instead:

```bash
mix usage_rules.sync AGENTS.md adze
```

It's loaded into every session, so skip it if your agent loads the skill.

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
# Map a file's structure without reading all of it
mix adze ls --file lib/my_app/accounts.ex

# Find all callers of a function across the project
mix adze find-callers --target MyApp.Accounts.register/1

# Several arities at once (e.g. a function with default arguments)
mix adze find-callers --target MyApp.Accounts.register/1,2
```

### Preview, then write

Every write command is a dry-run unless you add `!`. The dry-run prints what
would change and touches nothing:

```
$ mix adze extract --file lib/sample.ex --definition greet/1 --module Sample.Greeter
# new file: ./lib/sample/greeter.ex (Sample.Greeter)
defmodule Sample.Greeter do
  @spec greet(String.t()) :: String.t()
  def greet(name) when is_binary(name) do
    "hello, " <> name
  end

  def greet(_), do: "hello, stranger"
end

# source diff
--- a
+++ b
@@ -13,13 +13,6 @@

   defstruct [:id, :name, count: 0]

-  @spec greet(String.t()) :: String.t()
-  def greet(name) when is_binary(name) do
-    "hello, " <> name
-  end
-
-  def greet(_), do: "hello, stranger"
-
   defp internal(x), do: x * 2
 ...

# dropped directives (use / import / require)
# add back to the new target module if the build needs them.
  source:6  use GenServer
  source:8  import Enum, only: [map: 2]
  source:9  require Logger
```

Read the diff (and the dropped directives), then apply:

```bash
mix adze extract! --file lib/sample.ex --definition greet/1 --module Sample.Greeter
mix compile --warnings-as-errors
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
  require Logger   L9
  @behaviour GenServer   L11
  @some_attr   L12
  defstruct [:id, :name, :count]   L14
  @spec greet   L16
    greet/1 when …   L17–19
    greet/1   L21
  p internal/1   L23
  m debug/1   L25–29
  g is_pos/1 when …   L31
  d child_call/1   L33
```

Each line is a definition with its line range. A one-character marker column
precedes the name: `p` = `defp`, `m` = `defmacro`, `g` = `defguard`,
`d` = `defdelegate`; public `def`s have a blank marker (hence the deeper
indent). `@spec greet` is the spec for `greet`. Use `--format json` for the
same data as a structured tree.

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

Because callbacks and dynamically dispatched functions have no visible
callers, `extract-private` always refuses `@impl` definitions and callbacks
of a loadable `@behaviour` / `use`d behaviour, and refuses anything in a
module whose `use` / `@behaviour` target it can't load as a behaviour
(e.g. `use MyAppWeb, :controller`) unless you pass `--force`.
Functions reached via `mod.fun()` / `apply/3` from elsewhere are still
invisible to it.

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
