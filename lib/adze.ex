defmodule Adze do
  @moduledoc """
  Structural Elixir refactoring and outline-first code exploration.

  Adze is a toolkit built on [Sourceror](https://hex.pm/packages/sourceror) and
  [Igniter](https://hex.pm/packages/igniter) that gives AI coding agents (and humans)
  fast, token-efficient ways to understand and transform Elixir source code.

  Single-file analysis (outline, deps, aliases) uses raw Sourceror for AST parsing.
  Project-wide operations (rename, extract caller rewriting, find-callers) use Igniter
  for safe, multi-file rewrites with formatting preservation.

  ## Installation

  Add `adze` to your list of dependencies in `mix.exs`:

      def deps do
        [
          {:adze, "~> 0.1.0"}
        ]
      end

  ## Design Philosophy

  Adze splits its operations into two categories:

  ### Read-Only Analysis

  These functions parse source code and return structured data without modifying
  anything on disk. They come in two flavours:

    * **`*_file/1`** — reads a file path and returns the analysis.
    * **`*/2` or `*/3`** — accepts a source string directly (useful for editors,
      tests, or piping sources around).

  Read-only operations include:

    * `outline/2` / `outline_file/1` — structural outline (modules, defs, attributes, directives)
    * `deps/2` / `deps_file/1` — intra-module call graph
    * `ls_deps/3` / `ls_deps_file/2` — transitive dependency tree from a definition
    * `ls_extract/3` / `ls_extract_file/2` — private closure exclusively reachable from a definition
    * `aliases/2` / `aliases_file/1` — alias/import/require/use directives per module
    * `find_callers/2` — project-wide caller search for a qualified function

  ### Write Operations (Refactoring)

  These functions compute a transformation and can optionally write to disk.
  They follow a three-tier naming convention:

    * **`op/2`** — dry-run on a source string, returns `{:ok, result}` with diffs/new source.
    * **`op_file/2`** — dry-run reading from a file path.
    * **`op!/2`** — writes the result to disk (destructive).

  Write operations include:

    * `mv/2` / `mv_file/2` / `mv!/2` — reorder a definition within a module
    * `extract_private/2` / `extract_private_file/2` / `extract_private!/2` — flip `def` → `defp`
    * `extract/2` / `extract_file/2` / `extract!/2` — extract a def + closure into a new module
    * `rename/1` / `rename!/1` — rename a module across the entire project

  ## Underlying Modules

  Each operation is implemented in its own module with full documentation:

    * `Adze.Outline`
    * `Adze.Deps`
    * `Adze.LsDeps`
    * `Adze.Aliases`
    * `Adze.FindCallers`
    * `Adze.ExtractPrivate`
    * `Adze.Move`
    * `Adze.Extract`
    * `Adze.Rename`
  """

  # ===========================================================================
  # Outline — structural map of a file
  # ===========================================================================

  @doc """
  Returns a structural outline of the given source file.

  Parses the file at `path` and returns every top-level definition — `defmodule`,
  `def`, `defp`, `defmacro`, `defmacrop`, `defguard`, `defstruct`, module
  attributes (`@moduledoc`, `@doc`, custom attrs), and directives
  (`alias`, `import`, `require`, `use`) — annotated with line ranges.

  This is designed so an AI coding agent can map a 2000-line file in ~50 tokens.

  ## Examples

      {:ok, outline} = Adze.outline_file("lib/my_app/accounts.ex")

  See `Adze.Outline` for full details on the returned structure.
  """
  @spec outline_file(Path.t()) :: {:ok, map()} | {:error, term()}
  defdelegate outline_file(path), to: Adze.Outline

  @doc """
  Returns a structural outline from a source string.

  Same as `outline_file/1` but operates on source code passed directly as a string.

  ## Options

    * `:file` — an optional filename label to include in the result (useful for
      display purposes when the source didn't come from disk).

  ## Examples

      source = File.read!("lib/my_app/accounts.ex")
      {:ok, outline} = Adze.outline(source, file: "accounts.ex")

  See `Adze.Outline` for full details on the returned structure.
  """
  @spec outline(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate outline(source, opts \\ []), to: Adze.Outline

  # ===========================================================================
  # Deps — intra-module call graph
  # ===========================================================================

  @doc """
  Returns the intra-module call graph for the given file.

  Reads the file at `path` and builds a map of caller → callees relationships
  *within the same module*. Pipe chains and function captures (`&fun/arity`) are
  resolved so every internal call edge is captured.

  ## Examples

      {:ok, graph} = Adze.deps_file("lib/my_app/parser.ex")

  See `Adze.Deps` for full details on the returned structure.
  """
  @spec deps_file(Path.t()) :: {:ok, map()} | {:error, term()}
  defdelegate deps_file(path), to: Adze.Deps

  @doc """
  Returns the intra-module call graph from a source string.

  Same as `deps_file/1` but operates on source code passed directly as a string.

  ## Options

    * `:file` — an optional filename label.

  ## Examples

      {:ok, graph} = Adze.deps(source)

  See `Adze.Deps` for full details on the returned structure.
  """
  @spec deps(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate deps(source, opts \\ []), to: Adze.Deps

  # ===========================================================================
  # LsDeps — transitive dependency tree & extraction closure
  # ===========================================================================

  @doc """
  Returns the transitive dependency tree rooted at `definition` in the given file.

  Performs a depth-first traversal from the specified definition, showing all
  functions it transitively calls within the same module. Cycles are detected
  and marked with `repeat: true` rather than infinitely recursing.

  `definition` is a `{name, arity}` tuple, e.g. `{:process, 2}`.

  ## Examples

      {:ok, tree} = Adze.ls_deps_file("lib/my_app/parser.ex", {:parse, 1})

  See `Adze.LsDeps` for full details.
  """
  @spec ls_deps_file(Path.t(), {atom(), non_neg_integer()}) :: {:ok, map()} | {:error, term()}
  defdelegate ls_deps_file(path, definition), to: Adze.LsDeps

  @doc """
  Returns the transitive dependency tree rooted at `definition` from a source string.

  Same as `ls_deps_file/2` but operates on source code passed directly.

  ## Options

    * `:file` — an optional filename label.

  ## Examples

      {:ok, tree} = Adze.ls_deps(source, {:parse, 1})

  See `Adze.LsDeps` for full details.
  """
  @spec ls_deps(String.t(), {atom(), non_neg_integer()}, keyword()) ::
          {:ok, map()} | {:error, term()}
  defdelegate ls_deps(source, definition, opts \\ []), to: Adze.LsDeps

  @doc """
  Returns the flat extraction closure for `definition` in the given file.

  Computes the set of private helper functions that are *exclusively* reachable
  from the target definition — i.e., the private functions that could safely be
  extracted along with it without breaking anything else in the module.

  `definition` is a `{name, arity}` tuple, e.g. `{:process, 2}`.

  ## Examples

      {:ok, closure} = Adze.ls_extract_file("lib/my_app/parser.ex", {:parse, 1})

  See `Adze.LsDeps` for full details.
  """
  @spec ls_extract_file(Path.t(), {atom(), non_neg_integer()}) :: {:ok, map()} | {:error, term()}
  defdelegate ls_extract_file(path, definition), to: Adze.LsDeps

  @doc """
  Returns the flat extraction closure for `definition` from a source string.

  Same as `ls_extract_file/2` but operates on source code passed directly.

  ## Options

    * `:file` — an optional filename label.

  ## Examples

      {:ok, closure} = Adze.ls_extract(source, {:parse, 1})

  See `Adze.LsDeps` for full details.
  """
  @spec ls_extract(String.t(), {atom(), non_neg_integer()}, keyword()) ::
          {:ok, map()} | {:error, term()}
  defdelegate ls_extract(source, definition, opts \\ []), to: Adze.LsDeps

  # ===========================================================================
  # Aliases — directive inventory per module
  # ===========================================================================

  @doc """
  Returns all alias/import/require/use directives per module in the given file.

  Group-form aliases (e.g. `alias MyApp.{Foo, Bar}`) are expanded into their
  individual forms so every directive is represented as a single entry.

  ## Examples

      {:ok, directives} = Adze.aliases_file("lib/my_app/context.ex")

  See `Adze.Aliases` for full details on the returned structure.
  """
  @spec aliases_file(Path.t()) :: {:ok, map()} | {:error, term()}
  defdelegate aliases_file(path), to: Adze.Aliases

  @doc """
  Returns all alias/import/require/use directives per module from a source string.

  Same as `aliases_file/1` but operates on source code passed directly.

  ## Options

    * `:file` — an optional filename label.

  ## Examples

      {:ok, directives} = Adze.aliases(source)

  See `Adze.Aliases` for full details on the returned structure.
  """
  @spec aliases(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate aliases(source, opts \\ []), to: Adze.Aliases

  # ===========================================================================
  # FindCallers — project-wide caller search
  # ===========================================================================

  @doc """
  Finds all callers of a function across the project.

  Walks all project source files looking for qualified calls, pipe-chain calls,
  and function captures (`&Mod.fun/arity`) that reference the given target.

  ## Target Formats

  The `target` argument accepts several formats:

    * A string: `"MyApp.Accounts.create_user/2"`
    * A tuple with arity: `{MyApp.Accounts, :create_user, 2}`
    * A tuple matching any arity: `{MyApp.Accounts, :create_user}`

  ## Options

    * `:mix_root` — path to the Mix project root (defaults to current directory).
    * `:files` — a pre-loaded map of `%{path => source_string}` to search instead
      of reading from disk.

  ## Return Value

  Returns `{:ok, result}` where result is a map:

      %{
        target: %{module: "MyApp.Accounts", function: :create_user, arity: 2},
        total: 5,
        files: %{
          "lib/my_app_web/controllers/user_controller.ex" => [
            %{line: 14, kind: :call, arity: 2, snippet: "...", in_module: "MyAppWeb.UserController"}
          ]
        }
      }

  ## Examples

      {:ok, result} = Adze.find_callers("MyApp.Accounts.create_user/2")
      {:ok, result} = Adze.find_callers({MyApp.Accounts, :create_user, 2}, mix_root: "/path/to/project")

  See `Adze.FindCallers` for full details.
  """
  @spec find_callers(
          String.t() | {module(), atom()} | {module(), atom(), non_neg_integer() | :any},
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  defdelegate find_callers(target, opts \\ []), to: Adze.FindCallers

  # ===========================================================================
  # ExtractPrivate — flip def → defp when safe
  # ===========================================================================

  @doc """
  Dry-run: determines if a public function can be safely made private.

  Searches the project for external callers of the specified definition. If none
  are found, returns the diff that would flip `def` → `defp` along with the
  transformed source.

  ## Options

    * `:definition` (required) — the function spec, e.g. `"helper/2"`.
    * `:mix_root` — path to the Mix project root.
    * `:files` — pre-loaded source map.
    * `:include_attrs` — list of attribute atoms to include with the definition
      (e.g. `[:doc, :spec]`).

  ## Return Value

  On success returns `{:ok, result}` where result is:

      %{
        diff: "...",
        new_source: "...",
        module: "MyApp.Helpers",
        name: :helper,
        arity: 2,
        from_kind: :def,
        to_kind: :defp
      }

  Returns `{:error, {:external_callers, [...]}}` if external callers exist.

  ## Examples

      {:ok, result} = Adze.extract_private(source, definition: "helper/2")

  See `Adze.ExtractPrivate` for full details.
  """
  @spec extract_private(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate extract_private(source, opts), to: Adze.ExtractPrivate

  @doc """
  Dry-run: reads a file and determines if a public function can be made private.

  Same as `extract_private/2` but reads source from the given file path.

  ## Examples

      {:ok, result} = Adze.extract_private_file("lib/my_app/helpers.ex", definition: "helper/2")

  See `Adze.ExtractPrivate` for full details.
  """
  @spec extract_private_file(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate extract_private_file(path, opts), to: Adze.ExtractPrivate

  @doc """
  Writes the def → defp flip to disk.

  Same as `extract_private_file/2` but actually writes the transformed file.
  Raises or returns an error if external callers are found.

  ## Options

    * `:definition` (required) — the function spec, e.g. `"helper/2"`.
    * `:mix_root` — path to the Mix project root.
    * `:files` — pre-loaded source map.
    * `:include_attrs` — list of attribute atoms to include with the definition.

  ## Examples

      {:ok, result} = Adze.extract_private!("lib/my_app/helpers.ex", definition: "helper/2")

  See `Adze.ExtractPrivate` for full details.
  """
  @spec extract_private!(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate extract_private!(path, opts), to: Adze.ExtractPrivate

  # ===========================================================================
  # Move — reorder definitions within a module
  # ===========================================================================

  @doc """
  Dry-run: reorders a definition within a module.

  Moves the specified definition to just before the anchor definition. Returns
  the unified diff and the new source with the move applied.

  ## Options

    * `:definition` (required) — the function to move, e.g. `"process/2"`.
    * `:before` (required) — the anchor function to move before, e.g. `"handle_call/3"`.
    * `:include_attrs` — list of attribute atoms to move along with the definition
      (e.g. `[:doc, :spec]`).

  ## Return Value

  Returns `{:ok, %{diff: String.t(), new_source: String.t()}}`.

  ## Examples

      {:ok, result} = Adze.mv(source, definition: "process/2", before: "handle_call/3")

  See `Adze.Move` for full details.
  """
  @spec mv(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate mv(source, opts), to: Adze.Move

  @doc """
  Dry-run: reads a file and reorders a definition within a module.

  Same as `mv/2` but reads source from the given file path.

  ## Examples

      {:ok, result} = Adze.mv_file("lib/my_app/server.ex", definition: "process/2", before: "handle_call/3")

  See `Adze.Move` for full details.
  """
  @spec mv_file(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate mv_file(path, opts), to: Adze.Move

  @doc """
  Writes the definition reorder to disk.

  Same as `mv_file/2` but actually writes the transformed file.

  ## Examples

      {:ok, result} = Adze.mv!("lib/my_app/server.ex", definition: "process/2", before: "handle_call/3")

  See `Adze.Move` for full details.
  """
  @spec mv!(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate mv!(path, opts), to: Adze.Move

  # ===========================================================================
  # Extract — pull a def + private closure into a new module
  # ===========================================================================

  @doc """
  Dry-run: extracts a function and its private closure into a new module.

  Computes the full extraction — the target definition plus all exclusively-reachable
  private helpers are moved to a new module. Callers across the project are identified
  and their references are rewritten.

  ## Options

    * `:definition` (required) — the function to extract, e.g. `"parse/1"`.
    * `:module` (required) — the target module name, e.g. `"MyApp.NewParser"`.
    * `:from_module` — disambiguator if source contains multiple modules.
    * `:path` — override the target file path (otherwise inferred from module name).
    * `:mix_root` — path to the Mix project root.
    * `:files` — pre-loaded source map.
    * `:include_attrs` — list of attribute atoms to extract (e.g. `[:doc, :spec]`).
    * `:app_name` — the OTP app name (used for path inference).

  ## Return Value

  Returns `{:ok, result}` where result is:

      %{
        target_module: "MyApp.NewParser",
        target_path: "lib/my_app/new_parser.ex",
        target_content: "defmodule MyApp.NewParser do\\n  ...\\nend",
        new_source: "...",
        source_diff: "...",
        source_module: "MyApp.Parser",
        public_closure_keys: [parse: 1],
        caller_diffs: %{"lib/other.ex" => "..."},
        dropped_directives: [%{kind: :import, line: 3, text: "import Helpers"}]
      }

  ## Examples

      {:ok, result} = Adze.extract(source, definition: "parse/1", module: "MyApp.NewParser")

  See `Adze.Extract` for full details.
  """
  @spec extract(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate extract(source, opts), to: Adze.Extract

  @doc """
  Dry-run: reads a file and extracts a function and its private closure into a new module.

  Same as `extract/2` but reads source from the given file path.

  ## Examples

      {:ok, result} = Adze.extract_file("lib/my_app/parser.ex", definition: "parse/1", module: "MyApp.NewParser")

  See `Adze.Extract` for full details.
  """
  @spec extract_file(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate extract_file(path, opts), to: Adze.Extract

  @doc """
  Writes the extraction to disk.

  Performs the extraction and writes both the new module file and the updated
  source file. Also rewrites callers across the project to reference the new
  module.

  ## Examples

      {:ok, result} = Adze.extract!("lib/my_app/parser.ex", definition: "parse/1", module: "MyApp.NewParser")

  See `Adze.Extract` for full details.
  """
  @spec extract!(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate extract!(path, opts), to: Adze.Extract

  # ===========================================================================
  # Rename — rename a module across the entire project
  # ===========================================================================

  @doc """
  Dry-run: renames a module across the entire project.

  Scans all project sources and computes the diffs that would rename `from` → `to`
  in module definitions, qualified calls, aliases, atoms, and file paths.

  ## Options

    * `:from` (required) — the current module name (string or atom), e.g. `"MyApp.OldName"`.
    * `:to` (required) — the new module name (string or atom), e.g. `"MyApp.NewName"`.
    * `:mix_root` — path to the Mix project root.
    * `:files` — pre-loaded source map.
    * `:app_name` — the OTP app name (used for path inference).
    * `:force` — if `true`, allow rename even with surviving references (default: `false`).

  ## Return Value

  Returns `{:ok, result}` where result is:

      %{
        from: MyApp.OldName,
        to: MyApp.NewName,
        diffs: %{"lib/my_app/old_name.ex" => "...", ...},
        moves: %{"lib/my_app/old_name.ex" => "lib/my_app/new_name.ex"},
        warnings: [...],
        notices: [...]
      }

  ## Examples

      {:ok, result} = Adze.rename(from: "MyApp.OldName", to: "MyApp.NewName")

  See `Adze.Rename` for full details.
  """
  @spec rename(keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate rename(opts), to: Adze.Rename

  @doc """
  Writes the module rename to disk.

  Same as `rename/1` but actually writes all diffs and performs file moves.
  Refuses to proceed if there are surviving references that couldn't be
  automatically rewritten — unless `force: true` is passed.

  ## Examples

      {:ok, result} = Adze.rename!(from: "MyApp.OldName", to: "MyApp.NewName")
      {:ok, result} = Adze.rename!(from: "MyApp.OldName", to: "MyApp.NewName", force: true)

  See `Adze.Rename` for full details.
  """
  @spec rename!(keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate rename!(opts), to: Adze.Rename
end
