defmodule Adze.CLI do
  @moduledoc """
  Command-line entry point.

  Usage:

      adze ls --file lib/foo.ex
      adze outline --file lib/foo.ex --format json
      adze deps --file lib/foo.ex
      adze deps --file lib/foo.ex --definition bar/2
      adze mv   --file lib/foo.ex --definition bar/2 --before baz/1
      adze mv!  --file lib/foo.ex --definition bar/2 --before baz/1

  `ls` and `outline` are aliases.
  """

  alias Adze.{
    Outline,
    Deps,
    LsDeps,
    Aliases,
    Move,
    Extract,
    ExtractPrivate,
    Rename,
    FindCallers,
    Formatter
  }

  @doc false
  def main(argv) do
    case parse(argv) do
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
        run_extract_private(args, write?: false)

      {:ok, %{op: :"extract-private!"} = args} ->
        run_extract_private(args, write?: true)

      {:ok, %{op: :mv, file: file, format: format, definition: definition, before: before}} ->
        run_mv(file, format, definition, before, write?: false)

      {:ok, %{op: :mv!, file: file, format: format, definition: definition, before: before}} ->
        run_mv(file, format, definition, before, write?: true)

      {:ok, %{op: :extract} = args} ->
        run_extract(args, write?: false)

      {:ok, %{op: :extract!} = args} ->
        run_extract(args, write?: true)

      {:ok, %{op: :rename} = args} ->
        run_rename(args, write?: false)

      {:ok, %{op: :rename!} = args} ->
        run_rename(args, write?: true)

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
        IO.write(Formatter.format_deps(filter_definition(deps, definition), format))

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
      [definition: args.definition]
      |> maybe_put_opt(:from_module, args.from_module)
      |> maybe_put_opt(:mix_root, args.mix_root)

    ep_fun =
      if Keyword.fetch!(opts, :write?),
        do: &ExtractPrivate.extract_private!/2,
        else: &ExtractPrivate.extract_private_file/2

    case ep_fun.(args.file, ep_opts) do
      {:ok, result} ->
        IO.write(Formatter.format_extract_private(result, args.format))

      {:error, {:file_read, reason}} ->
        die("could not read #{args.file}: #{:file.format_error(reason)}")

      {:error, {:file_write, reason}} ->
        die("could not write #{args.file}: #{:file.format_error(reason)}")

      {:error, {:parse, reason}} ->
        die("parse error: #{inspect(reason)}")

      {:error, {:not_found, :definition}} ->
        die("--definition not found in #{args.file}")

      {:error, {:ambiguous_source_module, %{definition: d, modules: mods}}} ->
        die(
          "definition #{inspect(d)} exists in multiple modules: #{Enum.join(mods, ", ")}.\n" <>
            "Pass --from-module to disambiguate."
        )

      {:error, {:from_module_mismatch, %{from: from, candidates: mods}}} ->
        die("--from-module #{from} doesn't match. Candidates: #{Enum.join(mods, ", ")}")

      {:error, {:already_private, %{kind: k}}} ->
        die("definition is already private (#{k}). Nothing to do.")

      {:error, :cannot_be_private} ->
        die(
          "defdelegate has no private form. Convert to a regular `defp` " <>
            "delegating to the target manually if needed."
        )

      {:error, {:external_callers, refs}} ->
        die(format_externals_error(refs))

      {:error, {:ambiguous_attribute, _} = err} ->
        die("ambiguous attribute attachment: #{inspect(err)}")

      {:error, reason} ->
        die("extract-private failed: #{inspect(reason)}")
    end
  end

  defp format_externals_error(refs) do
    lines =
      refs
      |> Enum.sort_by(&{&1.path, &1.line})
      |> Enum.map(fn r ->
        mod = r[:in_module] || "?"
        "  #{r.path}:#{r.line}  (#{mod})  #{r.snippet}"
      end)
      |> Enum.join("\n")

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
        die("bad --target value: #{inspect(t)} (expected Module.fun or Module.fun/arity)")

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

      {:error, {:file_read, reason}} ->
        die("could not read #{file}: #{:file.format_error(reason)}")

      {:error, {:parse, reason}} ->
        die("parse error: #{inspect(reason)}")

      {:error, {:file_write, reason}} ->
        die("could not write #{file}: #{:file.format_error(reason)}")

      {:error, {:format, exception}} ->
        die("formatting failed after the move: #{Exception.message(exception)}")

      {:error, {:not_found, :definition}} ->
        die("--definition not found in #{file}")

      {:error, {:not_found, :before}} ->
        die("--before target not found in #{file}")

      {:error, :self_anchor} ->
        die("--definition and --before refer to the same definition")

      {:error, {:cross_module_move, info}} ->
        die(
          "cross-module move: #{inspect(info.definition)} is in #{info.definition_module}, " <>
            "but #{inspect(info.before)} is in #{info.before_module}. " <>
            "mv only reorders within a single module."
        )

      {:error, {:ambiguous_attribute, _} = err} ->
        die("ambiguous attribute attachment: #{inspect(err)}")

      {:error, reason} ->
        die("mv failed: #{inspect(reason)}")
    end
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

      {:error, {:file_read, reason}} ->
        die("could not read #{args.file}: #{:file.format_error(reason)}")

      {:error, {:file_write, reason}} ->
        die("could not write: #{:file.format_error(reason)}")

      {:error, {:format, exception}} ->
        die("formatting failed after the extract: #{Exception.message(exception)}")

      {:error, {:render, exception}} ->
        die("rendering the extracted AST failed: #{Exception.message(exception)}")

      {:error, {:parse, reason}} ->
        die("parse error: #{inspect(reason)}")

      {:error, {:target_exists, path}} ->
        die(
          "target file already exists: #{path}\n" <>
            "(adze refuses to overwrite; pick another --module or delete the file)"
        )

      {:error, {:bad_module_name, name}} ->
        die("bad --module value: #{name} (expected dot-separated CamelCase, e.g. MyApp.Helpers)")

      {:error, {:not_found, key}} ->
        die("definition not found in #{args.file}: #{inspect(key)}")

      {:error, {:ambiguous_source_module, %{definition: d, modules: mods}}} ->
        die(
          "definition #{inspect(d)} exists in multiple modules: #{Enum.join(mods, ", ")}.\n" <>
            "Pass --from-module to disambiguate."
        )

      {:error, {:from_module_mismatch, %{from: from, candidates: mods}}} ->
        die(
          "--from-module #{from} doesn't contain the definition. " <>
            "Candidates: #{Enum.join(mods, ", ")}"
        )

      {:error, {:typep_referenced, %{type: {n, a}, source: mod}}} ->
        die(
          "extracted @spec references @typep #{n}/#{a} in #{mod}, which can't be " <>
            "qualified across modules.\nWiden the @typep to @type in source first, " <>
            "then re-run extract."
        )

      {:error, {:ambiguous_attribute, _} = err} ->
        die("ambiguous attribute attachment: #{inspect(err)}")

      {:error, reason} ->
        die("extract failed: #{inspect(reason)}")
    end
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

      {:error, {:missing_opt, key}} ->
        die("--#{key} is required\n\n" <> help())

      {:error, {:bad_module_name, key, value}} ->
        die("--#{key} must be dot-separated CamelCase, got: #{inspect(value)}")

      {:error, {:same_module, mod}} ->
        die("--from and --to are the same module: #{inspect(mod)}")

      {:error, {:issues, issues}} ->
        die("rename refused — Igniter reported issues:\n  - " <> Enum.join(issues, "\n  - "))

      {:error, {:surviving_references, refs}} ->
        die(format_surviving_error(refs))

      {:error, {:file_write, reason}} ->
        die("could not write: #{:file.format_error(reason)}")

      {:error, reason} ->
        die("rename failed: #{inspect(reason)}")
    end
  end

  defp format_surviving_error(refs) do
    lines =
      refs
      |> Enum.map(fn %{path: p, line: l, short: s} -> "  #{p}:#{l}  #{s}.…" end)
      |> Enum.join("\n")

    """
    rename! refused — the rewrite would leave #{length(refs)} surviving bare-alias \
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

  defp filter_definition(deps, nil), do: deps

  defp filter_definition(deps, {name, arity}) do
    modules =
      deps.modules
      |> Enum.map(fn m ->
        %{m | defs: Enum.filter(m.defs, &(&1.name == name and &1.arity == arity))}
      end)
      |> Enum.reject(&(&1.defs == []))

    %{deps | modules: modules}
  end

  defp parse([]), do: {:error, "no op given"}

  defp parse([op | rest]) do
    {parsed, _, _} =
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
          force: :boolean
        ],
        aliases: [f: :file]
      )

    definition_raw = Keyword.get(parsed, :definition) || Keyword.get(parsed, :def)

    with {:ok, format} <- parse_format(Keyword.get(parsed, :format, "text")),
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
         force: Keyword.get(parsed, :force, false)
       }}
    end
  end

  defp parse_format("json"), do: {:ok, :json}
  defp parse_format("text"), do: {:ok, :text}
  defp parse_format(other), do: {:error, "unknown format: #{other} (expected text|json)"}

  defp parse_definition(nil), do: {:ok, nil}
  defp parse_definition(str), do: parse_definition(str, "--definition")

  defp parse_definition(nil, _label), do: {:ok, nil}

  defp parse_definition(str, label) do
    case String.split(str, "/", parts: 2) do
      [name, arity_str] ->
        case Integer.parse(arity_str) do
          {arity, ""} when arity >= 0 -> {:ok, {String.to_atom(name), arity}}
          _ -> {:error, "bad #{label} value: #{str} (expected name/arity)"}
        end

      _ ->
        {:error, "bad #{label} value: #{str} (expected name/arity)"}
    end
  end

  defp op_atom(":" <> op), do: String.to_atom(op)
  defp op_atom(op), do: String.to_atom(op)

  defp die(msg) do
    IO.puts(:stderr, msg)
    System.halt(1)
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
                       zero external callers. Dry-run; prints diff.
      extract-private! Same as extract-private but writes the file.
      mv               Reorder a def within a module. Dry-run; prints diff.
      mv!              Same as mv but actually writes the file.
                       Note: diff shows the minimal edit, so when two
                       defs are swapped Myers may render the *anchor*
                       moving rather than --definition. The resulting
                       source is correct either way.
      extract          Cut a def (+ its private closure) into a brand-new
                       module file. Dry-run; prints the new file and
                       a diff of the source.
      extract!         Same as extract but writes both files.
      rename           Rename a module across the entire project. Updates
                       defmodule, alias/use/import/require, every call
                       site, the corresponding test module, and moves
                       the file to its canonical location. Dry-run;
                       prints per-file diffs. Post-check scans for
                       surviving short-name refs and reports them in
                       warnings.
      rename!          Same as rename but writes every touched file.
                       Refuses to write if the post-check found
                       surviving refs (would compile-break). Pass
                       --force to override.

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
                           --target MyApp.Foo.bar/2).
      --force              Skip the post-check guard on rename! and
                           write even when surviving short refs are
                           detected. Use when you've verified the
                           refs are false positives.

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
      adze extract-private  --file lib/my_app/router.ex --definition helper/2
      adze extract-private! --file lib/my_app/router.ex --definition helper/2
      adze mv  --file lib/my_app/router.ex --definition dispatch/2 --before init/1
      adze mv! --file lib/my_app/router.ex --definition dispatch/2 --before init/1
      adze extract  --file lib/my_app/router.ex --definition dispatch/2 --module MyApp.Dispatcher
      adze extract! --file lib/my_app/router.ex --definition dispatch/2 --module MyApp.Dispatcher
      adze rename  --from MyApp.Old --to MyApp.New
      adze rename! --from MyApp.Old --to MyApp.New
    """
  end
end
