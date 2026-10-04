defmodule Adze.CLI do
  @moduledoc """
  Command-line entry point.

  Usage:

      adze ls --file lib/foo.ex
      adze outline --file lib/foo.ex --format json
      adze deps --file lib/foo.ex
      adze deps --file lib/foo.ex --definition bar/2
      adze mv   --file lib/foo.ex --definition bar/2 --before baz/1 --dry-run
      adze mv   --file lib/foo.ex --definition bar/2 --before baz/1

  `ls` and `outline` are aliases.
  """

  alias Adze.{
    Aliases,
    Definition,
    Deps,
    Extract,
    ExtractPrivate,
    FindCallers,
    Formatter,
    LsDeps,
    Move,
    Outline,
    Rename
  }

  @doc false
  # One flat clause per op; splitting the dispatch wouldn't make it simpler.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def main(argv) do
    case parse(argv) do
      :help ->
        IO.write(help())

      {:ok, %{op: op, file: file, format: format}} when op in [:ls, :outline] ->
        run_outline(file, format)

      {:ok, %{op: :deps, file: file, format: format, definition: definition}} ->
        run_deps(file, format, definition)

      {:ok, %{op: :"ls-deps", file: file, format: format, definition: definition}} ->
        run_ls_deps(file, format, definition)

      {:ok, %{op: :"ls-extract", file: file, format: format, definition: definition}} ->
        run_ls_extract(file, format, definition)

      {:ok, %{op: :aliases, file: file, format: format}} ->
        run_aliases(file, format)

      {:ok, %{op: :"find-callers"} = args} ->
        run_find_callers(args)

      {:ok, %{op: :"extract-private"} = args} ->
        run_extract_private(args, write?: not args.dry_run)

      {:ok, %{op: :mv} = args} ->
        run_mv(args.file, args.format, args.definition, args.before, write?: not args.dry_run)

      {:ok, %{op: :extract} = args} ->
        run_extract(args, write?: not args.dry_run)

      {:ok, %{op: :rename} = args} ->
        run_rename(args, write?: not args.dry_run)

      {:ok, %{op: op}} when op in [:"extract-private!", :mv!, :extract!, :rename!] ->
        base = op |> Atom.to_string() |> String.trim_trailing("!")

        die(
          "`#{op}` was removed: `#{base}` now writes by default. " <>
            "Pass --dry-run to preview without writing."
        )

      {:ok, %{op: op}} ->
        die("unknown op: #{op}\n\n" <> help())

      {:error, msg} ->
        die(msg <> "\n\n" <> help())
    end
  end

  defp run_outline(nil, _format), do: die("--file is required\n\n" <> help())

  defp run_outline(path, format) do
    case Outline.outline_file(path) do
      {:ok, outline} ->
        IO.write(Formatter.format(outline, format))

      {:error, {:file_read, reason}} ->
        die("could not read #{path}: #{:file.format_error(reason)}")

      {:error, {:parse, reason}} ->
        die("parse error: #{inspect(reason)}")
    end
  end

  defp run_deps(nil, _format, _definition), do: die("--file is required\n\n" <> help())

  defp run_deps(path, format, definition) do
    case Deps.deps_file(path) do
      {:ok, deps} ->
        case filter_definition(deps, definition) do
          {:ok, filtered} -> IO.write(Formatter.format_deps(filtered, format))
          {:error, msg} -> die(msg <> " in #{path}")
        end

      {:error, {:file_read, reason}} ->
        die("could not read #{path}: #{:file.format_error(reason)}")

      {:error, {:parse, reason}} ->
        die("parse error: #{inspect(reason)}")
    end
  end

  defp run_ls_deps(nil, _format, _definition), do: die("--file is required\n\n" <> help())

  defp run_ls_deps(_path, _format, nil),
    do: die("--definition is required for ls-deps\n\n" <> help())

  defp run_ls_deps(path, format, definition) do
    case LsDeps.ls_deps_file(path, definition) do
      {:ok, %{modules: []}} ->
        die("--definition #{definition} not found in #{path}")

      {:ok, result} ->
        IO.write(Formatter.format_ls_deps(result, format))

      {:error, {:file_read, reason}} ->
        die("could not read #{path}: #{:file.format_error(reason)}")

      {:error, {:parse, reason}} ->
        die("parse error: #{inspect(reason)}")
    end
  end

  defp run_ls_extract(nil, _format, _definition), do: die("--file is required\n\n" <> help())

  defp run_ls_extract(_path, _format, nil),
    do: die("--definition is required for ls-extract\n\n" <> help())

  defp run_ls_extract(path, format, definition) do
    case LsDeps.ls_extract_file(path, definition) do
      {:ok, %{modules: []}} ->
        die("--definition #{definition} not found in #{path}")

      {:ok, result} ->
        IO.write(Formatter.format_ls_extract(result, format))

      {:error, {:file_read, reason}} ->
        die("could not read #{path}: #{:file.format_error(reason)}")

      {:error, {:parse, reason}} ->
        die("parse error: #{inspect(reason)}")
    end
  end

  defp run_extract_private(%{file: nil}, _opts), do: die("--file is required\n\n" <> help())

  defp run_extract_private(%{definition: nil}, _opts),
    do: die("--definition is required for extract-private\n\n" <> help())

  defp run_extract_private(args, opts) do
    ep_opts =
      [definition: args.definition, force: args.force]
      |> maybe_put_opt(:from_module, args.from_module)
      |> maybe_put_opt(:mix_root, args.mix_root)

    ep_fun =
      if Keyword.fetch!(opts, :write?),
        do: &ExtractPrivate.extract_private!/2,
        else: &ExtractPrivate.extract_private_file/2

    case ep_fun.(args.file, ep_opts) do
      {:ok, result} ->
        IO.write(Formatter.format_extract_private(result, args.format))

      {:error, reason} ->
        die(extract_private_error(reason, args))
    end
  end

  defp extract_private_error({:file_read, reason}, args) do
    "could not read #{args.file}: #{:file.format_error(reason)}"
  end

  defp extract_private_error({:file_write, reason}, args) do
    "could not write #{args.file}: #{format_write_error(reason)}"
  end

  defp extract_private_error({:parse, reason}, _args) do
    "parse error: #{inspect(reason)}"
  end

  defp extract_private_error({:not_found, :definition}, args) do
    "--definition not found in #{args.file}"
  end

  defp extract_private_error({:ambiguous_source_module, %{definition: d, modules: mods}}, _args) do
    "definition #{inspect(d)} exists in multiple modules: #{Enum.join(mods, ", ")}.\n" <>
      "Pass --from-module to disambiguate."
  end

  defp extract_private_error({:from_module_mismatch, %{from: from, candidates: mods}}, _args) do
    "--from-module #{from} doesn't match. Candidates: #{Enum.join(mods, ", ")}"
  end

  defp extract_private_error({:already_private, %{kind: k}}, _args) do
    "definition is already private (#{k}). Nothing to do."
  end

  defp extract_private_error(:cannot_be_private, _args) do
    "defdelegate has no private form. Convert to a regular `defp` " <>
      "delegating to the target manually if needed."
  end

  defp extract_private_error({:external_callers, refs}, _args) do
    format_externals_error(refs)
  end

  defp extract_private_error(
         {:behaviour_callback, %{definition: {n, a}, module: mod, reason: reason}},
         _args
       ) do
    why =
      case reason do
        {:impl, value} -> "it is marked `@impl #{value}`"
        {:behaviour, b} -> "#{b} declares it as a callback"
      end

    "extract-private refused — #{mod}.#{n}/#{a} is a behaviour callback " <>
      "(#{why}).\nCallbacks are invoked dynamically and must stay public."
  end

  defp extract_private_error(
         {:possible_callback, %{definition: {n, a}, module: mod, uses: uses, behaviours: behs}},
         _args
       ) do
    decls =
      Enum.map(uses, &"use #{&1}") ++ Enum.map(behs, &"@behaviour #{&1}")

    "extract-private refused — #{mod}.#{n}/#{a} may be called dynamically: " <>
      "the module declares #{Enum.join(decls, ", ")}, which adze can't " <>
      "load to check for callbacks.\n" <>
      "Callbacks and dispatched functions (GenServer callbacks, Phoenix " <>
      "actions, LiveView callbacks) have no visible callers.\n" <>
      "Pass --force if you've verified #{n}/#{a} isn't one of them."
  end

  defp extract_private_error({:unsupported_module, module}, _args) do
    unsupported_module_message(module)
  end

  defp extract_private_error({:ambiguous_attribute, _} = err, _args) do
    "ambiguous attribute attachment: #{inspect(err)}"
  end

  defp extract_private_error(reason, _args) do
    "extract-private failed: #{inspect(reason)}"
  end

  defp unsupported_module_message(module) do
    "cannot check callers of definitions in `defmodule #{module}`: " <>
      "find-callers only searches Foo.Bar-style module names"
  end

  defp format_externals_error(refs) do
    lines =
      refs
      |> Enum.sort_by(&{&1.path, &1.line})
      |> Enum.map_join("\n", fn r ->
        mod = r[:in_module] || "?"
        "  #{r.path}:#{r.line}  (#{mod})  #{r.snippet}"
      end)

    """
    extract-private refused — #{length(refs)} external caller(s) would compile-break:

    #{lines}

    Resolve these (rename, inline, or update the callers to use the new
    name) before retrying. Or use `mix adze find-callers --target ...` to
    explore the graph.
    """
  end

  defp run_find_callers(%{target: nil}),
    do: die("--target is required for find-callers\n\n" <> help())

  defp run_find_callers(args) do
    fc_opts = maybe_put_opt([], :mix_root, args.mix_root)

    case FindCallers.find_callers(args.target, fc_opts) do
      {:ok, result} ->
        IO.write(Formatter.format_find_callers(result, args.format))

      {:error, {:bad_target, t}} ->
        die(
          "bad --target value: #{inspect(t)} (expected Module.fun, Module.fun/arity or Module.fun/a,b)"
        )

      {:error, reason} ->
        die("find-callers failed: #{inspect(reason)}")
    end
  end

  defp run_aliases(nil, _format), do: die("--file is required\n\n" <> help())

  defp run_aliases(path, format) do
    case Aliases.aliases_file(path) do
      {:ok, result} ->
        IO.write(Formatter.format_aliases(result, format))

      {:error, {:file_read, reason}} ->
        die("could not read #{path}: #{:file.format_error(reason)}")

      {:error, {:parse, reason}} ->
        die("parse error: #{inspect(reason)}")
    end
  end

  defp run_mv(nil, _format, _definition, _before, _opts),
    do: die("--file is required\n\n" <> help())

  defp run_mv(_file, _format, nil, _before, _opts),
    do: die("--definition is required for mv\n\n" <> help())

  defp run_mv(_file, _format, _definition, nil, _opts),
    do: die("--before is required for mv\n\n" <> help())

  defp run_mv(file, format, definition, before, opts) do
    mv_fun =
      if Keyword.fetch!(opts, :write?), do: &Move.mv!/2, else: &Move.mv_file/2

    case mv_fun.(file, definition: definition, before: before) do
      {:ok, result} ->
        IO.write(Formatter.format_mv(result, format))

      {:error, reason} ->
        die(mv_error(reason, file))
    end
  end

  defp mv_error({:file_read, reason}, file) do
    "could not read #{file}: #{:file.format_error(reason)}"
  end

  defp mv_error({:parse, reason}, _file) do
    "parse error: #{inspect(reason)}"
  end

  defp mv_error({:file_write, reason}, file) do
    "could not write #{file}: #{format_write_error(reason)}"
  end

  defp mv_error({:format, exception}, _file) do
    "formatting failed after the move: #{Exception.message(exception)}"
  end

  defp mv_error({:not_found, :definition}, file) do
    "--definition not found in #{file}"
  end

  defp mv_error({:not_found, :before}, file) do
    "--before target not found in #{file}"
  end

  defp mv_error(:self_anchor, _file) do
    "--definition and --before refer to the same definition"
  end

  defp mv_error({:cross_module_move, info}, _file) do
    "cross-module move: #{inspect(info.definition)} is in #{info.definition_module}, " <>
      "but #{inspect(info.before)} is in #{info.before_module}. " <>
      "mv only reorders within a single module."
  end

  defp mv_error({:ambiguous_attribute, _} = err, _file) do
    "ambiguous attribute attachment: #{inspect(err)}"
  end

  defp mv_error(reason, _file) do
    "mv failed: #{inspect(reason)}"
  end

  defp run_extract(%{file: nil}, _opts), do: die("--file is required\n\n" <> help())

  defp run_extract(%{definition: nil}, _opts),
    do: die("--definition is required for extract\n\n" <> help())

  defp run_extract(%{module: nil}, _opts),
    do: die("--module is required for extract\n\n" <> help())

  defp run_extract(args, opts) do
    extract_opts =
      [definition: args.definition, module: args.module]
      |> maybe_put_opt(:from_module, args.from_module)
      |> maybe_put_opt(:path, args.path)
      |> maybe_put_opt(:mix_root, args.mix_root)

    extract_fun =
      if Keyword.fetch!(opts, :write?), do: &Extract.extract!/2, else: &Extract.extract_file/2

    case extract_fun.(args.file, extract_opts) do
      {:ok, result} ->
        IO.write(Formatter.format_extract(result, args.format))

      {:error, reason} ->
        die(extract_error(reason, args))
    end
  end

  defp extract_error({:file_read, reason}, args) do
    "could not read #{args.file}: #{:file.format_error(reason)}"
  end

  defp extract_error({:file_write, reason}, _args) do
    "could not write: #{format_write_error(reason)}"
  end

  defp extract_error({:format, exception}, _args) do
    "formatting failed after the extract: #{Exception.message(exception)}"
  end

  defp extract_error({:render, exception}, _args) do
    "rendering the extracted AST failed: #{Exception.message(exception)}"
  end

  defp extract_error({:parse, reason}, _args) do
    "parse error: #{inspect(reason)}"
  end

  defp extract_error({:target_exists, path}, _args) do
    "target file already exists: #{path}\n" <>
      "(adze refuses to overwrite; pick another --module or delete the file)"
  end

  defp extract_error({:bad_module_name, name}, _args) do
    "bad --module value: #{name} (expected dot-separated CamelCase, e.g. MyApp.Helpers)"
  end

  defp extract_error({:unsupported_module, module}, _args) do
    unsupported_module_message(module)
  end

  defp extract_error({:not_found, key}, args) do
    "definition not found in #{args.file}: #{inspect(key)}"
  end

  defp extract_error({:ambiguous_source_module, %{definition: d, modules: mods}}, _args) do
    "definition #{inspect(d)} exists in multiple modules: #{Enum.join(mods, ", ")}.\n" <>
      "Pass --from-module to disambiguate."
  end

  defp extract_error({:from_module_mismatch, %{from: from, candidates: mods}}, _args) do
    "--from-module #{from} doesn't contain the definition. " <>
      "Candidates: #{Enum.join(mods, ", ")}"
  end

  defp extract_error({:typep_referenced, %{type: {n, a}, source: mod}}, _args) do
    "extracted @spec references @typep #{n}/#{a} in #{mod}, which can't be " <>
      "qualified across modules.\nWiden the @typep to @type in source first, " <>
      "then re-run extract."
  end

  defp extract_error({:private_macro_referenced, %{definitions: defs, source: mod}}, _args) do
    names = Enum.map_join(defs, ", ", fn {kind, n, a} -> "#{kind} #{n}/#{a}" end)

    "extracted code uses macros/guards that stay in #{mod}: #{names}.\n" <>
      "The target would need `require #{mod}` (and private ones must be public), " <>
      "or move them first, then re-run extract."
  end

  defp extract_error({:moved_macro_referenced, %{definitions: defs, source: mod}}, _args) do
    names = Enum.map_join(defs, ", ", fn {kind, n, a} -> "#{kind} #{n}/#{a}" end)

    "extracting #{names} would leave callers (in #{mod} or other files) " <>
      "calling it remotely without `require`.\n" <>
      "Add `require <Target>` to each caller yourself after moving, or " <>
      "move the callers too."
  end

  defp extract_error({:imported_by, %{source: mod, files: files, definitions: defs}}, _args) do
    names = Enum.map_join(defs, ", ", fn {n, a} -> "#{n}/#{a}" end)

    "#{mod} is imported by #{Enum.join(files, ", ")}; bare calls there to " <>
      "#{names} can't be retargeted.\nSwitch those files to qualified calls " <>
      "(or import the new module) first, then re-run extract."
  end

  defp extract_error({:ambiguous_attribute, _} = err, _args) do
    "ambiguous attribute attachment: #{inspect(err)}"
  end

  defp extract_error(reason, _args) do
    "extract failed: #{inspect(reason)}"
  end

  defp run_rename(%{from: nil}, _opts), do: die("--from is required\n\n" <> help())
  defp run_rename(%{to: nil}, _opts), do: die("--to is required\n\n" <> help())

  defp run_rename(args, opts) do
    rename_opts =
      [from: args.from, to: args.to, force: args.force]
      |> maybe_put_opt(:mix_root, args.mix_root)

    rename_fun =
      if Keyword.fetch!(opts, :write?), do: &Rename.rename!/1, else: &Rename.rename/1

    case rename_fun.(rename_opts) do
      {:ok, result} ->
        IO.write(Formatter.format_rename(result, args.format))

      {:error, reason} ->
        die(rename_error(reason))
    end
  end

  defp rename_error({:missing_opt, key}) do
    "--#{key} is required\n\n" <> help()
  end

  defp rename_error({:bad_module_name, key, value}) do
    "--#{key} must be dot-separated CamelCase, got: #{inspect(value)}"
  end

  defp rename_error({:same_module, mod}) do
    "--from and --to are the same module: #{inspect(mod)}"
  end

  defp rename_error({:issues, issues}) do
    "rename refused — Igniter reported issues:\n  - " <> Enum.join(issues, "\n  - ")
  end

  defp rename_error({:surviving_references, refs}) do
    format_surviving_error(refs)
  end

  defp rename_error({:file_write, reason}) do
    "could not write: #{format_write_error(reason)}"
  end

  defp rename_error(reason) do
    "rename failed: #{inspect(reason)}"
  end

  defp format_surviving_error(refs) do
    lines =
      refs
      |> Enum.map_join("\n", fn %{path: p, line: l, short: s} -> "  #{p}:#{l}  #{s}.…" end)

    """
    rename refused — the rewrite would leave #{length(refs)} surviving bare-alias \
    reference(s) to the old module's short name. These would compile-break on the \
    next `mix compile`. Locations:

    #{lines}

    Known Igniter bug for same-namespace renames (A.B.X → A.B.Y): the bare \
    `X.fun(...)` call sites aren't rewritten even though the alias declaration is. \
    Re-run as a cross-namespace rename (e.g. via an intermediate name), or pass \
    --force to write anyway and fix the references by hand.
    """
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp filter_definition(deps, nil), do: {:ok, deps}

  defp filter_definition(deps, spec) do
    case Definition.resolve_spec(spec, Enum.flat_map(deps.modules, & &1.defs)) do
      {:ok, {name, arity}} ->
        modules =
          deps.modules
          |> Enum.map(fn m ->
            %{m | defs: Enum.filter(m.defs, &(&1.name == name and &1.arity == arity))}
          end)
          |> Enum.reject(&(&1.defs == []))

        if modules == [] do
          {:error, "--definition #{spec} not found"}
        else
          {:ok, %{deps | modules: modules}}
        end

      {:error, _} ->
        {:error, "bad --definition value: #{spec} (expected name/arity)"}
    end
  end

  defp parse([]), do: {:error, "no op given"}
  defp parse([flag | _]) when flag in ["--help", "-h", "help"], do: :help
  defp parse([_op, flag | _]) when flag in ["--help", "-h"], do: :help

  defp parse([op | rest]) do
    {parsed, _, invalid} =
      OptionParser.parse(rest,
        strict: [
          file: :string,
          format: :string,
          definition: :string,
          def: :string,
          before: :string,
          module: :string,
          from_module: :string,
          from: :string,
          to: :string,
          path: :string,
          mix_root: :string,
          target: :string,
          force: :boolean,
          dry_run: :boolean
        ],
        aliases: [f: :file]
      )

    definition_raw = Keyword.get(parsed, :definition) || Keyword.get(parsed, :def)

    with :ok <- check_invalid(invalid),
         {:ok, format} <- parse_format(Keyword.get(parsed, :format, "text")),
         {:ok, definition} <- parse_definition(definition_raw),
         {:ok, before} <- parse_definition(Keyword.get(parsed, :before), "--before") do
      {:ok,
       %{
         op: op_atom(op),
         file: Keyword.get(parsed, :file),
         format: format,
         definition: definition,
         before: before,
         module: Keyword.get(parsed, :module),
         from_module: Keyword.get(parsed, :from_module),
         from: Keyword.get(parsed, :from),
         to: Keyword.get(parsed, :to),
         path: Keyword.get(parsed, :path),
         mix_root: Keyword.get(parsed, :mix_root),
         target: Keyword.get(parsed, :target),
         force: Keyword.get(parsed, :force, false),
         dry_run: Keyword.get(parsed, :dry_run, false)
       }}
    end
  end

  defp check_invalid([]), do: :ok

  defp check_invalid(invalid) do
    flags = Enum.map_join(invalid, ", ", fn {flag, _} -> flag end)
    {:error, "unknown or invalid option(s): #{flags}"}
  end

  defp parse_format("json"), do: {:ok, :json}
  defp parse_format("text"), do: {:ok, :text}
  defp parse_format(other), do: {:error, "unknown format: #{other} (expected text|json)"}

  defp parse_definition(nil), do: {:ok, nil}
  defp parse_definition(str), do: parse_definition(str, "--definition")

  defp parse_definition(nil, _label), do: {:ok, nil}

  # Validate only; the raw string is passed to the library, which resolves
  # the name against the parsed source instead of creating an atom.
  defp parse_definition(str, label) do
    case Definition.parse_definition_spec(str) do
      {:ok, _} -> {:ok, str}
      {:error, _} -> {:error, "bad #{label} value: #{str} (expected name/arity)"}
    end
  end

  # Every valid op is already an atom (they appear in `main/1`'s clauses),
  # so an unknown one stays a string, reported by the `unknown op` clause.
  defp op_atom(":" <> op), do: op_atom(op)

  defp op_atom(op) do
    String.to_existing_atom(op)
  rescue
    ArgumentError -> op
  end

  # `{:file_write, reason}` carries a POSIX atom from a single
  # `File.write`, or — from `ProjectRewrite.write/1`, after it rolled
  # back — a list of per-file reasons (`{path, reason}` or a bare
  # reason; Rewrite adds `:changed` when a file was modified on disk
  # after it was read).
  defp format_write_error(reasons) when is_list(reasons),
    do: Enum.map_join(reasons, "; ", &format_write_error/1)

  defp format_write_error({path, reason}) when is_binary(path),
    do: "#{path}: #{format_write_error(reason)}"

  defp format_write_error(:changed), do: "file changed on disk since it was read"

  defp format_write_error(reason) when is_atom(reason) do
    case to_string(:file.format_error(reason)) do
      "unknown POSIX error" <> _ -> inspect(reason)
      message -> message
    end
  end

  defp format_write_error(other), do: inspect(other)

  @spec die(String.t()) :: no_return()
  defp die(msg) do
    Mix.raise(String.trim_trailing(msg))
  end

  defp help do
    """
    adze — structural Elixir refactoring (alpha)

    OPS
      ls | outline     Outline a file: top-level definitions with line ranges
      deps             Intra-module call graph (per def, who it calls)
      ls-deps          Recursive call tree rooted at one def
                       (--definition required)
      ls-extract       Intra-module closure: target + exclusively-called
                       defps. Suggestion for what `extract!` would take.
      aliases          List every alias / import / require / use per
                       module with line ranges. Group-form aliases
                       (alias Foo.{A, B}) are expanded.
      find-callers     Project-wide read-only search for every call
                       site, capture, and pipe reference to a
                       Module.fun[/arity]. Resolves aliases per file.
                       (--target required)
      extract-private  Flip a public def to defp (or defmacro→defmacrop,
                       defguard→defguardp) when find-callers reports
                       zero external callers. Writes the file; prints
                       the diff.
      mv               Reorder a def within a module. Writes the file;
                       prints the diff.
                       Note: diff shows the minimal edit, so when two
                       defs are swapped Myers may render the *anchor*
                       moving rather than --definition. The resulting
                       source is correct either way.
      extract          Cut a def (+ its private closure) into a brand-new
                       module file. Writes both files; prints the new
                       file and a diff of the source.
      rename           Rename a module across the entire project. Updates
                       defmodule, alias/use/import/require, every call
                       site, the corresponding test module, and moves
                       the file to its canonical location. Writes every
                       touched file; prints per-file diffs. Refuses to
                       write if a post-check finds surviving short-name
                       refs (would compile-break). Pass --force to
                       override.

    Write ops (extract-private, mv, extract, rename) write by default.
    Pass --dry-run to print the same output without touching disk.

    FLAGS
      --file PATH      Source file to operate on
      --format FMT     text (default) | json
      --definition NAME/ARITY  Pick one def. Required for ls-deps /
                               ls-extract / mv / extract,
                               optional for deps. Short alias: --def.
      --before NAME/ARITY  Anchor for mv: insert --definition just before
                           this def.
      --module Foo.Bar     Target module name for extract. Path is
                           derived (lib/foo/bar.ex).
      --from-module Foo    Disambiguate the source module when the file
                           has multiple defmodules containing the def.
      --from Foo.Bar       Source module name (rename).
      --to Foo.Baz         New module name (rename).
      --mix-root PATH      Project root for rename / find-callers
                           (default: cwd).
      --target Mod.fun[/n] Reference target for find-callers. Arity
                           is optional — omit it to match any arity
                           (e.g. --target MyApp.Foo.bar or
                           --target MyApp.Foo.bar/2). A comma list
                           matches several arities
                           (--target MyApp.Foo.bar/1,2).
      --dry-run            For write ops: compute and print the result,
                           but write nothing.
      --force              Skip the post-check guard on rename and
                           write even when surviving short refs are
                           detected. Use when you've verified the
                           refs are false positives. For
                           extract-private, allow the flip in a module
                           whose `use` / `@behaviour` can't be checked
                           (known callbacks are still refused).

    EXAMPLES
      adze ls --file lib/my_app/router.ex
      adze outline --file lib/my_app/router.ex --format json
      adze deps --file lib/my_app/router.ex
      adze deps --file lib/my_app/router.ex --definition dispatch/2
      adze ls-deps --file lib/my_app/router.ex --definition dispatch/2
      adze ls-extract --file lib/my_app/router.ex --definition dispatch/2
      adze aliases --file lib/my_app/router.ex
      adze find-callers --target MyApp.Foo.bar/2
      adze find-callers --target MyApp.Foo.bar          # any arity
      adze extract-private --file lib/my_app/router.ex --definition helper/2
      adze mv --file lib/my_app/router.ex --definition dispatch/2 --before init/1
      adze extract --file lib/my_app/router.ex --definition dispatch/2 --module MyApp.Dispatcher
      adze rename --from MyApp.Old --to MyApp.New
      adze rename --from MyApp.Old --to MyApp.New --dry-run
    """
  end
end
